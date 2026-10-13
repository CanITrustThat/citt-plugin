#!/usr/bin/env bash
# lib/cmd-status.sh: citt status.
# shellcheck shell=bash disable=SC2034

# The human status from the body in $RESP.
_status_text() {
  jq -r '
    def nonzero: to_entries | map(select(.value != 0 and .value != null));
    # Capture-only apps never get a static scan, so they leave the settled total.
    (.apps_by_status.not_requested // 0) as $capture |
    "Project \(.name) (id \(.project_id)): \(.apps_settled) of \(.apps_total - $capture) apps settled",
    (if $capture > 0 then
       "Static scan not requested: \($capture) capture-only app\(if $capture == 1 then "" else "s" end); the settled count covers static-scan apps only."
     else empty end),
    "Apps: " + (.apps_by_status | nonzero | map("\(.key) \(.value)") | join(", ")),
    "Jobs: " + ((.jobs // {}) | to_entries | map(select(.value | nonzero | length > 0)) | map(
        .key + " " + (.value | nonzero | map("\(.key) \(.value)") | join(", "))) | join("; ")),
    (if (.failures // []) | length > 0 then
       "Failures (\(.failures | length)):"
     else empty end)' "$RESP" || die 1 "unparseable status response"
  if [ "$(jq '.failures // [] | length' "$RESP")" -gt 0 ]; then
    jq -c '[.failures[] | [.package_id, .kind,
      "\(.error // "-") (\(.failure_class // "unknown")\(if .refunded then ", refunded" else "" end))"]]' "$RESP" \
      | table | sed 's/^/  /'
  fi
}

cmd_status() {
  local wait=0 timeout=540 n
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --wait) wait=1 ;;
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_status
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  check_project_flags optional
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  need_auth
  resolve_project
  local start polls=0 active settled
  start="$(now_s)"
  while :; do
    call GET "$CITT_V1/projects/$PROJECT_ID/status"
    polls=$((polls + 1))
    active="$(jq -r '.jobs_active // 0' "$RESP" 2>/dev/null)" || die 1 "unparseable status response"
    settled=false
    [ "$active" = 0 ] && settled=true
    if [ "$wait" = 0 ] || [ "$settled" = true ] || [ $(($(now_s) - start)) -ge "$timeout" ]; then
      break
    fi
    poll_sleep "$(jq -r '.poll_after_seconds // empty' "$RESP")"
  done
  if [ "$CITT_JSON" = 1 ]; then
    if [ "$wait" = 1 ]; then
      jq -c --argjson p "$polls" --argjson s "$settled" \
        '{schema: "citt.plugin.status/1", polls: $p, settled: $s, status: .}' "$RESP"
    else
      cat "$RESP"
      printf '\n'
    fi
  else
    _status_text
  fi
  if [ "$wait" = 1 ] && [ "$settled" = false ]; then
    err "citt status: still running after $timeout s; re-run: citt status$(project_arg) --wait"
    exit 12
  fi
  return 0
}
