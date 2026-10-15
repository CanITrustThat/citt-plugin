#!/usr/bin/env bash
# lib/question-check.sh: the free `POST /questions/check` call before a question job (TASK-507).
# The check returns a suggested version of the question that states what a static reading can show,
# with one reason per change. A question whose wording would make every answer be refused costs the
# account nothing: the job is not created, the suggestion is printed for the caller (usually a model
# reading stdout) and the command exits 15. --accept-suggested submits the suggested question,
# --as-typed submits the typed one; both record the check. A check that fails, times out, is over
# its daily limit or is not deployed does not block the run, as the web Ask dialog treats
# `check_unavailable` (apps/web/src/app/components/AskSteps.tsx).
# shellcheck shell=bash disable=SC2034

# The check's limit on the question (crates/api/src/llm.rs MAX_PROMPT_CHARS). The job create route
# of a prompt thread takes 5,000 characters (crates/api/src/prompts.rs), so a longer question is
# submitted without a check rather than refused here.
CHECK_MAX_CHARS=4000

# The exit code of a question whose wording the check changed, with neither flag given.
CHECK_EXIT=15

# The prefix of every printed line of a question (TASK-507 D1). A fence line drawn from the same
# alphabet as the question collides with a question that holds that line, and the caller then
# resubmits the wrong text. Prefixing each line cannot collide: a question line that already starts
# with `Q>` is printed with one more `Q>`, and stripping exactly one prefix from each line of the
# block and joining the results with a newline recovers the question whatever it holds.
# The block's header states how many lines the question is, and that count is what bounds the block
# (D11). The first rule said only that a prefixed line is question text, which is false of the rest
# of stdout: the two re-run lines hold the typed question verbatim and `--wait` prints the answer
# after the block, so a typed line or an answer line that starts with `Q>` is a prefixed line
# outside the question. A count collides with no question content and no later line of stdout
# extends it.
CHECK_LINE_PREFIX='Q>'

# The largest signed 64-bit integer. `check_id` is `Option<i64>` on every job create route
# (services/research/crates/api/src/prompts.rs:138, llm.rs:70, cross.rs:40, facts_question.rs:39)
# and `i64` in the check's response (question_check.rs:93), so a larger digit string is unusable:
# the route rejects the body and the job is not created (D12).
CHECK_ID_MAX=9223372036854775807

# Set by check_question: ready, changes, unavailable or too_long, with the check's fields.
CHECK_STATUS=""
CHECK_ID=""
CHECK_SUGGESTED=""
CHECK_CHANGES="[]"
CHECK_PROOF=false
CHECK_CHARS=0
CHECK_REASON=""

# Set by check_gate: the question to submit, and the check_id for the job create route (empty when
# there is none to send).
CHECK_PROMPT=""
CHECK_SEND_ID=""

# Set by the command before check_gate: the command as given, for the two printed re-runs.
CHECK_RERUN=""

# Set by the command's flag parsing.
OPT_AS_TYPED=0
OPT_ACCEPT_SUGGESTED=0

# take_check_flag ARG: consumes --as-typed and --accept-suggested; returns 1 when ARG is neither.
take_check_flag() {
  case "$1" in
    --as-typed) OPT_AS_TYPED=1 ;;
    --accept-suggested) OPT_ACCEPT_SUGGESTED=1 ;;
    *) return 1 ;;
  esac
  return 0
}

# check_flags_ok: the two flags exclude each other.
check_flags_ok() {
  [ "$OPT_AS_TYPED" = 0 ] || [ "$OPT_ACCEPT_SUGGESTED" = 0 ] \
    || usage_error "use --as-typed or --accept-suggested, not both"
}

# check_id_ok VALUE: a JSON non-negative integer an i64 holds. `is_uint` (common.sh:576) passes any
# digit string and its other callers (file sizes, timeouts, offsets, project ids) depend on that
# contract, so the i64 bound is checked here, where the value is printed and sent (D12). The
# comparison is on the string: bash arithmetic on a digit string over the i64 range is itself
# truncated.
check_id_ok() {
  is_uint "$1" || return 1
  local n="$1"
  while [ "${#n}" -gt 1 ] && [ "${n#0}" != "$n" ]; do n="${n#0}"; done
  [ "${#n}" -lt "${#CHECK_ID_MAX}" ] && return 0
  [ "${#n}" -eq "${#CHECK_ID_MAX}" ] || return 1
  # shellcheck disable=SC2071 # a string comparison on purpose: -gt truncates a digit string this wide
  [[ "$n" > "$CHECK_ID_MAX" ]] && return 1
  return 0
}

# check_label: how the check is named in a printed line: its number, or that the response held no
# usable number (a check_id that is not a JSON non-negative integer an i64 holds is never printed
# and never sent, so that no response text reaches a printed command).
check_label() {
  if check_id_ok "$CHECK_ID"; then printf 'check %s' "$CHECK_ID"; else printf 'check id unavailable'; fi
}

