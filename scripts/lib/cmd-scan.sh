#!/usr/bin/env bash
# lib/cmd-scan.sh — `citt scan` subcommand.
# Usage: citt scan "<prompt>" <app> [--platform android|ios]
# POSTs a custom-prompt scan to /api/submit and prints the returned scan_id.
# Secret isolation: token and prompt never hit argv/stdout/xtrace — token via
# shared 0600 curl-config helpers, prompt via a 0600 JSON body file.

# _scan_looks_like_app: return 0 if the arg is a package_id (has a dot) or a
# store URL. A bare app name is rejected (no fuzzy name resolution).
_scan_looks_like_app() {
  case "$1" in
    http://*|https://*) return 0 ;;
  esac
  case "$1" in
    *.*) return 0 ;;   # a package_id always contains a dot
    *)   return 1 ;;
  esac
}

# citt_cmd_scan: entry point. $@ = args after "scan".
citt_cmd_scan() {
  local prompt="" app="" platform="" positional_count=0

  # First positional = prompt, second = app. --platform anywhere, as
  # --platform x or --platform=x.
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

  # Client-side guards. Prompt: required, non-empty, <= 5000 chars.
  if [ -z "$prompt" ]; then
    printf 'citt scan: a prompt is required — pass your analysis question as the first argument.\n' >&2
    printf '  Usage: citt scan "<prompt>" <package_id|store_url> [--platform android|ios]\n' >&2
    exit 1
  fi
  if [ "${#prompt}" -gt 5000 ]; then
    printf 'citt scan: the prompt is too long (%s chars) — the maximum is 5000.\n' "${#prompt}" >&2
    exit 1
  fi

  # App: required, must look like a package_id or store URL.
  if [ -z "$app" ]; then
    printf 'citt scan: an app is required — pass a package_id (com.foo.bar) or a store URL.\n' >&2
    exit 1
  fi
  if ! _scan_looks_like_app "$app"; then
    printf "citt scan: '%s' does not look like a package_id or store URL.\n" "$app" >&2
    printf '  Pass a package_id (e.g. com.foo.bar) or a store URL (https://play.google.com/... or https://apps.apple.com/...).\n' >&2
    exit 1
  fi

  # Auth (exits with re-auth hint if no token).
  _prepare_auth

  # Build the JSON body into the shared lib's 0600 body file (prompt never on
  # argv). Do NOT install a second EXIT trap — bash keeps only one, so it would
  # orphan the lib's tmpdir (which holds the Bearer-token curl config) on disk.
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
    # No jq: python fallback (prompt passed via env, never on argv).
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

  # POST the custom scan.
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
      # scan_id -> stdout; follow-up hint -> stderr.
      printf '%s\n' "$scan_id"
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
