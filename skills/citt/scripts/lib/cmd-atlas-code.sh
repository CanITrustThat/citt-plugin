#!/usr/bin/env bash
# lib/cmd-atlas-code.sh: citt code-search (TASK-1463, TASK-1466, TASK-1482, TASK-1502, TASK-1506).
# A literal or regex search over the decompiled app corpus. It calls the CITT backend's
# POST /api/research/v1/atlas/code/{count,search} routes (plugin -> backend -> navigator -> src
# router), reusing the stored token; the gate is the code_search entitlement (TASK-1467), whose 403
# code_search_not_enabled prints its own line and a next action. TASK-1502: every answer ends with a
# footer of labelled lines (matches, apps, shown, complete, next) computed from the answer contract of
# TASK-1500 (complete, counts, shards, window, resume_cursor, incomplete_reason), or derived from meta
# when the service has no contract fields; an incomplete answer that no cursor continues exits 12. A 200
# { code_search_available:false } is the backend's graceful-degrade state and prints the unavailable
# line with a next action (feedback-no-dead-ends). TASK-1506 (phase 2 contract of TASK-1500): --context N prints
# the lines around each match, --path GLOB restricts the file path, a walk follows the cursors of a service in
# positions mode to complete: yes, and a 501 code_search_feature_unavailable prints its message and a next action.
# TASK-1506 fix round 1 (the answers of TASK-1505 fix round 1): an app scan answers calls with no row, one cursor and
# counts that grow until the call that ends it, so a walk follows the cursor and stops only after 3 calls in a row
# with the same cursor and the same counts, at --max-rows or at --max-empty-pages; in the footer next: is a command
# and hint: a sentence. TASK-1508 (acceptance run of 2026-11-25): the case mode in the matches line, a walk that
# stops after 3 requests with no row and no change and then prints no continuing command, the number of files to read
# in the hint of a time stop, "none found so far" for a lower bound of 0, --append for the continuation file, the
# sentence and hint of no match under filters, and the time limit that applied in the complete: line.
# citt code-file (lib/cmd-code-file.sh) uses code_call of this file. Design:
# /data2/atlas-reports/deep-atlas-code-search-plan.md (sections 2, 3, 5 Phase 1).
# shellcheck shell=bash disable=SC2034,SC2016,SC2015,SC2153

CITT_ATLAS_CODE_BASE="$CITT_V1/atlas/code"

# code_unavailable: the backend returned 200 { code_search_available:false, reason, retry_after }.
# Prints the unavailable line (no internal mechanism name) and a next action, exits 8; with --json
# also emits the body. (feedback-no-dead-ends, feedback-no-staff-copy-for-customers.)
code_unavailable() {
  local reason retry msg next
  reason="$(body_field '.reason')"
  retry="$(body_field '.retry_after')"
  case "$reason" in
    timeout)
      msg="code search is unavailable, try again shortly (the service did not answer in time)"
      next="narrow with --package or --corpus, or raise --time-limit-ms"
      [ "$CITT_CMD" != "citt code-file" ] || next="try again shortly; --lines A-B reads a part of the file"
      ;;
    unreachable)
      msg="code search is unavailable, try again shortly (the service could not be reached)"
      next="try again shortly"
      ;;
    rate_limited)
      msg="code search is unavailable, too many requests"
      next="wait a moment, then run the search again"
      ;;
    no_literal_anchor)
      msg="code search could not run this pattern: it has no literal of 3 or more characters"
      next="add a literal substring to the pattern, or narrow with --package or --corpus"
      ;;
    *)
      msg="code search is unavailable, try again shortly"
      next="try again shortly"
      ;;
  esac
  if is_uint "$retry" && [ "$retry" -gt 0 ]; then msg="$msg; retry in $retry s"; fi
  err "$CITT_CMD: $msg"
  err "next: $next"
  [ "$CITT_JSON" != 1 ] || { cat "$RESP"; printf '\n'; }
  exit 8
}

# code_call METHOD PATH [BODY_FILE]: a backend code-search call, then the degrade check. E_KIND=atlas
# keeps a 404 on an undeployed route as the "update the plugin" line and a 403 atlas_not_enabled as
# the fixed disabled line. A 400 bad_cursor (a --cursor from another query or an expired window) is
# its own plain line and a next action, never the raw code/host/status (feedback-no-dead-ends,
# feedback-no-staff-copy-for-customers).
code_call() {
  local waits=0 ra ra_max why
  E_KIND=atlas
  while :; do
    http "$@"
    # TASK-1482: under --all and --out (CODE_ALL=1) a page refused by the per-account rate limit is
    # asked again after the service's retry time (1 to 30 s), up to 3 waits per page, so the pages
    # fetched so far are kept; a single request prints the refusal at once. TASK-1502 fix round 2: the
    # same for the two limits on searches at once of TASK-1501 (code_search_concurrency_limit,
    # code_search_long_search_limit), whose retry time is the rest of a search in progress (1 to 120 s).
    if [ "${CODE_ALL:-0}" = 1 ] && [ "$CODE" = 429 ] && [ "$waits" -lt 3 ]; then
      ra_max=0
      case "$(body_field '.error')" in
        code_search_rate_limited)
          ra_max=30
          why="too many searches in a short time"
          ;;
        code_search_concurrency_limit | code_search_long_search_limit)
          ra_max=120
          why="the most searches at once are in progress"
          ;;
      esac
      ra="$(body_field '.retry_after')"
      if [ "$ra_max" -gt 0 ] && is_uint "$ra" && [ "${#ra}" -le 3 ] && [ "$ra" -ge 1 ] && [ "$ra" -le "$ra_max" ]; then
        err "$CITT_CMD: $why; waiting $ra s, then continuing with the same page"
        sleep "$ra"
        waits=$((waits + 1))
        continue
      fi
    fi
    break
  done
  if ok; then
    if jq -e '.code_search_available == false' "$RESP" >/dev/null 2>&1; then
      code_unavailable
    fi
    return 0
  fi
  # TASK-1502 fix round 2: a cursor refused because the results of its query changed (TASK-1501: a count or a
  # first page searched again). A walk (CODE_CHANGED_RETURN=1) gets status 75 and starts again; a single page
  # prints the reason and the command without --cursor.
  if [ "$CODE" = 400 ] && [ "$(body_field '.error')" = bad_cursor ] \
    && jq -e '.results_changed == true' "$RESP" >/dev/null 2>&1; then
    [ "${CODE_CHANGED_RETURN:-0}" != 1 ] || return 75
    err "$CITT_CMD: the results of this search changed after the page that gave this --cursor value, so the next page cannot be read"
    err "next: $(_code_cmd same "$CS_TLM" "")"
    [ "$CITT_JSON" != 1 ] || { cat "$RESP"; printf '\n'; }
    exit 7
  fi
  if [ "$CODE" = 400 ] && [ "$(body_field '.error')" = bad_cursor ]; then
    err "$CITT_CMD: the --cursor value is not valid any more (it is from a different query or the result window expired)"
    err "next: run the search again without --cursor to start from the first page"
    [ "$CITT_JSON" != 1 ] || { cat "$RESP"; printf '\n'; }
    exit 7
  fi
  # TASK-1502: the 403 of an account without the code_search entitlement: the reason and a next action.
  if [ "$CODE" = 403 ] && [ "$(body_field '.error')" = code_search_not_enabled ]; then
    err "$CITT_CMD: code search is not enabled for this account (it needs the code_search entitlement)"
    err "next: contact support to have code search enabled for this account"
    [ "$CITT_JSON" != 1 ] || { cat "$RESP"; printf '\n'; }
    exit 3
  fi
  # TASK-1506: the file route has no file of this package at the path (citt code-file).
  if [ "$CODE" = 404 ] && [ "$(body_field '.error')" = code_file_not_found ] && [ "$CITT_CMD" = "citt code-file" ]; then
    _cf_not_found
  fi
  # TASK-1506: the service has no context lines, path filter or file read yet (TASK-1505: its engine lacks them).
  if [ "$CODE" = 501 ] && [ "$(body_field '.error')" = code_search_feature_unavailable ]; then
    code_feature_unavailable
  fi
  # TASK-1482: the 429 of the per-account rate limit (code_search_rate_limited) is a short wait, not a
  # limit of the plan: the service's message, its retry time and its next action, exit 6. Only the
  # 429 usage_limit_exceeded goes on to the limit line of fail_http.
  if [ "$CODE" = 429 ] && [ "$(body_field '.error')" != usage_limit_exceeded ]; then
    code_rate_limited
  fi
  fail_http
}

