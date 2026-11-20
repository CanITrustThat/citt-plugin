#!/usr/bin/env bash
# lib/cmd-campaign.sh: citt campaign (NP-2012, CAMP-12; services/netproof/planning/campaigns/PLAN.md section 2). A campaign is
# described in a spec file (draft), checked as a dry run (check, POST /campaigns?dry_run=1), created (create, POST /campaigns),
# listed and shown (GET /campaigns, GET /campaigns/{id}), paused, resumed, stopped and edited (POST .../pause|resume|stop,
# PATCH /campaigns/{id}), its apps held and restored (POST .../apps/{app}/hold|restore), a run's review queued again
# (POST .../reviews/{run}/retry), and its report read, waited for, watched and pulled with the runs (GET .../report, the
# customer view, then citt capture-sync of the runs).
# shellcheck shell=bash disable=SC2016

# CM_JQ: jq definitions for the printed lines. `one`: model or customer text on one line; `q`: that text in double quotes.
CM_JQ='
def one: tostring | gsub("[\r\n\t]+"; " ");
def q: "\"" + one + "\"";
def dur: (. | floor) as $s
  | if $s < 60 then "\($s)s" elif $s < 3600 then "\($s / 60 | floor)m"
    else "\($s / 3600 | floor)h \($s % 3600 / 60 | floor | tostring | if length < 2 then "0" + . else . end)m" end;
def by: ((if (.decided_by | type) == "object" then .decided_by.words else .decided_by end) // "")
  | if . != "" then " by " + . else "" end;
def why: if (.reason // "") != "" then ": " + (.reason | q) else "" end;
def st: if .status == "refused" and .refusal_code then "refused: \(.refusal_code)" else .status end;
def runs($n): if $n == 1 then "1 run" else "\($n) runs" end;
def wave_line($with_pkg): "Wave \(.wave // "-")" + (if $with_pkg then " of \(.package_id)" else "" end) + ": \(runs(.booked // .slots // 0))"
  + (if (.phones // []) | length > 0 then " on " + (.phones | join(", ")) else "" end)
  + (if .status != "done" then " (\(st))" else "" end) + (by | if . != "" then "," + . else . end) + why;
def step_text: "\(.type) (\(st))" + why;
def run_line: "Run \(.experiment_id), wave \(.wave // "-"), \(.phone // "no phone"), \(.status), \(.length_s // 0 | dur), \(.ads // 0) ads, \(.flags // 0) flags"
  + (if .verdict.summary then "; verdict: " + (.verdict.summary | q) else "" end)
  + ([.steps[]? | "; " + step_text] | join(""))
  + (if (.pending // []) | length > 0 then "; pending: " + (.pending | join(", ")) else "" end)
  + (if .review_queued then "; review queued" else "" end);
def state_line: "Campaign \(.id) \"\(.name | one)\" (project \(.project_name | one)): \(.state)"
  + (if .state == "queued" and .place_in_queue then ", place \(.place_in_queue) in the queue" else "" end)
  + (if (.state_reason // "") != "" then " (\(.state_reason | one))" else "" end);'

# The required fields of a draft, in the order they are listed: flag, then its plain-words description.
CM_REQUIRED='--name|the campaign'"'"'s name, unique in the project (1 to 80 characters)
--project|the project the campaign'"'"'s apps and runs belong to, by name or id
--goal|what the campaign should find, in plain words (20 to 4,000 characters)
--apps or --apps-file|the package ids of the apps to run, comma-separated or one per line in a file
--phones|the lab phones of the campaign, by name or id, comma-separated
--duration|the length of one run, in seconds or as 30m or 2h
--deadline or --run-until-stopped|the time every run should end by, with its UTC offset (2026-11-20T10:00-06:00), or no deadline
--zone|the IANA time zone of the deadline and the report, such as America/Chicago'

CM_DEADLINE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:[0-9]{2})$'
CM_WAIT_DEFAULT=540

cmd_campaign() {
  local sub="${1:-}"
  case "$sub" in
    '' | -h | --help | help)
      help_campaign
      exit 0
      ;;
  esac
  shift
  local a
  for a in "$@"; do
    case "$a" in
      --help | -h)
        help_campaign
        exit 0
        ;;
    esac
  done
  CITT_CMD="citt campaign $sub"
  case "$sub" in
    draft) _cm_draft "$@" ;;
    check) _cm_check "$@" ;;
    create) _cm_create "$@" ;;
    list) _cm_list "$@" ;;
    show) _cm_show "$@" ;;
    pause | resume) _cm_control "$sub" "$@" ;;
    stop) _cm_stop "$@" ;;
    edit) _cm_edit "$@" ;;
    app) _cm_app "$@" ;;
    review-run) _cm_review_run "$@" ;;
    report) _cm_report "$@" ;;
    pull) _cm_pull "$@" ;;
    watch) _cm_watch "$@" ;;
    *)
      CITT_CMD="citt campaign"
      usage_error "unknown subcommand $sub (run: citt campaign --help)"
      ;;
  esac
}

# --- helpers -------------------------------------------------------------------------------------------------------------

# _cm_help_or ARG: --help prints the synopsis; --json sets JSON output. Returns 0 when ARG was one of them.
_cm_common_flag() {
  case "$1" in
    --help | -h)
      help_campaign
      exit 0
      ;;
    --json)
      CITT_JSON=1
      return 0
      ;;
  esac
  return 1
}

# _cm_id RAW: a campaign id as given (cmp_41 or 41), else a usage error.
_cm_id() {
  printf '%s' "$1" | grep -Eq '^(cmp_)?[0-9]+$' || usage_error "a campaign id is cmp_N or N, such as cmp_41; got: $1 (see: citt campaign list)"
  printf '%s' "$1"
}