# check_id_null: the CHECK_ID as a JSON value: the number, or null.
check_id_null() {
  if check_id_ok "$CHECK_ID"; then printf '%s' "$CHECK_ID"; else printf 'null'; fi
}

# check_block LABEL TEXT: LABEL, the question's line count, the recovery rule scoped to that count,
# then TEXT with CHECK_LINE_PREFIX on every line. A TEXT ending in a newline ends in a prefixed
# empty line, which the count includes, so a trailing newline is recoverable. The count and the
# lines come from one jq expression, so they cannot disagree.
check_block() {
  jq -nrj --arg l "$1" --arg c "$(check_label)" --arg s "$2" --arg p "$CHECK_LINE_PREFIX" '
    ($s | split("\n") | map($p + .)) as $q
    | ($q | length) as $n
    | (if $n == 1 then "line" else "lines" end) as $w
    | "\($l) (\($c)), question lines: \($n). The question is the next \($n) printed \($w), each with one \"\($p)\" prefix. Recover it from exactly \($n) \($w): strip one \"\($p)\" from each and join them with a newline. Every later line of this output is outside the question.\n"
      + ($q | join("\n")) + "\n"'
}

# check_question TYPE PROMPT APP_COUNT: one POST /questions/check, never fatal. Sets CHECK_STATUS
# to ready (nothing to change), changes, too_long (over CHECK_MAX_CHARS, not sent) or unavailable
# (any failure, with CHECK_REASON).
check_question() {
  local kind="$1" p="$2" n="$3" body out error
  CHECK_STATUS=""
  CHECK_ID=""
  CHECK_SUGGESTED="$p"
  CHECK_CHANGES="[]"
  CHECK_PROOF=false
  CHECK_REASON=""
  CHECK_CHARS="$(jq -rn --arg p "$p" '$p | length')"
  if ! is_uint "$CHECK_CHARS"; then CHECK_CHARS=0; fi
  if [ "$CHECK_CHARS" -gt "$CHECK_MAX_CHARS" ]; then
    CHECK_STATUS=too_long
    return 0
  fi
  body="$(tmpfile check_body)"
  jq -nc --arg t "$kind" --arg p "$p" --argjson n "$n" '{type: $t, prompt: $p, app_count: $n}' >"$body"
  out="$(tmpfile check_resp)"
  HTTP_RETRY=no
  HTTP_MAX_TIME=30
  HTTP_OUT="$out"
  http POST "$CITT_V1/questions/check" "$body"
  if ! ok; then
    CHECK_STATUS=unavailable
    error="$(jq -r '.error // empty' "$out" 2>/dev/null)"
    if [ "$CODE" = 000 ]; then
      CHECK_REASON="no response from $CITT_HOST: $NET_REASON"
    else
      CHECK_REASON="HTTP $CODE${error:+ $error}"
    fi
    return 0
  fi
  CHECK_ID="$(jq -r '.check_id // empty' "$out" 2>/dev/null)"
  # -j and the X guard keep every byte of `suggested`, including a trailing newline (D5). A CR is
  # deleted here, once, so that the --json field, the prefixed stdout lines (where `clean` deletes
  # a CR for SEC-10) and the text --accept-suggested submits are the same bytes (D4).
  CHECK_SUGGESTED="$(jq -rj '.suggested // empty' "$out" 2>/dev/null; printf X)"
  CHECK_SUGGESTED="${CHECK_SUGGESTED%X}"
  CHECK_SUGGESTED="${CHECK_SUGGESTED//$'\r'/}"
  CHECK_CHANGES="$(jq -c '[(.changes // [])[] | {from: (.from // ""), to: (.to // ""), why: (.why // "")}]' "$out" 2>/dev/null)"
  CHECK_PROOF="$(jq -r 'if .proof_note == true then "true" else "false" end' "$out" 2>/dev/null)"
  if [ -z "$CHECK_SUGGESTED" ] || [ -z "$CHECK_CHANGES" ]; then
    CHECK_STATUS=unavailable
    CHECK_REASON="unparseable response from POST $CITT_V1/questions/check"
    CHECK_SUGGESTED="$p"
    CHECK_CHANGES="[]"
    CHECK_ID=""
    return 0
  fi
  # A check_id that is not a JSON non-negative integer an i64 holds is dropped, and the changes
  # still gate the question (D7, D12): the gate follows the changes, the printed commands and the
  # job body hold a number or nothing.
  if ! check_id_ok "$CHECK_ID"; then CHECK_ID=""; fi
  # A suggestion equal to the typed question changes nothing, whatever `changes` holds, so the job
  # is created and a caller that resubmits `.suggested` terminates (D3).
  if [ "$CHECK_CHANGES" = "[]" ] || [ "$CHECK_SUGGESTED" = "$p" ]; then
    CHECK_STATUS=ready
  else
    CHECK_STATUS=changes
  fi
  return 0
}

