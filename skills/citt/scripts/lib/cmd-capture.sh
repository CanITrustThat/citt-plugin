#!/usr/bin/env bash
# lib/cmd-capture.sh: citt capture-sync and citt captures (DESIGN-capture-data 2.5).
# capture-sync downloads completed capture sessions through the authenticated API: the
# GET /capture-sessions feed from a changed_after cursor, then each session's file list and each
# file with Range resume and a sha256 check. Only <file>.part is ever incomplete; a final name exists
# only after its hash matches; the session marker is written last; the state file is renamed into
# place. --install-timer runs the same command from a systemd user timer or a launchd agent, which
# read the token where the plugin stores it (keyring or the 0600 file); no unit holds a token.
# jq programs are single-quoted on purpose (SC2016); a download worker keeps its own RESP and HDRS in
# its subshell (SC2030, SC2031); CODE is set by http() in common.sh (SC2153).
# shellcheck shell=bash disable=SC2034,SC2016,SC2030,SC2031,SC2153

CS_GROUPS_ALL="analysis,network,data,video"
CS_SCHEMAS="run session event request ad bid citation app"
CS_RUN_FILES="README.md run.json citations.jsonl app.json"
CS_EPOCH="1970-01-01T00:00:00Z"
CS_OVERLAP_S=900
CS_MIN_EVERY=300
# Seconds before a failed session is tried again, by attempt: 15 min, 1 h, 4 h, then 24 h.
CS_BACKOFF="900 3600 14400 86400"

# jq: `ts` turns an RFC 3339 UTC time (any fraction, Z or +00:00) into epoch seconds with the fraction.
CS_JQ_TS='def ts: if . == null or . == "" then 0 else
  (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601)
  + ((capture("\\.(?<f>[0-9]+)") | ("0." + .f) | tonumber) // 0) end;'

# --- small helpers -----------------------------------------------------------------

_cs_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_cs_size() {
  if [ -e "$1" ]; then wc -c <"$1" | tr -d ' '; else printf '0'; fi
}

# _cs_bytes N: 1234567 -> "1.2 MB" (decimal units).
_cs_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b < 1000) printf "%d B", b
    else if (b < 1e6) printf "%.1f KB", b / 1e3
    else if (b < 1e9) printf "%.1f MB", b / 1e6
    else if (b < 1e12) printf "%.1f GB", b / 1e9
    else printf "%.1f TB", b / 1e12 }'
}

# _cs_dur SECONDS: "45 s", "12 min", "3 h 5 min".
_cs_dur() {
  local s="$1"
  if [ "$s" -lt 60 ]; then
    printf '%s s' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%s min' "$((s / 60))"
  elif [ $(((s % 3600) / 60)) -eq 0 ]; then
    printf '%s h' "$((s / 3600))"
  else
    printf '%s h %s min' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

# _cs_n N ONE MANY: "1 file", "3 files".
_cs_n() { if [ "$1" = 1 ]; then printf '1 %s' "$2"; else printf '%s %s' "$1" "$3"; fi; }

# _cs_every TEXT: seconds of "15m", "1h", "900s"; empty when malformed.
_cs_every() {
  case "$1" in
    *s) is_uint "${1%s}" && printf '%s' "${1%s}" ;;
    *m) is_uint "${1%m}" && printf '%s' "$((${1%m} * 60))" ;;
    *h) is_uint "${1%h}" && printf '%s' "$((${1%h} * 3600))" ;;
  esac
  return 0
}

# _cs_minus_overlap TIME: TIME minus 15 minutes, whole seconds, RFC 3339.
_cs_minus_overlap() {
  jq -rn --arg t "$1" --argjson o "$CS_OVERLAP_S" "$CS_JQ_TS"' $t | ts | floor - $o | if . < 0 then 0 else . end | todateiso8601'
}

# _cs_later A B: true when time A is after time B.
_cs_later() {
  jq -en --arg a "$1" --arg b "$2" "$CS_JQ_TS"' ($a | ts) > ($b | ts)' >/dev/null 2>&1
}

_cs_str_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}

