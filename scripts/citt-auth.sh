#!/usr/bin/env bash
set -euo pipefail

# citt-auth.sh — RFC-8628 device-flow client. Runs in Claude Code's Bash tool, so
# the access token must never enter model context (stdout/argv/xtrace).
# The client is unauthenticated; the minted token arrives only in the 200 body and
# is extracted file->file into a 0600 temp, then stored (keyring-first, else file).
# Host is hardcoded; CITT_API_OVERRIDE is honored only under CITT_TEST_MODE=1.

# API base (hardcoded egress allow-list). Test-only override under CITT_TEST_MODE=1.
CITT_API="https://canitrustthat.com"
if [ "${CITT_TEST_MODE:-}" = "1" ] && [ -n "${CITT_API_OVERRIDE:-}" ]; then
  CITT_API="${CITT_API_OVERRIDE}"
fi

# 0600 token file the helper scripts own. State dir is PINNED to a stable path (see
# lib/citt-common.sh for the rationale): CITT_STATE_DIR override, else $HOME/.config/citt.
# It must match every other helper so a token written here is readable by every
# subcommand regardless of how citt was invoked. CLAUDE_PLUGIN_DATA is migration-only.
CITT_STATE_DIR_RESOLVED="${CITT_STATE_DIR:-$HOME/.config/citt}"
TOKEN_FILE="${CITT_STATE_DIR_RESOLVED}/device_token"

# One-time migration of a token left by an older build under CLAUDE_PLUGIN_DATA.
_citt_migrate_legacy_token() {
  if [ -s "$TOKEN_FILE" ]; then return 0; fi
  local legacy="${CLAUDE_PLUGIN_DATA:-}/device_token"
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -s "$legacy" ]; then
    mkdir -p "$CITT_STATE_DIR_RESOLVED" 2>/dev/null || return 0
    chmod 700 "$CITT_STATE_DIR_RESOLVED" 2>/dev/null || true
    ( umask 077; tr -d '\n' <"$legacy" >"$TOKEN_FILE" ) 2>/dev/null || true
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  fi
  return 0
}

# Keyring coordinates (macOS security / Linux secret-tool).
KEYRING_SERVICE="canitrustthat-citt"
KEYRING_ACCOUNT="device_token"

POLL_CEILING_SECONDS=600   # 10 min hard bound regardless of expires_in

# JSON scalar extraction. jq preferred, grep/sed fallback. Usage: _json_get <field> <body>
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

# Keyring backend present? Non-zero -> callers use the 0600 file.
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

# Store the token (0600 file at $1) into the keyring via stdin, never argv.
_keyring_store_from_file() {
  local src="$1"
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    # `security add-generic-password -w` (value-less) is an interactive prompt that
    # reads TWICE (enter + retype); feed once and it stores EMPTY. Feed the token twice.
    local feed rc
    feed="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_feed.XXXXXX")"
    ( umask 077
      { tr -d '\n' <"$src"; printf '\n'; tr -d '\n' <"$src"; printf '\n'; } >"$feed"
    )
    security add-generic-password -U \
      -s "$KEYRING_SERVICE" -a "$KEYRING_ACCOUNT" \
      -w <"$feed" >/dev/null 2>&1
    rc=$?
    rm -f "$feed" 2>/dev/null || true
    return $rc
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    # secret-tool store reads cleanly from stdin (single read), so one line is right.
    tr -d '\n' <"$src" | secret-tool store --label="CITT device token" \
      service "$KEYRING_SERVICE" account "$KEYRING_ACCOUNT" >/dev/null 2>&1
    return $?
  fi
  return 1
}

# Confirm the stored value byte-matches $1, so a silently-broken keyring falls
# through to the file instead of persisting garbage. Compared via 0600 temps.
_keyring_roundtrip_ok() {  # $1 = src file holding the expected token
  local src="$1" got exp rc=1
  got="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_rt_got.XXXXXX")"
  exp="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_rt_exp.XXXXXX")"
  ( umask 077; tr -d '\n' <"$src" >"$exp" )
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$KEYRING_SERVICE" -a "$KEYRING_ACCOUNT" -w 2>/dev/null \
      | tr -d '\n' >"$got"
  elif command -v secret-tool >/dev/null 2>&1; then
    secret-tool lookup service "$KEYRING_SERVICE" account "$KEYRING_ACCOUNT" 2>/dev/null \
      | tr -d '\n' >"$got"
  fi
  if [ -s "$got" ] && cmp -s "$exp" "$got"; then rc=0; fi
  rm -f "$got" "$exp" 2>/dev/null || true
  return $rc
}

