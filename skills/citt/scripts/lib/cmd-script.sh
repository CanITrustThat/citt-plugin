#!/usr/bin/env bash
# lib/cmd-script.sh: customer post-capture scripts (NP-1908 CS-07, NP-1909 CS-08; proof of concept, epic NP-1900).
# A script folder (citt-script.json, build/Dockerfile, the customer's files) is checked and packed here into a
# deterministic tar.gz, uploaded with tus (purpose script_bundle) and registered as the next version of a NAME in a
# project; for each session of a capture run of the project the active version runs once (D16: input folder, output
# folder, one run per session) against that session's folder, and each session's script-outputs/ archive is pulled back
# here into <run_key>/<session>/script-outputs/<name>@<version>/. No customer secret exists (D17).
# Routes and JSON: services/netproof/planning/customer-scripts/poc/contracts/customer-api.md; archive and manifest: poc/contracts/bundle-and-manifest.md; what each state means:
# PLAN.md section 6.
# shellcheck shell=bash disable=SC2034,SC2153

# --watch and script-build poll every 15 s (AC-08.1).
SR_POLL_S=15
SR_NAME_RE='^[a-z0-9][a-z0-9._-]{0,63}$'
# NP-1975: the migration 0060 charset of run_key and session_key, as the API and the worker take it (NP-1974); `.` and
# `..` are refused by _sr_key_ok.
SR_RUN_KEY_RE='^[A-Za-z0-9._-]{1,128}$'
# R15 limits, checked here before the upload (the API checks them again).
SR_MAX_BYTES=268435456
SR_MAX_UNPACKED=2147483648
SR_MAX_ENTRIES=10000
SR_NAME_RULE="a name takes lowercase letters, digits, dot, underscore and hyphen, starts with a letter or digit, and has at most 64 characters"
# A session folder name of capture-sync: <session_key>_<start UTC like 2026-10-11T2044Z>, 128 + 17 characters at most (the
# worker's _SESSION bound); a session key alone also matches.
SR_SESSION_RE='^[A-Za-z0-9._-]{1,145}$'

# The tar program: tar; CITT_TAR names another one in test mode only (the bsdtar half of AC-07.3).
SR_TAR=tar
[ "${CITT_TEST_MODE:-}" != 1 ] || SR_TAR="${CITT_TAR:-tar}"

# Set by the commands for printed next steps: " --project kilo" (project_arg) and the run reference.
SR_PROJ_ARG=""
SR_REF=""
SR_FILE=""

# --- the hooks of lib/tus.sh ---------------------------------------------------------------

PROMPT_RERUN="citt script-push"

prompt_exit() {
  err "$CITT_CMD: $3"
  if [ "$CITT_JSON" = 1 ]; then
    jq -nc --arg e "$2" --arg m "$3" '{error: $e, message: $m, http_status: null}'
  fi
  exit "$1"
}

prompt_fail() { _script_fail; }

call_prompt() {
  http "$@"
  ok || _script_fail
}

# --- errors --------------------------------------------------------------------------------

# _sr_plain TEXT: TEXT from the service when it names no internal (plain_message without an error code to match).
_sr_plain() { plain_message "$1" $'\001'; }

# _script_fail: the refusals of the script routes that fail_http words for other commands, then fail_http.
_script_fail() {
  local error
  error="$(body_field '.error')"
  case "$CODE:$error" in
    413:*) fail_out 7 "the bundle is over 256 MiB compressed; move large data out of the folder (scripts read the session's files at /work/run-output)" ;;
    422:bundle_name_invalid) fail_out 7 "the name is refused: $SR_NAME_RULE" ;;
    422:script_not_found) fail_out 4 "that script version is not in the project; list them: citt scripts$SR_PROJ_ARG" ;;
    409:bundle_active) fail_out 5 "this version is the project's active version; deactivate it first: citt script-deactivate$SR_PROJ_ARG" ;;
    409:output_not_ready) fail_out 5 "the output of this script run is not stored yet; follow it: citt script-status $SR_REF --watch" ;;
    404:no_script_run) fail_out 4 "run ${SR_RUN:-?} has no script run; start one for each session: citt script-run ${SR_RUN:-RUN} --script NAME@VER" ;;
    404:session_not_found) fail_out 4 "run ${SR_RUN:-?} has no session ${SR_SESSION:-?}; its sessions: $(jq -r '(.sessions // []) | join(", ")' "$RESP" 2>/dev/null)" ;;
    404:log_not_available) fail_out 4 "no log of that stream for this script run yet; follow it: citt script-status $SR_REF --watch" ;;
    # NP-1921: an unknown capture run or script run is named as such (fail_http words a bare 404 as a missing project)
    404:not_found)
      if [ -n "$SR_RUN" ]; then
        fail_out 4 "capture run $SR_RUN is not among your runs (a script run id goes after --script-run); list them: citt captures"
      elif [ -n "$SR_ID" ]; then
        fail_out 4 "script run $SR_ID is not among your script runs"
      fi
      ;;
  esac
  fail_http
}

_script_call() {
  http "$@"
  ok || _script_fail
}

# --- arguments -----------------------------------------------------------------------------

# require_tar: tar for the commands that pack or unpack (AC-07.1); kept out of common.sh, which the TortScope release
# shares.
require_tar() {
  command -v "$SR_TAR" >/dev/null 2>&1 || {
    err "citt: tar is required (brew install gnu-tar, or apt install tar)"
    exit 1
  }
}

# _sr_matches RE TEXT: TEXT is one line that matches the extended regex RE.
_sr_matches() {
  case "$2" in *$'\n'*) return 1 ;; esac
  printf '%s' "$2" | LC_ALL=C grep -Eq "$1"
}

# _sr_key_ok RE TEXT: TEXT matches RE and is not `.` or `..` (a folder name that names no new folder; NP-1975).
_sr_key_ok() {
  case "$2" in . | ..) return 1 ;; esac
  _sr_matches "$1" "$2"
}

# _sr_check_name NAME: NAME follows SR_NAME_RE (AC-07.6), else exit 2 before any request.
_sr_check_name() {
  _sr_matches "$SR_NAME_RE" "$1" || usage_error "--name $(shq "$1") is refused: $SR_NAME_RULE"
}

# _sr_ref NAME@VER: sets SR_RNAME and SR_RVER.
SR_RNAME=""
SR_RVER=""
_sr_ref() {
  case "$1" in
    *@*) ;;
    *) usage_error "give the version as NAME@VERSION, such as decoder@3 (see: citt scripts$SR_PROJ_ARG)" ;;
  esac
  SR_RNAME="${1%@*}"
  SR_RVER="${1##*@}"
  _sr_matches "$SR_NAME_RE" "$SR_RNAME" || usage_error "$(shq "$1") is refused: $SR_NAME_RULE"
  _sr_matches '^[1-9][0-9]{0,8}$' "$SR_RVER" || usage_error "$(shq "$1"): the version after @ is a number, such as decoder@3"
}

# _sr_project: the --project or --project-id flag (required), resolved; sets SR_PROJ_ARG and SR_PLABEL.
SR_PLABEL=""
_sr_project() {
  check_project_flags
  SR_PROJ_ARG="$(project_arg)"
  need_auth
  resolve_project
  SR_PLABEL="${PROJECT_NAME:-$PROJECT_ID}"
}

# _sr_bundle_id NAME VER: the bundle_id of NAME@VER in PROJECT_ID, else exit 4.
_sr_bundle_id() {
  local id
  _script_call GET "$CITT_V1/projects/$PROJECT_ID/script-bundles"
  id="$(jq -r --arg n "$1" --argjson v "$2" '[.bundles[]? | select(.name == $n and .version == $v and .status != "deleted")][0].bundle_id // empty' "$RESP" 2>/dev/null)"
  is_uint "$id" || die 4 "$1@$2 is not a version in project $SR_PLABEL; list them: citt scripts$SR_PROJ_ARG"
  printf '%s' "$id"
}

# --- states (PLAN.md section 6) -------------------------------------------------------------

