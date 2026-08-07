#!/usr/bin/env bash
# =============================================================================
# lib/citt-common.sh — CITT plugin shared library (CITT-333)
# =============================================================================
# Sourced by the `citt` dispatcher and every subcommand module. Provides:
#   - Token load: keyring-first → 0600 file fallback
#   - _curl_auth / _curl_pub: authenticated / public request helpers
#   - emit_json / emit_err: canonical output helpers
#   - _reauth_hint: print re-auth hint to stderr + exit non-zero
#
# SECRET ISOLATION (hard invariants — mirrors citt-auth.sh):
#   - The token is NEVER echoed, NEVER placed on argv, NEVER printed, and
#     NEVER lands in a shell variable that could appear under `bash -x` xtrace.
#   - The token flows only via a 0600 curl --config file:
#       header = "Authorization: Bearer <token>"
#     The config file is assembled by writing static bytes via printf then
#     appending raw token bytes from the 0600 token file via `cat` — so no
#     printf/echo is ever called with the token as an argument.
#   - Host is HARDCODED (egress allow-list). CITT_API_OVERRIDE is honored ONLY
#     when CITT_TEST_MODE=1 (set by the harness). The production host is fixed.
#   - All temp files (token staging, curl config, response scratch) are created
#     with umask 077 (mode 600 from birth) and cleaned up on EXIT.
# =============================================================================

# Guard against double-sourcing.
[ "${_CITT_COMMON_LOADED:-}" = "1" ] && return 0
_CITT_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# API host (hardcoded egress allow-list — do NOT make this a general config).
# TEST-ONLY seam: honored ONLY when CITT_TEST_MODE=1.
# ---------------------------------------------------------------------------
_CITT_API="https://canitrustthat.com"
if [ "${CITT_TEST_MODE:-}" = "1" ] && [ -n "${CITT_API_OVERRIDE:-}" ]; then
  _CITT_API="${CITT_API_OVERRIDE}"
fi

# ---------------------------------------------------------------------------
# Token store coordinates — same as citt-auth.sh (shared convention).
# ---------------------------------------------------------------------------
_CITT_TOKEN_FILE="${CLAUDE_PLUGIN_DATA:-$HOME/.config/citt}/device_token"
_CITT_KR_SERVICE="canitrustthat-citt"
_CITT_KR_ACCOUNT="device_token"

# ---------------------------------------------------------------------------
# 0600 scratch files (created once, cleaned on EXIT).
# The CITT_COMMON_TMPDIR allows the caller (dispatcher) to set a shared tmpdir
# so subcommands inherit the same cleanup scope.
# ---------------------------------------------------------------------------
_CITT_TMPDIR="${CITT_COMMON_TMPDIR:-$(umask 077; mktemp -d "${TMPDIR:-/tmp}/citt_lib.XXXXXX")}"
_CITT_TOKEN_STAGING="${_CITT_TMPDIR}/tok_staging"
_CITT_CURL_CFG="${_CITT_TMPDIR}/curl_cfg"
_CITT_RESP_FILE="${_CITT_TMPDIR}/resp"
_CITT_BODY_FILE="${_CITT_TMPDIR}/body"

# Ensure all scratch files have mode 600 from birth.
( umask 077
  touch "${_CITT_TOKEN_STAGING}" "${_CITT_CURL_CFG}" "${_CITT_RESP_FILE}" "${_CITT_BODY_FILE}"
)

_citt_common_cleanup() {
  rm -rf "${_CITT_TMPDIR}" 2>/dev/null || true
}
trap _citt_common_cleanup EXIT

