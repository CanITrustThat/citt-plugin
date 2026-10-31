#!/usr/bin/env bash
# lib/cmd-search.sh: citt search, request search across the capture sessions of a date range (TASK-593):
# GET /capture-search and POST /capture-search/restore (TASK-590), the inside-words job
# POST /capture-search/deep and GET /capture-search/deep/{job} (TASK-591).
# Output for an agent session: one inline page when the whole result fits it, else a CSV file of the
# whole result (up to a row cap) with a short preview; --inline and --out choose.
# shellcheck shell=bash disable=SC2034,SC2153

# Defaults set by the TASK-593 output-size experiment (ticket, Build section).
SEARCH_PAGE_DEFAULT=50
SEARCH_MAX_ROWS_DEFAULT=5000
SEARCH_URL_WIDTH=100
SEARCH_PREVIEW_ROWS=5
SEARCH_PAGE_MAX=200
# A 503 capture_tables_busy (TASK-590 capture_lock.rs, with Retry-After) is asked again this many times.
SEARCH_BUSY_RETRIES=3

# The CSV columns: the 19 row fields of the TASK-590 contract, the matched part when the API reports it,
# and the dashboard link that opens the request in its session video.
SEARCH_COLUMNS="id session_id session_seq session_started_at run_id run_key project_id project_name package_id app_label offset_ms flow_id method url host status content_type resp_body_bytes error matched open_url"

S_Q=""
S_FROM=""
S_TO=""
S_DEEP=0
S_JOB=""
S_PIDS=""
S_BASE=""
S_PAGE=""
# The end of the --timeout wait while --load-older or --inside-words polls, in epoch seconds; empty otherwise.
S_DEADLINE=""

# _s_iso EPOCH: the UTC RFC 3339 time.
_s_iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# _s_bound VALUE: a date (YYYY-MM-DD) or an RFC 3339 time.
_s_bound() {
  printf '%s' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2}))?$'
}

# _s_query [K V...]: the query string of the text, range and projects, then the given pairs.
_s_query() {
  local -a a
  a=(q "$S_Q" from "$S_FROM" to "$S_TO")
  local p
  for p in $S_PIDS; do a+=(project_id "$p"); done
  while [ $# -ge 2 ]; do
    a+=("$1" "$2")
    shift 2
  done
  query ${a[@]+"${a[@]}"}
}

# _s_range_query: the range and projects only (the restore route takes no text).
_s_range_query() {
  local -a a
  a=(from "$S_FROM" to "$S_TO")
  local p
  for p in $S_PIDS; do a+=(project_id "$p"); done
  query ${a[@]+"${a[@]}"}
}

# Filip, 2026-10-30 (round 8): citt search states every answer other than 2xx in its own plain sentences, with one
# generic sentence for anything unmapped: no host, API path, API error code or HTTP status in a human line. With --json
# the error document keeps the API error code in `error`, and `message` is the plain sentence. The shared fail_http of
# lib/common.sh is not used here (TASK-597 covers the other commands).

# _s_noun: the request of the last call, as the object of "could not answer".
_s_noun() {
  case "$REQ_PATH" in
    */capture-search/restore) printf 'the request to load older sessions' ;;
    */capture-search/deep*) printf 'the inside-words search' ;;
    */projects) printf 'the project lookup of this search' ;;
    *) printf 'this search' ;;
  esac
}

# _s_feature: what a server without the route lacks.
_s_feature() {
  case "$REQ_PATH" in
    */capture-search/restore) printf 'loading older sessions' ;;
    */capture-search/deep*) printf 'inside-words search' ;;
    */projects) printf 'the project list' ;;
    *) printf 'request search' ;;
  esac
}

# _s_out CODE MESSAGE: the plain line and exit CODE; with --json, the answer's document with MESSAGE as its message.
_s_out() {
  local tmp
  if [ "$CITT_JSON" = 1 ] && jq -e 'type == "object"' "$RESP" >/dev/null 2>&1; then
    tmp="$(tmpfile errdoc)"
    jq -c --arg m "$2" '.message = $m' "$RESP" >"$tmp" 2>/dev/null && cp "$tmp" "$RESP"
  fi
  fail_out "$1" "$2"
}

