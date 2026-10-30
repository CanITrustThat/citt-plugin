#!/usr/bin/env bash
# lib/cmd-capture-run.sh: citt capture-options, capture-start, capture-watch and capture-stop (TASK-505).
# Starts a network capture run on a lab phone (POST /project-apps/{id}/ad-sessions), follows it
# (GET /capture-runs/{id}) and stops it (POST /capture-runs/{id}/stop). Sourced after cmd-capture.sh.
# shellcheck shell=bash disable=SC2034,SC2016,SC2153

CR_TERMINAL=" done done_with_gaps stopped failed imported "

# jq helpers: short durations (5m, 1h, 7d), counted nouns, UTC minutes.
CR_JQ="$CS_JQ_TS"'
def short: (. | floor) as $s | if $s % 86400 == 0 then "\($s / 86400 | floor)d" elif $s % 3600 == 0 then "\($s / 3600 | floor)h"
  elif $s % 60 == 0 then "\($s / 60 | floor)m" else "\($s)s" end;
def n($k; $one; $many): if $k == 1 then "1 \($one)" else "\($k) \($many)" end;
def utc: ts | floor | strftime("%Y-%m-%d %H:%M UTC");'

# --- arguments -------------------------------------------------------------------------

# _cr_secs FLAG VALUE: <n>s, <n>m, <n>h or <n>d in seconds.
_cr_secs() {
  local n
  case "$2" in
    *[0-9]s) n="${2%s}" ;;
    *[0-9]m) n="$((${2%m} * 60))" ;;
    *[0-9]h) n="$((${2%h} * 3600))" ;;
    *[0-9]d) n="$((${2%d} * 86400))" ;;
    *) n="" ;;
  esac
  case "${2%?}" in '' | *[!0-9]*) n="" ;; esac
  [ -n "$n" ] || usage_error "$1 takes <n>m, <n>h or <n>d (or <n>s), got: $2"
  printf '%s' "$n"
}

# _cr_package APP: the package id of a package id or a Google Play link.
_cr_package() {
  local a="$1" p
  case "$a" in
    *apps.apple.com* | *itunes.apple.com*) usage_error "capture runs take an Android app: a package id or a Google Play link" ;;
    http://* | https://*)
      case "$a" in *play.google.com*) ;; *) usage_error "not a Google Play link: $a" ;; esac
      p="$(printf '%s' "$a" | sed -n 's/.*[?&]id=\([^&#]*\).*/\1/p')"
      ;;
    *) p="$a" ;;
  esac
  [[ "$p" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$ ]] || usage_error "not an Android package id or Google Play link: $a"
  printf '%s' "$p"
}

# _cr_project_flag VALUE: --project takes a name or, when numeric, a project id.
_cr_project_fix() {
  if [ -n "$OPT_PROJECT" ] && [ -z "$OPT_PROJECT_ID" ] && is_uint "$OPT_PROJECT"; then
    OPT_PROJECT_ID="$OPT_PROJECT"
    OPT_PROJECT=""
  fi
  check_project_flags
}

# _cr_app PACKAGE: resolves the project and sets CR_PAPP, the project app id of PACKAGE.
_cr_app() {
  E_KIND=project
  resolve_project
  call GET "$CITT_V1/projects/$PROJECT_ID/apps$(query q "$1")"
  CR_PAPP="$(jq -r --arg p "$1" '[.apps[] | select(.platform == "android" and .package_id == $p) | .project_app_id] | first // empty' "$RESP" 2>/dev/null)" \
    || die 1 "unparseable response from GET $CITT_V1/projects/$PROJECT_ID/apps"
  [ -n "$CR_PAPP" ] || die 4 "$1 is not in project \"${PROJECT_NAME:-$PROJECT_ID}\"; add it: citt submit$(project_arg) $1"
  E_KIND=app
  E_PACKAGE="$1"
}

# _cr_options: GET the start options of CR_PAPP into CR_OPTS.
_cr_options() {
  call GET "$CITT_V1/project-apps/$CR_PAPP/ad-sessions/options"
  CR_OPTS="$(tmpfile options.json)"
  cp "$RESP" "$CR_OPTS"
  jq -e 'type == "object"' "$CR_OPTS" >/dev/null 2>&1 || die 1 "unparseable response from GET $CITT_V1/project-apps/$CR_PAPP/ad-sessions/options"
}

# _cr_run_id RUN: the experiment id of a run id or key.
_cr_run_id() {
  if is_uint "$1"; then
    printf '%s' "$1"
    return 0
  fi
  CS_RUNS="$1"
  CS_PIDS=""
  _cs_resolve_runs
  printf '%s' "$CS_RIDS"
}

# _cr_get_run ID: GET /capture-runs/ID into RESP; 404 is "no capture run".
_cr_get_run() {
  http GET "$CITT_V1/capture-runs/$1"
  case "$CODE" in
    2??) ;;
    404) [ -z "$(body_field '.error')" ] && fail_http; die 4 "no capture run $1 in your projects (see: citt captures)" ;;
    *) fail_http ;;
  esac
}

# --- capture-options -------------------------------------------------------------------

