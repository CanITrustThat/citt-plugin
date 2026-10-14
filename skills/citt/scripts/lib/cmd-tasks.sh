#!/usr/bin/env bash
# lib/cmd-tasks.sh: citt tasks and citt task (DESIGN-native-and-tasks B3, B5). A task is one
# submission: a scan request, an Ask of N questions, a thread turn, a kids check, a capture run or
# group, an export, a native code run, a legacy scan.
# shellcheck shell=bash disable=SC2034,SC2016,SC2153

TASK_KINDS=" rule_scan deep_scan question thread_turn kids_check capture capture_group export native_code legacy_scan "

# JQ_TASK: `tstatus` (partial is "done with gaps", the dashboard's words), `tprog` ("7/21 binaries"),
# `tstate` (status and progress), `tdur` (start to end, or to now while active).
JQ_TASK="$JQ_LT$JQ_NEXT"'
def tstatus: if . == "partial" then "done with gaps" else . end;
def tprog: if .progress != null and (.progress.total // 0) > 0
  then " \(.progress.done)/\(.progress.total) \(.progress.label)" + (if (.progress.failed // 0) > 0 then " (\(.progress.failed) failed)" else "" end)
  else "" end;
def tstate: "\(.status | tstatus)\(tprog)";
def tdur($now): if .status == "queued" then "-"
  else (((.finished_at | if . == null then $now else ts end) - ((.started_at // .submitted_at) | ts)) | if . < 0 then 0 else . end | dur) end;
def tqueue: if .queue == null then null
  else [ (if .queue.note then .queue.note else empty end),
         (if .queue.position then "place \(.queue.position) in the queue" else empty end),
         (if .queue.ahead then "\(.queue.ahead) ahead" else empty end),
         (if .queue.eta_at and ((.queue.note // "") | test("offline") | not) then "about \(.queue.eta_at | lt)" else empty end) ] | if length == 0 then null else join(", ") end end;'

# --- citt tasks ----------------------------------------------------------------------------

cmd_tasks() {
  local app="" platform="" kinds="" status="" mine=0 watch=0 limit="" cursor="" timeout=540 path q k a rerun="citt tasks"
  CITT_CMD="citt tasks"
  for a in "$@"; do
    case "$a" in --watch | --json) ;; *) rerun="$rerun $(shq "$a")" ;; esac
  done
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    k=$?
    if [ "$k" -gt 0 ]; then
      shift "$k"
      continue
    fi
    case "$1" in
      --app)
        need_value "$1" $#
        app="$2"
        shift
        ;;
      --platform)
        need_value "$1" $#
        platform="$2"
        shift
        ;;
      --kind)
        need_value "$1" $#
        kinds="$kinds${kinds:+,}$2"
        shift
        ;;
      --running)
        [ "$status" != failed ] || usage_error "use --running or --failed, not both"
        status=active
        ;;
      --failed)
        [ "$status" != active ] || usage_error "use --running or --failed, not both"
        status=failed
        ;;
      --mine) mine=1 ;;
      --watch) watch=1 ;;
      --limit)
        need_value "$1" $#
        limit="$2"
        shift
        ;;
      --cursor)
        need_value "$1" $#
        cursor="$2"
        shift
        ;;
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_tasks
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  project_flag_or_id
  case "$platform" in '' | android | ios) ;; *) usage_error "--platform is android or ios, got: $platform" ;; esac
  [ -z "$platform" ] || [ -n "$app" ] || usage_error "--platform goes with --app"
  for k in $(printf '%s' "$kinds" | tr ',' ' '); do
    case "$TASK_KINDS" in *" $k "*) ;; *) usage_error "unknown kind $k; kinds:$(printf '%s' "$TASK_KINDS" | sed 's/ $//')" ;; esac
  done
  if [ -n "$limit" ]; then
    if ! is_uint "$limit" || [ "$limit" -lt 1 ] || [ "$limit" -gt 100 ]; then usage_error "--limit is 1 to 100"; fi
  fi
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  [ "$watch" = 0 ] || [ -z "$cursor" ] || usage_error "--watch follows the first page; drop --cursor"
  need_auth
  if [ -n "$app" ]; then
    resolve_project
    resolve_app "$app" "$platform"
    path="$CITT_V1/project-apps/$APP_ID/tasks"
  elif [ -n "$OPT_PROJECT" ] || [ -n "$OPT_PROJECT_ID" ]; then
    resolve_project
    path="$CITT_V1/projects/$PROJECT_ID/tasks"
  else
    # No project: every project of the account (GET /tasks).
    path="$CITT_V1/tasks"
  fi
  E_KIND=project
  q="$(query kind "$kinds" status "$status" mine "$([ "$mine" = 1 ] && printf true)" limit "$limit" cursor "$cursor")"
  call GET "$path$q"
  jq -e '.tasks | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unparseable response from GET $path"

  if [ "$watch" = 1 ]; then
    _tasks_watch "$path$q" "$timeout" "$rerun --watch"
    return
  fi
  if [ "$CITT_JSON" = 1 ]; then
    jq -c '{schema: "citt.plugin.tasks/1", tasks, next_cursor}' "$RESP"
    return 0
  fi
  _tasks_table "$RESP" "$status"
  local next
  next="$(body_field '.next_cursor')"
  [ -z "$next" ] || printf 'More: %s --cursor %s\n' "$(printf '%s' "$rerun" | sed 's/ --cursor [^ ]*//')" "$next"
}

