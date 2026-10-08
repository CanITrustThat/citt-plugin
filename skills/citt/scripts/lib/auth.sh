#!/usr/bin/env bash
# lib/auth.sh: citt auth (legacy RFC 8628 device flow and token store), whoami, logout.
# The minted token goes from the response file into a 0600 file, never into a variable.
# shellcheck shell=bash disable=SC2034

POLL_CEILING_SECONDS=600

# Persist the token held in the 0600 file $1: keyring when the write round-trips, else the file.
_store_token() {
  local src="$1" exp got
  if keyring_available && _keyring_store "$src" && _keyring_roundtrip "$src"; then
    return 0
  fi
  mkdir -p "$CITT_STATE" 2>/dev/null || true
  chmod 700 "$CITT_STATE" 2>/dev/null || true
  ( umask 077; tr -d '\n' <"$src" >"$CITT_TOKEN_FILE" ) 2>/dev/null || true
  chmod 600 "$CITT_TOKEN_FILE" 2>/dev/null || true
  exp="$(tmpfile st_exp)"
  ( umask 077; tr -d '\n' <"$src" >"$exp" )
  got=0
  if [ ! -s "$CITT_TOKEN_FILE" ] || ! cmp -s "$CITT_TOKEN_FILE" "$exp"; then got=1; fi
  : >"$exp"
  if [ "$got" = 1 ]; then
    err "citt auth: could not save the credential (keyring and $CITT_TOKEN_FILE both failed)"
    return 1
  fi
  return 0
}

_keyring_store() {
  local src="$1" feed rc
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    # add-generic-password -w without a value prompts twice; feed the token twice on stdin.
    feed="$(tmpfile kr_feed)"
    ( umask 077; { tr -d '\n' <"$src"; printf '\n'; tr -d '\n' <"$src"; printf '\n'; } >"$feed" )
    security add-generic-password -U -s "$CITT_KR_SERVICE" -a "$CITT_KR_ACCOUNT" -w <"$feed" >/dev/null 2>&1
    rc=$?
    : >"$feed"
    return $rc
  fi
  tr -d '\n' <"$src" | secret-tool store --label="CITT device token" \
    service "$CITT_KR_SERVICE" account "$CITT_KR_ACCOUNT" >/dev/null 2>&1
}

_keyring_roundtrip() {
  local src="$1" got exp rc=1
  got="$(tmpfile rt_got)"
  exp="$(tmpfile rt_exp)"
  ( umask 077; tr -d '\n' <"$src" >"$exp" )
  keyring_to_file "$got" && cmp -s "$exp" "$got" && rc=0
  : >"$got"
  : >"$exp"
  return $rc
}

_delete_stored_token() {
  keyring_delete
  rm -f "$CITT_TOKEN_FILE" 2>/dev/null || true
}

# plugin_version: the version in the plugin's manifest (four levels above lib/), or "unknown".
plugin_version() {
  jq -r '.version // "unknown"' "$CITT_LIB/../../../../.claude-plugin/plugin.json" 2>/dev/null || printf 'unknown'
}