# True (0) only if a NON-EMPTY token is present (an empty item must not count as
# authenticated: it would block re-auth and shadow the file). Size-tested via a 0600 temp.
_keyring_has_token() {
  if [ "${CITT_TEST_MODE:-}" = "1" ] && [ "${CITT_FORCE_FILE_TOKEN:-}" = "1" ]; then
    return 1
  fi
  local t present=1
  t="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_has.XXXXXX")"
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$KEYRING_SERVICE" -a "$KEYRING_ACCOUNT" -w 2>/dev/null \
      | tr -d '\n' >"$t"
    [ -s "$t" ] && present=0
  elif command -v secret-tool >/dev/null 2>&1; then
    secret-tool lookup service "$KEYRING_SERVICE" account "$KEYRING_ACCOUNT" 2>/dev/null \
      | tr -d '\n' >"$t"
    [ -s "$t" ] && present=0
  fi
  rm -f "$t" 2>/dev/null || true
  return $present
}

# Usable token present locally? (No network.)
_have_token() {
  _citt_migrate_legacy_token
  if _keyring_has_token; then
    return 0
  fi
  if [ -s "$TOKEN_FILE" ]; then
    return 0
  fi
  return 1
}

# Persist the token ($1 = 0600 temp holding the raw token).
_store_token_file() {
  local src="$1"
  # Keyring only if the write round-trips; otherwise fall through to the 0600 file.
  if _keyring_available && _keyring_store_from_file "$src" && _keyring_roundtrip_ok "$src"; then
    return 0
  fi
  # File fallback (also the universal path where no keyring exists).
  mkdir -p "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
  chmod 700 "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
  ( umask 077; tr -d '\n' <"$src" >"$TOKEN_FILE" ) 2>/dev/null || true
  chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  # Fail loudly if neither store persisted a readable, byte-correct token — better than
  # reporting success and leaving the user "not authenticated" on the next call.
  local exp rc=0
  exp="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_st.XXXXXX")"
  ( umask 077; tr -d '\n' <"$src" >"$exp" )
  if [ ! -s "$TOKEN_FILE" ] || ! cmp -s "$TOKEN_FILE" "$exp"; then
    rc=1
    echo "citt-auth.sh: could not save the credential (keyring and ${TOKEN_FILE} both failed)." >&2
  fi
  rm -f "$exp" 2>/dev/null || true
  return $rc
}

# Pending-flow state (0600): device_code, interval, deadline_epoch. Written by
# --start, consumed by --wait. The flow is split into two foreground calls because
# a detached poller does not survive Claude Code's Bash tool.
FLOW_FILE="${CITT_STATE_DIR_RESOLVED}/device_flow"

# --start: get a device_code + link, persist pending state, print the link, return fast.
_do_start() {
  local device_json device_code verify_uri interval expires_in budget deadline now
  device_json="$(
    curl -sS -X POST "${CITT_API}/api/device/code" \
      -H 'Content-Type: application/json' \
      -d '{"client":"claude-plugin"}' 2>/dev/null
  )" || { echo "citt-auth.sh: could not reach the CITT device endpoint." >&2; return 1; }

  device_code="$(_json_get device_code "$device_json")"
  verify_uri="$(_json_get verification_uri_complete "$device_json")"
  interval="$(_json_get interval "$device_json")"
  expires_in="$(_json_get expires_in "$device_json")"

  if [ -z "$device_code" ] || [ -z "$verify_uri" ]; then
    echo "citt-auth.sh: unexpected response from the device endpoint." >&2
    return 1
  fi
  case "$interval" in ''|*[!0-9]*) interval=5 ;; esac
  case "$expires_in" in ''|*[!0-9]*) expires_in=900 ;; esac

  budget="$expires_in"
  [ "$budget" -gt "$POLL_CEILING_SECONDS" ] && budget="$POLL_CEILING_SECONDS"
  now="$(date +%s)"
  deadline="$((now + budget))"

  mkdir -p "$(dirname "$FLOW_FILE")"
  chmod 700 "$(dirname "$FLOW_FILE")" 2>/dev/null || true
  ( umask 077; printf '%s\n%s\n%s\n' "$device_code" "$interval" "$deadline" >"$FLOW_FILE" )
  chmod 600 "$FLOW_FILE" 2>/dev/null || true

  printf '%s\n' "$verify_uri"
  return 0
}