# _sr_sentence STATUS REASON: the plugin's plain sentence of a row, printed when the service's message names an internal.
_sr_sentence() {
  case "$1:$2" in
    waiting_data:sessions_uploading) printf 'The session is still being stored; its script starts once it is.' ;;
    waiting_data:restoring) printf 'The session is being restored from storage.' ;;
    waiting_data:analysis_pending) printf 'Our analysis of the session is being finished; the script starts after it.' ;;
    waiting_data:*) printf "The session's data is still being stored or analysed." ;;
    queued:build_cap_today) printf 'This project has used its 10 image builds today; the build starts after 00:00 UTC.' ;;
    queued:host_busy) printf 'The script host is busy with capture work; the job starts when load drops.' ;;
    queued:host_full) printf 'The script host is short of disk; the job starts when space is freed.' ;;
    queued:worker_offline | queued:worker_outdated) printf 'The script host is offline or being updated; the job starts when it is back.' ;;
    queued:*) printf 'Queued behind other script runs.' ;;
    fetching:*) printf "Copying the session's files to the script host." ;;
    building:*) printf 'Building the image from build/Dockerfile.' ;;
    running:*) printf 'The script is running.' ;;
    uploading:*) printf 'Storing the output.' ;;
    succeeded:image_ready) printf 'The image is ready.' ;;
    succeeded:*) printf 'The output is ready.' ;;
    failed:build_failed) printf 'The image build stopped at a step of build/Dockerfile.' ;;
    failed:build_timeout) printf 'The image build passed the build time limit.' ;;
    failed:image_too_large) printf 'The image passed the 10 GiB image size limit.' ;;
    failed:build_egress_denied) printf 'The build was stopped after more than 50 requests to hosts outside the allow-list.' ;;
    failed:exit_nonzero) printf 'The script ended with exit code %s.' "$(jq -r '.exit_code // "other than 0"' "$SR_FILE" 2>/dev/null)" ;;
    failed:out_of_memory) printf 'The script passed its memory limit of %s GB.' "$(jq -r '.limits.memory_gb // "?"' "$SR_FILE" 2>/dev/null)" ;;
    failed:entrypoint_missing) printf 'The entrypoint was not found in the image or the bundle.' ;;
    failed:output_too_large) printf 'The output passed the size limit; nothing was stored.' ;;
    failed:output_limits) printf 'The output passed the file count limit, or held links or unsafe names; nothing was stored.' ;;
    failed:service_error) printf 'The script could not be run after 3 attempts on our side; nothing is counted.' ;;
    failed:*) printf 'The script run failed.' ;;
    timed_out:*) printf 'The script passed its time limit of %s.' "$(jq -r 'if .limits.wall_minutes == 1 then "1 minute" else "\(.limits.wall_minutes // "?") minutes" end' "$SR_FILE" 2>/dev/null)" ;;
    skipped:no_sessions) printf 'The run stored no sessions, so there was nothing to run on.' ;;
    skipped:data_not_ready) printf "The session's data was not complete after 80 hours." ;;
    skipped:bundle_unavailable) printf "The script version was deleted or rejected before the session's script started." ;;
    skipped:not_entitled) printf 'Scripts are not in the plan of this account.' ;;
    skipped:scripts_disabled) printf 'Scripts were disabled for this account or project.' ;;
    skipped:input_too_large | skipped:never_claimable) printf "The session's selected input is larger than the script host can take." ;;
    skipped:replaced_per_session) printf 'This run-level script run was replaced by one script run per session.' ;;
    skipped:*) printf 'The script was not run for this session.' ;;
    cancelled:*) printf 'The script run was cancelled.' ;;
    *) printf 'State %s.' "$1" ;;
  esac
}

# _sr_exit STATUS REASON: the exit code of a state: 0 succeeded or still open, 13 a customer failure, 8 a failure on our
# side, 14 cancelled.
_sr_exit() {
  case "$1:$2" in
    failed:service_error) printf 8 ;;
    failed:* | timed_out:* | skipped:*) printf 13 ;;
    cancelled:*) printf 14 ;;
    *) printf 0 ;;
  esac
}

_sr_terminal() { case "$1" in succeeded | failed | timed_out | skipped | cancelled) return 0 ;; esac; return 1; }

# _sr_next STATUS REASON KIND: the next command of a state when the service names none. SR_REF names the row: the run with
# --session, or --script-run.
_sr_next() {
  local w="citt script-status $SR_REF --watch" b run
  b="$(jq -r '"\(.bundle.name)@\(.bundle.version)"' "$SR_FILE" 2>/dev/null)"
  run="$(jq -r '.run_id // "RUN"' "$SR_FILE" 2>/dev/null)"
  case "$1:$2" in
    waiting_data:* | queued:* | fetching:* | uploading:*) printf '%s' "$w" ;;
    building:*) printf 'citt script-logs %s --stream build' "$SR_REF" ;;
    running:*) printf 'citt script-logs %s --stream run' "$SR_REF" ;;
    succeeded:*)
      if [ "$3" = build_only ]; then
        printf 'citt script-activate %s%s' "$b" "${SR_PROJ_ARG:- --project PROJECT}"
      else
        printf 'citt script-pull %s' "$SR_REF"
      fi
      ;;
    failed:build_* | failed:image_too_large) printf 'citt script-logs %s --stream build; fix build/, then citt script-push and citt script-activate --pending' "$SR_REF" ;;
    failed:service_error) printf 'contact support with script run %s' "$(jq -r '.script_run_id' "$SR_FILE")" ;;
    failed:* | timed_out:*) printf 'citt script-logs %s --stream run; fix the script, then citt script-push and citt script-activate --pending' "$SR_REF" ;;
    skipped:input_too_large | skipped:never_claimable) printf 'change inputs.groups in citt-script.json, citt script-push, then citt script-run %s --script NAME@VER' "$run" ;;
    skipped:replaced_per_session) printf 'citt script-run %s --script %s' "$run" "$b" ;;
  esac
}

# _sr_head: the state line of SR_FILE.
_sr_head() {
  jq -r '"Script run \(.script_run_id) (\(if .kind == "build_only" then "image build" elif .session then "run \(.run_id), session \(.session)" else "run \(.run_id)" end), \(.bundle.name)@\(.bundle.version)): \(.status)\(if .reason then " (\(.reason))" else "" end)"' "$SR_FILE"
}