cmd_capture_options() {
  local app="" dur="" dur_s="" pkg
  CITT_CMD="citt capture-options"
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    local used=$?
    if [ "$used" -gt 0 ]; then
      shift "$used"
      continue
    fi
    case "$1" in
      --duration)
        need_value "$1" $#
        dur="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_capture_options
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$app" ] || usage_error "one app at a time; got $app and $1"
        app="$1"
        ;;
    esac
    shift
  done
  [ -n "$app" ] || usage_error "give the app: a package id or a Google Play link"
  pkg="$(_cr_package "$app")" || exit $?
  _cr_project_fix
  [ -z "$dur" ] || dur_s="$(_cr_secs --duration "$dur")" || exit $?
  need_auth
  _cr_app "$pkg"
  _cr_options
  if [ "$CITT_JSON" = 1 ]; then
    cat "$CR_OPTS"
    printf '\n'
    return 0
  fi
  jq -r --arg proj "${PROJECT_NAME:-$PROJECT_ID}" --argjson papp "$CR_PAPP" "$CR_JQ"'
    "App: \(.package_id) in project \"\($proj)\" (project app \($papp)): "
      + (if .package_allowed then "capture allowed" else "capture not allowed for this package" end),
    "Launcher: " + (if .launcher_online then "online" elif .launcher_seen_at then "offline since \(.launcher_seen_at | utc); a run queues until it is back"
      else "never seen; a run queues until it reports" end)' "$CR_OPTS"
  printf '\n'
  if [ "$(jq '.devices | length' "$CR_OPTS")" = 0 ]; then
    printf 'Phones: none registered\n'
  else
    jq -c '[["Phone", "Device", "Status", "Active runs"]] + [.devices[] | [.device_name, .device_id, .status, (.active_runs // 0)]]' "$CR_OPTS" | table
  fi
  printf '\n'
  jq -r --arg dur "$dur" --arg ds "${dur_s:-0}" --arg note "$CITT_TRACKING_NOTE" "$CR_JQ"'
    "Exit states (servers): " + ([.states[] | "\(.code) \(.servers // "-")"] | join(", ") | if . == "" then "none reported" else . end),
    (if ((.countries // []) | length) > 0 then
       (.regions // ([.countries[].region] | unique)) as $regions
       | ($regions[] as $g | [.countries[] | select(.region == $g)
           | "\(.code) \(.servers // "?")" + (if .code == "US" then " (by state, --state)" else "" end)]
         | select(length > 0) | "Exit countries (servers), \($g): " + join(", ")),
         (if any(.countries[]; .servers == null) then
            "? is a country no phone worker has reported a server count for yet; --country CC takes any code listed" else empty end)
     else empty end),
    (if ((.device_locales // []) | length) > 0 then
       "Device languages (--language, default the exit'"'"'s language): " + ([.device_locales[].tag] | join(", ")) else empty end),
    "Proxy exit: " + (if .proxy_exit == true then "available" else "not available" end),
    "Session lengths (--split): " + (.split_options_s | map(short) | join(", ")) + "; default \(.default_split_s | short)",
    "Duration (--duration): \(.min_duration_s | short) to \(.max_duration_s | short)",
    "Profile: age \(.default_profile.persona_age // "-"), tracking \(.default_profile.tracking // "-") (--age \(.min_persona_age) to \(.max_persona_age), --tracking allow|refuse)"
      + (if .default_exit_state then "; last exit state \(.default_exit_state)" else "" end)
      + (if .default_exit_country then "; last exit country \(.default_exit_country)" else "" end),
    $note,
    (if .bytes_per_hour == null then "Measured size: none yet; no session of this package has been ingested"
     else "Measured size: BPH:\(.bytes_per_hour) per captured hour over \(n(.measured_sessions // 0; "session"; "sessions"))"
       + (if $dur != "" then "; \($dur) is about EST:\(.bytes_per_hour * ($ds | tonumber) / 3600 | floor)" else "" end) end)' "$CR_OPTS" \
    | while IFS= read -r line; do
      case "$line" in
        "Measured size: BPH:"*)
          local bph est rest
          rest="${line#Measured size: BPH:}"
          bph="${rest%% *}"
          rest="${rest#* }"
          line="Measured size: $(_cs_bytes "$bph") $rest"
          case "$line" in *EST:*)
            est="${line##*EST:}"
            line="${line%EST:*}$(_cs_bytes "$est")"
            ;;
          esac
          ;;
      esac
      printf '%s\n' "$line"
    done
}

# --- capture-start ---------------------------------------------------------------------

# _cr_pick PHONE_ARG: sets CR_DEV and CR_DEV_NAME from CR_OPTS.
_cr_pick() {
  local sel
  if [ -n "$1" ]; then
    sel="$(jq -c --arg p "$1" '.devices as $d
      | ([$d[] | select(($p | test("^[0-9]+$")) and .device_id == ($p | tonumber))]
         + [$d[] | select(.device_name == $p)]
         + [$d[] | select((.device_name // "" | ascii_downcase) == ($p | ascii_downcase))]) | first // empty' "$CR_OPTS")"
    [ -n "$sel" ] || die 4 "no phone \"$1\"; phones: $(jq -r '[.devices[] | "\(.device_name) (device \(.device_id))"] | join(", ") | if . == "" then "none registered" else . end' "$CR_OPTS")"
    case "$(jq -r '.status' <<<"$sel")" in
      busy) err "$CITT_CMD: $(jq -r '.device_name' <<<"$sel") is busy ($(jq -r '.active_runs // 0' <<<"$sel") active runs); the run queues behind them" ;;
      offline) err "$CITT_CMD: $(jq -r '.device_name' <<<"$sel") is offline; the run queues until it reports" ;;
    esac
  else
    sel="$(jq -c '[.devices[] | select(.status == "free")] | first // empty' "$CR_OPTS")"
    if [ -z "$sel" ]; then
      [ "$(jq '.devices | length' "$CR_OPTS")" != 0 ] || die 5 "no lab phone is registered"
      die 5 "no free phone: $(jq -r 'def n($k; $one; $many): if $k == 1 then "1 \($one)" else "\($k) \($many)" end;
        [.devices[] | "\(.device_name) (device \(.device_id)) \(.status)"
          + (if (.active_runs // 0) > 0 then ", " + n(.active_runs; "active run"; "active runs") else "" end)] | join("; ")' "$CR_OPTS"); give one with --phone NAME|ID to queue the run on it"
    fi
  fi
  CR_DEV="$(jq -r '.device_id' <<<"$sel")"
  CR_DEV_NAME="$(jq -r '.device_name' <<<"$sel")"
}

# _cr_split DURATION_S: the default session length for a duration from CR_OPTS.
_cr_split() {
  jq -r --argjson d "$1" '(.split_options_s // []) as $o
    | if (.default_split_s // 0) > 0 and .default_split_s <= $d then .default_split_s
      elif ([$o[] | select(. <= $d)] | length) > 0 then [$o[] | select(. <= $d)] | max
      elif ($o | length) > 0 then $o | min
      else $d end' "$CR_OPTS"
}

_cr_nonce() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# _cr_host_ok HOST: a lowercased ASCII DNS name (labels of 1 to 63 letters, digits and "-", none starting or ending with "-"; at most
# 253 characters) or a dotted IPv4 address (four numeric labels, each 0 to 255 without a leading zero; four all-numeric labels are
# always read as IPv4). No wildcard, port, scheme, path, space, control character, non-ASCII character or IPv6 address. The same
# grammar as the API and netproof/pins.py.
_cr_host_ok() {
  local LC_ALL=C host="$1" label oct
  local -a parts
  [[ "$host" =~ ^[a-z0-9.-]+$ ]] || return 1
  if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    IFS=. read -r -a parts <<<"$host"
    for oct in ${parts[@]+"${parts[@]}"}; do
      [ "${#oct}" -le 3 ] && [ "$((10#$oct))" -le 255 ] || return 1
      [ "$oct" = 0 ] || [[ "$oct" != 0* ]] || return 1
    done
    return 0
  fi
  [ "${#host}" -le 253 ] || return 1
  [[ "$host" != *. && "$host" != .* && "$host" != *..* ]] || return 1
  IFS=. read -r -a parts <<<"$host"
  for label in ${parts[@]+"${parts[@]}"}; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
}

# _cr_passthrough LIST: validates the comma-separated LIST of one --passthrough flag (spaces around the commas are trimmed) and
# appends the lowercased hosts, once each, to CR_PT (a newline-separated list); CR_PT_N counts the raw entries of all flags. A bad
# entry or more than 20 raw entries exits 2 before any request.
_cr_passthrough() {
  local rest="$1," item host
  while [ -n "$rest" ]; do
    item="${rest%%,*}"
    rest="${rest#*,}"
    CR_PT_N=$((CR_PT_N + 1))
    host="${item#"${item%%[! ]*}"}"
    host="${host%"${host##*[! ]}"}"
    host="$(LC_ALL=C printf '%s' "$host" | LC_ALL=C tr '[:upper:]' '[:lower:]'; printf x)"
    host="${host%x}"
    _cr_host_ok "$host" \
      || usage_error "--passthrough entry '$item' is not a host name or IPv4 address; give a DNS name such as api.example.com or an address such as 1.2.3.4, with no wildcard, port, scheme, path or space"
    case "
$CR_PT
" in *"
$host
"*) ;; *) CR_PT="${CR_PT:+$CR_PT
}$host" ;; esac
  done
  [ "$CR_PT_N" -le 20 ] || usage_error "--passthrough takes at most 20 hosts; got $CR_PT_N"
}

# NP-874: the --proxy-file parser, a jq program over the file as one raw string. It prints {"entries": [NP-873 C1 objects]} or
# {"error": "<message>"}; a message names the line number and what is wrong, never the line, the user or the password. The
# entries go from the file to a file: no user, password or host is on a command line or in a shell variable.
# Line forms: http://user:pass@host:port, socks5://user:pass@host:port (user and password percent-decoded; an IPv6 host in
# brackets), host:port:user:pass (http; split at the first three colons). Blank lines and lines starting with # are skipped.
# The address classes are NP-873 C2, the table the API (citt-api) and the runner (netproof/e2e/residential.py) also apply.
CR_PROXY_FORMS="not an entry; give http://user:pass@host:port, socks5://user:pass@host:port or host:port:user:pass"
CR_PROXY_JQ='
def trim: sub("^[ \t\r]+"; "") | sub("[ \t\r]+$"; "");
def hexnum: ascii_downcase | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
def utf8dec:
  reduce .[] as $c ({o: [], n: 0, cp: 0, bad: false};
    if .bad then .
    elif .n == 0 then
      if $c < 128 then .o += [$c]
      elif $c >= 194 and $c < 224 then .n = 1 | .cp = $c - 192
      elif $c >= 224 and $c < 240 then .n = 2 | .cp = $c - 224
      elif $c >= 240 and $c < 245 then .n = 3 | .cp = $c - 240
      else .bad = true end
    elif $c >= 128 and $c < 192 then .cp = .cp * 64 + $c - 128 | .n -= 1 | (if .n == 0 then .o += [.cp] else . end)
    else .bad = true end)
  | if .bad or .n != 0 or any(.o[]; . >= 55296 and . < 57344) then error("pct") else .o | implode end;
def pctdec:
  if test("%(?![0-9A-Fa-f]{2})") then error("pct")
  else [scan("(?:%[0-9A-Fa-f]{2})+|[^%]+")] | map(if startswith("%") then [scan("%([0-9A-Fa-f]{2})") | .[0] | hexnum] | utf8dec else . end) | join("")
  end;
def v4nums:
  if test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$") then split(".")
    | if all(.[]; (tonumber <= 255) and (. == "0" or (startswith("0") | not))) then map(tonumber) else null end
  else null end;
def v6groups:
  (if test("\\.") then
     ((capture("^(?<h>.*:)(?<v>[^:]+)$") // null) as $m
      | if $m == null then null
        else ($m.v | v4nums) as $q | if $q == null then null else {h: $m.h, t: [$q[0] * 256 + $q[1], $q[2] * 256 + $q[3]]} end end)
   else {h: ., t: []} end) as $p
  | if $p == null or ($p.h | test("^[0-9A-Fa-f:]+$") | not) then null
    else ($p.h | if ($p.t | length) > 0 and (endswith("::") | not) then .[:-1] else . end) as $h
      | [$h | splits("::")] as $halves
      | if ($halves | length) > 2 then null
        else ($halves | map(if . == "" then [] else split(":") end)) as $hs
          | if any($hs[][]; test("^[0-9A-Fa-f]{1,4}$") | not) then null
            else ($hs | map(map(hexnum))) as $g
              | (($g | map(length) | add) + ($p.t | length)) as $n
              | if ($halves | length) == 2 then (if $n > 7 then null else $g[0] + [range(8 - $n) | 0] + $g[1] + $p.t end)
                elif $n != 8 then null
                else $g[0] + $p.t end
            end
        end
    end;
def v4class:
  .[0] as $a | .[1] as $b | .[2] as $c
  | if $a == 0 then "unspecified"
    elif $a == 127 then "loopback"
    elif $a == 10 or ($a == 172 and $b >= 16 and $b <= 31) or ($a == 192 and $b == 168) then "private"
    elif $a == 100 and $b >= 64 and $b <= 127 then "cgnat"
    elif $a == 169 and $b == 254 then "link-local"
    elif $a >= 224 and $a <= 239 then "multicast"
    elif ($a == 192 and $b == 0 and $c == 2) or ($a == 198 and $b == 51 and $c == 100) or ($a == 203 and $b == 0 and $c == 113) then "documentation"
    elif ($a == 192 and $b == 0 and $c == 0) or ($a == 198 and ($b == 18 or $b == 19)) or $a >= 240 then "reserved"
    else null end;
def v6class:
  .[0] as $a | .[1] as $b
  | if all(.[]; . == 0) then "unspecified"
    elif all(.[0:7][]; . == 0) and .[7] == 1 then "loopback"
    elif $a >= 64512 and $a <= 65023 then "private"
    elif $a >= 65152 and $a <= 65215 then "link-local"
    elif $a >= 65280 then "multicast"
    elif ($a == 8193 and $b == 3512) or ($a == 16383 and $b < 4096) then "documentation"
    elif $a < 8192 or $a >= 16384 or ($a == 8193 and $b < 512) or $a == 8194 then "reserved"
    else null end;
def badhost: "the host is not a DNS name, an IPv4 address or an IPv6 address";
def hostcheck($v6):
  if $v6 then (v6groups as $g | if $g == null then badhost else ($g | v6class) end)
  elif test("^[0-9]+(\\.[0-9]+){3}$") then (v4nums as $q | if $q == null then badhost else ($q | v4class) end)
  elif (utf8bytelength <= 253) and test("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$") then null
  else badhost end
  | if . == null or . == badhost then .
    else "the host is \(if . == "unspecified" then "an" else "a" end) \(.) address; a proxy needs a public address" end;
def ctl: any(explode[]; . < 32 or (. >= 127 and . < 160));
def entry($s; $h; $v6; $p; $u; $pw):
  if $h == "" then {err: "empty host"}
  elif ($p | test("^[0-9]{1,5}$") | not) or ($p | tonumber) < 1 or ($p | tonumber) > 65535 then {err: "port must be 1 to 65535"}
  elif ($h | hostcheck($v6)) != null then {err: ($h | hostcheck($v6))}
  elif $u == "" then {err: "empty user"}
  elif $pw == "" then {err: "empty password"}
  elif ($u | ctl) or ($pw | ctl) then {err: "control character in the user or password"}
  elif ($u | utf8bytelength) > 256 then {err: "user over 256 bytes"}
  elif ($pw | utf8bytelength) > 256 then {err: "password over 256 bytes"}
  else {e: {scheme: $s, host: $h, port: ($p | tonumber), username: $u, password: $pw}} end;
def parse_line:
  if test("^[A-Za-z][A-Za-z0-9+.-]*://") then
    capture("^(?<s>[^:]*)://(?<r>.*)$") as $m
    | ($m.s | ascii_downcase) as $s
    | if $s != "http" and $s != "socks5" then {err: "scheme must be http or socks5"}
      else ($m.r | sub("/$"; "")) as $r
        | (if ($r | test("@")) then ($r | capture("^(?<ui>.*)@(?<hp>[^@]*)$")) else {ui: "", hp: $r} end) as $a
        | (($a.hp | capture("^\\[(?<h>[^\\]]*)\\]:(?<p>[^:/?#]*)$") | . + {v6: true})
           // ($a.hp | capture("^(?<h>[^:/?#\\[\\]]*):(?<p>[^:/?#]*)$") | . + {v6: false})
           // null) as $hp
        | if $hp == null then {err: $forms}
          else ($a.ui | if test(":") then capture("^(?<u>[^:]*):(?<pw>.*)$") else {u: ., pw: ""} end) as $ui
            | ((try {u: ($ui.u | pctdec), pw: ($ui.pw | pctdec)} catch null)) as $d
            | if $d == null then {err: "bad percent-encoding in the user or password"}
              else entry($s; $hp.h; $hp.v6; $hp.p; $d.u; $d.pw) end
          end
      end
  elif test("^[^:]*:[^:]*:[^:]*:") then
    capture("^(?<h>[^:]*):(?<p>[^:]*):(?<u>[^:]*):(?<pw>.*)$") as $m
    | entry("http"; $m.h; false; $m.p; $m.u; $m.pw)
  else {err: $forms} end;
split("\n") | to_entries
| map({line: (.key + 1), text: (.value | trim)} | select(.text != "" and (.text | startswith("#") | not)))
| map(.line as $n | ((.text | try parse_line catch {err: $forms}) + {line: $n}))
| (map(select(has("err"))) | first) as $bad
| if $bad != null then {error: "--proxy-file line \($bad.line): \($bad.err)"}
  elif length == 0 then {error: "--proxy-file holds no entries"}
  elif length > 100 then {error: "--proxy-file holds \(length) entries; at most 100"}
  else {entries: map(.e + {line})} end'

# _cr_proxy_file PATH|-: reads the proxy file once into a 0600 tmpfile (stdin for -), parses it with xtrace off and sets
# CR_PX_ENTRIES (a tmpfile holding the C1 array), CR_PX_N (the entry count), CR_PX_NAME (the base name, stdin for -) and CR_PX_SHA
# (the SHA-256 of the content as read). A bad file exits 2 before any request.
_cr_proxy_file() {
  { _cr_x="$-"; set +x; } 2>/dev/null
  local src res msg
  src="$(tmpfile proxy-src.txt)"
  if [ "$1" = - ]; then
    CR_PX_NAME=stdin
    cat >"$src" 2>/dev/null || usage_error "--proxy-file: cannot read stdin"
  else
    CR_PX_NAME="${1##*/}"
    { [ -r "$1" ] && [ ! -d "$1" ] && cat -- "$1" >"$src" 2>/dev/null; } || usage_error "--proxy-file: cannot read $1"
    case "$CR_PX_NAME" in '' | *[[:cntrl:]]*) usage_error "--proxy-file: the file name must be 1 to 255 bytes without control characters" ;; esac
    [ "$(printf '%s' "$CR_PX_NAME" | LC_ALL=C wc -c | tr -d ' ')" -le 255 ] \
      || usage_error "--proxy-file: the file name must be 1 to 255 bytes without control characters"
  fi
  res="$(tmpfile proxy-parse.json)"
  jq -R -s -c --arg forms "$CR_PROXY_FORMS" "$CR_PROXY_JQ" "$src" >"$res" 2>/dev/null || die 1 "--proxy-file could not be parsed"
  msg="$(jq -r '.error // empty' "$res")"
  [ -z "$msg" ] || usage_error "$msg"
  CR_PX_ENTRIES="$(tmpfile proxy-entries.json)"
  jq -c '.entries' "$res" >"$CR_PX_ENTRIES"
  CR_PX_N="$(jq 'length' "$CR_PX_ENTRIES")"
  CR_PX_SHA="$(sha256_of "$src")"
  rm -f "$res"
  case "$_cr_x" in *x*) set -x ;; esac
}

cmd_capture_start() {
  local app="" pkg dur="" dur_s split="" split_s="" state="" country="" exit_key phone="" age="" tracking="" wait=0 timeout=540
  local proxy_file=""
  local nav="" help_wait="" nav_mode="" wait_s="" fallback="" pt_json="[]" reset_gaid="" language=""
  local goal="" conclusion="" prompts_file="" bmi_json="[]" prompts_json="{}"
  CR_PT="" CR_PT_N=0
  CR_PX_ENTRIES="" CR_PX_NAME="" CR_PX_SHA="" CR_PX_N=0
  CITT_CMD="citt capture-start"
  CR_OPTS=""
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    local used=$?
    if [ "$used" -gt 0 ]; then
      shift "$used"
      continue
    fi
    case "$1" in
      --duration | --split | --state | --country | --phone | --age | --tracking | --timeout | --navigator | --help-wait | --passthrough \
        | --goal | --bring-me-in | --conclusion | --prompts-file | --language | --proxy-file)
        need_value "$1" $#
        case "$1" in
          --language) language="$2" ;;
          --proxy-file) proxy_file="$2" ;;
          --goal) goal="$2" ;;
          --bring-me-in) bmi_json="$(jq -c --arg b "$2" '. + [$b]' <<<"$bmi_json")" ;;
          --conclusion) conclusion="$2" ;;
          --prompts-file) prompts_file="$2" ;;
          --passthrough) _cr_passthrough "$2" ;;
          --navigator) nav="$2" ;;
          --help-wait) help_wait="$2" ;;
          --duration) dur="$2" ;;
          --country) country="$2" ;;
          --split) split="$2" ;;
          --state) state="$2" ;;
          --phone) phone="$2" ;;
          --age) age="$2" ;;
          --tracking) tracking="$2" ;;
          --timeout) timeout="$2" ;;
        esac
        shift
        ;;
      --wait) wait=1 ;;
      --state-fallback) fallback=any_state ;;
      --reset-gaid) reset_gaid=true ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_capture_start
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$app" ] || usage_error "one app at a time; got $app and $1"
        app="$1"
        ;;
    esac
    shift
  done
  [ -n "$app" ] || usage_error "give the app: a package id or a Google Play link"
  pkg="$(_cr_package "$app")" || exit $?
  _cr_project_fix
  # NP-800: the session prompts of an orchestrated run, from the flags or from --prompts-file (JSON {goal, bring_me_in,
  # conclusion}); blank values and bullets are left out of the request body
  if [ -n "$prompts_file" ]; then
    { [ -z "$goal" ] && [ -z "$conclusion" ] && [ "$bmi_json" = "[]" ]; } \
      || usage_error "--prompts-file replaces --goal, --bring-me-in and --conclusion; give one or the other"
    { [ -f "$prompts_file" ] && [ -r "$prompts_file" ]; } || usage_error "--prompts-file: cannot read $prompts_file"
    jq -e 'type == "object"
        and ((.goal // null) | type | . == "string" or . == "null")
        and ((.conclusion // null) | type | . == "string" or . == "null")
        and ((.bring_me_in // []) | type == "array" and all(.[]; type == "string"))' "$prompts_file" >/dev/null 2>&1 \
      || usage_error "--prompts-file takes a JSON object {\"goal\": text or null, \"bring_me_in\": [text], \"conclusion\": text or null}"
    prompts_json="$(jq -c '{goal: (.goal // null), bring_me_in: (.bring_me_in // []), conclusion: (.conclusion // null)}' "$prompts_file")"
  else
    prompts_json="$(jq -nc --arg g "$goal" --arg c "$conclusion" --argjson b "$bmi_json" '{goal: $g, bring_me_in: $b, conclusion: $c}')"
  fi
  prompts_json="$(jq -c 'def blank: . == null or (. | test("^\\s*$"));
      (if (.goal | blank) then {} else {goal} end)
      + ([.bring_me_in[] | select(blank | not)] as $b | if ($b | length) == 0 then {} else {bring_me_in: $b} end)
      + (if (.conclusion | blank) then {} else {conclusion} end)' <<<"$prompts_json")"
  if [ -z "$dur" ] && [ "$(jq -r 'has("goal")' <<<"$prompts_json")" = true ]; then
    dur=30m  # NP-800: a goal without --duration is one session of 30 minutes, as the API's default
    [ -n "$split" ] || split=30m
  fi
  [ -n "$dur" ] || usage_error "give --duration, such as 1h, 90m or 2d"
  dur_s="$(_cr_secs --duration "$dur")" || exit $?
  [ -z "$split" ] || split_s="$(_cr_secs --split "$split")" || exit $?
  # NP-874: --proxy-file names the customer's proxies as the exit, in place of a NordVPN state or country; the file is read
  # and checked here, before any request, and its SHA-256 and name take the place of the exit key in the idempotency input.
  if [ -n "$proxy_file" ]; then
    { [ -z "$state" ] && [ -z "$country" ] && [ -z "$fallback" ]; } \
      || usage_error "--proxy-file replaces --state, --country and --state-fallback; give one or the other"
    _cr_proxy_file "$proxy_file"
    exit_key="proxy=$CR_PX_SHA|$CR_PX_NAME"
  # NP-503: --country CC exits through a NordVPN server in that country; a US exit (no --country, or --country US) needs
  # --state, and its request body is the one of before NP-503 (exit_state only).
  elif [ -n "$country" ]; then
    [[ "$country" =~ ^[A-Za-z]{2}$ ]] || usage_error "--country takes a two-letter country code, such as SG (see: citt capture-options)"
    country="$(printf '%s' "$country" | tr '[:lower:]' '[:upper:]')"
  fi
  if [ -n "$proxy_file" ]; then
    : # the exit key is the file's (above)
  elif [ -n "$country" ] && [ "$country" != US ]; then
    [ -z "$state" ] || usage_error "--state applies to US exits only; leave it out for --country $country"
    exit_key="country:$country"
  else
    country=""
    [[ "$state" =~ ^[A-Za-z]{2}$ ]] || usage_error "give --state with a two-letter exit state code, such as CA (see: citt capture-options)"
    state="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
    exit_key="$state"
  fi
  # NP-878: the device language of every session of the run, independent of the exit; the service checks the tag against its
  # list (the options' device_locales), the plugin checks the form only
  [ -z "$language" ] || [[ "$language" =~ ^[a-z]{2,3}(-[A-Z][a-z]{3})?-[A-Z]{2}$ ]] \
    || usage_error "--language takes a device language tag of the form ll-CC or ll-Ssss-CC, such as zh-Hans-CN or es-US (the options list device_locales: citt capture-options)"
  [ -z "$age" ] || is_uint "$age" || usage_error "--age takes a whole number of years, got: $age"
  case "$tracking" in '' | allow | refuse) ;; *) usage_error "--tracking takes allow or refuse, got: $tracking" ;; esac
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  # NP-691: the navigator mode (NP-677 `navigator`) and the wait for a human in whole minutes (`help_wait_s`).
  case "$nav" in
    '') ;;
    independent) nav_mode=independent ;;
    stuck) nav_mode=ask_when_stuck ;;
    unsure) nav_mode=ask_when_unsure ;;
    *) usage_error "--navigator takes independent, stuck or unsure, got: $nav" ;;
  esac
  if [ -n "$help_wait" ]; then
    { is_uint "$help_wait" && [ "$help_wait" -le 30 ]; } || usage_error "--help-wait takes whole minutes, 0 to 30, got: $help_wait"
    case "$nav_mode" in ask_when_stuck | ask_when_unsure) ;; *) usage_error "--help-wait applies to --navigator stuck or unsure" ;; esac
    wait_s=$((10#$help_wait * 60))
  fi
  # CF-W3: --state-fallback lets the run be captured in another state when no server of the booked one connects.
  [ -z "$fallback" ] || [ -n "$state" ] || usage_error "--state-fallback applies to a US exit booked with --state; leave it out for --country"
  # CF-W11: --passthrough hosts (validated while the flags were read), as the request's passthrough_hosts
  [ -z "$CR_PT" ] || pt_json="$(printf '%s\n' "$CR_PT" | jq -R . | jq -sc .)"
  need_auth
  _cr_app "$pkg"

  # A re-run of the same command within a day reuses the nonce, phone and session length of the
  # interrupted one, so the API returns the run that call may have created.
  local dir h pend nonce key now
  dir="$CITT_STATE/capture-start"
  local hin="v1|$CITT_HOST|$CR_PAPP|$phone|$exit_key|$dur_s|$split_s|$age|$tracking"
  [ -z "$nav_mode" ] || hin="$hin|nav=$nav_mode|wait=$wait_s"
  [ -z "$fallback" ] || hin="$hin|fallback=$fallback"
  [ -z "$reset_gaid" ] || hin="$hin|reset_gaid=1"
  [ -z "$language" ] || hin="$hin|device_locale=$language"
  [ -z "$CR_PT" ] || hin="$hin|passthrough=$(printf '%s' "$CR_PT" | tr '\n' ',')"
  [ "$prompts_json" = "{}" ] || hin="$hin|prompts=$(_cs_str_sha "$prompts_json")"
  h="$(_cs_str_sha "$hin")"
  pend="$dir/$h.json"
  now="$(now_s)"
  nonce=""
  if [ -f "$pend" ] && [ $((now - $(jq -r '.created_at // 0' "$pend" 2>/dev/null || echo 0))) -lt 86400 ]; then
    nonce="$(jq -r '.nonce // empty' "$pend")"
    CR_DEV="$(jq -r '.device_id // empty' "$pend")"
    CR_DEV_NAME="$(jq -r '.device_name // empty' "$pend")"
    split_s="$(jq -r '.split_s // empty' "$pend")"
  fi
  if [ -n "$country" ]; then
    _cr_options
    [ "$(jq -r --arg c "$country" 'any(.countries[]?; .code == $c)' "$CR_OPTS")" = true ] \
      || die 4 "no exit country $country in the capture options; list them with: citt capture-options $pkg$(project_arg)"
  fi
  if [ -z "$nonce" ] || [ -z "$CR_DEV" ] || [ -z "$split_s" ]; then
    [ -n "$CR_OPTS" ] || _cr_options
    [ "$(jq -r '.package_allowed' "$CR_OPTS")" = true ] || die 7 "$pkg is not among the packages allowed for capture runs"
    [ "$(jq -r '.launcher_online' "$CR_OPTS")" = true ] || err "$CITT_CMD: the lab launcher is offline; the run queues until it reports"
    _cr_pick "$phone"
    [ -n "$split_s" ] || split_s="$(_cr_split "$dur_s")"
    nonce="$(_cr_nonce)"
    (umask 077 && mkdir -p "$dir")
    (umask 077 && jq -nc --arg n "$nonce" --argjson d "$CR_DEV" --arg dn "$CR_DEV_NAME" --argjson s "$split_s" --argjson t "$now" \
      '{nonce: $n, device_id: $d, device_name: $dn, split_s: $s, created_at: $t}' >"$pend")
  fi
  key="plugin-$(_cs_str_sha "$h:$nonce" | cut -c1-32)"

  # NP-874: the proxy entries reach the body from their tmpfile (--slurpfile), never from a command line.
  local body
  body="$(tmpfile start.json)"
  jq -nc --argjson d "$CR_DEV" --arg st "$state" --arg cc "$country" --argjson dur "$dur_s" --argjson sp "$split_s" --arg k "$key" --arg age "$age" --arg tr "$tracking" \
    --arg nav "$nav_mode" --arg ws "$wait_s" --arg fb "$fallback" --argjson pt "$pt_json" --arg rg "$reset_gaid" --arg dl "$language" --argjson pr "$prompts_json" \
    --slurpfile px "${CR_PX_ENTRIES:-/dev/null}" --arg pxn "${CR_PX_NAME:-}" \
    '{device_id: $d} + (if ($px | length) > 0 then {} elif $cc == "" then {exit_state: $st} else {exit_country: $cc} end)
     + {duration_s: $dur, split_s: $sp, idempotency_key: $k}
     + (if $age == "" then {} else {persona_age: ($age | tonumber)} end)
     + (if $tr == "" then {} else {tracking: $tr} end)
     + (if $nav == "" then {} else {navigator: $nav} end)
     + (if $ws == "" then {} else {help_wait_s: ($ws | tonumber)} end)
     + (if $fb == "" then {} else {exit_fallback: $fb} end)
     + (if ($pt | length) == 0 then {} else {passthrough_hosts: $pt} end)
     + (if $rg == "" then {} else {reset_gaid: true} end)
     + (if $dl == "" then {} else {device_locale: $dl} end)
     + $pr
     + (if ($px | length) > 0 then {proxy_file_name: $pxn, proxy_entries: $px[0]} else {} end)' >"$body"
  HTTP_RETRY=yes
  http POST "$CITT_V1/project-apps/$CR_PAPP/ad-sessions" "$body"
  # With --wait the key is kept until the watch returns, so a re-run after a network or server
  # failure while watching gets the same run back and follows it.
  case "$CODE" in
    2??) [ "$wait" = 1 ] || rm -f "$pend" ;;
    400 | 402 | 403 | 404 | 409 | 422) rm -f "$pend" ;;
  esac
  # NP-873 AC3: a service without a proxy key refuses a proxy run; the refusal is final, so the key is not kept.
  if [ "$CODE" = 503 ] && [ "$(body_field '.error')" = proxy_exit_unavailable ]; then
    rm -f "$pend"
    fail_out 7 "request rejected: the proxy exit is not available on this service yet"
  fi
  ok || fail_http
  local launch rid
  launch="$(tmpfile launch.json)"
  cp "$RESP" "$launch"
  rid="$(jq -r '.experiment_id // empty' "$launch" 2>/dev/null)"
  [ -n "$rid" ] || die 1 "unparseable response from POST $CITT_V1/project-apps/$CR_PAPP/ad-sessions"
  if [ "$wait" = 1 ]; then
    if [ "$CITT_JSON" != 1 ]; then
      _cr_started "$launch" "$rid"
    else
      _cr_get_run "$rid"
    fi
    local wcode=0
    _cr_watch "$rid" "$rid" "$timeout" "$launch" || wcode=$?
    rm -f "$pend"
    return "$wcode"
  fi
  if [ "$CITT_JSON" = 1 ]; then
    cat "$launch"
    printf '\n'
    return 0
  fi
  _cr_started "$launch" "$rid"
}

