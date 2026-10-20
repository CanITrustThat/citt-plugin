#!/usr/bin/env bash
# lib/cmd-verdict.sh: citt verdict (TASK-528 R4), a Researcher verdict on one finding.
# shellcheck shell=bash disable=SC2034

# verdict_cite ARG: sets CITE to one citation as compact JSON. capture:S/R is a captured request; PATH or
# PATH#LOCATOR a file of the build's tree (split at the last #, which Windows paths never hold).
verdict_cite() {
  local c="$1" path loc
  case "$c" in
    capture:*)
      [[ "${c#capture:}" =~ ^([0-9]+)/([0-9]+)$ ]] || usage_error "--cite capture: needs SESSION/REQUEST numbers, got: $c"
      CITE="$(jq -nc --argjson s "${BASH_REMATCH[1]}" --argjson r "${BASH_REMATCH[2]}" '{session_id: $s, request_id: $r}')"
      ;;
    *#*)
      path="${c%#*}"
      loc="${c##*#}"
      { [ -n "$path" ] && [ -n "$loc" ]; } || usage_error "--cite needs PATH#LOCATOR with both parts, got: $c"
      CITE="$(jq -nc --arg p "$path" --arg l "$loc" '{path: $p, locator: $l}')"
      ;;
    '') usage_error "--cite needs a value" ;;
    *) CITE="$(jq -nc --arg p "$c" '{path: $p}')" ;;
  esac
}

cmd_verdict() {
  local verdict="" reason="" have_reason=0 id="" n
  local cites
  cites="$(tmpfile cites)"
  : >"$cites"
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --verdict)
        need_value "$1" $#
        verdict="$2"
        shift
        ;;
      --reason)
        need_value "$1" $#
        reason="$2"
        have_reason=1
        shift
        ;;
      --cite)
        need_value "$1" $#
        verdict_cite "$2"
        printf '%s\n' "$CITE" >>"$cites"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_verdict
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$id" ] || usage_error "give one FINDING_ID"
        id="$1"
        ;;
    esac
    shift
  done
  check_project_flags optional
  [ -n "$id" ] || usage_error "give a FINDING_ID"
  [[ "$id" =~ ^f_[a-z2-7]{52}$ ]] || usage_error "not a finding id: $id"
  case "$verdict" in
    confirmed | false_positive | cleared) ;;
    '') usage_error "give --verdict confirmed, false_positive or cleared" ;;
    *) usage_error "--verdict needs confirmed, false_positive or cleared, got: $verdict" ;;
  esac
  [ "$have_reason" = 1 ] || usage_error "give --reason TEXT"
  [[ "$reason" =~ [^[:space:]] ]] || usage_error "--reason needs text"
  need_auth
  E_KIND=finding
  E_FINDING="$id"
  local pid=null
  if [ -n "$OPT_PROJECT" ] || [ -n "$OPT_PROJECT_ID" ]; then
    resolve_project
    pid="$PROJECT_ID"
    E_KIND=finding
  fi
  local body
  body="$(tmpfile verdict_body)"
  jq -sc --arg v "$verdict" --arg r "$reason" --argjson pid "$pid" \
    '{verdict: $v, reason: $r}
     + (if length > 0 then {citations: .} else {} end)
     + (if $pid == null then {} else {project_id: $pid} end)' "$cites" >"$body"
  call POST "$CITT_V1/findings/$id/verdicts" "$body"
  # Project and event ids go into the printed line: numbers only.
  jq -e '(.project_id | type) == "number" and (.event_id | type) == "number" and (.unchanged | type) == "boolean"' \
    "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from POST $CITT_V1/findings/$id/verdicts"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c . "$RESP"
    return 0
  fi
  jq -r --arg id "$id" --arg v "$verdict" '
    ($v | gsub("_"; " ")) as $label
    | "in project \(.project_id) (event \(.event_id))." as $tail
    | if $v == "cleared" then
        "Cleared the researcher verdict on \($id) in project \(.project_id) (event \(.event_id)); the latest scrutiny is the current verdict again."
      elif .unchanged then "Already recorded: researcher verdict \($label) on \($id) \($tail)"
      else "Recorded researcher verdict \($label) on \($id) \($tail)" end' "$RESP"
}
