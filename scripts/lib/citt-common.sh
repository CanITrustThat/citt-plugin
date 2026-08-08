#!/usr/bin/env bash
# lib/citt-common.sh — shared library: token load, curl helpers, output helpers.
# Secret isolation: the token is never echoed, on argv, or in a variable that
# xtrace could trace. It flows only via a 0600 curl --config file, assembled by
# printf'ing static bytes then `cat`-ing the raw token from its 0600 file.
# Host is hardcoded; CITT_API_OVERRIDE is honored only under CITT_TEST_MODE=1.

[ "${_CITT_COMMON_LOADED:-}" = "1" ] && return 0
_CITT_COMMON_LOADED=1

# API host (hardcoded egress allow-list). Test-only override under CITT_TEST_MODE=1.
_CITT_API="https://canitrustthat.com"
if [ "${CITT_TEST_MODE:-}" = "1" ] && [ -n "${CITT_API_OVERRIDE:-}" ]; then
  _CITT_API="${CITT_API_OVERRIDE}"
fi

# Token store coordinates — shared with citt-auth.sh / citt-submit.sh / citt-auth-check.sh.
# The state dir is PINNED to a stable, invocation-independent path so it resolves
# identically whether citt runs as a /citt:* slash command or a bare Bash call.
# CLAUDE_PLUGIN_DATA is deliberately NOT used here: Claude Code sets it only for slash
# commands, so keying the path off it made writes and reads disagree (a token saved by
# /citt:auth was invisible to a raw-script call). It survives only as a migration source.
_CITT_STATE_DIR="${CITT_STATE_DIR:-$HOME/.config/citt}"
_CITT_TOKEN_FILE="${_CITT_STATE_DIR}/device_token"
_CITT_KR_SERVICE="canitrustthat-citt"
_CITT_KR_ACCOUNT="device_token"

# One-time migration: adopt a token left by an older build under CLAUDE_PLUGIN_DATA so
# upgrades don't look logged-out. Best-effort and silent; never fails the caller.
_citt_migrate_legacy_token() {
  if [ -s "${_CITT_TOKEN_FILE}" ]; then return 0; fi
  local legacy="${CLAUDE_PLUGIN_DATA:-}/device_token"
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -s "$legacy" ]; then
    mkdir -p "${_CITT_STATE_DIR}" 2>/dev/null || return 0
    chmod 700 "${_CITT_STATE_DIR}" 2>/dev/null || true
    ( umask 077; tr -d '\n' <"$legacy" >"${_CITT_TOKEN_FILE}" ) 2>/dev/null || true
    chmod 600 "${_CITT_TOKEN_FILE}" 2>/dev/null || true
  fi
  return 0
}
_citt_migrate_legacy_token

# 0600 scratch files, cleaned on EXIT. CITT_COMMON_TMPDIR lets the caller share a tmpdir.
_CITT_TMPDIR="${CITT_COMMON_TMPDIR:-$(umask 077; mktemp -d "${TMPDIR:-/tmp}/citt_lib.XXXXXX")}"
_CITT_TOKEN_STAGING="${_CITT_TMPDIR}/tok_staging"
_CITT_CURL_CFG="${_CITT_TMPDIR}/curl_cfg"
_CITT_RESP_FILE="${_CITT_TMPDIR}/resp"
_CITT_BODY_FILE="${_CITT_TMPDIR}/body"

# Scratch files mode 600 from birth.
( umask 077
  touch "${_CITT_TOKEN_STAGING}" "${_CITT_CURL_CFG}" "${_CITT_RESP_FILE}" "${_CITT_BODY_FILE}"
)

_citt_common_cleanup() {
  rm -rf "${_CITT_TMPDIR}" 2>/dev/null || true
}
trap _citt_common_cleanup EXIT

# JSON scalar extraction. jq preferred, grep/sed fallback. Usage: _json_get <field> <body>
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