# code_feature_unavailable: the 501 code_search_feature_unavailable: the service's message with its request fields
# printed as the plugin's flags (the plugin's sentence when the message names an internal), and a next action: the
# same command without the flag the service lacks, or for a file the search inside the app. Exit 8; with --json
# the body unchanged on stdout.
code_feature_unavailable() {
  local feature msg next or="" both=0
  feature="$(body_field '.feature')"
  # One verdict of the service covers context lines and the path filter (TASK-1505 caps.rs), and its answer names
  # the first of the two fields: a request with both flags is refused for both.
  case "$feature" in context | path_globs) [ "${CS_CTX:-0}" = 0 ] || [ -z "${CS_PATHS_W:-}" ] || both=1 ;; esac
  msg="$(plain_message "$(body_field '.message')" \
    | sed -e 's/`context`/--context/g' -e 's/`path_globs`/--path/g' -e 's/`packages`/--package/g' -e 's/`//g')"
  msg="${msg%.}"
  if [ "$CITT_CMD" = "citt code-file" ]; then
    msg="${msg:-reading a file is not available on this server yet}"
    next="run citt code-search QUERY --package $(shq "${CF_PACKAGE:-PACKAGE}") to read lines of the file, or run this command again later"
  else
    case "$both$feature" in
      1*)
        msg="context lines (--context) and the path filter (--path) are not available on this server yet"
        next="$(_code_cmd plain "$CS_TLM" "")"
        or="run the same command again later"
        ;;
      0context)
        msg="${msg:-context lines (--context) are not available on this server yet}"
        next="$(_code_cmd noctx "$CS_TLM" "")"
        or="run the same command again later"
        ;;
      0path_globs)
        msg="${msg:-the path filter (--path) is not available on this server yet}"
        next="$(_code_cmd nopath "$CS_TLM" "")"
        or="run the same command again later"
        ;;
      *)
        msg="${msg:-a part of this request is not available on this server yet}"
        next="run the same command again later"
        ;;
    esac
  fi
  err "$CITT_CMD: $msg"
  err "next: $next"
  [ -z "$or" ] || err "or: $or"
  [ "$CITT_JSON" != 1 ] || { cat "$RESP"; printf '\n'; }
  exit 8
}

# code_rate_limited: the two stderr lines of a 429 that is not a usage limit, then exit 6; with --json
# the body unchanged on stdout. A message or next action that names an internal (plain_message) is
# replaced by the plugin's own sentence.
code_rate_limited() {
  local error msg next retry
  error="$(body_field '.error')"
  retry="$(body_field '.retry_after')"
  msg=""
  next=""
  case "$error" in
    code_search_rate_limited | code_search_concurrency_limit | code_search_long_search_limit)
      # The service's sentences, with its request field printed as the plugin's flag.
      msg="$(plain_message "$(body_field '.message')" | sed 's/time_limit_ms/--time-limit-ms/g')"
      next="$(plain_message "$(body_field '.next_action')" | sed 's/time_limit_ms/--time-limit-ms/g')"
      ;;
  esac
  case "$error" in
    code_search_rate_limited)
      msg="${msg:-too many code searches from this account in a short time}"
      next="${next:-wait a moment, then run the search again; fewer, narrower searches stay under the limit}"
      ;;
    code_search_concurrency_limit)
      msg="${msg:-the most code searches at once are in progress}"
      next="${next:-wait for a search in progress to end, then run the search again; run searches one after another}"
      ;;
    code_search_long_search_limit)
      msg="${msg:-the most code searches with a time limit above 30 s at once are in progress}"
      next="${next:-wait for one of them to end, then run the search again; a search with --time-limit-ms 30000 or less starts now}"
      ;;
    *)
      msg="too many requests from this account in a short time"
      next="wait a moment, then run the search again"
      ;;
  esac
  msg="${msg%.}"
  if is_uint "$retry" && [ "$retry" -gt 0 ]; then msg="$msg; retry in $retry s"; fi
  err "$CITT_CMD: $msg"
  err "next: $next"
  if [ "$CITT_JSON" = 1 ]; then
    if jq -e 'type == "object"' "$RESP" >/dev/null 2>&1; then
      cat "$RESP"
      printf '\n'
    else
      jq -nc --arg m "$msg" --arg n "$next" '{error: "http_error", message: $m, next_action: $n, http_status: 429}'
    fi
  fi
  exit 6
}

# _code_jarr ELEM...: a JSON array of the string elements (empty array for no elements).
_code_jarr() {
  local out="[]" e
  for e in "$@"; do out="$(jq -c --arg v "$e" '. + [$v]' <<<"$out")"; done
  printf '%s' "$out"
}

# _code_fresh ISO: a trailing "atlas data as of <local time>" line, nothing when ISO is empty/null.
_code_fresh() {
  local iso="$1" e
  [ -n "$iso" ] && [ "$iso" != null ] || return 0
  e="$(jq -rn --arg t "$iso" 'try ($t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch empty' 2>/dev/null)"
  [ -n "$e" ] || return 0
  printf 'atlas data as of %s\n' "$(local_time "$e")"
}

# --- the answer contract (TASK-1500, TASK-1502) --------------------------------------------------

CODE_CORPORA="java resource manifest string asset native js hermes dart"
# The largest --time-limit-ms: of a service with the contract fields, and of one without (TASK-1462).
CODE_TLM_MAX=120000
# The time limit of a request without --time-limit-ms (src_search/shape.rs DEFAULT_BUDGET_MS of the backend).
CODE_TLM_DEFAULT=30000
# Requests in a row with no row, the same cursor and the same numbers after which a walk stops (TASK-1508: 3).
CODE_STALL_REQUESTS=3
# The same for an --apps walk (QA round 1): one more than the 3 calls with no moved position after which the service
# ends an app scan itself with an answer that has no cursor (src_search/walk.rs STALL_CALLS), so the service decides
# the end of a scan and this stop is for a service that repeats one answer without end.
CODE_STALL_REQUESTS_APPS=4
CODE_TLM_MAX_LEGACY=30000
# The row window of a service without the contract fields (its CITT_SRC_WINDOW_SIZE).
CODE_LEGACY_WINDOW=1000
# The most --path globs of one search (TASK-1506): the bound of the service and of the code index.
CODE_PATHS_MAX=16
# The most pages in a row with no row that a walk of --all or --out reads (--max-empty-pages).
CODE_MAXEMPTY_DEFAULT=50