# _cm_secs VALUE: seconds of N, Ns, Nm or Nh; empty when VALUE is none of them.
_cm_secs() {
  case "$1" in
    *[!0-9smh]* | '' | [smh]*) return 0 ;;
  esac
  local n="${1%[smh]}"
  is_uint "$n" || return 0
  case "$1" in
    *m) printf '%s' $((n * 60)) ;;
    *h) printf '%s' $((n * 3600)) ;;
    *) printf '%s' "$n" ;;
  esac
}

# _cm_value TEXT: TEXT as JSON when it parses as a JSON value, else as a JSON string.
_cm_value() {
  local v
  v="$(jq -c . <<<"$1" 2>/dev/null)"
  if [ -n "$v" ] && [ "$(printf '%s\n' "$v" | wc -l | tr -d ' ')" = 1 ]; then
    printf '%s' "$v"
  else
    jq -nc --arg v "$1" '$v'
  fi
}

# _cm_template_add JSON FIELD=VALUE NULL_ON_EMPTY: JSON with FIELD set to VALUE; with an empty VALUE, FIELD is set to null
# when NULL_ON_EMPTY is 1 (an edit removes the field), else left out.
_cm_template_add() {
  local obj="$1" kv="$2" f v
  case "$kv" in
    *=*) ;;
    *) usage_error "--template takes FIELD=VALUE, such as navigator=independent; got: $kv" ;;
  esac
  f="${kv%%=*}"
  v="${kv#*=}"
  printf '%s' "$f" | grep -Eq '^[a-z_]+$' || usage_error "--template takes FIELD=VALUE with a field name such as help_wait_s; got: $kv"
  if [ -z "$v" ]; then
    if [ "$3" = 1 ]; then
      jq -c --arg f "$f" '.[$f] = null' <<<"$obj"
    else
      jq -c --arg f "$f" 'del(.[$f])' <<<"$obj"
    fi
    return
  fi
  jq -c --arg f "$f" --argjson v "$(_cm_value "$v")" '.[$f] = $v' <<<"$obj"
}

# _cm_list_json CSV NUMBERS: a JSON list of the comma-separated items; with NUMBERS 1, items of digits only are numbers.
_cm_list_json() {
  jq -nc --arg s "$1" --argjson n "${2:-0}" '$s | split(",") | map(gsub("^ +| +$"; "")) | map(select(. != ""))
    | map(if $n == 1 and test("^[0-9]+$") then tonumber else . end)'
}