# _tasks_table FILE STATUS_FILTER: the table, then a line per failed task and per queued task with a
# queue place or estimate.
_tasks_table() {
  local L
  L="$(local_times "$1")"
  if [ "$(jq '.tasks | length' "$1")" = 0 ]; then
    case "$2" in
      active) printf 'No task is queued or running.\n' ;;
      failed) printf 'No failed tasks.\n' ;;
      *) printf 'No tasks.\n' ;;
    esac
    return 0
  fi
  jq -c --argjson L "$L" --argjson now "$(now_s)" "$JQ_TASK"'
    def cut($n): if length > $n then .[0:$n - 3] + "..." else . end;
    [["TASK", "KIND", "WHAT", "STATUS", "BY", "SUBMITTED", "DURATION"]]
    + [.tasks[] | [.task_id, .kind_label, (.title | cut(48)), tstate,
        "\(.submitted_by.name) via \(.source)", (.submitted_at | lt), tdur($now)]]' "$1" | table
  local notes
  notes="$(jq -r --argjson L "$L" --arg h "$CITT_APP_HOST" "$JQ_TASK"'
    .tasks[]
    | if .error != null then "Task \(.task_id) \(.status | tstatus): \(.error.reason)"
        + (if .error.next_action then "; next: " + (.error.next_action | next_line($h)) else "" end)
      elif (.status == "queued" or .status == "running") and tqueue != null then "Task \(.task_id): \(tqueue)"
      else empty end' "$1")"
  [ -z "$notes" ] || printf '\n%s\n' "$notes"
}

# _tasks_watch PATH_QUERY TIMEOUT RERUN: prints the table, then a line per task whose state changes,
# until no task of the page is queued or running.
_tasks_watch() {
  local pq="$1" timeout="$2" rerun="$3" start left polls=0 prev cur active line id gone L
  prev="$(tmpfile tasks_prev)"
  cur="$(tmpfile tasks_cur)"
  cp "$RESP" "$cur"
  [ "$CITT_JSON" = 1 ] || _tasks_table "$cur" ""
  start="$(now_s)"
  while :; do
    active="$(jq '[.tasks[] | select(.status == "queued" or .status == "running")] | length' "$cur")"
    [ "$active" -gt 0 ] || break
    left=$((timeout - ($(now_s) - start)))
    [ "$left" -gt 0 ] || break
    poll_sleep "" "$left"
    cp "$cur" "$prev"
    call GET "$pq"
    polls=$((polls + 1))
    cp "$RESP" "$cur"
    jq -e '.tasks | type == "array"' "$cur" >/dev/null 2>&1 || die 1 "unparseable response from GET ${pq%%\?*}"
    [ "$CITT_JSON" != 1 ] || continue
    L="$(local_times "$cur")"
    # Changed and new rows.
    jq -r --argjson L "$L" --slurpfile p "$prev" "$JQ_TASK"'
      ($p[0].tasks | map({key: (.task_id | tostring), value: "\(.status)|\(.progress)"}) | from_entries) as $old
      | .tasks[] | select($old[.task_id | tostring] != "\(.status)|\(.progress)")
      | "Task \(.task_id): \(tstate)" + (if $old[.task_id | tostring] == null then " (new: \(.title))" else "" end)
        + (if .error != null then ": \(.error.reason)" else "" end)
        + (if (.status == "queued" or .status == "running") and tqueue != null then "; \(tqueue)" else "" end)' "$cur"
    # Rows that left the page (a --running list drops a task once it ends): their end state.
    gone="$(jq -r --slurpfile c "$cur" '($c[0].tasks | map(.task_id)) as $now
      | .tasks[] | select(.status == "queued" or .status == "running") | .task_id | select(. as $i | $now | index($i) | not)' "$prev")"
    for id in $gone; do
      http GET "$CITT_V1/tasks/$id"
      ok || continue
      line="$(jq -r --argjson L "$(local_times "$RESP")" "$JQ_TASK"' "Task \(.task_id): \(tstate)" + (if .error != null then ": \(.error.reason)" else "" end)' "$RESP")"
      printf '%s\n' "$line"
    done
  done
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --argjson polls "$polls" --argjson ended "$([ "$active" -gt 0 ] && printf false || printf true)" \
      '{schema: "citt.plugin.tasks/1", polls: $polls, ended: $ended, tasks, next_cursor}' "$cur"
  fi
  if [ "$active" -gt 0 ]; then
    err "$CITT_CMD: $active task$([ "$active" = 1 ] || printf s) still queued or running after $timeout s; re-run: $rerun"
    exit 12
  fi
  [ "$CITT_JSON" = 1 ] || printf 'No task of the list is queued or running.\n'
}