# _cr_started LAUNCH_FILE RUN_ID: the four lines after a start (the end from GET /capture-runs/ID).
_cr_started() {
  local eta=""
  http GET "$CITT_V1/capture-runs/$2"
  if ok; then eta="$(jq -r "$CR_JQ"' .run.eta_at // empty | utc' "$RESP" 2>/dev/null)"; fi
  jq -r --arg eta "${eta:-unknown}" "$CR_JQ"'
    "Run \(.experiment_id) (\(.run_key)): \(.status) on \(.device_name // "phone") (device \(.device_id))"
      + (if (.runs_ahead // 0) > 0 then ", " + n(.runs_ahead; "run ahead"; "runs ahead") else "" end)
      + (if .status_reason then ": \(.status_reason)" else "" end),
    (if .proxy then "Exit: your proxies from \(.proxy.file_name // "your file"), \(n(.proxy.entries // 0; "entry"; "entries")), first entry first each session"
     elif .exit_state then "Exit state \(.exit_state)" + (if .exit_fallback == "any_state" then " (another state is allowed when \(.exit_state) connects nothing)" else "" end) else "Exit country \(.exit_country // "-")" end) + "; \(n(.planned_sessions // 0; "session"; "sessions")) of \(.split_s | short) over \(.duration_s | short)"
      + (if .device_locale then "; device language \(.device_locale)" else "" end)
      + (if (.passthrough_hosts // []) | length > 0
         then "; passed through unread, not decrypted and not captured: \(.passthrough_hosts | join(", "))" else "" end)
      + (if .persona_age then "; persona age \(.persona_age), tracking \(.tracking // "-")" else "" end)
      + (if .navigator == "ask_when_stuck" or .navigator == "ask_when_unsure"
         then "; navigator asks when \(.navigator | ltrimstr("ask_when_")), waits up to \((.help_wait_s // 0) / 60 | floor)m for a human" else "" end)
      + (if .orchestrated == true
         then "; orchestrated: yes, " + n((.prompts.bring_me_in // []) | length; "bring-me-in bullet"; "bring-me-in bullets")
           + (if .prompts.goal then ", goal set" else ", no goal" end)
           + (if .prompts.conclusion then ", conclusion set" else ", no conclusion" end) else "" end),
    "Estimated end: \($eta)",
    "Next: citt capture-watch \(.experiment_id) to follow it; citt capture-stop \(.experiment_id) to stop it; citt capture-sync --run \(.run_key) to download its sessions"' "$1"
}

# --- capture-watch ---------------------------------------------------------------------

# CF-W6: what follows a pending store, after the progress row's reason (attempt and next attempt time).
CR_OWED_NEXT="the service retries the store for up to 72 hours after the run ends; a session still not stored then is marked failed and support replays it"

# _cr_watch RUN_ID RUN_ARG TIMEOUT [LAUNCH_FILE]: polls the run until it ends or TIMEOUT passes.
# One line per state change and per finished session; the printed sessions are kept in the state
# folder, so a re-run prints only new ones.
# CF-W13: CR_ZERO_ON_END=1 (capture-watch --zero-on-end) makes every ended state exit 0 after its end record; the timeout (12) and
# needs_human (16) exits and a server error (8) stay.
_cr_watch() {
  local rid="$1" arg="$2" timeout="$3" launch="${4:-}" start left polls=0 last="" now_state seen sfile lines line ended=false
  local hfile hid human=false ofile
  sfile="$CITT_STATE/capture-watch/run-$rid"
  # NP-691: the help requests this run's watch has stopped for, so a re-run does not stop for them again.
  hfile="$sfile.help"
  ofile="$sfile.owed"
  (umask 077 && mkdir -p "$CITT_STATE/capture-watch")
  [ -f "$sfile" ] || : >"$sfile"
  [ -f "$ofile" ] || : >"$ofile"
  start="$(now_s)"
  while :; do
    _cr_get_run "$rid"
    polls=$((polls + 1))
    seen="$(jq -R -s -c 'split("\n") | map(select(. != "") | tonumber)' "$sfile")"
    lines="$(jq -r --argjson seen "$seen" "$CR_JQ"'
      . as $d | $d.run.planned_sessions as $p
      | [($d.progress // [])[] | select((.status == "ingested" or .status == "failed") and (.seq as $q | any($seen[]; . == $q) | not))]
      | sort_by(.seq)[] | . as $g
      | ([($d.sessions // [])[] | select(.seq == $g.seq)] | first) as $s
      | (($s | .flags) // 0) as $f
      | (if ($g.exit.proxy | type) == "object" then $g.exit as $x | $x.proxy as $px
          | (($px.skipped // [])[] | "\($g.seq)\t  #\(.entry) skipped: \(.text // .reason)" + (if .line then " (line \(.line))" else "" end)),
            (if $px.entry == null then empty
             else ([$x.exit_ip, $x.city, $x.region, $x.country, $x.org] | map(select(. != null and . != ""))) as $ip
               | ((["\($d.launch.proxy.file_name // "your proxy") #\($px.entry)"]
                   + (if ($ip | length) > 0 then [($ip | join(", ")) + " (ipinfo.io)"] else [] end)
                   + (if $x.registry_country then ["registry \($x.registry_country)"] else [] end)) | join(", ")) as $where
               | "\($g.seq)\t  exit: \($where); "
                 + (if $px.bytes == null then "bytes not measured"
                    elif $px.bytes > 0 and $px.bytes < 50000000 then "under 0.1 GB through your proxy"
                    else ($px.bytes / 100000000 | floor + (if ($px.bytes / 100000000) - floor >= 0.5 then 1 else 0 end)) as $t
                      | "\($t / 10 | floor).\($t % 10) GB through your proxy" end) end)
         else empty end),
        "\($g.seq)\tSession \($g.seq) of \($p // "?"): "
        + (if $g.status == "ingested" then "ingested, " + n($f; "flag"; "flags") else "failed" + (if $g.reason then ": \($g.reason)" else "" end) end)
        + (($s | .persona) // {} | if .locale then "; Phone locale \(.locale)"
             + (if .locale_source == "run" then " (set by the run)" elif .locale_source == "exit" then " (set by the exit)" else "" end)
             + (if .time_zone then " · time zone \(.time_zone)" else "" end) else "" end)' "$RESP" 2>/dev/null)" \
      || die 1 "unparseable response from GET $CITT_V1/capture-runs/$rid"
    if [ -n "$lines" ]; then
      while IFS=$'\t' read -r q line; do
        [ "$CITT_JSON" = 1 ] || printf '%s\n' "$line"
        printf '%s\n' "$q" >>"$sfile"
      done <<<"$lines"
    fi
    # CF-W6: a session uploaded and verified whose store the service retries (status owed) gets one line per seq, kept in
    # $ofile; its later ingested or failed line still prints.
    seen="$(jq -R -s -c 'split("\n") | map(select(. != "") | tonumber)' "$ofile")"
    lines="$(jq -r --argjson seen "$seen" --arg next "$CR_OWED_NEXT" '
      . as $d | $d.run.planned_sessions as $p
      | [($d.progress // [])[] | select(.status == "owed" and (.seq as $q | any($seen[]; . == $q) | not))]
      | sort_by(.seq)[]
      | "\(.seq)\tSession \(.seq) of \($p // "?"): "
        + ((.reason // "uploaded and verified, storage pending") | sub("^Session [0-9]+: "; ""))
        + "; \($next)"' "$RESP" 2>/dev/null)" \
      || die 1 "unparseable response from GET $CITT_V1/capture-runs/$rid"
    if [ -n "$lines" ]; then
      while IFS=$'\t' read -r q line; do
        [ "$CITT_JSON" = 1 ] || printf '%s\n' "$line"
        printf '%s\n' "$q" >>"$ofile"
      done <<<"$lines"
    fi
    now_state="$(jq -r '"\(.run.state)|\(.run.status_reason // "")"' "$RESP")"
    if [ "$now_state" != "$last" ] && [ "$CITT_JSON" != 1 ]; then
      jq -r "$CR_JQ"' .run as $r
        | "Run \($r.experiment_id) (\($r.run_key)): \($r.state)" + (if $r.status_reason then ": \($r.status_reason)" else "" end)
          + ", " + (if $r.planned_sessions then "\($r.finished_sessions // 0) of \(n($r.planned_sessions; "session"; "sessions"))"
                    else n($r.finished_sessions // 0; "session"; "sessions") end)
          + (if ($r.failed_sessions // 0) > 0 then ", \($r.failed_sessions) failed" else "" end)
          + (if ($r.flags // 0) > 0 then ", " + n($r.flags; "flag"; "flags") else "" end)
          + (if $r.eta_at then ", estimated end \($r.eta_at | utc)" else "" end)
          + (if $r.device_locale then ", device language \($r.device_locale)" else "" end)' "$RESP"
    fi
    last="$now_state"
    if [ "${now_state%%|*}" = needs_human ]; then
      hid="$(jq -r '.help.open.id // empty' "$RESP")"
      if [ -n "$hid" ] && ! grep -qx "$hid" "$hfile" 2>/dev/null; then
        (umask 077 && printf '%s\n' "$hid" >>"$hfile")
        human=true
        break
      fi
    fi
    case "$CR_TERMINAL" in *" ${now_state%%|*} "*)
      ended=true
      break
      ;;
    esac
    left=$((timeout - ($(now_s) - start)))
    [ "$left" -gt 0 ] || break
    poll_sleep "" "$left"
  done

  local st key fin planned failed reason code=0
  st="${now_state%%|*}"
  reason="${now_state#*|}"
  key="$(jq -r '.run.run_key // empty' "$RESP")"
  fin="$(jq -r '.run.finished_sessions // 0' "$RESP")"
  planned="$(jq -r '.run.planned_sessions // "?"' "$RESP")"
  failed="$(jq -r '.run.failed_sessions // 0' "$RESP")"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --argjson polls "$polls" --argjson ended "$ended" --argjson human "$human" --slurpfile l "${launch:-/dev/null}" \
      '{schema: "citt.plugin.capture-watch/1", polls: $polls, ended: $ended, needs_human: $human, run: .}
       + (if .help then {help: .help} else {} end) + (if ($l | length) > 0 then {started: $l[0]} else {} end)' "$RESP"
  fi
  if [ "$human" = true ]; then
    if [ "$CITT_JSON" != 1 ]; then
      local path link="no live link"
      path="$(jq -r '.help.open.live_path // empty' "$RESP")"
      [ -z "$path" ] || link="$(app_url "$path")"
      jq -r --argjson L "$(local_times "$RESP")" --arg link "$link" "$JQ_LT"' .run as $r | .help.open as $h
        | (if $h.trigger == "bring_me_in"
           then "Run \($r.experiment_id) (\($r.run_key)): needs_human: the session brings you in (help request \($h.id), session \($h.seq))"
           else "Run \($r.experiment_id) (\($r.run_key)): needs_human: the Visual LLM asks for a human (help request \($h.id), session \($h.seq))" end),
          "Reason: \($h.trigger_sentence)",
          (if $h.screen_line then "Screen: \($h.screen_line)" else empty end),
          "Waits for you until \($h.deadline_at | lt); then the Visual LLM continues on its own.",
          "Live page: \($link)",
          (if $h.answerable == true then "Answer by text: citt help-answer \($h.id) \"<your instruction>\"" else empty end)' "$RESP"
    fi
    err "$CITT_CMD: run $rid needs a human; give the Live page link to the user, then re-run: citt capture-watch $(shq "$arg")"
    return 16
  fi
  if [ "$ended" != true ]; then
    err "$CITT_CMD: run $rid is still $st after $timeout s; re-run: citt capture-watch $(shq "$arg")"
    return 12
  fi
  rm -f "$sfile" "$hfile"
  if [ "$CITT_JSON" != 1 ] && [ "$(jq '([(.progress // [])[] | select(.status == "ingested")] | length) + ((.sessions // []) | length)' "$RESP")" -gt 0 ]; then
    printf 'Next: citt capture-sync --run %s\n' "$key"
  fi
  case "$st" in
    done_with_gaps)
      err "$CITT_CMD: run $rid ended done_with_gaps: $failed of $planned sessions failed"
      code=13
      ;;
    stopped)
      err "$CITT_CMD: run $rid was stopped: $fin of $planned sessions finished"
      code=14
      ;;
    failed)
      err "$CITT_CMD: run $rid failed${reason:+: $reason}"
      code=8
      ;;
  esac
  [ "${CR_ZERO_ON_END:-}" != 1 ] || code=0
  return "$code"
}

cmd_capture_watch() {
  local run="" timeout=540 rid
  CR_ZERO_ON_END=0
  CITT_CMD="citt capture-watch"
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      --zero-on-end) CR_ZERO_ON_END=1 ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_capture_watch
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$run" ] || usage_error "one run at a time; got $run and $1"
        run="$1"
        ;;
    esac
    shift
  done
  [ -n "$run" ] || usage_error "give the run id or run key (see: citt captures)"
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  need_auth
  rid="$(_cr_run_id "$run")" || exit $?
  _cr_watch "$rid" "$run" "$timeout"
}

# --- capture-stop ----------------------------------------------------------------------

cmd_capture_stop() {
  local run="" rid st
  CITT_CMD="citt capture-stop"
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_capture_stop
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$run" ] || usage_error "one run at a time; got $run and $1"
        run="$1"
        ;;
    esac
    shift
  done
  [ -n "$run" ] || usage_error "give the run id or run key (see: citt captures)"
  need_auth
  rid="$(_cr_run_id "$run")" || exit $?
  _cr_get_run "$rid"
  st="$(jq -r '.run.state // empty' "$RESP")"
  case "$CR_TERMINAL" in *" $st "*)
    if [ "$CITT_JSON" = 1 ]; then
      cat "$RESP"
      printf '\n'
    else
      jq -r '"Run \(.run.experiment_id) (\(.run.run_key)) had already ended: \(.run.state)"' "$RESP"
    fi
    return 0
    ;;
  esac
  E_KIND=run
  HTTP_RETRY=yes
  call POST "$CITT_V1/capture-runs/$rid/stop"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  jq -r '"Run \(.experiment_id) (\(.run_key))" as $r
    | if .status == "stopping" then "\($r): stopping; the phone ends the current session and uploads it", "Next: citt capture-watch \(.experiment_id)"
      elif .status_reason == "stopped before it started" then "\($r): stopped before it started"
      else "\($r) has ended: \(.status)" end' "$RESP"
}
