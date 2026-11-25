#!/usr/bin/env bash
# lib/cmd-code-file.sh: citt code-file (TASK-1506, epic TASK-1500 "Phase 2 contract"). The lines of one file of an
# indexed app build: POST /api/research/v1/atlas/code/file (TASK-1505) with {package, path, build_id?, corpus?,
# lines?: [first, last]}. The answer is printed as numbered lines and a footer of labelled lines (file, complete,
# next); a truncated answer prints the command of the range that follows, and so does a --lines range that ends
# before the last line of the file (TASK-1508: complete: yes (the requested lines)). The refusals are those of code_call in
# lib/cmd-atlas-code.sh (the code_search entitlement, the limits on searches at once, a service without the file
# read), and the 404 code_file_not_found, which prints its reason and the way to list the paths of an app.
# shellcheck shell=bash disable=SC2034,SC2016,SC2015,SC2153

# The most requests of one --out walk over a truncated file.
CF_MAX_REQUESTS=400

# _cf_cmd FIRST LAST BUILD CORPUS: the command that reads the lines FIRST to LAST of the same file of BUILD. Under
# --out FILE its file is FILE.next, so the lines written stay.
_cf_cmd() {
  local o="--lines $1-$2"
  [ -z "$3" ] || o="$o --build-id $3"
  [ -z "$4" ] || o="$o --corpus $4"
  [ -z "$CF_OUT" ] || o="$o --out $(shq "$CF_OUT.next")"
  [ "$CITT_JSON" != 1 ] || o="$o --json"
  case "$CF_PACKAGE$CF_PATH" in
    -*) printf '%s %s -- %s %s' "$CITT_CMD" "$o" "$(shq "$CF_PACKAGE")" "$(shq "$CF_PATH")" ;;
    *)
      case "$CF_PATH" in
        -*) printf '%s %s -- %s %s' "$CITT_CMD" "$o" "$(shq "$CF_PACKAGE")" "$(shq "$CF_PATH")" ;;
        *) printf '%s %s %s %s' "$CITT_CMD" "$(shq "$CF_PACKAGE")" "$(shq "$CF_PATH")" "$o" ;;
      esac
      ;;
  esac
}

# _cf_not_found: the 404 code_file_not_found (called by code_call): the reason and the way to list the paths; exit 4.
_cf_not_found() {
  local msg
  msg="$(plain_message "$(body_field '.message')")"
  msg="${msg%.}"
  err "$CITT_CMD: ${msg:-no build of $CF_PACKAGE in the code index has a file at this path}"
  err "next: run citt code-search QUERY --package $(shq "$CF_PACKAGE") to list the paths of its matching files, then pass a path as printed there"
  [ "$CITT_JSON" != 1 ] || { cat "$RESP"; printf '\n'; }
  exit 4
}

# _cf_read FILE: sets the F_* variables from the file answer in FILE.
_cf_read() {
  local sh
  sh="$(jq -r 'select((.lines | type) == "array")
    | @sh "F_BUILD=\(.build_id // "") F_CORPUS=\(.corpus // "") F_PATH=\(.path // "") F_FIRST=\(.first_line // 1) F_N=\(.lines | length) F_TOTAL=\(.total_lines // "") F_TRUNC=\(.truncated == true) F_NEXT=\(.next_line // "") F_CUT=\(.line_cut == true) F_OTHERS=\((.other_builds // []) | length)"' "$1" 2>/dev/null)" \
    || die 1 "unexpected response from the server"
  [ -n "$sh" ] || die 1 "unexpected response from the server"
  eval "$sh"
  is_uint "$F_FIRST" || die 1 "unexpected response from the server"
  [ -z "$F_NEXT" ] || is_uint "$F_NEXT" || F_NEXT=""
  case "$F_BUILD" in *[!0-9a-f]*) F_BUILD="" ;; esac
  case " $CODE_CORPORA " in *" $F_CORPUS "*) ;; *) F_CORPUS="" ;; esac
}

