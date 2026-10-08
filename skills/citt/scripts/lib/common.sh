#!/usr/bin/env bash
# lib/common.sh: token store, HTTP with retries, error mapping, tables and CSV.
# Token isolation: the token is never echoed, never on argv and never written to disk by a
# request. It is read into an unexported variable that is expanded only with xtrace off, and
# reaches curl as a --config read from a pipe (process substitution), so a SIGKILL leaves no copy.
# shellcheck shell=bash disable=SC2034

[ "${_CITT_COMMON_LOADED:-}" = "1" ] && return 0
_CITT_COMMON_LOADED=1

# Host pinning: CITT_API_OVERRIDE is honoured only with CITT_TEST_MODE=1. An overridden host never
# gets the production token: no keyring, and a token store other than ~/.config/citt.
CITT_HOST="https://canitrustthat.com"
CITT_OVERRIDDEN=0
if [ "${CITT_TEST_MODE:-}" = "1" ] && [ -n "${CITT_API_OVERRIDE:-}" ]; then
  CITT_HOST="${CITT_API_OVERRIDE%/}"
  CITT_OVERRIDDEN=1
  if [ -z "${CITT_TOKEN+x}" ] && { [ -z "${CITT_STATE_DIR:-}" ] || [ "${CITT_STATE_DIR%/}" = "$HOME/.config/citt" ]; }; then
    printf 'citt: CITT_API_OVERRIDE needs CITT_STATE_DIR set to a directory other than ~/.config/citt, the production token store\n' >&2
    exit 2
  fi
fi
CITT_V1="/api/research/v1"
# Where a refusal sends the user: the plans, and the dashboard host of the billing page.
CITT_PRICING_URL="https://canitrustthat.com/pricing"
CITT_APP_HOST="https://app.canitrustthat.com"

# Token store shared with the legacy citt plugin, byte for byte.
CITT_STATE="${CITT_STATE_DIR:-$HOME/.config/citt}"
CITT_TOKEN_FILE="${CITT_STATE}/device_token"
CITT_FLOW_FILE="${CITT_STATE}/device_flow"
CITT_KR_SERVICE="canitrustthat-citt"
CITT_KR_ACCOUNT="device_token"

# Set by the dispatcher.
CITT_CMD="${CITT_CMD:-citt}"
CITT_JSON=0

# Removes the temp directories of earlier runs that ended without their EXIT trap (SIGKILL):
# those whose recorded pid is gone, and pid-less ones older than an hour.
_citt_sweep() {
  local d p
  for d in "${TMPDIR:-/tmp}"/citt_c.*; do
    if [ ! -d "$d" ] || [ ! -O "$d" ]; then continue; fi
    p="$(cat "$d/pid" 2>/dev/null)"
    case "$p" in
      '' | *[!0-9]*) [ -n "$(find "$d" -maxdepth 0 -mmin +60 2>/dev/null)" ] || continue ;;
      *) ! kill -0 "$p" 2>/dev/null || continue ;;
    esac
    rm -rf "$d" 2>/dev/null || true
  done
}
_citt_sweep

_CITT_TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/citt_c.XXXXXX")" || {
  printf 'citt: cannot create a temporary directory\n' >&2
  exit 1
}
RESP="$_CITT_TMP/resp"
HDRS="$_CITT_TMP/hdrs"
_CITT_ERR="$_CITT_TMP/err"
( umask 077; printf '%s' "$$" >"$_CITT_TMP/pid"; : >"$RESP"; : >"$HDRS"; : >"$_CITT_ERR" )
_CITT_TOK=""

_citt_cleanup() { rm -rf "$_CITT_TMP" 2>/dev/null || true; }
trap _citt_cleanup EXIT

# tmpfile NAME: a 0600 path inside the private temp directory.
tmpfile() {
  ( umask 077; : >"$_CITT_TMP/$1" )
  printf '%s' "$_CITT_TMP/$1"
}

# clean: drops terminal control characters (all but tab and newline) from app and server text.
clean() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }

err() { printf '%s\n' "$*" | clean >&2; }