# _cm_zone: the IANA zone of this machine ($TZ when it is a zone name, else the target of /etc/localtime), or nothing.
_cm_zone() {
  local z="${TZ:-}" t
  z="${z#:}"
  if printf '%s' "$z" | grep -Eq '^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$'; then
    printf '%s' "$z"
    return 0
  fi
  t="$(readlink /etc/localtime 2>/dev/null || true)"
  case "$t" in
    *zoneinfo/*) printf '%s' "${t##*zoneinfo/}" ;;
  esac
}

# _cm_spec_file FILE: the spec object of FILE, compact, else a usage error.
_cm_spec_file() {
  [ -n "$1" ] || usage_error "give the spec file written by citt campaign draft"
  [ -r "$1" ] || usage_error "cannot read $1"
  jq -ce 'if type == "object" then . else error("not an object") end' "$1" 2>/dev/null \
    || usage_error "$1 is not a campaign spec (a JSON object); write one with citt campaign draft"
}

# _cm_sha TEXT: the sha256 of TEXT in hex.
_cm_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}

# _cm_text: the message of a campaign error answer with its reason and next action, one line.
_cm_text() {
  jq -r '[.message, (if (.reason // "") != "" and .reason != .message then .reason else empty end), .next_action]
    | map(select(. != null and . != "") | tostring | gsub("[\r\n\t]+"; " ")) | join(" ")' "$RESP" 2>/dev/null
}

# _cm_refused HEAD: HEAD, then one block per refusal of the answer (field, reason, evidence, next action) on stderr; with
# --json the answer on stdout; exit 7.
_cm_refused() {
  err "$CITT_CMD: $1"
  jq -r '.refusals[]? | "  \(.field): \(.reason)"
      + (if .evidence != null then "\n    Evidence: \(.evidence | tojson)" else "" end)
      + (if (.next_action // "") != "" then "\n    Next: \(.next_action)" else "" end)' "$RESP" 2>/dev/null | clean >&2
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --arg m "$1" --argjson s "${CODE#0}" '. + {message: $m, http_status: $s}' "$RESP"
  fi
  exit 7
}

# _cm_call METHOD PATH [BODY_FILE]: http; an error answer of the campaign routes exits with its line and code (PLAN.md
# section 2), any other failure through fail_http.
_cm_call() {
  http "$@"
  ok && return 0
  local error text
  error="$(body_field '.error')"
  text="$(mask_server_text "$(_cm_text)")"
  text="$(plain_message "$text" "$error")"
  case "$CODE:$error" in
    422:spec_invalid | 422:spec_refused) _cm_refused "${text:-the campaign spec cannot run as written}" ;;
    403:campaigns_not_enabled | 403:campaigns_disabled | 404:campaigns_off) fail_out 3 "${text:-campaigns are not available for this account}" ;;
    503:campaigns_paused) fail_out 5 "${text:-campaigns are paused; try again later}" ;;
    404:campaign_not_found | 404:app_not_found | 404:run_not_found) fail_out 4 "${text:-not found among your campaigns}" ;;
    409:?*)
      local other
      other="$(body_field '.campaign | strings')"
      [ -z "$other" ] || text="$text (campaign $other)"
      fail_out 5 "${text:-the request conflicts with the state of the campaign; see: citt campaign show}"
      ;;
    422:?*) fail_out 7 "${text:-the service refused this change}" ;;
  esac
  fail_http
}

# _cm_body JSON: a private temp file holding JSON, for a request body.
_cm_body() {
  local f
  f="$(tmpfile "body.$RANDOM")"
  printf '%s\n' "$1" >"$f"
  printf '%s' "$f"
}

# _cm_print_doc: the state line and the next action of the show document in RESP (or --json: the document).
_cm_print_doc() {
  if [ "$CITT_JSON" = 1 ]; then
    jq -c . "$RESP"
    return 0
  fi
  jq -r "$CM_JQ"' (.campaign // .) | state_line, (if .next_action then "Next: \(.next_action)" else empty end)' "$RESP"
}

# _cm_report_get ID: GET /campaigns/{id}/report in the customer view into RESP.
_cm_report_get() {
  _cm_call GET "$CITT_V1/campaigns/$1/report?view=customer"
  jq -e '.report | type == "object"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
}

# _cm_no_staff FILE: FILE's report document without the staff section (a staff account's answer, D-18).
_cm_no_staff() {
  jq -c 'del(.report.measured.staff)' "$1"
}

# --- draft ---------------------------------------------------------------------------------------------------------------

_cm_draft() {
  local name="" project="" goal="" apps="" apps_file="" platform="" page="" phones="" duration="" split="" state="" country=""
  local deadline="" until=0 zone="" out="" rerun="" template='{}' look='[]' t k v
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      --name | --project | --goal | --apps | --apps-file | --platform | --page-size | --phones | --duration | --split | --state | \
        --country | --deadline | --zone | --out | --rerun-states | --template | --look-for)
        need_value "$1" $#
        case "$1" in
          --name) name="$2" ;;
          --project) project="$2" ;;
          --goal) goal="$2" ;;
          --apps) apps="$2" ;;
          --apps-file) apps_file="$2" ;;
          --platform) platform="$2" ;;
          --page-size) page="$2" ;;
          --phones) phones="$2" ;;
          --duration) duration="$2" ;;
          --split) split="$2" ;;
          --state) state="$2" ;;
          --country) country="$2" ;;
          --deadline) deadline="$2" ;;
          --zone) zone="$2" ;;
          --out) out="$2" ;;
          --rerun-states) rerun="$2" ;;
          --template) template="$(_cm_template_add "$template" "$2" 0)" || exit 2 ;;
          --look-for)
            case "$2" in
              *:?*) ;;
              *) usage_error "--look-for takes KIND:VALUE with KIND flag, key, host, ad_network or text; got: $2" ;;
            esac
            k="${2%%:*}"
            v="${2#*:}"
            case "$k" in
              flag | key | host | ad_network | text) ;;
              *) usage_error "--look-for takes KIND:VALUE with KIND flag, key, host, ad_network or text; got: $2" ;;
            esac
            look="$(jq -c --arg k "$k" --arg v "$v" '. + [{kind: $k, value: $v}]' <<<"$look")"
            ;;
        esac
        shift
        ;;
      --run-until-stopped) until=1 ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  [ -n "$out" ] || usage_error "give --out FILE, the spec file to write"
  [ -z "$deadline" ] || [ "$until" = 0 ] || usage_error "give --deadline or --run-until-stopped, not both"
  if [ -n "$deadline" ] && ! printf '%s' "$deadline" | grep -Eq "$CM_DEADLINE_RE"; then
    usage_error "--deadline needs a time with its UTC offset, such as 2026-11-20T10:00-06:00; got: $deadline"
  fi
  case "$platform" in '' | android | ios) ;; *) usage_error "--platform takes android or ios, got: $platform" ;; esac
  [ -z "$page" ] || is_uint "$page" || usage_error "--page-size takes a number of apps, got: $page"
  for t in duration split; do
    eval "v=\$$t"
    [ -n "$v" ] || continue
    k="$(_cm_secs "$v")"
    [ -n "$k" ] || usage_error "--$t takes seconds or a duration such as 30m or 2h, got: $v"
    eval "$t=\$k"
  done
  local list='[]'
  [ -z "$apps" ] || list="$(_cm_list_json "$apps")"
  if [ -n "$apps_file" ]; then
    [ -r "$apps_file" ] || usage_error "cannot read $apps_file"
    list="$(jq -nc --argjson l "$list" --rawfile f "$apps_file" \
      '$l + ($f | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "" and (startswith("#") | not))))')"
  fi
  [ -n "$zone" ] || zone="$(_cm_zone)"
  local spec
  spec="$(jq -nc --arg name "$name" --arg project "$project" --arg goal "$goal" --argjson look "$look" --argjson list "$list" \
    --arg platform "$platform" --arg page "$page" --argjson phones "$(_cm_list_json "$phones" 1)" --arg dur "$duration" \
    --arg split "$split" --arg state "$state" --arg country "$country" --argjson tpl "$template" \
    --argjson rerun "$(_cm_list_json "$rerun" | jq -c 'map(ascii_upcase)')" --arg deadline "$deadline" --argjson until "$until" \
    --arg zone "$zone" '
    {}
    + (if $name != "" then {name: $name} else {} end)
    + (if $project != "" then {project: (if $project | test("^[0-9]+$") then ($project | tonumber) else $project end)} else {} end)
    + (if $goal != "" then {goal: $goal} else {} end)
    + (if ($look | length) > 0 then {look_for: $look} else {} end)
    + (if ($list | length) > 0 then {apps: ({list: (if $platform == "" then $list else $list | map({package_id: ., platform: $platform}) end)}
        + (if $page != "" then {page_size: ($page | tonumber)} else {} end))} else {} end)
    + (if ($phones | length) > 0 then {phones: $phones} else {} end)
    + ((({} + (if $dur != "" then {duration_s: ($dur | tonumber)} else {} end)
          + (if $split != "" then {split_s: ($split | tonumber)} else {} end)
          + (if $state != "" then {exit_state: ($state | ascii_upcase)} else {} end)
          + (if $country != "" then {exit_country: ($country | ascii_upcase)} else {} end)) + $tpl) as $t
        | if ($t | length) > 0 then {template: $t} else {} end)
    + (if ($rerun | length) > 0 then {rerun_states: $rerun} else {} end)
    + (if $deadline != "" then {deadline: $deadline} else {} end)
    + (if $until == 1 then {run_until_stopped: true} else {} end)
    + (if $zone != "" then {zone: $zone} else {} end)')" || die 1 "the spec could not be written"
  (umask 077 && jq . <<<"$spec" >"$out") || die 1 "cannot write $out"
  local missing=""
  while IFS='|' read -r k v; do
    case "$k" in
      --name) [ -n "$name" ] || missing="$missing  $k: $v"$'\n' ;;
      --project) [ -n "$project" ] || missing="$missing  $k: $v"$'\n' ;;
      --goal) [ -n "$goal" ] || missing="$missing  $k: $v"$'\n' ;;
      --apps*) [ "$(jq '.apps.list // [] | length' <<<"$spec")" -gt 0 ] || missing="$missing  $k: $v"$'\n' ;;
      --phones) [ "$(jq '.phones // [] | length' <<<"$spec")" -gt 0 ] || missing="$missing  $k: $v"$'\n' ;;
      --duration) [ -n "$duration" ] || jq -e '.template.duration_s' <<<"$spec" >/dev/null || missing="$missing  $k: $v"$'\n' ;;
      --deadline*) [ -n "$deadline" ] || [ "$until" = 1 ] || missing="$missing  $k: $v"$'\n' ;;
      --zone) [ -n "$zone" ] || missing="$missing  $k: $v"$'\n' ;;
    esac
  done <<<"$CM_REQUIRED"
  if [ -n "$missing" ]; then
    err "$CITT_CMD: wrote $out; missing required fields:"
    printf '%s' "$missing" | clean >&2
    err "$CITT_CMD: run citt campaign draft again with every field and --out $(shq "$out"), then check it with citt campaign check $(shq "$out")"
    if [ "$CITT_JSON" = 1 ]; then
      jq -nc --arg m "missing required fields" --arg miss "$missing" --argjson spec "$spec" --arg out "$out" \
        '{error: "missing_fields", message: $m, missing: ($miss | split("\n") | map(select(. != "") | sub("^  "; "") | split(": ")[0])),
          file: $out, spec: $spec}'
    fi
    exit 2
  fi
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --arg out "$out" '{file: $out, spec: .}' <<<"$spec"
    return 0
  fi
  jq -r --arg out "$out" "$CM_JQ"' "Wrote \($out): campaign \(.name | q) in project \(.project | tostring | q), \(.apps.list | length) apps, \(.phones | length) phones, runs of \(.template.duration_s | dur), "
    + (if .deadline then "deadline \(.deadline) (\(.zone))" else "until stopped (\(.zone))" end) + "."' <<<"$spec"
  printf 'Next: citt campaign check %s\n' "$(shq "$out")"
}

# --- check ---------------------------------------------------------------------------------------------------------------

_cm_check() {
  local file=""
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$file" ] || usage_error "give one spec file"
        file="$1"
        ;;
    esac
    shift
  done
  local spec body
  spec="$(_cm_spec_file "$file")" || exit 2
  body="$(_cm_body "$(jq -c '{spec: .}' <<<"$spec")")"
  need_auth
  _cm_call POST "$CITT_V1/campaigns?dry_run=1" "$body"
  jq -e '.dry_run == true' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  local ok
  ok="$(body_field '.ok')"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c . "$RESP"
  else
    jq -r "$CM_JQ"'(if .ok then "The spec is accepted." else "The spec cannot run as written; each refusal is listed on stderr." end),
      ((.estimate // {}) as $e | "Apps: \($e.apps_total // 0)" + (if $e.apps_page_1 then " (\($e.apps_page_1 | length) on the first page)" else "" end)),
      (if (.estimate.phones // []) | length > 0 then "Phones:" else empty end)' "$RESP" | clean
    if [ "$(jq '.estimate.phones // [] | length' "$RESP")" -gt 0 ]; then
      jq -c '[["NAME", "STATUS", "SHARED", "QUEUED", "RUNNING", "NOTE"]]
        + [.estimate.phones[] | [.name, .status, (if .shared then "shared" else null end), .queued_runs, .running_runs, (.unavailable // "")]]' \
        "$RESP" | table | clean
    fi
    jq -r "$CM_JQ"'(.estimate // {}) as $e
      | (if $e.hours_to_deadline != null then "Hours to the deadline: \($e.hours_to_deadline)" else empty end),
        (if $e.device_hours_available != null then "Device hours available before the deadline: \($e.device_hours_available)"
          + (if $e.device_hours_basis then " (\($e.device_hours_basis | one))" else "" end) else empty end),
        (if $e.latest_start then "\($e.latest_start.text): \($e.latest_start.at)" else empty end),
        (if $e.measured_call_costs.note then $e.measured_call_costs.note
          + ([("review", "plan", "question") as $k | $e.measured_call_costs[$k] | select(. != null and .mean_usd != null)
              | " \($k) mean $\(.mean_usd)"] | join(",")) else empty end)' "$RESP" | clean
    [ "$ok" != true ] || printf 'Next: citt campaign create %s --start-now\n' "$(shq "$file")"
  fi
  if [ "$ok" != true ]; then
    # the --json document is printed above; the refusal blocks go to stderr
    CITT_JSON=0
    _cm_refused "the spec cannot run as written; correct the fields below and run citt campaign check $(shq "$file") again"
  fi
}

# --- create --------------------------------------------------------------------------------------------------------------

_cm_create() {
  local file="" start=0 wait=0 key="" timeout="$CM_WAIT_DEFAULT"
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      --start-now) start=1 ;;
      --wait-first) wait=1 ;;
      --idempotency-key | --timeout)
        need_value "$1" $#
        case "$1" in
          --idempotency-key) key="$2" ;;
          --timeout) timeout="$2" ;;
        esac
        shift
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$file" ] || usage_error "give one spec file"
        file="$1"
        ;;
    esac
    shift
  done
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  [ "$wait" = 0 ] || [ "$start" = 1 ] || usage_error "--wait-first needs --start-now: a campaign created without it does not start"
  local spec body
  spec="$(_cm_spec_file "$file")" || exit 2
  [ -n "$key" ] || key="cli-$(_cm_sha "$spec" | cut -c1-32)"
  body="$(_cm_body "$(jq -c --argjson s "$start" --arg k "$key" '{spec: ., start_now: ($s == 1), idempotency_key: $k}' <<<"$spec")")"
  need_auth
  _cm_call POST "$CITT_V1/campaigns" "$body"
  jq -e '.campaign.id' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  local id created doc
  id="$(body_field '.campaign.id')"
  created="$(body_field '.created')"
  doc="$(tmpfile create.json)"
  cp "$RESP" "$doc"
  if [ "$wait" = 0 ]; then
    _cm_print_doc
    [ "$CITT_JSON" = 1 ] || [ "$created" = true ] || printf 'This campaign was already created from this spec; it is shown as it is.\n'
    return 0
  fi
  if [ "$CITT_JSON" != 1 ]; then
    _cm_print_doc
    [ "$created" = true ] || printf 'This campaign was already created from this spec; it is shown as it is.\n'
  fi
  _cm_wait_first "$id" "$timeout" "citt campaign create $(shq "$file") --start-now --wait-first"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --slurpfile r <(_cm_no_staff "$RESP") '. + {report: $r[0]}' "$doc"
  else
    printf '\n'
    jq -r '.markdown // ""' "$RESP"
  fi
}

# _cm_wait_first ID TIMEOUT RERUN: polls the report until the first plan call (a wave booked) and the first review (a run whose
# latest call is valid, invalid or failed) are done, or the campaign ends or pauses; exit 12 with RERUN after TIMEOUT s.
_cm_wait_first() {
  local id="$1" timeout="$2" rerun="$3" start left plan=0 first ended st waves
  start="$(now_s)"
  wait_deadline "$timeout" "the first review of campaign $id is not done after $timeout s; re-run: $rerun"
  while :; do
    _cm_report_get "$id"
    waves="$(jq '.report.waves // [] | length' "$RESP")"
    if [ "$plan" = 0 ] && { [ "$waves" -gt 0 ] || [ "$(jq '.report.runs // [] | length' "$RESP")" -gt 0 ]; }; then
      if [ "$waves" = 1 ]; then err "$CITT_CMD: first plan call done: 1 wave booked"; else err "$CITT_CMD: first plan call done: $waves waves booked"; fi
      plan=1
    fi
    first="$(jq -r '[.report.runs[]? | select((.latest_call.status // "") as $s | ["valid", "invalid", "failed"] | index($s))][0].experiment_id // empty' "$RESP")"
    if [ -n "$first" ]; then
      err "$CITT_CMD: first review done: run $first"
      break
    fi
    ended="$(jq -r '.report.header.ended // false' "$RESP")"
    st="$(jq -r '.report.header.state // ""' "$RESP")"
    if [ "$ended" = true ] || [ "$st" = paused ] || [ "$st" = draft ]; then
      err "$CITT_CMD: the campaign is $st before a first review: $(jq -r '.report.header.end_text // ""' "$RESP" | clean)"
      break
    fi
    left=$((timeout - ($(now_s) - start)))
    if [ "$left" -le 0 ]; then
      wait_done
      [ "$CITT_JSON" != 1 ] || jq -nc --arg m "$rerun" '{error: "timeout", message: ("re-run: " + $m), exit: 12}'
      err "$CITT_CMD: the first review of campaign $id is not done after $timeout s; re-run: $rerun"
      exit 12
    fi
    poll_sleep "" "$left"
  done
  wait_done
}

# --- list and show -------------------------------------------------------------------------------------------------------

_cm_list() {
  local state="" n
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --state)
        need_value "$1" $#
        state="$2"
        shift
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  check_project_flags optional
  need_auth
  PROJECT_ID=""
  if [ -n "$OPT_PROJECT" ] || [ -n "$OPT_PROJECT_ID" ]; then
    resolve_project
  fi
  _cm_call GET "$CITT_V1/campaigns$(query project "$PROJECT_ID" state "$state")"
  jq -e '.campaigns | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c . "$RESP"
    return 0
  fi
  if [ "$(jq '.campaigns | length' "$RESP")" = 0 ]; then
    printf 'No campaigns%s. Describe one with citt campaign draft.\n' "${state:+ in state $state}"
    return 0
  fi
  jq -c --argjson L "$(local_times "$RESP")" "$JQ_LT$CM_JQ"' [["ID", "NAME", "PROJECT", "STATE", "PHONES", "APPS", "DEADLINE"]]
    + [.campaigns[] | [.id, (.name | one), (.project_name | one), (.state + (if .end_reason then ": \(.end_reason)" else "" end)),
        .phones, .apps, (if .deadline_at then (.deadline_at | lt) else "until stopped" end)]]' "$RESP" | table
}

_cm_show() {
  local id="" app=""
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      --app)
        need_value "$1" $#
        app="$2"
        shift
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$id" ] || usage_error "give one campaign id"
        id="$(_cm_id "$1")" || exit 2
        ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "give a campaign id, such as cmp_41 (see: citt campaign list)"
  need_auth
  _cm_call GET "$CITT_V1/campaigns/$id"
  jq -e '.id' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  local doc rep
  doc="$(tmpfile show.json)"
  cp "$RESP" "$doc"
  _cm_report_get "$id"
  rep="$(tmpfile show_report.json)"
  _cm_no_staff "$RESP" >"$rep"
  if [ -n "$app" ] && ! jq -e --arg p "$app" '(.apps.items // []) | map(.package_id) | index($p)' "$doc" >/dev/null 2>&1 \
    && ! jq -e --arg p "$app" '(.report.apps // []) | map(.package_id) | index($p)' "$rep" >/dev/null 2>&1; then
    die 4 "$app is not an app of campaign $id; list its apps with citt campaign show $id"
  fi
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --slurpfile r "$rep" --arg app "$app" '. + {report: $r[0].report}
      | if $app != "" then . + {app: {package_id: $app,
          state: ([.report.apps[]? | select(.package_id == $app)][0]),
          waves: [.report.waves[]? | select(.package_id == $app)],
          runs: [.report.runs[]? | select(.package_id == $app)]}} else . end' "$doc"
    return 0
  fi
  jq -r --slurpfile r "$rep" "$CM_JQ"' . as $d | $r[0].report as $rep
    | state_line,
      "Deadline: " + (if .deadline_local then "\(.deadline_local) (\(.zone))" else "none, it runs until stopped" end),
      "Phones: " + ([.phones[] | .name // "phone \(.device_id)"] | join(", ") | if . == "" then "none" else . end),
      ([$rep.runs[]? | select(.status | IN("queued", "claimed", "running", "stopping")) | .phone] | unique) as $busy
      | "Idle phones: " + ([.phones[] | (.name // "phone \(.device_id)") | select(. as $n | $busy | index($n) | not)] | join(", ")
          | if . == "" then "none" else . end),
      "Apps: " + ([.apps.counts | to_entries[] | "\(.value) \(.key)"] | join(", ") | if . == "" then "none" else . end),
      (if ($rep.measured.runs_by_state // {}) | length > 0 then "Runs: " + ([$rep.measured.runs_by_state | to_entries[] | "\(.value) \(.key)"] | join(", ")) else empty end),
      (if .next_action then "Next: \(.next_action)" else empty end)' "$doc" | clean
  [ -n "$app" ] || return 0
  printf '\n'
  jq -r --arg p "$app" "$CM_JQ"' .report as $rep
    | ([$rep.apps[]? | select(.package_id == $p)][0]) as $a
    | "\($p): \($a.state // "-")" + (if $a.decision then "; \($a.decision.type)" + ($a.decision | by) + ($a.decision | why) else "" end),
      ($rep.waves[]? | select(.package_id == $p) | wave_line(false)),
      ($rep.runs[]? | select(.package_id == $p) | run_line),
      (if ([$rep.runs[]? | select(.package_id == $p)] | length) == 0 then "No run of this app yet." else empty end)' "$rep" | clean
}

# --- pause, resume, stop -------------------------------------------------------------------------------------------------

_cm_one_id() {
  local id=""
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$id" ] || usage_error "give one campaign id"
        id="$(_cm_id "$1")" || exit 2
        ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "give a campaign id, such as cmp_41 (see: citt campaign list)"
  printf '%s' "$id"
}

_cm_control() {
  local action="$1" id
  shift
  id="$(_cm_one_id "$@")" || exit 2
  case " $* " in *" --json "*) CITT_JSON=1 ;; esac
  need_auth
  _cm_call POST "$CITT_V1/campaigns/$id/$action"
  _cm_print_doc | clean
}

_cm_stop() {
  local id="" now=0 body=""
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      --now) now=1 ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$id" ] || usage_error "give one campaign id"
        id="$(_cm_id "$1")" || exit 2
        ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "give a campaign id, such as cmp_41 (see: citt campaign list)"
  [ "$now" = 0 ] || body="$(_cm_body '{"now":true}')"
  need_auth
  _cm_call POST "$CITT_V1/campaigns/$id/stop" "$body"
  _cm_print_doc | clean
  [ "$CITT_JSON" = 1 ] || [ "$now" = 1 ] || printf 'Runs in flight end as they do; stop them now with citt campaign stop %s --now.\n' "$id"
  exit 14
}

# --- edit, app, review-run -----------------------------------------------------------------------------------------------

_cm_edit() {
  local id="" deadline="" zone="" until=0 phones="" have_phones=0 rerun="" have_rerun=0 goal="" have_goal=0 template='{}' tpl=0
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      --deadline | --zone | --phones | --rerun-states | --goal | --template)
        need_value "$1" $#
        case "$1" in
          --deadline) deadline="$2" ;;
          --zone) zone="$2" ;;
          --phones) phones="$2" have_phones=1 ;;
          --rerun-states) rerun="$2" have_rerun=1 ;;
          --goal) goal="$2" have_goal=1 ;;
          --template)
            template="$(_cm_template_add "$template" "$2" 1)" || exit 2
            tpl=1
            ;;
        esac
        shift
        ;;
      --run-until-stopped) until=1 ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$id" ] || usage_error "give one campaign id"
        id="$(_cm_id "$1")" || exit 2
        ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "give a campaign id, such as cmp_41 (see: citt campaign list)"
  [ -z "$deadline" ] || [ "$until" = 0 ] || usage_error "give --deadline or --run-until-stopped, not both"
  [ -z "$zone" ] || [ -n "$deadline" ] || usage_error "--zone goes with --deadline"
  if [ -n "$deadline" ] && ! printf '%s' "$deadline" | grep -Eq "$CM_DEADLINE_RE"; then
    usage_error "--deadline needs a time with its UTC offset, such as 2026-11-20T10:00-06:00; got: $deadline"
  fi
  if [ -z "$deadline" ] && [ "$until" = 0 ] && [ "$have_phones" = 0 ] && [ "$have_rerun" = 0 ] && [ "$have_goal" = 0 ] && [ "$tpl" = 0 ]; then
    usage_error "give at least one of --deadline, --run-until-stopped, --phones, --rerun-states, --template FIELD=VALUE and --goal"
  fi
  local body
  body="$(jq -nc --arg d "$deadline" --arg z "$zone" --argjson u "$until" --argjson hp "$have_phones" \
    --argjson phones "$(_cm_list_json "$phones" 1)" --argjson hr "$have_rerun" \
    --argjson rerun "$(_cm_list_json "$rerun" | jq -c 'map(ascii_upcase)')" --argjson hg "$have_goal" --arg goal "$goal" \
    --argjson tpl "$tpl" --argjson t "$template" '{}
    + (if $d != "" then {deadline: $d} else {} end) + (if $z != "" then {zone: $z} else {} end)
    + (if $u == 1 then {run_until_stopped: true} else {} end) + (if $hp == 1 then {phones: $phones} else {} end)
    + (if $hr == 1 then {rerun_states: $rerun} else {} end) + (if $hg == 1 then {goal: $goal} else {} end)
    + (if $tpl == 1 then {template: $t} else {} end)')"
  need_auth
  _cm_call PATCH "$CITT_V1/campaigns/$id" "$(_cm_body "$body")"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c . "$RESP"
    return 0
  fi
  jq -r "$CM_JQ"' state_line,
    (if (.edited // []) | length > 0 then "Spec version \(.spec_version): \(.edited | join(", ")) edited; future bookings use it."
     else "Nothing changed: the edit equals the stored spec." end),
    (if .next_action then "Next: \(.next_action)" else empty end)' "$RESP" | clean
}

_cm_app() {
  local action="${1:-}" id="" pkg=""
  case "$action" in
    restore | hold) shift ;;
    --help | -h) _cm_common_flag "$action" ;;
    *) usage_error "citt campaign app takes restore or hold, then the campaign id and the package id; got: ${action:-nothing}" ;;
  esac
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      -*) usage_error "unknown option $1" ;;
      *)
        if [ -z "$id" ]; then
          id="$(_cm_id "$1")" || exit 2
        elif [ -z "$pkg" ]; then
          pkg="$1"
        else
          usage_error "give the campaign id and one package id"
        fi
        ;;
    esac
    shift
  done
  { [ -n "$id" ] && [ -n "$pkg" ]; } || usage_error "give the campaign id and the package id: citt campaign app $action cmp_41 com.example.app"
  need_auth
  _cm_call POST "$CITT_V1/campaigns/$id/apps/$(urlenc "$pkg")/$action"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c . "$RESP"
    return 0
  fi
  jq -r '"\(.app.package_id): \(.app.from) -> \(.app.state)"' "$RESP" | clean
  if [ "$action" = hold ]; then
    printf 'The campaign books no run of this app until citt campaign app restore %s %s.\n' "$id" "$(shq "$pkg")"
  fi
}

_cm_review_run() {
  local id="" run=""
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      -*) usage_error "unknown option $1" ;;
      *)
        if [ -z "$id" ]; then
          id="$(_cm_id "$1")" || exit 2
        elif [ -z "$run" ]; then
          is_uint "$1" || usage_error "the run is its number, such as 5120 (see: citt campaign show $id --app PACKAGE); got: $1"
          run="$1"
        else
          usage_error "give the campaign id and one run"
        fi
        ;;
    esac
    shift
  done
  { [ -n "$id" ] && [ -n "$run" ]; } || usage_error "give the campaign id and the run: citt campaign review-run cmp_41 5120"
  need_auth
  _cm_call POST "$CITT_V1/campaigns/$id/reviews/$run/retry"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c . "$RESP"
    return 0
  fi
  jq -r --arg id "$id" '"Review of run \(.experiment_id) queued again (round \(.round)); follow it with citt campaign watch \($id)."' "$RESP"
}

# --- report --------------------------------------------------------------------------------------------------------------

_cm_report() {
  local id="" wait=0 timeout="$CM_WAIT_DEFAULT" start left
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      --wait) wait=1 ;;
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$id" ] || usage_error "give one campaign id"
        id="$(_cm_id "$1")" || exit 2
        ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "give a campaign id, such as cmp_41 (see: citt campaign list)"
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  need_auth
  start="$(now_s)"
  [ "$wait" = 0 ] || wait_deadline "$timeout" "campaign $id has not ended after $timeout s; re-run: citt campaign report $id --wait"
  while :; do
    _cm_report_get "$id"
    [ "$wait" = 1 ] || break
    if [ "$(jq -r '.final == true or .report.header.state == "done"' "$RESP")" = true ]; then
      break
    fi
    left=$((timeout - ($(now_s) - start)))
    if [ "$left" -le 0 ]; then
      wait_done
      [ "$CITT_JSON" != 1 ] || _cm_no_staff "$RESP"
      err "$CITT_CMD: campaign $id has not ended after $timeout s; re-run: citt campaign report $id --wait"
      exit 12
    fi
    poll_sleep "" "$left"
  done
  wait_done
  if [ "$CITT_JSON" = 1 ]; then
    _cm_no_staff "$RESP"
  else
    jq -r '.markdown // ""' "$RESP"
  fi
}

# --- pull ----------------------------------------------------------------------------------------------------------------

# CM_DECISIONS: jq program, the report's actions with a reason as one JSON object per line, deduped by action_id.
CM_DECISIONS='[(.report.waves[]? | {action_id, kind: "wave", type: "book_runs", campaign_app_id, package_id, wave, status,
      booked, phones, overrides, reason, decided_by: .decided_by.words, call_id: .decided_by.call_id}),
    (.report.runs[]? as $r | $r.steps[]? | {action_id, kind: "run_step", type, experiment_id: $r.experiment_id,
      campaign_app_id, package_id: $r.package_id, wave: $r.wave, status, refusal_code, reason, origin,
      decided_by: .decided_by.words, call_id}),
    (.report.apps[]? as $a | select($a.decision) | $a.decision | {action_id, kind: "app", type, campaign_app_id: $a.campaign_app_id,
      package_id: $a.package_id, status, refusal_code, reason, origin, decided_by: .decided_by.words, call_id})]
  | map(select(.action_id != null)) | unique_by(.action_id) | .[]'

_cm_pull() {
  local id="" hits=0 out="" groups=""
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      --hits-only) hits=1 ;;
      --out | --groups)
        need_value "$1" $#
        case "$1" in
          --out) out="$2" ;;
          --groups) groups="$2" ;;
        esac
        shift
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$id" ] || usage_error "give one campaign id"
        id="$(_cm_id "$1")" || exit 2
        ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "give a campaign id, such as cmp_41 (see: citt campaign list)"
  need_auth
  _cm_call GET "$CITT_V1/campaigns/$id"
  jq -e '.id' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  local pid
  pid="$(body_field '.id')"
  printf '%s' "$pid" | grep -Eq '^cmp_[0-9]+$' || pid="$id"
  [ -n "$out" ] || out="citt-campaigns/$pid"
  mkdir -p "$out" 2>/dev/null || die 1 "cannot create $out"
  jq . "$RESP" >"$out/campaign.json" || die 1 "cannot write $out/campaign.json"
  _cm_report_get "$id"
  local rep
  rep="$(tmpfile pull_report.json)"
  _cm_no_staff "$RESP" >"$rep"
  jq -c "$CM_DECISIONS" "$rep" >"$out/decisions.jsonl" || die 1 "cannot write $out/decisions.jsonl"
  jq -r '.markdown // ""' "$rep" >"$out/report.md" || die 1 "cannot write $out/report.md"
  local runs
  runs="$(jq -r --argjson h "$hits" '.report as $r | ([$r.apps[]? | select(.state == "hit") | .package_id]) as $hit
    | [$r.runs[]? | select($h == 0 or (.package_id as $p | $hit | index($p))) | .experiment_id] | unique | .[]' "$rep")"
  if [ "$CITT_JSON" != 1 ]; then
    printf 'Wrote %s/campaign.json, %s/decisions.jsonl (%s decisions) and %s/report.md\n' "$out" "$out" \
      "$(wc -l <"$out/decisions.jsonl" | tr -d ' ')" "$out"
  fi
  if [ -z "$runs" ]; then
    if [ "$CITT_JSON" = 1 ]; then
      jq -nc --arg o "$out" '{dir: $o, files: ["campaign.json", "decisions.jsonl", "report.md"], runs: []}'
    else
      if [ "$hits" = 1 ]; then printf 'The campaign has no run of an app with a hit yet: no run to sync.\n'; else printf 'The campaign has no run yet: no run to sync.\n'; fi
    fi
    return 0
  fi
  local -a args
  args=(capture-sync --dir "$out/runs")
  local r
  for r in $runs; do args+=(--run "$r"); done
  [ -z "$groups" ] || args+=(--groups "$groups")
  [ "$CITT_JSON" != 1 ] || args+=(--json)
  [ "$CITT_JSON" = 1 ] || printf 'Syncing %s run(s) into %s/runs with citt capture-sync\n' "$(printf '%s\n' "$runs" | wc -l | tr -d ' ')" "$out"
  "$CITT_LIB/../citt" ${args[@]+"${args[@]}"}
}

# --- watch ---------------------------------------------------------------------------------------------------------------

_cm_watch() {
  local id="" timeout="$CM_WAIT_DEFAULT"
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$id" ] || usage_error "give one campaign id"
        id="$(_cm_id "$1")" || exit 2
        ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "give a campaign id, such as cmp_41 (see: citt campaign list)"
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  need_auth
  local dir="$CITT_STATE/campaign-watch" seen_file start left doc rep seen st line new
  (umask 077 && mkdir -p "$dir") || die 1 "cannot create $dir"
  seen_file="$dir/${id#cmp_}.json"
  doc="$(tmpfile watch_doc.json)"
  rep="$(tmpfile watch_report.json)"
  start="$(now_s)"
  wait_deadline "$timeout" "campaign $id is still running after $timeout s; re-run: citt campaign watch $id"
  while :; do
    _cm_call GET "$CITT_V1/campaigns/$id"
    jq -e '.id' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
    cp "$RESP" "$doc"
    _cm_report_get "$id"
    _cm_no_staff "$RESP" >"$rep"
    seen='{"state":"","actions":[]}'
    [ ! -f "$seen_file" ] || seen="$(jq -c '{state: (.state // ""), actions: (.actions // [])}' "$seen_file" 2>/dev/null || printf '%s' "$seen")"
    st="$(jq -r '.state + "|" + (.state_reason // "")' "$doc")"
    new="$(jq -c --argjson seen "$seen" "$CM_DECISIONS" "$rep" | jq -sc --argjson seen "$seen" 'map(select(.action_id as $a | $seen.actions | index($a) | not))')"
    if [ "$CITT_JSON" = 1 ]; then
      if [ "$st" != "$(jq -r .state <<<"$seen")" ] || [ "$new" != "[]" ]; then
        jq -nc --slurpfile d "$doc" --argjson n "$new" '{campaign: $d[0].id, state: $d[0].state, state_reason: $d[0].state_reason, decisions: $n}'
      fi
    else
      if [ "$st" != "$(jq -r .state <<<"$seen")" ]; then
        jq -r '"\(.id): \(.state)" + (if (.state_reason // "") != "" then " (\(.state_reason | gsub("[\r\n\t]+"; " ")))" else "" end)' "$doc" | clean
      fi
      jq -r "$CM_JQ"' .[] | if .kind == "wave" then wave_line(true)
        elif .kind == "run_step" then "Run \(.experiment_id) (\(.package_id)): \(.type) (\(st))" + by + why
        else "\(.package_id): \(.type) (\(st))" + by + why end' <<<"$new" | clean
    fi
    (umask 077 && t="$(mktemp "$seen_file.XXXXXX")" && jq -nc --arg s "$st" --argjson seen "$seen" --argjson n "$new" \
      '{state: $s, actions: ($seen.actions + [$n[].action_id] | unique)}' >"$t" && mv "$t" "$seen_file")
    line="$(jq -r .state "$doc")"
    if [ "$line" = "done" ]; then
      wait_done
      [ "$CITT_JSON" = 1 ] || printf 'Read the report with citt campaign report %s and pull the data with citt campaign pull %s --hits-only\n' "$id" "$id"
      return 0
    fi
    left=$((timeout - ($(now_s) - start)))
    if [ "$left" -le 0 ]; then
      wait_done
      err "$CITT_CMD: campaign $id is still running after $timeout s; re-run: citt campaign watch $id"
      exit 12
    fi
    poll_sleep "" "$left"
  done
}