# _sr_show: the state of SR_FILE (a ScriptRun): line, sentence, queue, times, output, evidence and next command.
_sr_show() {
  local st rs kind msg next lt
  st="$(jq -r '.status' "$SR_FILE")"
  rs="$(jq -r '.reason // empty' "$SR_FILE")"
  kind="$(jq -r '.kind // "run"' "$SR_FILE")"
  _sr_head
  msg="$(_sr_plain "$(jq -r '.message // empty' "$SR_FILE")")"
  [ -n "$msg" ] || msg="$(_sr_sentence "$st" "$rs")"
  printf '%s\n' "$msg"
  lt="$(local_times "$SR_FILE")"
  jq -r --argjson L "$lt" "$JQ_LT"'
    (if .queue then "Queue: position \(.queue.position // "?")\(if .queue.estimated_start then "; estimated start \(.queue.estimated_start | lt)" else "" end)" else empty end),
    (if (.status == "running" or .status == "building") and .timings.started_at then "Started \(.timings.started_at | lt); time limit \(if .limits.wall_minutes == 1 then "1 minute" else "\(.limits.wall_minutes // "?") minutes" end)" else empty end),
    (if .output then "Output: \(.output.bytes) bytes, sha256 \(.output.sha256)" else empty end),
    (if .exit_code != null and .status != "succeeded" then "Exit code: \(.exit_code)" else empty end),
    ((.evidence // {}) | [paths(scalars) as $p | "\($p | map(tostring) | join(".")) \(getpath($p))"] | if length > 0 then "Evidence: " + join(", ") else empty end)' \
    "$SR_FILE"
  next="$(jq -r '.next_action // empty' "$SR_FILE")"
  # A next action from the service is printed only when it is a citt command line.
  if ! printf '%s' "$next" | LC_ALL=C grep -Eq '^citt [A-Za-z0-9@._/ =:,-]+$'; then
    next="$(_sr_next "$st" "$rs" "$kind")"
  fi
  [ -z "$next" ] || printf 'Next: %s\n' "$next"
  return 0
}

# _sr_get: the ScriptRun of SR_ID (a script run), or of session SR_SESSION of capture run SR_RUN, into SR_FILE; sets SR_ID
# and SR_REF. A run with one script run and no --session takes that row.
SR_RUN=""
SR_ID=""
SR_SESSION=""
SR_SET=""
_sr_get() {
  if [ -n "$SR_RUN" ]; then
    _sr_get_set
    local n
    if [ -n "$SR_SESSION" ]; then
      n="$(jq --arg s "$SR_SESSION" '[.sessions[] | select(.session == $s or .session_key == $s)] | length' "$SR_SET")"
      [ "$n" != 0 ] || die 4 "run $SR_RUN has no script run for session $SR_SESSION; its sessions: $(_sr_set_sessions)"
      [ -n "$SR_FILE" ] || SR_FILE="$(tmpfile script_run.json)"
      jq --arg s "$SR_SESSION" '[.sessions[] | select(.session == $s or .session_key == $s)] | max_by(.script_run_id)' "$SR_SET" >"$SR_FILE"
    else
      n="$(jq '.sessions | length' "$SR_SET")"
      [ "$n" = 1 ] || usage_error "run $SR_RUN has $n script runs, one per session; name one with --session S (sessions: $(_sr_set_sessions)) or --script-run N"
      [ -n "$SR_FILE" ] || SR_FILE="$(tmpfile script_run.json)"
      jq '.sessions[0]' "$SR_SET" >"$SR_FILE"
    fi
  else
    _script_call GET "$CITT_V1/script-runs/$SR_ID"
    [ -n "$SR_FILE" ] || SR_FILE="$(tmpfile script_run.json)"
    jq -e '(.script_run_id | type) == "number" and (.status | type) == "string"' "$RESP" >/dev/null 2>&1 \
      || die 1 "unexpected response from the server"
    cp "$RESP" "$SR_FILE"
  fi
  jq -e '(.script_run_id | type) == "number" and (.status | type) == "string"' "$SR_FILE" >/dev/null 2>&1 \
    || die 1 "unexpected response from the server"
  SR_ID="$(jq -r '.script_run_id' "$SR_FILE")"
  _sr_row_ref
}

# _sr_row_ref: SR_REF of the row in SR_FILE: `RUN --session S` for a session row, `--script-run N` otherwise.
_sr_row_ref() {
  local run sess
  run="$(jq -r '.run_id // empty' "$SR_FILE")"
  sess="$(jq -r '.session // empty' "$SR_FILE")"
  if is_uint "$run" && _sr_key_ok "$SR_SESSION_RE" "$sess"; then
    SR_REF="$run --session $sess"
  else
    SR_REF="--script-run $(jq -r '.script_run_id' "$SR_FILE")"
  fi
}

# _sr_get_set: the ScriptRunSet of SR_RUN into SR_SET (customer-api.md, D16).
_sr_get_set() {
  _script_call GET "$CITT_V1/capture-runs/$SR_RUN/script-runs"
  [ -n "$SR_SET" ] || SR_SET="$(tmpfile script_run_set.json)"
  jq -e '(.sessions | type) == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  cp "$RESP" "$SR_SET"
}

# _sr_set_sessions: the session folder names of SR_SET, comma-separated.
_sr_set_sessions() {
  jq -r '[.sessions[] | .session // "run-level"] | join(", ")' "$SR_SET" 2>/dev/null
}

# _sr_take_ref ARG: a capture run id (a number) as SR_RUN.
_sr_take_ref() {
  [ -z "$SR_RUN" ] || usage_error "one run at a time; got $SR_RUN and $1"
  is_uint "$1" || usage_error "give the capture run id, a number (see: citt captures), or --script-run N"
  SR_RUN="$1"
}

# _sr_take_session ARG: a session folder name (as capture-sync names it, such as s0001_2026-10-11T2044Z) or key as SR_SESSION.
_sr_take_session() {
  _sr_key_ok "$SR_SESSION_RE" "$1" || usage_error "--session takes a session folder name such as s0001_2026-10-11T2044Z (see: citt script-status RUN)"
  SR_SESSION="$1"
}

_sr_need_ref() {
  [ -n "$SR_RUN" ] || [ -n "$SR_ID" ] || usage_error "give the capture run id (see: citt captures) or --script-run N"
  [ -z "$SR_RUN" ] || [ -z "$SR_ID" ] || usage_error "give the capture run id or --script-run N, not both"
  [ -z "$SR_SESSION" ] || [ -n "$SR_RUN" ] || usage_error "--session goes with the capture run id, not with --script-run"
  if [ -n "$SR_RUN" ]; then SR_REF="$SR_RUN${SR_SESSION:+ --session $SR_SESSION}"; else SR_REF="--script-run $SR_ID"; fi
}

# _sr_set_exit: the exit code of a run's script runs: 0 while any is open or when all succeeded; else 8 for a failure on our
# side, 13 for a customer failure, 14 for a cancel, in that order.
_sr_set_exit() {
  jq -r '
    [.sessions[] | {s: .status, r: (.reason // "")}] as $rows
    | if any($rows[]; .s | IN("waiting_data","queued","fetching","building","running","uploading")) then 0
      elif any($rows[]; .s == "failed" and .r == "service_error") then 8
      elif any($rows[]; .s | IN("failed","timed_out","skipped")) then 13
      elif any($rows[]; .s == "cancelled") then 14
      else 0 end' "$SR_SET"
}

# _sr_show_set: the counts of SR_SET and one line per session: folder, status, the plain message and the next command.
_sr_show_set() {
  local i n row
  jq -r '"Run \(.run_id) (\(.run_key)), \(.bundle.name)@\(.bundle.version): \(.sessions | length) script run\(if (.sessions | length) == 1 then "" else "s" end), one per session: \(.counts | to_entries | map("\(.value) \(.key)") | join(", "))"' "$SR_SET"
  n="$(jq '.sessions | length' "$SR_SET")"
  row="$(tmpfile script_run_row.json)"
  i=0
  while [ "$i" -lt "$n" ]; do
    jq ".sessions[$i]" "$SR_SET" >"$row"
    local st rs msg next kind
    st="$(jq -r '.status' "$row")"
    rs="$(jq -r '.reason // empty' "$row")"
    kind="$(jq -r '.kind // "run"' "$row")"
    SR_FILE="$row"
    _sr_row_ref
    msg="$(_sr_plain "$(jq -r '.message // empty' "$row")")"
    [ -n "$msg" ] || msg="$(_sr_sentence "$st" "$rs")"
    next="$(jq -r '.next_action // empty' "$row")"
    if ! printf '%s' "$next" | LC_ALL=C grep -Eq '^citt [A-Za-z0-9@._/ =:,-]+$'; then
      next="$(_sr_next "$st" "$rs" "$kind")"
    fi
    printf '%s\t%s%s\t%s%s\n' "$(jq -r '.session // "run-level"' "$row")" "$st" "${rs:+ ($rs)}" "$msg" "${next:+ Next: $next}"
    i=$((i + 1))
  done
  SR_FILE=""
}

# _sr_follow_set TIMEOUT: polls the run's ScriptRunSet every SR_POLL_S seconds, printing the lines on each change, until every
# session's row has ended; exit 12 with the re-run line after TIMEOUT seconds.
_sr_follow_set() {
  local timeout="$1" start last cur left
  start="$(now_s)"
  last="$(jq -c '[.sessions[] | [.script_run_id, .status, .reason]]' "$SR_SET")"
  wait_deadline "$timeout" "the script runs of run $SR_RUN are still open after $timeout s; re-run: citt script-status $SR_RUN --watch"
  while :; do
    jq -e 'all(.sessions[]; .status | IN("succeeded","failed","timed_out","skipped","cancelled"))' "$SR_SET" >/dev/null && break
    left=$((timeout - ($(now_s) - start)))
    if [ "$left" -le 0 ]; then
      wait_done
      err "$CITT_CMD: the script runs of run $SR_RUN are still open after $timeout s; re-run: citt script-status $SR_RUN --watch"
      [ "$CITT_JSON" != 1 ] || cat "$SR_SET"
      exit 12
    fi
    poll_sleep "$SR_POLL_S" "$left"
    _sr_get_set
    cur="$(jq -c '[.sessions[] | [.script_run_id, .status, .reason]]' "$SR_SET")"
    if [ "$cur" != "$last" ] && [ "$CITT_JSON" != 1 ]; then
      _sr_show_set
    fi
    last="$cur"
  done
  wait_done
}

# _sr_follow TIMEOUT: polls GET /script-runs/SR_ID every SR_POLL_S seconds, printing each change, until an end state;
# exit 12 with the re-run line after TIMEOUT seconds. SR_FILE holds the first state.
_sr_follow() {
  local timeout="$1" start last cur st left
  start="$(now_s)"
  last="$(jq -r '"\(.status)/\(.reason)"' "$SR_FILE")"
  wait_deadline "$timeout" "script run $SR_ID is still running after $timeout s; re-run: citt script-status $SR_REF --watch"
  while :; do
    st="$(jq -r '.status' "$SR_FILE")"
    _sr_terminal "$st" && break
    left=$((timeout - ($(now_s) - start)))
    if [ "$left" -le 0 ]; then
      wait_done
      err "$CITT_CMD: script run $SR_ID is still $st after $timeout s; re-run: citt script-status $SR_REF --watch"
      [ "$CITT_JSON" != 1 ] || cat "$SR_FILE"
      exit 12
    fi
    poll_sleep "$SR_POLL_S" "$left"
    _script_call GET "$CITT_V1/script-runs/$SR_ID"
    cp "$RESP" "$SR_FILE"
    cur="$(jq -r '"\(.status)/\(.reason)"' "$SR_FILE")"
    if [ "$cur" != "$last" ] && [ "$CITT_JSON" != 1 ]; then
      _sr_show
    fi
    last="$cur"
  done
  wait_done
}

# --- script-push: local checks and the deterministic archive -------------------------------

# _sr_refuse CODE PATH WHY FIX: a refusal before the upload (AC-07.2): code, path, fix; exit 7.
_sr_refuse() {
  err "$CITT_CMD: refused before upload: $1: $2 $3"
  err "fix: $4; then run: $PROMPT_RERUN"
  if [ "$CITT_JSON" = 1 ]; then
    jq -nc --arg c "$1" --arg p "$2" --arg w "$3" --arg f "$4" \
      '{error: "bundle_refused_locally", rejection: $c, path: $p, message: $w, fix: $f, http_status: null}'
  fi
  exit 7
}

# _sr_fix CODE: the fix of a rejection code (bundle-and-manifest.md, R16).
_sr_fix() {
  case "$1" in
    not_targz) printf 'update the plugin, which packs the archive, and push again' ;;
    bundle_too_large) printf 'keep the bundle under 256 MiB compressed: move large data out of the folder' ;;
    bundle_limits) printf 'keep the folder under 10,000 entries and 2 GiB unpacked' ;;
    unsafe_path) printf 'rename the file: plain relative names without backslashes or control characters, at most 255 bytes per name and 1024 per path, no two names equal ignoring letter case' ;;
    link_entry) printf 'replace the link with the file it points to, or remove it' ;;
    no_manifest) printf 'add citt-script.json at the folder root with "schema": "citt.script.v1" and "entrypoint"' ;;
    manifest_invalid) printf 'fix citt-script.json: schema citt.script.v1, entrypoint as an argv array, optional inputs and limits, no other keys (no secrets: ship reference data in the bundle)' ;;
    no_dockerfile) printf 'add build/Dockerfile (at most 256 KiB); the image is built from build/ alone' ;;
    dockerfile_refused) printf 'remove the refused flag from that RUN line of build/Dockerfile (--network=host, --security=insecure, --mount=type=ssh, --mount=type=secret)' ;;
    entrypoint_missing) printf 'add the file the entrypoint names under /bundle/, or fix entrypoint in citt-script.json' ;;
    *) printf 'fix the folder' ;;
  esac
}

