#!/usr/bin/env bash
# =============================================================================
# lib/cmd-result.sh — citt result subcommand (CITT-C2)
# =============================================================================
# Usage: citt result <scan_id>
#
# Fetches a CUSTOM-scan result for a given scan_id.
#
# Endpoint (mirrors the SECONDARY custom-result fetch in cmd-report.sh's
# _fetch_custom_result — src/api.py custom-scan result, api.py:6703):
#   GET /api/scan/{scan_id}/result
#   - Auth via get_current_user (the skill token works).
#   - 200 → JSON {scan_id, package_id, prompt, status:"completed", result:<…>}.
#   - 404 → the result is not ready yet (custom scan still processing / no such
#     scan). We surface this as a friendly "not ready — try again" hint.
#   - 403 → the caller is not authorized to view this scan.
#   - 401 → token expired/invalid → re-auth hint.
#
# Output contract:
#   - The result JSON → stdout (emit_json; the Claude tool output channel).
#   - Human summary → stderr.
#
# SECRET ISOLATION (inherits all invariants from citt-common.sh):
#   - The token NEVER appears on argv, stdout, or `bash -x` xtrace.
#   - All token handling flows through 0600 temp files via the shared lib.
#
# Not-ready / not-authorized / not-found / unreachable → clean NO-LEAK message
# + nonzero exit. Raw error bodies that might carry sensitive information are
# NEVER dumped; only a sanitized summary is printed.
# =============================================================================

# Guard against double-sourcing.
[ "${_CITT_CMD_RESULT_LOADED:-}" = "1" ] && return 0
_CITT_CMD_RESULT_LOADED=1

# Export the response-file path so any helper subshell can read it.
export _CITT_RESP_FILE

# ---------------------------------------------------------------------------
# _result_urlenc: minimal URL-encoding for the scan_id path segment. In
# practice a scan_id is UUID/hex ([0-9a-zA-Z._-]), but encode defensively so a
# crafted value can never break out of the path. Mirrors cmd-report.sh's
# _urlenc_qs_val (kept local so this module does not depend on it).
# ---------------------------------------------------------------------------
_result_urlenc() {
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

# ---------------------------------------------------------------------------
# citt_cmd_result: main entry point (called by the citt dispatcher — glue is a
# separate ticket; today it is exercised via a direct-source runner).
# ---------------------------------------------------------------------------
citt_cmd_result() {
  local scan_id=""

  # -------- argument parsing -------------------------------------------------
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cat >&2 <<'H'
Usage: citt result <scan_id>

Fetches the result of a custom scan by its scan_id. Requires 'citt auth'.
The result JSON goes to stdout; a human summary goes to stderr.
H
        exit 0
        ;;
      --)
        shift
        [ -n "${1:-}" ] && scan_id="$1"
        ;;
      -*)
        printf 'citt result: unknown option: %s\n' "$1" >&2
        exit 1
        ;;
      *)
        if [ -z "$scan_id" ]; then
          scan_id="$1"
        else
          printf 'citt result: unexpected extra argument: %s\n' "$1" >&2
          exit 1
        fi
        ;;
    esac
    shift 2>/dev/null || break
  done

  if [ -z "$scan_id" ]; then
    printf 'Usage: citt result <scan_id>\n' >&2
    exit 1
  fi

  # -------- auth (exits with re-auth hint if no token) -----------------------
  _prepare_auth

  # -------- fetch the custom-scan result -------------------------------------
  local path code body
  path="/api/scan/$(_result_urlenc "$scan_id")/result"
  code="$(_curl_auth_get "$path")"
  body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"

  case "$code" in
    200)
      emit_json "$body"
      emit_err "citt result: ${scan_id} — custom-scan result fetched."
      exit 0
      ;;
    401)
      _reauth_hint   # exits non-zero
      ;;
    403)
      emit_err "citt result: not authorized to view scan ${scan_id}."
      exit 1
      ;;
    404)
      emit_err "citt result: scan ${scan_id} is not ready yet (still processing). Try again shortly."
      exit 1
      ;;
    "")
      emit_err "citt result: could not reach the CITT API."
      exit 1
      ;;
    *)
      emit_err "citt result: unexpected HTTP ${code} from /api/scan/${scan_id}/result."
      exit 1
      ;;
  esac
}