# die CODE MESSAGE: prints "citt <cmd>: MESSAGE" (and the --json error document) and exits.
die() {
  local code="$1"
  shift
  err "$CITT_CMD: $*"
  if [ "$CITT_JSON" = 1 ]; then
    jq -nc --arg m "$*" --argjson c "$code" '{error: "plugin_error", message: $m, http_status: null, exit: $c}'
  fi
  exit "$code"
}

usage_error() { die 2 "$*"; }

# --- tools -----------------------------------------------------------------

require_tools() {
  local t
  for t in curl jq; do
    command -v "$t" >/dev/null 2>&1 || {
      err "citt: $t is required (brew install $t, or apt install $t)"
      exit 1
    }
  done
}

require_unzip() {
  command -v unzip >/dev/null 2>&1 || {
    err "citt: unzip is required (brew install unzip, or apt install unzip)"
    exit 1
  }
}

# sha256_of FILE: the lowercase hex digest.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

file_bytes() { wc -c <"$1" | tr -d ' '; }

# --- keyring and token -----------------------------------------------------

_file_only() { [ "$CITT_OVERRIDDEN" = 1 ] || { [ "${CITT_TEST_MODE:-}" = "1" ] && [ "${CITT_FORCE_FILE_TOKEN:-}" = "1" ]; }; }

keyring_available() {
  _file_only && return 1
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then return 0; fi
  command -v secret-tool >/dev/null 2>&1
}

# keyring_to_file DEST: the keyring token into a 0600 file; non-zero when absent.
keyring_to_file() {
  keyring_available || return 1
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$CITT_KR_SERVICE" -a "$CITT_KR_ACCOUNT" -w 2>/dev/null \
      | tr -d '\n' >"$1"
  else
    secret-tool lookup service "$CITT_KR_SERVICE" account "$CITT_KR_ACCOUNT" 2>/dev/null \
      | tr -d '\n' >"$1"
  fi
  [ -s "$1" ]
}

keyring_has_token() {
  local t
  t="$(tmpfile kr_has)"
  keyring_to_file "$t"
  local rc=$?
  : >"$t"
  return $rc
}

keyring_delete() {
  keyring_available || return 0
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security delete-generic-password -s "$CITT_KR_SERVICE" -a "$CITT_KR_ACCOUNT" >/dev/null 2>&1 || true
  else
    secret-tool clear service "$CITT_KR_SERVICE" account "$CITT_KR_ACCOUNT" >/dev/null 2>&1 || true
  fi
}

# _tok_read: stdin's first line into _CITT_TOK; read is traced without the value.
_tok_read() {
  _CITT_TOK=""
  IFS= read -r _CITT_TOK || true
  [ -n "${_CITT_TOK:+x}" ]
}

# keyring_out: the keyring token on stdout, for a pipe into _tok_read.
keyring_out() {
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$CITT_KR_SERVICE" -a "$CITT_KR_ACCOUNT" -w 2>/dev/null
  else
    secret-tool lookup service "$CITT_KR_SERVICE" account "$CITT_KR_ACCOUNT" 2>/dev/null
  fi
}

# Token into _CITT_TOK. Order: CITT_TOKEN, keyring, file.
load_token() {
  # ${CITT_TOKEN+x}: a set-test, so xtrace shows only "x".
  if [ -n "${CITT_TOKEN+x}" ]; then
    _tok_read < <(tr -d '\r\n' <<<"${CITT_TOKEN}"; printf '\n') && return 0
  fi
  if keyring_available; then
    _tok_read < <(keyring_out | tr -d '\r\n'; printf '\n') && return 0
  fi
  if [ -s "$CITT_TOKEN_FILE" ]; then
    _tok_read < <(tr -d '\r\n' <"$CITT_TOKEN_FILE"; printf '\n') && return 0
  fi
  return 1
}

# _citt_cfg: the curl config with the Authorization header on stdout, printed with xtrace off.
_citt_cfg() {
  { _citt_x="$-"; set +x; } 2>/dev/null
  [ -z "${_CITT_TOK:+x}" ] || printf 'header = "Authorization: Bearer %s"\n' "$_CITT_TOK"
  case "$_citt_x" in *x*) set -x ;; esac
}