# _trusted_link URL: true for a sign-in link on the service host or the dashboard host; any link of
# the overridden host in test mode.
_trusted_link() {
  case "$1" in
    "$CITT_HOST"/* | https://canitrustthat.com/* | "$CITT_APP_HOST"/*) return 0 ;;
  esac
  [ "$CITT_OVERRIDDEN" = 1 ] && case "$1" in http://* | https://*) return 0 ;; esac
  return 1
}

# _auth_start: requests a device code, saves the pending flow and prints the link.
_auth_start() {
  local body interval expires deadline link
  body="$(tmpfile dc_body)"
  jq -nc --arg c "citt-plugin $(plugin_version)" '{client: $c}' >"$body"
  HTTP_AUTH=0
  HTTP_RETRY=no
  http POST /api/device/code "$body"
  ok || fail_http
  link="$(body_field '.verification_uri_complete')"
  if [ -z "$(body_field '.device_code')" ] || [ -z "$link" ]; then
    die 1 "unexpected response from /api/device/code"
  fi
  _trusted_link "$link" || die 1 "the sign-in link is not on canitrustthat.com; not shown"
  interval="$(body_field '.interval')"
  expires="$(body_field '.expires_in')"
  is_uint "$interval" || interval=5
  is_uint "$expires" || expires=900
  [ "$expires" -gt "$POLL_CEILING_SECONDS" ] && expires="$POLL_CEILING_SECONDS"
  deadline=$(($(now_s) + expires))
  mkdir -p "$CITT_STATE"
  chmod 700 "$CITT_STATE" 2>/dev/null || true
  # The device code goes file to file: line 1 code, line 2 interval, line 3 deadline.
  ( umask 077
    { jq -r '.device_code' "$RESP"; printf '%s\n%s\n' "$interval" "$deadline"; } >"$CITT_FLOW_FILE" )
  printf '%s\n' "$link"
}

# _auth_wait: polls /api/device/token until authorized, denied, expired or the deadline.
_auth_wait() {
  [ -s "$CITT_FLOW_FILE" ] || die 3 "no pending sign-in; run: citt auth"
  local body tok interval deadline error
  body="$(tmpfile poll_body)"
  tok="$(tmpfile new_tok)"
  sed -n '1p' "$CITT_FLOW_FILE" | tr -d '\n' | jq -Rc '{grant_type: "device_code", device_code: .}' >"$body"
  interval="$(sed -n '2p' "$CITT_FLOW_FILE")"
  deadline="$(sed -n '3p' "$CITT_FLOW_FILE")"
  is_uint "$interval" || interval=5
  is_uint "$deadline" || deadline=$(($(now_s) + POLL_CEILING_SECONDS))
  while :; do
    if [ "$(now_s)" -ge "$deadline" ]; then
      err "still waiting for authorization; open the link, then run: citt auth --wait"
      exit 12
    fi
    HTTP_AUTH=0
    HTTP_RETRY=no
    http POST /api/device/token "$body"
    if [ "$CODE" = 200 ]; then
      ( umask 077; jq -j '.access_token // empty' "$RESP" | tr -d '\n' >"$tok" )
      : >"$RESP"
      [ -s "$tok" ] || die 1 "authorization succeeded but no token was returned"
      _store_token "$tok" || exit 1
      : >"$tok"
      rm -f "$CITT_FLOW_FILE"
      printf 'authenticated\n'
      exit 0
    fi
    [ "$CODE" = 000 ] && fail_http
    error="$(body_field '.error')"
    case "$error" in
      authorization_pending) ;;
      slow_down) interval=$((interval + 5)) ;;
      access_denied)
        rm -f "$CITT_FLOW_FILE"
        err "$(body_field '.message // "access denied for this plan; see canitrustthat.com/pricing"')"
        exit 3
        ;;
      expired_token)
        rm -f "$CITT_FLOW_FILE"
        err "the link expired; run: citt auth"
        exit 3
        ;;
      *) case "$CODE" in 5??) ;; 4??) [ -n "$error" ] || fail_http ;; esac ;;
    esac
    poll_sleep "$interval"
  done
}

# _auth_check: 0 when the stored or given token is accepted, 1 when there is none or it got a
# 401 (the stored one is then deleted); any other failure exits with its mapped code.
_auth_check() {
  load_token || return 1
  http GET "$CITT_V1/usage"
  ok && return 0
  if [ "$CODE" = 401 ]; then
    [ -n "${CITT_TOKEN+x}" ] || _delete_stored_token
    return 1
  fi
  fail_http
}

cmd_auth() {
  local mode=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --start | --wait | --status) mode="$1" ;;
      --help | -h)
        help_auth
        exit 0
        ;;
      *) usage_error "unknown option $1 (use --start, --wait or --status)" ;;
    esac
    shift
  done
  case "$mode" in
    --status)
      # Local only, for the SessionStart hook: is a token stored?
      if [ -n "${CITT_TOKEN+x}" ] || keyring_has_token || [ -s "$CITT_TOKEN_FILE" ]; then
        printf 'signed in (token stored)\n'
        exit 0
      fi
      err "citt auth: not signed in; run: citt auth"
      exit 3
      ;;
    --wait) _auth_wait ;;
    --start)
      if _auth_check; then
        printf 'authenticated\n'
        exit 0
      fi
      _auth_start
      exit 0
      ;;
    *)
      if _auth_check; then
        printf 'authenticated\n'
        exit 0
      fi
      _auth_start
      _auth_wait
      ;;
  esac
}

cmd_whoami() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_whoami
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  need_auth
  local account="$_CITT_TMP/whoami-account.json" me="$_CITT_TMP/whoami-me.json"
  call GET /api/me
  cp "$RESP" "$account"
  # The research account (DESIGN-37 "GET /me"): answered without the entitlement too.
  call GET "$CITT_V1/me"
  cp "$RESP" "$me"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --slurpfile me "$me" '. + {research: $me[0]}' "$account" \
      || die 1 "unparseable response from GET /api/me"
    return 0
  fi
  jq -r '"email: \(.email // "-")",
    "user_type: \(.user_type // "-")",
    "analysis_track: \(.analysis_track // "-")"' "$account" \
    || die 1 "unparseable response from GET /api/me"
  # The service's plan (GET /me .plan) first: an account can hold a plan without a legacy subscription.
  printf 'plan: %s\n' "$(_plan_name "$(jq -rn --slurpfile a "$account" --slurpfile m "$me" \
    '$m[0].plan // $a[0].subscription.plan_id // $a[0].subscription.plan // $a[0].plan // empty')")"
  # D62: `research` is the only entitlement; any other value is shown as none.
  jq -r '[(.entitlements // [])[] | select(. == "research")] as $e
    | "entitlements: \(if $e == [] then "none" else ($e | join(",")) end)",
    "owned_projects: \(.owned_project_count // 0)",
    "free_scans_project: \(.free_scans_project_id // "none")"' "$me" \
    || die 1 "unparseable response from GET $CITT_V1/me"
  if ! jq -e '(.entitlements // []) | index("research")' "$me" >/dev/null; then
    err "$CITT_CMD: Pay as you go: Android rule scans (citt submit PACKAGE) and questions (citt prompt); projects, CSV, findings across a project, scrutiny and exports: $CITT_PRICING_URL"
  fi
}

cmd_logout() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --help | -h)
        help_logout
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
  done
  local removed=0
  if keyring_has_token; then
    keyring_delete
    removed=1
  fi
  if [ -f "$CITT_TOKEN_FILE" ]; then
    rm -f "$CITT_TOKEN_FILE"
    removed=1
  fi
  rm -f "$CITT_FLOW_FILE" 2>/dev/null || true
  if [ "$removed" = 1 ]; then
    err "logged out; token removed."
  else
    err "logged out (no token was stored)."
  fi
}
