#!/usr/bin/env bash
# lib/cmd-report.sh — citt report subcommand.
# Usage: citt report <package_id> [--scan <scan_id>] [--platform android|ios]
#
# Serves the OWNER/RESEARCHER detailed (full) report for an app's latest
# completed FULL scan (markdown), or a specific scan via --scan.
#
# PRIMARY: GET /reports/{pkg}.md?report_type=detailed[&scan_id][&platform].
# Returns markdown, not JSON. 403 = not authorized (or locked, see the
# unlock_required flag); 404 = no completed scan. The endpoint is PACKAGE-KEYED,
# so a bare scan_id as the main arg is rejected with a hint.
#
# SECONDARY: for a scan_type='custom' scan the detailed endpoint 404s; when a
# scan_id was given we fall back to GET /api/scan/{id}/result (custom JSON).
#
# stdout: report markdown / custom JSON. stderr: human summary. Error bodies are
# never dumped. Secret isolation inherited from citt-common.sh.

# Export the response-file path so any python helper subshell can read it.
export _CITT_RESP_FILE

# _is_scan_id: return 0 if the arg looks like a UUID / scan-id (UUID-4 or a bare
# 32+ char hex token). A package_id always contains a dot, so it never matches.
_is_scan_id() {
  local arg="$1"
  if printf '%s' "$arg" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    return 0
  fi
  if printf '%s' "$arg" | grep -qiE '^[0-9a-f]{32,}$'; then
    return 0
  fi
  return 1
}

# _urlenc_qs_val: minimal URL-encoding for a query-string value (scan_id /
# platform), so a crafted value can never break out of the query string.
_urlenc_qs_val() {
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# _fetch_custom_result: SECONDARY fallback. Fetch GET /api/scan/{id}/result;
# on 200 emit the JSON + summary and return 0, else return non-zero.
_fetch_custom_result() {
  local scan_id="$1" code body
  code="$(_curl_auth_get "/api/scan/${scan_id}/result")"
  body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then
    emit_json "$body"
    emit_err "citt report: scan ${scan_id} — custom-scan result fetched (JSON)."
    return 0
  fi
  return 1
}

# citt_cmd_report: main entry point (called by the citt dispatcher).
citt_cmd_report() {
  local pkg="" scan_id="" platform=""

  # -------- argument parsing -------------------------------------------------
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --scan|--scan-id)
        shift
        scan_id="${1:-}"
        if [ -z "$scan_id" ]; then
          printf 'citt report: --scan requires a scan_id.\n' >&2
          exit 1
        fi
        ;;
      --scan=*)
        scan_id="${1#--scan=}"
        ;;
      --platform)
        shift
        platform="${1:-}"
        ;;
      --platform=*)
        platform="${1#--platform=}"
        ;;
      -h|--help)
        cat >&2 <<'H'
Usage: citt report <package_id> [--scan <scan_id>] [--platform android|ios]

Fetches the OWNER/RESEARCHER detailed (full) report for an app's latest
completed FULL scan (or a specific scan via --scan). Requires 'citt auth'.
The report (markdown) goes to stdout; a human summary goes to stderr.
H
        exit 0
        ;;
      --)
        shift
        [ -n "${1:-}" ] && pkg="$1"
        ;;
      -*)
        printf 'citt report: unknown option: %s\n' "$1" >&2
        exit 1
        ;;
      *)
        if [ -z "$pkg" ]; then
          pkg="$1"
        else
          printf 'citt report: unexpected extra argument: %s\n' "$1" >&2
          exit 1
        fi
        ;;
    esac
    shift 2>/dev/null || break
  done

  if [ -z "$pkg" ]; then
    printf 'Usage: citt report <package_id> [--scan <scan_id>] [--platform android|ios]\n' >&2
    exit 1
  fi

  # PACKAGE-KEYED endpoint: reject a bare scan_id as the main arg with a hint.
  if [ -z "$scan_id" ] && _is_scan_id "$pkg"; then
    printf 'citt report: that looks like a scan_id. The detailed report is keyed by package.\n' >&2
    printf '  Use:  citt report <package_id> --scan %s\n' "$pkg" >&2
    exit 1
  fi

  # -------- auth (exits with re-auth hint if no token) -----------------------
  _prepare_auth

  # -------- build the detailed-report path -----------------------------------
  local path="/reports/${pkg}.md?report_type=detailed"
  if [ -n "$scan_id" ]; then
    path="${path}&scan_id=$(_urlenc_qs_val "$scan_id")"
  fi
  if [ -n "$platform" ]; then
    path="${path}&platform=$(_urlenc_qs_val "$platform")"
  fi

  # -------- PRIMARY: fetch the detailed markdown report ----------------------
  local code body
  code="$(_curl_auth_get "$path")"
  body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"

  case "$code" in
    200)
      # Detailed report (markdown) → stdout (the Claude tool output channel).
      printf '%s\n' "$body"
      if [ -n "$scan_id" ]; then
        emit_err "citt report: ${pkg} (scan ${scan_id}) — detailed report fetched."
      else
        emit_err "citt report: ${pkg} — detailed report for the latest completed full scan fetched."
      fi
      exit 0
      ;;
    401)
      _reauth_hint   # exits non-zero
      ;;
    403)
      # Distinguish locked (unlock_required) from a plain auth denial, without
      # dumping the raw body.
      if printf '%s' "$body" | grep -q '"unlock_required"[[:space:]]*:[[:space:]]*true'; then
        emit_err "citt report: this report is locked for '${pkg}'. Unlock it in the CITT app, or use an owner/admin token."
      else
        emit_err "citt report: access denied for '${pkg}' — you must own this app (or have admin/research access) to view its detailed report."
      fi
      exit 1
      ;;
    404)
      # No detailed report. If a scan_id was given it might be a custom scan —
      # try the custom-result JSON fallback before erroring.
      if [ -n "$scan_id" ]; then
        if _fetch_custom_result "$scan_id"; then
          exit 0
        fi
      fi
      emit_err "citt report: no completed report found for '${pkg}'${scan_id:+ (scan ${scan_id})}."
      exit 1
      ;;
    410)
      emit_err "citt report: that report type is no longer available."
      exit 1
      ;;
    "")
      emit_err "citt report: could not reach the CITT API."
      exit 1
      ;;
    *)
      emit_err "citt report: unexpected HTTP ${code} from /reports/${pkg}.md."
      exit 1
      ;;
  esac
}