# need_auth: a token for this call, else the sign-in line and exit 3.
need_auth() {
  load_token || die 3 "not signed in or the token expired; run: citt auth"
}

# --- HTTP ------------------------------------------------------------------

# Request state, set by http.
CODE=""
NET_REASON=""
RETRIED=0
REQ_METHOD=""
REQ_PATH=""
# Set before http to change its behaviour for one call.
HTTP_AUTH=1
HTTP_RETRY=auto
HTTP_OUT=""
HTTP_RESUME=0
# Extra request headers, one per line.
HTTP_HEADERS=""
# The request body is HTTP_CHUNK_LEN bytes of HTTP_CHUNK from HTTP_CHUNK_OFF, from a pipe.
HTTP_CHUNK=""
HTTP_CHUNK_OFF=0
HTTP_CHUNK_LEN=0

# _chunk_bytes FILE OFFSET LENGTH: LENGTH bytes of FILE from OFFSET on stdout.
_chunk_bytes() {
  tail -c +"$(($2 + 1))" "$1" 2>/dev/null | head -c "$3"
  return 0
}

# hdr NAME: the last value of response header NAME, empty when absent.
hdr() {
  tr -d '\r' <"$HDRS" | awk -v n="$1" '
    { i = index($0, ":") }
    i > 0 && tolower(substr($0, 1, i - 1)) == tolower(n) { v = substr($0, i + 1); sub(/^ */, "", v); last = v }
    END { if (last != "") print last }'
}

_retry_delay() {
  local attempt="$1" ra
  if [ "${CITT_TEST_MODE:-}" = "1" ]; then
    printf '0'
    return
  fi
  ra="$(tr -d '\r' <"$HDRS" | awk -F': *' 'tolower($1) == "retry-after" { print $2 }' | tail -n1)"
  case "$ra" in '' | *[!0-9]*) ;; *)
    printf '%s' "$ra"
    return
    ;;
  esac
  case "$attempt" in 1) printf '1' ;; 2) printf '2' ;; *) printf '4' ;; esac
}

# http METHOD PATH [BODY_FILE]: the response body goes to $RESP (or $HTTP_OUT), the status to
# $CODE ("000" when there was no response, with $NET_REASON). GETs and, with HTTP_RETRY=yes,
# POSTs are retried 3 times on 5xx and network failures. HEAD is sent with -I.
http() {
  local method="$1" path="$2" body="${3:-}" out retry attempt=0 rc url h chunk="$HTTP_CHUNK"
  REQ_METHOD="$method"
  REQ_PATH="${path%%\?*}"
  out="${HTTP_OUT:-$RESP}"
  retry="$HTTP_RETRY"
  if [ "$retry" = auto ]; then
    if [ "$method" = GET ]; then retry=yes; else retry=no; fi
  fi
  case "$path" in http://* | https://*) url="$path" ;; *) url="$CITT_HOST$path" ;; esac
  local -a args
  args=(-sS -g -o "$out" -D "$HDRS" -w '%{http_code}' --connect-timeout 20)
  if [ "$method" = HEAD ]; then args+=(-I); else args+=(-X "$method"); fi
  if [ -n "$HTTP_HEADERS" ]; then
    while IFS= read -r h; do
      [ -z "$h" ] || args+=(-H "$h")
    done <<EOF
$HTTP_HEADERS
EOF
  fi
  if [ -n "$body" ]; then args+=(-H 'Content-Type: application/json' --data-binary "@$body"); fi
  if [ -n "$chunk" ]; then
    args+=(-H 'Content-Type: application/offset+octet-stream' -H 'Expect:' --data-binary @- --max-time 900)
  elif [ "$HTTP_RESUME" = 1 ]; then
    args+=(-C -)
  else
    args+=(--max-time 300)
  fi
  while :; do
    attempt=$((attempt + 1))
    : >"$HDRS"
    [ "$HTTP_RESUME" = 1 ] || : >"$out"
    if [ "$HTTP_AUTH" != 1 ]; then
      CODE="$(curl -q "${args[@]}" "$url" 2>"$_CITT_ERR" </dev/null)"
    elif [ -n "$chunk" ]; then
      CODE="$(_chunk_bytes "$chunk" "$HTTP_CHUNK_OFF" "$HTTP_CHUNK_LEN" | curl -q --config <(_citt_cfg) "${args[@]}" "$url" 2>"$_CITT_ERR")"
    else
      CODE="$(curl -q --config <(_citt_cfg) "${args[@]}" "$url" 2>"$_CITT_ERR" </dev/null)"
    fi
    rc=$?
    [ -n "$CODE" ] || CODE=000
    if [ "$rc" -ne 0 ] && [ "$CODE" = 000 ]; then
      NET_REASON="$(sed -e 's/^curl: ([0-9]*) //' "$_CITT_ERR" | head -n1)"
      [ -n "$NET_REASON" ] || NET_REASON="curl exit $rc"
    elif [ "$rc" -ne 0 ] && [ "$HTTP_RESUME" != 1 ]; then
      CODE=000
      NET_REASON="$(sed -e 's/^curl: ([0-9]*) //' "$_CITT_ERR" | head -n1)"
    fi
    if [ "$retry" = yes ] && [ "$attempt" -lt 4 ]; then
      case "$CODE" in 000 | 5??)
        sleep "$(_retry_delay "$attempt")"
        continue
        ;;
      esac
    fi
    break
  done
  RETRIED=$((attempt - 1))
  HTTP_AUTH=1
  HTTP_RETRY=auto
  HTTP_OUT=""
  HTTP_RESUME=0
  HTTP_HEADERS=""
  HTTP_CHUNK=""
}

