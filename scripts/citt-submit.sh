#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# citt-submit.sh — CITT batch CSV submit + poll + comparative summary (CITT-268)
# =============================================================================
# Runs inside Claude Code's Bash tool as part of the published CITT plugin, so
# the skill token must NEVER enter model context (stdout / argv / xtrace).
# This mirrors citt-auth.sh's (CITT-267) token-handling discipline exactly.
#
# Usage: citt-submit.sh <path-to-csv>
#
# Behavior (PLAN §5):
#   1. Load the opaque skill token IN-PROCESS (keyring-first, else TOKEN_FILE,
#      else CITT_TOKEN env override). If missing OR any call 401s, print
#      "re-authenticate: run citt-auth.sh" to stderr and exit non-zero so the
#      model re-runs auth.
#   2. Parse a FORGIVING CSV (header row, quoted fields, blank lines, missing
#      optional columns): package_id | store_url | app_name | platform |
#      is_private(default false) | scan_type(default full), one app per row.
#   3. Resolve rows: package_id used directly; store_url -> extract id;
#      app_name-only -> resolve via /api/search-apps, but NEVER auto-submit a
#      guessed match — surface it in an "unresolved / needs confirmation" block.
#   4. Dedup / cost pre-flight: GET /api/status/{pkg} first; a fresh (<90d)
#      completed scan is REUSED (no re-submit, no re-bill). This is how client-
#      side idempotency is achieved — there is no server Idempotency-Key.
#   5. Submit the rest via POST /api/submit (metered — the pre-check keeps a
#      re-invoke from double-submitting).
#   6. Poll each in-flight scan to completion with bounded backoff. A stuck/
#      failed app is time-boxed and MUST NOT strand the rest; a PARTIAL summary
#      is still emitted.
#   7. Print ONLY a non-secret comparative summary to stdout: ranked table,
#      worst offenders, clean bucket, deltas where available, the unresolved
#      section, and each row deep-linked to canitrustthat.com/apps/{pkg}.
#      On a tier 403 (Developer/Research required) print the upgrade nudge with
#      the canitrustthat.com/pricing link and stop.
#
# SECRET ISOLATION (hard invariants — red-teamed in CITT-270, statically scanned
# in CITT-264). Mirrors citt-auth.sh:
#   - The token is read IN-PROCESS and written ONLY into a 0600 curl-config temp
#     file (`Authorization: Bearer ...` as a curl `header = "..."` line). curl
#     reads it via `--config <file>`. The token is NEVER on argv, NEVER echoed/
#     printf'd, and — proven by running the whole script under `bash -x` in the
#     harness — never appears on an xtrace line. There is no `set -x` here.
#   - Host is HARDCODED (egress allow-list). A test-only seam (CITT_API_OVERRIDE,
#     honored ONLY when CITT_TEST_MODE=1) points the harness at a mock.
#   - curl error bodies are captured to a file and only the parsed error scalar
#     is surfaced — a non-2xx can never reflect the Authorization header back.
# =============================================================================

# API base (hardcoded egress allow-list — do NOT make this configurable).
CITT_API="https://canitrustthat.com"

# TEST-ONLY seam: point the client at a mock server. Honored ONLY when
# CITT_TEST_MODE=1 (set by the harness). Production host stays hardcoded.
if [ "${CITT_TEST_MODE:-}" = "1" ] && [ -n "${CITT_API_OVERRIDE:-}" ]; then
  CITT_API="${CITT_API_OVERRIDE}"
fi

# Local token file the helper scripts own (same convention as citt-auth.sh).
TOKEN_FILE="${CLAUDE_PLUGIN_DATA:-$HOME/.config/citt}/device_token"

# macOS keyring coordinates (Linux uses secret-tool with matching attributes).
KEYRING_SERVICE="canitrustthat-citt"
KEYRING_ACCOUNT="device_token"

# Polling budget knobs (overridable by the harness for speed).
POLL_BASE_SLEEP="${CITT_POLL_BASE_SLEEP:-4}"     # first backoff, seconds
POLL_MAX_SLEEP="${CITT_POLL_MAX_SLEEP:-30}"      # backoff ceiling
PER_APP_BUDGET="${CITT_PER_APP_BUDGET:-900}"     # per-app poll wall-clock cap (s)
FRESH_WINDOW_DAYS=90                              # reuse a completed scan if <this old