# Keyring helpers (read-only here; citt-auth.sh owns writes).
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
  # Require a NON-EMPTY value (a zero-length keychain item is not "authenticated"
  # and must not shadow the 0600 file). Value goes to a 0600 temp and is size-
  # tested, never held in a shell variable (xtrace-safe).
  if [ "${CITT_TEST_MODE:-}" = "1" ] && [ "${CITT_FORCE_FILE_TOKEN:-}" = "1" ]; then
    return 1
  fi
  local t present=1
  t="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_has.XXXXXX")"
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$_CITT_KR_SERVICE" -a "$_CITT_KR_ACCOUNT" -w 2>/dev/null \
      | tr -d '\n' >"$t"
    [ -s "$t" ] && present=0
  elif command -v secret-tool >/dev/null 2>&1; then
    secret-tool lookup service "$_CITT_KR_SERVICE" account "$_CITT_KR_ACCOUNT" 2>/dev/null \
      | tr -d '\n' >"$t"
    [ -s "$t" ] && present=0
  fi
  rm -f "$t" 2>/dev/null || true
  return $present
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

# Returns 0 if a usable token is present (local only, no network).
_have_token() {
  if _keyring_has_token; then return 0; fi
  if [ -s "$_CITT_TOKEN_FILE" ]; then return 0; fi
  return 1
}

# Load the token into the 0600 staging file. Order: CITT_TOKEN env, keyring, file.
# Token flows file->file only, never through a traced variable.
_load_token_to_staging() {
  # ${CITT_TOKEN+x} (set-test, not value-expansion) so xtrace sees only "x".
  if [ -n "${CITT_TOKEN+x}" ]; then
    ( umask 077; tr -d '\n' <<<"${CITT_TOKEN}" >"${_CITT_TOKEN_STAGING}" )
    [ -s "${_CITT_TOKEN_STAGING}" ] && return 0
  fi
  if _keyring_to_file "${_CITT_TOKEN_STAGING}"; then
    ( umask 077; tr -d '\n' <"${_CITT_TOKEN_STAGING}" >"${_CITT_TOKEN_STAGING}.n" )
    mv -f "${_CITT_TOKEN_STAGING}.n" "${_CITT_TOKEN_STAGING}"
    [ -s "${_CITT_TOKEN_STAGING}" ] && return 0
  fi
  if [ -s "${_CITT_TOKEN_FILE}" ]; then
    ( umask 077; tr -d '\n' <"${_CITT_TOKEN_FILE}" >"${_CITT_TOKEN_STAGING}" )
    [ -s "${_CITT_TOKEN_STAGING}" ] && return 0
  fi
  return 1
}

# Build the 0600 curl --config with the Authorization header. Token bytes are
# `cat`-ed from the staging file, never passed as a printf arg (xtrace-safe).
_build_curl_cfg() {
  ( umask 077
    {
      printf 'silent\n'
      printf 'show-error\n'
      printf 'header = "Authorization: Bearer '
      cat "${_CITT_TOKEN_STAGING}"
      printf '"\n'
    } >"${_CITT_CURL_CFG}"
  )
}

# Load token + build curl config; re-auth hint + non-zero exit if no token.
_prepare_auth() {
  if ! _load_token_to_staging; then
    printf 'not authenticated — run: citt auth\n' >&2
    exit 1
  fi
  _build_curl_cfg
}

# Print re-auth hint + non-zero exit. Used on 401.
_reauth_hint() {
  printf 're-authenticate — run: citt auth\n' >&2
  exit 1
}

# Authenticated GET/POST via the 0600 curl --config. Body -> _CITT_RESP_FILE, HTTP code -> stdout.
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

# Unauthenticated request helpers.
_curl_pub_post() {  # $1 = path  $2 = body (inline string, not a secret)
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

# emit_json -> stdout, emit_err -> stderr.
emit_json() {  # $1 = compact JSON string
  printf '%s\n' "$1"
}

emit_err() {  # $1 = human message
  printf '%s\n' "$1" >&2
}