# _cs_segment NAME: true when NAME is one safe path segment (a run key or a session folder).
_cs_segment() {
  case "$1" in '' | . | .. | */* | *\\* | .citt-sync) return 1 ;; esac
  return 0
}

# _cs_unsafe PATH: true when PATH is absolute, empty, has a backslash or a "", "." or ".." segment.
_cs_unsafe() {
  case "$1" in /* | *\\* | '') return 0 ;; esac
  case "/$1/" in */../* | */./* | *//*) return 0 ;; esac
  return 1
}

# The plugin version: the copy's VERSION file, else the plugin manifest.
_cs_version() {
  if [ -f "$CITT_LIB/../VERSION" ]; then
    tr -d '\n' <"$CITT_LIB/../VERSION"
  else
    jq -r '.version // "unknown"' "$CITT_LIB/../../../../.claude-plugin/plugin.json" 2>/dev/null || printf 'unknown'
  fi
}

# --- arguments -----------------------------------------------------------------------

CS_DIR=""
CS_META=""
CS_GROUPS="$CS_GROUPS_ALL"
CS_SINCE=""
CS_PARALLEL=2
CS_RATE=""
CS_DRY=0
CS_VERIFY=0
CS_EVERY=""
CS_PROJECTS=""
CS_RUNS=""
CS_PIDS=""
CS_RIDS=""
CS_FILTER_Q=""

# _cs_norm_groups LIST: the groups in canonical order; empty when one is unknown.
_cs_norm_groups() {
  local g out=""
  for g in $(printf '%s' "$1" | tr ',' ' '); do
    case "$g" in analysis | network | data | video) ;; *) return 0 ;; esac
  done
  for g in analysis network data video; do
    case ",$1," in *",$g,"*) out="$out${out:+,}$g" ;; esac
  done
  printf '%s' "$out"
}

# _cs_since TEXT: an RFC 3339 time for a date or a UTC time; empty when malformed.
_cs_since() {
  if printf '%s' "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    printf '%sT00:00:00Z' "$1"
  elif printf '%s' "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    printf '%s' "$1"
  fi
}

# _cs_args: the options of this sync as one word per line, for a timer, cron or --watch.
_cs_args() {
  local v
  printf -- '--dir\n%s\n' "$CS_DIR"
  [ "$CS_GROUPS" = "$CS_GROUPS_ALL" ] || printf -- '--groups\n%s\n' "$CS_GROUPS"
  while IFS= read -r v; do [ -z "$v" ] || printf -- '--project\n%s\n' "$v"; done <<EOF
$CS_PROJECTS
EOF
  while IFS= read -r v; do [ -z "$v" ] || printf -- '--run\n%s\n' "$v"; done <<EOF
$CS_RUNS
EOF
  [ "$CS_PARALLEL" = 2 ] || printf -- '--parallel\n%s\n' "$CS_PARALLEL"
  [ -z "$CS_RATE" ] || printf -- '--limit-rate\n%s\n' "$CS_RATE"
  [ -z "$CS_SINCE" ] || printf -- '--since\n%s\n' "$CS_SINCE"
}

cmd_capture_sync() {
  local mode=sync dir="${CITT_CAPTURE_DIR:-./citt-captures}" groups="$CS_GROUPS_ALL" every="" since="" g
  CITT_CMD="citt capture-sync"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)
        need_value "$1" $#
        dir="$2"
        shift
        ;;
      --project)
        need_value "$1" $#
        CS_PROJECTS="$CS_PROJECTS$2"$'\n'
        shift
        ;;
      --run)
        need_value "$1" $#
        CS_RUNS="$CS_RUNS$2"$'\n'
        shift
        ;;
      --groups)
        need_value "$1" $#
        groups="$2"
        shift
        ;;
      --since)
        need_value "$1" $#
        since="$2"
        shift
        ;;
      --parallel)
        need_value "$1" $#
        CS_PARALLEL="$2"
        shift
        ;;
      --limit-rate)
        need_value "$1" $#
        CS_RATE="$2"
        shift
        ;;
      --every)
        need_value "$1" $#
        every="$2"
        shift
        ;;
      --dry-run) CS_DRY=1 ;;
      --verify) CS_VERIFY=1 ;;
      --watch | --install-timer | --uninstall-timer | --status | --print-cron)
        [ "$mode" = sync ] || usage_error "use one of --watch, --install-timer, --uninstall-timer, --status and --print-cron"
        mode="${1#--}"
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_capture_sync
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  [ -n "$dir" ] || usage_error "--dir needs a folder"
  CS_GROUPS="$(_cs_norm_groups "$groups")"
  [ -n "$CS_GROUPS" ] || usage_error "--groups takes a comma list of analysis, network, data and video, got: $groups"
  if ! is_uint "$CS_PARALLEL" || [ "$CS_PARALLEL" -lt 1 ] || [ "$CS_PARALLEL" -gt 4 ]; then
    usage_error "--parallel takes 1 to 4 (the service streams 4 files at a time per account), got: $CS_PARALLEL"
  fi
  if [ -n "$CS_RATE" ] && ! printf '%s' "$CS_RATE" | grep -qE '^[0-9]+[kKmMgG]?$'; then
    usage_error "--limit-rate takes bytes per second such as 500k or 2M, got: $CS_RATE"
  fi
  if [ -n "$since" ]; then
    CS_SINCE="$(_cs_since "$since")"
    [ -n "$CS_SINCE" ] || usage_error "--since takes a date (2026-10-01) or a UTC time (2026-10-01T08:00:00Z), got: $since"
  fi
  if [ -n "$every" ]; then
    case "$mode" in watch | install-timer | print-cron) ;; *) usage_error "--every goes with --watch, --install-timer or --print-cron" ;; esac
    CS_EVERY="$(_cs_every "$every")"
    [ -n "$CS_EVERY" ] || usage_error "--every takes a duration such as 15m or 1h, got: $every"
    [ "$CS_EVERY" -ge "$CS_MIN_EVERY" ] || usage_error "--every is 5 minutes at least, got: $every"
  fi
  CS_EVERY="${CS_EVERY:-900}"
  if [ "$mode" != sync ] && { [ "$CS_DRY" = 1 ] || [ "$CS_VERIFY" = 1 ]; }; then
    usage_error "--dry-run and --verify go with a plain sync"
  fi
  case "$dir" in /*) ;; *) dir="$PWD/${dir#./}" ;; esac
  [ ! -d "$dir" ] || dir="$(cd "$dir" && pwd)"
  CS_DIR="${dir%/}"
  CS_META="$CS_DIR/.citt-sync"
  g="$CS_RATE"
  [ -z "$g" ] || HTTP_EXTRA_ARGS="--limit-rate"$'\n'"$g"
  case "$mode" in
    sync) _cs_sync ;;
    status) _cs_status ;;
    install-timer) _cs_install ;;
    uninstall-timer) _cs_uninstall ;;
    print-cron) _cs_cron ;;
    watch) _cs_watch ;;
  esac
}

# --- lock ----------------------------------------------------------------------------

CS_LOCKDIR=""

_cs_unlock() {
  [ -z "$CS_LOCKDIR" ] || rm -rf "$CS_LOCKDIR" 2>/dev/null || true
}

# _cs_lock: flock on <meta>/lock where flock exists, else a mkdir lock with a pid file whose
# process is checked; false when another sync holds it.
_cs_lock() {
  if command -v flock >/dev/null 2>&1 && ! { [ "${CITT_TEST_MODE:-}" = 1 ] && [ "${CITT_SYNC_NO_FLOCK:-}" = 1 ]; }; then
    exec 9>>"$CS_META/lock" || die 1 "cannot open $CS_META/lock"
    flock -n 9
    return
  fi
  local d="$CS_META/lock.d" p
  if ! mkdir "$d" 2>/dev/null; then
    p="$(cat "$d/pid" 2>/dev/null)"
    if is_uint "$p"; then
      kill -0 "$p" 2>/dev/null && return 1
    elif [ -z "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      return 1
    fi
    rm -rf "$d"
    mkdir "$d" 2>/dev/null || return 1
  fi
  printf '%s' "$$" >"$d/pid"
  CS_LOCKDIR="$d"
  trap '_cs_unlock; _citt_cleanup' EXIT
  return 0
}

# --- state ---------------------------------------------------------------------------

CS_ST=""

# _cs_state_load: the state into a private working copy at $CS_ST (a fresh one when absent).
_cs_state_load() {
  CS_ST="$(tmpfile state.json)"
  if [ -s "$CS_META/state.json" ]; then
    jq -e 'type == "object"' "$CS_META/state.json" >/dev/null 2>&1 \
      || die 1 "$CS_META/state.json is not valid JSON; move it away to start a full sync"
    cp "$CS_META/state.json" "$CS_ST"
  else
    jq -n '{state_schema: 1, host: null, account: null, filters: null, high_water: null, runs_high_water: null,
      sessions: {}, runs: {}, failures: {}}' >"$CS_ST"
  fi
}

# _cs_st FILTER [jq args...]: applies a jq filter to the working copy.
_cs_st() {
  local f="$1"
  shift
  jq "$@" "$f" "$CS_ST" >"$CS_ST.new" || die 1 "cannot update the sync state"
  mv -f "$CS_ST.new" "$CS_ST"
}

# _cs_save: the working copy renamed into place (never in a dry run).
_cs_save() {
  [ "$CS_DRY" = 1 ] && return 0
  if ! { cp "$CS_ST" "$CS_META/state.json.tmp" && mv -f "$CS_META/state.json.tmp" "$CS_META/state.json"; }; then
    die 1 "cannot write $CS_META/state.json"
  fi
}

# --- filters -------------------------------------------------------------------------

# _cs_resolve_projects: CS_PIDS from CS_PROJECTS (ids as given, names through GET /projects).
_cs_resolve_projects() {
  local p ids listed=0 list
  list="$(tmpfile projects.json)"
  CS_PIDS=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if is_uint "$p"; then
      CS_PIDS="$CS_PIDS$p"$'\n'
      continue
    fi
    if [ "$listed" = 0 ]; then
      call GET "$CITT_V1/projects"
      cp "$RESP" "$list"
      listed=1
    fi
    ids="$(jq -r --arg n "$p" '[.projects[] | select(.name == $n) | .project_id] | map(tostring) | join(" ")' "$list")" \
      || die 1 "unparseable response from GET $CITT_V1/projects"
    case "$ids" in
      '') die 4 "no project named \"$p\" among your projects" ;;
      *' '*) die 5 "several projects named \"$p\": ids $(printf '%s' "$ids" | sed 's/ /, /g'); give the id with --project" ;;
    esac
    CS_PIDS="$CS_PIDS$ids"$'\n'
  done <<EOF
$CS_PROJECTS
EOF
  CS_PIDS="$(printf '%s' "$CS_PIDS" | sort -n -u)"
}

# _cs_pid_query: "&project_id=N" for each resolved project.
_cs_pid_query() {
  local p q=""
  for p in $CS_PIDS; do q="$q&project_id=$p"; done
  printf '%s' "$q"
}

# _cs_resolve_runs: CS_RIDS from CS_RUNS (ids as given, run keys through GET /capture-runs).
_cs_resolve_runs() {
  local r cursor id all
  all="$(tmpfile runs_all.jsonl)"
  CS_RIDS=""
  [ -n "$(printf '%s' "$CS_RUNS" | tr -d '\n')" ] || return 0
  if printf '%s' "$CS_RUNS" | grep -qv '^[0-9]*$'; then
    cursor=""
    while :; do
      call GET "$CITT_V1/capture-runs?limit=200$(_cs_pid_query)${cursor:+&cursor=$(urlenc "$cursor")}"
      jq -c '.runs[] | {experiment_id, run_key}' "$RESP" >>"$all" 2>/dev/null \
        || die 1 "unparseable response from GET $CITT_V1/capture-runs"
      cursor="$(body_field '.next_cursor')"
      [ -n "$cursor" ] || break
    done
  fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if is_uint "$r"; then
      CS_RIDS="$CS_RIDS$r"$'\n'
      continue
    fi
    id="$(jq -r --arg k "$r" 'select(.run_key == $k) | .experiment_id' "$all" | head -n1)"
    [ -n "$id" ] || die 4 "no capture run $r in your projects (see: citt captures)"
    CS_RIDS="$CS_RIDS$id"$'\n'
  done <<EOF
$CS_RUNS
EOF
  CS_RIDS="$(printf '%s' "$CS_RIDS" | sort -n -u)"
}

_cs_filters_json() {
  jq -nc --arg p "$CS_PIDS" --arg r "$CS_RIDS" --arg g "$CS_GROUPS" \
    '{projects: ($p | split("\n") | map(select(. != "") | tonumber)), runs: ($r | split("\n") | map(select(. != "") | tonumber)), groups: $g}'
}

# --- downloads -----------------------------------------------------------------------

CS_FCODE=0
CS_FMSG=""

_cs_retry_after() {
  local ra
  if [ "${CITT_TEST_MODE:-}" = 1 ]; then
    printf '0'
    return
  fi
  ra="$(hdr Retry-After)"
  if is_uint "$ra" && [ "$ra" -le 300 ]; then printf '%s' "$ra"; else printf '5'; fi
}

# _cs_fetch SESSION REL SIZE SHA FINAL: downloads one file to FINAL.part with resume, checks the
# ETag and the sha256, then renames it to FINAL. On failure sets CS_FCODE (an exit code) and CS_FMSG.
_cs_fetch() {
  local sid="$1" rel="$2" size="$3" sha="$4" final="$5" part url have got e total tries=0 bad=0 waits=0 tagbad
  part="$final.part"
  url="$CITT_V1/capture-sessions/$sid/file?path=$(urlenc "$rel")"
  if ! mkdir -p "$(dirname "$final")" 2>/dev/null; then
    CS_FCODE=1
    CS_FMSG="cannot create $(dirname "$final")"
    return 1
  fi
  while :; do
    have="$(_cs_size "$part")"
    if [ "$have" -gt "$size" ]; then
      rm -f "$part"
      have=0
    fi
    tagbad=0
    if [ "$have" -lt "$size" ] || [ ! -e "$part" ]; then
      tries=$((tries + 1))
      HTTP_OUT="$part"
      HTTP_RESUME=1
      http GET "$url"
      case "$CODE" in
        200 | 206) ;;
        416)
          rm -f "$part"
          [ "$tries" -ge 5 ] || continue
          CS_FCODE=8
          CS_FMSG="$rel: the server refused the byte range (416)"
          return 1
          ;;
        429)
          waits=$((waits + 1))
          if [ "$waits" -le 10 ]; then
            sleep "$(_cs_retry_after)"
            continue
          fi
          CS_FCODE=6
          CS_FMSG="the service streams 4 files at a time per account and refused $rel 10 times (429); lower --parallel or stop other downloads"
          return 1
          ;;
        401)
          CS_FCODE=3
          CS_FMSG="not signed in or the token expired; run: citt auth"
          return 1
          ;;
        403)
          CS_FCODE=3
          CS_FMSG="$rel: refused (403); the session belongs to a project you no longer own"
          return 1
          ;;
        000)
          CS_FCODE=9
          CS_FMSG="cannot reach $CITT_HOST ($NET_REASON)$(_retried_suffix); the next sync resumes $rel from $(_cs_bytes "$(_cs_size "$part")")"
          return 1
          ;;
        404)
          CS_FCODE=8
          CS_FMSG="$rel is no longer in the session's file list (404); the next sync lists the session again"
          return 1
          ;;
        *)
          CS_FCODE=8
          CS_FMSG="$rel: server error $CODE$(_retried_suffix)"
          return 1
          ;;
      esac
      [ -e "$part" ] || : >"$part"
      e="$(hdr ETag | sed -e 's|^W/||' -e 's/"//g')"
      [ -z "$e" ] || [ "$e" = "$sha" ] || tagbad=1
      # The total the server declares (Content-Range of a 206, Content-Length of a 200) is the listed size.
      if [ "$CODE" = 206 ]; then total="$(hdr Content-Range | sed -n 's|^bytes [0-9]*-[0-9]*/\([0-9]*\)$|\1|p')"; else total="$(hdr Content-Length)"; fi
      ! is_uint "$total" || [ "$total" = "$size" ] || tagbad=1
    fi
    got="$(_cs_size "$part")"
    if [ "$tagbad" = 0 ] && [ "$got" -lt "$size" ]; then
      if [ "$tries" -ge 5 ]; then
        CS_FCODE=9
        CS_FMSG="the download of $rel stopped at $got of $size bytes; the next sync resumes it"
        return 1
      fi
      # No progress: the server ignored the range; start the file over.
      [ "$got" -gt "$have" ] || rm -f "$part"
      continue
    fi
    if [ "$tagbad" = 0 ] && [ "$got" -eq "$size" ] && [ "$(sha256_of "$part")" = "$sha" ]; then
      mv -f "$part" "$final" || {
        CS_FCODE=1
        CS_FMSG="cannot write $final"
        return 1
      }
      return 0
    fi
    rm -f "$part"
    bad=$((bad + 1))
    if [ "$bad" -ge 2 ]; then
      CS_FCODE=11
      if [ "$tagbad" = 1 ]; then
        CS_FMSG="$rel differs from the server's list twice (ETag ${e:-none}, ${total:-?} bytes; listed sha256 $sha, $size bytes); nothing was kept"
      else
        CS_FMSG="sha256 of $rel differs from the server's list twice (listed $sha); nothing was kept"
      fi
      return 1
    fi
  done
}