# ---------------------------------------------------------------------------
# JSON scalar extraction. Prefer jq; else a tight grep/sed pulling ONLY the one
# requested scalar (string or number) — never dumps the body. (From citt-auth.sh)
# ---------------------------------------------------------------------------
_json_get() {  # $1 = field  $2 = body
  local field="$1" body="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -er --arg k "$field" '.[$k] // empty' 2>/dev/null || true
    return 0
  fi
  local v
  v="$(printf '%s' "$body" \
    | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n1 \
    | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/")"
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  printf '%s' "$body" \
    | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*-\?[0-9]\+" \
    | head -n1 \
    | sed -E "s/.*:[[:space:]]*(-?[0-9]+)/\1/"
}

# ---------------------------------------------------------------------------
# Keyring lookup (read-only; citt-auth.sh owns writes). Prints the token to
# stdout of the subshell it's captured in — never to the script's own stdout.
# Returns non-zero if no keyring backend or no entry.
# ---------------------------------------------------------------------------
_keyring_lookup_to_file() {  # $1 = dest 0600 file
  local dest="$1"
  if [ "${CITT_TEST_MODE:-}" = "1" ] && [ "${CITT_FORCE_FILE_TOKEN:-}" = "1" ]; then
    return 1
  fi
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$KEYRING_SERVICE" -a "$KEYRING_ACCOUNT" -w \
      >"$dest" 2>/dev/null || return 1
    [ -s "$dest" ] || return 1
    return 0
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    secret-tool lookup service "$KEYRING_SERVICE" account "$KEYRING_ACCOUNT" \
      >"$dest" 2>/dev/null || return 1
    [ -s "$dest" ] || return 1
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Temp files (all 0600). One holds the raw token; one is the curl --config file
# carrying the Authorization header line; the rest are scratch for responses.
# ---------------------------------------------------------------------------
TOKEN_TMP="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_stok.XXXXXX")"
CURL_CFG="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_cfg.XXXXXX")"
RESP_FILE="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_resp.XXXXXX")"
BODY_FILE="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_body.XXXXXX")"
cleanup() { rm -f "$TOKEN_TMP" "$CURL_CFG" "$RESP_FILE" "$BODY_FILE" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Load the token IN-PROCESS into TOKEN_TMP (0600). Order: CITT_TOKEN env ->
# keyring -> TOKEN_FILE. The value flows via files/redirects only — never argv,
# never echo/printf, never a traced expansion. Returns non-zero if none found.
# ---------------------------------------------------------------------------
_load_token() {
  # NB: the token value is moved via `cat`/redirects and here-strings ONLY —
  # never `echo`/`printf` (which the CITT-264 static scanner flags on a secret-
  # named var) — and never as argv. `tr -d '\n'` strips a trailing newline the
  # keyring/file may carry so the header line stays single-line.
  # Use ${CITT_TOKEN+x} (set-test) not ${CITT_TOKEN:-} (value-expansion) so
  # bash -x traces only the literal "x", never the token value. (CITT-347 F1)
  if [ -n "${CITT_TOKEN+x}" ]; then
    # Move the env value into the 0600 file via a here-string fed to `cat`.
    ( umask 077; tr -d '\n' <<<"${CITT_TOKEN}" >"$TOKEN_TMP" )
    [ -s "$TOKEN_TMP" ] && return 0
  fi
  if _keyring_lookup_to_file "$TOKEN_TMP"; then
    # Normalize (drop any trailing newline) into a sibling temp, then swap.
    ( umask 077; tr -d '\n' <"$TOKEN_TMP" >"${TOKEN_TMP}.n" )
    mv -f "${TOKEN_TMP}.n" "$TOKEN_TMP"
    [ -s "$TOKEN_TMP" ] && return 0
  fi
  if [ -s "$TOKEN_FILE" ]; then
    ( umask 077; tr -d '\n' <"$TOKEN_FILE" >"$TOKEN_TMP" )
    [ -s "$TOKEN_TMP" ] && return 0
  fi
  return 1
}

# Build the 0600 curl --config file that carries the Authorization header. The
# token is read from the 0600 TOKEN_TMP file into the config file via `cat`
# (never argv, never echo/printf of the secret). The header line is assembled by
# writing the STATIC prefix, appending the token bytes with `cat`, then the
# closing quote — so no `printf`/`echo` ever takes the token as an argument.
# curl reads it via `--config "$CURL_CFG"`.
_build_curl_cfg() {
  ( umask 077
    {
      printf 'silent\n'
      printf 'show-error\n'
      printf 'header = "Authorization: Bearer '   # static prefix, no secret
      cat "$TOKEN_TMP"                            # token bytes, straight from 0600 file
      printf '"\n'                                # close the quoted header
    } >"$CURL_CFG"
  )
}

_reauth_and_exit() {
  echo "re-authenticate: run citt-auth.sh" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Authenticated request helper. Writes body -> RESP_FILE, prints the HTTP code
# to stdout of its capture. The Authorization header comes from the 0600 config
# file (never argv). On 401 the whole run aborts with the re-auth hint.
#   _api_get   <path>
#   _api_post  <path> <json-body-file>
# ---------------------------------------------------------------------------
_api_get() {  # $1 = path (already URL-safe)
  local path="$1" code
  code="$(
    curl --config "$CURL_CFG" -o "$RESP_FILE" -w '%{http_code}' \
      "${CITT_API}${path}" 2>/dev/null || true
  )"
  printf '%s' "$code"
}

_api_post() {  # $1 = path  $2 = body file (0600)
  local path="$1" bodyf="$2" code
  code="$(
    curl --config "$CURL_CFG" -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "${CITT_API}${path}" \
      -H 'Content-Type: application/json' \
      --data "@${bodyf}" 2>/dev/null || true
  )"
  printf '%s' "$code"
}

