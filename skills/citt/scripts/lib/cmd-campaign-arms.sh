#!/usr/bin/env bash
# lib/cmd-campaign-arms.sh: the arms of citt campaign (TASK-1601, feedback 68): the --arm and --arms-file entries of draft and
# edit, the edit of the stored arm list, the Arms lines of check and create and the app × arm table of report; the --set-pref
# entries of draft (TASK-1597 AC8) and the Play links of --apps-file (TASK-1602 AC-11). An arm is one setup of the campaign's
# runs: the campaign books every arm for every app, and the report compares the arms per app.
# shellcheck shell=bash disable=SC2016,SC2034

# The bounds and the link forms the research service checks (crates/api/src/campaign/arms.rs: ARMS_MAX, ARM_NAME_MAX_CHARS,
# LINK_SCHEMES; TASK-1601 "Plan review": a bound changed there is changed here in the same change).
CM_ARMS_MAX=20
CM_ARM_NAME_RE='^[A-Za-z0-9_.-]{1,40}$'

# CM_ARMS: the arms of the flags, a JSON list of {name, install_referrer?, app_referrer?, note?} in the order given.
# CM_SP: the --set-pref entries of draft, a JSON list of {file, key, type, value}.
CM_ARMS='[]'
CM_SP='[]'
CM_ARMS_NEW='[]'

# _cm_arm_add ENTRY [NOTE] [WHERE]: adds one arm to CM_ARMS. ENTRY is NAME (an arm without a referrer: it installs the stored
# build), NAME=REFERRER (everything after the first "=" is the referrer, as typed) or NAME=@app (each app's own referrer,
# TASK-1602). WHERE names the source in an error (a line of --arms-file). Exits 2 on a form the service refuses.
_cm_arm_add() {
  local entry="$1" note="${2:-}" where="${3:+$3: }" name ref="" has=0 low
  name="${entry%%=*}"
  case "$entry" in
    *=*)
      has=1
      ref="${entry#*=}"
      ;;
  esac
  printf '%s' "$name" | LC_ALL=C grep -Eq "$CM_ARM_NAME_RE" \
    || usage_error "${where}an arm name is 1 to 40 characters of letters, digits, underscore, dot and hyphen, such as R1_play_organic; got: $name"
  if jq -e --arg n "$name" 'map(.name | ascii_downcase) | index($n | ascii_downcase)' <<<"$CM_ARMS" >/dev/null; then
    usage_error "${where}the arm $name is given twice; give each arm its own name (upper and lower case count as the same name)"
  fi
  if [ "$has" = 1 ] && [ -z "$ref" ]; then
    usage_error "${where}the referrer of the arm $name is empty; give --arm $name=REFERRER, or --arm $name for an arm without a referrer (its runs install the stored build)"
  fi
  low="$(printf '%s' "$ref" | sed 's/^[[:space:]]*//' | tr '[:upper:]' '[:lower:]')"
  case "$low" in
    http://* | https://* | market://* | intent://*)
      usage_error "${where}an arm takes the value of the link's referrer parameter, decoded, such as utm_source=google&utm_medium=cpc, and the value of the arm $name is a link; citt capture-start --help describes the Play links of a single run, and a link per app goes into --apps-file with --arm NAME=@app"
      ;;
  esac
  CM_ARMS="$(jq -c --arg n "$name" --arg r "$ref" --arg note "$note" '. + [{name: $n}
    + (if $r == "@app" then {app_referrer: true} elif $r != "" then {install_referrer: $r} else {} end)
    + (if $note != "" then {note: $note} else {} end)]' <<<"$CM_ARMS")" || die 1 "the arm could not be read: $entry"
  if [ "$(jq 'length' <<<"$CM_ARMS")" -gt "$CM_ARMS_MAX" ]; then
    usage_error "a campaign takes at most $CM_ARMS_MAX arms; $(jq 'length' <<<"$CM_ARMS") are given; keep $CM_ARMS_MAX, or split the arms over campaigns"
  fi
}

# _cm_arms_file FILE: one arm per line of FILE in the forms of --arm; blank lines and # lines are skipped, a line end of CR LF
# is read, and the text after a tab is the arm's note.
_cm_arms_file() {
  local file="$1" line entry note n=0
  [ -r "$file" ] || usage_error "cannot read $file"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    entry="${line%%$'\t'*}"
    note=""
    case "$line" in *$'\t'*) note="$(printf '%s' "${line#*$'\t'}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" ;; esac
    entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//')"
    case "$entry" in '' | '#'*) continue ;; esac
    _cm_arm_add "$entry" "$note" "$file line $n"
  done <"$file"
}