# _cs_worker N LIST OUT SESSION SESSDIR: downloads the files of LIST (rel, size, sha per line) in a
# background subshell with its own header and error files; one result line per file in OUT.
_cs_worker() {
  local n="$1" list="$2" out="$3" sid="$4" sdir="$5"
  (
    HDRS="$_CITT_TMP/hdrs.$n"
    _CITT_ERR="$_CITT_TMP/err.$n"
    RESP="$_CITT_TMP/resp.$n"
    : >"$HDRS"
    : >"$_CITT_ERR"
    # --fail keeps an error body out of a .part; the speed limit ends a stalled stream for a resume.
    HTTP_EXTRA_ARGS="${HTTP_EXTRA_ARGS}${HTTP_EXTRA_ARGS:+$'\n'}--fail"$'\n'"--speed-limit"$'\n'"1"$'\n'"--speed-time"$'\n'"120"
    local drops=0
    while IFS=$'\t' read -r rel size sha <&4; do
      [ -n "$rel" ] || continue
      if _cs_fetch "$sid" "$rel" "$size" "$sha" "$sdir/$rel"; then
        printf 'ok\t%s\t%s\n' "$rel" "$size" >>"$out"
        drops=0
      else
        printf 'fail\t%s\t%s\t%s\n' "$CS_FCODE" "$rel" "$CS_FMSG" >>"$out"
        case "$CS_FCODE" in
          1 | 3 | 6) break ;;
          9)
            # One dropped stream: go on with the other files; two in a row: the network is down.
            drops=$((drops + 1))
            [ "$drops" -lt 2 ] || break
            ;;
        esac
      fi
    done 4<"$list"
  ) &
}

# --- one session ---------------------------------------------------------------------

CS_NEW=0
CS_UPD=0
CS_FILES=0
CS_BYTES=0
CS_FAILED_NOW=0
CS_INTEG=0
CS_SERVER_ERR=0
CS_ABORT=0
CS_ABORT_MSG=""
CS_VER_SESS=0
CS_VER_FILES=0
CS_DRY_SESS=0
CS_DRY_FILES=0
CS_DRY_BYTES=0

# _cs_abort CODE MESSAGE: stops the sync after the current step.
_cs_abort() {
  CS_ABORT="$1"
  CS_ABORT_MSG="$2"
}

# _cs_fail SESSION CODE MESSAGE ETAG RUN_ID RUN_KEY FOLDER: records a failed session with its next try.
_cs_fail() {
  local sid="$1" code="$2" msg="$3" now attempts wait
  now="$(now_s)"
  attempts="$(jq -r --arg s "$sid" '(.failures[$s].attempts // 0) + 1' "$CS_ST")"
  # shellcheck disable=SC2086
  wait="$(printf '%s\n' $CS_BACKOFF | sed -n "${attempts}p")"
  # shellcheck disable=SC2086
  [ -n "$wait" ] || wait="$(printf '%s\n' $CS_BACKOFF | tail -n1)"
  _cs_st '.failures[$s] = {attempts: $a, exit: $c, last_error: $m, at: $at, next_try_at: ($n | todateiso8601),
           export_etag: $e, run_id: $r, run_key: $k, folder: $f}' \
    --arg s "$sid" --argjson a "$attempts" --argjson c "$code" --arg m "$msg" --arg at "$(_cs_now_iso)" \
    --argjson n "$((now + wait))" --arg e "$4" --argjson r "${5:-null}" --arg k "$6" --arg f "$7"
  _cs_save
  CS_FAILED_NOW=$((CS_FAILED_NOW + 1))
  if [ "$code" = 11 ]; then CS_INTEG=$((CS_INTEG + 1)); else CS_SERVER_ERR=$((CS_SERVER_ERR + 1)); fi
  err "$CITT_CMD: session $sid${6:+ ($6/$7)}: $msg"
}