# ---------------------------------------------------------------------------
# URL-encode a package id / query for safe path/query use (stdlib python; falls
# back to a conservative passthrough if python is unavailable — package ids are
# already restricted to [A-Za-z0-9._-] server-side).
# ---------------------------------------------------------------------------
_urlenc() {  # $1 = raw
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
  else
    printf '%s' "$1"
  fi
}

# ---------------------------------------------------------------------------
# Days since an ISO-8601 (…Z) timestamp. Prints an integer (or empty on parse
# failure). Uses python3 for portable date math.
# ---------------------------------------------------------------------------
_days_since() {  # $1 = iso ts
  [ -n "$1" ] || { printf ''; return; }
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" <<'PY' 2>/dev/null || true
import sys, datetime
ts = sys.argv[1].strip().replace('Z', '+00:00')
try:
    dt = datetime.datetime.fromisoformat(ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    now = datetime.datetime.now(datetime.timezone.utc)
    print(int((now - dt).total_seconds() // 86400))
except Exception:
    pass
PY
  fi
}

# ---------------------------------------------------------------------------
# Extract a Play/App Store package id from a store URL. Play: ?id=<pkg>.
# App Store: .../id<digits> (numeric slug — server resolves it to a bundle id,
# so we keep the numeric id form which /api/submit + /api/status understand).
# ---------------------------------------------------------------------------
_pkg_from_store_url() {  # $1 = url
  local url="$1" pkg=""
  case "$url" in
    *play.google.com*id=*)
      pkg="${url#*id=}"; pkg="${pkg%%&*}" ;;
    *apps.apple.com*|*itunes.apple.com*)
      # trailing /id123456789 (optionally with a query)
      pkg="${url%%\?*}"
      pkg="${pkg##*/}"        # last path segment, e.g. id123456789
      case "$pkg" in id[0-9]*) : ;; *) pkg="" ;; esac ;;
  esac
  printf '%s' "$pkg"
}

# ===========================================================================
# 0. Arg + token preflight.
# ===========================================================================
CSV_PATH="${1:-}"
if [ -z "$CSV_PATH" ]; then
  echo "usage: citt-submit.sh <path-to-csv>" >&2
  exit 2
fi
if [ ! -r "$CSV_PATH" ]; then
  echo "citt-submit.sh: cannot read CSV: $CSV_PATH" >&2
  exit 2
fi

if ! _load_token; then
  _reauth_and_exit
