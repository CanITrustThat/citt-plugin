#!/usr/bin/env bash
# lib/cmd-campaign.sh: citt campaign (NP-2012, CAMP-12; services/netproof/planning/campaigns/PLAN.md section 2). A campaign is
# described in a spec file (draft), checked as a dry run (check, POST /campaigns?dry_run=1), created (create, POST /campaigns),
# listed and shown (GET /campaigns, GET /campaigns/{id}), paused, resumed, stopped and edited (POST .../pause|resume|stop,
# PATCH /campaigns/{id}), its apps held and restored (POST .../apps/{app}/hold|restore), a run's review queued again
# (POST .../reviews/{run}/retry), and its report read, waited for, watched and pulled with the runs (GET .../report, the
# customer view, then citt capture-sync of the runs). TASK-1601: the arms of a campaign (the --arm flags of draft and edit, the
# Arms lines, the app × arm table of report) are in lib/cmd-campaign-arms.sh, which the script loads with this file.
# shellcheck shell=bash disable=SC2016

# CM_JQ: jq definitions for the printed lines. `one`: model or customer text on one line; `q`: that text in double quotes.
# TASK-1592: `place_words` is the place of a queued campaign from the `queue` block (place P of Q and the number of campaigns that
# run at once), or the place alone from a service without the block; `planning_lines`, `attention_lines` and `phone_time_line`
# print the `planning` and `phone_time` blocks of the show document and nothing for a document without them. `fx(d)`: a number
# with d decimals. The reason of a plan call that booked nothing is the one of its last `none` step, else of its last step, as
# in the service's report. TASK-1601: `arm_names` and `arm_name` are the arms of a wave and the arm of a run, empty for a
# campaign without arms.
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
def arm_names: (if (.arms | type) == "array" then .arms else [] end) | map(one)
  | if length == 0 then "" elif length == 1 then ", arm \(.[0])" else ", arms " + join(", ") end;
