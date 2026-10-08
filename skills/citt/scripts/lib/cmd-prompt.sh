#!/usr/bin/env bash
# lib/cmd-prompt.sh: citt prompt. Two forms: TARGET "message" (a build file, a store link or a
# package id; CUSTOM-PROMPT section 1) and the project form (--project NAME --apps ...).
# shellcheck shell=bash disable=SC2034

PROMPT_LABEL="Model answer from static code. Every cited file and quoted line was checked to exist in the decompiled build; the reasoning was not checked. Static code shows what the app contains, not what it sends."

# The command as given, for re-run lines.
PROMPT_RERUN="citt prompt"

cmd_prompt() {
  local a
  for a in "$@"; do
    PROMPT_RERUN="$PROMPT_RERUN $(shq "$a")"
  done
  for a in "$@"; do
    [ "$a" = -- ] && break
    case "$a" in
      --project | --project=* | --project-id | --project-id=* | --apps | --file)
        _prompt_project "$@"
        return
        ;;
    esac
  done
  _prompt_target "$@"
}

# --- errors ----------------------------------------------------------------

# prompt_exit CODE ERROR MESSAGE [REJECTION]: a failure without an HTTP error; with --json one
# document {error, message, http_status: null, rejection?}.
prompt_exit() {
  err "$CITT_CMD: $3"
  if [ "$CITT_JSON" = 1 ]; then
    jq -nc --arg e "$2" --arg m "$3" --arg r "${4:-}" --arg u "$UPLOAD_ID" \
      '{error: $e, message: $m, http_status: null}
       + (if $r == "" then {} else {rejection: $r} end)
       + (if $u == "" then {} else {upload_id: $u} end)'
  fi
  exit "$1"
}

# prompt_fail: the shared mapping (fail_http) with the codes of this command: 403
# custom_prompt_not_in_plan is 3 (the shared 403 line), every 429 is 6, 409 upload_rejected and 413 are 7.
prompt_fail() {
  local error message
  error="$(body_field '.error')"
  message="$(body_field '.message')"
  case "$CODE" in
    429)
      case "$error" in
        upload_rate_limit) fail_out 6 "upload limit reached: ${message:-too many uploads created this hour}; try again later" ;;
        upload_quota) fail_out 6 "stored uploads are over this account's byte quota: ${message:-$error}" ;;
      esac
      [ -n "$(body_field '.action')" ] || fail_out 6 "usage limit reached: ${message:-$error}; see: citt usage"
      ;;
    409)
      [ "$error" != upload_rejected ] \
        || fail_out 7 "the service rejected the upload: $(body_field '.rejection // "no code given"')"
      ;;
    413)
      fail_out 7 "the service refused the upload: ${message:-$error} (the limit is 500 MiB)"
      ;;
  esac
  fail_http
}

# call_prompt METHOD PATH [BODY_FILE]: http, then prompt_fail unless 2xx.
call_prompt() {
  http "$@"
  ok || prompt_fail
}

# --- the target form -------------------------------------------------------

# _is_build PATH: an existing regular file with a build extension.
_is_build() {
  [ -f "$1" ] || return 1
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    apk | xapk | apks | apkm | ipa) return 0 ;;
  esac
  return 1
}