# _sr_check_dir DIR: the local checks before packing (AC-07.2, bundle-and-manifest.md); writes the sorted, NUL-separated
# member list to SR_LIST.
SR_LIST=""
_sr_check_dir() {
  local dir="$1" p rel comp n=0 hit size
  if [ -L "${dir%/}" ]; then
    _sr_refuse link_entry "$dir" "is a symbolic link; the folder must be a plain folder inside which nothing points outside" "$(_sr_fix link_entry)"
  fi
  hit="$(find "$dir" -mindepth 1 -type l -print 2>/dev/null | head -n 1)"
  [ -z "$hit" ] || _sr_refuse link_entry "${hit#"$dir"/}" "is a symbolic link" "$(_sr_fix link_entry)"
  hit="$(find "$dir" -mindepth 1 -type f -links +1 -print 2>/dev/null | head -n 1)"
  [ -z "$hit" ] || _sr_refuse link_entry "${hit#"$dir"/}" "is a hard link (the same file under two names)" "$(_sr_fix link_entry)"
  hit="$(find "$dir" -mindepth 1 ! -type f ! -type d -print 2>/dev/null | head -n 1)"
  [ -z "$hit" ] || _sr_refuse unsafe_path "${hit#"$dir"/}" "is not a regular file or folder (a FIFO, socket or device)" "remove it"
  [ -f "$dir/citt-script.json" ] || _sr_refuse no_manifest "citt-script.json" "is missing" "$(_sr_fix no_manifest)"
  [ "$(file_bytes "$dir/citt-script.json")" -le 65536 ] \
    || _sr_refuse manifest_invalid "citt-script.json" "is over 64 KiB" "$(_sr_fix manifest_invalid)"
  jq -e 'type == "object" and .schema == "citt.script.v1" and (.entrypoint | type) == "array"' "$dir/citt-script.json" >/dev/null 2>&1 \
    || _sr_refuse manifest_invalid "citt-script.json" "is not a JSON object with schema citt.script.v1 and an entrypoint array" "$(_sr_fix manifest_invalid)"
  # D17 (NP-1968): the detail of bundle-and-manifest.md, as the service words it
  ! jq -e 'has("secrets")' "$dir/citt-script.json" >/dev/null 2>&1 \
    || _sr_refuse manifest_invalid "citt-script.json" "secrets: customer secrets are not supported; ship reference data in the bundle" "remove the secrets key from citt-script.json and put reference data or decryption code in the bundle"
  [ -f "$dir/build/Dockerfile" ] || _sr_refuse no_dockerfile "build/Dockerfile" "is missing" "$(_sr_fix no_dockerfile)"
  SR_LIST="$(tmpfile members)"
  # Names in byte order, NUL-separated, without the leading ./ (find prints DIR/...; the prefix is cut).
  while IFS= read -r -d '' p; do
    rel="${p#"$dir"/}"
    case "$rel" in
      *\\* | *[[:cntrl:]]*) _sr_refuse unsafe_path "$(printf '%s' "$rel" | LC_ALL=C tr -c '[:print:]' '?')" "has a backslash or a control character in its name" "$(_sr_fix unsafe_path)" ;;
    esac
    [ "$(printf '%s' "$rel" | LC_ALL=C wc -c | tr -d ' ')" -le 1024 ] || _sr_refuse unsafe_path "$rel" "is longer than 1024 bytes" "$(_sr_fix unsafe_path)"
    comp="${rel##*/}"
    [ "$(printf '%s' "$comp" | LC_ALL=C wc -c | tr -d ' ')" -le 255 ] || _sr_refuse unsafe_path "$rel" "has a name longer than 255 bytes" "$(_sr_fix unsafe_path)"
    n=$((n + 1))
    printf '%s\0' "$rel"
  done < <(find "$dir" -mindepth 1 -print0) | LC_ALL=C sort -z >"$SR_LIST"
  # The subshell of the loop exits through _sr_refuse; its status reaches here as the pipe's.
  hit="${PIPESTATUS[0]}"
  [ "$hit" = 0 ] || exit "$hit"
  n="$(tr -cd '\0' <"$SR_LIST" | wc -c | tr -d ' ')"
  [ "$n" -le "$SR_MAX_ENTRIES" ] || _sr_refuse bundle_limits "$dir" "has $n entries, more than 10,000" "$(_sr_fix bundle_limits)"
  hit="$(tr '\0' '\n' <"$SR_LIST" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sort | uniq -d | head -n 1)"
  [ -z "$hit" ] || _sr_refuse unsafe_path "$hit" "is there twice when letter case is ignored" "$(_sr_fix unsafe_path)"
  size="$(find "$dir" -type f -exec sh -c 'stat -c %s "$@" 2>/dev/null || stat -f %z "$@"' sh {} + | awk '{ s += $1 } END { printf "%.0f", s }')"
  [ "${size:-0}" -le "$SR_MAX_UNPACKED" ] 2>/dev/null \
    || _sr_refuse bundle_limits "$dir" "holds $size bytes, more than 2 GiB unpacked" "$(_sr_fix bundle_limits)"
}

# _sr_mtree_esc TEXT: TEXT with every byte outside [A-Za-z0-9._/+,=-] as \ooo, for an mtree line (bsdtar).
_sr_mtree_esc() {
  local LC_ALL=C s="$1" out="" c i=0 n
  case "$s" in *[!A-Za-z0-9._/+,=-]*) ;; *) printf '%s' "$s"; return 0 ;; esac
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    case "$c" in
      [A-Za-z0-9._/+,=-]) out="$out$c" ;;
      *) out="$out$(printf '\\%03o' "'$c")" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# _sr_pack DIR OUT: the members of SR_LIST as a tar.gz in OUT: pax, owner 0:0, mtime 0, modes 0644 or 0755, byte-order
# names, gzip without a name or time (AC-07.3). GNU tar takes flags; bsdtar (macOS) takes an mtree description.
_sr_pack() {
  local dir="$1" out="$2" tar="$SR_TAR" spec rel abs mode
  abs="$(cd "$dir" && pwd -P)" || die 1 "cannot read $dir"
  if "$tar" --version 2>/dev/null | grep -q 'GNU tar'; then
    (cd "$abs" && "$tar" --format=pax --owner=0 --group=0 --numeric-owner --mtime=@0 --mode='u+rwX,go+rX,go-w' \
      --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
      --no-recursion --null --verbatim-files-from -T "$SR_LIST" -cf -) | gzip -n -9 >"$out" \
      || die 1 "tar could not pack $dir"
  else
    spec="$(tmpfile spec.mtree)"
    {
      printf '#mtree\n'
      while IFS= read -r -d '' rel; do
        if [ -d "$abs/$rel" ]; then
          printf './%s type=dir mode=0755 uid=0 gid=0 uname= gname= time=0.0\n' "$(_sr_mtree_esc "$rel")"
        else
          mode=0644
          [ ! -x "$abs/$rel" ] || mode=0755
          printf './%s type=file mode=%s uid=0 gid=0 uname= gname= time=0.0 contents=%s\n' \
            "$(_sr_mtree_esc "$rel")" "$mode" "$(_sr_mtree_esc "$abs/$rel")"
        fi
      done <"$SR_LIST"
    } >"$spec"
    # Every name starts with ./ so mtree reads it as a full path (a bare folder name would change the current folder of
    # the lines after it); -s takes the ./ off the member names again.
    "$tar" --format=pax -s ',^\./,,' -cf - "@$spec" | gzip -n -9 >"$out" || die 1 "tar could not pack $dir"
  fi
  [ "$(file_bytes "$out")" -le "$SR_MAX_BYTES" ] \
    || _sr_refuse bundle_too_large "$dir" "packs to $(file_bytes "$out") bytes, more than 256 MiB" "$(_sr_fix bundle_too_large)"
}