# _s_fail: the line and exit code of an answer other than 2xx (exit codes as in the reference: 1 to 10).
_s_fail() {
  local error message generic
  error="$(body_field '.error')"
  message="$(body_field '.message')"
  generic="the server could not answer $(_s_noun); try again shortly"
  case "$CODE" in
    000) _s_out 9 "the service could not be reached; check the network connection and try again" ;;
    400)
      case "$error" in
        range_too_wide)
          local max sessions requests
          max="$(body_field '.limit_days')"
          sessions="$(body_field '.range_sessions')"
          requests="$(body_field '.range_requests')"
          _s_out 2 "the inside-words search covers at most ${max:-?} days; the asked range holds ${sessions:-?} sessions and ${requests:-?} requests; narrow it, for example: citt search $(shq "$S_Q") --days ${max:-1} --inside-words$(_s_project_words)"
          ;;
        invalid_from | invalid_to)
          case "$message" in
            *" is after "*) _s_out 7 "the range starts after it ends: give a --from before the --to" ;;
            *) _s_out 7 "the range needs a date (2026-10-20) or an RFC 3339 time for --from and --to" ;;
          esac
          ;;
        *)
          case "$message" in
            after*) _s_out 7 "--cursor is not a cursor of this search: use the --cursor of a command this search printed, with the same range and projects" ;;
            *) _s_out 7 "the server refused this search; check the text, the range and the projects" ;;
          esac
          ;;
      esac
      ;;
    401) _s_out 3 "not signed in or the token expired; run: citt auth" ;;
    402 | 429) _s_out 6 "this account has reached a usage limit; see: citt usage" ;;
    403)
      if [ "$error" = not_entitled ]; then
        _s_out 3 "$CITT_NOT_ENTITLED_LINE"
      fi
      _s_out 3 "this account cannot search these capture sessions"
      ;;
    404 | 405)
      [ -n "$error" ] || _s_out 10 "this server does not offer $(_s_feature) yet"
      if [ "$error" = deep_search_not_found ]; then
        # F18: the inside-words search was removed while it was followed (replaced by a newer one, or unread).
        _s_out 4 "the inside-words search is no longer on the server; start it again: $S_BASE"
      fi
      case "$S_PIDS" in
        "") _s_out 4 "$generic" ;;
        *" "*) _s_out 4 "one of the projects $(printf '%s' "$S_PIDS" | sed 's/ /, /g') is not found, or you are not an owner of it" ;;
        *) _s_out 4 "project $S_PIDS is not found, or you are not an owner" ;;
      esac
      ;;
    409) _s_out 5 "$generic" ;;
    422) _s_out 7 "$generic" ;;
    503)
      if [ "$error" = search_timed_out ]; then
        _s_out 8 "the search passed the server's time limit; narrow the range or the projects, or search again"
      fi
      if [ "$error" = capture_tables_busy ]; then
        _s_out 8 "$(_s_busy_line); try again shortly"
      fi
      _s_out 8 "$generic"
      ;;
    5??) _s_out 8 "$generic" ;;
    *) _s_out 1 "$generic" ;;
  esac
}

# _s_busy_line: a 503 capture_tables_busy in plain words, for the route of the last request (Filip, 2026-10-30:
# the TASK-592 page's sentence; no tables, maintenance or error code).
_s_busy_line() {
  local what="the search"
  case "$REQ_PATH" in
    */capture-search/restore) what="loading older sessions" ;;
    */capture-search/deep*) what="the inside-words search" ;;
  esac
  if [ "$(body_field '.busy_reason')" = pool ]; then
    printf '%s is busy with other searches right now' "$what"
  else
    printf '%s is briefly unavailable while older data is being moved' "$what"
  fi
}

# _s_call METHOD PATH: http, then _s_fail unless 2xx. This function asks a request again, not http(): a 503
# capture_tables_busy after its Retry-After seconds (30 when absent), and, on a GET (or with HTTP_RETRY=yes), a network
# failure or another 5xx as http() would (Retry-After, else 1, 2, 4 s); at most SEARCH_BUSY_RETRIES times in all.
# While S_DEADLINE is set (the polls of --load-older and --inside-words), no wait passes it (F19): the wait is cut to the
# time left, and an answer after it is final.
_s_call() {
  local method="$1" again=no tries=0 wait left busy
  case "$HTTP_RETRY" in
    yes) again=yes ;;
    auto) [ "$method" != GET ] || again=yes ;;
  esac
  while :; do
    HTTP_RETRY=no
    http "$@"
    ok && return 0
    busy=no
    if [ "$CODE" = 503 ] && [ "$(body_field '.error')" = capture_tables_busy ]; then
      busy=yes
    elif [ "$again" = yes ]; then
      case "$CODE" in 000 | 5??) ;; *) break ;; esac
    else
      break
    fi
    tries=$((tries + 1))
    [ "$tries" -le "$SEARCH_BUSY_RETRIES" ] || break
    if [ "$busy" = yes ]; then
      wait="$(hdr Retry-After)"
      is_uint "$wait" || wait=30
    else
      wait="$(_retry_delay "$tries")"
    fi
    if [ -n "${S_DEADLINE:-}" ]; then
      left=$((S_DEADLINE - $(now_s)))
      [ "$left" -gt 0 ] || break
      [ "$wait" -le "$left" ] || wait="$left"
    fi
    if [ "$busy" = yes ]; then
      err "$CITT_CMD: $(_s_busy_line); trying again in $wait s"
      poll_sleep "$wait"
    else
      sleep "$wait"
    fi
  done
  _s_fail
}