ok() { case "$CODE" in 2??) return 0 ;; esac; return 1; }

# body_field FILTER: a jq filter over the response body, raw, empty on failure.
body_field() { jq -r "$1 // empty" "$RESP" 2>/dev/null || true; }

# Context for error messages, set by commands before a call.
E_KIND=project
E_PROJECT_ID=""
E_PROJECT_LABEL=""
E_PROJECT_REF=""
E_PACKAGE=""
E_FINDING=""
E_EXPORT=""
E_EMAIL=""
E_THREAD=""

_retried_suffix() { [ "$RETRIED" -gt 0 ] && printf '; retried %s times' "$RETRIED"; }

# The fixed line for 403 `not_entitled` (SECURITY.md ENT-6). One body on every route, so it also
# covers a shared project whose first owner lost the entitlement (DESIGN-37 D61).
CITT_NOT_ENTITLED_LINE="this needs a Researcher, Deep Researcher or Custom plan (in a shared project, its first owner's plan); on Pay as you go, scan one Android app with citt submit PACKAGE and ask about it with citt prompt; plans: $CITT_PRICING_URL"
# `not_entitled` on a free submit (no project): what a free submit may hold.
CITT_FREE_SUBMIT_LINE="a Pay as you go account scans one Android app per submit with the rule scan; several apps, a deep scan or a prompt need a Researcher, Deep Researcher or Custom plan: $CITT_PRICING_URL"

# _plan_name ID: the plan's name on the pricing page.
_plan_name() {
  case "$1" in
    research) printf 'Researcher' ;;
    deep-research) printf 'Deep Researcher' ;;
    custom) printf 'Custom' ;;
    developer) printf 'Developer' ;;
    free | "") printf 'Pay as you go' ;;
    *) printf '%s' "$1" ;;
  esac
}

# _limit_line: the 429 `usage_limit_exceeded` line from its period, counts, reset and plan.
_limit_line() {
  local period resets plan line
  period="$(body_field '.period')"
  case "$period" in
    day) period=daily ;;
    month | "") period=monthly ;;
  esac
  line="$period limit reached for $(body_field '.action'): $(body_field '.used') of $(body_field '.limit') used, this request needs $(body_field '.requested')"
  resets="$(body_field '.resets_at')"
  [ -z "$resets" ] || line="$line; resets $resets"
  plan="$(body_field '.upgrade_plan')"
  [ -z "$plan" ] || line="$line; the $(_plan_name "$plan") plan raises it: $CITT_PRICING_URL"
  printf '%s; see: citt usage' "$line"
}