# --- citt task -----------------------------------------------------------------------------

cmd_task() {
  local id="" watch=0 cancel=0 timeout=540 a
  CITT_CMD="citt task"
  while [ $# -gt 0 ]; do
    case "$1" in
      --watch) watch=1 ;;
      --cancel) cancel=1 ;;
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_task
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$id" ] || usage_error "one task at a time; got $id and $1"
        id="$1"
        ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "give the task id (see: citt tasks)"
  is_uint "$id" || usage_error "the task id is a number, got: $id"
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  need_auth
  local doc st start left polls=0 shown=0 code=0 line last=""
  doc="$(tmpfile task_doc)"
  _task_get "$id" "$doc"
  if [ "$cancel" = 1 ]; then
    _task_cancel "$id" "$doc"
  fi
  if [ "$watch" != 1 ]; then
    if [ "$CITT_JSON" = 1 ]; then
      jq -c '{schema: "citt.plugin.task/1", task: .}' "$doc"
    elif [ "$cancel" != 1 ]; then
      _task_print "$doc"
    fi
    return 0
  fi
  [ "$CITT_JSON" = 1 ] || [ "$cancel" = 1 ] || _task_print "$doc"
  shown="$(jq '.timeline | length' "$doc")"
  st="$(jq -r .status "$doc")"
  last="$(jq -r --argjson L "$(local_times "$doc")" "$JQ_TASK"' "Task \(.task_id): \(tstate)" + (if tqueue != null then "; \(tqueue)" else "" end)' "$doc")"
  start="$(now_s)"
  while [ "$st" = queued ] || [ "$st" = running ]; do
    left=$((timeout - ($(now_s) - start)))
    [ "$left" -gt 0 ] || break
    poll_sleep "" "$left"
    _task_get "$id" "$doc"
    polls=$((polls + 1))
    st="$(jq -r .status "$doc")"
    [ "$CITT_JSON" != 1 ] || continue
    # New timeline events, then the state.
    jq -r --argjson L "$(local_times "$doc")" --argjson from "$shown" "$JQ_TASK"' .timeline[$from:][] | "\(.at | lt)  \(.label)"' "$doc"
    shown="$(jq '.timeline | length' "$doc")"
    line="$(jq -r --argjson L "$(local_times "$doc")" "$JQ_TASK"' "Task \(.task_id): \(tstate)" + (if tqueue != null then "; \(tqueue)" else "" end)' "$doc")"
    [ "$line" = "$last" ] || printf '%s\n' "$line"
    last="$line"
  done
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --argjson polls "$polls" '{schema: "citt.plugin.task/1", polls: $polls, ended: (.status != "queued" and .status != "running"), task: .}' "$doc"
  fi
  case "$st" in
    queued | running)
      err "$CITT_CMD: task $id is still $st after $timeout s; re-run: citt task $id --watch"
      exit 12
      ;;
    partial)
      err "$CITT_CMD: task $id ended done with gaps: $(jq -r '.error.reason // "some parts failed"' "$doc")"
      code=13
      ;;
    failed)
      err "$CITT_CMD: task $id failed: $(jq -r '.error.reason // "no reason given"' "$doc")"
      code=8
      ;;
    cancelled)
      err "$CITT_CMD: task $id was cancelled"
      code=14
      ;;
  esac
  [ "$CITT_JSON" = 1 ] || [ "$polls" = 0 ] || _task_result "$doc"
  exit "$code"
}

