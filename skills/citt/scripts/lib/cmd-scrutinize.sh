#!/usr/bin/env bash
# lib/cmd-scrutinize.sh: citt scrutinize.
# shellcheck shell=bash disable=SC2034

cmd_scrutinize() {
  local prompt="" wait=0 timeout=540 job_ids="" n id
  local -a ids
  ids=()
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --prompt)
        need_value "$1" $#
        prompt="$2"
        shift
        ;;
      --wait) wait=1 ;;
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      --job-id)
        need_value "$1" $#
        job_ids="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_scrutinize
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *) ids+=("$1") ;;
    esac
    shift
  done
  check_project_flags optional
  [ "${#ids[@]}" -gt 0 ] || usage_error "give one or more FINDING_IDs"
  for id in "${ids[@]}"; do
    [[ "$id" =~ ^f_[a-z2-7]{52}$ ]] || usage_error "not a finding id: $id"
  done
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  if [ -n "$job_ids" ]; then
    [[ "$job_ids" =~ ^[0-9]+(,[0-9]+)*$ ]] || usage_error "--job-id needs job numbers, comma-separated"
    wait=1
  fi
  need_auth
  E_KIND=finding
  E_FINDING="${ids[0]}"
  local pid=null
  if [ -n "$OPT_PROJECT" ] || [ -n "$OPT_PROJECT_ID" ]; then
    resolve_project
    pid="$PROJECT_ID"
    E_KIND=finding
  fi
  local jobs
  jobs="$(tmpfile jobs)"
  if [ -n "$job_ids" ]; then
    jq -nc --arg j "$job_ids" '{jobs: ($j | split(",") | map({job_id: tonumber}))}' >"$jobs"
  else
    local body
    body="$(tmpfile scr_body)"
    printf '%s\n' "${ids[@]}" | jq -Rn --arg p "$prompt" --argjson pid "$pid" \
      '{finding_ids: [inputs | select(. != "")]}
       + (if $p == "" then {} else {prompt: $p} end)
       + (if $pid == null then {} else {project_id: $pid} end)' >"$body"
    call POST "$CITT_V1/findings/scrutinize" "$body"
    # Job ids go into printed commands: numbers only.
    jq -e 'all(.jobs[]?; (.job_id | type) == "number" and .job_id >= 0 and (.job_id | floor) == .job_id)' "$RESP" >/dev/null \
      || die 1 "unexpected job id in the response from POST $CITT_V1/findings/scrutinize"
    cp "$RESP" "$jobs"
    if [ "$wait" = 0 ]; then
      if [ "$CITT_JSON" = 1 ]; then
        cat "$RESP"
        printf '\n'
        return 0
      fi
      jq -r --arg ref "$( [ "$pid" = null ] && printf -- '--project NAME' || project_ref)" --arg ids "${ids[*]}" '
        .jobs as $j
        | ($j | map(.finding_ids // [] | length) | add // 0) as $nf
        | ($j | map(.package_id) | unique | length) as $na
        | ($j | map(select(.deep_prepare_job_id != null) | .package_id) | unique) as $deep
        | "Queued scrutiny of \($nf) finding\(if $nf == 1 then "" else "s" end) in \($na) app\(if $na == 1 then "" else "s" end) (\($j | length) llm_scrutiny job\(if ($j | length) == 1 then "" else "s" end)"
          + (if ($deep | length) > 0 then "; " + ($deep | join(", ")) + (if ($deep | length) == 1 then " needs" else " need" end) + " deep preparation first" else "" end) + ").",
          "Jobs: " + ($j | map("\(.job_id) (\(.package_id), \(.finding_ids | length) finding\(if (.finding_ids | length) == 1 then "" else "s" end))") | join(", ")),
          "Next: citt scrutinize --wait \($ids) --job-id \($j | map(.job_id | tostring) | join(",")) or citt findings \($ref) --verdict none"' "$RESP" \
        || die 1 "unparseable scrutinize response"
      return 0
    fi
  fi

  # Wait: poll each finding until it has a scrutiny event of one of the jobs, or every one of
  # the jobs listed for it in scrutiny_jobs ended failed (or done without an event for it).
  local start pending done_list details failed fdoc
  start="$(now_s)"
  details="$(tmpfile details)"
  failed="$(tmpfile failed)"
  printf '{}' >"$details"
  printf '[]' >"$failed"
  pending="${ids[*]}"
  while :; do
    local still=""
    for id in $pending; do
      E_FINDING="$id"
      call GET "$CITT_V1/findings/$id"
      if jq -e --slurpfile j "$jobs" '[$j[0].jobs[].job_id] as $ids
          | any((.events // [])[]; .kind == "scrutiny" and ((.job_id) as $x | $ids | index($x)) != null)' "$RESP" >/dev/null 2>&1; then
        jq --arg id "$id" --slurpfile d "$RESP" '.[$id] = $d[0]' "$details" >"$details.n" && mv "$details.n" "$details"
        continue
      fi
      fdoc="$(jq -c --arg id "$id" --slurpfile j "$jobs" '
        [$j[0].jobs[] | select((.finding_ids // null) == null or ((.finding_ids | index($id)) != null)) | .job_id] as $mine
        | [(.scrutiny_jobs // [])[] | select((.job_id) as $x | $mine | index($x) != null)] as $sj
        | if ($sj | length) > 0 and all($sj[]; .state == "failed" or (.state == "done" and .event_id == null))
          then [$sj[] | {job_id, finding_id: $id,
                         reason: (if .state == "failed" then (.reason // {code: "unknown", message: "no reason given"})
                                  else {code: "no_verdict", message: "the job finished without a verdict for this finding"} end)}]
          else empty end' "$RESP" 2>/dev/null)"
      if [ -n "$fdoc" ]; then
        jq -r '.[] | "citt scrutinize: job \(.job_id) failed: \(.reason.message) (\(.reason.code))"' <<<"$fdoc" >&2
        jq -c --argjson f "$fdoc" '. + $f' "$failed" >"$failed.n" && mv "$failed.n" "$failed"
      else
        still="$still $id"
      fi
    done
    pending="${still# }"
    [ -n "$pending" ] || break
    if [ $(($(now_s) - start)) -ge "$timeout" ]; then break; fi
    poll_sleep ""
  done
  done_list="$(jq -r 'keys | length' "$details")"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --slurpfile j "$jobs" --slurpfile f "$failed" \
      '{schema: "citt.plugin.scrutinize/1", jobs: $j[0].jobs, findings: [.[]], failed: $f[0]}' "$details"
  elif [ "$done_list" -gt 0 ]; then
    printf '%s\n' "${ids[@]}" | jq -Rc --slurpfile d "$details" --slurpfile j "$jobs" '
      [$j[0].jobs[].job_id] as $jids
      | [["FINDING_ID", "VERDICT", "PROPOSED_SEVERITY", "CITATIONS", "RATIONALE"]]
      + [inputs | select(. != "") as $id | $d[0][$id] | select(. != null)
         | ([.events[] | select(.kind == "scrutiny" and ((.job_id) as $x | $jids | index($x)) != null)] | last) as $e
         | [$id, (if $e.verdict == "inconclusive" and $e.reason == "not_read" then "inconclusive (not read)" else ($e.verdict // "-") end),
            ($e.proposed_severity // "-"), (($e.evidence // []) | length),
            (($e.rationale // "") | gsub("[\r\n\t]+"; " ") | .[0:120])]]' -n | table
  fi
  if [ -n "$pending" ]; then
    local jl
    jl="$(jq -r '[.jobs[].job_id | tostring] | join(",")' "$jobs")"
    local ref=""
    [ "$pid" = null ] || ref=" $(project_ref)"
    err "citt scrutinize: still running after $timeout s; re-run: citt scrutinize $pending$ref --wait --job-id $jl"
    exit 12
  fi
  if [ "$(jq 'length' "$failed")" -gt 0 ]; then exit 8; fi
}