def arm_name: if (.arm // "") != "" then ", arm \(.arm | one)" else "" end;
def wave_line($with_pkg): "Wave \(.wave // "-")" + (if $with_pkg then " of \(.package_id)" else "" end) + arm_names + ": \(runs(.booked // .slots // 0))"
  + (if (.phones // []) | length > 0 then " on " + (.phones | join(", ")) else "" end)
  + (if .status != "done" then " (\(st))" else "" end) + (by | if . != "" then "," + . else . end) + why;
def step_text: "\(.type) (\(st))" + why;
def run_line: "Run \(.experiment_id), wave \(.wave // "-")" + arm_name + ", \(.phone // "no phone"), \(.status), \(.length_s // 0 | dur), \(.ads // 0) ads, \(.flags // 0) flags"
  + (if .verdict.summary then "; verdict: " + (.verdict.summary | q) else "" end)
  + ([.steps[]? | "; " + step_text] | join(""))
  + (if (.pending // []) | length > 0 then "; pending: " + (.pending | join(", ")) else "" end)
  + (if .review_queued then "; review queued" else "" end);
def cnt($n; $one; $many): if $n == 1 then "1 \($one)" else "\($n) \($many)" end;
def fx($d): (pow(10; $d) | round) as $p | ((. // 0) * $p | round) as $n
  | "\($n / $p | floor)." + ($n % $p | tostring | ("0" * ($d - length)) + .);
def place_words: (if (.queue | type) == "object" then .queue else {} end) as $q | ($q.place // .place_in_queue) as $p
  | if .state != "queued" or ($p | not) then ""
    elif $q.max_parallel then ", place \($p) of \([$q.queued // $p, $p] | max) in the queue ("
      + (if $q.max_parallel == 1 then "1 campaign runs" else "\($q.max_parallel) campaigns run" end) + " at once)"
    else ", place \($p) in the queue" end;
def state_line: "Campaign \(.id) \"\(.name | one)\" (project \(.project_name | one)): \(.state)" + place_words
  + (if (.state_reason // "") != "" then " (\(.state_reason | one))" else "" end);
def last_call: (.last_plan_call // null) as $l
  | if ($l | type) != "object" then "no plan call yet."
    else "last plan call \($l.at_local // "at an unknown time") "
      + (if $l.status == "valid" then
           (($l.booked_runs // 0) as $b | ($l.pulled_apps // 0) as $pl
            | (if $b > 0 then "booked " + cnt($b; "run"; "runs") else "booked nothing" end)
              + (if $pl > 0 then ", pulled " + cnt($pl; "app"; "apps") else "" end)
              + (([$l.steps[]? | select(.type == "none")] | last // ($l.steps // [] | last) | .reason? // "") as $r
                 | if $b == 0 and ($r | one | gsub("^ +| +$"; "")) != ""
                   then ": " + ($r | one | if length > 300 then .[0:300] + "…" else . end | "\"" + . + "\"") else "." end))
         elif $l.status == "queued" then "waits for the model."
         elif $l.status == "running" then "the model is answering."
         else "ended with no valid answer; the plan is asked again." end) end;
def attention_lines: if (.planning | type) == "object" and (.planning.attention.words? // "") != ""
  then "Attention: " + (.planning.attention.words | one) else empty end;
def planning_lines: .state as $st | if (.planning | type) != "object" then empty else .planning
  | "Planning: " + last_call,
    (if .plan_calls != null then "Plan calls: \(.plan_calls), \(.plan_calls_without_booking // 0) without a booking"
      + (if .last_booking_local then ", \(.plan_calls_since_last_booking // 0) since the last booking at \(.last_booking_local)" else "" end)
      + "." else empty end),
    (if (.waiting | type) == "object" then .waiting
      | "Waiting: " + cnt(.ready_open // 0; "ready app"; "ready apps") + " with no run, \(.pending_slots // 0) booked ahead, \(.source_pending // 0) not pulled yet."
        + (if (.next_pull_words // "") != "" then " " + (.next_pull_words | one) else "" end) else empty end),
    (if ($st | IN("running", "waiting_phones")) then
       (if .next_plan_call == "queued" or .next_plan_call == "running" then "Next plan call: \(.next_plan_call)"
        elif (.next_plan_words // "") != "" then (.next_plan_words | one) else empty end) else empty end) end;
def phone_time_line: if (.phone_time | type) == "object" and .phone_time.measured_from and (.phone_time.total | type) == "object"
  then .phone_time | .total as $t
  | "Phone time while running: \($t.run_h | fx(2)) h in campaign runs, \($t.idle_h | fx(2)) h idle"
    + (if $t.idle_share != null then " (\($t.idle_share * 100 | fx(1)) %)" else "" end)
    + ", \($t.other_work_h | fx(2)) h on other work, \($t.unusable_h | fx(2)) h not usable"
    + (if .last_hour.idle_share? != null then "; last hour: \(.last_hour.idle_share * 100 | fx(1)) % idle" else "" end)
    + ". Measured from \(.measured_from_local // .measured_from)."
  else empty end;'

# The required fields of a draft, in the order they are listed: flag, then its plain-words description.
CM_REQUIRED='--name|the campaign'"'"'s name, unique in the project (1 to 80 characters)
--project|the project the campaign'"'"'s apps and runs belong to, by name or id
--goal|what the campaign should find, in plain words (20 to 4,000 characters)
--apps or --apps-file|the package ids of the apps to run, comma-separated or one per line in a file
--phones|the lab phones of the campaign, by name or id, comma-separated
--duration|the length of one run, in seconds or as 30m or 2h
--deadline or --run-until-stopped|the time every run should end by, with its UTC offset (2026-11-20T10:00-06:00), or no deadline
--zone|the IANA time zone of the deadline and the report, such as America/Chicago'

# NP-2040: the session lengths (seconds) and the US exit states a run start takes, the research service's SPLIT_OPTIONS_S and
# US_STATES (services/research/crates/api/src/capture_launch.rs; tests/np2040_campaign_draft_fields.bats checks they agree).
CM_SPLITS='300 900 1800 3600 7200 10800 21600'
CM_STATES='AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY'

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

# _cm_secs VALUE: seconds of N, Ns, Nm, Nh or Nd (NP-2040: the forms of capture-start); empty when VALUE is none of them.
_cm_secs() {
  case "$1" in
    *[!0-9smhd]* | '' | [smhd]*) return 0 ;;
  esac
  local n="${1%[smhd]}"
  is_uint "$n" || return 0
  case "$1" in
    *m) printf '%s' $((10#$n * 60)) ;;
    *h) printf '%s' $((10#$n * 3600)) ;;
    *d) printf '%s' $((10#$n * 86400)) ;;
    *) printf '%s' "$((10#$n))" ;;
  esac
}

# _cm_short SECONDS: 5m, 1h (NP-2040: the session lengths in the words of capture-options).
_cm_short() {
  if [ $(($1 % 3600)) = 0 ]; then printf '%sh' $(($1 / 3600)); else printf '%sm' $(($1 / 60)); fi
}

# _cm_splits_words: the session lengths the server takes, as "5m, 15m, ...".
_cm_splits_words() {
  local s out=""
  for s in $CM_SPLITS; do out="$out${out:+, }$(_cm_short "$s")"; done
  printf '%s' "$out"
}

# _cm_states_words: the US exit state codes, as "AL, AK, ...".
_cm_states_words() { printf '%s' "$CM_STATES" | sed 's/ /, /g'; }

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
  # TASK-1601 AC-7: a service from before arms answers the key arms as a field it does not have
  if jq -e '[.refusals[]? | select(.field == "arms" and .code == "unknown_field")] | length > 0' "$RESP" >/dev/null 2>&1; then
    err "hint: this service does not take arms yet"
  fi
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

# _cm_print_arms: TASK-1601 AC-3: the Arms line of a created campaign, from the estimate of the answer when it has one, else
# the number and the names of the arms of the stored spec; nothing for a campaign without arms and with --json.
_cm_print_arms() {
  [ "$CITT_JSON" != 1 ] || return 0
  jq -r "$CM_JQ$CM_ARMS_JQ"' if (.estimate.arms | type) == "object" then arms_check
    else ((.campaign // .).spec.arms // []) | if type == "array" and length > 0 then "Arms: \(length) (\(map(.name | one) | join(", ")))" else empty end end' "$RESP" | clean
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
  local name="" project="" project_id="" goal="" apps="" apps_file="" platform="" page="" phones="" duration="" split="" state=""
  local country="" age="" tracking="" deadline="" until=0 zone="" out="" rerun="" template='{}' look='[]' t k v arms_file=""
  CM_ARMS='[]'
  CM_SP='[]'
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      --name | --project | --project-id | --goal | --apps | --apps-file | --platform | --page-size | --phones | --duration | \
        --split | --state | --exit-state | --country | --age | --tracking | --deadline | --zone | --out | --rerun-states | \
        --template | --look-for | --arm | --arms-file | --set-pref)
        need_value "$1" $#
        case "$1" in
          --arm) _cm_arm_add "$2" ;;
          --arms-file) arms_file="$2" ;;
          --set-pref) _cm_set_pref "$2" ;;
          --name) name="$2" ;;
          --project) project="$2" ;;
          --project-id) project_id="$2" ;;
          --goal) goal="$2" ;;
          --apps) apps="$2" ;;
          --apps-file) apps_file="$2" ;;
          --platform) platform="$2" ;;
          --page-size) page="$2" ;;
          --phones) phones="$2" ;;
          --duration) duration="$2" ;;
          --split) split="$2" ;;
          --state | --exit-state) state="$2" ;;
          --age) age="$2" ;;
          --tracking) tracking="$2" ;;
          --country) country="$2" ;;
          --deadline) deadline="$2" ;;
          --zone) zone="$2" ;;
          --out) out="$2" ;;
          --rerun-states) rerun="$2" ;;
          --template)
            # TASK-1601 AC-2: one referrer for every app is an arm, and the service refuses these template keys (use_arms)
            case "${2%%=*}" in
              install_referrer | referrer | install_link)
                usage_error "a campaign sets install referrers per arm: use --arm NAME=REFERRER instead of --template ${2%%=*}=...; one arm gives every app the same referrer, and --arm NAME adds an arm without one to compare with"
                ;;
            esac
            template="$(_cm_template_add "$template" "$2" 0)" || exit 2
            ;;
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
  # NP-2040: --project-id is --project, as in the other commands
  if [ -n "$project_id" ]; then
    [ -z "$project" ] || [ "$project" = "$project_id" ] || usage_error "give --project or --project-id, not both"
    project="$project_id"
  fi
  [ -z "$age" ] || is_uint "$age" || usage_error "--age takes a whole number of years, got: $age"
  case "$tracking" in '' | allow | refuse) ;; *) usage_error "--tracking takes allow or refuse, got: $tracking" ;; esac
  if [ -n "$state" ]; then
    state="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
    case " $CM_STATES " in
      *" $state "*) ;;
      *) usage_error "--exit-state takes a two-letter US state code ($(_cm_states_words)), got: $state" ;;
    esac
    case "$country" in
      '' | US | us) ;;
      *) usage_error "--exit-state applies to a US exit; leave it out for --country $(printf '%s' "$country" | tr '[:lower:]' '[:upper:]')" ;;
    esac
  fi
  [ -z "$deadline" ] || [ "$until" = 0 ] || usage_error "give --deadline or --run-until-stopped, not both"
  if [ -n "$deadline" ] && ! printf '%s' "$deadline" | grep -Eq "$CM_DEADLINE_RE"; then
    usage_error "--deadline needs a time with its UTC offset, such as 2026-11-20T10:00-06:00; got: $deadline"
  fi
  case "$platform" in '' | android | ios) ;; *) usage_error "--platform takes android or ios, got: $platform" ;; esac
  [ -z "$page" ] || is_uint "$page" || usage_error "--page-size takes a number of apps, got: $page"
  local split_raw="$split"
  for t in duration split; do
    eval "v=\$$t"
    [ -n "$v" ] || continue
    k="$(_cm_secs "$v")"
    [ -n "$k" ] || usage_error "--$t takes seconds or a duration such as 30m, 2h or 1d, got: $v"
    eval "$t=\$k"
  done
  if [ -n "$split" ]; then
    case " $CM_SPLITS " in
      *" $split "*) ;;
      *) usage_error "--split takes one of $(_cm_splits_words), got: $split_raw" ;;
    esac
  fi
  # TASK-1601: the arms of the flags, then the arms of --arms-file; TASK-1597 AC8: --set-pref is template.set_prefs
  [ -z "$arms_file" ] || _cm_arms_file "$arms_file"
  [ "$platform" != ios ] || _cm_arms_ios
  local sp_n
  sp_n="$(jq 'length' <<<"$CM_SP")"
  if [ "$sp_n" -gt 0 ]; then
    [ "$sp_n" -le 20 ] || usage_error "--set-pref is given $sp_n times; a run takes at most 20 entries"
    [ "$platform" != ios ] \
      || usage_error "--set-pref writes SharedPreferences files on Android lab phones only: an iOS app has no SharedPreferences file; leave --platform ios out"
    ! jq -e 'has("set_prefs")' <<<"$template" >/dev/null \
      || usage_error "give set_prefs once: --set-pref FILE.xml:KEY=TYPE:VALUE or --template set_prefs=LIST"
    template="$(jq -c --argjson l "$CM_SP" '. + {set_prefs: $l}' <<<"$template")"
  fi
  # TASK-1602 AC-11: a referrer can contain a comma, the separator of --apps, so a link is a line of --apps-file
  case "$apps" in
    *://*) usage_error "--apps takes package ids, comma-separated, and this value has a link; put links in a file, one per line, and give it with --apps-file" ;;
  esac
  local list='[]' file_list
  [ -z "$apps" ] || list="$(_cm_list_json "$apps")"
  if [ -n "$apps_file" ]; then
    file_list="$(_cm_apps_file "$apps_file" "$platform")" || exit 2
    list="$(jq -nc --argjson l "$list" --argjson f "$file_list" '$l + $f')"
  fi
  [ -n "$zone" ] || zone="$(_cm_zone)"
  # NP-2040 QA 4: a flag and --template that set the same template field; the template would replace the flag's value
  if [ -n "$age" ] && jq -e 'has("age") or has("persona_age")' <<<"$template" >/dev/null; then
    usage_error "give the age once: --age N, or --template age=N, or --template persona_age=N"
  fi
  local fv
  for fv in "duration_s|--duration|$duration" "split_s|--split|$split" "exit_state|--exit-state|$state" \
    "exit_country|--country|$country" "tracking|--tracking|$tracking"; do
    IFS='|' read -r k t v <<<"$fv"
    if [ -n "$v" ] && jq -e --arg k "$k" 'has($k)' <<<"$template" >/dev/null; then
      usage_error "give $k once: $t or --template $k=VALUE"
    fi
  done
  local spec
  spec="$(jq -nc --arg name "$name" --arg project "$project" --arg goal "$goal" --argjson look "$look" --argjson list "$list" \
    --arg platform "$platform" --arg page "$page" --argjson phones "$(_cm_list_json "$phones" 1)" --arg dur "$duration" \
    --arg split "$split" --arg state "$state" --arg country "$country" --arg age "$age" --arg tracking "$tracking" \
    --argjson tpl "$template" --argjson arms "$CM_ARMS" \
    --argjson rerun "$(_cm_list_json "$rerun" | jq -c 'map(ascii_upcase)')" --arg deadline "$deadline" --argjson until "$until" \
    --arg zone "$zone" '
    {}
    + (if $name != "" then {name: $name} else {} end)
    + (if $project != "" then {project: (if $project | test("^[0-9]+$") then ($project | tonumber) else $project end)} else {} end)
    + (if $goal != "" then {goal: $goal} else {} end)
    + (if ($look | length) > 0 then {look_for: $look} else {} end)
    + (if ($list | length) > 0 then {apps: ({list: (if $platform == "" then $list else $list | map(if contains("://") then . else {package_id: ., platform: $platform} end) end)}
        + (if $page != "" then {page_size: ($page | tonumber)} else {} end))} else {} end)
    + (if ($phones | length) > 0 then {phones: $phones} else {} end)
    + ((({} + (if $dur != "" then {duration_s: ($dur | tonumber)} else {} end)
          + (if $split != "" then {split_s: ($split | tonumber)} else {} end)
          + (if $state != "" then {exit_state: ($state | ascii_upcase)} else {} end)
          + (if $country != "" then {exit_country: ($country | ascii_upcase)} else {} end)
          + (if $age != "" then {persona_age: ($age | tonumber)} else {} end)
          + (if $tracking != "" then {tracking: $tracking} else {} end)) + $tpl
        | with_entries(if (.key == "exit_country" or .key == "exit_state") and (.value | type) == "string"
            then .value |= ascii_upcase else . end)) as $t
        | if ($t | length) > 0 then {template: $t} else {} end)
    + (if ($arms | length) > 0 then {arms: $arms} else {} end)
    + (if ($rerun | length) > 0 then {rerun_states: $rerun} else {} end)
    + (if $deadline != "" then {deadline: $deadline} else {} end)
    + (if $until == 1 then {run_until_stopped: true} else {} end)
    + (if $zone != "" then {zone: $zone} else {} end)')" || die 1 "the spec could not be written"
  # NP-2040 QA 2 and 3: the conflicts of the flags with --template that the server refuses
  local tc
  tc="$(jq -r '.template.exit_country // empty | tostring | ascii_upcase' <<<"$spec")"
  if jq -e '.template.exit_state' <<<"$spec" >/dev/null && [ -n "$tc" ] && [ "$tc" != US ]; then
    usage_error "exit_state applies to a US exit; leave it out for exit_country $tc"
  fi
  if [ "$(jq '[.template // {} | has("age", "persona_age") | select(.)] | length' <<<"$spec")" = 2 ]; then
    usage_error "give the age once: --age N, or --template age=N, or --template persona_age=N"
  fi
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
  # NP-2040 (F1): the session length and the exit, with the values the server takes; a template with a goal takes the server's
  # one-session default
  local allowed='{}'
  if ! jq -e '.template.split_s // .template.goal' <<<"$spec" >/dev/null; then
    missing="$missing  --split: the length of one session of a run, one of $(_cm_splits_words)"$'\n'
    allowed="$(jq -c --arg s "$CM_SPLITS" '. + {"--split": ($s | split(" ") | map(tonumber))}' <<<"$allowed")"
  fi
  # a US exit is booked by state: exit_country US without exit_state is refused by the server (QA 1)
  if ! jq -e '.template.exit_state // (.template.exit_country | select(. != null and (tostring | ascii_upcase) != "US"))' \
    <<<"$spec" >/dev/null; then
    missing="$missing  --exit-state or --country: the exit of the runs, a two-letter US state code ($(_cm_states_words)), or a two-letter country code outside the US (citt capture-options lists the countries)"$'\n'
    allowed="$(jq -c --arg s "$CM_STATES" '. + {"--exit-state or --country": ($s | split(" "))}' <<<"$allowed")"
  fi
  if [ -n "$missing" ]; then
    err "$CITT_CMD: wrote $out; missing required fields:"
    printf '%s' "$missing" | clean >&2
    err "$CITT_CMD: run citt campaign draft again with every field and --out $(shq "$out"), then check it with citt campaign check $(shq "$out")"
    if [ "$CITT_JSON" = 1 ]; then
      jq -nc --arg m "missing required fields" --arg miss "$missing" --argjson spec "$spec" --arg out "$out" --argjson allowed "$allowed" \
        '{error: "missing_fields", message: $m, missing: ($miss | split("\n") | map(select(. != "") | sub("^  "; "") | split(": ")[0])),
          allowed: $allowed, file: $out, spec: $spec}'
    fi
    exit 2
  fi
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --arg out "$out" '{file: $out, spec: .}' <<<"$spec"
    return 0
  fi
  jq -r --arg out "$out" "$CM_JQ"' (.apps.list | length) as $apps | "Wrote \($out): campaign \(.name | q) in project \(.project | tostring | q), \($apps) apps"
    + (([.apps.list[] | select(type == "string" and contains("://"))] | length) as $own | if $own > 0 then " (\($own) with their own install referrer)" else "" end)
    + ((.arms // []) | length as $n | if $n > 0 then ", " + cnt($n; "arm"; "arms") + " (\(runs($n * $apps)) or more)" else "" end)
    + ", \(.phones | length) phones, runs of \(.template.duration_s | dur), "
    + ((.template.set_prefs // null) | if type == "array" and length > 0 then (map(.file) | unique | length) as $f
        | "app preferences set before launch (\(cnt(length; "key"; "keys")) in \(cnt($f; "file"; "files"))), " else "" end)
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
    jq -r "$CM_JQ$CM_ARMS_JQ"'(.estimate // {}) as $e
      | (if $e.hours_to_deadline != null then "Hours to the deadline: \($e.hours_to_deadline)" else empty end),
        (if $e.device_hours_available != null then "Device hours available before the deadline: \($e.device_hours_available)"
          + (if $e.device_hours_basis then " (\($e.device_hours_basis | one))" else "" end) else empty end),
        arms_check,
        (if $e.latest_start then "\($e.latest_start.text): \($e.latest_start.at)" else empty end),
        (if $e.profile then $e.profile as $p
          | def from: if . == "template" then "the template" elif . == "project_last_run" then "the project'"'"'s last run"
              else "the default" end;
          "Profile of the runs: age \($p.persona_age | one) (\($p.persona_age_from | from)), tracking \($p.tracking | one) (\($p.tracking_from | from))"
         else empty end),
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
    _cm_print_arms
    [ "$CITT_JSON" = 1 ] || [ "$created" = true ] || printf 'This campaign was already created from this spec; it is shown as it is.\n'
    return 0
  fi
  if [ "$CITT_JSON" != 1 ]; then
    _cm_print_doc
    _cm_print_arms
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
  jq -r --slurpfile r "$rep" "$CM_JQ$CM_ARMS_JQ"' . as $d | $r[0].report as $rep
    | state_line,
      attention_lines,
      "Deadline: " + (if .deadline_local then "\(.deadline_local) (\(.zone))" else "none, it runs until stopped" end),
      "Phones: " + ([.phones[] | .name // "phone \(.device_id)"] | join(", ") | if . == "" then "none" else . end),
      ([$rep.runs[]? | select(.status | IN("queued", "claimed", "running", "stopping")) | .phone] | unique) as $busy
      | (if has("phone_time") and .phone_time != null then "Idle phones now: " else "Idle phones: " end) + ([.phones[] | (.name // "phone \(.device_id)") | select(. as $n | $busy | index($n) | not)] | join(", ")
          | if . == "" then "none" else . end),
      "Apps: " + ([.apps.counts | to_entries[] | "\(.value) \(.key)"] | join(", ") | if . == "" then "none" else . end),
      (((.spec.arms // null) | if type == "array" and length > 0 then . else ($rep.header.arms // null) end) | arms_list),
      planning_lines,
      (if ($rep.measured.runs_by_state // {}) | length > 0 then "Runs: " + ([$rep.measured.runs_by_state | to_entries[] | "\(.value) \(.key)"] | join(", ")) else empty end),
      ($rep.measured // {} | if .device_hours_booked != null then "Device hours: \(.device_hours_booked) booked"
        + (if .device_hours_booked_now != null then ", \(.device_hours_booked_now) booked now (pending and running)" else "" end)
        + ", \(.device_hours_used // 0) used" else empty end),
      phone_time_line,
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
  local remove='[]' arms='[]' have_arms=0 both
  CM_ARMS='[]'
  while [ $# -gt 0 ]; do
    ! _cm_common_flag "$1" || { shift; continue; }
    case "$1" in
      --deadline | --zone | --phones | --rerun-states | --goal | --template | --arm | --remove-arm)
        need_value "$1" $#
        case "$1" in
          --arm)
            _cm_arm_add "$2"
            have_arms=1
            ;;
          --remove-arm)
            remove="$(jq -c --arg n "$2" '. + [$n]' <<<"$remove")"
            have_arms=1
            ;;
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
  if [ -z "$deadline" ] && [ "$until" = 0 ] && [ "$have_phones" = 0 ] && [ "$have_rerun" = 0 ] && [ "$have_goal" = 0 ] && [ "$tpl" = 0 ] && [ "$have_arms" = 0 ]; then
    usage_error "give at least one of --deadline, --run-until-stopped, --phones, --rerun-states, --template FIELD=VALUE, --arm NAME[=REFERRER], --remove-arm NAME and --goal"
  fi
  both="$(jq -r --argjson a "$CM_ARMS" '[.[] | select(ascii_downcase as $n | $a | map(.name | ascii_downcase) | index($n))][0] // empty' <<<"$remove")"
  [ -z "$both" ] || usage_error "the arm $both is given to --arm and to --remove-arm; give it to one of them"
  need_auth
  # TASK-1601 AC-4: the PATCH takes the whole arm list, so the stored one is read first
  if [ "$have_arms" = 1 ]; then
    _cm_arms_edit "$id" "$remove"
    arms="$CM_ARMS_NEW"
  fi
  local body
  body="$(jq -nc --arg d "$deadline" --arg z "$zone" --argjson u "$until" --argjson hp "$have_phones" \
    --argjson phones "$(_cm_list_json "$phones" 1)" --argjson hr "$have_rerun" \
    --argjson rerun "$(_cm_list_json "$rerun" | jq -c 'map(ascii_upcase)')" --argjson hg "$have_goal" --arg goal "$goal" \
    --argjson tpl "$tpl" --argjson t "$template" --argjson ha "$have_arms" --argjson arms "$arms" '{}
    + (if $d != "" then {deadline: $d} else {} end) + (if $z != "" then {zone: $z} else {} end)
    + (if $u == 1 then {run_until_stopped: true} else {} end) + (if $hp == 1 then {phones: $phones} else {} end)
    + (if $hr == 1 then {rerun_states: $rerun} else {} end) + (if $hg == 1 then {goal: $goal} else {} end)
    + (if $tpl == 1 then {template: $t} else {} end) + (if $ha == 1 then {arms: $arms} else {} end)')"
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
    # TASK-1601 AC-5: the app × arm matrix as a table, one row per cell
    if jq -e '.report.arm_matrix | type == "object"' "$RESP" >/dev/null 2>&1; then
      printf '\nApp × arm matrix:\n'
      jq -c "$CM_ARMS_JQ"'.report.arm_matrix | arm_table' "$RESP" | table | clean
    fi
  fi
}

# --- pull ----------------------------------------------------------------------------------------------------------------

# CM_DECISIONS: jq program, the report's actions with a reason as one JSON object per line, deduped by action_id. TASK-1601: a
# wave has `arms` and a run step `arm` when the campaign has arms; without arms the objects have the keys of before.
CM_DECISIONS='[(.report.waves[]? | {action_id, kind: "wave", type: "book_runs", campaign_app_id, package_id, wave, status,
      booked, phones, overrides, reason, decided_by: .decided_by.words, call_id: .decided_by.call_id}
      + (if (.arms | type) == "array" and (.arms | length) > 0 then {arms} else {} end)),
    (.report.runs[]? as $r | $r.steps[]? | {action_id, kind: "run_step", type, experiment_id: $r.experiment_id,
      campaign_app_id, package_id: $r.package_id, wave: $r.wave, status, refusal_code, reason, origin,
      decided_by: .decided_by.words, call_id} + (if ($r.arm // "") != "" then {arm: $r.arm} else {} end)),
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
        elif .kind == "run_step" then "Run \(.experiment_id) (\(.package_id)" + arm_name + "): \(.type) (\(st))" + by + why
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