# check_gate TYPE PROMPT APP_COUNT: the check and what follows from it. Sets CHECK_PROMPT (the
# question to submit) and CHECK_SEND_ID (the check_id for a job create route that takes one). A
# suggested change without --as-typed or --accept-suggested prints the suggestion and exits
# CHECK_EXIT without creating a job.
check_gate() {
  check_question "$@"
  CHECK_PROMPT="$2"
  CHECK_SEND_ID=""
  [ -n "$CHECK_RERUN" ] || CHECK_RERUN="$CITT_CMD"
  case "$CHECK_STATUS" in
    too_long)
      err "$CITT_CMD: the question is $CHECK_CHARS characters, over the check's 4,000-character limit; it was not checked, and is submitted as typed"
      return 0
      ;;
    unavailable)
      err "$CITT_CMD: the question check did not run ($CHECK_REASON); the question is submitted as typed"
      return 0
      ;;
    ready)
      CHECK_SEND_ID="$CHECK_ID"
      [ -n "$CHECK_ID" ] \
        || err "$CITT_CMD: the question check returned no check id; the question is submitted as typed and the check is not recorded"
      return 0
      ;;
  esac
  CHECK_SEND_ID="$CHECK_ID"
  if [ "$OPT_ACCEPT_SUGGESTED" = 1 ]; then
    # The empty-question guard of the typed text applies to the suggested text too (D8).
    [ -n "$(printf '%s' "$CHECK_SUGGESTED" | tr -d ' \t\r\n')" ] \
      || die 1 "the suggested question is empty; no job was created ($(check_label))"
    CHECK_PROMPT="$CHECK_SUGGESTED"
    err "$CITT_CMD: the suggested question is submitted ($(check_label))"
    if [ "$CITT_JSON" != 1 ]; then
      check_block "Submitted question" "$CHECK_SUGGESTED"
    fi
    return 0
  fi
  if [ "$OPT_AS_TYPED" = 1 ]; then
    err "$CITT_CMD: the suggestion was declined; the question is submitted as typed ($(check_label))"
    return 0
  fi
  check_refuse
}

# check_refuse: the suggestion on stdout (one --json document, or the prefixed question and one
# line per change) and exit CHECK_EXIT. No job was created and nothing was charged.
check_refuse() {
  local msg="the question's wording would make the answers be refused; no job was created and nothing was charged"
  err "$CITT_CMD: $msg ($(check_label))"
  if [ "$CITT_JSON" = 1 ]; then
    jq -nc --argjson id "$(check_id_null)" --arg s "$CHECK_SUGGESTED" --argjson c "$CHECK_CHANGES" \
      --argjson p "$CHECK_PROOF" --arg m "$msg" --argjson x "$CHECK_EXIT" --arg r "$CHECK_RERUN" \
      '{error: "question_check_changes", message: $m, http_status: null, exit: $x,
        check_id: $id, suggested: $s, changes: $c, proof_note: $p,
        accept_command: "\($r) --accept-suggested", as_typed_command: "\($r) --as-typed"}'
  else
    check_block "Suggested question" "$CHECK_SUGGESTED"
    # Each field is printed as a JSON string, so a change whose text holds a newline or a quote is
    # still one line (D2).
    printf 'Changes, one per line, each field a JSON string:\n'
    jq -r '.[] | "  " + (.from | tojson) + " -> " + (.to | tojson) + ": " + (.why | tojson)' <<<"$CHECK_CHANGES"
    if [ "$CHECK_PROOF" = true ]; then
      printf 'The answers of this question end with the fixed proof line.\n'
    fi
    printf 'Submit the suggested question: %s --accept-suggested\nSubmit the question as typed: %s --as-typed\n' \
      "$CHECK_RERUN" "$CHECK_RERUN"
  fi
  exit "$CHECK_EXIT"
}

# check_id_json: the `--argjson cid` value of a job create body: the check_id, or null.
check_id_json() {
  if check_id_ok "$CHECK_SEND_ID"; then printf '%s' "$CHECK_SEND_ID"; else printf 'null'; fi
}

# check_doc: the `check` object a --json body carries when a suggestion was accepted or declined;
# empty when the check changed nothing or did not run (its line went to stderr).
check_doc() {
  [ "$CHECK_STATUS" = changes ] || return 0
  local sub
  if [ "$OPT_ACCEPT_SUGGESTED" = 1 ]; then
    sub=suggested
  elif [ "$OPT_AS_TYPED" = 1 ]; then
    sub=original
  else
    return 0
  fi
  jq -nc --argjson id "$(check_id_null)" --arg s "$CHECK_SUGGESTED" --argjson c "$CHECK_CHANGES" \
    --argjson p "$CHECK_PROOF" --arg sub "$sub" \
    '{check_id: $id, submitted: $sub, suggested: $s, changes: $c, proof_note: $p}'
}

# print_json_body FILE: the API body on stdout, with the check object added as `check` when there
# is one.
print_json_body() {
  local d out
  d="$(check_doc)"
  if [ -n "$d" ]; then
    out="$(jq -c --argjson c "$d" '. + {check: $c}' "$1" 2>/dev/null)" || out=""
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  cat "$1"
  printf '\n'
}
