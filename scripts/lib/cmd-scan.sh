#!/usr/bin/env bash
# =============================================================================
# lib/cmd-scan.sh — `citt scan` subcommand (CITT-C1)
# =============================================================================
# Usage: citt scan "<prompt>" <app> [--platform android|ios]
#
# Runs a CUSTOM-PROMPT scan: the caller supplies a free-form analysis question
# (<prompt>, the FIRST positional) about an app (<app>, the SECOND positional —
# a package_id like com.foo.bar or a store URL). We POST a custom scan request
# to /api/submit and print the returned scan_id.
#
# Request body (JSON, built with jq into a 0600 temp file):
#   {"package_id":"<app>","platform":"<p>","scan_type":"custom",
#    "prompt":"<prompt>","is_private":true}
# The "platform" key is omitted entirely when --platform is not supplied (the
# backend then applies its own default).
#
# On 200 OR 202: parse `scan_id` from the response, print it to stdout, and
# print a follow-up hint to stderr:  → citt result <scan_id>
#
# SECRET / SENSITIVE-DATA ISOLATION (inherits all invariants from
# citt-common.sh — QA red-teams this):
#   - The auth token NEVER appears on argv, stdout, or in a bash -x xtrace. It
#     is handled ONLY by the shared helpers (_prepare_auth / _curl_auth_post),
#     which load it into a 0600 curl-config file.
#   - The PROMPT NEVER appears on a curl argv: it goes into the JSON body FILE
#     (a 0600 temp file, cleaned up on EXIT), posted via `--data @<file>` by the
#     shared _curl_auth_post — never as an inline -d string or in a URL.
#   - Raw error bodies are NEVER dumped — only sanitized messages.
# =============================================================================

# ---------------------------------------------------------------------------
# _scan_looks_like_app: return 0 if the arg is an unambiguous package_id
# (contains a dot) or a store URL (http/https). v1 requires an id/URL — a bare
# app name is rejected (no fuzzy name resolution).
# ---------------------------------------------------------------------------
_scan_looks_like_app() {
  case "$1" in
    http://*|https://*) return 0 ;;
  esac
  case "$1" in
    *.*) return 0 ;;   # a package_id always contains a dot
    *)   return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# citt_cmd_scan: main entry point (called by the citt dispatcher, or directly).
# $@ = everything after "scan" on the citt command line.
# ---------------------------------------------------------------------------
citt_cmd_scan() {
  local prompt="" app="" platform="" positional_count=0

  # -------- argument parsing -------------------------------------------------
  # First positional = prompt, second positional = app. --platform may appear
  # anywhere. Options with an attached value (--platform=x) or a following value
  # (--platform x) are both supported.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --platform)
        shift
        platform="${1:-}"
        if [ -z "$platform" ]; then
          printf 'citt scan: --platform requires a value (android|ios).\n' >&2
          exit 1
        fi
        ;;
      --platform=*)
        platform="${1#--platform=}"
        ;;
      -h|--help)
        cat >&2 <<'H'
Usage: citt scan "<prompt>" <app> [--platform android|ios]