# _cs_session ROW: lists one session's files, downloads what is missing, writes the marker and
# the state. ROW is a feed row or a {session_id, src} row of a retry or a verify.
_cs_session() {
  local row="$1" sid feed_etag run_id run_key folder etag list files need res rel size sha
  sid="$(jq -r '.session_id' <<<"$row")"
  feed_etag="$(jq -r '.export_etag // empty' <<<"$row")"
  run_id="$(jq -r '.run_id // empty' <<<"$row")"
  [ -n "$run_id" ] || run_id="$(jq -r --arg s "$sid" '.sessions[$s].run_id // .failures[$s].run_id // empty' "$CS_ST")"
  list="$_CITT_TMP/files.$sid.json"
  http GET "$CITT_V1/capture-sessions/$sid/files?groups=$(urlenc "$CS_GROUPS")"
  cp "$RESP" "$list" 2>/dev/null
  case "$CODE" in
    2??) ;;
    401) fail_http ;;
    000)
      _cs_abort 9 "cannot reach $CITT_HOST ($NET_REASON)$(_retried_suffix)"
      return
      ;;
    429)
      _cs_abort 6 "the service refused the file list of session $sid (429); the next sync continues"
      return
      ;;
    403 | 404)
      _cs_fail "$sid" 8 "the session is no longer among your projects' captures ($CODE)" "$feed_etag" "$run_id" "" ""
      return
      ;;
    *)
      _cs_fail "$sid" 8 "the file list failed: server error $CODE$(_retried_suffix)" "$feed_etag" "$run_id" "" ""
      return
      ;;
  esac
  run_key="$(jq -r '.run_key // empty' "$list" 2>/dev/null)"
  folder="$(jq -r '.folder // empty' "$list" 2>/dev/null)"
  etag="$(jq -r '.export_etag // empty' "$list" 2>/dev/null)"
  if ! jq -e '.files | type == "array"' "$list" >/dev/null 2>&1; then
    _cs_fail "$sid" 8 "unparseable file list" "$feed_etag" "$run_id" "" ""
    return
  fi
  if ! _cs_segment "$run_key" || ! _cs_segment "$folder"; then
    _cs_fail "$sid" 11 "unsafe run key or session folder in the file list: $run_key/$folder" "$feed_etag" "$run_id" "" ""
    return
  fi
  # Every path: a safe relative path under a requested group, a size and a sha256.
  local bad
  bad="$(jq -r --arg g ",$CS_GROUPS," '.files[] | select(
      ((.path | type) != "string") or ((.size | type) != "number") or ((.sha256 | type) != "string")
      or (.sha256 | test("^[0-9a-f]{64}$") | not)
      or ((.path | split("/")[0]) as $grp | $g | contains("," + $grp + ",") | not)) | (.path | tostring)' "$list" | head -n1)"
  if [ -z "$bad" ]; then
    while IFS= read -r rel; do
      if _cs_unsafe "$rel" || [ "${rel#*/}" = "$rel" ]; then
        bad="$rel"
        break
      fi
      case "/$rel/" in */.citt-session.json/* | *.part/*) bad="$rel"; break ;; esac
    done < <(jq -r '.files[].path' "$list")
  fi
  if [ -n "$bad" ]; then
    _cs_fail "$sid" 11 "unsafe or malformed entry in the file list: $bad" "$etag" "$run_id" "$run_key" "$folder"
    printf '%s\t%s\n' "$run_id" "$run_key" >>"$_CITT_TMP/touched"
    return
  fi
  local sdir="$CS_DIR/$run_key/$folder"
  files="$(jq '.files | length' "$list")"
  # What is missing: files whose final copy is absent or differs.
  need="$_CITT_TMP/need.$sid"
  : >"$need"
  local missing=0 part_have
  while IFS=$'\t' read -r rel size sha; do
    if [ -f "$sdir/$rel" ] && [ "$(_cs_size "$sdir/$rel")" = "$size" ] && [ "$(sha256_of "$sdir/$rel")" = "$sha" ]; then
      continue
    fi
    printf '%s\t%s\t%s\n' "$rel" "$size" "$sha" >>"$need"
    part_have="$(_cs_size "$sdir/$rel.part")"
    [ "$part_have" -le "$size" ] || part_have=0
    missing=$((missing + size - part_have))
  done < <(jq -r '.files[] | [.path, (.size | tostring), .sha256] | @tsv' "$list")
  local nneed
  nneed="$(wc -l <"$need" | tr -d ' ')"
  [ "$CS_VERIFY" = 0 ] || {
    CS_VER_SESS=$((CS_VER_SESS + 1))
    CS_VER_FILES=$((CS_VER_FILES + files))
  }

  if [ "$CS_DRY" = 1 ]; then
    if [ "$nneed" -gt 0 ]; then
      printf '%s/%s (session %s): %s, %s\n' "$run_key" "$folder" "$sid" "$(_cs_n "$nneed" file files)" "$(_cs_bytes "$missing")"
      CS_DRY_SESS=$((CS_DRY_SESS + 1))
      CS_DRY_FILES=$((CS_DRY_FILES + nneed))
      CS_DRY_BYTES=$((CS_DRY_BYTES + missing))
    fi
    return
  fi

  # Free space: the missing bytes plus 10%.
  if [ "$missing" -gt 0 ]; then
    local avail want
    want=$((missing + missing / 10))
    avail="$(df -Pk "$CS_DIR" 2>/dev/null | awk 'NR == 2 { printf "%.0f", $4 * 1024 }')"
    if is_uint "$avail" && [ "$avail" -lt "$want" ]; then
      _cs_abort 1 "not enough free space in $CS_DIR: $avail bytes free, about $want bytes needed for session $sid ($(_cs_bytes "$avail") free, $(_cs_bytes "$want") needed); free space or choose another --dir"
      return
    fi
  fi
  printf '%s\t%s\n' "$run_id" "$run_key" >>"$_CITT_TMP/touched"

  # Downloads, the largest files first, spread over --parallel workers.
  res="$_CITT_TMP/res.$sid"
  : >"$res"
  if [ "$nneed" -gt 0 ]; then
    local i pids=""
    rm -f "$_CITT_TMP/list.$sid".*
    sort -t "$(printf '\t')" -k2,2nr "$need" | awk -v n="$CS_PARALLEL" -v base="$_CITT_TMP/list.$sid" '{ print > (base "." ((NR - 1) % n)) }'
    i=0
    while [ "$i" -lt "$CS_PARALLEL" ]; do
      if [ -s "$_CITT_TMP/list.$sid.$i" ]; then
        _cs_worker "$i" "$_CITT_TMP/list.$sid.$i" "$res" "$sid" "$sdir"
        pids="$pids $!"
      fi
      i=$((i + 1))
    done
    for i in $pids; do wait "$i" 2>/dev/null || true; done
  fi
  local okn okbytes worst="" msg=""
  okn="$(awk -F '\t' '$1 == "ok"' "$res" | wc -l | tr -d ' ')"
  okbytes="$(awk -F '\t' '$1 == "ok" { s += $3 } END { printf "%.0f", s + 0 }' "$res")"
  CS_FILES=$((CS_FILES + okn))
  CS_BYTES=$((CS_BYTES + okbytes))
  # The most serious failure decides: auth, disk, rate limit and network stop the sync.
  local c
  for c in 3 1 6 9 11 8; do
    msg="$(awk -F '\t' -v c="$c" '$1 == "fail" && $2 == c { print $4; exit }' "$res")"
    if [ -n "$msg" ]; then
      worst="$c"
      break
    fi
  done
  case "$worst" in
    3) fail_out 3 "$msg" ;;
    1 | 6 | 9)
      _cs_abort "$worst" "$msg"
      return
      ;;
    11 | 8)
      _cs_fail "$sid" "$worst" "$msg" "$etag" "$run_id" "$run_key" "$folder"
      return
      ;;
  esac
  if [ "$okn" -lt "$nneed" ]; then
    _cs_fail "$sid" 8 "$((nneed - okn)) of $nneed downloads ended without a result" "$etag" "$run_id" "$run_key" "$folder"
    return
  fi

  # Every file verified: files the server no longer lists stay on disk and are logged (D23).
  local marker="$sdir/.citt-session.json" now dropped
  now="$(_cs_now_iso)"
  mkdir -p "$sdir" || {
    _cs_abort 1 "cannot create $sdir"
    return
  }
  if [ -f "$marker" ]; then
    dropped="$(jq -r --slurpfile l "$list" '($l[0].files | map(.path)) as $now | .files[]?.path | select(. as $p | $now | index($p) | not)' "$marker" 2>/dev/null)"
    if [ -n "$dropped" ]; then
      printf '%s\n' "$dropped" | while IFS= read -r rel; do
        [ -e "$sdir/$rel" ] && printf '%s\t%s\n' "$sid" "$run_key/$folder/$rel" >>"$_CITT_TMP/dropped"
      done
    fi
  fi
  jq -c --arg at "$now" --arg g "$CS_GROUPS" \
    '{session_id, run_key, folder, export_etag, groups: $g, verified_at: $at, files: [.files[] | {path, size, sha256}]}' \
    "$list" >"$marker.tmp"
  if ! mv -f "$marker.tmp" "$marker"; then
    _cs_abort 1 "cannot write $marker"
    return
  fi
  local known prev_etag bytes
  known="$(jq -r --arg s "$sid" 'if .sessions[$s] then "1" else "0" end' "$CS_ST")"
  prev_etag="$(jq -r --arg s "$sid" '.sessions[$s].export_etag // empty' "$CS_ST")"
  bytes="$(jq '[.files[].size] | add // 0' "$list")"
  if [ "$known" = 0 ]; then
    CS_NEW=$((CS_NEW + 1))
  elif [ "$okn" -gt 0 ] || [ "$prev_etag" != "$etag" ]; then
    CS_UPD=$((CS_UPD + 1))
  fi
  _cs_st '.sessions[$s] = {export_etag: $e, run_id: $r, run_key: $k, folder: $f, groups: $g, files: $n, bytes: $b, verified_at: $at}
          | del(.failures[$s])' \
    --arg s "$sid" --arg e "$etag" --argjson r "${run_id:-null}" --arg k "$run_key" --arg f "$folder" --arg g "$CS_GROUPS" \
    --argjson n "$files" --argjson b "$bytes" --arg at "$now"
  _cs_save
  [ "${CITT_JSON:-0}" = 1 ] || [ "$nneed" = 0 ] \
    || printf 'Session %s: %s/%s, %s, %s\n' "$sid" "$run_key" "$folder" "$(_cs_n "$okn" file files)" "$(_cs_bytes "$okbytes")"
}

# --- run-level files -----------------------------------------------------------------

# _cs_run_get PATH DEST: one run-level file into DEST.tmp, renamed on success. Sets CS_RG to "ok",
# "same", "absent" (404), "net" (no response) or "err".
CS_RG=""
_cs_run_get() {
  local path="$1" dest="$2"
  HTTP_OUT="$dest.tmp"
  http GET "$path"
  case "$CODE" in
    2??)
      if [ -f "$dest" ] && cmp -s "$dest.tmp" "$dest"; then
        rm -f "$dest.tmp"
        CS_RG=same
      else
        mv -f "$dest.tmp" "$dest" && CS_RG=ok
      fi
      ;;
    404)
      rm -f "$dest.tmp"
      CS_RG=absent
      ;;
    401)
      rm -f "$dest.tmp"
      : >"$RESP"
      fail_out 3 "not signed in or the token expired; run: citt auth"
      ;;
    000)
      rm -f "$dest.tmp"
      CS_RG=net
      ;;
    *)
      rm -f "$dest.tmp"
      CS_RG=err
      ;;
  esac
}

# _cs_checksums RUNDIR: checksums.sha256 over the run-level files and every verified session file.
_cs_checksums() {
  local rd="$1" out="$1/checksums.sha256.tmp" f
  : >"$out"
  {
    for f in $CS_RUN_FILES; do
      [ -f "$rd/$f" ] && printf '%s  %s\n' "$(sha256_of "$rd/$f")" "$f"
    done
    if [ -d "$rd/schema" ]; then
      for f in "$rd"/schema/*.schema.json; do
        [ -f "$f" ] && printf '%s  schema/%s\n' "$(sha256_of "$f")" "$(basename "$f")"
      done
    fi
    for f in "$rd"/*/.citt-session.json; do
      [ -f "$f" ] || continue
      jq -r '.folder as $d | .files[] | "\(.sha256)  \($d)/\(.path)"' "$f" 2>/dev/null
    done
  } | sort -k2 >"$out"
  mv -f "$out" "$rd/checksums.sha256"
}

