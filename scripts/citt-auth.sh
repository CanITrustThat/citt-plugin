#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# citt-auth.sh — CITT device-flow authentication client  (CITT-267)
# =============================================================================
# RFC-8628 long-link device-flow client. Runs inside Claude Code's Bash tool as
# part of the published CITT plugin, so the access token must NEVER enter model
# context (stdout / argv / xtrace).
#
# Behavior (PLAN §2, CITT-265 spike):
#   1. CITT_TOKEN env set  -> already authenticated (override); print
#      "authenticated", exit 0. The value is NEVER echoed.
#   2. Valid token already in TOKEN_FILE -> print "authenticated", exit 0. No
#      network call. (Opaque token; local presence == authenticated. The submit
#      script re-invokes us on a server 401/expiry.)
#   3. Else POST /api/device/code, parse device_code + verification_uri_complete
#      + interval + expires_in. Print ONLY the link. Background-poll
#      /api/device/token honoring authorization_pending / slow_down, bounded to
#      ~10 min / expires_in. On access_denied(tier) print the scrubbed upgrade
#      nudge + exit non-zero. On success STORE the token (keyring-first, else a
#      0600 file) and print ONLY "authenticated". On timeout print a re-run hint
#      to STDERR + exit non-zero (Claude re-invokes; no interactive TTY).
#
# SECRET ISOLATION (hard invariants — red-team tested in CITT-270):
#   - This device-flow client is UNAUTHENTICATED (no Authorization header on any
#     call), so the token is never on the request side at all. The minted
#     access_token arrives ONLY in the /api/device/token 200 body; we extract the
#     single `access_token` scalar with jq straight into a 0600 temp file and
#     move/keyring it into place. It is NEVER echoed, NEVER placed on argv, and —
#     proven by running the whole script under `bash -x` in the harness — never
#     appears on an xtrace line. (There is no `set -x` in this script.)
#   - The pending device_code is passed to curl via a 0600 --data @file, not on
#     argv, so it never shows in `ps`.
#   - Host is HARDCODED (egress allow-list). A test-only seam (CITT_API_OVERRIDE,
#     honored ONLY when CITT_TEST_MODE=1) lets the harness point at a mock; the
#     production path stays hardcoded.
#   - curl error bodies are captured to a var and only the parsed `error`/`message`
#     scalar is surfaced — a non-2xx can never reflect raw headers/body to stdout.
# =============================================================================

# API base (hardcoded egress allow-list — do NOT make this configurable).
CITT_API="https://canitrustthat.com"

# TEST-ONLY seam: point the client at a mock server. This is NOT a general
# config knob — it is honored ONLY when CITT_TEST_MODE=1 (set by the harness).
# The production path above stays hardcoded.
if [ "${CITT_TEST_MODE:-}" = "1" ] && [ -n "${CITT_API_OVERRIDE:-}" ]; then
  CITT_API="${CITT_API_OVERRIDE}"
fi

# Local token file the helper scripts own. Written at chmod 0600 and read back
# by the scripts in-process; NEVER echoed or passed as argv.
TOKEN_FILE="${CLAUDE_PLUGIN_DATA:-$HOME/.config/citt}/device_token"

# macOS keyring coordinates (Linux uses secret-tool with matching attributes).
KEYRING_SERVICE="canitrustthat-citt"
KEYRING_ACCOUNT="device_token"

POLL_CEILING_SECONDS=600   # ~10 min hard bound regardless of expires_in

# ---------------------------------------------------------------------------
# JSON scalar extraction. Prefer jq; fall back to a tight grep/sed that pulls
# ONLY the one requested scalar (string or number) — never dumps the body.
# Usage: _json_get <field> <body>
# ---------------------------------------------------------------------------
_json_get() {
  local field="$1" body="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -er --arg k "$field" '.[$k] // empty' 2>/dev/null || true
    return 0
  fi
  # String value:  "field":"value"
  local v
  v="$(printf '%s' "$body" \
    | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n1 \
    | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/")"
  if [ -n "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  # Numeric value: "field":123
  printf '%s' "$body" \
    | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*[0-9]\+" \
    | head -n1 \
    | sed -E "s/.*:[[:space:]]*([0-9]+)/\1/"
}