# _cm_arms_ios: exits 2 when an arm of CM_ARMS has a referrer (the Play Store installs on Android phones only).
_cm_arms_ios() {
  local name
  name="$(jq -r '[.[] | select(.install_referrer or .app_referrer) | .name][0] // empty' <<<"$CM_ARMS")"
  [ -z "$name" ] || usage_error "the arm $name has an install referrer, and a referrer is sent by the Play Store on an Android phone; leave --platform ios out, or give the arms without a referrer"
}

# _cm_set_pref SPEC: one --set-pref FILE:KEY=TYPE:VALUE of draft, added to CM_SP with the split of citt capture-start
# (_cr_set_pref, TASK-1596): FILE ends at the first ":", KEY at the first "=" after it, TYPE at the next ":", and VALUE is the
# rest, unchanged. The service checks the four parts.
_cm_set_pref() {
  local spec="$1" file rest key type value
  local bad="--set-pref takes FILE.xml:KEY=TYPE:VALUE, such as com.example.app.xml:paid_user=bool:true; TYPE is bool, int, long, float or string; got: $1"
  case "$spec" in *:*) ;; *) usage_error "$bad" ;; esac
  file="${spec%%:*}"
  rest="${spec#*:}"
  case "$file" in *=*) usage_error "$bad" ;; esac
  case "$rest" in *=*) ;; *) usage_error "$bad" ;; esac
  key="${rest%%=*}"
  rest="${rest#*=}"
  case "$rest" in *:*) ;; *) usage_error "$bad" ;; esac
  type="${rest%%:*}"
  value="${rest#*:}"
  CM_SP="$(jq -c --arg f "$file" --arg k "$key" --arg t "$type" --arg v "$value" '. + [{file: $f, key: $k, type: $t, value: $v}]' <<<"$CM_SP")" \
    || die 1 "--set-pref: the entry could not be read: $1"
}

# _cm_apps_file FILE PLATFORM: the lines of FILE as a JSON list (blank lines and # lines skipped). TASK-1602 AC-11: a line with
# "://" is a Play link with the app's own install referrer and stays a string entry; with PLATFORM ios it exits 2.
_cm_apps_file() {
  local file="$1" platform="$2" list n
  [ -r "$file" ] || usage_error "cannot read $file"
  list="$(jq -nc --rawfile f "$file" '$f | split("\n") | map(gsub("^\\s+|\\s+$"; ""))')" || die 1 "cannot read $file"
  if [ "$platform" = ios ]; then
    n="$(jq -r '[to_entries[] | select(.value | (startswith("#") | not) and contains("://")) | .key + 1][0] // empty' <<<"$list")"
    [ -z "$n" ] || usage_error "$file line $n is a Play link, and a Play link installs an Android app; leave --platform ios out, or list the package id of the iOS app"
  fi
  jq -c 'map(select(. != "" and (startswith("#") | not)))' <<<"$list"
}

# _cm_arms_edit ID REMOVE_JSON: the arm list of a PATCH. Reads the stored spec with GET /campaigns/{id}, takes the arms named in
# REMOVE_JSON out and adds the arms of CM_ARMS: an arm whose name the campaign has keeps its place, its note and its other
# keys and gets the referrer given (the service answers arm_changed for another setup, and changes nothing for the same one).
# Names compare without regard to case, as on the service. Sets CM_ARMS_NEW; exit 4 for a name to remove the campaign lacks.
_cm_arms_edit() {
  local id="$1" remove="$2" stored miss
  _cm_call GET "$CITT_V1/campaigns/$id"
  jq -e '.id' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  stored="$(jq -c '(.spec.arms // []) | if type == "array" then . else [] end' "$RESP")"
  miss="$(jq -r --argjson s "$stored" '[.[] | select(ascii_downcase as $n | $s | map(.name | ascii_downcase) | index($n) | not)][0] // empty' <<<"$remove")"
  if [ -n "$miss" ]; then
    die 4 "campaign $id has no arm $miss; $(jq -r 'if length == 0 then "it has no arms" else "its arms: " + (map(.name) | join(", ")) end' <<<"$stored")"
  fi
  CM_ARMS_NEW="$(jq -c --argjson rm "$remove" --argjson add "$CM_ARMS" '
    def lc: ascii_downcase;
    def setup($a): del(.install_referrer, .app_referrer)
      + (if $a.install_referrer then {install_referrer: $a.install_referrer} elif $a.app_referrer then {app_referrer: true} else {} end);
    map(select(.name | lc as $n | $rm | map(lc) | index($n) | not))
    | reduce $add[] as $a (.; (map(.name | lc) | index($a.name | lc)) as $i
        | if $i == null then . + [$a] else .[$i] |= setup($a) end)' <<<"$stored")" || die 1 "the arms of campaign $id could not be read"
}

