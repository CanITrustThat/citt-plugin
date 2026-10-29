#!/usr/bin/env bash
# lib/cmd-help-requests.sh: citt help-requests (NP-691, RC-54). Lists the help requests of the capture runs the account
# launched (GET /capture-help-requests, NP-685) and with --watch prints each new open request once with its Live page link.
# NP-803: citt help-answer sends a typed answer to an open bring-me-in request (POST /capture-help-requests/{id}/answer).
# NP-832: with --type the text is typed on the phone into the input field on screen ({text, kind: "type"}); it is never printed.
# shellcheck shell=bash disable=SC2016

HR_STATES=" open answered missed expired "

# HR_JQ: jq program printing one open request as one line (needs $L and $links from _hr_links).
HR_JQ="$JQ_LT"'
def live: $links[.id | tostring] // "no live link";
def line: "Help request \(.id): run \(.run_id), session \(.seq), \(.app.package_id) on \(.phone.name // "phone \(.phone.device_id)"): "
  + .trigger_sentence + (if .screen_line then " Screen: \(.screen_line)." else "" end)
  + " Waits until \(.deadline_at | lt). Live page: \(live)"
  + (if .answer_refusal then " The phone typed nothing (\(.answer_refusal)): open the field on the Live page and send the text again." else "" end)
  + (if .answerable == true then " Answer by text: citt help-answer \(.id) \"<your instruction>\" (or --type \"<text for the phone>\")" else "" end);'

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

HA_MAX=1000

# cmd_help_answer ID TEXT: the typed answer to bring-me-in request ID; the session's orchestrator acts on it.
cmd_help_answer() {
  local id="" text="" have_text=0 kind=instruction
  CITT_CMD="citt help-answer"
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) CITT_JSON=1 ;;
      --type)
        [ $# -ge 2 ] || usage_error "--type takes the text the phone types: citt help-answer REQUEST --type \"TEXT\""
        [ "$have_text" = 0 ] || usage_error "one request id and one text; put the text in quotes"
        kind="type"
        text="$2"
        have_text=1
        shift
        ;;
      --help | -h)
        help_help_answer
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        if [ -z "$id" ]; then
          id="$1"
        elif [ "$have_text" = 0 ]; then
          text="$1"
          have_text=1
        else
          usage_error "one request id and one text; put the text in quotes"
        fi
        ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "a help request id is required: citt help-answer REQUEST \"TEXT\""
  { is_uint "$id" && [ "$id" -ge 1 ]; } || usage_error "the help request id is a number (the Id of citt help-requests), got: $id"
  [ "$have_text" = 1 ] || usage_error "the answer text is required: citt help-answer $id \"TEXT\""
  jq -en --arg t "$text" '$t | test("\\S")' >/dev/null 2>&1 || usage_error "the answer text is empty"
  [ "$(jq -rn --arg t "$text" '$t | gsub("^\\s+|\\s+$"; "") | length')" -le "$HA_MAX" ] \
    || usage_error "the answer text is longer than $HA_MAX characters"
  local body
  body="$(tmpfile help_answer_body)"
  if [ "$kind" = type ]; then
    jq -nc --arg t "$text" '{text: ($t | gsub("^\\s+|\\s+$"; "")), kind: "type"}' >"$body"
  else
    jq -nc --arg t "$text" '{text: ($t | gsub("^\\s+|\\s+$"; ""))}' >"$body"
  fi
  need_auth
  # One attempt only: a retried POST could meet its own stored answer and read as answered already.
  # shellcheck disable=SC2034  # read by http in lib/common.sh
  HTTP_RETRY=no
  http POST "$CITT_V1/capture-help-requests/$id/answer" "$body"
  if ok; then
    jq -e '.request.id | type == "number"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from POST $CITT_V1/capture-help-requests/$id/answer"
    if [ "$CITT_JSON" = 1 ]; then
      jq -c . "$RESP"
      return 0
    fi
    if [ "$kind" = type ]; then
      jq -r '.request as $r | "Sent to help request \($r.id) (run \($r.run_id), session \($r.seq)) to type on the phone: \($r.answer_length // 0) characters",
        "The phone types it into the input field on screen at its next step; the request then reads answered."' "$RESP"
      return 0
    fi
    jq -r '.request as $r | "Answer sent to help request \($r.id) (run \($r.run_id), session \($r.seq)): \($r.answer_text)",
      "The session receives it at its next step; the request then reads answered."' "$RESP"
    return 0
  fi
  local error message state link path
  error="$(body_field '.error')"
  message="$(body_field '.message')"
  case "$CODE:$error" in
    404:not_found)
      die 4 "help request $id not found among the help requests of your capture runs; list them: citt help-requests --state open"
      ;;
    409:help_request_closed)
      state="$(body_field '.request.state')"
      die 5 "help request $id is ${state:-closed}; nothing to answer ($message)"
      ;;
    409:help_request_answered)
      if [ "$(body_field '.request.answer_mode')" = type ]; then
        die 5 "help request $id: an answer was sent already: text to type on the phone ($(body_field '.request.answer_length') characters)"
      fi
      die 5 "help request $id: an answer was sent already: $(body_field '.request.answer_text')"
      ;;
    409:answer_not_supported)
      path="$(body_field '.request.live_path')"
      link="no live link"
      [ -z "$path" ] || link="$(app_url "$path")"
      die 5 "help request $id takes no typed answer ($message); take over on the Live page: $link"
      ;;
  esac
  fail_http
}