# _cs_run_files ID RUN_KEY RUN_ETAG: README.md, run.json, citations.jsonl, app.json and the schemas.
_cs_run_files() {
  local id="$1" rk="$2" etag="$3" rd n readme="" s errs=0
  _cs_segment "$rk" || {
    err "$CITT_CMD: run $id has an unsafe run key: $rk"
    CS_INTEG=$((CS_INTEG + 1))
    return
  }
  rd="$CS_DIR/$rk"
  mkdir -p "$rd" || {
    _cs_abort 1 "cannot create $rd"
    return
  }
  for n in $CS_RUN_FILES; do
    _cs_run_get "$CITT_V1/capture-runs/$id/export/$n?groups=$(urlenc "$CS_GROUPS")" "$rd/$n"
    case "$CS_RG" in
      ok) [ "$n" != README.md ] || readme=changed ;;
      same | absent) ;;
      net)
        _cs_abort 9 "cannot reach $CITT_HOST ($NET_REASON)$(_retried_suffix)"
        return
        ;;
      *)
        err "$CITT_CMD: run $rk: $n failed: server error $CODE$(_retried_suffix); the next sync fetches it again"
        errs=$((errs + 1))
        ;;
    esac
  done
  for s in $CS_SCHEMAS; do
    [ -n "$readme" ] || [ -f "$rd/schema/$s.schema.json" ] || readme=missing
  done
  if [ -n "$readme" ]; then
    mkdir -p "$rd/schema"
    for s in $CS_SCHEMAS; do
      _cs_run_get "$CITT_V1/capture-export/schema/$s.schema.json" "$rd/schema/$s.schema.json"
      case "$CS_RG" in
        ok | same | absent) ;;
        net)
          _cs_abort 9 "cannot reach $CITT_HOST ($NET_REASON)$(_retried_suffix)"
          return
          ;;
        *) errs=$((errs + 1)) ;;
      esac
    done
  fi
  _cs_checksums "$rd"
  if [ "$errs" -gt 0 ]; then
    CS_SERVER_ERR=$((CS_SERVER_ERR + 1))
    return
  fi
  _cs_st '.runs[$i] = {run_key: $k, run_etag: $e, fetched_at: $at}' \
    --arg i "$id" --arg k "$rk" --arg e "$etag" --arg at "$(_cs_now_iso)"
  _cs_save
}