# _task_cancel ID FILE: POST /tasks/ID/cancel, then the task into FILE. 404 is "no task", 409 (the task has
# ended, or its kind has no cancel) exits 5 with the service's reason. A native code run that legacy has to
# stop ends within seconds; until then the task reads "cancel requested".
_task_cancel() {
  local id="$1" out="$2"
  HTTP_RETRY=no
  http POST "$CITT_V1/tasks/$id/cancel"
  case "$CODE" in
    2??) ;;
    404) [ -z "$(body_field '.error')" ] && fail_http; die 4 "no task $id in your projects (see: citt tasks)" ;;
    409) fail_out 5 "task $id cannot be cancelled: $(body_field '.message')" ;;
    *) fail_http ;;
  esac
  _task_get "$id" "$out"
  if [ "$CITT_JSON" != 1 ]; then
    jq -r '"Task \(.task_id): " + (if .status == "cancelled" then "cancelled. Work already done stays."
      else "cancel requested (" + .status + "); it ends once the finished work is stored: citt task \(.task_id) --watch" end)' "$out"
  fi
}

# _task_get ID FILE: GET /tasks/ID with every page of its timeline into FILE; 404 is "no task".
_task_get() {
  local id="$1" out="$2" more pages=0 events
  http GET "$CITT_V1/tasks/$1"
  case "$CODE" in
    2??) ;;
    404) [ -z "$(body_field '.error')" ] && fail_http; die 4 "no task $id in your projects (see: citt tasks)" ;;
    *) fail_http ;;
  esac
  jq -e '.task_id' "$RESP" >/dev/null 2>&1 || die 1 "unparseable response from GET $CITT_V1/tasks/$id"
  cp "$RESP" "$out"
  events="$(tmpfile task_events)"
  more="$(jq -r '.events_cursor // empty' "$out")"
  while [ -n "$more" ] && [ "$pages" -lt 50 ]; do
    call GET "$CITT_V1/tasks/$id$(query events_cursor "$more")"
    jq -c '.timeline' "$RESP" >"$events"
    jq -c --slurpfile e "$events" '.timeline += $e[0]' "$out" >"$out.n" && mv "$out.n" "$out"
    more="$(body_field '.events_cursor')"
    pages=$((pages + 1))
  done
  jq -c '.events_cursor = null' "$out" >"$out.n" && mv "$out.n" "$out"
}

# _task_result FILE: the error with its next step, the result link and the task page.
_task_result() {
  jq -r --arg h "$CITT_APP_HOST" "$JQ_TASK"'
    (if .error != null then "Reason: \(.error.reason)" + (if .error.next_action then "; next: " + (.error.next_action | next_line($h)) else "" end) else empty end),
    (if .result != null then "Result: \(.result.label): " + (if (.result.href | test("^https?://")) then .result.href else "\($h)\(.result.href)" end) else empty end),
    "Page: \($h)/projects/\(.project_id)/tasks/\(.task_id)"' "$1"
}

# _task_print FILE: the header, the parts and the timeline.
_task_print() {
  local L
  L="$(local_times "$1")"
  jq -r --argjson L "$L" --argjson now "$(now_s)" "$JQ_TASK"'
    "Task \(.task_id): \(.title)",
    "Kind: \(.kind_label)",
    "Status: \(tstate)" + (if tqueue != null then "; \(tqueue)" else "" end),
    "Submitted: \(.submitted_at | lt) by \(.submitted_by.name) via \(.source)\(if .client and .client != .source then " (\(.client))" else "" end)",
    (if .started_at then "Started: \(.started_at | lt)" else empty end),
    (if .finished_at then "Finished: \(.finished_at | lt)" else empty end),
    (if .status != "queued" then "Duration: \(tdur($now))" else empty end),
    (if (.apps | length) > 0 then "Apps: " + ([.apps[] | "\(.package_id) (\(.platform))"] | join(", "))
       + (if .app_count > (.apps | length) then " and \(.app_count - (.apps | length)) more" else "" end) else empty end)' "$1"
  _task_result "$1"
  local np
  np="$(jq '.parts | length' "$1")"
  if [ "$np" -gt 0 ]; then
    printf '\nParts (%s):\n' "$(jq -r '.parts_total // (.parts | length)' "$1")"
    jq -c '
      (any(.parts[]; .app != null)) as $apps
      | [(["PART", "STATUS"] + (if $apps then ["APP"] else [] end) + ["NOTE"])]
        + [.parts[] | [.slot, (if .status == "partial" then "done with gaps" else .status end)]
            + (if $apps then [(.app.package_id // "-")] else [] end)
            + [(.reason // .detail // "-")]]' "$1" | table
    jq -r 'if (.parts_total // 0) > (.parts | length) then "Showing \(.parts | length) of \(.parts_total) parts; the task page lists all." else empty end' "$1"
  fi
  printf '\nTimeline:\n'
  jq -r --argjson L "$L" "$JQ_TASK"' .timeline[] | "\(.at | lt)  \(.label)"' "$1"
}