# ---------------------------------------------------------------------------
# Keyring helpers. Return non-zero if no keyring backend is available so callers
# fall back to the 0600 file. The token value is fed to `security`/`secret-tool`
# via STDIN, never on argv: `security add-generic-password ... -w` (with -w as the
# trailing, value-less option) reads the secret from stdin, and `secret-tool store`
# reads from stdin. So the token never appears in `ps`.
# ---------------------------------------------------------------------------
_keyring_available() {
  # TEST-ONLY: force the 0600 file fallback so the harness can assert file mode
  # without touching the real OS keychain. Honored ONLY under CITT_TEST_MODE=1.
  if [ "${CITT_TEST_MODE:-}" = "1" ] && [ "${CITT_FORCE_FILE_TOKEN:-}" = "1" ]; then
    return 1
  fi
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    return 0
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Store token read from a 0600 file at $1 into the OS keyring. The token is fed
# via STDIN (never on argv), so it never appears in `ps` or under xtrace.
_keyring_store_from_file() {
  local src="$1"
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    # -U updates if present. -w given LAST with no value makes `security` read the
    # password from stdin — the token is piped in from the 0600 file, never argv.
    security add-generic-password -U \
      -s "$KEYRING_SERVICE" -a "$KEYRING_ACCOUNT" \
      -w <"$src" >/dev/null 2>&1
    return $?
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    secret-tool store --label="CITT device token" \
      service "$KEYRING_SERVICE" account "$KEYRING_ACCOUNT" <"$src" >/dev/null 2>&1
    return $?
  fi
  return 1
}

# True (0) if a token is present in the keyring.
_keyring_has_token() {
  # TEST-ONLY: honor the forced-file mode so the harness's file-only fixtures are
  # authoritative and don't collide with a real keychain entry.
  if [ "${CITT_TEST_MODE:-}" = "1" ] && [ "${CITT_FORCE_FILE_TOKEN:-}" = "1" ]; then
    return 1
  fi
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$KEYRING_SERVICE" -a "$KEYRING_ACCOUNT" \
      >/dev/null 2>&1
    return $?
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    secret-tool lookup service "$KEYRING_SERVICE" account "$KEYRING_ACCOUNT" \
      >/dev/null 2>&1
    return $?
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Do we already have a usable token? (No network — local presence only.)
# ---------------------------------------------------------------------------
_have_token() {
  if _keyring_has_token; then
    return 0
  fi
  if [ -s "$TOKEN_FILE" ]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Persist the freshly-minted token. Input: path to a 0600 temp file that already
# holds ONLY the raw token string. Keyring-first, else atomically move into the
# 0600 TOKEN_FILE. The token is never echoed on the way through.
# ---------------------------------------------------------------------------
_store_token_file() {
  local src="$1"
  if _keyring_available && _keyring_store_from_file "$src"; then
    return 0
  fi
  # File fallback: 0600 from birth (umask) and re-asserted with chmod.
  mkdir -p "$(dirname "$TOKEN_FILE")"
  chmod 700 "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
  ( umask 077; cat "$src" >"$TOKEN_FILE" )
  chmod 600 "$TOKEN_FILE"
}

# ===========================================================================
# 1. CITT_TOKEN override — treat as authenticated, never echo the value.
# Use ${CITT_TOKEN+x} (set-test, not value-expansion) so bash -x traces
# only the literal "x", never the token value.  (CITT-347 Finding 1)
# ===========================================================================
if [ -n "${CITT_TOKEN+x}" ]; then
  echo "authenticated"
  exit 0
fi

# ===========================================================================
# 2. Already-authenticated short-circuit — no network call.
# ===========================================================================
if _have_token; then
  echo "authenticated"
  exit 0
fi

# ===========================================================================
# 3. Start the device flow: request a device_code + verification link.
# ===========================================================================
DEVICE_JSON="$(
  curl -sS -X POST "${CITT_API}/api/device/code" \
    -H 'Content-Type: application/json' \
    -d '{"client":"claude-plugin"}' 2>/dev/null
)" || {
  echo "citt-auth.sh: could not reach the CITT device endpoint." >&2
  exit 1
}

DEVICE_CODE="$(_json_get device_code "$DEVICE_JSON")"
VERIFY_URI="$(_json_get verification_uri_complete "$DEVICE_JSON")"
INTERVAL="$(_json_get interval "$DEVICE_JSON")"
EXPIRES_IN="$(_json_get expires_in "$DEVICE_JSON")"

if [ -z "$DEVICE_CODE" ] || [ -z "$VERIFY_URI" ]; then
  echo "citt-auth.sh: unexpected response from the device endpoint." >&2
  exit 1
fi

# Sane numeric defaults if the server omitted them.
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac
case "$EXPIRES_IN" in ''|*[!0-9]*) EXPIRES_IN=900 ;; esac