_s_project_words() {
  local p
  for p in $S_PIDS; do printf ' --project %s' "$p"; done
}

# _s_page LIMIT AFTER: one page of the result into $S_PAGE, normalized to
# {items, next, has_more, total, total_estimated, sessions_searched, older, restoring, job}.
_s_page() {
  local limit="$1" after="$2"
  if [ "$S_DEEP" = 1 ]; then
    _s_call GET "$CITT_V1/capture-search/deep/$S_JOB$(query after "$after" limit "$limit")"
  else
    HTTP_RETRY=no
    _s_call GET "$CITT_V1/capture-search$(_s_query limit "$limit" after "$after")"
  fi
  jq -e '.items | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  # A running inside-words job (TASK-591) answers has_more true and next set (to the given after when no new hit
  # was found) until it ends: a page shorter than the limit holds every hit found so far, so it is the last page.
  jq -c --argjson lim "$limit" '
    ((.job != null) and ((.job.finished == true) or (.job.state | IN("done", "failed", "cancelled")) | not)
      and ((.items | length) < $lim)) as $short
    | {items, next: (if $short then null else .next end), has_more: (if $short then false else (.has_more // false) end),
      total, total_estimated: (.total_estimated // false),
      sessions_searched: (.sessions_searched // .job.sessions_total // null),
      older: (.older // null), restoring: (.restoring // null), job: (.job // null)}' "$RESP" >"$S_PAGE"
}

# _s_zones FILE: {iso: {o: utc offset in seconds, z: zone abbreviation}} for every session start of the page,
# so each request time prints in the local zone of its session start.
_s_zones() {
  local iso e z
  jq -r "$JQ_TS"' [.items[].session_started_at | strings] | unique[] | "\(.)\t\(ts | floor)"' "$1" 2>/dev/null \
    | while IFS=$'\t' read -r iso e; do
      z="$(date -d "@$e" '+%z %Z' 2>/dev/null || date -r "$e" '+%z %Z')"
      jq -nc --arg k "$iso" --arg z "$z" \
        '($z | split(" ")) as $p | ($p[0] | .[0:1]) as $sg | ($p[0][1:3] | tonumber) as $h | ($p[0][3:5] | tonumber) as $m
         | {($k): {o: ((if $sg == "-" then -1 else 1 end) * ($h * 3600 + $m * 60)), z: $p[1]}}'
    done | jq -sc 'add // {}'
}

# JQ_SROW: `srow`, a page item as the inline row (time, project, app, run, session, method, status, host, cut URL).
# shellcheck disable=SC2016
JQ_SROW="$JQ_TS"'
def ms: (.session_started_at | ts) * 1000
  + ((.session_started_at | capture("\\.(?<f>[0-9]+)") .f // "0") | (. + "000")[0:3] | tonumber) + (.offset_ms // 0);
def when: if .session_started_at == null then "-" else
  ($Z[.session_started_at] // {o: 0, z: "UTC"}) as $zz
  | ((ms / 1000 | floor) + $zz.o | strftime("%Y-%m-%d %H:%M:%S")) + " " + $zz.z end;
def cut($w): if . == null then "-" elif length > $w then .[0:($w - 3)] + "..." else . end;
def srow: [when, .project_name, .package_id, .run_key, .session_id, .method, .status, .host, (.url | cut($W))];'

# _s_table FILE N: the inline table of the first N items of a normalized page (or of a JSON array of items).
_s_table() {
  local zones
  zones="$(_s_zones "$1")"
  jq -c --argjson Z "$zones" --argjson W "$SEARCH_URL_WIDTH" --argjson n "$2" "$JQ_SROW"'
    [["Time", "Project", "App", "Run", "Session", "Method", "Status", "Host", "URL"]] + [.items[0:$n][] | srow]' "$1" | table
}

# _s_count_line FILE SHOWN AFTER: the total line of a page.
_s_count_line() {
  jq -r --argjson shown "$2" --arg after "$3" '
    (.sessions_searched // "?") as $s
    | if .has_more | not then
        (if $after != "" then "Last page: \($shown) rows."
         elif $shown == 0 then "No matches in \($s) sessions searched."
         elif $shown == 1 then "1 match in \($s) sessions searched."
         else "\(.total // $shown) matches in \($s) sessions searched." end)
      elif .total == null then "Shown \($shown); more than \($shown) matches (\($s) sessions searched)."
      elif .total_estimated then "Shown \($shown) of about \(.total) matches (\($s) sessions searched)."
      else "Shown \($shown) of \(.total) matches (\($s) sessions searched)." end' "$S_PAGE"
}

# _s_older_notice: the stderr notice of sessions whose rows are in the archive, and of open restores, from the
# page in $S_PAGE; printed once per command. GET /capture-search sends older only on the first page.
_s_older_notice() {
  local line
  [ "${S_NOTICE_DONE:-0}" = 0 ] || return 0
  S_NOTICE_DONE=1
  line="$(jq -r '.older | select(. != null and (.sessions // 0) > 0)
    | (.estimated_seconds // 0) as $e
    | (if $e < 60 then "under a minute" elif $e < 7200 then "about \(($e / 60) | ceil) min" else "about \(($e / 3600) | ceil) h" end) as $t
    | "\(.sessions) older sessions (\(.requests) requests, captured \((.oldest_started_at // .captured_from // "?")[0:10]) to \((.newest_started_at // .captured_to // "?")[0:10])) were not searched: their requests are in the archive; restoring them takes \($t)"' \
    "$S_PAGE" 2>/dev/null)"
  [ -z "$line" ] || err "$CITT_CMD: $line; run: $S_BASE --load-older"
  line="$(jq -r '.restoring | select(. != null) | "\(.sessions_total) older sessions are being restored: \(.sessions_done) of \(.sessions_total) done"' "$S_PAGE" 2>/dev/null)"
  [ -z "$line" ] || err "$CITT_CMD: $line; search again when it ends, or follow it: $S_BASE --load-older"
}

# _s_next_csv FILE: hits.csv -> hits-2.csv, hits-2.csv -> hits-3.csv.
_s_next_csv() {
  local b="${1%.csv}" n
  n="$(printf '%s' "$b" | sed -n 's/.*-\([0-9][0-9]*\)$/\1/p')"
  if [ -n "$n" ]; then
    printf '%s-%s.csv' "${b%-"$n"}" "$((n + 1))"
  else
    printf '%s-2.csv' "$b"
  fi
}

# _s_csv_name: a default file name in the working directory for the CSV of a result.
_s_csv_name() {
  local slug
  slug="$(printf '%s' "$S_Q" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-30)"
  printf 'citt-search-%s-%s.csv' "${slug:-text}" "$(date -u +%Y%m%dT%H%M%SZ)"
}

# shellcheck disable=SC2016
JQ_SCSV='def open($h): "\($h)/capture-sessions/\(.session_id)?t=\(.offset_ms)&request=\(.id)";
  .items[] | [.id, .session_id, .session_seq, .session_started_at, .run_id, .run_key, .project_id, .project_name,
    .package_id, .app_label, .offset_ms, .flow_id, .method, .url, .host, .status, .content_type, .resp_body_bytes,
    .error, (.matched // null), open($h)] | csvrow'

# _s_csv OUT MAX FIRST_DONE AFTER: writes the result to OUT, walking pages from AFTER (or from the page in
# $S_PAGE, read from AFTER, when FIRST_DONE is 1), at most MAX rows; prints the summary.
# GET /capture-search sends total on the first page only (null on every page with after), so the left-out count
# is taken from the last page that sent one; an inside-words page sends the job's growing count on every page.
# That total counts the whole result, so a walk from a cursor prints "more matches" (F14).
_s_csv() {
  local out="$1" max="$2" first="$3" after="$4" n=0 got lim preview left prev total=null
  local from_cursor=0
  [ -z "$after" ] || from_cursor=1
  preview="$(tmpfile preview)"
  ( umask 022; printf '%s\n' "$(printf '%s' "$SEARCH_COLUMNS" | tr ' ' ',')" >"$out" ) || die 1 "cannot write $out"
  while :; do
    if [ "$first" = 1 ]; then
      first=0
      # A first page over the cap: its next points past rows the cap leaves out, so the page is asked again with
      # the cap as its limit, and its next is the cursor of the row after the cap.
      [ "$(jq '.items | length' "$S_PAGE")" -le "$max" ] || _s_page "$max" "$after"
    else
      lim=$((max - n))
      [ "$lim" -le "$SEARCH_PAGE_MAX" ] || lim="$SEARCH_PAGE_MAX"
      _s_page "$lim" "$after"
    fi
    got="$(jq '.items | length' "$S_PAGE")"
    # A walk from a cursor has no count of the rows before it (written to earlier files), so it keeps no total.
    [ "$from_cursor" = 1 ] \
      || total="$(jq -c --argjson t "$total" 'if .total == null then $t else {n: .total, est: (.total_estimated == true)} end' "$S_PAGE")"
    if [ "$n" = 0 ]; then
      cp "$S_PAGE" "$preview"
      _s_older_notice
    fi
    jq -r --arg h "$CITT_APP_HOST" "$JQ_CSV$JQ_SCSV" "$S_PAGE" | head -n $((max - n)) >>"$out"
    n=$((n + got))
    [ "$n" -le "$max" ] || n="$max"
    prev="$after"
    after="$(jq -r '.next // empty' "$S_PAGE")"
    # A page with no rows, or a next equal to the cursor sent, ends the walk: the next request would repeat it.
    if ! { [ "$(jq -r '.has_more' "$S_PAGE")" = true ] && [ -n "$after" ] && [ "$got" -gt 0 ] && [ "$after" != "$prev" ]; }; then
      after=""
      break
    fi
    [ "$n" -lt "$max" ] || break
  done
  printf 'Wrote %s rows to %s.\n' "$n" "$out"
  printf 'Columns: %s\n' "$(printf '%s' "$SEARCH_COLUMNS" | sed -e 's/ /, /g' \
    -e 's/matched/matched (url, headers or body, when the API reports it)/' -e 's/open_url/open_url (the request in its session video)/')"
  if [ -z "$after" ] && [ "$from_cursor" = 1 ]; then
    # A walk from a cursor holds the rest of the result only: its row count is not the count of the search.
    printf 'The rest of the result: %s %s, the last rows of the search.\n' "$n" "$([ "$n" = 1 ] && printf row || printf rows)"
  elif [ -z "$after" ]; then
    if [ "$n" = 1 ]; then
      printf '1 match in %s sessions searched.\n' "$(jq -r '.sessions_searched // "?"' "$S_PAGE")"
    else
      printf '%s matches in %s sessions searched.\n' "$n" "$(jq -r '.sessions_searched // "?"' "$S_PAGE")"
    fi
  else
    left="$(jq -nr --argjson n "$n" --argjson t "$total" 'if $t == null then "more matches"
      elif $t.est then "about \($t.n - $n) matches" else "\($t.n - $n) matches" end')"
    printf 'Left out: %s over the row cap of %s; the next rows: %s --cursor %s --out %s\n' \
      "$left" "$max" "$S_BASE" "$(shq "$after")" "$(shq "$(_s_next_csv "$(basename "$out")")")"
  fi
  if [ "$n" -gt 0 ]; then
    printf 'First %s rows:\n' "$([ "$n" -lt "$SEARCH_PREVIEW_ROWS" ] && printf '%s' "$n" || printf '%s' "$SEARCH_PREVIEW_ROWS")"
    _s_table "$preview" "$SEARCH_PREVIEW_ROWS"
  fi
}

# Filip, 2026-10-30: user-facing copy never exposes internals. The API's left_out.reason, a restore's error and an
# inside-words job's error name settings, tables, disk paths and database errors; these lines are built from the
# answer's numbers and from a fixed sentence per kind of error, and the API's text is never printed (F13).

# _s_bytes N: 2200000000 -> "2.2 GB" (decimal units).
_s_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b < 0) b = 0
    if (b < 1000) printf "%d B", b
    else if (b < 1e6) printf "%.1f KB", b / 1e3
    else if (b < 1e9) printf "%.1f MB", b / 1e6
    else if (b < 1e12) printf "%.1f GB", b / 1e9
    else printf "%.1f TB", b / 1e12 }'
}

# _s_restore_wait ERROR: why a restore that has not started waits (TASK-590 errors `no room: ...`, `disk floor: ...`).
_s_restore_wait() {
  case "$1" in
    "no room"*) printf 'the space for restored sessions is full, the restores start when older restored sessions expire' ;;
    "disk floor"*) printf 'the disk is nearly full, the restores start when space frees up' ;;
    *) printf 'the restores start when space frees up' ;;
  esac
}

# _s_deep_why ERROR: why an inside-words search stopped (TASK-591 `REPLACED`, `UNREAD`, `failure_reason`).
_s_deep_why() {
  case "$1" in
    "cancelled: a newer"*) printf 'a newer inside-words search of your account replaced it' ;;
    "cancelled: unread"*) printf 'it was cancelled when its results went unread for 10 minutes' ;;
    *"did not finish within 10 minutes"*) printf 'a session took longer than 10 minutes to search; narrow the range' ;;
    cancelled*) printf 'it was cancelled' ;;
    *) printf 'the search failed in a session' ;;
  esac
}

# _s_restore TIMEOUT: --load-older: queues the restore of the range's archived sessions, follows it, returns 12
# after TIMEOUT seconds.
_s_restore() {
  local timeout="$1" start total line done_n failed left
  HTTP_RETRY=no
  _s_call POST "$CITT_V1/capture-search/restore$(_s_range_query)"
  jq -e 'type == "object"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  line="$(jq -r '.left_out | select(. != null and (.sessions // 0) > 0) | "\(.sessions)\t\(.needs_bytes // 0)\t\(.room_bytes // 0)"' "$RESP")"
  if [ -n "$line" ]; then
    local lo_n lo_need lo_room
    IFS=$'\t' read -r lo_n lo_need lo_room <<<"$line"
    err "$CITT_CMD: $lo_n older $([ "$lo_n" = 1 ] && printf 'session' || printf 'sessions') left out of the restore: $([ "$lo_n" = 1 ] && printf 'it needs' || printf 'they need') $(_s_bytes "$lo_need") and $(_s_bytes "$lo_room") is free for restored sessions"
  fi
  total="$(jq -r '.sessions_total // 0' "$RESP")"
  if [ "$(jq -r '.state // empty' "$RESP")" = "done" ] || [ "$total" = 0 ]; then
    return 0
  fi
  start="$(now_s)"
  S_DEADLINE=$((start + timeout))
  while :; do
    # GET /capture-search/restore: the progress of the range's open restores (a RestoreAnswer); it queues nothing
    # and searches nothing, so a poll costs no search of the range.
    _s_call GET "$CITT_V1/capture-search/restore$(_s_range_query)"
    jq -e 'type == "object"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
    if [ "$(jq -r '.state // empty' "$RESP")" != restoring ]; then
      err "$CITT_CMD: restoring $total older sessions: done"
      return 0
    fi
    done_n="$(jq -r '.sessions_done // 0' "$RESP")"
    failed="$(jq -r '.sessions_failed // 0' "$RESP")"
    total="$(jq -r --arg t "$total" '.sessions_total // ($t | tonumber)' "$RESP")"
    line="$(jq -r '.error // empty' "$RESP")"
    # An error with no failed session is the reason the restores wait; with failed sessions it is the first failure.
    err "$CITT_CMD: restoring $total older sessions: $done_n of $total done$([ "$failed" = 0 ] || printf ', %s failed' "$failed")$([ "$failed" != 0 ] || [ -z "$line" ] || printf '; waiting: %s' "$(_s_restore_wait "$line")")"
    if [ $((done_n + failed)) -ge "$total" ]; then
      [ "$failed" = 0 ] || err "$CITT_CMD: $failed older $([ "$failed" = 1 ] && printf 'session was' || printf 'sessions were') not restored after 5 attempts"
      return 0
    fi
    left=$((timeout - ($(now_s) - start)))
    if [ "$left" -le 0 ]; then
      err "$CITT_CMD: the restore of $total older sessions is at $done_n of $total after $timeout s; re-run: $S_BASE --load-older"
      return 12
    fi
    poll_sleep "" "$left"
  done
}

# _s_deep TIMEOUT: starts or reuses the inside-words job and follows it; returns 12 after TIMEOUT seconds,
# 8 when the job failed or was cancelled, in a poll or in the POST answer (the hits found so far are printed by the
# caller in both cases).
_s_deep() {
  local timeout="$1" start left st
  HTTP_RETRY=no
  _s_call POST "$CITT_V1/capture-search/deep$(_s_query)"
  S_JOB="$(jq -r '.job.id // .id // empty' "$RESP" 2>/dev/null)"
  is_uint "$S_JOB" || die 1 "unexpected response from the server"
  start="$(now_s)"
  S_DEADLINE=$((start + timeout))
  while ! _s_deep_finished; do
    _s_call GET "$CITT_V1/capture-search/deep/$S_JOB$(query limit 1)"
    err "$CITT_CMD: $(jq -r '(.job // .) as $j | (.total // 0) as $h
      | "inside words: \($j.sessions_done // 0) of \($j.sessions_total // "?") sessions searched, \($j.requests_scanned // 0) requests, \($h) \(if $h == 1 then "hit" else "hits" end) so far"' "$RESP")"
    _s_deep_finished && break
    left=$((timeout - ($(now_s) - start)))
    if [ "$left" -le 0 ]; then
      S_DEEP_LATE="$(jq -r '(.job // .) | "has \(.sessions_done // 0) of \(.sessions_total // "?") sessions searched"' "$RESP")"
      return 12
    fi
    poll_sleep "" "$left"
  done
  st="$(jq -r '(.job // .) | .state // empty' "$RESP")"
  if [ "$st" = failed ] || [ "$st" = cancelled ]; then
    local why
    why="$(jq -r '(.job // .) | .error // empty' "$RESP")"
    S_DEEP_LATE="stopped ($st${why:+: $(_s_deep_why "$why")})"
    return 8
  fi
  return 0
}

_s_deep_finished() {
  jq -e '(.job // .) | (.finished == true) or (.state | IN("done", "failed", "cancelled"))' "$RESP" >/dev/null 2>&1
}

cmd_search() {
  local days="" limit="" cursor="" out="" inline=0 load_older=0 timeout=540 max_rows="" n
  local -a prefs
  prefs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --days | --from | --to | --project | --limit | --cursor | --out | --timeout | --max-rows)
        need_value "$1" $#
        case "$1" in
          --days) days="$2" ;;
          --from) S_FROM="$2" ;;
          --to) S_TO="$2" ;;
          --project) prefs+=("$2") ;;
          --limit) limit="$2" ;;
          --cursor) cursor="$2" ;;
          --out) out="$2" ;;
          --timeout) timeout="$2" ;;
          --max-rows) max_rows="$2" ;;
        esac
        shift
        ;;
      --inside-words) S_DEEP=1 ;;
      --inline) inline=1 ;;
      --load-older) load_older=1 ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_search
        exit 0
        ;;
      -*) usage_error "unknown option $1; the range is --days N (--days 30 for the last 30 days) or --from DATE [--to DATE]; see: citt search --help" ;;
      *)
        [ -z "$S_Q" ] || usage_error "give one search text (quote a text with spaces): $1"
        S_Q="$1"
        ;;
    esac
    shift
  done
  local range_hint="--days 30 (the last 30 days)"
  [ "$S_DEEP" = 0 ] || range_hint="--days 1 (inside-words search is much slower: start with 1 day, then 3, then 7)"
  [ -n "$S_Q" ] || usage_error "give the text to search: citt search TEXT $range_hint"
  [ "${#S_Q}" -le 200 ] || usage_error "the search text is limited to 200 characters"
  if [ "$S_DEEP" = 1 ] && [ "${#S_Q}" -lt 3 ]; then usage_error "--inside-words needs a text of at least 3 characters"; fi
  if [ -n "$days" ] && { [ -n "$S_FROM" ] || [ -n "$S_TO" ]; }; then usage_error "use --days N or --from DATE [--to DATE], not both"; fi
  if [ -z "$days" ] && [ -z "$S_FROM" ]; then
    [ -z "$S_TO" ] || usage_error "--to needs --from"
    usage_error "give the range: $range_hint, or --from DATE [--to DATE]"
  fi
  if [ -n "$days" ]; then
    { is_uint "$days" && [ "$days" -gt 0 ]; } || usage_error "--days needs a number of days, got: $days"
  fi
  [ -z "$S_FROM" ] || _s_bound "$S_FROM" || usage_error "--from needs a date (2026-10-20) or an RFC 3339 time, got: $S_FROM"
  [ -z "$S_TO" ] || _s_bound "$S_TO" || usage_error "--to needs a date (2026-10-20) or an RFC 3339 time, got: $S_TO"
  if [ -n "$limit" ]; then
    { is_uint "$limit" && [ "$limit" -ge 1 ] && [ "$limit" -le "$SEARCH_PAGE_MAX" ]; } || usage_error "--limit needs a number from 1 to $SEARCH_PAGE_MAX"
  fi
  if [ -n "$max_rows" ]; then
    { is_uint "$max_rows" && [ "$max_rows" -ge 1 ]; } || usage_error "--max-rows needs a number of rows"
  fi
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  if [ -n "$out" ]; then
    case "$out" in *.csv) ;; *) usage_error "--out needs a file name ending in .csv, got: $out" ;; esac
    [ "$inline" = 0 ] || usage_error "use --inline or --out FILE.csv, not both"
  fi
  if [ "$CITT_JSON" = 1 ] && [ -n "$out" ]; then usage_error "use --json or --out FILE.csv, not both"; fi
  local page_size="${limit:-$SEARCH_PAGE_DEFAULT}" cap="${max_rows:-$SEARCH_MAX_ROWS_DEFAULT}"

  need_auth
  # Projects: a number is a project id; a name is looked up in the project list.
  local ref ids c
  for ref in ${prefs[@]+"${prefs[@]}"}; do
    if is_uint "$ref"; then
      S_PIDS="$S_PIDS${S_PIDS:+ }$ref"
      continue
    fi
    [ -n "${_S_PROJECTS:-}" ] || {
      _s_call GET "$CITT_V1/projects"
      _S_PROJECTS="$(tmpfile projects)"
      cp "$RESP" "$_S_PROJECTS"
    }
    ids="$(jq -r --arg n "$ref" '[.projects[] | select(.name == $n) | .project_id] | sort | map(tostring) | join(" ")' "$_S_PROJECTS")" \
      || die 1 "unexpected response from the server"
    c="$(printf '%s' "$ids" | wc -w | tr -d ' ')"
    case "$c" in
      0) die 4 "no project named \"$ref\" among your projects" ;;
      1) S_PIDS="$S_PIDS${S_PIDS:+ }$ids" ;;
      *) die 5 "several projects named \"$ref\": ids $(printf '%s' "$ids" | sed 's/ /, /g'); give the id with --project N" ;;
    esac
  done
  E_KIND=project
  E_PROJECT_ID="$(printf '%s' "$S_PIDS" | sed 's/ /, /g')"

  # The range: --days N ends now; --from without --to ends now. Printed commands carry the resolved bounds,
  # so a next page or a re-run searches the same range.
  local now
  now="$(now_s)"
  if [ -n "$days" ]; then
    S_TO="$(_s_iso "$now")"
    S_FROM="$(_s_iso $((now - days * 86400)))"
  elif [ -z "$S_TO" ]; then
    S_TO="$(_s_iso "$now")"
  fi
  S_BASE="citt search $(shq "$S_Q") --from $(shq "$S_FROM") --to $(shq "$S_TO")$(_s_project_words)"
  [ "$S_DEEP" = 0 ] || S_BASE="$S_BASE --inside-words"
  S_PAGE="$(tmpfile page)"

  local code=0 rcode
  if [ "$load_older" = 1 ]; then
    _s_restore "$timeout" || {
      rcode=$?
      S_DEADLINE=""
      [ "$CITT_JSON" != 1 ] || jq -nc --arg q "$S_Q" '{schema: "citt.plugin.search/1", q: $q, error: "restore_timeout"}'
      exit "$rcode"
    }
    S_DEADLINE=""
  fi
  if [ "$S_DEEP" = 1 ]; then
    S_DEEP_LATE=""
    _s_deep "$timeout" || code=$?
    S_DEADLINE=""
  fi

  # --out: the CSV of the result from the cursor on.
  if [ -n "$out" ]; then
    case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
    _s_csv "$out" "$cap" 0 "$cursor"
    _s_deep_end "$code"
    return "$code"
  fi

  _s_page "$page_size" "$cursor"
  _s_older_notice
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --arg q "$S_Q" --arg f "$S_FROM" --arg t "$S_TO" --arg p "$S_PIDS" --argjson d "$S_DEEP" \
      '{schema: "citt.plugin.search/1", q: $q, from: $f, to: $t,
        project_ids: ($p | split(" ") | map(select(. != "") | tonumber)), inside_words: ($d == 1),
        rows: .items, next, has_more, total, total_estimated, sessions_searched, older, restoring}
       + (if .job != null then {job} else {} end)' "$S_PAGE"
    _s_deep_end "$code"
    return "$code"
  fi
  if [ "$inline" = 0 ] && [ "$(jq -r '.has_more' "$S_PAGE")" = true ]; then
    # Over the inline page: the whole result goes to a CSV file in the working directory.
    _s_csv "$PWD/$(_s_csv_name)" "$cap" 1 "$cursor"
    _s_deep_end "$code"
    return "$code"
  fi
  local shown next
  shown="$(jq '.items | length' "$S_PAGE")"
  if [ "$shown" != 0 ]; then
    _s_table "$S_PAGE" "$shown"
    printf '\n'
  fi
  _s_count_line "$S_PAGE" "$shown" "$cursor"
  next="$(jq -r 'select(.has_more) | .next // empty' "$S_PAGE")"
  if [ -n "$next" ]; then
    printf 'Next page: %s --limit %s --inline --cursor %s\n' "$S_BASE" "$page_size" "$(shq "$next")"
    printf 'Whole result as CSV: %s --out %s\n' "$S_BASE" "$(_s_csv_name)"
  fi
  _s_deep_end "$code"
  return "$code"
}

# _s_deep_end CODE: the stderr line of an inside-words search that has not ended or stopped.
_s_deep_end() {
  case "$1" in
    12) err "$CITT_CMD: the inside-words search $S_DEEP_LATE after ${timeout:-540} s; the hits above are those found so far; re-run: $S_BASE" ;;
    8) err "$CITT_CMD: the inside-words search $S_DEEP_LATE; the hits above are those found so far" ;;
  esac
}
