#!/usr/bin/env bash
# lib/cmd-help-requests.sh: citt help-requests (NP-691, RC-54). Lists the help requests of the capture runs the account
# launched (GET /capture-help-requests, NP-685) and with --watch prints each new open request once with its Live page link.
# shellcheck shell=bash disable=SC2016

HR_STATES=" open answered missed expired "

# HR_JQ: jq program printing one open request as one line (needs $L and $links from _hr_links).
HR_JQ="$JQ_LT"'
def live: $links[.id | tostring] // "no live link";
def line: "Help request \(.id): run \(.run_id), session \(.seq), \(.app.package_id) on \(.phone.name // "phone \(.phone.device_id)"): "
  + .trigger_sentence + (if .screen_line then " Screen: \(.screen_line)." else "" end)
  + " Waits until \(.deadline_at | lt). Live page: \(live)";'

# _hr_links FILE: a JSON object mapping each request id in FILE to its Live page URL (app_url of `live_path`); a request
# without `live_path` is left out, and prints "no live link".
_hr_links() {
  local id path
  jq -r '.requests[] | select(.live_path != null and .live_path != "") | "\(.id)\t\(.live_path)"' "$1" | while IFS=$'\t' read -r id path; do
    jq -nc --arg k "$id" --arg v "$(app_url "$path")" '{($k): $v}'
  done | jq -sc 'add // {}'
}

cmd_help_requests() {
  local states="" limit="" watch=0 timeout=540 s
  CITT_CMD="citt help-requests"
  while [ $# -gt 0 ]; do
    case "$1" in
      --state | --limit | --timeout)
        need_value "$1" $#
        case "$1" in
          --state) states="$2" ;;
          --limit) limit="$2" ;;
          --timeout) timeout="$2" ;;
        esac
        shift
        ;;
      --watch) watch=1 ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_help_requests
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  if [ "$watch" = 1 ]; then
    { [ -z "$states" ] && [ -z "$limit" ]; } || usage_error "--watch lists open requests only; leave out --state and --limit"
    need_auth
    _hr_watch "$timeout"
    return
  fi
  if [ -n "$states" ]; then
    for s in ${states//,/ }; do
      case "$HR_STATES" in *" $s "*) ;; *) usage_error "--state takes a comma list of open, answered, missed and expired, got: $states" ;; esac
    done
  fi
  [ -n "$limit" ] || limit=50
  { is_uint "$limit" && [ "$limit" -ge 1 ] && [ "$limit" -le 200 ]; } || usage_error "--limit takes 1 to 200, got: $limit"
  need_auth
  call GET "$CITT_V1/capture-help-requests$(query state "$states" limit "$limit")"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  jq -e '.requests | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unparseable response from GET $CITT_V1/capture-help-requests"
  printf 'Open help requests: %s\n' "$(jq -r '.open_count // 0' "$RESP")"
  if [ "$(jq '.requests | length' "$RESP")" = 0 ]; then
    printf 'No help requests.\n'
    return 0
  fi
  jq -c --argjson L "$(local_times "$RESP")" --argjson links "$(_hr_links "$RESP")" "$HR_JQ"'
    [["Id", "Opened", "State", "Run", "Session", "App", "Phone", "Reason", "Waits until", "Live page"]]
    + [.requests[] | [.id, (.opened_at | lt), .state, .run_id, .seq, .app.package_id, (.phone.name // "-"), .trigger,
        (.deadline_at | lt), (if .state == "open" then live else "-" end)]]' "$RESP" | table
}

# _hr_watch TIMEOUT: polls the open requests every 15 s; prints each one not printed before and exits 16, or exits 12 at
# TIMEOUT. The seen file holds the printed ids that are still open, one per line.
_hr_watch() {
  local timeout="$1" start left seen_file seen new
  seen_file="$CITT_STATE/help-requests/seen"
  (umask 077 && mkdir -p "$CITT_STATE/help-requests")
  start="$(now_s)"
  while :; do
    call GET "$CITT_V1/capture-help-requests?state=open&limit=200"
    jq -e '.requests | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unparseable response from GET $CITT_V1/capture-help-requests"
    seen='[]'
    [ ! -f "$seen_file" ] || seen="$(jq -R -s -c 'split("\n") | map(select(test("^[0-9]+$")) | tonumber)' "$seen_file")"
    new="$(jq -c --argjson seen "$seen" '[.requests[] | select(.state == "open") | select(.id as $i | $seen | index($i) | not)]' "$RESP")"
    # Keep the ids printed now or before whose requests are still in the open list.
    # A temp file of its own per write (mktemp, mode 0600), so watchers on one state directory never share one.
    (umask 077 && t="$(mktemp "$seen_file.XXXXXX")" && jq -r --argjson seen "$seen" --argjson new "$new" \
      '[.requests[].id] as $open | ($seen + [$new[].id]) | unique | map(select(. as $i | $open | index($i)))[]' "$RESP" \
      >"$t" && mv "$t" "$seen_file")
    if [ "$new" != "[]" ]; then
      if [ "$CITT_JSON" = 1 ]; then
        jq -c '.[]' <<<"$new"
      else
        jq -r --argjson L "$(local_times "$RESP")" --argjson links "$(_hr_links "$RESP")" "$HR_JQ"' .[] | line' <<<"$new"
      fi
      err "$CITT_CMD: give each Live page link to the user, then re-run: citt help-requests --watch"
      return 16
    fi
    left=$((timeout - ($(now_s) - start)))
    [ "$left" -gt 0 ] || break
    poll_sleep "" "$left"
  done
  err "$CITT_CMD: no new open help request after $timeout s; re-run: citt help-requests --watch"
  return 12
}