cmd_code_file() {
  local opts=1 lines="" build="" corpus="" out="" first="" last="" npos=0
  CF_PACKAGE=""
  CF_PATH=""
  CF_OUT=""
  while [ $# -gt 0 ]; do
    if [ "$opts" = 1 ]; then
      case "$1" in
        --)
          opts=0
          shift
          continue
          ;;
        --lines)
          _code_value "$1" $# "${2:-}"
          lines="$2"
          shift 2
          continue
          ;;
        --build-id)
          _code_value "$1" $# "${2:-}"
          build="$2"
          shift 2
          continue
          ;;
        --corpus)
          _code_value "$1" $# "${2:-}"
          case " $CODE_CORPORA " in
            *" $2 "*) ;;
            *) usage_error "--corpus must be one of: $CODE_CORPORA" ;;
          esac
          corpus="$2"
          shift 2
          continue
          ;;
        --out)
          _code_value "$1" $# "${2:-}"
          out="$2"
          shift 2
          continue
          ;;
        --json)
          CITT_JSON=1
          shift
          continue
          ;;
        --help | -h)
          help_code_file
          exit 0
          ;;
        -*) usage_error "unknown option $1 (a PATH that starts with - goes after --)" ;;
      esac
    fi
    npos=$((npos + 1))
    case "$npos" in
      1) CF_PACKAGE="$1" ;;
      2) CF_PATH="$1" ;;
      *) usage_error "give PACKAGE and PATH only (quote a path with spaces)" ;;
    esac
    shift
  done
  [ -n "$CF_PACKAGE" ] && [ -n "$CF_PATH" ] || usage_error "give the PACKAGE and the PATH of the file, as printed by citt code-search"
  if [ -n "$lines" ]; then
    case "$lines" in
      *[!0-9-]* | -* | *- | *-*-*) usage_error "--lines needs A-B, the first and the last line (1 or more, A not above B)" ;;
      *-*) ;;
      *) usage_error "--lines needs A-B, the first and the last line (1 or more, A not above B)" ;;
    esac
    first="${lines%-*}"
    last="${lines#*-}"
    [ "${#first}" -le 9 ] && [ "${#last}" -le 9 ] || usage_error "--lines needs A-B, the first and the last line (1 or more, A not above B)"
    first="$((10#$first))"
    last="$((10#$last))"
    [ "$first" -ge 1 ] && [ "$first" -le "$last" ] || usage_error "--lines needs A-B, the first and the last line (1 or more, A not above B)"
  fi
  if [ -n "$build" ]; then
    case "$build" in *[!0-9a-f]*) usage_error "--build-id needs the 64-character build id of a code-search row" ;; esac
    [ "${#build}" = 64 ] || usage_error "--build-id needs the 64-character build id of a code-search row"
  fi
  [ -z "$out" ] || [ "$CITT_JSON" = 0 ] || usage_error "use --out FILE or --json, not both"
  CF_OUT="$out"
  # --out: a target that cannot be written is refused before any request; an existing file keeps its content until
  # the lines are written.
  if [ -n "$out" ]; then
    if [ -e "$out" ]; then
      [ -f "$out" ] && [ -w "$out" ] || _code_out_fail "$out"
    else
      local d
      d="$(dirname -- "$out")"
      [ -d "$d" ] && [ -w "$d" ] || _code_out_fail "$out"
    fi
  fi
  need_auth

  local body text requests=0 rfirst="$first" rbuild="$build" rcorpus="$corpus" shown_first="" shown_n=0 others=""
  local refused=0 refused_from="" cut_seen=0 fresh="" note="" span
  body="$(tmpfile code_file_body)"
  text="$(tmpfile code_file_text)"
  while :; do
    jq -nc --arg p "$CF_PACKAGE" --arg f "$CF_PATH" --arg b "$rbuild" --arg c "$rcorpus" --arg a "$rfirst" --arg z "$last" \
      '{package:$p, path:$f}
       + (if $b != "" then {build_id:$b} else {} end)
       + (if $c != "" then {corpus:$c} else {} end)
       + (if $a != "" then {lines:[($a|tonumber), ($z|tonumber)]} else {} end)' >"$body"
    if [ "$requests" = 0 ]; then
      code_call POST "$CITT_ATLAS_CODE_BASE/file" "$body"
    else
      # A later range of --out that is refused: the lines fetched are written; the refusal lines are on stderr.
      (code_call POST "$CITT_ATLAS_CODE_BASE/file" "$body") >/dev/null || refused=$?
      if [ "$refused" != 0 ]; then
        refused_from="$rfirst"
        break
      fi
    fi
    requests=$((requests + 1))
    if [ "$CITT_JSON" = 1 ]; then
      cat "$RESP"
      printf '\n'
    fi
    _cf_read "$RESP"
    [ -n "$shown_first" ] || shown_first="$F_FIRST"
    if [ "$requests" = 1 ]; then
      fresh="$(jq -r '(.refs_refreshed_at | strings) // empty' "$RESP")"
      others="$(jq -r '(.other_builds // []) | if length == 0 then empty else
        "other builds with this file: \(length) (the latest was read; --build-id ID reads another): "
        + ([.[0:5][] | (.build_id // "-") + (if .version_code != null then " (version \(.version_code))" else "" end)] | join(", "))
        + (if length > 5 then ", ..." else "" end) end' "$RESP")"
    fi
    shown_n=$((shown_n + F_N))
    [ "$F_CUT" != true ] || cut_seen=1
    if [ -n "$out" ]; then
      jq -r '.lines[]' "$RESP" >>"$text"
    elif [ "$CITT_JSON" != 1 ]; then
      jq -r '(.first_line // 1) as $a | ((.first_line // 1) + (.lines | length) - 1 | tostring | length) as $w
        | .lines | to_entries[]
        | (($a + .key) | tostring) as $n | (" " * ($w - ($n | length))) + $n + "  " + .value' "$RESP"
    fi
    # --out follows a truncated answer: the range after it, of the same build.
    [ -n "$out" ] && [ "$F_TRUNC" = true ] && [ -n "$F_NEXT" ] && [ "$F_N" -gt 0 ] && [ "$requests" -lt "$CF_MAX_REQUESTS" ] || break
    rfirst="$F_NEXT"
    [ -n "$last" ] || last="$F_TOTAL"
    is_uint "$last" && [ "$rfirst" -le "$last" ] || break
    [ -z "$F_BUILD" ] || rbuild="$F_BUILD"
    [ -z "$F_CORPUS" ] || rcorpus="$F_CORPUS"
    err "$CITT_CMD: $shown_n lines fetched"
  done

  # The verdict: complete, or cut with the command of the following range.
  local complete=yes reason="" next="" rc=0 end to
  if [ "$refused" != 0 ]; then
    complete=no
    reason="a request was refused after $shown_n lines"
    next="$(_cf_cmd "$refused_from" "$last" "$rbuild" "$rcorpus")"
    rc="$refused"
  elif [ "$F_TRUNC" = true ]; then
    complete=no
    if [ "$F_CUT" = true ]; then
      reason="a line above the size limit of one request was cut; the rest of that line is not available"
    else
      reason="the answer was cut at the size limit of one request"
    fi
    to="$last"
    [ -n "$to" ] || to="$F_TOTAL"
    # An answer with no line and the same range again would repeat: no command then.
    if [ -n "$F_NEXT" ] && [ "$F_N" -gt 0 ] && is_uint "$to" && [ "$F_NEXT" -le "$to" ]; then
      next="$(_cf_cmd "$F_NEXT" "$to" "$F_BUILD" "$F_CORPUS")"
    else
      rc=12
    fi
  elif [ "$cut_seen" = 1 ]; then
    # --out followed the ranges to the end, and one of the lines written was cut.
    complete=no
    reason="a line above the size limit of one request was cut; the rest of that line is not available"
    rc=12
  fi
  if [ "$CITT_JSON" = 1 ]; then
    if [ "$rc" != 0 ]; then err "$CITT_CMD: the answer is incomplete: $reason"; fi
    return "$rc"
  fi
  # TASK-1508: --lines A-B that is a part of the file. complete: yes is then about the requested lines, and the
  # command of the following range (the same number of lines, cut at the last line of the file) is the next: line.
  end=$((shown_first + shown_n - 1))
  if [ "$complete" = yes ] && [ -n "$lines" ] && [ "$shown_n" -gt 0 ] && is_uint "$F_TOTAL"; then
    if [ "$shown_first" -gt 1 ] || [ "$end" -lt "$F_TOTAL" ]; then note=" (the requested lines)"; fi
    if [ "$end" -lt "$F_TOTAL" ]; then
      span=$((end - shown_first + 1))
      to=$((end + span))
      [ "$to" -le "$F_TOTAL" ] || to="$F_TOTAL"
      next="$(_cf_cmd $((end + 1)) "$to" "$F_BUILD" "$F_CORPUS")"
    fi
  fi
  if [ -n "$out" ]; then
    cat "$text" >"$out" 2>/dev/null || _code_out_fail "$out"
    printf '%s lines written to %s\n' "$shown_n" "$out"
  fi
  if [ "$shown_n" = 0 ]; then
    printf 'file: %s (build %s), no lines in this range; the file has %s lines\n' "${F_PATH:-$CF_PATH}" "${F_BUILD:--}" "${F_TOTAL:-0}"
  else
    printf 'file: %s (build %s), lines %s-%s of %s\n' "${F_PATH:-$CF_PATH}" "${F_BUILD:--}" "$shown_first" "$end" "${F_TOTAL:-$end}"
  fi
  [ -z "$others" ] || printf '%s\n' "$others"
  if [ "$complete" = yes ]; then
    printf 'complete: yes%s\n' "$note"
  else
    printf 'complete: no (%s)\n' "$reason"
  fi
  [ -z "$next" ] || printf 'next: %s\n' "$next"
  # The data time of the answer, when the service sends one (TASK-1508; the file answer of today has none).
  _code_fresh "$fresh"
  return "$rc"
}