fi
_build_curl_cfg

# ===========================================================================
# 1. Parse the FORGIVING CSV with a stdlib python reader (quoted fields, blank
#    lines, optional/absent columns, header detection). Emits one TAB-separated
#    record per data row: package_id \t store_url \t app_name \t platform \t
#    is_private \t scan_type  (missing cells empty). Header row is skipped when
#    detected. If python3 is unavailable, fall back to a naive comma split.
# ===========================================================================
# Fields are joined with the ASCII Unit Separator (0x1f), NOT a tab: a tab is
# IFS whitespace, so `read` would collapse leading empty fields (a name-only row
# would wrongly land in package_id). 0x1f is non-whitespace and never appears in
# CSV data, so leading/empty fields survive intact.
US=$'\x1f'
_parse_csv() {  # $1 = csv path  -> 0x1f-separated rows on stdout
  local path="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$path" <<'PY'
import sys, csv
KNOWN = {"package_id","store_url","app_name","platform","is_private","scan_type"}
path = sys.argv[1]
with open(path, newline='') as fh:
    rows = list(csv.reader(fh))
# Drop wholly-empty rows.
rows = [r for r in rows if any((c or '').strip() for c in r)]
if not rows:
    sys.exit(0)
# Header detection: if the first row's cells are all known column names.
header = None
first = [ (c or '').strip().lower() for c in rows[0] ]
if first and all(c in KNOWN for c in first if c):
    header = first
    data = rows[1:]
else:
    data = rows
def col(row, idx):
    return (row[idx].strip() if idx < len(row) and row[idx] is not None else '')
order = ["package_id","store_url","app_name","platform","is_private","scan_type"]
US = "\x1f"
for row in data:
    rec = {k: '' for k in order}
    if header:
        for i, name in enumerate(header):
            if name in rec:
                rec[name] = col(row, i)
    else:
        # Positional: fill in declared order.
        for i, name in enumerate(order):
            rec[name] = col(row, i)
    sys.stdout.write(US.join(rec[k] for k in order) + "\n")
PY
  else
    # Naive fallback: split on comma, strip quotes/space, skip a header line.
    local ln first=1
    while IFS= read -r ln || [ -n "$ln" ]; do
      [ -z "${ln//[[:space:]]/}" ] && continue
      local a b c d e f
      IFS=',' read -r a b c d e f <<<"$ln"
      a="${a//\"/}"; b="${b//\"/}"; c="${c//\"/}"; d="${d//\"/}"; e="${e//\"/}"; f="${f//\"/}"
      a="${a// /}"; d="${d// /}"; e="${e// /}"; f="${f// /}"
      if [ "$first" = "1" ] && { [ "$a" = "package_id" ] || [ "$b" = "store_url" ] || [ "$c" = "app_name" ]; }; then
        first=0; continue
      fi
      first=0
      printf '%s%s%s%s%s%s%s%s%s%s%s\n' "$a" "$US" "$b" "$US" "$c" "$US" "$d" "$US" "$e" "$US" "$f"
    done <"$path"
  fi
}

# ===========================================================================
# 2. Resolve rows into a work list. Parallel arrays keyed by index.
#    R_PKG   resolved package id (empty => unresolved)
#    R_PLATFORM  android|ios
#    R_PRIVATE   true|false
#    R_SCANTYPE  full|custom
#    R_LABEL     display label (package or the name/url the user gave)
#    R_STATE     one of: reuse | submitted | inflight | unresolved | failed | timeout
#    R_SCORE / R_BAND / R_WORSTCAT / R_NOTE  filled during summary build
# ===========================================================================
R_PKG=(); R_PLATFORM=(); R_PRIVATE=(); R_SCANTYPE=(); R_LABEL=()
R_STATE=(); R_SCORE=(); R_BAND=(); R_WORSTCAT=(); R_NOTE=(); R_PRIORTS=()

TIER_DENIED=0

