#!/usr/bin/env bash
# lib/cmd-mine.sh — `citt mine` subcommand. Lists the authenticated user's
# submitted apps with their latest scan summary and a scan_id for `citt report`.
#
# Ownership: the only client-queryable signal is submission
# (GET /api/apps?my_scans=true), so `citt mine` shows apps the user submitted
# scans for — a proxy for ownership. Email-domain ownership and verified claims
# are server-side only (no GET /api/me/apps endpoint exists yet).
#
# stdout: JSON array (one object per app), newest-scan-first, with fields
# package_id, app_name, scan_id, status, overall_score, security_score,
# privacy_score, recommendation, completed_at, platform.
# stderr: human summary. Secret isolation inherited from citt-common.sh.

# Guard against double-sourcing.
[ "${_CITT_CMD_MINE_LOADED:-}" = "1" ] && return 0
_CITT_CMD_MINE_LOADED=1

citt_cmd_mine() {
  _prepare_auth   # exits non-zero with re-auth hint if no token

  # Paginate through all the user's submitted apps (max 100 per page).
  local page_limit=100
  local offset=0
  local total_fetched=0
  local all_apps_json="[]"
  local first_page=1

  while true; do
    local path="/api/apps?my_scans=true&scan_type=full&limit=${page_limit}&offset=${offset}"
    local code body

    code="$(_curl_auth_get "${path}")"

    case "$code" in
      200)
        body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"
        ;;
      401)
        _reauth_hint   # exits non-zero
        ;;
      "")
        emit_err "citt mine: could not reach the CITT API"
        exit 1
        ;;
      *)
        emit_err "citt mine: unexpected HTTP ${code} from ${path}"
        exit 1
        ;;
    esac

    # Extract total and apps array from the page response.
    local page_total page_apps_json page_count
    page_total="$(_json_get "total" "$body")"

    if command -v jq >/dev/null 2>&1; then
      page_apps_json="$(printf '%s' "$body" | jq -c '.apps // []' 2>/dev/null || printf '[]')"
      page_count="$(printf '%s' "$page_apps_json" | jq 'length' 2>/dev/null || printf '0')"
    else
      page_apps_json="$(printf '%s' "$body" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(json.dumps(d.get('apps',[])))
" 2>/dev/null || printf '[]')"
      page_count="$(printf '%s' "$page_apps_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || printf '0')"
    fi

    if [ "$first_page" -eq 1 ]; then
      all_apps_json="$page_apps_json"
      first_page=0
    else
      # Merge subsequent pages.
      if command -v jq >/dev/null 2>&1; then
        all_apps_json="$(printf '%s\n%s' "$all_apps_json" "$page_apps_json" \
          | jq -cs 'add // []' 2>/dev/null || printf '%s' "$all_apps_json")"
      else
        all_apps_json="$(python3 -c "
import sys,json
lines=sys.stdin.read().strip().split('\n')
merged=[]
for l in lines:
    try: merged.extend(json.loads(l))
    except: pass
print(json.dumps(merged))
" <<EOF
${all_apps_json}
${page_apps_json}
EOF
)"
      fi
    fi

    total_fetched=$((total_fetched + page_count))

    # Stop if we got fewer than the page size (last page).
    if [ "$page_count" -lt "$page_limit" ]; then
      break
    fi

    # Stop if we've fetched everything the server said exists.
    if [ -n "$page_total" ] && [ "$total_fetched" -ge "$page_total" ]; then
      break
    fi

    offset=$((offset + page_limit))
  done

  # Transform the raw API response into the canonical citt mine output shape.
  # scan_id is the list row's top-level id field.
  local output_json
  if command -v jq >/dev/null 2>&1; then
    output_json="$(printf '%s' "$all_apps_json" | jq -c '
      [.[] | {
        package_id:    .package_id,
        app_name:      .app_name,
        scan_id:       .id,
        status:        (.status // "unknown"),
        overall_score: .overall_score,
        security_score: .security_score,
        privacy_score:  .privacy_score,
        recommendation: .recommendation,
        completed_at:   .completed_at,
        platform:      (.platform // "android")
      }]
    ' 2>/dev/null || printf '%s' "$all_apps_json")"
  else
    output_json="$(printf '%s' "$all_apps_json" | python3 -c "
import sys,json
apps=json.load(sys.stdin)
out=[]
for a in apps:
    out.append({
        'package_id':    a.get('package_id'),
        'app_name':      a.get('app_name'),
        'scan_id':       a.get('id'),
        'status':        a.get('status','unknown'),
        'overall_score': a.get('overall_score'),
        'security_score': a.get('security_score'),
        'privacy_score':  a.get('privacy_score'),
        'recommendation': a.get('recommendation'),
        'completed_at':   a.get('completed_at'),
        'platform':      a.get('platform','android'),
    })
print(json.dumps(out))
" 2>/dev/null || printf '%s' "$all_apps_json")"
  fi

  # Count for the human summary.
  local app_count
  if command -v jq >/dev/null 2>&1; then
    app_count="$(printf '%s' "$output_json" | jq 'length' 2>/dev/null || printf '0')"
  else
    app_count="$(printf '%s' "$output_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || printf '0')"
  fi

  # Emit JSON to stdout (the Claude tool output channel).
  emit_json "$output_json"

  # Human summary to stderr.
  if [ "$app_count" -eq 0 ]; then
    emit_err "citt mine: no submitted apps found."
  else
    emit_err "citt mine: ${app_count} app(s) found."
  fi
  emit_err "note: lists apps you submitted scans for (proxy for ownership)."
  emit_err "      email-domain ownership and verified claims require a dedicated"
  emit_err "      GET /api/me/apps backend endpoint (not yet implemented)."
  emit_err "      Use 'citt report <package_id>' to fetch the full scorecard."
}