_prompt_target() {
  local thread="" platform="" schema="" wait=0 timeout=540 npos=0 p1="" p2="" opts=1
  while [ $# -gt 0 ]; do
    if [ "$opts" = 1 ]; then
      case "$1" in
        --)
          opts=0
          shift
          continue
          ;;
        --thread)
          need_value "$1" $#
          thread="$2"
          shift 2
          continue
          ;;
        --thread=*) thread="${1#--thread=}" ;;
        --platform)
          need_value "$1" $#
          platform="$2"
          shift 2
          continue
          ;;
        --platform=*) platform="${1#--platform=}" ;;
        --schema)
          need_value "$1" $#
          schema="$2"
          shift 2
          continue
          ;;
        --schema=*) schema="${1#--schema=}" ;;
        --timeout)
          need_value "$1" $#
          timeout="$2"
          shift 2
          continue
          ;;
        --wait) wait=1 ;;
        --json) CITT_JSON=1 ;;
        --help | -h)
          help_prompt
          exit 0
          ;;
        -?*) usage_error "unknown option $1" ;;
        *) opts=2 ;;
      esac
      if [ "$opts" != 2 ]; then
        shift
        continue
      fi
      opts=1
    fi
    npos=$((npos + 1))
    case "$npos" in
      1) p1="$1" ;;
      2) p2="$1" ;;
    esac
    shift
  done
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  local text kind="" target=""
  if [ -n "$thread" ]; then
    is_uint "$thread" || usage_error "--thread needs a thread number, got: $thread"
    [ -z "$platform" ] || usage_error "--platform applies to a package id, not to --thread (the thread fixes the app)"
    case "$npos" in
      0)
        [ "$wait" = 1 ] || usage_error "give the message of the follow-up, or --wait to wait for the thread's last turn"
        [ -z "$schema" ] || usage_error "--schema needs a message"
        ;;
      1) text="$p1" ;;
      *) usage_error "with --thread give only the message, quoted; the thread fixes the app" ;;
    esac
  else
    case "$npos" in
      0) usage_error "give a target (a build file, a store link or a package id) and the message" ;;
      1) usage_error "give the message after the target: citt prompt $(shq "$p1") \"QUESTION\"" ;;
      2) ;;
      *) usage_error "give the message as one argument (quote it)" ;;
    esac
    target="$p1"
    text="$p2"
    if _is_build "$target"; then
      kind="file"
    else
      case "$target" in
        http://* | https://*) kind="link" ;;
        *) kind="id" ;;
      esac
    fi
    case "$platform" in
      '' | android | ios) ;;
      *) usage_error "--platform is android or ios, got: $platform" ;;
    esac
    [ -z "$platform" ] || [ "$kind" = id ] || usage_error "--platform applies to a package id; a $kind gives its own platform"
    [ -n "$platform" ] || platform=android
  fi
  if [ "$npos" -gt 0 ]; then
    [ -n "$(printf '%s' "$text" | tr -d ' \t\r\n')" ] || usage_error "the message is empty"
  fi
  local schema_json=""
  if [ -n "$schema" ]; then
    if [ ! -f "$schema" ] || [ ! -r "$schema" ]; then usage_error "cannot read the schema file $schema"; fi
    schema_json="$(tmpfile schema.json)"
    jq -ce 'if type == "object" then . else error("not an object") end' "$schema" >"$schema_json" 2>/dev/null \
      || usage_error "$schema is not a JSON object (a JSON Schema for the answer's data)"
  fi

  need_auth
  local tid seq="" body key
  key="plugin-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  if [ -n "$thread" ]; then
    E_KIND=thread
    E_THREAD="$thread"
    tid="$thread"
    if [ "$npos" -eq 0 ]; then
      _prompt_wait "$tid" "" "$timeout"
      return
    fi
    body="$(tmpfile turn_body)"
    jq -nc --arg p "$text" --arg k "$key" --slurpfile s "${schema_json:-/dev/null}" \
      '{prompt: $p, idempotency_key: $k} + (if ($s | length) > 0 then {output_schema: $s[0]} else {} end)' >"$body"
    HTTP_RETRY=yes
    call_prompt POST "$CITT_V1/prompts/$tid/turns" "$body"
    seq="$(body_field '.seq')"
  else
    local tjson
    case "$kind" in
      file)
        tus_upload "$target" "$timeout"
        tjson="$(jq -nc --arg u "$UPLOAD_ID" '{upload_id: $u}')"
        ;;
      link) tjson="$(jq -nc --arg u "$target" '{store_url: $u}')" ;;
      id) tjson="$(jq -nc --arg p "$target" --arg pl "$platform" '{package_id: $p, platform: $pl}')" ;;
    esac
    E_KIND=upload
    body="$(tmpfile prompt_body)"
    jq -nc --argjson t "$tjson" --arg p "$text" --arg k "$key" --slurpfile s "${schema_json:-/dev/null}" \
      '{target: $t, prompt: $p, idempotency_key: $k} + (if ($s | length) > 0 then {output_schema: $s[0]} else {} end)' >"$body"
    HTTP_RETRY=yes
    call_prompt POST "$CITT_V1/prompts" "$body"
    tid="$(body_field '.thread_id')"
    is_uint "$tid" || die 1 "unparseable response from POST $CITT_V1/prompts"
    seq="$(body_field '.turns | last | .seq')"
    E_KIND=thread
    E_THREAD="$tid"
  fi
  if [ "$wait" = 1 ]; then
    _prompt_wait "$tid" "$seq" "$timeout"
    return
  fi
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  jq -r --arg t "$tid" --arg s "${seq:-?}" '
    (if .target.package_id then " for \(.target.package_id) (\(.target.platform // "-"))" else "" end) as $app
    | "Thread \($t): turn \($s) \((.turns // [.]) | map(select((.seq | tostring) == $s)) | first | .status // "queued")\($app).",
      "Answer: citt prompt --thread \($t) --wait",
      "Follow-up: citt prompt --thread \($t) \"QUESTION\""' "$RESP" \
    || die 1 "unparseable prompt response"
}