# CM_ARMS_JQ: jq definitions of the arm lines. `arms_check`: the lines of estimate.arms in a dry run (TASK-1601 AC-3, TASK-1602
# AC-11; the counts of the apps with their own referrer or app preferences, the hint of arms that do not fit and the hint of
# an implicit arm, which has no control arm). `arm_setup`: the setup of one arm of the spec in words. `arms_list`: the Arms
# block of show. `arm_table`: the rows of the app × arm table of report.
CM_ARMS_JQ='
def arms_check: (.estimate // {}) as $e | ($e.arms // null) as $a | if ($a | type) != "object" then empty else
  "Arms: \($a.count // ($a.names // [] | length)) (\($a.names // [] | map(tostring | gsub("[\r\n\t]+"; " ")) | join(", ")))"
    + (if $a.runs_min != null then "; runs: \($a.runs_min) or more" else "" end)
    + (if $a.device_hours_min != null then "; device hours needed: \($a.device_hours_min)"
        + (if $e.device_hours_available != null then " of \($e.device_hours_available) available" else "" end) else "" end),
  (if $a.apps_with_referrer != null then "Apps with their own install referrer: \($a.apps_with_referrer) of \($a.apps_with_referrer + ($a.apps_without_referrer // 0))" else empty end),
  (if $a.apps_with_set_prefs != null then "Apps with their own app preferences: \($a.apps_with_set_prefs) of \($a.apps_with_set_prefs + ($a.apps_without_set_prefs // 0))" else empty end),
  (if $a.fits == false then "hint: the arms need more device hours than the phones have before the deadline; the campaign books what fits" else empty end),
  (if $a.implicit == true then "hint: every run uses its app'"'"'s "
      + ([(if $a.apps_with_set_prefs != null and $a.apps_with_referrer == null then empty else "referrer" end),
          (if $a.apps_with_set_prefs != null then "app preferences" else empty end)] | join(" and "))
      + " and the campaign has no control arm; add arms to compare" else empty end) end;
def arm_setup: (if (.install_referrer // "") != "" then "install referrer \(.install_referrer | tostring | gsub("[\r\n\t]+"; " "))"
    elif .app_referrer == true then "each app'"'"'s own install referrer" else "no install referrer (the stored build)" end)
  + (if (.set_prefs | type) == "array" and (.set_prefs | length) > 0
      then (.set_prefs | length) as $k | (.set_prefs | map(.file) | unique | length) as $f
        | ", app preferences (\($k) key\(if $k == 1 then "" else "s" end) in \($f) file\(if $f == 1 then "" else "s" end))" else "" end)
  + (if .app_set_prefs == true then ", each app'"'"'s own app preferences" else "" end)
  + (if (.note // "") != "" then "; note: \"\(.note | tostring | gsub("[\r\n\t]+"; " "))\"" else "" end);
def arms_list: if type == "array" and length > 0 then "Arms: \(length)", (.[] | "  \(.name): " + arm_setup) else empty end;
def arm_table: (.removed // []) as $rm
  | [["PACKAGE", "ARM", "RUNS", "ENDED", "ADS", "HITS", "VERDICT"]]
    + [.cells[]? | [.package_id, (.arm as $n | $n + (if $rm | index($n) then " (removed)" else "" end)), (.runs // 0), (.ended // 0),
        (.ads // 0), (.hits // 0),
        ((.verdict.summary? // "") | tostring | gsub("[\r\n\t]+"; " ") | if . == "" then null elif length > 120 then .[0:120] + "…" else . end)]];'