Runs a custom-prompt scan: ask a free-form analysis question (<prompt>) about an
app (<app> = a package_id like com.foo.bar, or a store URL). Prints the new
scan_id to stdout; follow up with:  citt result <scan_id>. Requires 'citt auth'.
H
        exit 0
        ;;
      --)
        shift
        # Remaining args are positional.
        while [ "$#" -gt 0 ]; do
          if [ "$positional_count" -eq 0 ]; then prompt="$1"
          elif [ "$positional_count" -eq 1 ]; then app="$1"
          else
            printf 'citt scan: unexpected extra argument: %s\n' "$1" >&2
            exit 1
          fi
          positional_count=$((positional_count + 1))
          shift
        done
        break
        ;;
      -*)
        printf 'citt scan: unknown option: %s\n' "$1" >&2
        exit 1
        ;;
      *)
        if [ "$positional_count" -eq 0 ]; then prompt="$1"
        elif [ "$positional_count" -eq 1 ]; then app="$1"
        else
          printf 'citt scan: unexpected extra argument: %s\n' "$1" >&2
          exit 1
        fi
        positional_count=$((positional_count + 1))
        ;;
    esac
    shift 2>/dev/null || break
  done

  # -------- CLIENT-SIDE guards (before any network call) ---------------------
  # Prompt: required, non-empty, ≤ 5000 chars.
  if [ -z "$prompt" ]; then
    printf 'citt scan: a prompt is required — pass your analysis question as the first argument.\n' >&2
    printf '  Usage: citt scan "<prompt>" <package_id|store_url> [--platform android|ios]\n' >&2
    exit 1
  fi
  if [ "${#prompt}" -gt 5000 ]; then
    printf 'citt scan: the prompt is too long (%s chars) — the maximum is 5000.\n' "${#prompt}" >&2
    exit 1
  fi

  # App: required, must look like a package_id or store URL (no fuzzy names).
  if [ -z "$app" ]; then
    printf 'citt scan: an app is required — pass a package_id (com.foo.bar) or a store URL.\n' >&2
    exit 1
  fi
  if ! _scan_looks_like_app "$app"; then
    printf "citt scan: '%s' does not look like a package_id or store URL.\n" "$app" >&2
    printf '  Pass a package_id (e.g. com.foo.bar) or a store URL (https://play.google.com/... or https://apps.apple.com/...).\n' >&2
    exit 1
  fi

  # -------- auth (exits with re-auth hint if no token) -----------------------
  _prepare_auth

  # -------- build the JSON body into a 0600 temp file ------------------------
  # The prompt lives in a FILE, never on a curl argv. Reuse the shared lib's
  # body file (created 0600 at source time, inside _CITT_TMPDIR). Do NOT install
  # a second EXIT trap: bash keeps only one, so overriding it here would orphan
  # the lib's tmpdir — which holds the Bearer-token curl config — on disk. The
  # lib's own _citt_common_cleanup EXIT trap removes this file with the tmpdir.
  local bodyf="${_CITT_BODY_FILE}"

  if command -v jq >/dev/null 2>&1; then
    if [ -n "$platform" ]; then
      jq -n \
        --arg pkg "$app" \
        --arg platform "$platform" \
        --arg prompt "$prompt" \
        '{package_id:$pkg, platform:$platform, scan_type:"custom", prompt:$prompt, is_private:true}' \
        >"$bodyf"
    else
      jq -n \
        --arg pkg "$app" \
        --arg prompt "$prompt" \
        '{package_id:$pkg, scan_type:"custom", prompt:$prompt, is_private:true}' \
        >"$bodyf"
    fi
  else
    # No jq: build JSON with a python fallback (still into the 0600 file; the
    # prompt is passed via env, never on argv).
    if [ -n "$platform" ]; then
      SCAN_PKG="$app" SCAN_PLATFORM="$platform" SCAN_PROMPT="$prompt" python3 -c '
import json, os
obj = {
    "package_id": os.environ["SCAN_PKG"],
    "platform": os.environ["SCAN_PLATFORM"],
    "scan_type": "custom",
    "prompt": os.environ["SCAN_PROMPT"],
    "is_private": True,
}
print(json.dumps(obj))
' >"$bodyf"
    else
      SCAN_PKG="$app" SCAN_PROMPT="$prompt" python3 -c '
import json, os
obj = {
    "package_id": os.environ["SCAN_PKG"],
    "scan_type": "custom",
    "prompt": os.environ["SCAN_PROMPT"],
    "is_private": True,
}
print(json.dumps(obj))
' >"$bodyf"
    fi
  fi

  # -------- POST the custom scan ---------------------------------------------
  local code body scan_id
  code="$(_curl_auth_post "/api/submit" "$bodyf")"
  body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"

  case "$code" in
    200|202)
      scan_id="$(_json_get "scan_id" "$body")"
      if [ -z "$scan_id" ]; then
        emit_err "citt scan: the scan was accepted but no scan_id was returned."
        exit 1
      fi
      # scan_id → stdout (the machine-readable channel).
      printf '%s\n' "$scan_id"
      # Follow-up hint → stderr.
      printf '\xe2\x86\x92 citt result %s\n' "$scan_id" >&2
      exit 0
      ;;
    400)
      emit_err "citt scan: the prompt was rejected (empty or too long — max 5000 chars)."
      exit 1
      ;;
    401)
      _reauth_hint   # exits non-zero
      ;;
    403)
      emit_err "citt scan: custom prompts on apps you don't own need the Research plan."
      exit 1
      ;;
    "")
      emit_err "citt scan: could not reach the CITT API."
      exit 1
      ;;
    *)
      emit_err "citt scan: unexpected HTTP ${code} from /api/submit."
      exit 1
      ;;
  esac
}
