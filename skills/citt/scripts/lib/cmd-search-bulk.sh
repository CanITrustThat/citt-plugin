#!/usr/bin/env bash
# lib/cmd-search-bulk.sh: the vendor-list parts of citt search (TASK-642): --hosts-file, --counts (POST /capture-search/groups,
# TASK-640) and --export (the export job of TASK-641: POST, GET and DELETE /capture-search/exports, GET .../download).
# Sourced after lib/cmd-search.sh, whose _s_call, _s_fail, _s_body and lines it uses.
# shellcheck shell=bash disable=SC2034,SC2153

# --- --hosts-file -----------------------------------------------------------------------------------------------------------

# The most values of one OR list (TASK-640 D1, MAX_VALUES).
SEARCH_HOSTS_MAX=500
# A domain: labels of letters, digits and hyphens (1 to 63 characters, no hyphen at either end), at least two labels.
SEARCH_DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

# _s_hosts_file FILE: the domains of FILE (one per line; # comments, blank lines, a leading *. and a trailing . dropped, lower
# case, repeats once) as S_HOSTS_Q, domain:X or domain:(X OR Y ...), and S_HF_WORDS, the words of printed commands; exits 2
# with the line of the first entry that is not a domain (TASK-642 D1).
_s_hosts_file() {
  local f="$1" norm bad k ln raw n abs
  { [ -f "$f" ] && [ -r "$f" ]; } || usage_error "--hosts-file cannot read $f; give a text file with one domain per line"
  # Lines "N<tab>domain<tab>entry as written": N the line number, the entry without its comment and outer spaces.
  # A UTF-8 byte order mark before line 1 (TASK-642 QA Q3) is dropped; the bytes are read as bytes in every locale.
  norm="$(LC_ALL=C awk '{
      if (NR == 1 && substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)
      sub(/\r$/, ""); t = $0; sub(/#.*/, "", t); gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "") next
      d = tolower(t); sub(/\.$/, "", d); sub(/^\*\./, "", d)
      if (d in seen) next
      seen[d] = 1
      print NR "\t" d "\t" t
    }' "$f")" || usage_error "--hosts-file cannot read $f"
  [ -n "$norm" ] || usage_error "--hosts-file $f holds no domain; write one domain per line, such as example.com"
  # In the C locale [a-z] is ASCII only, as captured hosts are (TASK-642 QA Q2).
  bad="$(printf '%s\n' "$norm" | cut -f2 | LC_ALL=C grep -Evn "$SEARCH_DOMAIN_RE" | head -n 1 | cut -d: -f1)"
  if [ -n "$bad" ]; then
    k="$(printf '%s\n' "$norm" | sed -n "${bad}p")"
    ln="${k%%$'\t'*}"
    raw="${k##*$'\t'}"
    if [ -n "$(printf '%s' "$raw" | LC_ALL=C tr -d '\000-\177')" ]; then
      usage_error "line $ln of $f: \"$raw\" is not a domain as captured hosts are written: a domain with letters outside a to z is written in its xn-- form$(_s_puny_hint "$raw")"
    fi
    usage_error "line $ln of $f: \"$raw\" is not a domain; write one domain per line, such as example.com (subdomains are included)"
  fi
  n="$(printf '%s\n' "$norm" | wc -l | tr -d ' ')"
  [ "$n" -le "$SEARCH_HOSTS_MAX" ] \
    || usage_error "--hosts-file takes at most $SEARCH_HOSTS_MAX domains, and $f holds $n; split the list over several files"
  if [ "$n" = 1 ]; then
    S_HOSTS_Q="domain:$(printf '%s\n' "$norm" | cut -f2)"
  else
    S_HOSTS_Q="domain:($(printf '%s\n' "$norm" | cut -f2 | paste -sd' ' - | sed 's/ / OR /g'))"
  fi
  case "$f" in /*) abs="$f" ;; *) abs="$PWD/$f" ;; esac
  S_HF_WORDS=" --hosts-file $(shq "$abs")"
}

# _s_puny_hint DOMAIN: ", here xn--..." with the xn-- (punycode) form of DOMAIN when python3 can make it; empty otherwise.
_s_puny_hint() {
  local p
  command -v python3 >/dev/null 2>&1 || return 0
  p="$(python3 -I -c 'import sys
try:
    print(sys.argv[1].lower().encode("idna").decode("ascii"))
except Exception:
    pass' "$1" 2>/dev/null)" || return 0
  case "$p" in *xn--*) printf ', here %s' "$p" ;; esac
}

# --- --counts ---------------------------------------------------------------------------------------------------------------

# Groups a page (TASK-640 D4, at most 10,000), and the groups printed as a table without --out.
SEARCH_GROUPS_PAGE=10000
SEARCH_COUNTS_INLINE=50
SEARCH_COUNTS_PREVIEW=10
# shellcheck disable=SC2016
SHAPE_GROUPS='type == "object" and (.groups | type == "array" and all(.[]; type == "object"
    and (.host == null or (.host | type == "string")) and (.app == null or (.app | type == "string"))
    and (.app_label == null or (.app_label | type == "string"))
    and (.requests | num) and (.sessions | num) and (.apps | num) and (.hosts | num)))
  and (.groups_total | num) and (.next == null or (.next | type == "string"))
  and (.has_more == null or (.has_more | type == "boolean"))
  and (.total == null or (.total | type == "object" and (.requests | num) and (.sessions | num) and (.apps | num) and (.hosts | num)))
  and (.query_info == null or (.query_info | type == "object"))'

# _s_by_json BY: the by list of POST /capture-search/groups for --counts BY (host, app, host,app or app,host).
_s_by_json() {
  case "$1" in
    host) printf '["host"]' ;;
    app) printf '["app"]' ;;
    host,app | app,host) printf '["host","app"]' ;;
    *) return 1 ;;
  esac
}

# _s_groups_page AFTER OUT_FILE: one POST /capture-search/groups of this search (TASK-640), S_BY_JSON groups, from AFTER; the
# answer into OUT_FILE. Returns 75 as _s_call does with S_SOFT=1.
_s_groups_page() {
  local body rc=0
  body="$(tmpfile groups-body)"
  _s_body limit "$SEARCH_GROUPS_PAGE" after "$1" | jq -c --argjson by "$S_BY_JSON" '. + {by: $by}' >"$body" \
    || die 1 "cannot write the counts request"
  HTTP_RETRY=no
  _s_call POST "$CITT_V1/capture-search/groups" "$body" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  _s_shape "$SHAPE_GROUPS"
  cp "$RESP" "$2"
}

# JQ_GROUP_ROW: `grow($by)`, a group as the cells of its CSV row; `ghead($by)` the CSV header; `gtab($by)` the table header.
# shellcheck disable=SC2016
JQ_GROUP_ROW='def grow($by): if $by == "host" then [.host, .requests, .sessions, .apps]
    elif $by == "app" then [.app, .app_label, .requests, .sessions, .hosts]
    else [.host, .app, .app_label, .requests, .sessions] end;
  def ghead($by): if $by == "host" then ["host", "requests", "sessions", "apps"]
    elif $by == "app" then ["app", "app_label", "requests", "sessions", "hosts"]
    else ["host", "app", "app_label", "requests", "sessions"] end;
  def gtab($by): if $by == "host" then ["Host", "Requests", "Sessions", "Apps"]
    elif $by == "app" then ["App", "Label", "Requests", "Sessions", "Hosts"]
    else ["Host", "App", "Label", "Requests", "Sessions"] end;'

# _s_groups_table FILE N: the first N groups of the JSON lines FILE as a table, counts grouped by thousands.
_s_groups_table() {
  jq -sc --arg by "$S_BY_KIND" --argjson n "$2" "$JQ_COUNTED$JQ_GROUP_ROW"'
    [gtab($by)] + [.[0:$n][] | grow($by) | map(if type == "number" then grp else . end)]' "$1" | table
}

# _s_counts BY OUT: --counts: every group of the search, every page, to OUT (a CSV), to a table (up to 50 groups and no OUT),
# or to a citt-counts-*.csv file in the working directory; --json prints one document (TASK-642 D3).
_s_counts() {
  local by="$1" out="$2" after="" prev page meta lines got n=0 total rc
  S_BY_KIND="$by"
  case "$by" in app,host) S_BY_KIND=host,app ;; esac
  [ "$S_BY_KIND" != host,app ] || S_BY_KIND=pair
  S_BY_JSON="$(_s_by_json "$by")"
  page="$(tmpfile groups)"
  meta="$(tmpfile groups-first)"
  lines="$(tmpfile groups-lines)"
  : >"$lines"
  S_LONG_RETRY=1
  while :; do
    rc=0
    [ "$n" = 0 ] || S_SOFT=1
    _s_groups_page "$after" "$page" || rc=$?
    S_SOFT=0
    if [ "$rc" = 75 ]; then
      S_LONG_RETRY=0
      err "$CITT_CMD: the counts stopped after $(_s_counted "$n" group) of $(_s_grp "$total"): $(_s_stop_why); the server keeps the counts 10 minutes, so the same command is fast: $S_BASE$S_FIX_TAIL"
      [ "$S_STOP_KIND" != other ] || exit "$S_STOP_CODE"
      exit 13
    fi
    [ "$n" != 0 ] || cp "$page" "$meta"
    total="$(jq -r '.groups_total // empty' "$meta")"
    jq -c '.groups[]' "$page" >>"$lines" || die 1 "unexpected response from the server"
    got="$(jq '.groups | length' "$page")"
    n=$((n + got))
    prev="$after"
    after="$(jq -r '.next // empty' "$page")"
    if [ "$(jq -r '.has_more // (.next != null)' "$page")" != true ]; then
      # The last page: every group of groups_total is written, else the counts are not complete (TASK-642 QA Q5).
      if is_uint "$total" && [ "$n" != "$total" ]; then _s_counts_short "$n" "$total" "the groups the server sent do not add up to its count of groups"; fi
      break
    fi
    { [ -n "$after" ] && [ "$after" != "$prev" ] && [ "$got" -gt 0 ]; } || _s_counts_short "$n" "$total" "the server did not send the next page of groups"
  done
  S_LONG_RETRY=0
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --slurpfile g "$lines" --arg qq "$S_QUERY" --arg f "$S_FROM" --arg t "$S_TO" --arg p "$S_PIDS" \
      '{schema: "citt.plugin.search-counts/1", query: $qq, from: (if $f == "" then null else $f end),
        to: (if $t == "" then null else $t end), project_ids: ($p | split(" ") | map(select(. != "") | tonumber)),
        by, groups: $g, groups_total, total, basis, query_info}' "$meta"
    return 0
  fi
  _s_range_line "$meta"
  if [ -z "$out" ] && [ "$n" -le "$SEARCH_COUNTS_INLINE" ]; then
    [ "$n" = 0 ] || _s_groups_table "$lines" "$n"
  else
    [ -n "$out" ] || out="$PWD/$(_s_counts_name)"
    case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
    (
      umask 022
      jq -nr --arg by "$S_BY_KIND" "$JQ_CSV$JQ_GROUP_ROW"'ghead($by) | csvrow' >"$out" \
        && jq -r --arg by "$S_BY_KIND" "$JQ_CSV$JQ_GROUP_ROW"'grow($by) | csvrow' "$lines" >>"$out"
    ) || die 1 "cannot write $out"
    printf 'Wrote %s to %s.\n' "$(_s_counted "$n" group)" "$out"
    printf 'Columns: %s\n' "$(jq -nr --arg by "$S_BY_KIND" "$JQ_GROUP_ROW"'ghead($by) | join(", ")')"
    if [ "$n" -gt 0 ]; then
      printf 'First %s groups:\n' "$([ "$n" -lt "$SEARCH_COUNTS_PREVIEW" ] && printf '%s' "$n" || printf '%s' "$SEARCH_COUNTS_PREVIEW")"
      _s_groups_table "$lines" "$SEARCH_COUNTS_PREVIEW"
    fi
  fi
  jq -r "$JQ_COUNTED"'(.total // {}) as $t
    | "Counted: \($t.requests // 0 | counted("request")) in \($t.sessions // 0 | counted("session")) of \($t.apps // 0 | counted("app")) and \($t.hosts // 0 | counted("host")); \(.groups_total // 0 | counted("group"))."' "$meta"
}

# _s_counts_short N TOTAL WHY: counts that stopped before every group (a server answer that breaks its own paging): the line
# and exit 13; no file is written, so a part of the groups never reads as complete counts.
_s_counts_short() {
  err "$CITT_CMD: the counts stopped after $(_s_counted "$1" group) of $(_s_grp "${2:-?}"): $3; run the same command again: $S_BASE$S_FIX_TAIL"
  exit 13
}

# _s_counts_name: the default file of --counts in the working directory.
_s_counts_name() {
  local n
  n="$(_s_csv_name)"
  printf 'citt-counts-%s' "${n#citt-search-}"
}

# _s_stop_why: the reason of a page that failed after its retries (S_STOP_KIND, S_STOP_LINE of _s_call), in the words of the
# Stopped early line.
_s_stop_why() {
  case "$S_STOP_KIND" in
    timed) printf "the next page passed the server's time limit twice" ;;
    busy) _s_busy_line ;;
    net) printf 'the service could not be reached' ;;
    server) printf 'the server could not answer' ;;
    *) printf '%s' "$S_STOP_LINE" ;;
  esac
}

# --- --export ---------------------------------------------------------------------------------------------------------------

# shellcheck disable=SC2016
SHAPE_EXPORT='type == "object" and (.id | type == "number" and num) and (.state | type == "string")
  and (.rows_written | num) and (.sessions_read | num) and (.sessions_total | num) and (.sessions_evicted | num)
  and (.progress == null or (.progress | type == "number")) and (.jobs_ahead | num) and (.max_rows | num)
  and (.limit_reached == null or (.limit_reached | type == "boolean"))
  and (.partial == null or (.partial | type == "boolean"))
  and (.query == null or (.query | type == "string"))
  and (.range_read_at == null or (.range_read_at | type == "string"))
  and (.paused_reason == null or (.paused_reason | type == "string"))
  and (.paused_since == null or (.paused_since | type == "string"))
  and (.project_ids == null or (.project_ids | type == "array" and all(.[]; type == "number")))
  and (.error == null or (.error | type == "string"))
  and (.notes == null or (.notes | type == "array" and all(.[]; type == "string")))
  and (.rest == null or (.rest | type == "object" and (.from | type == "string") and (.to | type == "string")))
  and (.error_code == null or (.error_code | type == "string")) and (.row_count | num) and (.file_bytes | num)
  and (.file_sha256 == null or (.file_sha256 | type == "string")) and (.download_url == null or (.download_url | type == "string"))
  and (.columns == null or (.columns | type == "array" and all(.[]; type == "string")))
  and (.from == null or (.from | type == "string")) and (.to == null or (.to | type == "string"))'
# shellcheck disable=SC2016
SHAPE_EXPORT_LIST='type == "object" and (.items | type == "array" and all(.[]; type == "object"
  and (.id | type == "number") and (.state | type == "string") and (.rows_written | num)))'

# The start of a command whose search is not known here (--export-id before an answer, --cancel-export): what to add, stated.
S_EX_NO_QUERY="add the search's --query to: citt search"

# _s_fresh_gz FILE: a free file for a fresh export of this search, out of the series of rest files that _s_next_gz names:
# out.csv.gz and out-2.csv.gz -> out-fresh.csv.gz, then out-fresh-2.csv.gz; never FILE, a file in use or the next rest file.
_s_fresh_gz() {
  local b c n=2 next
  next="$(_s_next_gz "$1")"
  b="$(printf '%s' "${1%.csv.gz}" | sed -e 's/-[0-9][0-9]*$//' -e 's/-fresh$//')"
  c="$b-fresh.csv.gz"
  while [ "$c" = "$1" ] || [ "$c" = "$next" ] || [ -e "$c" ] || [ -e "$c.citt-export" ]; do
    c="$b-fresh-$n.csv.gz"
    n=$((n + 1))
  done
  printf '%s' "$c"
}

# _s_next_gz FILE: out.csv.gz -> out-2.csv.gz, out-2.csv.gz -> out-3.csv.gz.
_s_next_gz() {
  local b="${1%.csv.gz}" n
  n="$(printf '%s' "$b" | sed -n 's/.*-\([0-9][0-9]*\)$/\1/p')"
  if [ -n "$n" ]; then
    printf '%s-%s.csv.gz' "${b%-"$n"}" "$((n + 1))"
  else
    printf '%s-2.csv.gz' "$b"
  fi
}

# _s_export_fail ID: the line and exit code of a failed answer of an export route; other answers as _s_fail. A 409 or 410 has
# several causes (running, cancelled, failed with no file; expired, deleted): the service's sentence states which, and the
# plugin adds the command (TASK-642 D5, fix round 2). A 404 is one answer for an unknown id and a project that is no longer
# open to the account (TASK-641 D15).
_s_export_fail() {
  local id="$1" new="${S_EX_NEW:-$S_EX_NO_QUERY --export FILE.csv.gz}" msg
  msg="$(plain_message "$(body_field '.message')")"
  case "$CODE:$(body_field '.error')" in
    404:search_export_not_found)
      _s_out 4 "export $id is not open to this account: its file was deleted after 72 hours, or a project of the export is no longer open to this account; start a new export: $new"
      ;;
    410:search_export_expired)
      [ -z "$msg" ] || _s_out 4 "$msg: $new"
      _s_out 4 "the file of export $id has expired (it is kept 72 hours after its export ends); export again: $new"
      ;;
    409:search_export_not_ready)
      local again="${S_EX_CMD:-citt search --export-id $id --export FILE.csv.gz}"
      [ -z "$msg" ] || _s_out 5 "$msg; run: $again"
      _s_out 5 "export $id has no file to download yet; the same command follows it: $again"
      ;;
    503:search_export_unavailable) _s_out 8 "search exports are not available on this server; write the rows with --out FILE.csv, or contact support" ;;
  esac
  _s_fail
}

# _s_export_read_fail ID: a progress read that failed. No connection or a gateway error after the retries of D6 says what is
# known: the export keeps running on the server, and the same command goes on with it. Other answers as _s_export_fail.
_s_export_read_fail() {
  local why=""
  case "$CODE" in
    000) why="the service could not be reached" ;;
    *) ! _s_outage "$(body_field '.error')" || why="the server could not answer" ;;
  esac
  [ -n "$why" ] || _s_export_fail "$1"
  trap - INT TERM
  err "$CITT_CMD: $why; export $1 keeps running on the server. The same command follows it and downloads the file: $S_EX_CMD"
  [ "$CODE" = 000 ] && exit 9
  exit 8
}

# _s_export_taken FILE WORDS: FILE belongs to another search or another export: no request, FILE and its state file unchanged,
# and the command for a free file; exit 5 (QA round 2, R2-Q5).
_s_export_taken() {
  err "$CITT_CMD: $S_EX_GIVEN already exists or belongs to another search, so this export did not start; name another file, or delete $S_EX_GIVEN and $S_EX_GIVEN.citt-export to replace it"
  err "  try: $1"
  exit 5
}

# _s_export_get ID FILE: GET /capture-search/exports/ID into FILE, asked again across a restart; a failed answer returns 75 with
# CODE and RESP kept.
_s_export_get() {
  local rc=0
  S_LONG_RETRY=1
  S_SOFT=1
  HTTP_RETRY=no
  _s_call GET "$CITT_V1/capture-search/exports/$1" || rc=$?
  S_SOFT=0
  S_LONG_RETRY=0
  [ "$rc" = 0 ] || return "$rc"
  _s_shape "$SHAPE_EXPORT"
  cp "$RESP" "$2"
}

# _s_export_state_write ID BODY FILE: the state file beside FILE (TASK-642 D4).
_s_export_state_write() {
  jq -nc --argjson id "$1" --argjson b "$2" --arg h "$CITT_HOST" --arg f "$3" '{id: $id, body: $b, host: $h, file: $f}' \
    >"$3.citt-export" 2>/dev/null || die 1 "cannot write $3.citt-export"
}

# _s_export FILE ORDER TIMEOUT: --export: the export of this search (the state file's export of the same body, else a new
# one), followed and downloaded.
_s_export() {
  local file="$1" order="$2" timeout="$3" body canon id="" sid sbody shost st job rc why
  body="$(tmpfile export-body)"
  _s_body order "$order" format csv.gz >"$body" || die 1 "cannot write the export request"
  canon="$(jq -S -c . "$body")"
  S_EX_CMD="$S_BASE --export $(shq "$S_EX_GIVEN")$([ "$order" = newest ] || printf ' --order %s' "$order")"
  S_EX_NEW="$S_EX_CMD"
  job="$(tmpfile export-job)"
  if [ -s "$file.citt-export" ]; then
    sid="$(jq -r '.id // empty' "$file.citt-export" 2>/dev/null)"
    sbody="$(jq -S -c '.body // null' "$file.citt-export" 2>/dev/null)"
    shost="$(jq -r '.host // empty' "$file.citt-export" 2>/dev/null)"
  fi
  # A file or a recorded export of another search is not replaced.
  if [ "${sbody:-}" != "$canon" ] && { [ -e "$file" ] || { [ -s "$file.citt-export" ] && [ "${shost:-}" = "$CITT_HOST" ]; }; }; then
    _s_export_taken "$S_BASE --export $(shq "$(_s_fresh_gz "$S_EX_GIVEN")")$([ "$order" = newest ] || printf ' --order %s' "$order")"
  fi
  if [ -s "$file.citt-export" ]; then
    if is_uint "$sid" && [ "$sbody" = "$canon" ] && [ "$shost" = "$CITT_HOST" ]; then
      rc=0
      _s_export_get "$sid" "$job" || rc=$?
      if [ "$rc" = 0 ]; then
        st="$(jq -r '.state' "$job")"
        case "$st" in
          queued | running)
            id="$sid"
            S_EX_FIRST="$job"
            ;;
          done | failed)
            if [ "$st" = failed ] && [ "$(jq -r '.partial == true' "$job")" != true ]; then
              err "$CITT_CMD: export $sid failed; starting a new export of this search"
            elif [ "${S_EX_RESTORED:-0}" = 1 ]; then
              # The file of this export lacks the sessions --load-older just restored.
              err "$CITT_CMD: export $sid was written before this restore; starting a new export of this search"
            else
              id="$sid"
              S_EX_FIRST="$job"
            fi
            ;;
          expired | deleted)
            # A partial export whose file is gone has an error that states it (TASK-641 fix round 2).
            why="$(_s_export_reason "$job")"
            err "$CITT_CMD: ${why:-export $sid is no longer on the server (files are kept 72 hours after an export ends)}; starting a new export of this search"
            ;;
          *) err "$CITT_CMD: export $sid $st; starting a new export of this search" ;;
        esac
      elif [ "$CODE" = 404 ]; then
        err "$CITT_CMD: export $sid is no longer on the server; starting a new export of this search"
      else
        _s_export_read_fail "$sid"
      fi
    fi
  fi
  if [ -z "$id" ]; then
    rc=0
    S_LONG_RETRY=1
    S_SOFT=1
    HTTP_RETRY=no
    _s_call POST "$CITT_V1/capture-search/exports" "$body" || rc=$?
    S_SOFT=0
    S_LONG_RETRY=0
    if [ "$rc" != 0 ]; then
      [ "$CODE:$(body_field '.error')" != 409:search_export_running ] || _s_export_running
      _s_export_fail "?"
    fi
    _s_shape "$SHAPE_EXPORT"
    cp "$RESP" "$job"
    id="$(jq -r '.id' "$job")"
    if [ "$CODE" = 200 ]; then
      err "Export $id of this search is already running; following it."
    else
      err "$CITT_CMD: export $id started on the server; this command follows it"
    fi
    rm -f "$file.part"
    _s_export_state_write "$id" "$canon" "$file"
  fi
  _s_export_follow "$id" "$file" "$timeout"
}

# _s_export_running: a create refused because another export of the account runs (409, TASK-641 D6): its id and rows from the
# export list, and the commands that follow or cancel it; exit 5.
_s_export_running() {
  local line="" oid rows
  HTTP_RETRY=no
  http GET "$CITT_V1/capture-search/exports"
  if ok && jq -e "$JQ_NUM $SHAPE_EXPORT_LIST" "$RESP" >/dev/null 2>&1; then
    line="$(jq -r '[.items[] | select(.state == "queued" or .state == "running")][0] // empty | "\(.id)\t\(.rows_written // 0)"' "$RESP")"
  fi
  if [ -n "$line" ]; then
    oid="${line%%$'\t'*}"
    rows="${line#*$'\t'}"
    die 5 "another export of this account is running (export $oid, $(_s_counted "$rows" row) written); an account runs one export at a time. Follow it: citt search --export-id $oid --export $(shq "$S_EX_GIVEN"), or cancel it: citt search --cancel-export $oid"
  fi
  die 5 "another export of this account is running; an account runs one export at a time; run this command again when it ends"
}

# _s_export_stop CODE: INT (CODE 130) or TERM (143) while an export is followed: the server job keeps running (no DELETE).
_s_export_stop() {
  trap - INT TERM
  [ -z "${S_EX_WAIT:-}" ] || kill "$S_EX_WAIT" 2>/dev/null
  err "Stopped following export $S_EX_ID; it keeps running on the server. The same command follows it and downloads the file: $S_EX_CMD"
  exit "$1"
}

# _s_export_follow ID FILE TIMEOUT: polls export ID every 15 s with a progress line until it is done, then downloads it; exit 12
# after TIMEOUT seconds, 8 when it failed, 4 when it was cancelled or removed. S_EX_FIRST, when set, is an answer of export ID
# read just before, used as the first poll.
_s_export_follow() {
  local id="$1" file="$2" timeout="$3" job st start left rc why pause_seen="" pause
  S_EX_ID="$id"
  trap '_s_export_stop 130' INT
  trap '_s_export_stop 143' TERM
  job="$(tmpfile export-poll)"
  start="$(now_s)"
  while :; do
    rc=0
    if [ -n "${S_EX_FIRST:-}" ]; then
      cp "$S_EX_FIRST" "$job"
      S_EX_FIRST=""
    else
      _s_export_get "$id" "$job" || rc=$?
    fi
    [ "$rc" = 0 ] || _s_export_read_fail "$id"
    _s_export_id_learn "$job"
    st="$(jq -r '.state' "$job")"
    case "$st" in
      done) break ;;
      queued)
        err "$CITT_CMD: export $id: $(jq -r "$JQ_COUNTED"'if (.jobs_ahead // 0) > 0 then "queued, \(.jobs_ahead | counted("export")) ahead" else "queued, next to start" end' "$job")"
        ;;
      running)
        # A pause (TASK-641 D6) keeps the counts unchanged and ends by itself: its sentence prints once, and the follow goes on.
        pause="$(jq -r '[.paused_since // "", .paused_reason // ""] | join(" ")' "$job")"
        why=""
        if [ "$pause" != "$pause_seen" ]; then
          pause_seen="$pause"
          why="$(plain_message "$(jq -r '.paused_reason // empty' "$job")" search_export)"
        fi
        err "$CITT_CMD: export $id: $(jq -r "$JQ_COUNTED"'"\(.rows_written // 0 | counted("row")) written, \(.sessions_read // 0 | grp) of \(.sessions_total // 0 | grp) sessions read (\((.progress // 0) * 100 | floor)%)"' "$job")${why:+; $why}"
        ;;
      failed)
        # Rows in a file (TASK-641 D14): downloaded and kept like a done export; _s_export_summary ends it with exit 13.
        [ "$(jq -r '.partial == true' "$job")" != true ] || break
        trap - INT TERM
        _s_export_notes "$job"
        why="$(_s_export_reason "$job")"
        [ -z "$why" ] || die 8 "export $id failed: $why"
        die 8 "export $id failed after $(_s_counted "$(jq -r '.rows_written // 0' "$job")" row): $(_s_export_why "$(jq -r '.error_code // empty' "$job")")"
        ;;
      cancelled)
        trap - INT TERM
        die 4 "export $id was cancelled; start it again: $S_EX_NEW"
        ;;
      *)
        trap - INT TERM
        # A partial export whose file is gone: its error states it, rest is null, and nothing is downloaded.
        why="$(_s_export_reason "$job")"
        [ -z "$why" ] || die 4 "$why: $S_EX_NEW"
        die 4 "export $id is no longer on the server (files are kept 72 hours after an export ends); start it again: $S_EX_NEW"
        ;;
    esac
    left=$((timeout - ($(now_s) - start)))
    if [ "$left" -le 0 ]; then
      trap - INT TERM
      die 12 "export $id is still running on the server ($(_s_counted "$(jq -r '.rows_written // 0' "$job")" row) written); the same command follows it and downloads the file: $S_EX_CMD"
    fi
    # In the background, so a TERM to the group ends the wait at once and bash prints no Terminated line for the sleep.
    poll_sleep "" "$left" </dev/null >/dev/null 2>&1 &
    S_EX_WAIT=$!
    wait "$S_EX_WAIT"
    S_EX_WAIT=""
  done
  _s_export_notes "$job"
  _s_export_download "$job" "$file"
  trap - INT TERM
  _s_export_summary "$job" "$file"
}

# _s_export_reason JOB: the service's sentence of why the export failed, empty when plain_message refuses it. The code passed
# is error_code or a word no sentence holds: without one plain_message compares the text with the answer's own error field,
# which here is the text.
_s_export_reason() {
  local text code
  text="$(jq -r '.error // empty' "$1")"
  code="$(jq -r '.error_code // empty' "$1")"
  [ -z "$text" ] || plain_message "$text" "${code:-search_export}"
}

# _s_export_why CODE: why an export failed (TASK-641 D13 error_code), in the plugin's words, for an answer with no sentence
# that can be printed.
_s_export_why() {
  case "$1" in
    page_too_slow) printf 'a part of the search took too long to read; narrow the range or add a host or app condition, then export again' ;;
    database_busy) printf 'the server was busy for too long; export again shortly' ;;
    *) printf 'a service error stopped the export; export again, and contact support if it stops again' ;;
  esac
}

# _s_export_download JOB FILE: the file of the done or partial export JOB into FILE.part with Range resume across a restart, its SHA-256
# checked, then moved to FILE; a FILE that already has the SHA-256 is kept. A mismatch downloads once more, then exits 11.
_s_export_download() {
  local job="$1" file="$2" want url bytes part round outages got size
  want="$(jq -r '.file_sha256 // empty' "$job")"
  bytes="$(jq -r '.file_bytes // empty' "$job")"
  url="$(jq -r '.download_url // empty' "$job")"
  [ -n "$url" ] || url="$CITT_V1/capture-search/exports/$S_EX_ID/download"
  case "$url" in
    /*) ;;
    "$CITT_HOST"/*) url="${url#"$CITT_HOST"}" ;;
    *) die 1 "unexpected response from the server" ;;
  esac
  if [ -n "$want" ] && [ -s "$file" ] && [ "$(sha256_of "$file")" = "$want" ]; then
    S_EX_KEPT=1
    return 0
  fi
  S_EX_KEPT=0
  # --export-id names no search: a file that this export did not write is not replaced.
  if [ "${S_EX_ID_RUN:-0}" = 1 ] && [ -e "$file" ] && [ "$(jq -r '.id // empty' "$file.citt-export" 2>/dev/null)" != "$S_EX_ID" ]; then
    trap - INT TERM
    _s_export_taken "citt search --export-id $S_EX_ID --export $(shq "$(_s_fresh_gz "$S_EX_GIVEN")")"
  fi
  part="$file.part"
  local fresh
  for round in 1 2; do
    outages=0
    fresh=0
    while :; do
      HTTP_OUT="$part"
      HTTP_RESUME=1
      HTTP_RETRY=no
      http GET "$url"
      # A part file past the file's end (416) is dropped and the download starts again once.
      if [ "$CODE" = 416 ] && [ "$fresh" = 0 ]; then
        rm -f "$part"
        fresh=1
        continue
      fi
      size="$(file_bytes "$part" 2>/dev/null || printf 0)"
      case "$CODE" in
        200 | 206)
          # A transfer cut under its length resumes like a lost connection.
          if ! is_uint "$bytes" || [ "$size" -ge "$bytes" ]; then break; fi
          CODE=000
          ;;
      esac
      # shellcheck disable=SC2086
      if _s_outage "" && [ "$outages" -lt "$(printf '%s\n' $SEARCH_OUTAGE_WAITS | wc -l | tr -d ' ')" ]; then
        outages=$((outages + 1))
        local wait
        wait="$(_s_outage_wait "$outages")"
        err "$CITT_CMD: the download of export $S_EX_ID stopped; trying again in $wait s"
        sleep "$wait"
        continue
      fi
      if ok || [ "$CODE" = 000 ]; then
        trap - INT TERM
        die 9 "the download of export $S_EX_ID stopped: the service could not be reached; the same command resumes it: $S_EX_CMD"
      fi
      # http() writes the body of an answer other than 200 or 206 to RESP (NP-1340 L4), so its sentence is mapped below.
      rm -f "$part"
      trap - INT TERM
      _s_export_fail "$S_EX_ID"
    done
    got="$(sha256_of "$part")"
    if [ -z "$want" ] || [ "$got" = "$want" ]; then
      mv -f "$part" "$file" || die 1 "cannot write $file"
      return 0
    fi
    rm -f "$part"
  done
  trap - INT TERM
  die 11 "the file of export $S_EX_ID did not match its SHA-256 on two downloads; no file was written; run the same command again: $S_EX_CMD"
}

# _s_export_try_fresh JOB: once, on stderr, the command of a fresh export of this search. The same command reads the export of
# the state file, so a fresh one needs another file.
_s_export_try_fresh() {
  [ "${S_EX_TRIED:-0}" = 0 ] || return 0
  S_EX_TRIED=1
  local other order
  other="$(_s_fresh_gz "$S_EX_GIVEN")"
  order="$(jq -r '.order // "newest"' "$1")"
  err "  try: $S_BASE --export $(shq "$other")$([ "$order" = newest ] || printf ' --order %s' "$order")"
}

# _s_export_notes JOB: the service's notes on stderr (TASK-641 D13: what the file leaves out and the next action), each through
# plain_message; sessions in the archive add the command that restores them and exports again.
_s_export_notes() {
  local job="$1" n line code ev
  code="$(jq -r '.error_code // empty' "$job")"
  while IFS= read -r n; do
    line="$(plain_message "$n" "${code:-search_export}")"
    [ -z "$line" ] || err "$CITT_CMD: $line"
    case "$line" in *"arrived after"*) _s_export_try_fresh "$job" ;; esac
  done < <(jq -r '.notes // [] | .[]' "$job")
  ev="$(jq -r '.sessions_evicted // 0' "$job")"
  if is_uint "$ev" && [ "$ev" -gt 0 ]; then err "  try: $S_EX_NEW --load-older"; fi
}

# _s_export_summary JOB FILE: the range, rows, file and columns of a downloaded export. Exit 13 for a file that is not complete:
# the export stopped at its row limit or failed with rows in its file (partial), with the command of the rest, or sessions
# are left out because they are in the archive, stated on the last line.
_s_export_summary() {
  local job="$1" file="$2" f t src rows partial limited why ev
  IFS=$'\t' read -r f t src < <(jq -r "$JQ_TS"'"\(.from | ts | floor)\t\(.to | ts | floor)\t\(.range_source // "")"' "$job" 2>/dev/null)
  if is_uint "$f" && [ "$f" != 0 ]; then
    printf 'Range: %s to %s%s.\n' "$(local_time "$f")" "$(local_time "$t")" "$([ "$src" != default ] || printf ' (the last 30 days, the default)')"
  fi
  rows="$(jq -r '.row_count // .rows_written // 0' "$job")"
  if [ "${S_EX_KEPT:-0}" = 1 ]; then
    _s_export_try_fresh "$job"
    printf '%s already holds the %s of export %s (gzip CSV, %s, SHA-256 verified).\n' "$file" "$(_s_counted "$rows" row)" "$S_EX_ID" \
      "$(_s_bytes "$(file_bytes "$file")")"
  elif [ -n "$(jq -r '.file_sha256 // empty' "$job")" ]; then
    printf 'Wrote %s to %s (gzip CSV, %s, SHA-256 verified).\n' "$(_s_counted "$rows" row)" "$file" "$(_s_bytes "$(file_bytes "$file")")"
  else
    printf 'Wrote %s to %s (gzip CSV, %s; the server gave no SHA-256, so the file was not checked).\n' "$(_s_counted "$rows" row)" "$file" \
      "$(_s_bytes "$(file_bytes "$file")")"
  fi
  printf 'Columns: %s\n' "$(jq -r --arg d "$SEARCH_COLUMNS" 'if (.columns // []) == [] then ($d | split(" ")) else .columns end | join(", ")' "$job")"
  partial="$(jq -r '.partial == true' "$job")"
  limited="$(jq -r '.limit_reached == true and .rest != null' "$job")"
  if [ "$partial" = true ]; then
    why="$(_s_export_reason "$job")"
    if [ -n "$why" ]; then
      printf 'Export %s failed: %s\n' "$S_EX_ID" "$why"
    else
      printf 'Export %s stopped after %s: %s\n' "$S_EX_ID" "$(_s_counted "$rows" row)" "$(_s_export_why "$(jq -r '.error_code // empty' "$job")")"
    fi
    [ "$(jq -r '.rest != null' "$job")" != true ] || printf '%s\n' "$(_s_export_rest_line "$job" "$file" 'The sessions')"
  elif [ "$limited" = true ]; then
    printf '%s\n' "$(_s_export_rest_line "$job" "$file" "The export stopped at its limit of $(_s_counted "$(jq -r '.max_rows // 0' "$job")" row): the sessions")"
  fi
  ev="$(jq -r '.sessions_evicted // 0' "$job")"
  if is_uint "$ev" && [ "$ev" -gt 0 ]; then
    if [ "$ev" = 1 ]; then
      printf 'This file is not complete: 1 older session is archived; restore it and export again: %s --load-older\n' "$S_EX_NEW"
    else
      printf 'This file is not complete: %s older sessions are archived; restore them and export again: %s --load-older\n' "$(_s_grp "$ev")" "$S_EX_NEW"
    fi
  fi
  if [ "$partial" = true ] || [ "$limited" = true ]; then exit 13; fi
  if is_uint "$ev" && [ "$ev" -gt 0 ]; then exit 13; fi
}

# _s_export_rest_said JOB: true when a note printed on stderr states the rest (its range and the merge by id, TASK-641 D7).
_s_export_rest_said() {
  local n code
  code="$(jq -r '.error_code // empty' "$1")"
  while IFS= read -r n; do
    case "$n" in *"merge the files by id"*) [ -z "$(plain_message "$n" "${code:-search_export}")" ] || return 0 ;; esac
  done < <(jq -r '.notes // [] | .[]' "$1")
  return 1
}

# _s_export_rest_line JOB FILE LEAD: the command that exports .rest; before it LEAD and the range, and after it the merge, unless
# a note already printed them.
_s_export_rest_line() {
  local job="$1" file="$2" rest_f rest_t lf lt rep order cmd
  rest_f="$(jq -r '.rest.from' "$job")"
  rest_t="$(jq -r '.rest.to' "$job")"
  order="$(jq -r '.order // "newest"' "$job")"
  lf="$(local_time "$(jq -r "$JQ_TS"'.rest.from | ts | floor' "$job")")"
  lt="$(local_time "$(jq -r "$JQ_TS"'.rest.to | ts | floor' "$job")")"
  if [ "$order" = oldest ]; then rep="$lf"; else rep="$lt"; fi
  cmd="$S_EX_HEAD --from $(shq "$rest_f") --to $(shq "$rest_t")$(_s_project_words) --export $(shq "$(_s_next_gz "$S_EX_GIVEN")")$([ "$order" = newest ] || printf ' --order %s' "$order")"
  if _s_export_rest_said "$job"; then
    printf 'The rest: %s' "$cmd"
  else
    printf '%s started from %s to %s are missing from %s. The rest: %s; the session started at %s is in both files: merge them by id.' \
      "$3" "$lf" "$lt" "$file" "$cmd" "$rep"
  fi
}

# _s_export_id ID FILE TIMEOUT: --export-id: follows and downloads export ID, whatever its search.
_s_export_id() {
  S_EX_CMD="citt search --export-id $1 --export $(shq "$S_EX_GIVEN")"
  S_EX_NEW="$S_EX_NO_QUERY --export $(shq "$S_EX_GIVEN")"
  S_BASE="$S_EX_NO_QUERY"
  S_EX_HEAD="$S_EX_NO_QUERY"
  S_EX_BY_ID=1
  S_EX_ID_RUN=1
  _s_export_follow "$1" "$2" "$3"
}

# _s_export_id_learn JOB: for --export-id, whose command names no search: the printed commands take the query, projects, range
# and order of the export's answer; an answer with no query keeps the words that say what to add.
_s_export_id_learn() {
  [ "${S_EX_BY_ID:-0}" = 1 ] || return 0
  S_EX_BY_ID=0
  local q order
  q="$(jq -r '.query // empty' "$1")"
  order="$(jq -r '.order // "newest"' "$1")"
  S_PIDS="$(jq -r '(.project_ids // []) | map(tostring) | join(" ")' "$1")"
  if [ -n "$q" ]; then S_EX_HEAD="citt search --query $(_s_qq "$q")"; fi
  S_BASE="$S_EX_HEAD --from $(shq "$(jq -r '.from // empty' "$1")") --to $(shq "$(jq -r '.to // empty' "$1")")$(_s_project_words)"
  S_EX_NEW="$S_BASE --export $(shq "$S_EX_GIVEN")$([ "$order" = newest ] || printf ' --order %s' "$order")"
}

# _s_export_cancel ID: --cancel-export: DELETE of export ID; prints its state.
_s_export_cancel() {
  local rc=0
  S_EX_NEW="$S_EX_NO_QUERY --export FILE.csv.gz"
  S_SOFT=1
  HTTP_RETRY=no
  _s_call DELETE "$CITT_V1/capture-search/exports/$1" || rc=$?
  S_SOFT=0
  [ "$rc" = 0 ] || _s_export_fail "$1"
  _s_shape "$SHAPE_EXPORT"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c . "$RESP"
    return 0
  fi
  case "$(jq -r '.state' "$RESP")" in
    cancelled) printf 'Export %s: cancelled.\n' "$1" ;;
    deleted) printf 'Export %s: deleted; its file is removed from the server.\n' "$1" ;;
    *) printf 'Export %s: %s.\n' "$1" "$(jq -r '.state' "$RESP")" ;;
  esac
}