# _prompt_wait THREAD SEQ TIMEOUT: polls GET /prompts/THREAD until turn SEQ (empty: the last turn)
# is answered (exit 0) or failed (exit 8); exit 12 at the timeout.
_prompt_wait() {
  local tid="$1" seq="$2" timeout="$3" start st=""
  E_KIND=thread
  E_THREAD="$tid"
  start="$(now_s)"
  while :; do
    call_prompt GET "$CITT_V1/prompts/$tid"
    [ -n "$seq" ] || seq="$(body_field '.turns | last | .seq')"
    st="$(jq -r --arg s "$seq" '[.turns[]? | select((.seq | tostring) == $s)] | first | .status // empty' "$RESP" 2>/dev/null)"
    case "$st" in answered | failed) break ;; esac
    if [ $(($(now_s) - start)) -ge "$timeout" ]; then
      _prompt_done 12 timeout "turn $seq of thread $tid is still ${st:-queued} after $timeout s; re-run: citt prompt --thread $tid --wait"
    fi
    poll_sleep "$(body_field '.poll_after_seconds')"
  done
  if [ "$st" = failed ]; then
    _prompt_done 8 turn_failed "turn $seq of thread $tid failed: $(jq -r --arg s "$seq" \
      '[.turns[] | select((.seq | tostring) == $s)] | first | .reason // "no reason given"' "$RESP")"
  fi
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  _prompt_print "$tid" "$seq"
}

# _prompt_done CODE ERROR MESSAGE: the stderr line and, with --json, the thread with the error.
_prompt_done() {
  err "$CITT_CMD: $3"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --arg e "$2" --arg m "$3" '. + {error: $e, message: $m, http_status: null}' "$RESP"
  fi
  exit "$1"
}

# _prompt_print THREAD SEQ: the answered turn as text, from the thread in $RESP.
_prompt_print() {
  jq -r --arg t "$1" --arg s "$2" --arg label "$PROMPT_LABEL" '
    def cell: if . == null then "-" else tostring end;
    ([.turns[] | select((.seq | tostring) == $s)] | first) as $u
    | "Thread \($t), turn \($s)\(if .target.package_id then " (\(.target.package_id), \(.target.platform // "-"))" else "" end): \($u.status)",
      "",
      ($u.answer // ""),
      "",
      "Citations:",
      (($u.citations // [])[] | "  \(.path):\(.line | cell)\(if .snippet then "  " + .snippet else "" end)"),
      (if ($u.findings // []) | length > 0 then
         "Findings:", ($u.findings[] | "  \(.severity | cell)  \(.title | cell)  \(.subject | cell)  \(.finding_id | cell)")
       else empty end),
      (if ($u.rejected_findings // 0) > 0 then
         "\($u.rejected_findings) finding\(if $u.rejected_findings == 1 then "" else "s" end) failed the citation check and were not stored."
       else empty end),
      (if $u.data != null then "Data:", ($u.data | tojson) else empty end),
      "",
      $label,
      "Follow-up: citt prompt --thread \($t) \"QUESTION\""' "$RESP" \
    || die 1 "unparseable thread response"
}

# --- the project form ------------------------------------------------------

_prompt_project() {
  local apps="" file="" text="" have_text=0 n
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --apps)
        need_value "$1" $#
        apps="$2"
        shift
        ;;
      --file)
        need_value "$1" $#
        file="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_prompt
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ "$have_text" = 0 ] || usage_error "give the prompt as one argument (quote it)"
        text="$1"
        have_text=1
        ;;
    esac
    shift
  done
  check_project_flags
  [ -n "$apps" ] || usage_error "give --apps all or --apps A[,B...]"
  if [ -n "$file" ]; then
    [ "$have_text" = 0 ] || usage_error "use TEXT or --file, not both"
    [ -r "$file" ] || usage_error "cannot read $file"
    text="$(cat "$file")"
  fi
  [ -n "$(printf '%s' "$text" | tr -d ' \t\r\n')" ] || usage_error "the prompt is empty"
  need_auth
  resolve_project
  local body
  body="$(tmpfile prompt_body)"
  jq -nc --arg apps "$apps" --arg p "$text" \
    '{apps: (if $apps == "all" then "all" else ($apps | split(",") | map(select(. != ""))) end), prompt: $p}' >"$body"
  call POST "$CITT_V1/projects/$PROJECT_ID/prompt" "$body"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  local ref
  ref="$(project_ref)"
  jq -r --arg ref "$ref" '
    .counts as $c
    | "Queued a custom prompt for \($c.apps) app\(if $c.apps == 1 then "" else "s" end) (\($c.llm_prompt) llm_prompt job\(if $c.llm_prompt == 1 then "" else "s" end); \($c.deep_prepare) need\(if $c.deep_prepare == 1 then "s" else "" end) deep preparation first).",
      "Answers appear as findings with source llm_prompt: citt status \($ref) --wait, then citt findings \($ref) --source llm_prompt"' "$RESP" \
    || die 1 "unparseable prompt response"
}
