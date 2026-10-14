#!/usr/bin/env bash
# lib/cmd-native.sh: citt native (DESIGN-native-and-tasks A2, A6, B5). Starts the native code run
# of an app's build (POST /project-apps/{id}/native-code): Binary Ninja decompiles the build's
# native binaries into its sources. --wait follows the run (GET /project-apps/{id}/native-code).
# shellcheck shell=bash disable=SC2034,SC2016,SC2153

NATIVE_ENDED=" done partial failed cancelled not_run "

# JQ_NATIVE: `nstatus`, a run status in words; `progress_line`, one line of a run's progress.
JQ_NATIVE="$JQ_LT$JQ_NEXT"'
def nstatus: {queued: "queued", preparing: "preparing its binaries", waiting_split: "waiting for the split libraries of the build",
  running: "running", done: "done", partial: "done with gaps", failed: "failed", cancelled: "cancelled", not_run: "not run"}[.] // .;
def pl($n; $one; $many): if $n == 1 then "\($n) \($one)" else "\($n) \($many)" end;
# todo_lines: the binaries the run decompiles, named by their path in the build, and the reason of a noted one.
def todo_lines: .run as $r
  | ([$r.binaries[] | select(.status != "skipped")] as $q
     | if ($q | length) == 0 and ($r.progress.skipped // 0) == 0 and ($r.status == "done")
       then "This build ships no native libraries."
       elif ($q | length) == 0 and ((["queued", "preparing", "waiting_split"] | index($r.status)) != null)
       then "The binaries are listed when the run starts."
       else "To decompile: \(pl($q | length; "binary"; "binaries"))\(if $r.abi then " (\($r.abi))" else "" end)"
         + (if ($q | length) > 0 then ": " + ([$q[].path] | join(", ")) else "" end),
         ($q[] | select(.reason != null and (.status == "queued" or .status == "running")) | "  \(.path): \(.reason)") end);
def progress_line: .run as $r
  | if $r == null then "No native code run for this app."
    else ($r.progress // {}) as $p
    | "Run \($r.run_id): \($r.status | nstatus), \($p.done // 0) of \($p.total // 0) done"
      + (if ($p.failed // 0) > 0 then ", \($p.failed) failed" else "" end)
      + (if (($p.running // []) | length) > 0 then "; decompiling " + ([$p.running[].path] | join(", ")) else "" end)
      + (if $r.queue != null and ($r.queue.ahead_binaries // 0) > 0 and (($p.running // []) | length) == 0
         then "; waiting behind \($r.queue.ahead_binaries) binar\(if $r.queue.ahead_binaries == 1 then "y" else "ies" end) of other work" else "" end)
      + (if $r.queue != null and ($r.worker == null or $r.worker.online != false)
         then (if $r.queue.eta_at then "; about \($r.queue.eta_at | lt)" else "; no estimate yet" end) else "" end)
      + (if $r.worker != null and $r.worker.online == false
         then "; the decompiler is offline since \($r.worker.offline_since | lt); the task stays queued and starts when it returns" else "" end)
      + (if $r.status == "failed" and $r.error then ": \($r.error.reason)" else "" end)
    end;'

# _native_rerun: the command as given, with --wait, for the re-run line.
NATIVE_RERUN="citt native"

cmd_native() {
  local target="" platform="" wait=0 timeout=540 n a
  CITT_CMD="citt native"
  for a in "$@"; do
    case "$a" in --wait | --json) ;; *) NATIVE_RERUN="$NATIVE_RERUN $(shq "$a")" ;; esac
  done
  NATIVE_RERUN="$NATIVE_RERUN --wait"
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --platform)
        need_value "$1" $#
        platform="$2"
        shift
        ;;
      --platform=*) platform="${1#--platform=}" ;;
      --wait) wait=1 ;;
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_native
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$target" ] || usage_error "one app at a time; got $target and $1"
        target="$1"
        ;;
    esac
    shift
  done
  [ -n "$target" ] || usage_error "give the PACKAGE (with --project) or the project app id"
  case "$platform" in '' | android | ios) ;; *) usage_error "--platform is android or ios, got: $platform" ;; esac
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  project_flag_or_id
  need_auth
  if is_uint "$target" && [ -z "$OPT_PROJECT" ] && [ -z "$OPT_PROJECT_ID" ]; then
    # A number without a project is a project app id (the `citt native N` an answer prints).
    APP_ID="$target"
    APP_PACKAGE=""
    APP_PLATFORM="$platform"
    E_KIND=native_app
  else
    resolve_project
    resolve_app "$target" "$platform"
  fi

  local body started
  body="$(tmpfile native_body)"
  jq -nc --arg k "plugin-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" '{idempotency_key: $k}' >"$body"
  # One live run per build: a repeat of the POST returns the same run, so a retry is safe.
  HTTP_RETRY=yes
  http POST "$CITT_V1/project-apps/$APP_ID/native-code" "$body"
  ok || _native_fail
  started="$(tmpfile native_started)"
  cp "$RESP" "$started"
  jq -e '.project_app_id' "$started" >/dev/null 2>&1 || die 1 "unparseable response from POST $CITT_V1/project-apps/$APP_ID/native-code"

  if [ "$CITT_JSON" != 1 ]; then
    _native_summary "$started" "$wait"
  fi
  if [ "$wait" != 1 ]; then
    if [ "$CITT_JSON" = 1 ]; then
      jq -c '{schema: "citt.plugin.native/1", project_app_id, task_id, reused, polls: 0, ended: (.status as $s | " done partial failed cancelled " | contains(" \($s) ")), state: .}' "$started"
    fi
    return 0
  fi
  _native_watch "$started" "$timeout"
}

# _native_fail: 409 build_unavailable and tree_unavailable with what to do; 404 for an app id; else fail_http.
_native_fail() {
  local error message
  error="$(body_field '.error')"
  message="$(body_field '.message')"
  case "$CODE:$error" in
    409:build_unavailable)
      if [ -n "$APP_PACKAGE" ]; then
        fail_out 5 "${message:-This app has no stored build yet.} Scan the app first: citt submit$(project_arg) $APP_PACKAGE"
      fi
      fail_out 5 "${message:-This app has no stored build yet.} Scan the app first: $(jq -r --arg h "$CITT_APP_HOST" "$JQ_NEXT"' .next_action | next_line($h)' "$RESP")"
      ;;
    409:tree_unavailable)
      if [ -n "$APP_PACKAGE" ]; then
        fail_out 5 "${message:-This build has no prepared files yet.} Prepare them on the app page: $CITT_APP_HOST/projects/$PROJECT_ID/apps/$APP_PLATFORM/$APP_PACKAGE, then run this command again"
      fi
      fail_out 5 "${message:-This build has no prepared files yet.} $(jq -r --arg h "$CITT_APP_HOST" "$JQ_NEXT"' .next_action | next_line($h) // "Prepare the app'"'"'s files on its app page."' "$RESP")"
      ;;
    404:?*)
      [ "$E_KIND" = native_app ] && fail_out 4 "project app $APP_ID is not in your projects (give the package with --project instead)"
      ;;
  esac
  fail_http
}