# _cs_runs RESET: refreshes the run-level files of every run touched in this sync and of every
# local run whose run_etag moved in GET /capture-runs?changed_after=.
_cs_runs() {
  local after hw cursor="" all id rk etag want
  all="$(tmpfile runs.jsonl)"
  hw="$(jq -r '.runs_high_water // empty' "$CS_ST")"
  if [ "$1" = 0 ] && [ -n "$hw" ]; then
    after="$(_cs_minus_overlap "$hw")"
  else
    after="${CS_SINCE:-$CS_EPOCH}"
  fi
  while :; do
    if [ -n "$cursor" ]; then
      http GET "$CITT_V1/capture-runs?limit=200&cursor=$(urlenc "$cursor")&changed_after=$(urlenc "$after")$(_cs_pid_query)"
    else
      http GET "$CITT_V1/capture-runs?limit=200&changed_after=$(urlenc "$after")$(_cs_pid_query)"
    fi
    case "$CODE" in
      2??) ;;
      401) fail_http ;;
      000)
        _cs_abort 9 "cannot reach $CITT_HOST ($NET_REASON)$(_retried_suffix)"
        return
        ;;
      *)
        err "$CITT_CMD: the run list failed: HTTP $CODE; run files are refreshed on the next sync"
        CS_SERVER_ERR=$((CS_SERVER_ERR + 1))
        break
        ;;
    esac
    jq -c '.runs[] | {experiment_id, run_key, run_etag, changed_at}' "$RESP" >>"$all" 2>/dev/null
    cursor="$(body_field '.next_cursor')"
    [ -n "$cursor" ] || break
  done
  # Targets: touched runs, and local runs whose run_etag moved; only runs inside --run.
  want="$(tmpfile run_targets)"
  jq -r -n --slurpfile st "$CS_ST" --rawfile touched "$_CITT_TMP/touched" --arg rids "$CS_RIDS" '
    ($rids | split("\n") | map(select(. != ""))) as $only
    | ($touched | split("\n") | map(select(. != "") | split("\t") | {id: .[0], key: .[1]})) as $t
    | [inputs] as $listed
    | ($listed | map({key: (.experiment_id | tostring), value: .}) | from_entries) as $by
    | ( [$t[] | select(.id != "") | {id, key: ($by[.id].run_key // .key), etag: ($by[.id].run_etag // "")}]
      + [$listed[] | (.experiment_id | tostring) as $i | select($st[0].runs[$i] != null and $st[0].runs[$i].run_etag != .run_etag)
         | {id: $i, key: .run_key, etag: .run_etag}] )
    | unique_by(.id)[] | select(($only | length) == 0 or (.id as $i | $only | index($i)))
    | [.id, .key, .etag] | @tsv' "$all" >"$want" 2>/dev/null
  while IFS=$'\t' read -r id rk etag; do
    [ -n "$id" ] || continue
    _cs_run_files "$id" "$rk" "$etag"
    [ "$CS_ABORT" = 0 ] || return
  done <"$want"
  hw="$(jq -r -s --arg old "$hw" "$CS_JQ_TS"' (map(.changed_at) + [$old] | map(select(. != null and . != "")) | max_by(ts)) // empty' "$all")"
  [ -z "$hw" ] || _cs_st '.runs_high_water = $h' --arg h "$hw"
}

# --- the sync ------------------------------------------------------------------------

_cs_sync() {
  local start reset=0 old after hw feed todo cursor row n
  start="$(now_s)"
  : >"$_CITT_TMP/touched"
  : >"$_CITT_TMP/dropped"
  if [ "$CS_DRY" = 0 ]; then
    mkdir -p "$CS_META" 2>/dev/null || die 1 "cannot create $CS_META"
    chmod 700 "$CS_META" 2>/dev/null || true
    if ! _cs_lock; then
      printf 'another sync is running for %s; this one exits\n' "$CS_DIR"
      exit 0
    fi
  fi
  need_auth
  call GET "$CITT_V1/me"
  local account
  account="$(body_field '.email')"
  [ -n "$account" ] || die 1 "unparseable response from GET $CITT_V1/me"
  CS_ST=""
  _cs_state_load
  old="$(jq -r '.account // empty' "$CS_ST")"
  if [ -n "$old" ] && [ "$old" != "$account" ]; then
    die 2 "$CS_DIR holds the captures of $old, and the plugin is signed in as $account; sign in as $old (citt auth) or sync into another --dir"
  fi
  old="$(jq -r '.host // empty' "$CS_ST")"
  if [ -n "$old" ] && [ "$old" != "$CITT_HOST" ]; then
    die 2 "$CS_DIR holds captures from $old, not $CITT_HOST; sync into another --dir"
  fi
  E_KIND=project
  E_PROJECT_ID="$(printf '%s' "$CS_PROJECTS" | tr '\n' ' ' | sed 's/ *$//')"
  _cs_resolve_projects
  _cs_resolve_runs
  local filters
  filters="$(_cs_filters_json)"
  if [ "$(jq -c '.filters' "$CS_ST")" != "$filters" ]; then
    # New filters: list every session again; sessions already on disk are skipped by export_etag.
    [ "$(jq -c '.filters' "$CS_ST")" = null ] || reset=1
    _cs_st '.filters = $f | .high_water = (if $r == 1 then null else .high_water end) | .runs_high_water = (if $r == 1 then null else .runs_high_water end)' \
      --argjson f "$filters" --argjson r "$reset"
  fi
  _cs_st '.account = $a | .host = $h' --arg a "$account" --arg h "$CITT_HOST"
  _cs_save
  CS_FILTER_Q="$(_cs_pid_query)"
  for n in $CS_RIDS; do CS_FILTER_Q="$CS_FILTER_Q&run_id=$n"; done

  # The feed, from high_water minus the overlap.
  hw="$(jq -r '.high_water // empty' "$CS_ST")"
  if [ -n "$hw" ]; then after="$(_cs_minus_overlap "$hw")"; else after="${CS_SINCE:-$CS_EPOCH}"; fi
  feed="$(tmpfile feed.jsonl)"
  cursor=""
  E_KIND=project
  while :; do
    if [ -n "$cursor" ]; then
      call GET "$CITT_V1/capture-sessions?limit=200&cursor=$(urlenc "$cursor")$CS_FILTER_Q"
    else
      call GET "$CITT_V1/capture-sessions?changed_after=$(urlenc "$after")&limit=200$CS_FILTER_Q"
    fi
    jq -c '.sessions[]' "$RESP" >>"$feed" 2>/dev/null || die 1 "unparseable response from GET $CITT_V1/capture-sessions"
    cursor="$(body_field '.next_cursor')"
    [ -n "$cursor" ] || break
  done

  # What to process: feed rows, then due retries, then (with --verify) every session on disk.
  todo="$(tmpfile todo.jsonl)"
  jq -c -n --slurpfile st "$CS_ST" --argjson now "$(now_s)" --argjson verify "$CS_VERIFY" "$CS_JQ_TS"'
    [inputs] as $feed | ($feed | map(.session_id | tostring)) as $ids
    | ($feed | map(. + {src: "feed"}))
      + [($st[0].failures // {}) | to_entries[] | select(.key as $k | $ids | index($k) | not)
         | select((.value.next_try_at | ts) <= $now) | {session_id: (.key | tonumber), run_id: .value.run_id, src: "retry"}]
      + (if $verify == 1 then [($st[0].sessions // {}) | to_entries[] | select(.key as $k | $ids | index($k) | not)
         | {session_id: (.key | tonumber), run_id: .value.run_id, src: "verify"}] else [] end)
    | reduce .[] as $r ({seen: {}, out: []}; if .seen[$r.session_id | tostring] then . else .seen[$r.session_id | tostring] = true | .out += [$r] end)
    | .out[]' "$feed" >"$todo"

  local seen sid etag src skip pending=0 nowiso
  seen="$(tmpfile seen_at)"
  nowiso="$(now_s)"
  while IFS= read -r row <&3; do
    [ "$CS_ABORT" = 0 ] || break
    sid="$(jq -r '.session_id' <<<"$row")"
    etag="$(jq -r '.export_etag // empty' <<<"$row")"
    src="$(jq -r '.src' <<<"$row")"
    skip=0
    if [ "$src" = feed ] && [ "$CS_VERIFY" = 0 ]; then
      skip="$(jq -r --arg s "$sid" --arg e "$etag" --arg g "$CS_GROUPS" --argjson now "$nowiso" "$CS_JQ_TS"'
        if .sessions[$s].export_etag == $e and .sessions[$s].groups == $g and (.failures[$s] == null) then "done"
        elif .failures[$s] != null and .failures[$s].export_etag == $e and ((.failures[$s].next_try_at | ts) > $now) then "wait"
        else "0" end' "$CS_ST")"
      if [ "$skip" = "done" ]; then
        local folder rk
        rk="$(jq -r --arg s "$sid" '.sessions[$s].run_key' "$CS_ST")"
        folder="$(jq -r --arg s "$sid" '.sessions[$s].folder' "$CS_ST")"
        [ "$(jq -r '.export_etag // empty' "$CS_DIR/$rk/$folder/.citt-session.json" 2>/dev/null)" = "$etag" ] || skip=0
      fi
    fi
    case "$skip" in
      done | wait) ;;
      *) _cs_session "$row" ;;
    esac
    [ "$CS_ABORT" = 0 ] || break
    [ "$src" != feed ] || jq -r '.changed_at // empty' <<<"$row" >>"$seen"
  done 3<"$todo"

  if [ "$CS_DRY" = 1 ]; then
    printf 'Would download %s, %s, %s.\n' "$(_cs_n "$CS_DRY_SESS" session sessions)" "$(_cs_n "$CS_DRY_FILES" file files)" "$(_cs_bytes "$CS_DRY_BYTES")"
    return 0
  fi

  # high_water: the latest change processed in feed order.
  local newhw
  newhw="$(jq -R -r -s --arg old "$hw" "$CS_JQ_TS"' split("\n") + [$old] | map(select(. != "")) | (max_by(ts) // empty)' "$seen")"
  [ -z "$newhw" ] || _cs_st '.high_water = $h' --arg h "$newhw"
  _cs_save

  [ "$CS_ABORT" != 0 ] || _cs_runs "$reset"
  _cs_save

  # Summary, log line and exit code.
  local secs code=0 summary nfail
  secs=$(($(now_s) - start))
  nfail="$(jq '.failures | length' "$CS_ST")"
  if [ "$CS_ABORT" != 0 ]; then
    code="$CS_ABORT"
  elif [ "$CS_INTEG" -gt 0 ]; then
    code=11
  elif [ "$nfail" -gt 0 ] || [ "$CS_SERVER_ERR" -gt 0 ]; then
    code=8
  fi
  summary="$(_cs_n "$CS_NEW" "new session" "new sessions"), $CS_UPD updated, $(_cs_n "$CS_FILES" file files), $(_cs_bytes "$CS_BYTES") in $(_cs_dur "$secs"); $nfail failed"
  local errors dropped
  errors="$(jq -c '[.failures | to_entries[] | {session_id: (.key | tonumber), run_key: .value.run_key, folder: .value.folder,
    error: .value.last_error, exit: .value.exit, attempts: .value.attempts, next_try_at: .value.next_try_at}]' "$CS_ST")"
  dropped="$(jq -R -s -c 'split("\n") | map(select(. != "") | split("\t") | {session_id: (.[0] | tonumber), path: .[1]})' "$_CITT_TMP/dropped")"
  jq -nc --arg at "$(_cs_now_iso)" --argjson code "$code" --argjson new "$CS_NEW" --argjson upd "$CS_UPD" \
    --argjson files "$CS_FILES" --argjson bytes "$CS_BYTES" --argjson secs "$secs" --argjson failed "$nfail" \
    --arg hw "$(jq -r '.high_water // empty' "$CS_ST")" --arg summary "$summary" --arg abort "$CS_ABORT_MSG" \
    --argjson errors "$errors" --argjson dropped "$dropped" --argjson verify "$CS_VERIFY" \
    '{at: $at, exit: $code, new: $new, updated: $upd, files: $files, bytes: $bytes, seconds: $secs, failed: $failed,
      high_water: (if $hw == "" then null else $hw end), summary: $summary, error: (if $abort == "" then null else $abort end),
      verify: ($verify == 1), failures: $errors, kept_files: $dropped}' >>"$CS_META/log.jsonl"

  if [ "${CITT_JSON:-0}" = 1 ]; then
    tail -n1 "$CS_META/log.jsonl" | jq -c --arg d "$CS_DIR" '{schema: "citt.plugin.capture-sync/1", dir: $d} + .'
  else
    printf '%s\n' "$summary"
    if [ "$CS_VERIFY" = 1 ]; then
      printf 'Verified %s, %s; %s downloaded again.\n' "$(_cs_n "$CS_VER_SESS" session sessions)" "$(_cs_n "$CS_VER_FILES" file files)" "$(_cs_n "$CS_FILES" file files)"
    fi
    if [ -s "$_CITT_TMP/dropped" ]; then
      printf 'Kept %s that the server no longer lists (a re-ingest replaced them): %s\n' \
        "$(_cs_n "$(wc -l <"$_CITT_TMP/dropped" | tr -d ' ')" file files)" "$(cut -f2 "$_CITT_TMP/dropped" | paste -sd, - | sed 's/,/, /g')"
    fi
  fi
  if [ "$nfail" -gt 0 ]; then
    jq -r '.failures | to_entries[] | "session \(.key)\(if .value.run_key != "" and .value.run_key != null then " (\(.value.run_key)/\(.value.folder))" else "" end): \(.value.last_error); next try \(.value.next_try_at), attempt \(.value.attempts)"' "$CS_ST" \
      | while IFS= read -r n; do err "$CITT_CMD: $n"; done
    err "$CITT_CMD: failed sessions are tried again by the next sync after their wait; see: citt capture-sync --dir $(shq "$CS_DIR") --status"
  fi
  [ -z "$CS_ABORT_MSG" ] || err "$CITT_CMD: $CS_ABORT_MSG"
  exit "$code"
}

# --- status --------------------------------------------------------------------------

# _cs_timer_info: one JSON object describing the installed timer, or null.
_cs_timer_info() {
  local meta="$CS_META/timer.json" kind name state="" copy_v plugin_v
  [ -s "$meta" ] || {
    printf 'null'
    return
  }
  kind="$(jq -r '.kind' "$meta")"
  name="$(jq -r '.name' "$meta")"
  case "$kind" in
    systemd)
      state="$(systemctl --user is-active "$name" 2>/dev/null | head -n1)"
      ;;
    launchd)
      if launchctl print "gui/$(id -u)/$name" >/dev/null 2>&1; then state=loaded; else state="not loaded"; fi
      ;;
  esac
  copy_v="$(tr -d '\n' <"$CITT_STATE/sync/bin/VERSION" 2>/dev/null)"
  plugin_v="$(_cs_version)"
  jq -c --arg s "${state:-unknown}" --arg cv "${copy_v:-missing}" --arg pv "$plugin_v" '. + {state: $s, copy_version: $cv, plugin_version: $pv}' "$meta"
}