# Store the pending-flow device_code transiently in a 0600 temp (off argv/stdout
# beyond the link). It is not the final secret but still kept out of argv.
DC_FILE="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_dc.XXXXXX")"
# Body files for curl (token-token request payload + curl config) also 0600.
BODY_FILE="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_body.XXXXXX")"
RESP_FILE="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_resp.XXXXXX")"
TOKEN_TMP="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_tok.XXXXXX")"
cleanup() { rm -f "$DC_FILE" "$BODY_FILE" "$RESP_FILE" "$TOKEN_TMP" 2>/dev/null || true; }
trap cleanup EXIT

printf '%s' "$DEVICE_CODE" >"$DC_FILE"

# The device_code is a pending identifier, not the final secret, but still keep
# it off argv: build the poll request body in a 0600 file via jq (or a safe
# here-doc-free printf that quotes it) rather than on the command line.
_write_poll_body() {
  if command -v jq >/dev/null 2>&1; then
    jq -nc --rawfile dc "$DC_FILE" \
      '{grant_type:"device_code", device_code:($dc|rtrimstr("\n"))}' >"$BODY_FILE"
  else
    # No-jq fallback: assemble JSON via printf (static parts) + cat (device_code
    # bytes from 0600 file) — no command-substitution of the value, so bash -x
    # never traces it on a printf arg. (CITT-347 Finding 3)
    { printf '{"grant_type":"device_code","device_code":"'
      cat "$DC_FILE"
      printf '"}'; } >"$BODY_FILE"
  fi
}
_write_poll_body

# 4. Print ONLY the verification link (the single thing the user opens).
printf '%s\n' "$VERIFY_URI"

# ===========================================================================
# 5. Background-poll /api/device/token.
# ===========================================================================
# Bound polling by the smaller of expires_in and the 10-min ceiling.
DEADLINE_BUDGET="$EXPIRES_IN"
if [ "$DEADLINE_BUDGET" -gt "$POLL_CEILING_SECONDS" ]; then
  DEADLINE_BUDGET="$POLL_CEILING_SECONDS"
fi
START="$(date +%s)"

while :; do
  NOW="$(date +%s)"
  if [ "$((NOW - START))" -ge "$DEADLINE_BUDGET" ]; then
    echo "still waiting for authorization — open the link, then run this again." >&2
    exit 2
  fi

  # POST the poll. Capture body to a file; read HTTP code separately. --data
  # comes from the 0600 body file so the device_code is not on argv.
  HTTP_CODE="$(
    curl -sS -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "${CITT_API}/api/device/token" \
      -H 'Content-Type: application/json' \
      --data "@${BODY_FILE}" 2>/dev/null || true
  )"

  if [ "$HTTP_CODE" = "200" ]; then
    # Success. Extract ONLY the access_token scalar by reading STRAIGHT from the
    # 0600 response file into the 0600 temp — file->file. The token is NEVER read
    # into a shell variable (no $BODY here), so it can never be echoed or appear
    # on a `bash -x` xtrace line. (QA-270 Finding A / CITT-272.)
    if command -v jq >/dev/null 2>&1; then
      jq -er '.access_token' <"$RESP_FILE" >"$TOKEN_TMP" 2>/dev/null || true
    else
      grep -o '"access_token"[[:space:]]*:[[:space:]]*"[^"]*"' <"$RESP_FILE" \
        | head -n1 \
        | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' \
        | tr -d '\n' >"$TOKEN_TMP"
    fi
    if [ ! -s "$TOKEN_TMP" ]; then
      echo "citt-auth.sh: authorization succeeded but no token was returned." >&2
      exit 1
    fi
    _store_token_file "$TOKEN_TMP"
    echo "authenticated"
    exit 0
  fi

  # Non-200: error bodies never contain the token, so it is safe to read the body
  # into a var here (and ONLY here). Parse ONLY the `error` scalar; never surface
  # raw headers/body.
  BODY="$(cat "$RESP_FILE" 2>/dev/null || true)"
  ERR="$(_json_get error "$BODY")"
  case "$ERR" in
    authorization_pending)
      : # keep polling
      ;;
    slow_down)
      INTERVAL="$((INTERVAL + 5))"   # RFC 8628 §3.5 back-off
      ;;
    access_denied)
      # Wrong tier (or hard deny). Surface the scrubbed upgrade nudge only.
      MSG="$(_json_get message "$BODY")"
      if [ -n "$MSG" ]; then
        printf '%s\n' "$MSG" >&2
      else
        echo "access denied for this plan — see canitrustthat.com/pricing" >&2
      fi
      exit 3
      ;;
    expired_token)
      echo "the link expired — run this again to restart authorization." >&2
      exit 4
      ;;
    *)
      # Unknown/unmapped state: generic message only, no body leakage.
      : # treat like pending and keep within the deadline
      ;;
  esac

  sleep "$INTERVAL"
done