_band_for_score() {  # $1 = score int  -> band label (mirrors scoreBands SoT)
  local s="$1"
  # Guard non-numeric / empty so a bad value can't abort under `set -e`.
  case "$s" in ''|*[!0-9]*) printf 'Unknown'; return ;; esac
  if [ "$s" -ge 90 ]; then printf 'Very Secure'
  elif [ "$s" -ge 80 ]; then printf 'Trustworthy'
  elif [ "$s" -ge 70 ]; then printf 'Solid'
  elif [ "$s" -ge 55 ]; then printf 'Use With Caution'
  elif [ "$s" -ge 35 ]; then printf 'Elevated Risk'
  else printf 'High Risk'; fi
}

# Pull worst category from a completed status body (RESP_FILE). Prefers the
# first top_security_issue title; else the highest-severity findings_by_category.
_worst_cat_from_resp() {
  local body; body="$(cat "$RESP_FILE" 2>/dev/null || true)"
  local t=""
  if command -v jq >/dev/null 2>&1; then
    t="$(printf '%s' "$body" | jq -er '(.top_security_issues[0] // .top_privacy_issues[0] // empty)' 2>/dev/null || true)"
    if [ -z "$t" ]; then
      t="$(printf '%s' "$body" | jq -er '
        ([.findings_by_category[]? | {c:.category, n:((.critical//0)*1000+(.high//0)*100+(.medium//0)*10+(.low//0))}]
         | sort_by(-.n) | .[0].c) // empty' 2>/dev/null || true)"
    fi
  fi
  printf '%s' "$t"
}

# ---------------------------------------------------------------------------
# Handle a non-2xx from an authenticated call. 401 => reauth+exit. 403 tier =>
# set TIER_DENIED + surface the scrubbed upgrade nudge. Other codes => generic.
# Prints nothing secret; only a parsed scalar. Returns 0 if the caller should
# treat the app as "not created" (skip), 1 to continue.
# ---------------------------------------------------------------------------
_handle_http_error() {  # $1 = code  $2 = context label
  local code="$1"
  local body; body="$(cat "$RESP_FILE" 2>/dev/null || true)"
  if [ "$code" = "401" ]; then
    _reauth_and_exit
  fi
  if [ "$code" = "403" ]; then
    # Tier gate. detail may be a nested object ({status, message, upgrade_url}).
    local msg=""
    if command -v jq >/dev/null 2>&1; then
      msg="$(printf '%s' "$body" | jq -er '(.detail.message // .detail // .message // empty)' 2>/dev/null || true)"
    fi
    [ -z "$msg" ] && msg="Batch submission needs the Developer (\$20/mo) or Research (\$299/mo) plan — upgrade at canitrustthat.com/pricing."
    printf '%s\n' "$msg" >&2
    TIER_DENIED=1
    return 0
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Poll a single package to completion within PER_APP_BUDGET, bounded backoff.
# Fills R_STATE/R_SCORE/R_BAND/R_WORSTCAT/R_NOTE for index $1. Never throws;
# a stuck/failed app is time-boxed so it cannot strand the batch.
# ---------------------------------------------------------------------------
_poll_index() {  # $1 = array index  $2 = package id
  local i="$1" pkg="$2" enc code start now sleep_s status_val
  enc="$(_urlenc "$pkg")"
  start="$(date +%s)"
  sleep_s="$POLL_BASE_SLEEP"
  while :; do
    now="$(date +%s)"
    if awk "BEGIN{exit !(($now - $start) >= $PER_APP_BUDGET)}"; then
      R_STATE[$i]="timeout"
      R_NOTE[$i]="still running (timed out waiting; check back later)"
      return 0
    fi
    code="$(_api_get "/api/status/${enc}")"
    if [ "$code" = "401" ]; then _reauth_and_exit; fi
    if [ "$code" != "200" ]; then
      # 404 mid-create or transient — keep within budget.
      sleep "$sleep_s"
      sleep_s="$(awk "BEGIN{s=$sleep_s*2; m=$POLL_MAX_SLEEP; print (s>m)?m:s}")"
      continue
    fi
    status_val="$(_json_get status "$(cat "$RESP_FILE")")"
    case "$status_val" in
      completed)
        R_STATE[$i]="done"
        R_SCORE[$i]="$(_json_get overall_score "$(cat "$RESP_FILE")")"
        R_BAND[$i]="$(_band_for_score "${R_SCORE[$i]}")"
        R_WORSTCAT[$i]="$(_worst_cat_from_resp)"
        return 0
        ;;
      failed)
        R_STATE[$i]="failed"
        R_NOTE[$i]="scan failed"
        return 0
        ;;
      *)
        sleep "$sleep_s"
        sleep_s="$(awk "BEGIN{s=$sleep_s*2; m=$POLL_MAX_SLEEP; print (s>m)?m:s}")"
        ;;
    esac
  done
}

# ===========================================================================
# 3-5. Resolve + dedup pre-check + submit, per row.
# ===========================================================================
idx=0
while IFS=$'\x1f' read -r c_pkg c_url c_name c_platform c_private c_scantype; do
  # Normalize optionals.
  platform="$c_platform"; [ -z "$platform" ] && platform="android"
  case "$platform" in android|ios) : ;; *) platform="android" ;; esac
  is_private="false"
  case "$(printf '%s' "$c_private" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes) is_private="true" ;;
  esac
  scan_type="full"; [ "$c_scantype" = "custom" ] && scan_type="custom"

  pkg="$c_pkg"
  label="$c_pkg"
  if [ -z "$pkg" ] && [ -n "$c_url" ]; then
    pkg="$(_pkg_from_store_url "$c_url")"
    label="$c_url"
  fi

  # Name-only row: resolve a candidate but NEVER auto-submit a guess.
  if [ -z "$pkg" ] && [ -n "$c_name" ]; then
    label="$c_name"
    enc_q="$(_urlenc "$c_name")"
    code="$(_api_get "/api/search-apps?q=${enc_q}&platform=${platform}")"
    if [ "$code" = "401" ]; then _reauth_and_exit; fi
    candidate=""
    if [ "$code" = "200" ] && command -v jq >/dev/null 2>&1; then
      candidate="$(jq -er '.results[0].package_id // empty' "$RESP_FILE" 2>/dev/null || true)"
    fi
    R_PKG[$idx]=""; R_PLATFORM[$idx]="$platform"; R_PRIVATE[$idx]="$is_private"
    R_SCANTYPE[$idx]="$scan_type"; R_LABEL[$idx]="$c_name"; R_STATE[$idx]="unresolved"
    if [ -n "$candidate" ]; then
      R_NOTE[$idx]="did you mean ${candidate}? confirm, then re-run with the package id"
    else
      R_NOTE[$idx]="no match found — provide a package id or store URL"
    fi
    idx=$((idx + 1))
    continue
  fi

  if [ -z "$pkg" ]; then
    R_PKG[$idx]=""; R_PLATFORM[$idx]="$platform"; R_PRIVATE[$idx]="$is_private"
    R_SCANTYPE[$idx]="$scan_type"; R_LABEL[$idx]="${label:-<empty row>}"
    R_STATE[$idx]="unresolved"; R_NOTE[$idx]="no package id / store URL / app name given"
    idx=$((idx + 1))
    continue
  fi

  R_PKG[$idx]="$pkg"; R_PLATFORM[$idx]="$platform"; R_PRIVATE[$idx]="$is_private"
  R_SCANTYPE[$idx]="$scan_type"; R_LABEL[$idx]="$pkg"
  R_STATE[$idx]="pending"; R_NOTE[$idx]=""; R_PRIORTS[$idx]=""

  # --- Dedup / cost pre-check: GET status first ---
  enc="$(_urlenc "$pkg")"
  code="$(_api_get "/api/status/${enc}")"
  if [ "$code" = "401" ]; then _reauth_and_exit; fi

  reuse=0
  if [ "$code" = "200" ]; then
    st="$(_json_get status "$(cat "$RESP_FILE")")"
    if [ "$st" = "completed" ]; then
      cts="$(_json_get completed_at "$(cat "$RESP_FILE")")"
      days="$(_days_since "$cts")"
      if [ -n "$days" ] && [ "$days" -lt "$FRESH_WINDOW_DAYS" ]; then
        # Fresh completed scan -> REUSE, do not re-submit / re-bill.
        reuse=1
        R_STATE[$idx]="reuse"
        R_SCORE[$idx]="$(_json_get overall_score "$(cat "$RESP_FILE")")"
        R_BAND[$idx]="$(_band_for_score "${R_SCORE[$idx]}")"
        R_WORSTCAT[$idx]="$(_worst_cat_from_resp)"
        R_NOTE[$idx]="reused existing scan (${days}d old)"
      else
        R_PRIORTS[$idx]="$(_json_get overall_score "$(cat "$RESP_FILE")")"  # prior score for delta
      fi
    elif [ "$st" = "queued" ] || [ "$st" = "analyzing" ]; then
      # Already in flight — do NOT submit again; just poll it.
      R_STATE[$idx]="inflight"
    fi
  fi

  if [ "$reuse" = "1" ] || [ "${R_STATE[$idx]}" = "inflight" ]; then
    idx=$((idx + 1))
    continue
  fi

  # --- Submit (metered). The status pre-check above is what makes a re-invoke
  #     idempotent client-side (there is no server Idempotency-Key). ---
  ( umask 077
    if command -v jq >/dev/null 2>&1; then
      jq -nc --arg p "$pkg" --arg pl "$platform" --argjson priv "$is_private" --arg st "$scan_type" \
        '{package_id:$p, platform:$pl, is_private:$priv, scan_type:$st}' >"$BODY_FILE"
    else
      printf '{"package_id":"%s","platform":"%s","is_private":%s,"scan_type":"%s"}' \
        "$pkg" "$platform" "$is_private" "$scan_type" >"$BODY_FILE"
    fi
  )
  code="$(_api_post "/api/submit" "$BODY_FILE")"
  if [ "$code" = "401" ]; then _reauth_and_exit; fi
  if [ "$code" = "403" ]; then
    _handle_http_error 403 "submit ${pkg}"
    if [ "$TIER_DENIED" = "1" ]; then
      # Tier gate is global for this account — stop the batch per PLAN §5.
      echo "Upgrade at canitrustthat.com/pricing to enable batch submission." >&2
      exit 3
    fi
  fi
  if [ "$code" != "200" ] && [ "$code" != "201" ] && [ "$code" != "202" ]; then
    R_STATE[$idx]="failed"
    R_NOTE[$idx]="submit failed (HTTP ${code})"
    idx=$((idx + 1))
    continue
  fi
  R_STATE[$idx]="inflight"
  idx=$((idx + 1))
