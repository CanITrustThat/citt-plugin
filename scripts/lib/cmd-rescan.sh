#!/usr/bin/env bash
# lib/cmd-rescan.sh — `citt rescan` subcommand. Sourced by the `citt` dispatcher
# (which has already sourced lib/citt-common.sh).
#
#   citt rescan <pkg> [--platform android|ios] [--private]  — force a fresh scan
#   citt rescan --check <pkg> [--platform ...]              — read-only eligibility probe
#
# Unlike `submit`, rescan NEVER reuses an existing scan: POST /api/rescan always
# creates a new scan (full pipeline). Who may rescan is decided server-side, not
# here — admin: any app; developer: apps they own; Research/custom plan: any app
# (metered against the scan-others quota). The CLI never pre-judges: it POSTs and
# relays the server's verdict. Secret isolation matches the rest of the CLI: the
# token rides the 0600 curl --config only, never argv/stdout/xtrace.

[ "${_CITT_CMD_RESCAN_LOADED:-}" = "1" ] && return 0
_CITT_CMD_RESCAN_LOADED=1

# _rescan_err: clean human error to stderr + exit. Never dumps raw bodies.
_rescan_err() {
  local msg="$1" code="${2:-}"
  if [ -n "$code" ]; then
    emit_err "citt rescan: $msg (HTTP $code)"
  else
    emit_err "citt rescan: $msg"
  fi
  exit 1
}

# _rescan_detail: pull the "detail" scalar from the response for a clean message.
_rescan_detail() {
  local body; body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"
  _json_get "detail" "$body"
}

# URL-encode a package id for use in a path (defensive; ids are [A-Za-z0-9._-]).
_rescan_urlenc() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}

citt_cmd_rescan() {
  local pkg="" platform="android" is_private="false" do_check=0

  # Parse positional package id + flags (no getopts — portability).
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check)    do_check=1 ;;
      --private)  is_private="true" ;;
      --platform)
        shift
        case "${1:-}" in
          android|ios) platform="$1" ;;
          *) _rescan_err "invalid --platform '${1:-}' (use android or ios)" ;;
        esac
        ;;
      --help|-h)
        cat >&1 <<'USAGE'
Usage: citt rescan <package_id> [--platform android|ios] [--private]
       citt rescan --check <package_id> [--platform android|ios]

  citt rescan <pkg>          Force a fresh full scan (creates a NEW scan; never reuses)
  citt rescan --check <pkg>  Read-only: can you rescan this app right now, and quota left

Who may rescan (enforced server-side): admin — any app; developer — apps you own;
Research/custom plan — any app, metered against your scan-others quota. Run
`citt auth` first if not authenticated.
USAGE
        return 0
        ;;
      -*)
        _rescan_err "unknown flag: $1 (see: citt rescan --help)"
        ;;
      *)
        if [ -z "$pkg" ]; then pkg="$1"; else _rescan_err "unexpected extra argument: $1"; fi
        ;;
    esac
    shift
  done

  if [ -z "$pkg" ]; then
    emit_err "citt rescan: missing package_id"
    emit_err "Usage: citt rescan <package_id> [--platform android|ios] [--private]"
    exit 2
  fi

  # Auth: load token + build curl config. Exits with re-auth hint if missing.
  _prepare_auth

  # ---- Read-only eligibility probe -----------------------------------------
  if [ "$do_check" = "1" ]; then
    local enc code body
    enc="$(_rescan_urlenc "$pkg")"
    code="$(_curl_auth_get "/api/apps/${enc}/rescan-eligibility")"
    case "$code" in
      200)
        body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"
        emit_json "$body"
        local can reason used limit
        can="$(_json_get can_rescan "$body")"
        reason="$(_json_get reason "$body")"
        used="$(_json_get rescans_used "$body")"
        limit="$(_json_get rescans_limit "$body")"
        if [ "$can" = "true" ]; then
          emit_err "rescan check: ${pkg} — you CAN rescan (used ${used:-0}/${limit:-unlimited})"
        else
          emit_err "rescan check: ${pkg} — cannot rescan (${reason:-not eligible}; used ${used:-0}/${limit:-?})"
        fi
        return 0
        ;;
      401) _reauth_hint ;;
      "")  _rescan_err "could not reach the CITT API" ;;
      *)   _rescan_err "unexpected response from rescan-eligibility" "$code" ;;
    esac
  fi

  # ---- Trigger the rescan ---------------------------------------------------
  # Build the 0600 request body. is_private=false => refreshes the PUBLIC
  # scorecard; --private creates a private scan instead.
  local body_file
  body_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_rescan_body.XXXXXX")"
  local _rf="$body_file"
  trap "rm -f '${_rf}' 2>/dev/null || true; _citt_common_cleanup" EXIT
  ( umask 077
    if command -v jq >/dev/null 2>&1; then
      jq -nc --arg p "$pkg" --arg pl "$platform" --argjson priv "$is_private" \
        '{package_id:$p, platform:$pl, is_private:$priv}' >"$body_file"
    else
      printf '{"package_id":"%s","platform":"%s","is_private":%s}' \
        "$pkg" "$platform" "$is_private" >"$body_file"
    fi
  )

  local code
  code="$(_curl_auth_post "/api/rescan" "$body_file")"

  case "$code" in
    200)
      local body scan_id scan_number
      body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"
      emit_json "$body"
      scan_id="$(_json_get scan_id "$body")"
      scan_number="$(_json_get scan_number "$body")"
      emit_err "citt rescan: ${pkg} — fresh scan #${scan_number:-?} queued (scan_id ${scan_id:-?})."
      # Poll the NEW scan by id — plain `citt status ${pkg}` shows the last
      # COMPLETED scan while this rescan runs, not the in-flight one.
      if [ -n "$scan_id" ]; then
        emit_err "Poll this scan with: citt status ${pkg} --scan-id ${scan_id}"
      else
        emit_err "Poll progress with: citt status ${pkg}"
      fi
      ;;
    401) _reauth_hint ;;
    403)
      local detail; detail="$(_rescan_detail)"
      _rescan_err "${detail:-not authorized to rescan this app for your plan; developers rescan apps they own, Research plans can scan apps they do not own}" "$code"
      ;;
    429)
      local detail; detail="$(_rescan_detail)"
      _rescan_err "${detail:-monthly rescan limit reached — upgrade for more}" "$code"
      ;;
    400)
      local detail; detail="$(_rescan_detail)"
      _rescan_err "${detail:-bad request}" "$code"
      ;;
    "")  _rescan_err "could not reach the CITT API" ;;
    *)
      local detail; detail="$(_rescan_detail)"
      _rescan_err "${detail:-rescan failed}" "$code"
      ;;
  esac
}
