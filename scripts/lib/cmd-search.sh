#!/usr/bin/env bash
# =============================================================================
# lib/cmd-search.sh — `citt search` subcommand (CITT-338)
# =============================================================================
# Sourced by the `citt` dispatcher when the user runs `citt search`.
# Exposes: citt_cmd_search()
#
# Usage: citt search <query> [--platform android|ios] [--limit N]
#
# Calls GET /api/search-apps?q=<query>&platform=<p>&limit=<n>&offset=0
# This is a PUBLIC endpoint (no auth required). Uses _curl_pub_get from the
# shared lib. If a token is present it stays in the 0600 curl-config file and
# is never sent on this call (pub helper uses a plain curl without --config).
#
# Output contract:
#   stdout — JSON array of result items for Claude (structured tool output)
#   stderr — human summary (result count, query, platform)
#
# Query constraints verified from src/api.py:
#   q:        required, min_length=1, max_length=200
#   platform: "android" or "ios" (default "android")
#   limit:    ge=1, le=50 (default 20)
#   offset:   ge=0 (always 0 for this command — no pagination arg exposed)
#
# Result item fields (from api.py search_apps_endpoint response):
#   package_id, app_name, developer, icon_url, rating, downloads,
#   store_url, platform, scanned, overall_score, status,
#   app_description, recommendation,
#   critical_findings_count, high_findings_count,
#   medium_findings_count, low_findings_count
#
# Pairs naturally with: citt results <pkg>
# =============================================================================

# Guard: this file must be sourced, not executed directly.
# The shared lib (_curl_pub_get, emit_json, emit_err, _json_get, _CITT_API,
# _CITT_RESP_FILE) is already sourced by the dispatcher before sourcing us.

# ---------------------------------------------------------------------------
# _urlenc_search: percent-encode a query string safely via python3.
# The query is read from a temp file (never passed as argv to python) to guard
# against any unusual characters. Falls back to a conservative passthrough when
# python3 is unavailable (package IDs are already safe; arbitrary queries may
# not be, but the fallback is last-resort only).
# ---------------------------------------------------------------------------
_urlenc_search() {  # $1 = raw query string  -> percent-encoded on stdout
  local raw="$1"
  if command -v python3 >/dev/null 2>&1; then
    # Pass the string via stdin (not argv) so no shell expansion/injection.
    printf '%s' "$raw" | python3 -c \
      'import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(sys.stdin.read(), safe=""))'
  else
    # Minimal fallback: replace spaces with + (good enough for ASCII queries).
    printf '%s' "$raw" | sed 's/ /+/g'
  fi
}