# ---------------------------------------------------------------------------
# JSON scalar extraction. Prefer jq; fall back to grep/sed — same implementation
# as citt-auth.sh so behavior is consistent across the plugin.
# Usage: _json_get <field> <body>
# ---------------------------------------------------------------------------
_json_get() {
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
# Keyring helpers (read-only from lib; citt-auth.sh owns writes).
# _keyring_available: returns 0 if a keyring backend exists.
# _keyring_to_file: reads the token from keyring → dest 0600 file. Non-zero if
#   no backend or no entry.
# ---------------------------------------------------------------------------
_keyring_available() {
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

_keyring_to_file() {  # $1 = destination 0600 file
  local dest="$1"
  if [ "${CITT_TEST_MODE:-}" = "1" ] && [ "${CITT_FORCE_FILE_TOKEN:-}" = "1" ]; then
    return 1
  fi
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security find-generic-password \
      -s "$_CITT_KR_SERVICE" -a "$_CITT_KR_ACCOUNT" -w \
      >"$dest" 2>/dev/null || return 1
    [ -s "$dest" ] || return 1
    return 0
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    secret-tool lookup service "$_CITT_KR_SERVICE" account "$_CITT_KR_ACCOUNT" \
      >"$dest" 2>/dev/null || return 1
    [ -s "$dest" ] || return 1
    return 0
  fi
  return 1
}

_keyring_has_token() {
  if [ "${CITT_TEST_MODE:-}" = "1" ] && [ "${CITT_FORCE_FILE_TOKEN:-}" = "1" ]; then
    return 1
  fi
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security find-generic-password \
      -s "$_CITT_KR_SERVICE" -a "$_CITT_KR_ACCOUNT" \
      >/dev/null 2>&1
    return $?
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    secret-tool lookup service "$_CITT_KR_SERVICE" account "$_CITT_KR_ACCOUNT" \
      >/dev/null 2>&1
    return $?
  fi
  return 1
}

_keyring_delete() {
  if [ "${CITT_TEST_MODE:-}" = "1" ] && [ "${CITT_FORCE_FILE_TOKEN:-}" = "1" ]; then
    return 0
  fi
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security delete-generic-password \
      -s "$_CITT_KR_SERVICE" -a "$_CITT_KR_ACCOUNT" \
      >/dev/null 2>&1 || true
    return 0
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    secret-tool clear service "$_CITT_KR_SERVICE" account "$_CITT_KR_ACCOUNT" \
      >/dev/null 2>&1 || true
    return 0
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _have_token: returns 0 if a usable token is present (no network — local only).
# ---------------------------------------------------------------------------
_have_token() {
  if _keyring_has_token; then return 0; fi
  if [ -s "$_CITT_TOKEN_FILE" ]; then return 0; fi
  return 1
}

# ---------------------------------------------------------------------------
# _load_token_to_staging: load the token IN-PROCESS into the 0600 staging file.
# Order: CITT_TOKEN env → keyring → TOKEN_FILE.
# The token NEVER appears on argv, NEVER in printf/echo args, NEVER in a shell
# variable expansion that would be traced — it flows via file → file only.
# Returns non-zero if no token is available.
# ---------------------------------------------------------------------------
_load_token_to_staging() {
  # CITT_TOKEN env override — move via here-string to avoid argv.
  # Use ${CITT_TOKEN+x} (set-test) not ${CITT_TOKEN:-} (value-expansion) so
  # bash -x traces only the literal "x", never the token value. (CITT-347 F1)
  if [ -n "${CITT_TOKEN+x}" ]; then
    ( umask 077; tr -d '\n' <<<"${CITT_TOKEN}" >"${_CITT_TOKEN_STAGING}" )
    [ -s "${_CITT_TOKEN_STAGING}" ] && return 0
  fi
  # Keyring path
  if _keyring_to_file "${_CITT_TOKEN_STAGING}"; then
    ( umask 077; tr -d '\n' <"${_CITT_TOKEN_STAGING}" >"${_CITT_TOKEN_STAGING}.n" )
    mv -f "${_CITT_TOKEN_STAGING}.n" "${_CITT_TOKEN_STAGING}"
    [ -s "${_CITT_TOKEN_STAGING}" ] && return 0
  fi
  # 0600 file fallback
  if [ -s "${_CITT_TOKEN_FILE}" ]; then
    ( umask 077; tr -d '\n' <"${_CITT_TOKEN_FILE}" >"${_CITT_TOKEN_STAGING}" )
    [ -s "${_CITT_TOKEN_STAGING}" ] && return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _build_curl_cfg: build the 0600 curl --config file with the Authorization
# header. The token bytes are appended from the staging file via `cat` — never
# passed as a printf/echo argument, so they cannot appear in xtrace.
# ---------------------------------------------------------------------------
_build_curl_cfg() {
  ( umask 077
    {
      printf 'silent\n'
      printf 'show-error\n'
      printf 'header = "Authorization: Bearer '  # static prefix, no secret
      cat "${_CITT_TOKEN_STAGING}"               # token bytes from 0600 file
      printf '"\n'                               # close the quoted header
    } >"${_CITT_CURL_CFG}"
  )
}

# ---------------------------------------------------------------------------
# _prepare_auth: load token + build curl config. Prints re-auth hint to stderr
# and exits non-zero if no token is available. Call this at the start of any
# subcommand that needs authenticated requests.
# ---------------------------------------------------------------------------
_prepare_auth() {
  if ! _load_token_to_staging; then
    printf 'not authenticated — run: citt auth\n' >&2
    exit 1
  fi
  _build_curl_cfg
}

# ---------------------------------------------------------------------------
# _reauth_hint: print re-auth hint to stderr and exit non-zero. Used on 401.
# ---------------------------------------------------------------------------
_reauth_hint() {
  printf 're-authenticate — run: citt auth\n' >&2
  exit 1
}

# ---------------------------------------------------------------------------
# _curl_auth: authenticated GET/POST via the 0600 curl --config file.
# The Authorization header comes from the config file — never on argv.
# Writes the response body to _CITT_RESP_FILE; prints HTTP code to stdout.
#
#   _curl_auth_get  <path>
#   _curl_auth_post <path> <body-file>
# ---------------------------------------------------------------------------
_curl_auth_get() {  # $1 = path
  local path="$1" code
  code="$(
    curl --config "${_CITT_CURL_CFG}" \
      -o "${_CITT_RESP_FILE}" -w '%{http_code}' \
      "${_CITT_API}${path}" 2>/dev/null || true
  )"
  printf '%s' "$code"
}

_curl_auth_post() {  # $1 = path  $2 = body file
  local path="$1" bodyf="$2" code
  code="$(
    curl --config "${_CITT_CURL_CFG}" \
      -o "${_CITT_RESP_FILE}" -w '%{http_code}' \
      -X POST "${_CITT_API}${path}" \
      -H 'Content-Type: application/json' \
      --data "@${bodyf}" 2>/dev/null || true
  )"
  printf '%s' "$code"
}

# ---------------------------------------------------------------------------
# _curl_pub: unauthenticated request helper (used by auth flow).
# ---------------------------------------------------------------------------
_curl_pub_post() {  # $1 = path  $2 = body (inline string — safe, not a secret)
  local path="$1" body="$2" code
  code="$(
    curl -sS -X POST "${_CITT_API}${path}" \
      -H 'Content-Type: application/json' \
      -d "$body" \
      -o "${_CITT_RESP_FILE}" -w '%{http_code}' 2>/dev/null || true
  )"
  printf '%s' "$code"
}

_curl_pub_get() {  # $1 = path  (unauthenticated GET; sends no token)
  local path="$1" code
  code="$(
    curl -sS -o "${_CITT_RESP_FILE}" -w '%{http_code}' \
      "${_CITT_API}${path}" 2>/dev/null || true
  )"
  printf '%s' "$code"
}

# ---------------------------------------------------------------------------
# emit_json: write compact JSON to stdout (the Claude tool output channel).
# emit_err:  write a human summary to stderr.
# On HTTP 401 the caller should call _reauth_hint (explicit).
# ---------------------------------------------------------------------------
emit_json() {  # $1 = JSON string (already compact)
  printf '%s\n' "$1"
}

emit_err() {  # $1 = human message
  printf '%s\n' "$1" >&2
}
