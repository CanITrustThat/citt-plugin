#!/usr/bin/env bash
# lib/cmd-atlas-code.sh: citt code-search (TASK-1463, Phase 1 MVP).
# A literal or regex search over the decompiled app corpus. It calls the CITT backend's
# POST /api/research/v1/atlas/code/{count,search} routes (plugin -> backend -> navigator -> src
# router), reusing the stored token and the backend's atlas_enabled gate: no new credential surface.
# A 403 atlas_not_enabled prints the fixed CITT_ATLAS_DISABLED_LINE (common.sh); a 200
# { code_search_available:false } is the backend's graceful-degrade state and prints the unavailable
# line with a next action (feedback-no-dead-ends). Design:
# /data2/atlas-reports/deep-atlas-code-search-plan.md (sections 2, 3, 5 Phase 1).
# shellcheck shell=bash disable=SC2034,SC2016

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
      msg="code search could not run this pattern: it has no literal of 3 or more characters to prefilter on"
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
  local waits=0 ra
  E_KIND=atlas
  while :; do
    http "$@"
    # TASK-1482: under --all and --out (CODE_ALL=1) a page refused by the per-account rate limit is
    # asked again after the service's retry time (1 to 30 s), up to 3 waits per page, so the pages
    # fetched so far are kept; a single request prints the refusal at once.
    if [ "${CODE_ALL:-0}" = 1 ] && [ "$CODE" = 429 ] && [ "$waits" -lt 3 ] \
      && [ "$(body_field '.error')" = code_search_rate_limited ]; then
      ra="$(body_field '.retry_after')"
      if is_uint "$ra" && [ "$ra" -ge 1 ] && [ "$ra" -le 30 ]; then
        err "$CITT_CMD: too many searches in a short time; waiting $ra s, then continuing with the same page"
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
  if [ "$CODE" = 400 ] && [ "$(body_field '.error')" = bad_cursor ]; then
    err "$CITT_CMD: the --cursor value is not valid any more (it is from a different query or the result window expired)"
    err "next: run the search again without --cursor to start from the first page"
    [ "$CITT_JSON" != 1 ] || { cat "$RESP"; printf '\n'; }
    exit 7
  fi
  # TASK-1482: the 429 of the per-account rate limit (code_search_rate_limited) is a short wait, not a
  # limit of the plan: the service's message, its retry time and its next action, exit 6. Only the
  # 429 usage_limit_exceeded goes on to the limit line of fail_http.
  if [ "$CODE" = 429 ] && [ "$(body_field '.error')" != usage_limit_exceeded ]; then
    code_rate_limited
  fi
  fail_http
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
  if [ "$error" = code_search_rate_limited ]; then
    msg="$(plain_message "$(body_field '.message')")"
    next="$(plain_message "$(body_field '.next_action')")"
    msg="${msg:-too many code searches from this account in a short time}"
    next="${next:-wait a moment, then run the search again; fewer, narrower searches stay under the limit}"
  else
    msg="too many requests from this account in a short time"
    next="wait a moment, then run the search again"
  fi
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

# _code_cursor_line CURSOR: the next action of a page that has a next page (TASK-1466; the first page
# too since TASK-1482).
_code_cursor_line() {
  printf 'next: more results available; fetch them with --cursor %s (or --all for every page, --out FILE.csv to save)\n' "$1"
}