done < <(_parse_csv "$CSV_PATH")

TOTAL=$idx

# ===========================================================================
# 6. Poll every in-flight scan to completion (time-boxed per app so one stuck
#    app cannot strand the rest).
# ===========================================================================
i=0
while [ "$i" -lt "$TOTAL" ]; do
  if [ "${R_STATE[$i]:-}" = "inflight" ]; then
    _poll_index "$i" "${R_PKG[$i]}"
  fi
  i=$((i + 1))
done

# ===========================================================================
# 7. Comparative summary (NON-SECRET only) to stdout.
# ===========================================================================
INCOMPLETE=0
printf '# CITT batch results\n\n'

# --- Ranked table (completed + reused, by score desc) ---
printf '## Ranked (%d apps)\n\n' "$TOTAL"
printf '%-40s  %5s  %-16s  %s\n' "app" "score" "band" "worst category"
printf '%-40s  %5s  %-16s  %s\n' "----------------------------------------" "-----" "----------------" "--------------"

# Build a sortable list: "<score>\t<index>" for done/reuse rows.
sortable=""
i=0
while [ "$i" -lt "$TOTAL" ]; do
  case "${R_STATE[$i]:-}" in
    done|reuse)
      s="${R_SCORE[$i]:-}"; [ -z "$s" ] && s=-1
      sortable="${sortable}${s}	${i}