# ---------------------------------------------------------------------------
# citt_cmd_search: the public search subcommand.
# ---------------------------------------------------------------------------
citt_cmd_search() {
  # ------------------------------------------------------------------
  # Arg parsing
  # ------------------------------------------------------------------
  local query=""
  local platform="android"
  local limit="20"
  local arg

  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --platform)
        shift
        platform="${1:-}"
        if [ -z "$platform" ]; then
          emit_err "citt search: --platform requires a value (android or ios)"
          exit 2
        fi
        shift
        ;;
      --platform=*)
        platform="${arg#--platform=}"
        shift
        ;;
      --limit)
        shift
        limit="${1:-}"
        if [ -z "$limit" ]; then
          emit_err "citt search: --limit requires a value (1..50)"
          exit 2
        fi
        shift
        ;;
      --limit=*)
        limit="${arg#--limit=}"
        shift
        ;;
      --help|-h)
        printf 'Usage: citt search <query> [--platform android|ios] [--limit N]\n' >&2
        printf '\n' >&2
        printf '  Search public app index (no login required).\n' >&2
        printf '  --platform   android (default) or ios\n' >&2
        printf '  --limit      1..50 results (default 20)\n' >&2
        printf '\n' >&2
        printf 'Pairs with: citt results <package_id>\n' >&2
        exit 0
        ;;
      -*)
        emit_err "citt search: unknown option: $arg"
        exit 2
        ;;
      *)
        if [ -z "$query" ]; then
          query="$arg"
        else
          # Treat extra positional args as additional query words
          query="$query $arg"
        fi
        shift
        ;;
    esac
  done

  # ------------------------------------------------------------------
  # Validate query
  # ------------------------------------------------------------------
  if [ -z "$query" ]; then
    emit_err "citt search: query argument required"
    emit_err "Usage: citt search <query> [--platform android|ios] [--limit N]"
    exit 2
  fi

  local qlen="${#query}"
  if [ "$qlen" -gt 200 ]; then
    emit_err "citt search: query too long (max 200 characters)"
    exit 2
  fi

  # ------------------------------------------------------------------
  # Validate platform
  # ------------------------------------------------------------------
  case "$platform" in
    android|ios) : ;;
    *)
      emit_err "citt search: invalid platform '$platform' (use: android or ios)"
      exit 2
      ;;
  esac

  # ------------------------------------------------------------------
  # Validate limit (api.py: ge=1, le=50)
  # ------------------------------------------------------------------
  case "$limit" in
    ''|*[!0-9]*)
      emit_err "citt search: --limit must be a positive integer (1..50)"
      exit 2
      ;;
  esac
  if [ "$limit" -lt 1 ] || [ "$limit" -gt 50 ]; then
    emit_err "citt search: --limit must be between 1 and 50 (got $limit)"
    exit 2
  fi

  # ------------------------------------------------------------------
  # Build the query string (URL-encode the query — spaces, special chars)
  # ------------------------------------------------------------------
  local enc_q
  enc_q="$(_urlenc_search "$query")"

  local path="/api/search-apps?q=${enc_q}&platform=${platform}&limit=${limit}&offset=0"

  # ------------------------------------------------------------------
  # Make the public (unauthenticated) GET request.
  # _curl_pub_get writes body to $_CITT_RESP_FILE and prints HTTP code.
  # ------------------------------------------------------------------
  local code
  code="$(_curl_pub_get "$path")"

  case "$code" in
    200)
      local body
      body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"

      # Extract the results array for Claude's structured output.
      # api.py returns: {"results":[...], "total":N, "has_more":bool}
      # We emit the results array to stdout (structured JSON for Claude).
      local results_json total has_more
      if command -v jq >/dev/null 2>&1; then
        results_json="$(printf '%s' "$body" | jq -er '.results // []' 2>/dev/null || printf '[]')"
        total="$(printf '%s' "$body" | jq -er '.total // 0' 2>/dev/null || printf '0')"
        has_more="$(printf '%s' "$body" | jq -er '.has_more // false' 2>/dev/null || printf 'false')"
      else
        # Minimal fallback: try to extract the results array via python3
        if command -v python3 >/dev/null 2>&1; then
          results_json="$(printf '%s' "$body" | python3 -c \
            'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("results",[])))'  \
            2>/dev/null || printf '[]')"
          total="$(printf '%s' "$body" | python3 -c \
            'import json,sys; d=json.load(sys.stdin); print(d.get("total",0))' \
            2>/dev/null || printf '0')"
          has_more="$(printf '%s' "$body" | python3 -c \
            'import json,sys; d=json.load(sys.stdin); print("true" if d.get("has_more") else "false")' \
            2>/dev/null || printf 'false')"
        else
          # Last resort: emit the raw body (it is valid JSON) and let Claude parse it
          results_json="$(printf '%s' "$body" | grep -o '"results"\s*:\s*\[.*\]' | head -n1 || printf '[]')"
          total="$(_json_get total "$body")"
          has_more="false"
        fi
      fi

      # Human summary to stderr
      if [ "${total:-0}" -eq 0 ] 2>/dev/null; then
        emit_err "citt search: 0 results for '$query' on $platform"
      else
        local has_more_note=""
        [ "$has_more" = "true" ] && has_more_note=" (more available — use a higher --limit)"
        emit_err "citt search: ${total} result(s) for '$query' on $platform${has_more_note}"
      fi

      # Structured JSON to stdout for Claude
      emit_json "$results_json"
      ;;
    "")
      emit_err "citt search: could not reach the CITT API"
      exit 1
      ;;
    *)
      emit_err "citt search: unexpected HTTP $code from /api/search-apps"
      exit 1
      ;;
  esac
}