# _code_no_match QUERY: the two lines of an answer with no row, from the meta object on stdin
# (TASK-1482). Four cases, each a reason and a next action in the plugin's own flags: an empty page
# past the last match (meta.total above 0); a search that stopped at the time limit (truncated, or
# shards that ran out of time), where no match is not established for the files not scanned; shards
# that did not answer; and a complete search.
_code_no_match() {
  jq -r --arg q "$1" '
    (if type == "object" then . else {} end) as $m
    | ($m.total // 0) as $tot
    | (($m.truncated == true) or (($m.shards_timeout // 0) > 0)) as $timed
    | ($m.shards_failed // 0) as $failed
    | (if (($m.elapsed_ms | type) == "number") and ($m.elapsed_ms >= 500)
       then " in \($m.elapsed_ms / 1000 | round) s" else "" end) as $secs
    | if $tot > 0 then
        "no more matches for \"\($q)\": all \($tot) matches collected for this search were shown",
        "next: narrow the search with --package or --corpus to see other matches"
      elif $timed then
        "no match for \"\($q)\" in the files scanned\($secs): the search stopped at the time limit before every candidate file was scanned",
        "next: narrow the search with --package or --corpus, or raise --time-limit-ms (up to 30000), then run it again"
      elif $failed > 0 then
        "no match for \"\($q)\" in the part of the index that answered: \($failed) of the shards did not answer, so some apps were not searched",
        "next: run the search again shortly"
      else
        "no code matches \"\($q)\" in any indexed app (every candidate file was scanned)",
        "next: check the spelling, try --regex for a pattern, or drop --package, --corpus or --build-id"
      end'
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

# JQ_COMMAFY: `commafy`, a non-negative integer as a string with thousands separators (2803222 -> 2,803,222).
JQ_COMMAFY='def commafy: tostring | . as $s | ($s | length) as $n
  | [range(0; $n) | . as $i | ($s[$i:$i+1]) + (if ((($n - $i - 1) % 3) == 0 and $i < $n - 1) then "," else "" end)]
  | join("");'

# _code_count_print QUERY: the human lines for a /atlas/code/count response in $RESP.
_code_count_print() {
  jq -r --arg q "$1" "$JQ_COMMAFY"'
    . as $c
    | ($c.shards_total // 0) as $tot
    | ($c.shards_ok // 0) as $ok
    | ($c.shards_timeout // 0) as $to
    | ($c.shards_failed // 0) as $fail
    | (if ($ok == $tot and $tot > 0) then "\($tot) shards, all ok" else "\($ok)/\($tot) shards ok" end) as $shards
    | if (($to > 0) or ($fail > 0)) and ($c.exact != true) then
        ("Could not estimate \"\($q)\": " + (($c.meta.reason) // "some shards ran out of time scanning the index") + "."),
        ("next: " + (($c.meta.next_action) // "add --corpus or --package to narrow, or raise --time-limit-ms"))
      elif ($c.exact == true) then
        ("\($c.estimate | commafy) files match \"\($q)\" (\($shards))."),
        ("next: " + (($c.meta.next_action) // "run without --count for the hits"))
      else
        ("~\($c.estimate | commafy) candidate files to scan for \"\($q)\" (\($shards))."),
        "This is an upper bound from the trigram prefilter; the true match count is lower.",
        ("next: " + (($c.meta.next_action) // "add --corpus/--package to narrow, or run without --count for the hits"))
      end
  ' "$RESP" || die 1 "unparseable code-search response"
  _code_fresh "$(body_field '.refs_refreshed_at')"
}

# _code_search_print QUERY: the table, footer and stated limits for a /atlas/code/search response in $RESP.
_code_search_print() {
  jq -e '.data | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  # An empty result is not a dead end: the reason and a next action from meta.
  if [ "$(jq '.data | length' "$RESP")" = 0 ]; then
    jq -c '.meta // {}' "$RESP" | _code_no_match "$1"
    _code_fresh "$(body_field '.refs_refreshed_at')"
    return 0
  fi
  jq -c '[["PACKAGE","CORPUS","PATH:LINE","SNIPPET"]]
    + [.data[] | [(.package // "-"), (.corpus // "-"), ((.path // "-") + ":" + ((.line // 0) | tostring)), (.text // "")]]' "$RESP" \
    | table
  # The footer counts, with any truncation or shard timeout stated as a floor.
  jq -r "$JQ_COMMAFY"'
    .meta as $m | (.data | length) as $n
    | ($m.total // $n) as $tot
    | ($m.total_is_estimate == true) as $est
    | (($m.truncated == true) or (($m.shards_timeout // 0) > 0) or (($m.shards_failed // 0) > 0)) as $floor
    | ((if $est then "Shown \($n) of about \($tot | commafy) matches" else "Shown \($n | commafy) matches" end)
       + (if ($m.distinct_apps != null) then " across \($m.distinct_apps | commafy) apps" else "" end)
       + (if $floor then
            " (result is a floor"
            + (if (($m.shards_timeout // 0) > 0) then "; \($m.shards_timeout) of the shards timed out" else "" end)
            + (if (($m.shards_failed // 0) > 0) then "; \($m.shards_failed) of the shards failed" else "" end)
            + (if ($m.truncated == true) then "; the page limit was reached" else "" end)
            + ")"
          else "" end)
       + "."),
      (if (($m.builds_not_loaded // 0) > 0) then "\($m.builds_not_loaded) builds are not yet indexed." else empty end),
      (if ((.page.next_cursor // "") != "") then empty
       elif $floor then "next: " + (if (($m.next_action // "") != "") then $m.next_action
            else "narrow with --package or --corpus, or raise --time-limit-ms" end) else empty end)' "$RESP" \
    || die 1 "unparseable code-search response"
  # TASK-1482: a first page with a next page prints the cursor of that page, as the page at --cursor does.
  local next_cursor
  next_cursor="$(jq -r '.page.next_cursor // empty' "$RESP")"
  [ -z "$next_cursor" ] || _code_cursor_line "$next_cursor"
  _code_fresh "$(body_field '.refs_refreshed_at')"
}

# --- pagination (TASK-1466) --------------------------------------------------------------------

# CODE_CAP: the --all safety cap. A result window is bounded; stopping at the cap is a stated limit
# with a next action, not a dead end.
CODE_CAP=50

# _code_pager BASEBODY STARTCURSOR: POSTs $CITT_ATLAS_CODE_BASE/search with the base body (no cursor)
# plus the cursor of each page, once, or every page under $CODE_ALL until page.next_cursor is absent
# (or the cap). Accumulates .data into $CODE_DATA. Sets CODE_META (first page's meta), CODE_SNAP
# (freshness), CODE_NEXT (the last next_cursor), CODE_PAGES, CODE_CAPPED.
_code_pager() {
  local basebody="$1" cursor="$2" pages=0 body
  CODE_DATA="$(tmpfile code_data)"
  printf '[]' >"$CODE_DATA"
  CODE_META=""
  CODE_SNAP=""
  CODE_NEXT=""
  CODE_PAGES=0
  CODE_CAPPED=0
  body="$(tmpfile code_page_body)"
  while :; do
    if [ -n "$cursor" ]; then
      jq -c --arg c "$cursor" '. + {cursor:$c}' "$basebody" >"$body"
    else
      cp "$basebody" "$body"
    fi
    code_call POST "$CITT_ATLAS_CODE_BASE/search" "$body"
    jq -e '.data | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
    jq -c --slurpfile p "$RESP" '. + $p[0].data' "$CODE_DATA" >"$CODE_DATA.n" && mv "$CODE_DATA.n" "$CODE_DATA"
    [ -n "$CODE_META" ] || CODE_META="$(jq -c '.meta // {}' "$RESP")"
    CODE_SNAP="$(body_field '.refs_refreshed_at')"
    CODE_NEXT="$(jq -r '.page.next_cursor // empty' "$RESP")"
    cursor="$CODE_NEXT"
    pages=$((pages + 1))
    CODE_PAGES="$pages"
    if [ "$CODE_ALL" != 1 ] || [ -z "$cursor" ]; then
      break
    fi
    if [ "$pages" -ge "$CODE_CAP" ]; then
      CODE_CAPPED=1
      break
    fi
  done
}

# _code_paged_json: the reconstructed list envelope from the accumulated pages, for --json --all.
_code_paged_json() {
  jq -c -n --slurpfile d "$CODE_DATA" --argjson meta "${CODE_META:-{\}}" \
    --arg nc "$CODE_NEXT" --arg snap "${CODE_SNAP:-}" \
    '{data: $d[0], meta: $meta,
      page: {next_cursor: (if $nc == "" then null else $nc end)},
      refs_refreshed_at: (if $snap == "" then null else $snap end)}'
}

# _code_write_csv FILE: the accumulated rows as CSV (header package,corpus,path,line,text then one
# row per hit, each cell RFC-4180 escaped through JQ_CSV). Returns non-zero when the file cannot be
# written; its stderr is suppressed so no script path or line number reaches the user.
_code_write_csv() {
  {
    printf 'package,corpus,path,line,text\n'
    jq -r "$JQ_CSV"'.[] | [.package, .corpus, .path, .line, .text] | csvrow' "$CODE_DATA"
  } >"$1" 2>/dev/null
}

# _code_out_fail FILE: the plain reason and next action for a CSV that cannot be written (no internal
# path, line or status; feedback-no-dead-ends, feedback-no-staff-copy-for-customers), then exit.
_code_out_fail() {
  err "$CITT_CMD: cannot write $1"
  err "next: choose a writable folder and retry"
  exit 1
}

# _code_paged_print QUERY: the table and footer for the accumulated pages (human output). An
# empty set prints the reason and a next action (no dead end). A page with more rows prints a next
# action carrying the cursor; the cap prints a stated-limit line with a narrowing next action.
_code_paged_print() {
  local n apps
  n="$(jq 'length' "$CODE_DATA")"
  if [ "$n" = 0 ]; then
    printf '%s' "${CODE_META:-{\}}" | _code_no_match "$1"
    _code_fresh "$CODE_SNAP"
    return 0
  fi
  jq -c '[["PACKAGE","CORPUS","PATH:LINE","SNIPPET"]]
    + [.[] | [(.package // "-"), (.corpus // "-"), ((.path // "-") + ":" + ((.line // 0) | tostring)), (.text // "")]]' "$CODE_DATA" \
    | table
  apps="$(jq '[.[].package] | unique | length' "$CODE_DATA")"
  printf '%s' "${CODE_META:-{\}}" | jq -r "$JQ_COMMAFY"' . as $m | '"$n"' as $n | '"$apps"' as $apps
    | (($m.truncated == true) or (($m.shards_timeout // 0) > 0) or (($m.shards_failed // 0) > 0)) as $floor
    | ("Shown \($n | commafy) matches across \($apps | commafy) apps"
       + (if $floor then
            " (result is a floor"
            + (if (($m.shards_timeout // 0) > 0) then "; \($m.shards_timeout) of the shards timed out" else "" end)
            + (if (($m.shards_failed // 0) > 0) then "; \($m.shards_failed) of the shards failed" else "" end)
            + (if ($m.truncated == true) then "; the page limit was reached" else "" end)
            + ")"
          else "" end)
       + "."),
      (if (($m.builds_not_loaded // 0) > 0) then "\($m.builds_not_loaded) builds are not yet indexed." else empty end)'
  # One next action: the cap line, else the cursor continuation, else (a terminal page) the floor's
  # narrowing advice, defaulted when meta carries none (the paged path mirrors the single-page default).
  if [ "$CODE_CAPPED" = 1 ]; then
    printf 'stopped at %s pages (the result window is bounded).\n' "$CODE_CAP"
    printf 'next: narrow the query with --package or --corpus to see the rest, or save it with --out FILE.csv\n'
  elif [ -n "$CODE_NEXT" ]; then
    _code_cursor_line "$CODE_NEXT"
  else
    printf '%s' "${CODE_META:-{\}}" | jq -r '
      (((.truncated == true) or ((.shards_timeout // 0) > 0) or ((.shards_failed // 0) > 0)) as $floor
       | if $floor then "next: " + (if ((.next_action // "") != "") then .next_action
           else "narrow with --package or --corpus, or raise --time-limit-ms" end) else empty end)'
  fi
  _code_fresh "$CODE_SNAP"
}

# --- citt code-search --------------------------------------------------------------------------

cmd_code_search() {
  local query="" mode="" count=0 case_sensitive=false limit="" time_limit=""
  local cursor="" all=0 out=""
  local corpora=() packages=() buildids=()
  while [ $# -gt 0 ]; do
    case "$1" in
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
      --corpus)
        need_value "$1" $#
        corpora+=("$2")
        shift
        ;;
      --package)
        need_value "$1" $#
        packages+=("$2")
        shift
        ;;
      --build-id)
        need_value "$1" $#
        buildids+=("$2")
        shift
        ;;
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
      --all) all=1 ;;
      --out)
        need_value "$1" $#
        out="$2"
        shift
        ;;
      --time-limit-ms)
        need_value "$1" $#
        time_limit="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_code_search
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$query" ] || usage_error "one QUERY only (quote a multi-word or regex query)"
        query="$1"
        ;;
    esac
    shift
  done
  [ -n "$query" ] || usage_error "give the QUERY"
  [ -n "$mode" ] || mode=literal
  [ -z "$time_limit" ] || is_uint "$time_limit" || usage_error "--time-limit-ms needs a number"

  # --cursor/--all/--out page the hits; they do not apply to a --count estimate.
  if [ "$count" = 1 ] && { [ -n "$cursor" ] || [ "$all" = 1 ] || [ -n "$out" ]; }; then
    usage_error "--cursor, --all and --out page the hits; drop --count (or drop them)"
  fi
  [ -z "$out" ] || [ "$CITT_JSON" = 0 ] || usage_error "use --out FILE.csv or --json, not both"
  # --out writes every fetched row; it follows every page.
  [ -z "$out" ] || all=1

  # --limit: at most 200 rows per page. Over 200 is clamped with a note; --all pages beyond it.
  if [ "$count" = 0 ]; then
    if [ -n "$limit" ]; then
      is_uint "$limit" || usage_error "--limit needs a number"
      if [ "$limit" -gt 200 ]; then
        err "$CITT_CMD: --limit is capped at 200 per page; using 200"
        limit=200
      elif [ "$limit" -lt 1 ]; then
        usage_error "--limit must be at least 1"
      fi
    else
      limit=50
    fi
  fi
  need_auth

  local body cs_json cj pj bj
  body="$(tmpfile code_body)"
  cs_json="$case_sensitive"
  cj="$(_code_jarr ${corpora[@]+"${corpora[@]}"})"
  pj="$(_code_jarr ${packages[@]+"${packages[@]}"})"
  bj="$(_code_jarr ${buildids[@]+"${buildids[@]}"})"

  if [ "$count" = 1 ]; then
    # Count: no limit (the backend forces limit 0); a short budget unless --time-limit-ms is set.
    jq -nc --arg q "$query" --arg mode "$mode" --argjson cs "$cs_json" \
      --argjson corpora "$cj" --argjson packages "$pj" --argjson build_ids "$bj" --arg tlm "$time_limit" \
      '{q:$q, mode:$mode, case_sensitive:$cs, corpora:$corpora, packages:$packages, build_ids:$build_ids}
       + (if $tlm != "" then {time_limit_ms:($tlm|tonumber)} else {} end)' >"$body"
    code_call POST "$CITT_ATLAS_CODE_BASE/count" "$body"
    if [ "$CITT_JSON" = 1 ]; then cat "$RESP"; printf '\n'; return 0; fi
    _code_count_print "$query"
    return 0
  fi

  jq -nc --arg q "$query" --arg mode "$mode" --argjson cs "$cs_json" \
    --argjson corpora "$cj" --argjson packages "$pj" --argjson build_ids "$bj" \
    --arg limit "$limit" --arg tlm "$time_limit" \
    '{q:$q, mode:$mode, case_sensitive:$cs, corpora:$corpora, packages:$packages, build_ids:$build_ids,
      limit:($limit|tonumber)}
     + (if $tlm != "" then {time_limit_ms:($tlm|tonumber)} else {} end)' >"$body"

  # Phase-1 single page: no --cursor/--all/--out. The body carries no cursor.
  if [ -z "$cursor" ] && [ "$all" = 0 ] && [ -z "$out" ]; then
    code_call POST "$CITT_ATLAS_CODE_BASE/search" "$body"
    if [ "$CITT_JSON" = 1 ]; then cat "$RESP"; printf '\n'; return 0; fi
    _code_search_print "$query"
    return 0
  fi

  # --out: refuse an unwritable target before any backend call, so a bad path costs no request and
  # leaks no script path (feedback-no-staff-copy-for-customers, feedback-no-dead-ends).
  if [ -n "$out" ] && ! ( : >"$out" ) 2>/dev/null; then
    _code_out_fail "$out"
  fi

  # Paged: start at --cursor (if any) and, under --all/--out, follow page.next_cursor to the cap.
  CODE_ALL="$all"
  _code_pager "$body" "$cursor"
  if [ -n "$out" ]; then
    _code_write_csv "$out" || _code_out_fail "$out"
    local rows apps summary
    rows="$(jq 'length' "$CODE_DATA")"
    apps="$(jq '[.[].package] | unique | length' "$CODE_DATA")"
    summary="$rows rows across $apps apps written to $out"
    # The 50-page cap is a stated limit, named in the summary so the truncation is explicit.
    [ "$CODE_CAPPED" != 1 ] || summary="$summary (stopped at the $CODE_CAP-page cap — narrow the query with --package or --corpus for the rest)"
    printf '%s\n' "$summary"
    if [ "$rows" = 0 ]; then
      printf '%s' "${CODE_META:-{\}}" | _code_no_match "$query"
    fi
    return 0
  fi
  if [ "$CITT_JSON" = 1 ]; then
    # A single --cursor page prints the raw body (Phase-1 shape); --all the reconstructed envelope.
    if [ "$all" = 1 ]; then _code_paged_json; else cat "$RESP"; printf '\n'; fi
    return 0
  fi
  _code_paged_print "$query"
}