# _sr_rejected: a 400 bundle_invalid: code, path, detail and the fix (AC-07.4); exit 7.
_sr_rejected() {
  local c p d
  c="$(body_field '.rejection')"
  p="$(body_field '.path')"
  d="$(_sr_plain "$(body_field '.detail')")"
  err "$CITT_CMD: the bundle was refused: ${c:-no code given}${p:+ at $p}${d:+ ($d)}"
  err "fix: $(_sr_fix "$c"); then run: $PROMPT_RERUN"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --argjson s "$CODE" '. + {http_status: $s}' "$RESP"
  fi
  exit 7
}

cmd_script_push() {
  local dir="" name="" activate=0 timeout=540 upload_id="" a arc start body b
  CITT_CMD="citt script-push"
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    a=$?
    if [ "$a" -gt 0 ]; then
      shift "$a"
      continue
    fi
    case "$1" in
      --name)
        need_value "$1" $#
        name="$2"
        shift
        ;;
      --name=*) name="${1#--name=}" ;;
      --activate) activate=1 ;;
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      --upload-id)
        need_value "$1" $#
        upload_id="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_script_push
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$dir" ] || usage_error "one folder at a time; got $dir and $1"
        dir="$1"
        ;;
    esac
    shift
  done
  [ -n "$dir" ] || usage_error "give the script folder: citt script-push DIR --project NAME --name NAME"
  [ -d "$dir" ] || usage_error "$dir is not a folder"
  _sr_check_name "$name"
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  case "$upload_id" in '' | *[!A-Za-z0-9_-]*) [ -z "$upload_id" ] || usage_error "--upload-id takes the id a re-run line printed" ;; esac
  check_project_flags
  dir="${dir%/}"
  [ -n "$dir" ] || dir=/
  PROMPT_RERUN="citt script-push $(shq "$dir")$(project_arg) --name $name$([ "$activate" = 0 ] || printf ' --activate')"
  require_tar
  arc="$_CITT_TMP/$name.tar.gz"
  if [ -z "$upload_id" ]; then
    _sr_check_dir "$dir"
    _sr_pack "$dir" "$arc"
    if [ "${CITT_TEST_MODE:-}" = 1 ] && [ "${CITT_SCRIPT_PACK_ONLY:-}" = 1 ]; then
      cp "$arc" "./$name-pack.tar.gz"
      printf 'archive %s\nsha256 %s\n' "$PWD/$name-pack.tar.gz" "$(sha256_of "$arc")"
      return 0
    fi
  fi
  _sr_project
  if [ -z "$upload_id" ]; then
    TUS_META_EXTRA="purpose $(printf 'script_bundle' | base64 | tr -d '\n'),project_id $(printf '%s' "$PROJECT_ID" | base64 | tr -d '\n')"
    TUS_SETTLE=0
    tus_upload "$arc" "$timeout"
    upload_id="$UPLOAD_ID"
  fi
  body="$(tmpfile register.json)"
  jq -nc --arg n "$name" --arg u "$upload_id" '{name: $n, upload_id: $u}' >"$body"
  start="$(now_s)"
  while :; do
    http POST "$CITT_V1/projects/$PROJECT_ID/script-bundles" "$body"
    case "$CODE:$(body_field '.error')" in
      200:* | 201:*) break ;;
      409:upload_not_validated)
        if [ $(($(now_s) - start)) -ge "$timeout" ]; then
          err "$CITT_CMD: the bundle is still being checked after $timeout s; re-run: citt script-push $(shq "$dir")$SR_PROJ_ARG --name $name --upload-id $upload_id$([ "$activate" = 0 ] || printf ' --activate')"
          exit 12
        fi
        poll_sleep 2
        ;;
      400:bundle_invalid) _sr_rejected ;;
      *) _script_fail ;;
    esac
  done
  b="$(tmpfile bundle.json)"
  cp "$RESP" "$b"
  if [ "$activate" = 1 ]; then
    jq -nc --argjson id "$(jq '.bundle_id' "$b")" '{bundle_id: $id, pending: false}' >"$body"
    _script_call PUT "$CITT_V1/projects/$PROJECT_ID/script-activation" "$body"
  fi
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --argjson a "$activate" '. + {activated: ($a == 1)}' "$b"
    return 0
  fi
  jq -r --arg p "$SR_PLABEL" --arg pa "$SR_PROJ_ARG" --argjson a "$activate" '
    "\(.name)@\(.version)" as $ref
    | "Pushed \(.name) version \(.version) to project \($p) (bundle \(.bundle_id), \(.bytes) bytes).",
      (if .deps_changed then "Image: rebuilt (build/ changed or first version); image state: \(.image_state)."
       else "Image: reused (build/ unchanged since the previous version); image state: \(.image_state)." end),
      ((.warnings // [])[] | "Warning: \(.code)\(if .name then " (\(.name))" else "" end)"),
      ((.limits_clamped // [])[] | "Limit \(.field): asked \(.asked), applied \(.applied) (the ceiling)."),
      (if $a == 1 then "Active: \($ref) runs after each capture run booked in project \($p) from now on." else empty end),
      (if .image_state == "ready" then
         (if $a == 1 then "Next: after a capture run in project \($p) ends: citt script-status RUN"
          else "Next: citt script-activate \($ref)\($pa)" end)
       else "Next: citt script-build \($ref)\($pa)" end)' "$b"
}

# --- scripts, activation, build, egress ------------------------------------------------------

cmd_scripts() {
  local name="" a lt
  CITT_CMD="citt scripts"
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    a=$?
    if [ "$a" -gt 0 ]; then
      shift "$a"
      continue
    fi
    case "$1" in
      --name)
        need_value "$1" $#
        name="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_scripts
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  [ -z "$name" ] || _sr_check_name "$name"
  _sr_project
  _script_call GET "$CITT_V1/projects/$PROJECT_ID/script-bundles"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --arg n "$name" 'if $n == "" then . else .bundles |= map(select(.name == $n)) end' "$RESP"
    return 0
  fi
  if [ "$(jq --arg n "$name" '[.bundles[]? | select($n == "" or .name == $n)] | length' "$RESP")" = 0 ]; then
    printf 'No script versions in project %s%s; push one: citt script-push DIR%s --name NAME\n' "$SR_PLABEL" "${name:+ named $name}" "$SR_PROJ_ARG"
    return 0
  fi
  lt="$(local_times "$RESP")"
  jq -c --arg n "$name" --argjson L "$lt" "$JQ_LT"'
    (.active.bundle_id // null) as $act
    | [["NAME", "VERSION", "STATUS", "IMAGE", "BUILD", "PUSHED", "ACTIVE"]]
      + [.bundles[] | select($n == "" or .name == $n) | select(.status != "deleted")
         | [.name, .version, .status, .image_state, (if .deps_changed then "rebuilt" else "reused" end),
            (.created_at | lt), (if .bundle_id == $act then "active" else "-" end)]]' "$RESP" | table
  printf '\n'
  jq -r 'if .active then "Active: \(.active.name)@\(.active.version)" else "No version is active." end' "$RESP"
}

cmd_script_activate() {
  local ref="" pending=false a id body
  CITT_CMD="citt script-activate"
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    a=$?
    if [ "$a" -gt 0 ]; then
      shift "$a"
      continue
    fi
    case "$1" in
      --pending) pending=true ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_script_activate
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$ref" ] || usage_error "one version at a time; got $ref and $1"
        ref="$1"
        ;;
    esac
    shift
  done
  [ -n "$ref" ] || usage_error "give the version as NAME@VERSION (see: citt scripts --project NAME)"
  _sr_ref "$ref"
  _sr_project
  id="$(_sr_bundle_id "$SR_RNAME" "$SR_RVER")" || exit $?
  body="$(tmpfile activate.json)"
  jq -nc --argjson id "$id" --argjson p "$pending" '{bundle_id: $id, pending: $p}' >"$body"
  _script_call PUT "$CITT_V1/projects/$PROJECT_ID/script-activation" "$body"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  printf 'Active: %s@%s runs after each capture run booked in project %s from now on.\n' "$SR_RNAME" "$SR_RVER" "$SR_PLABEL"
  if [ "$pending" = true ]; then
    jq -r --arg r "$SR_RNAME@$SR_RVER" '(.repointed_runs // 0) as $n
      | if $n == 0 then "No run booked earlier was waiting for its script."
        elif $n == 1 then "1 run booked earlier whose script had not started now runs \($r)."
        else "\($n) runs booked earlier whose script had not started now run \($r)." end' "$RESP"
  fi
}

cmd_script_deactivate() {
  local a
  CITT_CMD="citt script-deactivate"
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    a=$?
    if [ "$a" -gt 0 ]; then
      shift "$a"
      continue
    fi
    case "$1" in
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_script_deactivate
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  _sr_project
  _script_call DELETE "$CITT_V1/projects/$PROJECT_ID/script-activation"
  if [ "$CITT_JSON" = 1 ]; then
    jq -nc --argjson p "$PROJECT_ID" '{project_id: $p, active: null}'
    return 0
  fi
  printf 'No script is active in project %s; capture runs booked from now on run none.\n' "$SR_PLABEL"
}

cmd_script_build() {
  local ref="" a id timeout=540 wait=1 st rs log
  CITT_CMD="citt script-build"
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    a=$?
    if [ "$a" -gt 0 ]; then
      shift "$a"
      continue
    fi
    case "$1" in
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      --no-wait) wait=0 ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_script_build
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$ref" ] || usage_error "one version at a time; got $ref and $1"
        ref="$1"
        ;;
    esac
    shift
  done
  [ -n "$ref" ] || usage_error "give the version as NAME@VERSION (see: citt scripts --project NAME)"
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  _sr_ref "$ref"
  _sr_project
  id="$(_sr_bundle_id "$SR_RNAME" "$SR_RVER")" || exit $?
  _script_call POST "$CITT_V1/script-bundles/$id/build"
  SR_FILE="$(tmpfile script_run.json)"
  cp "$RESP" "$SR_FILE"
  SR_ID="$(jq -r '.script_run_id // empty' "$SR_FILE")"
  is_uint "$SR_ID" || die 1 "unexpected response from the server"
  SR_REF="--script-run $SR_ID"
  [ "$CITT_JSON" = 1 ] || _sr_show
  [ "$wait" = 1 ] || { [ "$CITT_JSON" != 1 ] || cat "$SR_FILE"; return 0; }
  _sr_follow "$timeout"
  st="$(jq -r '.status' "$SR_FILE")"
  rs="$(jq -r '.reason // empty' "$SR_FILE")"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$SR_FILE"
    printf '\n'
  fi
  if [ "$st" = failed ] && [ "$(jq -r '.logs.build // false' "$SR_FILE")" = true ]; then
    log="./script-run-$SR_ID-build.log"
    if _sr_fetch_log build "$log"; then
      [ "$CITT_JSON" = 1 ] || printf 'Build log: %s\n' "$log"
    fi
  fi
  return "$(_sr_exit "$st" "$rs")"
}

cmd_script_egress() {
  local a lt
  CITT_CMD="citt script-egress"
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    a=$?
    if [ "$a" -gt 0 ]; then
      shift "$a"
      continue
    fi
    case "$1" in
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_script_egress
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  _sr_project
  _script_call GET "$CITT_V1/projects/$PROJECT_ID/script-egress"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  lt="$(local_times "$RESP")"
  jq -r --arg p "$SR_PLABEL" --argjson L "$lt" "$JQ_LT"'
    "Hosts an image build in project \($p) can reach (the script run itself has no network):",
    ((.global // [])[] | "  \(.)"),
    (if (.project // []) | length > 0 then "Added for this project:", (.project[] | "  \(.host) (added \(.added_at | lt)\(if .reason then ": \(.reason)" else "" end))")
     else "Added for this project: none; ask support for an addition." end)' "$RESP"
}

# --- status, logs, pull, run ---------------------------------------------------------------

cmd_script_status() {
  local watch=0 timeout=540 st rs
  CITT_CMD="citt script-status"
  while [ $# -gt 0 ]; do
    case "$1" in
      --script-run)
        need_value "$1" $#
        is_uint "$2" || usage_error "--script-run needs a number"
        SR_ID="$2"
        shift
        ;;
      --session)
        need_value "$1" $#
        _sr_take_session "$2"
        shift
        ;;
      --watch) watch=1 ;;
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_script_status
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *) _sr_take_ref "$1" ;;
    esac
    shift
  done
  _sr_need_ref
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  need_auth
  # D16: a run without --session is its ScriptRunSet, one line per session
  if [ -n "$SR_RUN" ] && [ -z "$SR_SESSION" ]; then
    _sr_get_set
    [ "$CITT_JSON" = 1 ] || _sr_show_set
    [ "$watch" = 0 ] || _sr_follow_set "$timeout"
    if [ "$CITT_JSON" = 1 ]; then
      cat "$SR_SET"
      printf '\n'
    fi
    return "$(_sr_set_exit)"
  fi
  _sr_get
  [ "$CITT_JSON" = 1 ] || _sr_show
  [ "$watch" = 0 ] || _sr_follow "$timeout"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$SR_FILE"
    printf '\n'
  fi
  st="$(jq -r '.status' "$SR_FILE")"
  rs="$(jq -r '.reason // empty' "$SR_FILE")"
  return "$(_sr_exit "$st" "$rs")"
}

# _sr_fetch_log STREAM OUT: GET the log of SR_ID into OUT through OUT.part; non-zero when the service has none.
_sr_fetch_log() {
  local part="$2.part"
  ( umask 077; : >"$part" ) 2>/dev/null || die 1 "cannot write $2"
  HTTP_OUT="$part"
  http GET "$CITT_V1/script-runs/$SR_ID/logs?stream=$1"
  if ! ok; then
    # The error body went to the part file; the error mapping reads RESP.
    cp "$part" "$RESP" 2>/dev/null
    rm -f "$part"
    [ "$CODE:$(body_field '.error')" = "404:log_not_available" ] && return 1
    _script_fail
  fi
  mv -f "$part" "$2" || die 1 "cannot write $2"
}

cmd_script_logs() {
  local stream="" out="" rk sess
  CITT_CMD="citt script-logs"
  while [ $# -gt 0 ]; do
    case "$1" in
      --script-run)
        need_value "$1" $#
        is_uint "$2" || usage_error "--script-run needs a number"
        SR_ID="$2"
        shift
        ;;
      --stream)
        need_value "$1" $#
        stream="$2"
        shift
        ;;
      --session)
        need_value "$1" $#
        _sr_take_session "$2"
        shift
        ;;
      --out)
        need_value "$1" $#
        out="$2"
        shift
        ;;
      --help | -h)
        help_script_logs
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *) _sr_take_ref "$1" ;;
    esac
    shift
  done
  _sr_need_ref
  case "$stream" in build | run) ;; *) usage_error "--stream takes build or run" ;; esac
  need_auth
  _sr_get
  if [ -z "$out" ]; then
    rk="$(jq -r '.run_key // empty' "$SR_FILE")"
    sess="$(jq -r '.session // empty' "$SR_FILE")"
    if _sr_key_ok "$SR_RUN_KEY_RE" "$rk" && _sr_key_ok "$SR_SESSION_RE" "$sess"; then
      out="./$rk-$sess-$stream.log"
    elif _sr_key_ok "$SR_RUN_KEY_RE" "$rk"; then
      out="./$rk-$stream.log"
    else
      out="./script-run-$SR_ID-$stream.log"
    fi
  fi
  # RT-20: the log text is written to the file only; stdout gets its path.
  _sr_fetch_log "$stream" "$out" \
    || die 4 "no $stream log for script run $SR_ID yet (status $(jq -r '.status' "$SR_FILE")); follow it: citt script-status $SR_REF --watch"
  printf '%s\n' "$out"
}