# --wait: resume the pending flow and block-poll until authorized or the deadline passes.
_do_wait() {
  if [ ! -s "$FLOW_FILE" ]; then
    echo "no pending sign-in — run: citt auth" >&2
    return 1
  fi

  local dc_file body_file resp_file token_tmp
  dc_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_dc.XXXXXX")"
  body_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_body.XXXXXX")"
  resp_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_resp.XXXXXX")"
  token_tmp="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_tok.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$dc_file' '$body_file' '$resp_file' '$token_tmp' 2>/dev/null || true" RETURN

  # Read device_code (line 1) + interval (line 2) + deadline (line 3). device_code
  # goes straight into a 0600 file (never a traced variable).
  ( umask 077; sed -n '1p' "$FLOW_FILE" | tr -d '\n' >"$dc_file" )
  local interval deadline
  interval="$(sed -n '2p' "$FLOW_FILE" | tr -d '\n')"
  deadline="$(sed -n '3p' "$FLOW_FILE" | tr -d '\n')"
  case "$interval" in ''|*[!0-9]*) interval=5 ;; esac
  case "$deadline" in ''|*[!0-9]*) deadline="$(( $(date +%s) + 600 ))" ;; esac

  # Build the poll body (device_code off argv), jq or safe printf+cat fallback.
  if command -v jq >/dev/null 2>&1; then
    jq -nc --rawfile dc "$dc_file" \
      '{grant_type:"device_code", device_code:($dc|rtrimstr("\n"))}' >"$body_file"
  else
    { printf '{"grant_type":"device_code","device_code":"'
      cat "$dc_file"
      printf '"}'; } >"$body_file"
  fi

  local now http_code body err msg
  while :; do
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      echo "still waiting for authorization — open the link, then run: citt auth --wait" >&2
      return 2
    fi

    http_code="$(
      curl -sS -o "$resp_file" -w '%{http_code}' \
        -X POST "${CITT_API}/api/device/token" \
        -H 'Content-Type: application/json' \
        --data "@${body_file}" 2>/dev/null || true
    )"

    if [ "$http_code" = "200" ]; then
      # Extract ONLY the access_token scalar file->file; NEVER into a shell var.
      if command -v jq >/dev/null 2>&1; then
        jq -er '.access_token' <"$resp_file" >"$token_tmp" 2>/dev/null || true
      else
        grep -o '"access_token"[[:space:]]*:[[:space:]]*"[^"]*"' <"$resp_file" \
          | head -n1 \
          | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' \
          | tr -d '\n' >"$token_tmp"
      fi
      # tr -d '\n' guards against an all-whitespace body sneaking past `-s`.
      ( umask 077; tr -d '\n' <"$token_tmp" >"${token_tmp}.n"; mv -f "${token_tmp}.n" "$token_tmp" )
      if [ ! -s "$token_tmp" ]; then
        echo "citt-auth.sh: authorization succeeded but no token was returned." >&2
        return 1
      fi
      if ! _store_token_file "$token_tmp"; then
        return 1   # _store_token_file already explained the failure on stderr
      fi
      rm -f "$FLOW_FILE" 2>/dev/null || true
      echo "authenticated"
      return 0
    fi

    body="$(cat "$resp_file" 2>/dev/null || true)"
    err="$(_json_get error "$body")"
    case "$err" in
      authorization_pending) : ;;
      slow_down) interval="$((interval + 5))" ;;   # RFC 8628 §3.5 back-off
      access_denied)
        msg="$(_json_get message "$body")"
        if [ -n "$msg" ]; then printf '%s\n' "$msg" >&2
        else echo "access denied for this plan — see canitrustthat.com/pricing" >&2; fi
        rm -f "$FLOW_FILE" 2>/dev/null || true
        return 3
        ;;
      expired_token)
        echo "the link expired — run: citt auth to restart." >&2
        rm -f "$FLOW_FILE" 2>/dev/null || true
        return 4
        ;;
      *) : ;;   # unknown: treat like pending within the deadline
    esac
    sleep "$interval"
  done
}

# Dispatch: `citt auth` = start+wait (terminal), --start = link then return,
# --wait = block until authorized. Override + short-circuit apply to all.
MODE="${1:-}"

# CITT_TOKEN override — authenticated, never echo the value.
if [ -n "${CITT_TOKEN+x}" ]; then
  echo "authenticated"
  exit 0
fi

# Already-authenticated short-circuit (skip for --wait so it just polls the pending flow).
if [ "$MODE" != "--wait" ] && _have_token; then
  echo "authenticated"
  exit 0
fi

case "$MODE" in
  --start)
    _do_start; exit $?
    ;;
  --wait)
    _do_wait; exit $?
    ;;
  ''|--)
    _do_start || exit $?
    _do_wait;  exit $?
    ;;
  *)
    echo "citt auth: unknown option '$MODE' (use --start or --wait)" >&2
    exit 64
    ;;
esac