# _balance_line: the 402 `insufficient_balance` line with the top-up link on the dashboard host.
_balance_line() {
  local url
  url="$(body_field '.topup_url')"
  case "$url" in
    //*) url="$CITT_APP_HOST/settings/billing" ;;
    /*) url="$CITT_APP_HOST$url" ;;
    "$CITT_APP_HOST"/*) ;;
    *) url="$CITT_APP_HOST/settings/billing" ;;
  esac
  printf '%s; top up: %s; see: citt usage' "$(body_field '.message')" "$url"
}

# fail_http: the stderr line and exit code for a failed request (DESIGN-11 "HTTP error handling").
fail_http() {
  local error message msg code
  error="$(body_field '.error')"
  message="$(body_field '.message')"
  case "$CODE" in
    000)
      msg="cannot reach $CITT_HOST ($NET_REASON)$(_retried_suffix)"
      code=9
      ;;
    400)
      if [ "$error" = csv_invalid ]; then
        msg="CSV rejected: $message; the file needs a package_id, play_store_url or app_store_url column (Google Play and Apple App Store headers are accepted)"
      else
        local unknown
        unknown="$(body_field '(.unknown_apps // []) | join(", ") | select(. != "")')"
        msg="request rejected: ${message:-$error}${unknown:+: $unknown}"
      fi
      code=7
      ;;
    401)
      msg="not signed in or the token expired; run: citt auth"
      code=3
      ;;
    402)
      msg="$(_balance_line)"
      code=6
      ;;
    403)
      if [ "$error" = not_entitled ] && [ "$E_KIND" = free_submit ]; then
        msg="$CITT_FREE_SUBMIT_LINE"
      elif [ "$error" = not_entitled ]; then
        msg="$CITT_NOT_ENTITLED_LINE"
      else
        msg="${message:-$error}"
        [ -z "$(body_field '.upgrade_plan')" ] || msg="$msg; plans: $CITT_PRICING_URL"
      fi
      code=3
      ;;
    404 | 405)
      if [ -z "$error" ]; then
        msg="this server does not provide $REQ_METHOD $REQ_PATH yet"
        code=10
      else
        case "$E_KIND" in
          app) msg="$E_PACKAGE is not in project \"$E_PROJECT_LABEL\"" ;;
          finding) msg="finding $E_FINDING not found in your projects" ;;
          export) msg="export $E_EXPORT not found" ;;
          owner) msg="$E_EMAIL is not an owner of project \"$E_PROJECT_LABEL\"" ;;
          thread) msg="thread $E_THREAD not found among your prompt threads" ;;
          upload) msg="the upload or project of this target is not among yours" ;;
          *) msg="project $E_PROJECT_ID not found, or you are not an owner" ;;
        esac
        code=4
      fi
      ;;
    409)
      case "$error" in
        ambiguous_project)
          local ids
          ids="$(body_field '(.project_ids // []) | map(tostring) | join(", ")')"
          if [ -n "$E_PROJECT_LABEL" ]; then
            msg="several projects named \"$E_PROJECT_LABEL\": ids $ids; re-run with --project-id"
          else
            msg="several projects named differently hold these findings: ids $ids; re-run with --project-id"
          fi
          ;;
        last_owner)
          msg="$E_EMAIL is the only owner of \"$E_PROJECT_LABEL\" and cannot be removed; add another owner first"
          ;;
        not_ready)
          msg="$E_PACKAGE has no finished scan yet (status: $(body_field '.app_status')); run: citt status${E_PROJECT_REF:+ $E_PROJECT_REF} --wait"
          ;;
        *) msg="conflict: ${message:-$error}" ;;
      esac
      code=5
      ;;
    422)
      msg="$(body_field '.action // "this action"') is not available in v1"
      code=7
      ;;
    429)
      msg="$(_limit_line)"
      code=6
      ;;
    502)
      if [ "$error" = legacy_unavailable ]; then
        msg="the sign-in service is unavailable (502); try again shortly$(_retried_suffix)"
      else
        msg="server error 502${error:+ $error}$(_retried_suffix)"
      fi
      code=8
      ;;
    5??)
      msg="server error $CODE${error:+ $error}$(_retried_suffix)"
      code=8
      ;;
    *)
      msg="unexpected HTTP $CODE from $REQ_METHOD $REQ_PATH"
      code=1
      ;;
  esac
  fail_out "$code" "$msg"
}

# fail_out CODE MESSAGE: the stderr line and, with --json, the response body (or a built error
# document) with http_status, then exit CODE.
fail_out() {
  local code="$1" msg="$2"
  err "$CITT_CMD: $msg"
  if [ "$CITT_JSON" = 1 ]; then
    if jq -e 'type == "object"' "$RESP" >/dev/null 2>&1; then
      jq -c --argjson s "${CODE#0}" --arg m "$msg" \
        '. + {http_status: (if $s == 0 then null else $s end)} | .message = (.message // $m) | .error = (.error // "http_error")' "$RESP"
    else
      jq -nc --arg m "$msg" --arg c "$CODE" \
        '{error: (if $c == "000" then "network" else "http_error" end), message: $m,
          http_status: (if $c == "000" then null else ($c | tonumber) end)}'
    fi
  fi
  exit "$code"
}

# call METHOD PATH [BODY_FILE]: http, then fail_http unless 2xx.
call() {
  http "$@"
  ok || fail_http
}

# urlenc STRING: percent-encoded for a path segment or query value.
urlenc() { jq -rn --arg s "$1" '$s | @uri'; }

# query K V [K V...]: "?k=v&..." for the non-empty values.
query() {
  local q="" k v
  while [ $# -ge 2 ]; do
    k="$1"
    v="$2"
    shift 2
    [ -n "$v" ] || continue
    q="$q${q:+&}$k=$(urlenc "$v")"
  done
  [ -n "$q" ] && printf '?%s' "$q"
}

# --- arguments -------------------------------------------------------------

# need_value FLAG COUNT: a flag's value is present.
need_value() { [ "$2" -ge 2 ] || usage_error "$1 needs a value"; }

is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; return 0; }

# shq WORD: WORD as a shell word for a printed command.
shq() {
  case "$1" in
    '' | *[!A-Za-z0-9._/:@,+=%-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- project resolution ----------------------------------------------------

OPT_PROJECT=""
OPT_PROJECT_ID=""
PROJECT_ID=""
PROJECT_NAME=""

# take_project_flag ARGS...: consumes --project/--project-id; returns the number of words used
# (0 when the first word is neither).
take_project_flag() {
  case "$1" in
    --project)
      need_value "$1" $#
      OPT_PROJECT="$2"
      return 2
      ;;
    --project=*)
      OPT_PROJECT="${1#--project=}"
      return 1
      ;;
    --project-id)
      need_value "$1" $#
      OPT_PROJECT_ID="$2"
      return 2
      ;;
    --project-id=*)
      OPT_PROJECT_ID="${1#--project-id=}"
      return 1
      ;;
  esac
  return 0
}

# check_project_flags [optional]: exactly one of --project and --project-id.
check_project_flags() {
  if [ -n "$OPT_PROJECT" ] && [ -n "$OPT_PROJECT_ID" ]; then
    usage_error "use --project NAME or --project-id N, not both"
  fi
  if [ -z "$OPT_PROJECT" ] && [ -z "$OPT_PROJECT_ID" ] && [ "${1:-}" != optional ]; then
    usage_error "give --project NAME or --project-id N"
  fi
  if [ -n "$OPT_PROJECT_ID" ] && ! is_uint "$OPT_PROJECT_ID"; then
    usage_error "--project-id needs a number, got: $OPT_PROJECT_ID"
  fi
}

# The flag as the user gave it, for printed commands; empty for the free project (D217).
project_ref() {
  if [ "${FREE_PROJECT:-0}" = 1 ]; then
    return 0
  elif [ -n "$OPT_PROJECT_ID" ]; then
    printf -- '--project-id %s' "$OPT_PROJECT_ID"
  else
    printf -- '--project %s' "$(shq "$OPT_PROJECT")"
  fi
}

# project_arg: " <project_ref>", or empty for the free project; for printed commands.
project_arg() {
  local r
  r="$(project_ref)"
  [ -z "$r" ] || printf ' %s' "$r"
}

# free_account: GET /me; true for an account without `research`, whose FREE_PROJECT_ID is set
# (empty before its first free scan). An account with `research` gets the usage error.
free_account() {
  call GET "$CITT_V1/me"
  if jq -e '(.entitlements // []) | index("research")' "$RESP" >/dev/null 2>&1; then
    usage_error "give --project NAME or --project-id N"
  fi
  FREE_PROJECT_ID="$(jq -r '.free_scans_project_id // empty' "$RESP" 2>/dev/null)" \
    || die 1 "unparseable response from GET $CITT_V1/me"
}

# resolve_project: sets PROJECT_ID and PROJECT_NAME (empty with --project-id). Without a flag,
# the free project of an account without `research` (D217).
resolve_project() {
  if [ -z "$OPT_PROJECT" ] && [ -z "$OPT_PROJECT_ID" ]; then
    free_account
    [ -n "$FREE_PROJECT_ID" ] || die 4 "no free scans yet; start one: citt submit PACKAGE"
    FREE_PROJECT=1
    PROJECT_ID="$FREE_PROJECT_ID"
    PROJECT_NAME="Free scans"
    E_PROJECT_REF=""
    E_PROJECT_ID="$PROJECT_ID"
    E_PROJECT_LABEL="$PROJECT_NAME"
    return 0
  fi
  E_PROJECT_REF="$(project_ref)"
  if [ -n "$OPT_PROJECT_ID" ]; then
    PROJECT_ID="$OPT_PROJECT_ID"
    PROJECT_NAME=""
  else
    local ids n
    call GET "$CITT_V1/projects"
    ids="$(jq -r --arg n "$OPT_PROJECT" '[.projects[] | select(.name == $n) | .project_id] | sort | map(tostring) | join(", ")' "$RESP")" \
      || die 1 "unparseable response from GET $CITT_V1/projects"
    n="$(printf '%s' "$ids" | awk -F', ' 'NF { print NF }')"
    case "${n:-0}" in
      0) die 4 "no project named \"$OPT_PROJECT\" among your projects" ;;
      1) ;;
      *) die 5 "several projects named \"$OPT_PROJECT\": ids $ids; re-run with --project-id" ;;
    esac
    PROJECT_ID="$ids"
    PROJECT_NAME="$OPT_PROJECT"
  fi
  E_PROJECT_ID="$PROJECT_ID"
  E_PROJECT_LABEL="${PROJECT_NAME:-$PROJECT_ID}"
}

# --- polling ---------------------------------------------------------------

# poll_sleep SECONDS: the response's poll_after_seconds (or 15); CITT_POLL_INTERVAL in test mode.
poll_sleep() {
  local s="${1:-}"
  if [ "${CITT_TEST_MODE:-}" = "1" ] && [ -n "${CITT_POLL_INTERVAL:-}" ]; then
    s="$CITT_POLL_INTERVAL"
  fi
  is_uint "$s" || s=15
  [ "$s" -gt 0 ] && sleep "$s"
  return 0
}

now_s() { date +%s; }

# --- output ----------------------------------------------------------------

# table: a JSON array of rows (arrays, header first) on stdin to aligned text, columns padded to
# the widest cell plus 2 characters, the last column unpadded. Widths count characters.
table() {
  jq -r '
    def pad($w): . + ([range(0; $w - length)] | map(" ") | join(""));
    map(map(if . == null then "-" else tostring end)) as $r
    | ($r[0] | length) as $n
    | [range(0; $n) as $i | ($r | map(.[$i] | length) | max)] as $w
    | $r[] | . as $row | [range(0; $n) as $i | ($row[$i] // "") | if $i == $n - 1 then . else pad($w[$i] + 2) end]
    | join("") | sub(" +$"; "")'
}

# CSV cell and row helpers for jq (RFC 4180: quote only when needed).
JQ_CSV='def cell: if . == null then "" elif type == "string" and test("^[=+@-]") then "'"'"'" + . else tostring end
  | if test("[,\"\r\n]") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
  def csvrow: map(cell) | join(",");'