_cs_status() {
  local st="$CS_META/state.json" log="$CS_META/log.jsonl" timer last
  timer="$(_cs_timer_info)"
  if [ ! -s "$st" ]; then
    if [ "${CITT_JSON:-0}" = 1 ]; then
      jq -nc --arg d "$CS_DIR" --argjson t "$timer" '{schema: "citt.plugin.capture-sync-status/1", dir: $d, synced: false, timer: $t}'
    else
      printf 'No sync has run in %s yet; start one: citt capture-sync --dir %s\n' "$CS_DIR" "$(shq "$CS_DIR")"
      [ "$timer" = null ] || _cs_timer_line "$timer"
    fi
    return 0
  fi
  last="null"
  [ ! -s "$log" ] || last="$(tail -n1 "$log")"
  if [ "${CITT_JSON:-0}" = 1 ]; then
    jq -c --arg d "$CS_DIR" --argjson last "$last" --argjson t "$timer" \
      '{schema: "citt.plugin.capture-sync-status/1", dir: $d, synced: true, account, host, filters, high_water,
        sessions: (.sessions | length), runs: ([.sessions[].run_key] | unique | length), bytes: ([.sessions[].bytes] | add // 0),
        failures: [.failures | to_entries[] | {session_id: (.key | tonumber)} + .value], last_run: $last, timer: $t}' "$st"
    return 0
  fi
  printf 'Folder: %s\n' "$CS_DIR"
  jq -r '"Account: \(.account // "-")"' "$st"
  if [ "$last" != null ]; then
    jq -r '"Last run: \(.at | fromdateiso8601 | strftime("%Y-%m-%d %H:%M UTC")), exit \(.exit): \(.summary)"
      + (if .error then "\nLast error: \(.error)" else "" end)' <<<"$last"
  fi
  local bytes
  bytes="$(jq '[.sessions[].bytes] | add // 0' "$st")"
  jq -r --arg b "$(_cs_bytes "$bytes")" '(.sessions | length) as $n | ([.sessions[].run_key] | unique | length) as $r
    | "Downloaded: \($n) session\(if $n == 1 then "" else "s" end) of \($r) run\(if $r == 1 then "" else "s" end), \($b)"' "$st"
  jq -r '"Changes seen up to: \(.high_water // "none yet")"' "$st"
  jq -r '(.failures | length) as $n | if $n == 0 then "Failures: none" else "Failures: \($n)",
    (.failures | to_entries[] | "  session \(.key)\(if (.value.run_key // "") != "" then " (\(.value.run_key)/\(.value.folder))" else "" end): \(.value.last_error); next try \(.value.next_try_at), attempt \(.value.attempts)") end' "$st"
  _cs_timer_line "$timer"
}

# _cs_timer_line TIMER_JSON: the "Timer:" line of --status.
_cs_timer_line() {
  local timer="$1"
  if [ "$timer" = null ]; then
    printf 'Timer: not installed; install one: citt capture-sync --dir %s --install-timer\n' "$(shq "$CS_DIR")"
  else
    jq -r --arg every "$(_cs_dur "$(jq -r '.every_s' <<<"$timer")")" '
      "Timer: " + (if .kind == "systemd" then "systemd user timer \(.name), every \($every), \(.state)"
        elif .kind == "launchd" then "launchd agent \(.name), every \($every), \(.state)"
        else "crontab line printed \(.installed_at), every \($every) (check: crontab -l)" end)
      + "; script copy \(.copy_version), plugin \(.plugin_version)"
      + (if .copy_version != .plugin_version then "; refresh the copy: citt capture-sync --dir \(.dir) --install-timer" else "" end)' <<<"$timer"
  fi
}

# --- timers --------------------------------------------------------------------------

CS_COPY=""