"
      ;;
  esac
  i=$((i + 1))
done
if [ -n "$sortable" ]; then
  while IFS=$'\t' read -r sc i; do
    [ -z "${i:-}" ] && continue
    disp_score="${R_SCORE[$i]:-?}"; [ -z "$disp_score" ] && disp_score="?"
    wc="${R_WORSTCAT[$i]:-}"; [ -z "$wc" ] && wc="(none)"
    printf '%-40s  %5s  %-16s  %s\n' "${R_PKG[$i]}" "$disp_score" "${R_BAND[$i]:-Unknown}" "$wc"
  done < <(printf '%s' "$sortable" | sort -t'	' -k1,1nr)
else
  printf '(no completed scans yet)\n'
fi
printf '\n'

# --- Worst offenders (lowest scoring completed apps) ---
printf '## Worst offenders\n\n'
worst=""
i=0
while [ "$i" -lt "$TOTAL" ]; do
  case "${R_STATE[$i]:-}" in
    done|reuse)
      s="${R_SCORE[$i]:-}"
      case "$s" in ''|*[!0-9]*) s=999 ;; esac
      if [ "$s" -lt 70 ]; then
        worst="${worst}${s}	${i}
"
      fi
      ;;
  esac
  i=$((i + 1))
done
if [ -n "$worst" ]; then
  printf '%s' "$worst" | sort -t'	' -k1,1n | while IFS=$'\t' read -r sc i; do
    [ -z "${i:-}" ] && continue
    printf -- '- %s (%s, %s)\n' "${R_PKG[$i]}" "${R_SCORE[$i]:-?}" "${R_BAND[$i]:-Unknown}"
  done