# _sr_host_allowed URL: URL is on the API host or on canitrustthat.com, the hosts of the plugin's network allowlist
# (SKILL.md, Codex domains); a presigned URL elsewhere is fetched through the API stream instead (AC-08.3).
_sr_host_allowed() {
  local u="$1" host
  case "$u" in "$CITT_HOST"/*) return 0 ;; https://*) ;; *) return 1 ;; esac
  host="${u#https://}"
  host="${host%%[/?#]*}"
  case "$host" in *@* | *:*) return 1 ;; esac
  case "$host" in canitrustthat.com | *.canitrustthat.com) return 0 ;; esac
  return 1
}

# _sr_download URL SIZE PART: the output archive into PART, resumed with Range; the presigned URL first when its host is
# allowed, else and after a failure the bearer stream. Non-zero when PART is not SIZE bytes after 5 tries.
_sr_download() {
  local url="$1" size="$2" part="$3" tries=0 have via=api
  [ -n "$url" ] && _sr_host_allowed "$url" && via=presigned
  while [ "$tries" -lt 6 ]; do
    tries=$((tries + 1))
    have=0
    [ ! -f "$part" ] || have="$(file_bytes "$part")"
    [ "$have" -le "$size" ] || { rm -f "$part"; have=0; }
    [ "$have" -lt "$size" ] || return 0
    HTTP_OUT="$part"
    HTTP_RESUME=1
    if [ "$via" = presigned ]; then
      HTTP_AUTH=0
      HTTP_CLIENT_HDR=0
      HTTP_RETRY=no
      http GET "$url"
      case "$CODE" in 200 | 206) ;; *) via=api ;; esac
    else
      http GET "$CITT_V1/script-runs/$SR_ID/output?path=script-outputs.tar.gz"
      case "$CODE" in
        200 | 206 | 000) ;;
        416) rm -f "$part" ;;
        *) _script_fail ;;
      esac
    fi
  done
  [ -f "$part" ] && [ "$(file_bytes "$part")" = "$size" ]
}

# _sr_check_archive ARC: every member of ARC is a regular file or folder with a plain relative name (AC-08.3); exit 11
# otherwise, before anything is extracted.
_sr_check_archive() {
  local arc="$1" tar="$SR_TAR" names types qs="" bad
  names="$(tmpfile out.names)"
  types="$(tmpfile out.types)"
  ! "$tar" --version 2>/dev/null | grep -q 'GNU tar' || qs="--quoting-style=escape"
  # shellcheck disable=SC2086
  "$tar" $qs -tzf "$arc" >"$names" 2>/dev/null || _sr_unsafe "the output archive is not a readable tar.gz"
  # shellcheck disable=SC2086
  "$tar" $qs -tvzf "$arc" 2>/dev/null | cut -c1 >"$types" || _sr_unsafe "the output archive is not a readable tar.gz"
  [ "$(wc -l <"$names")" = "$(wc -l <"$types")" ] || _sr_unsafe "the member list of the output archive could not be read"
  bad="$(paste -d '\t' "$types" "$names" | awk -F '\t' '$1 != "-" && $1 != "d" { print; exit }')"
  [ -z "$bad" ] || _sr_unsafe "member ${bad#*	} is not a regular file or folder (type ${bad%%	*})"
  bad="$(awk '/^\// || /(^|\/)\.\.(\/|$)/ || /\\/ || $0 == "" { print; exit }' "$names")"
  [ -z "$bad" ] || _sr_unsafe "member $bad has an absolute, .., backslash or empty name"
  return 0
}

_sr_unsafe() {
  rm -f "${SR_PART:-}" "${SR_ARC:-}" 2>/dev/null
  die 11 "$1; nothing was extracted (the output of script run $SR_ID is refused; contact support with the script run id)"
}

# _sr_pull_one DIR: pulls the output of the succeeded row in SR_FILE (SR_ID) into DIR/<run_key>/<session>/script-outputs/
# <name>@<version>/ (a run-level row of rounds 1 and 2: DIR/<run_key>/script-outputs/<name>@<version>/) after the AC-08.3
# checks; appends one result line to SR_PULLED (JSON). A refused archive stops the command (exit 11).
SR_PART=""
SR_ARC=""
SR_PULLED=""
_sr_pull_one() {
  local dir="$1" rk sess name ver sha size url dest parent marker tmpd tar="$SR_TAR" lsha bad
  rk="$(jq -r '.run_key // empty' "$SR_FILE")"
  sess="$(jq -r '.session // empty' "$SR_FILE")"
  name="$(jq -r '.bundle.name // empty' "$SR_FILE")"
  ver="$(jq -r '.bundle.version // empty' "$SR_FILE")"
  sha="$(jq -r '.output.sha256 // empty' "$SR_FILE")"
  size="$(jq -r '.output.bytes // empty' "$SR_FILE")"
  bad=""
  if ! _sr_key_ok "$SR_RUN_KEY_RE" "$rk"; then
    bad="the run key of this run is not a plain folder name"
  elif [ -n "$sess" ] && ! _sr_key_ok "$SR_SESSION_RE" "$sess"; then
    bad="the session name of this script run is not a plain folder name"
  elif ! { _sr_matches "$SR_NAME_RE" "$name" && is_uint "$ver"; }; then
    bad="the script name or version is not a plain folder name"
  fi
  if [ -n "$bad" ]; then
    # NP-1975: a pull of every session reports the row and goes on to the next one; a pull of one row stops (exit 11)
    [ "${SR_WHOLE_RUN:-0}" = 1 ] || _sr_unsafe "$bad"
    _sr_refused_name "$bad"
    return 3
  fi
  { _sr_matches '^[0-9a-f]{64}$' "$sha" && is_uint "$size"; } || die 1 "unexpected response from the server"
  parent="${dir%/}/$rk${sess:+/$sess}/script-outputs"
  dest="$parent/$name@$ver"
  marker="$parent/.$name@$ver.sha256"
  if [ -d "$dest" ]; then
    if [ "$(cat "$marker" 2>/dev/null)" = "$sha" ]; then
      jq -nc --argjson id "$SR_ID" --arg se "$sess" --arg d "$dest" --arg s "$sha" --argjson n "$size" \
        '{script_run_id: $id, session: (if $se == "" then null else $se end), dir: $d, sha256: $s, bytes: $n, already: true}' >>"$SR_PULLED"
      [ "$CITT_JSON" = 1 ] || printf 'Already pulled: %s/ (sha256 %s)\n' "$dest" "$sha"
      return 0
    fi
    die 5 "$dest exists and holds other files; move it away, or pull into another folder with --dir DIR"
  fi
  mkdir -p "$parent" 2>/dev/null || die 1 "cannot create $parent"
  _script_call GET "$CITT_V1/script-runs/$SR_ID/output-list"
  url="$(jq -r '[.files[]? | select(.path == "script-outputs.tar.gz")][0].url // empty' "$RESP")"
  lsha="$(jq -r '[.files[]? | select(.path == "script-outputs.tar.gz")][0].sha256 // empty' "$RESP")"
  # The sha256 recorded when the output was verified (the ScriptRun) is the reference; the list must agree with it.
  [ "$lsha" = "$sha" ] || die 11 "the download list of script run $SR_ID names another sha256 than the one recorded when the output was stored; nothing was downloaded; try again: citt script-pull $SR_REF"
  SR_PART="$parent/.$name@$ver.tar.gz.part"
  SR_ARC="$parent/.$name@$ver.tar.gz"
  _sr_download "$url" "$size" "$SR_PART" \
    || die 8 "the output download of script run $SR_ID stopped before its end; run again to resume: citt script-pull $SR_REF${dir:+ --dir $(shq "$dir")}"
  if [ "$(sha256_of "$SR_PART")" != "$sha" ]; then
    rm -f "$SR_PART"
    die 11 "the downloaded output of script run $SR_ID differs from the sha256 recorded when it was stored; nothing was extracted; pull again: citt script-pull $SR_REF"
  fi
  mv -f "$SR_PART" "$SR_ARC" || die 1 "cannot write $SR_ARC"
  _sr_check_archive "$SR_ARC"
  tmpd="$dest.part.d"
  rm -rf "$tmpd"
  mkdir -p "$tmpd" || die 1 "cannot create $tmpd"
  if "$tar" --version 2>/dev/null | grep -q 'GNU tar'; then
    # GNU tar 1.35 refuses --no-overwrite-dir with --keep-old-files ("cannot be used with"); the folder is new and empty,
    # so --keep-old-files (a member there twice fails) is kept and --no-overwrite-dir is left out (NP-1909 deviation).
    "$tar" -xzf "$SR_ARC" -C "$tmpd" --no-same-owner --no-same-permissions --keep-old-files 2>/dev/null
  else
    "$tar" -xzf "$SR_ARC" -C "$tmpd" --no-same-owner --no-same-permissions -k 2>/dev/null
  fi || { rm -rf "$tmpd"; _sr_unsafe "the output archive could not be extracted (a member is there twice)"; }
  if [ -n "$(find "$tmpd" ! -type f ! -type d -print 2>/dev/null | head -n 1)" ]; then
    rm -rf "$tmpd"
    _sr_unsafe "the output archive held a member other than a file or folder"
  fi
  chmod -R ug-s,-t "$tmpd" 2>/dev/null
  mv "$tmpd" "$dest" || die 1 "cannot create $dest"
  printf '%s' "$sha" >"$marker"
  rm -f "$SR_ARC"
  jq -nc --argjson id "$SR_ID" --arg se "$sess" --arg d "$dest" --arg s "$sha" --argjson n "$size" \
    '{script_run_id: $id, session: (if $se == "" then null else $se end), dir: $d, sha256: $s, bytes: $n, already: false}' >>"$SR_PULLED"
  [ "$CITT_JSON" = 1 ] || printf 'Wrote %s/ (%s files, %s bytes compressed, sha256 %s)\n' "$dest" "$(find "$dest" -type f | wc -l | tr -d ' ')" "$size" "$sha"
}

# _sr_refused_name REASON: the line (stderr) of a row of a whole-run pull whose run key, session or script name is refused
# as a folder name (NP-1975); appended to SR_SKIPPED (JSON) with reason unsafe_name. Nothing of the row was downloaded.
_sr_refused_name() {
  local se who next
  se="$(jq -r '.session // empty' "$SR_FILE")"
  if [ -n "$se" ]; then who="session $se (script run $SR_ID)"; else who="script run $SR_ID"; fi
  next="citt script-status --script-run $SR_ID"
  jq -nc --argjson id "$SR_ID" --arg se "$se" --arg st "$(jq -r '.status' "$SR_FILE")" --arg n "$next" \
    '{script_run_id: $id, session: (if $se == "" then null else $se end), status: $st, reason: "unsafe_name", next: $n}' >>"$SR_SKIPPED"
  err "$CITT_CMD: $who: not pulled: $1; nothing was downloaded (the output of this script run is refused; contact support with the script run id)"
}

# _sr_not_pulled: the line (stderr) of a row in SR_FILE without output: its status and next command; appended to SR_SKIPPED
# (JSON).
SR_SKIPPED=""
_sr_not_pulled() {
  local st rs stream next who line
  st="$(jq -r '.status' "$SR_FILE")"
  rs="$(jq -r '.reason // empty' "$SR_FILE")"
  who="$(jq -r 'if .session then "session \(.session) (script run \(.script_run_id))" else "script run \(.script_run_id)" end' "$SR_FILE")"
  if _sr_terminal "$st"; then
    # NP-1949: an ended run without output points to its log
    case "$rs" in build_* | image_too_large) stream=build ;; *) stream=run ;; esac
    next="citt script-logs $SR_REF --stream $stream"
    line="$who ended $st${rs:+ ($rs)} with no output; read its log: $next"
  else
    next="citt script-status $SR_REF --watch"
    line="$who is $st${rs:+ ($rs)} and has no output yet; follow it: $next"
  fi
  jq -nc --argjson id "$SR_ID" --arg se "$(jq -r '.session // empty' "$SR_FILE")" --arg st "$st" --arg rs "$rs" --arg n "$next" \
    '{script_run_id: $id, session: (if $se == "" then null else $se end), status: $st, reason: (if $rs == "" then null else $rs end), next: $n}' >>"$SR_SKIPPED"
  err "$CITT_CMD: $line"
}

cmd_script_pull() {
  local dir="." n i row st kind missing=0 refused=0
  CITT_CMD="citt script-pull"
  while [ $# -gt 0 ]; do
    case "$1" in
      --script-run)
        need_value "$1" $#
        is_uint "$2" || usage_error "--script-run needs a number"
        SR_ID="$2"
        shift
        ;;
      --session)
        need_value "$1" $#
        _sr_take_session "$2"
        shift
        ;;
      --dir)
        need_value "$1" $#
        dir="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_script_pull
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *) _sr_take_ref "$1" ;;
    esac
    shift
  done
  _sr_need_ref
  require_tar
  need_auth
  SR_PULLED="$(tmpfile pulled.jsonl)"
  SR_SKIPPED="$(tmpfile skipped.jsonl)"
  : >"$SR_PULLED"
  : >"$SR_SKIPPED"
  row="$(tmpfile script_run_row.json)"
  if [ -n "$SR_RUN" ] && [ -z "$SR_SESSION" ]; then
    # D16: every session of the run
    _sr_get_set
    n="$(jq '.sessions | length' "$SR_SET")"
    i=0
    SR_WHOLE_RUN=1
    while [ "$i" -lt "$n" ]; do
      jq ".sessions[$i]" "$SR_SET" >"$row"
      SR_FILE="$row"
      SR_ID="$(jq -r '.script_run_id' "$row")"
      _sr_row_ref
      st="$(jq -r '.status' "$row")"
      kind="$(jq -r '.kind' "$row")"
      if [ "$st" = succeeded ] && [ "$kind" != build_only ] && [ "$(jq -r '.output.sha256 // empty' "$row")" != "" ]; then
        _sr_pull_one "$dir" || refused=1
      else
        _sr_not_pulled
        missing=1
      fi
      i=$((i + 1))
    done
  else
    _sr_get
    st="$(jq -r '.status' "$SR_FILE")"
    if [ "$st" = succeeded ] && [ "$(jq -r '.kind' "$SR_FILE")" != build_only ]; then
      _sr_pull_one "$dir"
    else
      [ "$CITT_JSON" = 1 ] || err "$CITT_CMD: $(_sr_head)"
      _sr_not_pulled
      missing=1
    fi
  fi
  if [ "$CITT_JSON" = 1 ]; then
    jq -nc --slurpfile p "$SR_PULLED" --slurpfile s "$SR_SKIPPED" '{pulled: $p, not_pulled: $s}'
  fi
  # AC-08.3, D16: 0 when every session with a script run was pulled, 5 when at least one has no output; NP-1975: 11 when
  # a row was refused for its name (the other rows were pulled)
  [ "$refused" = 0 ] || exit 11
  [ "$missing" = 0 ] || exit 5
  return 0
}

cmd_script_run() {
  local ref="" a id body pid
  CITT_CMD="citt script-run"
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    a=$?
    if [ "$a" -gt 0 ]; then
      shift "$a"
      continue
    fi
    case "$1" in
      --script)
        need_value "$1" $#
        ref="$2"
        shift
        ;;
      --session)
        need_value "$1" $#
        _sr_take_session "$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_script_run
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *) _sr_take_ref "$1" ;;
    esac
    shift
  done
  [ -n "$SR_RUN" ] || usage_error "give the capture run id (see: citt captures)"
  [ -n "$ref" ] || usage_error "give the script version: --script NAME@VERSION"
  SR_REF="$SR_RUN"
  _sr_ref "$ref"
  check_project_flags optional
  need_auth
  if [ -n "$OPT_PROJECT$OPT_PROJECT_ID" ]; then
    _sr_project
  else
    _script_call GET "$CITT_V1/capture-runs/$SR_RUN"
    pid="$(jq -r '.run.project_id // empty' "$RESP")"
    is_uint "$pid" || die 1 "unexpected response from the server"
    OPT_PROJECT_ID="$pid"
    _sr_project
  fi
  id="$(_sr_bundle_id "$SR_RNAME" "$SR_RVER")" || exit $?
  body="$(tmpfile script_run_body.json)"
  jq -nc --argjson id "$id" --arg s "$SR_SESSION" 'if $s == "" then {bundle_id: $id} else {bundle_id: $id, session: $s} end' >"$body"
  # D16: one script run per session of the run (or the named session), each starting once its session's analysis is built
  http POST "$CITT_V1/capture-runs/$SR_RUN/script-runs" "$body"
  SR_SET="$(tmpfile script_run_set.json)"
  case "$CODE:$(body_field '.error')" in
    200:* | 201:*) cp "$RESP" "$SR_SET" ;;
    409:script_run_exists)
      jq '{run_id: '"$SR_RUN"', run_key: (.existing[0].run_key), bundle: (.existing[0].bundle), counts: ([.existing[].status] | group_by(.) | map({(.[0]): length}) | add // {}), sessions: .existing}' "$RESP" >"$SR_SET"
      if [ "$CITT_JSON" != 1 ]; then
        if [ -n "$SR_SESSION" ]; then
          printf 'Session %s of run %s already has its script run; nothing new was created.\n' "$SR_SESSION" "$SR_RUN"
        else
          printf 'Every session of run %s already has its script run; nothing new was created.\n' "$SR_RUN"
        fi
        printf 'Next: citt script-status %s\n' "$SR_RUN"
        return 0
      fi
      ;;
    409:no_sessions) die 5 "run $SR_RUN has stored no session yet; its script runs start as its sessions are stored; follow it: citt capture-watch $SR_RUN" ;;
    *) _script_fail ;;
  esac
  if [ "$CITT_JSON" = 1 ]; then
    cat "$SR_SET"
    printf '\n'
    return 0
  fi
  printf 'Created %s script run%s for run %s, one per session; each starts once its session is stored and analysed.\n' \
    "$(jq '.sessions | length' "$SR_SET")" "$(jq -r 'if (.sessions | length) == 1 then "" else "s" end' "$SR_SET")" "$SR_RUN"
  _sr_show_set
}