# _cs_copy: scripts/citt and scripts/lib/ copied to $CITT_STATE/sync/bin, the folder a timer runs.
# A plugin update moves the plugin's folder; the copy stays until --install-timer refreshes it.
_cs_copy() {
  local base="$CITT_STATE/sync" new
  new="$base/bin.new.$$"
  mkdir -p "$new/lib" 2>/dev/null || die 1 "cannot create $base"
  if ! { cp "$CITT_LIB/../citt" "$new/citt" && cp "$CITT_LIB"/*.sh "$new/lib/"; }; then
    rm -rf "$new"
    die 1 "cannot copy the script to $base/bin"
  fi
  _cs_version >"$new/VERSION"
  chmod 755 "$new/citt"
  rm -rf "$base/bin.old"
  [ ! -d "$base/bin" ] || mv "$base/bin" "$base/bin.old"
  mv "$new" "$base/bin" || die 1 "cannot write $base/bin"
  rm -rf "$base/bin.old"
  CS_COPY="$base/bin/citt"
}

# _cs_env: KEY=VALUE lines the timer needs: PATH to curl and jq, the token store, and the test host.
_cs_env() {
  local t d path=""
  for t in curl jq flock sha256sum shasum df; do
    d="$(command -v "$t" 2>/dev/null)" || continue
    d="$(dirname "$d")"
    case ":$path:" in *":$d:"*) ;; *) path="$path${path:+:}$d" ;; esac
  done
  for d in /usr/bin /bin /usr/sbin /sbin; do
    case ":$path:" in *":$d:"*) ;; *) path="$path:$d" ;; esac
  done
  printf 'PATH=%s\n' "$path"
  [ -z "${CITT_STATE_DIR:-}" ] || printf 'CITT_STATE_DIR=%s\n' "$CITT_STATE_DIR"
  if [ "$CITT_OVERRIDDEN" = 1 ]; then
    printf 'CITT_TEST_MODE=1\nCITT_API_OVERRIDE=%s\n' "$CITT_HOST"
  fi
}

# _cs_sdq WORD: a systemd-quoted word (backslash, quote, % and $ escaped).
_cs_sdq() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g' -e 's/\$/$$/g')"
}

# _cs_sdword WORD: WORD as is when plain, else systemd-quoted.
_cs_sdword() {
  case "$1" in
    '' | *[!A-Za-z0-9._:@,+=-]*) _cs_sdq "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

_cs_xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

_cs_hash() { _cs_str_sha "$CS_DIR" | cut -c1-12; }

# _cs_preflight KIND: runs `citt usage` the way the timer will run the sync; stops with its reason.
_cs_preflight() {
  local out err_f rc kv
  out="$(tmpfile preflight.out)"
  err_f="$(tmpfile preflight.err)"
  local -a setenv
  setenv=()
  while IFS= read -r kv; do
    [ -z "$kv" ] || setenv+=("$kv")
  done < <(_cs_env)
  if [ "$1" = systemd ]; then
    local -a sargs
    sargs=()
    for kv in "${setenv[@]}"; do sargs+=("--setenv=$kv"); done
    systemd-run --user --wait --pipe --quiet --collect "${sargs[@]}" "$CS_COPY" usage </dev/null >"$out" 2>"$err_f"
    rc=$?
  else
    launchctl asuser "$(id -u)" env "${setenv[@]}" "$CS_COPY" usage </dev/null >"$out" 2>"$err_f"
    rc=$?
  fi
  [ "$rc" -eq 0 ] && return 0
  local reason
  reason="$(grep -m1 '^citt ' "$err_f" | sed 's/^citt [a-z-]*: //')"
  [ -n "$reason" ] || reason="$(head -n1 "$err_f")"
  err "$CITT_CMD: the timer's environment cannot use the plugin's sign-in: ${reason:-exit $rc}"
  err "$CITT_CMD: the timer reads the token from the keyring or $CITT_TOKEN_FILE; a keyring locked outside a login session is the common cause. Nothing was installed. On a host without a desktop session, sign in with citt auth --file (the token goes to $CITT_TOKEN_FILE only, read before the keyring) and install again; or keep a terminal open with: citt capture-sync --dir $(shq "$CS_DIR") --watch"
  case "$rc" in 3 | 9) exit "$rc" ;; *) exit 1 ;; esac
}

_cs_write_timer_meta() {
  jq -nc --arg k "$1" --arg n "$2" --arg u "$3" --argjson e "$CS_EVERY" --arg d "$CS_DIR" --arg at "$(_cs_now_iso)" --arg v "$(_cs_version)" \
    '{kind: $k, name: $n, unit: $u, every_s: $e, dir: $d, installed_at: $at, version: $v}' >"$CS_META/timer.json"
}

_cs_install() {
  local os name h
  os="$(uname -s)"
  h="$(_cs_hash)"
  case "$os" in
    Linux)
      { command -v systemctl >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1; } \
        || die 1 "systemd is not available here; print a crontab line instead: citt capture-sync --dir $(shq "$CS_DIR") --print-cron"
      ;;
    Darwin)
      command -v launchctl >/dev/null 2>&1 || die 1 "launchctl is not available; print a crontab line instead: citt capture-sync --dir $(shq "$CS_DIR") --print-cron"
      ;;
    *) die 1 "timers are installed on Linux (systemd) and macOS (launchd); print a crontab line instead: citt capture-sync --dir $(shq "$CS_DIR") --print-cron" ;;
  esac
  mkdir -p "$CS_META" 2>/dev/null || die 1 "cannot create $CS_META"
  chmod 700 "$CS_META" 2>/dev/null || true
  _cs_copy
  local args=() a
  while IFS= read -r a; do args+=("$a"); done < <(_cs_args)
  if [ "$os" = Linux ]; then
    _cs_preflight systemd
    local udir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" execline kv
    name="citt-capture-sync-$h"
    mkdir -p "$udir" || die 1 "cannot create $udir"
    execline="ExecStart=$(_cs_sdq "$CS_COPY") capture-sync"
    for a in "${args[@]}"; do
      if [ "$a" = "$CS_DIR" ]; then execline="$execline $(_cs_sdq "$a")"; else execline="$execline $(_cs_sdword "$a")"; fi
    done
    {
      printf '[Unit]\nDescription=citt capture sync into %s\n\n[Service]\nType=oneshot\n' "$(printf '%s' "$CS_DIR" | sed 's/%/%%/g')"
      while IFS= read -r kv; do printf 'Environment=%s\n' "$(_cs_sdq "$kv")"; done < <(_cs_env)
      printf '%s\nNice=10\n' "$execline"
    } >"$udir/$name.service" || die 1 "cannot write $udir/$name.service"
    printf '[Unit]\nDescription=citt capture sync every %s into %s\n\n[Timer]\nOnActiveSec=60\nOnBootSec=300\nOnUnitActiveSec=%s\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' \
      "$(_cs_dur "$CS_EVERY")" "$(printf '%s' "$CS_DIR" | sed 's/%/%%/g')" "$CS_EVERY" >"$udir/$name.timer" || die 1 "cannot write $udir/$name.timer"
    systemctl --user daemon-reload || die 1 "systemctl --user daemon-reload failed"
    systemctl --user enable --now "$name.timer" || die 1 "systemctl --user enable --now $name.timer failed"
    _cs_write_timer_meta systemd "$name.timer" "$udir/$name.timer"
    printf 'Installed the systemd user timer %s: citt capture-sync runs every %s into %s.\n' "$name.timer" "$(_cs_dur "$CS_EVERY")" "$CS_DIR"
    printf 'It runs the copy at %s and reads the sign-in token where the plugin stores it; no token is in the units.\n' "$CS_COPY"
    printf 'To keep it running while you are logged out, run once: loginctl enable-linger %s\n' "${USER:-\$USER}"
  else
    _cs_preflight launchd
    local adir="$HOME/Library/LaunchAgents" plist kv
    name="com.canitrustthat.citt.capture-sync.$h"
    plist="$adir/$name.plist"
    mkdir -p "$adir" || die 1 "cannot create $adir"
    {
      printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      printf '<plist version="1.0">\n<dict>\n  <key>Label</key>\n  <string>%s</string>\n  <key>ProgramArguments</key>\n  <array>\n' "$name"
      printf '    <string>%s</string>\n    <string>capture-sync</string>\n' "$(_cs_xml "$CS_COPY")"
      for a in "${args[@]}"; do printf '    <string>%s</string>\n' "$(_cs_xml "$a")"; done
      printf '  </array>\n  <key>EnvironmentVariables</key>\n  <dict>\n'
      while IFS= read -r kv; do
        printf '    <key>%s</key>\n    <string>%s</string>\n' "${kv%%=*}" "$(_cs_xml "${kv#*=}")"
      done < <(_cs_env)
      printf '  </dict>\n  <key>StartInterval</key>\n  <integer>%s</integer>\n  <key>RunAtLoad</key>\n  <true/>\n' "$CS_EVERY"
      printf '  <key>ProcessType</key>\n  <string>Background</string>\n'
      printf '  <key>StandardOutPath</key>\n  <string>%s</string>\n  <key>StandardErrorPath</key>\n  <string>%s</string>\n' \
        "$(_cs_xml "$CS_META/launchd.log")" "$(_cs_xml "$CS_META/launchd.log")"
      printf '</dict>\n</plist>\n'
    } >"$plist" || die 1 "cannot write $plist"
    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$plist" || die 1 "launchctl bootstrap gui/$(id -u) $plist failed"
    _cs_write_timer_meta launchd "$name" "$plist"
    printf 'Installed the launchd agent %s: citt capture-sync runs every %s into %s.\n' "$name" "$(_cs_dur "$CS_EVERY")" "$CS_DIR"
    printf 'It runs the copy at %s and reads the sign-in token from the login keychain; no token is in the agent.\n' "$CS_COPY"
  fi
  printf 'After a plugin update, run the same --install-timer again to refresh the copy. Status: citt capture-sync --dir %s --status\n' "$(shq "$CS_DIR")"
}

_cs_uninstall() {
  local h udir name plist removed=0
  h="$(_cs_hash)"
  udir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  name="citt-capture-sync-$h"
  if [ -f "$udir/$name.timer" ] || [ -f "$udir/$name.service" ]; then
    systemctl --user disable --now "$name.timer" >/dev/null 2>&1 || true
    rm -f "$udir/$name.timer" "$udir/$name.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    printf 'Removed the systemd user timer %s.\n' "$name.timer"
    removed=1
  fi
  plist="$HOME/Library/LaunchAgents/com.canitrustthat.citt.capture-sync.$h.plist"
  if [ -f "$plist" ]; then
    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
    printf 'Removed the launchd agent %s.\n' "$(basename "$plist" .plist)"
    removed=1
  fi
  rm -f "$CS_META/timer.json"
  [ "$removed" = 1 ] || printf 'No timer is installed for %s.\n' "$CS_DIR"
  return 0
}

_cs_cron() {
  local m when line a kv
  m=$((CS_EVERY / 60))
  if [ $((CS_EVERY % 60)) -ne 0 ]; then
    usage_error "cron runs in whole minutes; give --every in minutes or hours"
  elif [ "$m" -lt 60 ]; then
    when="*/$m * * * *"
  elif [ $((m % 60)) -eq 0 ] && [ $((m / 60)) -lt 24 ]; then
    when="0 */$((m / 60)) * * *"
  else
    usage_error "--print-cron takes 5 to 59 minutes or 1 to 23 hours"
  fi
  mkdir -p "$CS_META" 2>/dev/null || die 1 "cannot create $CS_META"
  _cs_copy
  line="$when"
  while IFS= read -r kv; do line="$line ${kv%%=*}=$(shq "${kv#*=}")"; done < <(_cs_env)
  line="$line $(shq "$CS_COPY") capture-sync"
  while IFS= read -r a; do line="$line $(shq "$a")"; done < <(_cs_args)
  line="$line >>$(shq "$CS_META/cron.log") 2>&1"
  _cs_write_timer_meta cron crontab ""
  # cron reads % as a newline.
  printf '%s\n' "$line" | sed 's/%/\\%/g'
}

_cs_watch() {
  local rc ticks=0 a
  local -a args
  args=()
  while IFS= read -r a; do args+=("$a"); done < <(_cs_args)
  [ "${CITT_JSON:-0}" = 0 ] || args+=(--json)
  while :; do
    "$CITT_LIB/../citt" capture-sync "${args[@]}"
    rc=$?
    case "$rc" in 2 | 3) exit "$rc" ;; esac
    ticks=$((ticks + 1))
    if [ "${CITT_TEST_MODE:-}" = 1 ] && is_uint "${CITT_SYNC_WATCH_TICKS:-}" && [ "$ticks" -ge "$CITT_SYNC_WATCH_TICKS" ]; then
      exit "$rc"
    fi
    [ "${CITT_JSON:-0}" = 1 ] || printf 'Next sync in %s (Ctrl-C stops).\n' "$(_cs_dur "$CS_EVERY")"
    poll_sleep "$CS_EVERY"
  done
}

# --- citt captures -------------------------------------------------------------------

cmd_captures() {
  local state="" limit=50 cursor=""
  CITT_CMD="citt captures"
  while [ $# -gt 0 ]; do
    case "$1" in
      --state)
        need_value "$1" $#
        state="$2"
        shift
        ;;
      --project)
        need_value "$1" $#
        CS_PROJECTS="$CS_PROJECTS$2"$'\n'
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
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_captures
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  if ! is_uint "$limit" || [ "$limit" -lt 1 ] || [ "$limit" -gt 200 ]; then usage_error "--limit takes 1 to 200"; fi
  need_auth
  E_KIND=project
  E_PROJECT_ID="$(printf '%s' "$CS_PROJECTS" | tr '\n' ' ' | sed 's/ *$//')"
  _cs_resolve_projects
  call GET "$CITT_V1/capture-runs$(query state "$state" limit "$limit" cursor "$cursor")$(_cs_pid_query)"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  local n
  n="$(jq '.runs | length' "$RESP" 2>/dev/null)" || die 1 "unparseable response from GET $CITT_V1/capture-runs"
  if [ "$n" = 0 ]; then
    if [ -n "$state" ] || [ -n "$CS_PIDS" ]; then
      printf 'No capture runs match these filters; all runs: citt captures\n'
    else
      printf 'No capture runs in your projects yet. A capture starts from an Android app'"'"'s Network section on %s\n' "$CITT_APP_HOST"
    fi
    return 0
  fi
  jq -c "$CS_JQ_TS"' [["Run", "Key", "State", "App", "Phone", "Sessions", "Flags", "ETA"]]
    + [.runs[] | [.experiment_id, .run_key,
        (.state // "-") + (if .status_reason then ": " + .status_reason else "" end),
        (.app_label // .package_id),
        (.device_name // "-"),
        (if .planned_sessions then "\(.finished_sessions // 0)/\(.planned_sessions)" else "\(.finished_sessions // .sessions // 0)" end)
          + (if (.failed_sessions // 0) > 0 then ", \(.failed_sessions) failed" else "" end),
        (.flags // 0),
        (if .eta_at then (.eta_at | ts | floor | strftime("%Y-%m-%d %H:%M UTC"))
         elif .overdue_s then "overdue \((.overdue_s / 3600) | floor) h \(((.overdue_s % 3600) / 60) | floor) min"
         else "-" end)]]' "$RESP" | table
  local next
  next="$(body_field '.next_cursor')"
  [ -z "$next" ] || printf '\nMore runs: citt captures%s%s --cursor %s\n' "${state:+ --state $(shq "$state")}" "$( [ "$limit" = 50 ] || printf ' --limit %s' "$limit")" "$(shq "$next")"
}