else
  printf 'None below the caution threshold.\n'
fi
printf '\n'

# --- Clean bucket (>=80) ---
printf '## Clean (Trustworthy or better)\n\n'
clean_any=0
i=0
while [ "$i" -lt "$TOTAL" ]; do
  case "${R_STATE[$i]:-}" in
    done|reuse)
      s="${R_SCORE[$i]:-}"
      case "$s" in
        ''|*[!0-9]*) : ;;
        *) if [ "$s" -ge 80 ]; then printf -- '- %s (%s)\n' "${R_PKG[$i]}" "$s"; clean_any=1; fi ;;
      esac
      ;;
  esac
  i=$((i + 1))
done
[ "$clean_any" = "0" ] && printf 'None.\n'
printf '\n'

# --- In-progress / incomplete (partial summary marker) ---
partial_any=0
i=0
while [ "$i" -lt "$TOTAL" ]; do
  case "${R_STATE[$i]:-}" in
    timeout|inflight|failed) partial_any=1 ;;
  esac
  i=$((i + 1))
done
if [ "$partial_any" = "1" ]; then
  INCOMPLETE=1
  printf '## Incomplete (partial summary — some apps did not finish)\n\n'
  i=0
  while [ "$i" -lt "$TOTAL" ]; do
    case "${R_STATE[$i]:-}" in
      timeout)
        printf -- '- %s — still running / timed out (partial)\n' "${R_PKG[$i]}" ;;
      inflight)
        printf -- '- %s — still in progress (partial)\n' "${R_PKG[$i]}" ;;
      failed)
        printf -- '- %s — %s\n' "${R_PKG[$i]:-${R_LABEL[$i]}}" "${R_NOTE[$i]:-failed}" ;;
    esac
    i=$((i + 1))
  done
  printf '\n'
fi

# --- Unresolved / needs confirmation ---
unres_any=0
i=0
while [ "$i" -lt "$TOTAL" ]; do
  [ "${R_STATE[$i]:-}" = "unresolved" ] && unres_any=1
  i=$((i + 1))
done
if [ "$unres_any" = "1" ]; then
  printf '## Unresolved / needs confirmation\n\n'
  printf 'These rows were NOT submitted (a name match is only a guess — confirm before submitting):\n\n'
  i=0
  while [ "$i" -lt "$TOTAL" ]; do
    if [ "${R_STATE[$i]:-}" = "unresolved" ]; then
      printf -- '- "%s" — %s\n' "${R_LABEL[$i]}" "${R_NOTE[$i]:-needs a package id}"
    fi
    i=$((i + 1))
  done
  printf '\n'
fi

# --- Deep links ---
printf '## Reports\n\n'
i=0
while [ "$i" -lt "$TOTAL" ]; do
  if [ -n "${R_PKG[$i]:-}" ]; then
    printf -- '- %s: https://canitrustthat.com/apps/%s\n' "${R_PKG[$i]}" "${R_PKG[$i]}"
  fi
  i=$((i + 1))
done
printf '\n'

if [ "$INCOMPLETE" = "1" ]; then
  printf 'Note: this is a PARTIAL summary. Re-run citt-submit.sh with the same CSV to pick up apps that were still running (finished ones are reused, not re-billed).\n'
fi

exit 0