# _native_summary STATE_FILE WAIT: the task, the run and its listing, the progress, and what follows.
_native_summary() {
  local L
  L="$(local_times "$1")"
  jq -r --argjson L "$L" --arg h "$CITT_APP_HOST" --arg pkg "$APP_PACKAGE" --arg pl "$APP_PLATFORM" --arg rerun "$NATIVE_RERUN" --arg wait "$2" \
    --argjson pid "${PROJECT_ID:-null}" "$JQ_NATIVE"'
    . as $s | .run as $r
    | (if $pkg != "" then "\($pkg) (\($pl))" else "project app \(.project_app_id)" end) as $app
    | (if .task_id then "Task \(.task_id): " else "" end) as $t
    | if $r == null then "\($t)Native code for \($app): no run was started."
      else
        (if .reused then "\($t)Native code for \($app): this build already has run \($r.run_id) (\($r.status | nstatus)); nothing new was queued."
         else "\($t)Native code for \($app): run \($r.run_id) \($r.status | nstatus)." end),
        todo_lines,
        ([$r.binaries[] | select(.status == "skipped")] as $sk
         | if ($sk | length) == 0 then empty
           else "Skipped: \($sk | length)",
             ($sk | group_by(.reason // "-")[] | "  \(.[0].reason // "no reason given") (\(length)): " + ([.[].path] | join(", ")))
           end),
        progress_line,
        (if (" done partial " | contains(" \($r.status) ")) then
           ([$r.binaries[] | select(.status == "failed")][] | "  \(.path) failed: \(.reason // "no reason given")"),
           (if $pkg != "" and $pid != null then "Next: citt export-sources --project-id \($pid) --apps \($pkg) (the output is under native/)" else empty end)
         elif $r.status == "failed" then
           (($r.error.next_action // null) as $n
            | if $n != null and (($n.href // "") | test("/native-code$") | not) then "Next: " + ($n | next_line($h))
              else "Next: run it again: \($rerun | sub(" --wait$"; ""))" end)
         elif $r.status == "cancelled" or $wait == "1" then empty
         else "Next: \($rerun) to follow it" + (if $s.task_id then "; citt task \($s.task_id) for its timeline" else "" end) end)
      end' "$1" || die 1 "unparseable native code response"
}

# _native_next STATE_FILE: what follows a failed run: its next action when that is not the run itself (an iOS build
# whose files must be prepared first), else the same command again.
_native_next() {
  jq -r --arg h "$CITT_APP_HOST" --arg rerun "${NATIVE_RERUN% --wait}" "$JQ_NEXT"'
    (.run.error.next_action // null) as $n
    | if $n != null and (($n.href // "") | test("/native-code$") | not) then "next: " + ($n | next_line($h)) else "run it again: \($rerun)" end' "$1"
}

# _native_watch STARTED_FILE TIMEOUT: polls the app's native code state until the run ends or
# TIMEOUT passes; a line per change.
_native_watch() {
  local started="$1" timeout="$2" start left polls=0 last="" line st ended=false L code=0 run state listed=0
  state="$(tmpfile native_state)"
  cp "$started" "$state"
  L="$(local_times "$state")"
  last="$(jq -r --argjson L "$L" "$JQ_NATIVE"' progress_line' "$state")"
  [ "$(jq '(.run.binaries // []) | length' "$state")" = 0 ] || listed=1
  start="$(now_s)"
  while :; do
    st="$(jq -r '.status // "not_run"' "$state")"
    case "$NATIVE_ENDED" in *" $st "*)
      ended=true
      break
      ;;
    esac
    left=$((timeout - ($(now_s) - start)))
    [ "$left" -gt 0 ] || break
    poll_sleep "" "$left"
    call GET "$CITT_V1/project-apps/$APP_ID/native-code"
    polls=$((polls + 1))
    cp "$RESP" "$state"
    L="$(local_times "$state")"
    line="$(jq -r --argjson L "$L" "$JQ_NATIVE"' progress_line' "$state")" \
      || die 1 "unparseable response from GET $CITT_V1/project-apps/$APP_ID/native-code"
    if [ "$CITT_JSON" != 1 ] && [ "$listed" = 0 ] && [ "$(jq '(.run.binaries // []) | length' "$state")" -gt 0 ]; then
      # The service lists the binaries when the run starts: the count the first summary could not give.
      listed=1
      jq -r --argjson L "$L" "$JQ_NATIVE"' todo_lines' "$state"
    fi
    if [ "$line" != "$last" ] && [ "$CITT_JSON" != 1 ]; then
      printf '%s\n' "$line"
    fi
    last="$line"
  done

  run="$(jq -r '.run.run_id // "?"' "$state")"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --argjson polls "$polls" --argjson ended "$ended" --slurpfile s "$started" \
      '{schema: "citt.plugin.native/1", project_app_id, task_id: (.task_id // $s[0].task_id), reused: $s[0].reused,
        polls: $polls, ended: $ended, state: ., started: $s[0]}' "$state"
  fi
  if [ "$ended" != true ]; then
    err "$CITT_CMD: run $run is still $(jq -r '.status // "queued"' "$state") after $timeout s; re-run: $NATIVE_RERUN"
    return 12
  fi
  if [ "$CITT_JSON" != 1 ] && [ "$polls" -gt 0 ]; then
    jq -r '[.run.binaries[]? | select(.status == "failed")][] | "  \(.path) failed: \(.reason // "no reason given")"' "$state"
    if [ "$st" = "done" ] || [ "$st" = partial ]; then
      if [ -n "$APP_PACKAGE" ] && [ -n "${PROJECT_ID:-}" ]; then
        printf 'Next: citt export-sources --project-id %s --apps %s (the output is under native/)\n' "$PROJECT_ID" "$APP_PACKAGE"
      fi
    fi
  fi
  case "$st" in
    partial)
      err "$CITT_CMD: run $run ended done with gaps: $(jq -r '"\(.run.progress.failed // 0) of \(.run.progress.total // 0) binaries failed"' "$state")"
      code=13
      ;;
    failed)
      err "$CITT_CMD: run $run failed: $(jq -r '.run.error.reason // "no reason given"' "$state"); $(_native_next "$state")"
      code=8
      ;;
    cancelled)
      err "$CITT_CMD: run $run was cancelled: $(jq -r '"\(.run.progress.done // 0) of \(.run.progress.total // 0) binaries done"' "$state")"
      code=14
      ;;
    not_run)
      err "$CITT_CMD: the app has no native code run"
      code=8
      ;;
  esac
  return "$code"
}