# JQ_CODE_NORM: `norm`, one view of a search or count body. tmax and noraise are read from the wording of the
# service's next_action of a time stop (TASK-1501 src_search/contract.rs): the largest time limit the service
# searches with ("time_limit_ms (max N)"), and whether a longer time limit changes nothing; the answer has no
# field for either. noprog and ended (TASK-1505 src_search/walk.rs) are read the same way: a call that made no
# progress, a walk that the service ended after a part of the index did not answer 3 times, and an app list at its
# largest size (appscan.rs; window.size is the row window and is not that bound); na is the sentence.
# The rest: A body with a boolean `complete` is read by its
# contract fields. A body without it is derived: incomplete when meta.truncated or a part of the index
# ran out of time or did not answer; the cursor is page.next_cursor; the counts are meta.total and
# meta.distinct_apps, exact only when complete and not marked as estimates.
JQ_CODE_NORM='def norm:
  . as $b
  | ($b.meta // {}) as $m
  | (($b.data | type) == "array") as $search
  | (($b.complete | type) == "boolean") as $has
  | (if $search then $m else $b end) as $s
  | (($s.shards_timeout // 0) > 0) as $lto
  | (($s.shards_failed // 0) > 0) as $lfail
  | ($m.truncated == true) as $ltr
  | (if $has then $b.complete else (($ltr or $lto or $lfail) | not) end) as $complete
  | (if $complete then null
     elif $has then (($b.incomplete_reason | strings)
                     // (if $b.window.capped == true then "row_cap"
                         elif ((($b.resume_cursor | strings) // "") != "") then "more_pages"
                         else "other" end))
     elif ($ltr and ($lto | not) and (($m.total // 0) >= '"$CODE_LEGACY_WINDOW"')) then "row_cap"
     elif ($ltr or $lto) then "time_limit"
     else "shard_failed" end) as $reason
  | (($b.next_action | strings) // "") as $na
  | {contract: $has, complete: $complete, reason: $reason,
     tmax: ([$na | match("time_limit_ms \\(max ([0-9]{4,6})\\)").captures[0].string] | first // ""),
     noraise: ($na | test("time_limit_ms is at its maximum|raising time_limit_ms does not change")),
     na: $na,
     noprog: ($na | test("made no progress")),
     ended: ($na | test("this walk ends here")),
     appbound: ($na | test("more apps than one app list can have")),
     cursor: (if $has then (($b.resume_cursor | strings) // ($b.page.next_cursor | strings) // "")
              else (($b.page.next_cursor | strings) // "") end),
     matches: (if ($b.counts.matches | type) == "object"
               then {value: ($b.counts.matches.value // 0), exact: ($complete and $b.counts.matches.exact == true)}
               elif $search then {value: ([($m.total // 0), ($b.data | length)] | max),
                                  exact: ($complete and $m.total_is_estimate != true)}
               else null end),
     apps: (if ($b.counts.apps | type) == "object"
            then {value: ($b.counts.apps.value // 0), exact: ($complete and $b.counts.apps.exact == true)}
            elif ($search and $m.distinct_apps != null)
            then {value: $m.distinct_apps, exact: ($complete and $m.distinct_apps_is_estimate != true)}
            else null end),
     candidate_files: ($b.counts.candidate_files // (if $search then null else $b.estimate end)),
     candidate_scope: ($b.candidate_files_scope // ""),
     window_size: ($b.window.size // ""),
     total: ($m.total // 0),
     elapsed_ms: (if ($m.elapsed_ms | type) == "number" then $m.elapsed_ms else -1 end),
     builds_not_loaded: ($m.builds_not_loaded // $b.builds_not_loaded // 0)};'

# _code_norm FILE: sets the N_* variables from the body in FILE.
_code_norm() {
  local sh
  sh="$(jq -r "$JQ_CODE_NORM"' norm | @sh "N_CONTRACT=\(.contract) N_COMPLETE=\(.complete) N_REASON=\(.reason // "") N_TMAX=\(.tmax) N_NORAISE=\(.noraise) N_NA=\(.na) N_NOPROG=\(.noprog) N_ENDED=\(.ended) N_APPBOUND=\(.appbound) N_CURSOR=\(.cursor) N_MV=\(.matches.value // "") N_ME=\(.matches.exact // false) N_AV=\(.apps.value // "") N_AE=\(.apps.exact // false) N_CF=\(.candidate_files // "") N_SCOPE=\(.candidate_scope) N_WIN=\(.window_size) N_TOTAL=\(.total) N_ELAPSED=\(.elapsed_ms) N_BNL=\(.builds_not_loaded)"' "$1" 2>/dev/null)" \
    || die 1 "unexpected response from the server"
  [ -n "$sh" ] || die 1 "unexpected response from the server"
  eval "$sh"
}

# _code_cmd VARIANT TIME_LIMIT CURSOR: the full command of a next step: the query and the flags of this call in a
# fixed order, with TIME_LIMIT and CURSOR (each left out when empty). VARIANT same: this call; search: without
# --count; cont: a walk continued at CURSOR, whose --out file is FILE.next.csv so the rows written stay (with
# --append when the file of this call is the continuation file already); noctx
# and nopath: this call without --context, or without --path; plain: without both (TASK-1506).
_code_cmd() {
  local variant="$1" tlm="$2" cursor="$3" w="$CS_FILTERS" o a
  [ "$variant" = nopath ] || [ "$variant" = plain ] || w="$w$CS_PATHS_W"
  [ "$variant" = noctx ] || [ "$variant" = plain ] || [ "$CS_CTX" = 0 ] || w="$w --context $CS_CTX"
  [ "$CS_APPS" != 1 ] || w="$w --apps"
  [ "$CS_COUNT" != 1 ] || [ "$variant" = search ] || w="$w --count"
  [ -z "$CS_LIMIT" ] || w="$w --limit $CS_LIMIT"
  [ "$CS_ALL" != 1 ] || w="$w --all"
  if [ -n "$CS_OUT" ]; then
    o="$CS_OUT"
    a="$CS_APPEND"
    # TASK-1508: the rows of every continuation are in one file. The first continuation of FILE.csv writes
    # FILE.next.csv; a continuation of a file with that ending, or of a file opened with --append, adds to it.
    if [ "$variant" = cont ] && [ "$a" != 1 ]; then
      case "$o" in
        *.next.csv | *.next) a=1 ;;
        *.csv) o="${o%.csv}.next.csv" ;;
        *) o="$o.next" ;;
      esac
    fi
    w="$w --out $(shq "$o")"
    [ "$a" != 1 ] || w="$w --append"
  fi
  [ -z "$CS_MAXROWS_ARG" ] || w="$w --max-rows $CS_MAXROWS_ARG"
  [ -z "$CS_MAXEMPTY_ARG" ] || w="$w --max-empty-pages $CS_MAXEMPTY_ARG"
  [ "$CS_JSON" != 1 ] || w="$w --json"
  [ -z "$tlm" ] || w="$w --time-limit-ms $tlm"
  [ -z "$cursor" ] || w="$w --cursor $(shq "$cursor")"
  case "$CS_QUERY" in
    -*) printf '%s%s -- %s' "$CITT_CMD" "$w" "$(shq "$CS_QUERY")" ;;
    *) printf '%s %s%s' "$CITT_CMD" "$(shq "$CS_QUERY")" "$w" ;;
  esac
}

# _code_limit_secs: the time limit that applied to the last request, in seconds ("30", "1.5"): --time-limit-ms, else
# the default of the service, and the largest limit of the service when its sentence names a lower one. Nothing for a
# service without the contract fields and when the service states that a longer limit does not change the stop (the
# limit that applied is then not in the answer).
_code_limit_secs() {
  local ms="${CS_TLM:-$CODE_TLM_DEFAULT}"
  [ "${N_CONTRACT:-}" = true ] && [ "${N_NORAISE:-}" != true ] || return 0
  if is_uint "${N_TMAX:-}" && [ "$N_TMAX" -ge 1000 ] && [ "$N_TMAX" -lt "$ms" ]; then ms="$N_TMAX"; fi
  if [ $((ms % 1000)) = 0 ]; then
    printf '%s' $((ms / 1000))
  else
    printf '%s.%s' $((ms / 1000)) $(((ms % 1000) / 100))
  fi
}

# _code_cost_hint: the hint of a time stop when the answer has the number of files the query has to read
# (TASK-1508), or nothing. Under --count the scan cost line is above the hint.
_code_cost_hint() {
  local how="a longer or rarer string reads fewer (--count shows the number)"
  is_uint "$N_CF" && [ "$N_CF" -gt 0 ] || return 0
  [ "$CS_COUNT" != 1 ] || how="a longer or rarer string reads fewer"
  printf 'this query has to read about %s files; %s, or limit it with --package or --corpus' "$N_CF" "$how"
}

# _code_join LAST ITEM...: the items joined by ", " and the last one by LAST.
_code_join() {
  local last="$1" out="" n i=0 e
  shift
  n=$#
  for e in "$@"; do
    i=$((i + 1))
    if [ "$i" = 1 ]; then
      out="$e"
    elif [ "$i" = "$n" ]; then
      out="$out$last$e"
    else
      out="$out, $e"
    fi
  done
  printf '%s' "$out"
}

# _code_empty_hint: the hint of a complete search with no match: only what applies to this command (TASK-1508).
_code_empty_hint() {
  set -- "check the spelling"
  [ "$CS_REGEX" = 1 ] || set -- "$@" "try --regex for a pattern"
  # shellcheck disable=SC2086
  [ -z "$CS_DROPS" ] || set -- "$@" "drop $(_code_join " or " $CS_DROPS)"
  _code_join ", or " "$@"
}

# _code_reason_text REASON: the plain words of an incomplete answer.
_code_reason_text() {
  local secs
  case "$1" in
    time_limit)
      secs="$(_code_limit_secs)"
      if [ -n "$secs" ]; then
        printf 'the search stopped at its %s s time limit before every candidate file was scanned' "$secs"
      else
        printf 'the search stopped at the time limit before every candidate file was scanned'
      fi
      ;;
    row_cap)
      if [ "${N_APPBOUND:-}" = true ]; then
        printf 'the app list is at its largest size and more apps have a match; the matches of its rows are lower bounds'
      elif is_uint "$N_WIN"; then
        printf 'the search stopped at %s collected rows and more matches exist' "$N_WIN"
      else
        printf 'the search stopped at its row cap and more matches exist'
      fi
      ;;
    shard_failed) printf 'part of the index did not answer, so some apps were not searched' ;;
    more_pages) printf 'more rows follow on the next page' ;;
    max_rows) printf 'stopped at --max-rows %s; more rows are available' "$CS_MAXROWS" ;;
    empty_pages) printf 'stopped after %s pages in a row with no row; the search is not at its end' "$CS_MAXEMPTY" ;;
    refused) printf 'a page was refused after %s rows' "$CS_ROWS" ;;
    changed) printf 'the results changed while paging' ;;
    *) printf 'the search did not finish' ;;
  esac
}

CODE_NARROW="narrow the search with --package or --corpus"
# TASK-1502 fix round 2: a time stop is narrowed first.
CODE_NARROW_TIME="narrow the search with --package, --corpus or a more specific query, then run it again"

# _code_service_hint: the next_action sentence of the service with its request fields as the plugin's flags
# (TASK-1506 fix round 1), or nothing when the sentence names an internal or still has a field name.
_code_service_hint() {
  local t
  t="$(plain_message "$N_NA" | sed -e 's/`//g' -e 's/time_limit_ms/--time-limit-ms/g' \
    -e 's/packages or corpora/--package or --corpus/g' -e 's/without a cursor/without --cursor/g')"
  case "$t" in
    *resume_cursor* | *time_limit_ms* | *packages* | *corpora* | *build_ids* | *shard* | *trigram*) return 0 ;;
  esac
  printf '%s' "$t"
}

# _code_verdict: from the N_* variables of the last answer and the state of the walk (CS_STOP, CS_ROWS), sets
# V_COMPLETE (yes or no), V_REASON, V_NEXT, V_HINT and V_EXIT. V_NEXT is a command to run as printed, or empty;
# V_HINT is a sentence (TASK-1506 fix round 1: before, V_NEXT was a command or a sentence and V_OR a second choice).
# Exit 0: a complete answer, a cursor that continues it, or a walk stopped at a bound of the plugin. Exit 12:
# incomplete with no cursor, or a walk that ended before its end with no bound (no command continues a walk whose
# last 3 requests changed nothing). A refused page keeps the exit code of its refusal.
_code_verdict() {
  local tmax="$CODE_TLM_MAX" cost=""
  [ "$N_CONTRACT" = true ] || tmax="$CODE_TLM_MAX_LEGACY"
  V_COMPLETE=yes
  V_REASON=""
  V_NEXT=""
  V_HINT=""
  V_EXIT=0
  if [ "$CS_STOP" = refused ]; then
    V_COMPLETE=no
    V_REASON="$(_code_reason_text refused)"
    V_NEXT="$(_code_cmd cont "$CS_TLM" "$CS_STOP_CURSOR")"
    V_EXIT="$CS_STOP_RC"
    return 0
  fi
  # The results changed twice in one walk: the rows of the current walk are kept; the same call reads them again.
  if [ "$CS_STOP" = changed ]; then
    V_COMPLETE=no
    V_REASON="$(_code_reason_text changed)"
    V_NEXT="$(_code_cmd same "$CS_TLM" "")"
    V_EXIT=12
    return 0
  fi
  # 3 requests in a row with no row, the same cursor and the same numbers: the rows fetched are kept. TASK-1508: no
  # command continues at that cursor (run as printed on prod it took 216 s and ended with the same line); the hint
  # has the number of files the query has to read when the answer has it.
  if [ "$CS_STOP" = stalled ]; then
    V_COMPLETE=no
    V_REASON="$(_code_reason_text "$N_REASON")"
    [ "$N_REASON" != time_limit ] || cost="$(_code_cost_hint)"
    V_HINT="the last $CS_STALL_N requests brought no row and no change of the numbers; ${cost:-$CODE_NARROW_TIME}"
    V_EXIT=12
    return 0
  fi
  if [ "$CS_STOP" = max_rows ]; then
    V_COMPLETE=no
    V_REASON="$(_code_reason_text max_rows)"
    V_NEXT="$(_code_cmd cont "$CS_TLM" "$N_CURSOR")"
    V_HINT="$CODE_NARROW, or raise --max-rows"
    return 0
  fi
  if [ "$CS_STOP" = empty_pages ]; then
    V_COMPLETE=no
    V_REASON="$(_code_reason_text empty_pages)"
    V_NEXT="$(_code_cmd cont "$CS_TLM" "$N_CURSOR")"
    V_HINT="$CODE_NARROW or a more specific query, or raise --max-empty-pages"
    return 0
  fi
  if [ "$N_COMPLETE" != true ]; then
    V_COMPLETE=no
    V_REASON="$(_code_reason_text "$N_REASON")"
  fi
  if [ -n "$N_CURSOR" ] && [ "$CS_COUNT" != 1 ]; then
    V_NEXT="$(_code_cmd same "$CS_TLM" "$N_CURSOR")"
    return 0
  fi
  if [ "$N_COMPLETE" = true ]; then
    if [ "$N_MV" = 0 ]; then
      V_HINT="$(_code_empty_hint)"
    elif [ "$CS_COUNT" = 1 ]; then
      V_NEXT="$(_code_cmd search "" "")"
    fi
    return 0
  fi
  V_EXIT=12
  case "$N_REASON" in
    time_limit)
      # The service searches with at most its own limit, which may be below CODE_TLM_MAX: the value of the
      # command is the maximum of the service's sentence when it has one.
      # TASK-1508: with the number of files to read in the answer, the hint names it.
      V_HINT="$(_code_cost_hint)"
      V_HINT="${V_HINT:-$CODE_NARROW_TIME}"
      if [ "$N_NOPROG" = true ]; then
        # No progress (TASK-1505): the sentence of the service; a longer time limit only when it names one.
        V_HINT="$(_code_service_hint)"
        V_HINT="${V_HINT:-$CODE_NARROW_TIME}"
        is_uint "$N_TMAX" || tmax=0
      fi
      if is_uint "$N_TMAX" && [ "$N_TMAX" -ge 1000 ] && [ "$N_TMAX" -le "$CODE_TLM_MAX" ]; then tmax="$N_TMAX"; fi
      if [ "$N_NORAISE" != true ] && [ "$tmax" -gt 0 ] && { [ -z "$CS_TLM" ] || [ "$CS_TLM" -lt "$tmax" ]; }; then
        V_NEXT="$(_code_cmd same "$tmax" "")"
      fi
      ;;
    shard_failed)
      V_NEXT="$(_code_cmd same "$CS_TLM" "")"
      [ "$N_ENDED" != true ] || V_HINT="$(_code_service_hint)"
      ;;
    *) V_HINT="$CODE_NARROW, then run it again" ;;
  esac
}

# _code_no_match: the sentence of an answer with no row, by its cause (TASK-1482): an empty page past the last
# match; a search stopped before its end, where no match is not established for the files not scanned; a part of the
# index that did not answer; a complete search.
_code_no_match() {
  local secs=""
  if is_uint "$N_ELAPSED" && [ "$N_ELAPSED" -ge 500 ]; then secs=" in $(((N_ELAPSED + 500) / 1000)) s"; fi
  # TASK-1506 fix round 1: an answer with no row that a cursor continues, and a call that made no progress: the
  # rows are not at their end, so "no more matches" is not printed.
  if [ "$N_COMPLETE" != true ] && [ -n "$N_CURSOR" ] && [ -z "$V_NEXT" ] && [ "$CS_APPS" = 1 ]; then
    # TASK-1508: a walk that stopped with no continuing command.
    printf 'no app row yet for "%s": the scan stopped before it ended, so no app is listed\n' "$CS_QUERY"
  elif [ "$N_COMPLETE" != true ] && [ -n "$N_CURSOR" ] && [ -z "$V_NEXT" ]; then
    printf 'no matching line for "%s" in the files read so far\n' "$CS_QUERY"
  elif [ "$N_COMPLETE" != true ] && [ -n "$N_CURSOR" ] && [ "$CS_APPS" = 1 ]; then
    printf 'no app row yet for "%s": the rows are listed when the scan has ended, and the next: command continues the scan\n' "$CS_QUERY"
  elif [ "$N_COMPLETE" != true ] && [ -n "$N_CURSOR" ]; then
    printf 'no matching line for "%s" in the files read by this request; the next: command continues the search\n' "$CS_QUERY"
  elif [ "$N_COMPLETE" != true ] && [ "$N_CONTRACT" = true ] && is_uint "$N_TOTAL" && [ "$N_TOTAL" -gt 0 ] \
    && { [ "$N_NOPROG" = true ] || [ "$N_ENDED" = true ]; }; then
    printf 'no further match for "%s" in the files read by this request: %s\n' "$CS_QUERY" "$V_REASON"
  elif is_uint "$N_TOTAL" && [ "$N_TOTAL" -gt 0 ]; then
    printf 'no more matches for "%s": all %s matches collected for this search were shown\n' "$CS_QUERY" "$N_TOTAL"
  elif [ "$N_COMPLETE" = true ] && [ "$CS_FILTERED" = 1 ]; then
    # TASK-1508: under --package, --build-id, --corpus or --path the search covered a part of the apps and files.
    printf 'no code matches "%s" in the apps and paths of this search\n' "$CS_QUERY"
  elif [ "$N_COMPLETE" = true ]; then
    printf 'no code matches "%s" in any indexed app (every candidate file was scanned)\n' "$CS_QUERY"
  elif [ "$N_REASON" = shard_failed ]; then
    printf 'no match for "%s" in the part of the index that answered: %s\n' "$CS_QUERY" "$(_code_reason_text shard_failed)"
  else
    printf 'no match for "%s" in the files scanned%s: %s\n' "$CS_QUERY" "$secs" "$(_code_reason_text "$N_REASON")"
  fi
}

# _code_count_line LABEL VALUE EXACT [NOTE]: "matches: N (exact)", "matches: at least N", or for a lower bound of 0
# "matches: none found so far" (TASK-1508: "0 (exact)" is absent, a lower bound of 0 is not reached yet). NOTE is
# added in brackets: the case mode of a --case-sensitive search.
_code_count_line() {
  local note="${4:-}"
  if [ "$3" = true ]; then
    printf '%s: %s (exact%s)\n' "$1" "$2" "${note:+, $note}"
  elif [ "$2" = 0 ]; then
    printf '%s: none found so far%s\n' "$1" "${note:+ ($note)}"
  else
    printf '%s: at least %s%s\n' "$1" "$2" "${note:+ ($note)}"
  fi
}

# _code_append_guard: QA round 1 finding 2. A walk with --append whose next: command has no --cursor (a stop that no
# cursor continues: the time limit, a part of the index that did not answer, results that changed) would read the
# search from its first page and add the rows of the file again. No command is printed then; the hint says what the
# file has and how to search from the first page.
_code_append_guard() {
  local how="" t
  [ "$CS_APPEND" = 1 ] && [ -n "$V_NEXT" ] || return 0
  case "$V_NEXT" in *" --cursor "*) return 0 ;; esac
  case "$V_NEXT" in
    *" --time-limit-ms "*)
      t="${V_NEXT##* --time-limit-ms }"
      t="${t%% *}"
      ! is_uint "$t" || [ "$t" = "$CS_TLM" ] || how=" (with --time-limit-ms $t for a longer time limit)"
      ;;
  esac
  V_NEXT=""
  V_HINT="$CS_OUT has the rows of this search up to this stop, and the same command from the first page would add them again; to search from the first page, give --out a new file without --append$how"
}

# _code_footer [SHOWN_LINE]: the labelled lines of every answer: matches, apps, the shown or written line, complete,
# the scan cost of a count, next (a command) and hint (a sentence). Needs _code_verdict.
_code_footer() {
  local note=""
  [ "$CS_CASE" != 1 ] || note="case-sensitive"
  if [ -n "$N_MV" ]; then
    _code_count_line matches "$N_MV" "$N_ME" "$note"
  else
    printf 'matches: unknown (this server counts candidate files only)\n'
  fi
  [ -z "$N_AV" ] || _code_count_line apps "$N_AV" "$N_AE"
  [ -z "${1:-}" ] || printf '%s\n' "$1"
  if [ "$V_COMPLETE" = yes ]; then
    printf 'complete: yes\n'
  else
    printf 'complete: no (%s)\n' "$V_REASON"
  fi
  if [ "$CS_COUNT" = 1 ] && [ -n "$N_CF" ]; then
    if [ "$N_SCOPE" = before_corpus_filter ] && [ "$CS_HAS_CORPUS" = 1 ]; then
      printf 'scan cost: about %s candidate files (counted before the --corpus filter)\n' "$N_CF"
    else
      printf 'scan cost: about %s candidate files\n' "$N_CF"
    fi
  fi
  if is_uint "$N_BNL" && [ "$N_BNL" -gt 0 ]; then printf '%s builds are not yet indexed.\n' "$N_BNL"; fi
  [ -z "$V_NEXT" ] || printf 'next: %s\n' "$V_NEXT"
  [ -z "$V_HINT" ] || printf 'hint: %s\n' "$V_HINT"
}

# _code_json_incomplete: with --json the document is stdout; an incomplete answer that ends the command (exit 12,
# a refused page, a stop at --max-rows) has its reason and next step on stderr.
_code_json_incomplete() {
  [ "$V_COMPLETE" = no ] || return 0
  [ "$V_EXIT" != 0 ] || [ -n "$CS_STOP" ] || return 0
  err "$CITT_CMD: the answer is incomplete: $V_REASON"
  [ -z "$V_NEXT" ] || err "next: $V_NEXT"
  [ -z "$V_HINT" ] || err "hint: $V_HINT"
}

# --- pages -------------------------------------------------------------------------------------

# _code_progress PAGES: the progress line of a walk on stderr, with the matches found so far (TASK-1508), so that a
# scan with no row yet shows its movement.
_code_progress() {
  local m=""
  if is_uint "$N_MV"; then
    if [ "$N_ME" = true ]; then
      m=", $N_MV matches found"
    elif [ "$N_MV" = 0 ]; then
      m=", no match found so far"
    else
      m=", at least $N_MV matches found"
    fi
  fi
  err "$CITT_CMD: page $1 fetched, $CS_ROWS rows so far$m"
}

# _code_pager BASEBODY STARTCURSOR: POSTs the search with the base body plus the cursor of each page: one page, or
# under CS_WALK every page until the answer has no cursor (TASK-1502: no page cap), the rows reach CS_MAXROWS, or
# CS_MAXEMPTY pages in a row had no row (CS_STOP=empty_pages), or 3 requests in a row changed nothing (stalled).
# The rows are appended to $CODE_DATA (one JSON row per line), the last answer is kept in $CODE_LAST and read into
# the N_* variables. A page after the first that is refused ends the walk with the rows fetched (CS_STOP=refused,
# CS_STOP_RC its exit code, CS_STOP_CURSOR its cursor); the refusal lines are on stderr.
_code_pager() {
  local basebody="$1" cursor="$2" start="$2" pages=0 body n rc restarts=0 sent empty=0 same=0 key prev="" d
  CS_STALL_N="$CODE_STALL_REQUESTS"
  [ "$CS_APPS" != 1 ] || CS_STALL_N="$CODE_STALL_REQUESTS_APPS"
  CODE_DATA="$(tmpfile code_data)"
  CODE_LAST="$(tmpfile code_last)"
  CS_ROWS=0
  CS_STOP=""
  CS_STOP_RC=0
  CS_STOP_CURSOR=""
  body="$(tmpfile code_page_body)"
  while :; do
    if [ -n "$cursor" ]; then
      jq -c --arg c "$cursor" '. + {cursor:$c}' "$basebody" >"$body"
    else
      cp "$basebody" "$body"
    fi
    rc=0
    sent="$cursor"
    if [ "$pages" = 0 ] && { [ "$CS_WALK" != 1 ] || [ -z "$cursor" ]; }; then
      code_call POST "$CITT_ATLAS_CODE_BASE/search" "$body"
    elif [ "$pages" = 0 ]; then
      # The first request of a walk started with --cursor: any other refusal ends the command in code_call.
      CODE_CHANGED_RETURN=1
      code_call POST "$CITT_ATLAS_CODE_BASE/search" "$body" || rc=$?
      CODE_CHANGED_RETURN=0
    else
      (
        CODE_CHANGED_RETURN=1
        code_call POST "$CITT_ATLAS_CODE_BASE/search" "$body"
      ) >/dev/null || rc=$?
    fi
    if [ "$rc" = 75 ]; then
      # TASK-1502 fix round 2: the results changed (400 bad_cursor, results_changed). The walk starts again
      # from the first page once, without the rows read so far, which may be in the new result again; a
      # second change ends the walk with the rows of the current walk.
      if [ "$restarts" = 0 ]; then
        restarts=1
        err "$CITT_CMD: the results changed while paging; starting again from the first page (the $CS_ROWS rows read so far are dropped)"
        : >"$CODE_DATA"
        CS_ROWS=0
        pages=0
        empty=0
        same=0
        prev=""
        cursor=""
        start=""
        continue
      fi
      err "$CITT_CMD: the results changed while paging a second time; the $CS_ROWS rows of this walk are kept"
      CS_STOP=changed
      break
    fi
    if [ "$pages" != 0 ]; then
      if [ "$rc" != 0 ]; then
        CS_STOP=refused
        CS_STOP_RC="$rc"
        CS_STOP_CURSOR="$cursor"
        break
      fi
    fi
    jq -e '.data | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
    if [ "$CS_APPS" = 1 ] && jq -e '.data | length > 0 and ((.[0].sample | type) != "object")' "$RESP" >/dev/null 2>&1; then
      die 10 "this server does not offer --apps yet; run the search without --apps, or try again later"
    fi
    # TASK-1506: a service before the phase 2 contract ignores the request field and its rows have no context.
    if [ "$CS_CTX" != 0 ] && jq -e '.data | length > 0 and all(.[]; has("context_before") | not)' "$RESP" >/dev/null 2>&1; then
      die 10 "this server does not offer --context yet; run the search without --context, or try again later"
    fi
    n="$(jq '.data | length' "$RESP")"
    jq -c '.data[]' "$RESP" >>"$CODE_DATA"
    cp "$RESP" "$CODE_LAST"
    CS_ROWS=$((CS_ROWS + n))
    pages=$((pages + 1))
    _code_norm "$CODE_LAST"
    cursor="$N_CURSOR"
    # TASK-1506 fix round 1: a page with no row and a cursor. The backend of TASK-1505 ends a search that makes no
    # progress itself (no cursor), and an app scan answers calls with no row, one cursor and counts that grow until
    # the call that ends it. So the walk follows the cursor; it is stalled only after 3 requests in a row with no row,
    # one cursor and the same counts, and it is bounded by --max-empty-pages.
    # QA round 1: the number of files read is in the key. A call of an app scan that moved forward and found no new
    # app answers the cursor and the counts of the call before (appscan.rs), and the files read are summed over the
    # steps of every call (walk.rs Summary::apply), so they grow with each step the service got an answer for.
    key="$cursor|$N_MV|$N_AV|$N_CF"
    if [ "$n" = 0 ] && [ "$N_COMPLETE" != true ] && [ -n "$cursor" ]; then
      empty=$((empty + 1))
      if [ "$cursor" = "$sent" ] && [ "$key" = "$prev" ]; then same=$((same + 1)); else same=0; fi
      # TASK-1508: `same` counts the repeats of an answer, so CODE_STALL_REQUESTS requests are 1 answer and its
      # repeats (before: 3 repeats, 4 requests).
      if [ "$CS_WALK" = 1 ] && [ "$same" -ge $((CS_STALL_N - 1)) ]; then
        _code_progress "$pages"
        CS_STOP=stalled
        break
      fi
      if [ "$CS_WALK" = 1 ] && [ "$CS_MAXEMPTY" -gt 0 ] && [ "$empty" -ge "$CS_MAXEMPTY" ]; then
        _code_progress "$pages"
        CS_STOP=empty_pages
        break
      fi
    else
      empty=0
      same=0
    fi
    prev="$key"
    [ "$CS_WALK" = 1 ] || break
    _code_progress "$pages"
    [ -n "$cursor" ] || break
    if [ "$CS_MAXROWS" -gt 0 ] && [ "$CS_ROWS" -ge "$CS_MAXROWS" ]; then
      CS_STOP=max_rows
      break
    fi
  done
  # A walk from the first page to the last page of a service without the contract fields counts its own rows.
  if [ "$N_CONTRACT" != true ] && [ "$CS_WALK" = 1 ] && [ -z "$start" ] && [ -z "$CS_STOP" ] && [ -z "$N_CURSOR" ]; then
    N_MV="$CS_ROWS"
    N_ME="$N_COMPLETE"
    N_AV="$(jq -s '[.[].package] | unique | length' "$CODE_DATA")"
    N_AE="$N_COMPLETE"
  elif is_uint "$N_MV" && [ "$CS_APPS" != 1 ] && [ "$N_MV" -lt "$CS_ROWS" ]; then
    N_MV="$CS_ROWS"
  fi
  # TASK-1506 fix round 1: the app number of a line page of positions mode is that of the page (TASK-1505 "Limits"),
  # so after a walk of line rows the apps: line is the number of apps of the rows of the walk: exact for a walk from
  # the first page to complete: yes whose rows are the exact number of matches, a lower bound otherwise.
  if [ "$N_CONTRACT" = true ] && [ "$CS_WALK" = 1 ] && [ "$CS_APPS" != 1 ] && [ "$N_AE" != true ] && is_uint "$N_AV"; then
    d="$(jq -s '[.[].package | strings] | unique | length' "$CODE_DATA")"
    if [ -z "$start" ] && [ -z "$CS_STOP" ] && [ -z "$N_CURSOR" ] && [ "$N_COMPLETE" = true ] && [ "$N_ME" = true ] \
      && [ "$N_MV" = "$CS_ROWS" ] && ! jq -e -s 'any(.[]; .package == null)' "$CODE_DATA" >/dev/null 2>&1; then
      N_AV="$d"
      N_AE=true
    elif [ "$d" -gt "$N_AV" ]; then
      N_AV="$d"
    fi
  fi
  # The counts of the last page are those of a result that the service has replaced.
  if [ "$CS_STOP" = changed ]; then
    N_ME=false
    N_AE=false
  fi
}

# _code_csv_header: the header line of the CSV of this search. _code_csv_rows: its rows. _code_write_csv FILE: the
# header and the fetched rows as CSV, each cell RFC-4180 escaped through JQ_CSV: package,corpus,path,
# line,text per line row (with --context also context_before,context_after), or
# package,matches,builds,corpus,path,line,text,builds_exact per app row (--apps; builds_exact is true, false, or
# empty for a service row with no such field: false marks a builds number that is a lower bound). Returns non-zero
# when the file cannot be written; its stderr is suppressed so no script path or line number reaches the user.
_code_csv_header() {
  if [ "$CS_APPS" = 1 ]; then
    printf 'package,matches,builds,corpus,path,line,text,builds_exact'
  elif [ "$CS_CTX" != 0 ]; then
    printf 'package,corpus,path,line,text,context_before,context_after'
  else
    printf 'package,corpus,path,line,text'
  fi
}

_code_write_csv() {
  # TASK-1508: --append adds the rows to a file that has its header line; a missing or empty file is written whole.
  if [ "$CS_APPEND" = 1 ] && [ -s "$1" ]; then
    _code_csv_rows >>"$1" 2>/dev/null
    return
  fi
  {
    _code_csv_header
    printf '\n'
    _code_csv_rows
  } >"$1" 2>/dev/null
}

_code_csv_rows() {
  {
    if [ "$CS_APPS" = 1 ]; then
      jq -r "$JQ_CSV"'[.package, .matches, .builds, .sample.corpus, .sample.path, .sample.line, .sample.text,
                      (if (.builds_exact | type) == "boolean" then (.builds_exact | tostring) else "" end)] | csvrow' "$CODE_DATA"
    elif [ "$CS_CTX" != 0 ]; then
      # TASK-1506: the lines of each context cell are joined by a newline inside the quoted cell.
      jq -r "$JQ_CSV"'[.package, .corpus, .path, .line, .text, ((.context_before // []) | join("\n")),
                      ((.context_after // []) | join("\n"))] | csvrow' "$CODE_DATA"
    else
      jq -r "$JQ_CSV"'[.package, .corpus, .path, .line, .text] | csvrow' "$CODE_DATA"
    fi
  }
}

# _code_out_fail FILE: the plain reason and next action for a CSV that cannot be written (no internal
# path, line or status; feedback-no-dead-ends, feedback-no-staff-copy-for-customers), then exit.
_code_out_fail() {
  err "$CITT_CMD: cannot write $1"
  err "next: choose a writable folder and retry"
  exit 1
}

# _code_blocks: the fetched rows with their context lines in grep style (TASK-1506): "PACKAGE  PATH-LINE- TEXT" for
# a context line, "PACKAGE  PATH:LINE: TEXT" for the matching line, and "--" between two rows.
_code_blocks() {
  jq -s -r 'to_entries[] | .key as $i | .value as $r
    | ($r.package // "-") as $p | ($r.path // "-") as $f | ($r.line // 0) as $l
    | (($r.context_before // []) | length) as $nb
    | (if $i > 0 then ["--"] else [] end)
      + [($r.context_before // []) | to_entries[] | "\($p)  \($f)-\($l - $nb + .key)- \(.value)"]
      + ["\($p)  \($f):\($l): \($r.text // "")"]
      + [($r.context_after // []) | to_entries[] | "\($p)  \($f)-\($l + 1 + .key)- \(.value)"]
    | .[]' "$CODE_DATA"
}

# _code_table: the fetched rows as a table: one line of one build per row, or one package per row (--apps).
_code_table() {
  if [ "$CS_CTX" != 0 ]; then
    _code_blocks
  elif [ "$CS_APPS" = 1 ]; then
    jq -s -c '[["PACKAGE","MATCHES","SAMPLE PATH:LINE","SNIPPET"]]
      + [.[] | [(.package // "-"), ((.matches // 0) | tostring),
                (if .sample.path == null then "-" else .sample.path + ":" + ((.sample.line // 0) | tostring) end),
                (.sample.text // "-")]]' "$CODE_DATA" | table
  else
    jq -s -c '[["PACKAGE","CORPUS","PATH:LINE","SNIPPET"]]
      + [.[] | [(.package // "-"), (.corpus // "-"), ((.path // "-") + ":" + ((.line // 0) | tostring)), (.text // "")]]' "$CODE_DATA" | table
  fi
}

# --- citt code-search --------------------------------------------------------------------------

# _code_value FLAG COUNT NEXT: the value of FLAG is present and is not another option.
_code_value() {
  [ "$2" -ge 2 ] || usage_error "$1 needs a value"
  case "$3" in --* | -h) usage_error "$1 needs a value; $3 is an option" ;; esac
}

cmd_code_search() {
  local query="" have_query=0 mode="" count=0 case_sensitive=false limit="" time_limit=""
  local cursor="" all=0 out="" apps=0 max_rows="" max_empty="" opts=1 c context="" append=0
  local corpora=() packages=() buildids=() paths=()
  CS_FILTERS=""
  CS_LIMIT=""
  CS_PATHS_W=""
  CS_CTX=0
  while [ $# -gt 0 ]; do
    if [ "$opts" = 0 ]; then
      [ "$have_query" = 0 ] || usage_error "one QUERY only (quote a multi-word or regex query)"
      query="$1"
      have_query=1
      shift
      continue
    fi
    case "$1" in
      --) opts=0 ;;
      --regex)
        [ -z "$mode" ] || [ "$mode" = regex ] || usage_error "use --regex or --literal, not both"
        mode=regex
        ;;
      --literal)
        [ -z "$mode" ] || [ "$mode" = literal ] || usage_error "use --regex or --literal, not both"
        mode=literal
        ;;
      --case-sensitive) case_sensitive=true ;;
      --count) count=1 ;;
      --apps) apps=1 ;;
      --corpus)
        _code_value "$1" $# "${2:-}"
        case " $CODE_CORPORA " in
          *" $2 "*) ;;
          *) usage_error "--corpus must be one of: $CODE_CORPORA" ;;
        esac
        corpora+=("$2")
        shift
        ;;
      --package)
        _code_value "$1" $# "${2:-}"
        packages+=("$2")
        shift
        ;;
      --build-id)
        _code_value "$1" $# "${2:-}"
        buildids+=("$2")
        shift
        ;;
      --path)
        _code_value "$1" $# "${2:-}"
        c="$(printf '%s' "$2" | wc -c)"
        [ "$c" -ge 1 ] && [ "$c" -le 256 ] || usage_error "--path needs a glob of 1 to 256 bytes"
        paths+=("$2")
        [ "${#paths[@]}" -le "$CODE_PATHS_MAX" ] || usage_error "--path can be given at most $CODE_PATHS_MAX times"
        shift
        ;;
      --context)
        _code_value "$1" $# "${2:-}"
        is_uint "$2" && [ "${#2}" -le 2 ] && [ "$2" -le 10 ] || usage_error "--context needs a number of lines from 0 to 10"
        context="$((10#$2))"
        shift
        ;;
      --limit)
        _code_value "$1" $# "${2:-}"
        limit="$2"
        shift
        ;;
      --cursor)
        _code_value "$1" $# "${2:-}"
        cursor="$2"
        shift
        ;;
      --all) all=1 ;;
      --out)
        _code_value "$1" $# "${2:-}"
        out="$2"
        shift
        ;;
      --append) append=1 ;;
      --max-rows)
        _code_value "$1" $# "${2:-}"
        max_rows="$2"
        shift
        ;;
      --max-empty-pages)
        _code_value "$1" $# "${2:-}"
        max_empty="$2"
        shift
        ;;
      --time-limit-ms)
        _code_value "$1" $# "${2:-}"
        time_limit="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_code_search
        exit 0
        ;;
      -*) usage_error "unknown option $1 (a QUERY that starts with - goes after --)" ;;
      *)
        [ "$have_query" = 0 ] || usage_error "one QUERY only (quote a multi-word or regex query)"
        query="$1"
        have_query=1
        ;;
    esac
    shift
  done
  [ -n "$query" ] || usage_error "give the QUERY"
  if [ -n "$time_limit" ]; then
    is_uint "$time_limit" && [ "${#time_limit}" -le 6 ] && [ "$time_limit" -ge 1000 ] && [ "$time_limit" -le "$CODE_TLM_MAX" ] \
      || usage_error "--time-limit-ms must be 1000 or more, up to $CODE_TLM_MAX; the service may apply a lower limit"
  fi

  # --cursor/--all/--out page the hits; they do not apply to a count.
  if [ "$count" = 1 ] && { [ -n "$cursor" ] || [ "$all" = 1 ] || [ -n "$out" ]; }; then
    usage_error "--cursor, --all and --out page the hits; drop --count (or drop them)"
  fi
  [ "$count" = 0 ] || [ "$apps" = 0 ] || usage_error "--count prints the app count; use --apps or --count, not both"
  [ -z "$out" ] || [ "$CITT_JSON" = 0 ] || usage_error "use --out FILE.csv or --json, not both"
  [ "$append" = 0 ] || [ -n "$out" ] || usage_error "--append adds the rows to the file of --out; give --out FILE.csv"
  if [ -n "$context" ] && [ "$context" != 0 ]; then
    [ "$count" = 0 ] && [ "$apps" = 0 ] || usage_error "--context prints the lines around each matching line; drop --apps or --count (or drop --context)"
    CS_CTX="$context"
  fi
  CS_MAXROWS_ARG="$max_rows"
  if [ -n "$max_rows" ]; then
    [ "$all" = 1 ] || [ -n "$out" ] || usage_error "--max-rows needs --all or --out"
    is_uint "$max_rows" && [ "${#max_rows}" -le 9 ] || usage_error "--max-rows needs a number: 1 or more, or 0 for no bound"
    max_rows="$((10#$max_rows))"
  elif [ "$apps" = 1 ]; then
    # TASK-1509: an app list is followed to its end; the service bounds a list at its own limit and says so.
    max_rows=0
  else
    max_rows=10000
  fi
  # TASK-1506 fix round 1: the most pages in a row with no row that a walk reads (0 is no bound).
  CS_MAXEMPTY_ARG="$max_empty"
  if [ -n "$max_empty" ]; then
    [ "$all" = 1 ] || [ -n "$out" ] || usage_error "--max-empty-pages needs --all or --out"
    is_uint "$max_empty" && [ "${#max_empty}" -le 6 ] || usage_error "--max-empty-pages needs a number: 1 or more, or 0 for no bound"
    max_empty="$((10#$max_empty))"
  else
    max_empty="$CODE_MAXEMPTY_DEFAULT"
  fi

  # --limit: at most 200 rows per page. Over 200 is clamped with a note; --all pages beyond it.
  if [ "$count" = 0 ]; then
    if [ -n "$limit" ]; then
      is_uint "$limit" && [ "${#limit}" -le 9 ] || usage_error "--limit needs a number"
      if [ "$limit" -gt 200 ]; then
        err "$CITT_CMD: --limit is capped at 200 per page; using 200"
        limit=200
      elif [ "$limit" -lt 1 ]; then
        usage_error "--limit must be at least 1"
      fi
      CS_LIMIT="$limit"
    else
      limit=50
    fi
    # A walk asks for no more rows per page than --max-rows.
    if { [ "$all" = 1 ] || [ -n "$out" ]; } && [ "$max_rows" -gt 0 ] && [ "$limit" -gt "$max_rows" ]; then limit="$max_rows"; fi
  fi

  # The state the printed commands and the footer read.
  CS_QUERY="$query"
  CS_APPS="$apps"
  CS_COUNT="$count"
  CS_ALL="$all"
  CS_OUT="$out"
  CS_JSON="$CITT_JSON"
  CS_TLM="$time_limit"
  CS_MAXROWS="$max_rows"
  CS_MAXEMPTY="$max_empty"
  CS_HAS_CORPUS=0
  CS_APPEND="$append"
  CS_REGEX=0
  CS_CASE=0
  CS_FILTERED=0
  CS_DROPS=""
  CS_STOP=""
  CS_ROWS=0
  CS_WALK=0
  [ "$all" = 0 ] && [ -z "$out" ] || CS_WALK=1
  if [ "$mode" = regex ]; then
    CS_FILTERS="$CS_FILTERS --regex"
    CS_REGEX=1
  fi
  if [ "$case_sensitive" = true ]; then
    CS_FILTERS="$CS_FILTERS --case-sensitive"
    CS_CASE=1
    CS_DROPS="$CS_DROPS --case-sensitive"
  fi
  for c in ${corpora[@]+"${corpora[@]}"}; do
    CS_FILTERS="$CS_FILTERS --corpus $c"
    CS_HAS_CORPUS=1
  done
  for c in ${packages[@]+"${packages[@]}"}; do CS_FILTERS="$CS_FILTERS --package $(shq "$c")"; done
  for c in ${buildids[@]+"${buildids[@]}"}; do CS_FILTERS="$CS_FILTERS --build-id $(shq "$c")"; done
  for c in ${paths[@]+"${paths[@]}"}; do CS_PATHS_W="$CS_PATHS_W --path $(shq "$c")"; done
  # TASK-1508: the flags of this command that a search with no match can drop, in the order of the hint.
  [ "${#packages[@]}" = 0 ] || CS_DROPS="$CS_DROPS --package"
  [ "$CS_HAS_CORPUS" = 0 ] || CS_DROPS="$CS_DROPS --corpus"
  [ "${#buildids[@]}" = 0 ] || CS_DROPS="$CS_DROPS --build-id"
  [ "${#paths[@]}" = 0 ] || CS_DROPS="$CS_DROPS --path"
  case "$CS_DROPS" in *--package* | *--corpus* | *--build-id* | *--path*) CS_FILTERED=1 ;; esac
  [ -n "$mode" ] || mode=literal

  # --out: refuse a target that cannot be written before any request, so a bad path costs no request and leaks no
  # script path. An existing file keeps its content until the rows are written (TASK-1502).
  if [ -n "$out" ]; then
    if [ -e "$out" ]; then
      [ -f "$out" ] && [ -w "$out" ] || _code_out_fail "$out"
    else
      c="$(dirname -- "$out")"
      [ -d "$c" ] && [ -w "$c" ] || _code_out_fail "$out"
    fi
    # TASK-1508: --append adds rows under the header line of the file, so the file has the columns of this search.
    if [ "$append" = 1 ] && [ -s "$out" ] && [ "$(head -n 1 -- "$out" 2>/dev/null)" != "$(_code_csv_header)" ]; then
      err "$CITT_CMD: cannot add rows to $out: its header line is not the one of this search"
      err "next: give --out another file, or run the command without --append to replace the file"
      exit 1
    fi
  fi
  need_auth

  local body cj pj bj gj
  body="$(tmpfile code_body)"
  gj="$(_code_jarr ${paths[@]+"${paths[@]}"})"
  cj="$(_code_jarr ${corpora[@]+"${corpora[@]}"})"
  pj="$(_code_jarr ${packages[@]+"${packages[@]}"})"
  bj="$(_code_jarr ${buildids[@]+"${buildids[@]}"})"

  if [ "$count" = 1 ]; then
    # Count: no limit; the service's own time limit unless --time-limit-ms is set.
    jq -nc --arg q "$query" --arg mode "$mode" --argjson cs "$case_sensitive" \
      --argjson corpora "$cj" --argjson packages "$pj" --argjson build_ids "$bj" --arg tlm "$time_limit" \
      --argjson globs "$gj" \
      '{q:$q, mode:$mode, case_sensitive:$cs, corpora:$corpora, packages:$packages, build_ids:$build_ids}
       + (if $tlm != "" then {time_limit_ms:($tlm|tonumber)} else {} end)
       + (if ($globs | length) > 0 then {path_globs:$globs} else {} end)' >"$body"
    code_call POST "$CITT_ATLAS_CODE_BASE/count" "$body"
    _code_norm "$RESP"
    _code_verdict
    if [ "$CITT_JSON" = 1 ]; then
      cat "$RESP"
      printf '\n'
      _code_json_incomplete
    else
      _code_footer | clean
      _code_fresh "$(body_field '.refs_refreshed_at')"
    fi
    return "$V_EXIT"
  fi

  jq -nc --arg q "$query" --arg mode "$mode" --argjson cs "$case_sensitive" \
    --argjson corpora "$cj" --argjson packages "$pj" --argjson build_ids "$bj" \
    --arg limit "$limit" --arg tlm "$time_limit" --arg apps "$apps" --argjson globs "$gj" --argjson ctx "$CS_CTX" \
    '{q:$q, mode:$mode, case_sensitive:$cs, corpora:$corpora, packages:$packages, build_ids:$build_ids,
      limit:($limit|tonumber)}
     + (if $tlm != "" then {time_limit_ms:($tlm|tonumber)} else {} end)
     + (if $apps == "1" then {group:"app"} else {} end)
     + (if $ctx > 0 then {context:$ctx} else {} end)
     + (if ($globs | length) > 0 then {path_globs:$globs} else {} end)' >"$body"

  # One page, or under --all and --out every page from --cursor (if any) to the end.
  CODE_ALL="$CS_WALK"
  _code_pager "$body" "$cursor"
  _code_verdict
  _code_append_guard

  if [ "$CITT_JSON" = 1 ]; then
    # One page: the service body unchanged. --all: the body of the last page with the rows of every page.
    if [ "$CS_WALK" = 1 ]; then
      jq -c --slurpfile d "$CODE_DATA" '.data = $d' "$CODE_LAST"
    else
      cat "$CODE_LAST"
      printf '\n'
    fi
    _code_json_incomplete
    return "$V_EXIT"
  fi

  local shown="" unit=rows verb=written
  [ "$apps" != 1 ] || unit=apps
  [ "$append" != 1 ] || verb=added
  if [ -n "$out" ]; then
    _code_write_csv "$out" || _code_out_fail "$out"
    # TASK-1508: a walk with no row says so; "0 apps written" for a file with a header line only is not printed.
    if [ "$CS_ROWS" = 0 ] && [ "$append" = 1 ]; then
      shown="no row added to $out"
    elif [ "$CS_ROWS" = 0 ]; then
      shown="no row written to $out (the file has its header line only)"
    elif [ "$apps" = 1 ]; then
      shown="$CS_ROWS apps $verb to $out"
    else
      shown="$CS_ROWS rows across $(jq -s '[.[].package] | unique | length' "$CODE_DATA") apps $verb to $out"
    fi
  elif [ "$CS_ROWS" != 0 ]; then
    _code_table
    shown="shown: $CS_ROWS $unit"
  fi
  # An answer with no row: the written line of --out and the sentence of the cause, then the footer.
  if [ "$CS_ROWS" = 0 ]; then
    [ -z "$shown" ] || printf '%s\n' "$shown" | clean
    _code_no_match | clean
    shown=""
  fi
  _code_footer "$shown" | clean
  _code_fresh "$(jq -r '.refs_refreshed_at // .meta.refs_refreshed_at // empty' "$CODE_LAST")"
  return "$V_EXIT"
}
