#!/usr/bin/env bash
# lib/cmd-atlas-cohort.sh: citt atlas-cohort (TASK-711, Atlas Cohort Export).
# Subcommands: count, preview, export, jobs, status, sdk-resolve. Each calls the CITT backend's
# /api/research/v1/atlas/cohort/* (and /atlas/sdk-resolve) routes (plugin -> backend -> navigator ->
# citt-atlas), reusing the stored token and the backend's atlas_enabled gate: no new credential surface.
# A 403 atlas_not_enabled prints the fixed CITT_ATLAS_DISABLED_LINE; a 200 { atlas_available:false } is
# the backend's graceful-degrade state (feedback-no-dead-ends). The selector flags build the backend
# CohortSelector JSON body; export mirrors cmd_export's submit-poll flow, then downloads the single
# presigned OVH URL with no X-CITT-Client header (the storage-URL convention). Design:
# docs/atlas/cohort-export/SPEC.md "The plugin atlas cohort command".
# shellcheck shell=bash disable=SC2034,SC2016

CITT_COHORT_BASE="$CITT_V1/atlas/cohort"
CITT_SDK_RESOLVE="$CITT_V1/atlas/sdk-resolve"

# cohort_unavailable: the backend returned 200 { atlas_available:false, reason, retry_after }.
cohort_unavailable() {
  local reason retry msg
  reason="$(body_field '.reason')"
  retry="$(body_field '.retry_after')"
  case "$reason" in
    timeout) msg="atlas data unavailable, try again shortly (the service did not answer in time)" ;;
    unreachable) msg="atlas data unavailable, try again shortly (the service could not be reached)" ;;
    rate_limited) msg="atlas data unavailable, too many requests" ;;
    not_configured) msg="atlas is not configured on this backend" ;;
    *) msg="atlas data unavailable, try again shortly" ;;
  esac
  if is_uint "$retry" && [ "$retry" -gt 0 ]; then msg="$msg; retry in $retry s"; fi
  fail_out 8 "$msg"
}

# cohort_call METHOD PATH [BODY_FILE]: a backend cohort call, then the degrade check. E_KIND=atlas keeps
# a 404 on an undeployed route as the "update the plugin" line.
cohort_call() {
  E_KIND=atlas
  call "$@"
  if jq -e '.atlas_available == false' "$RESP" >/dev/null 2>&1; then
    cohort_unavailable
  fi
}

# --- selector parsing --------------------------------------------------------------------------

# _kv ARG: "term=value" -> {"term":..,"value":..}; "term" -> {"term":..}. The first "=" splits.
_kv() {
  case "$1" in
    *=*) jq -nc --arg t "${1%%=*}" --arg v "${1#*=}" '{term:$t, value:$v}' ;;
    *) jq -nc --arg t "$1" '{term:$t}' ;;
  esac
}

# The arrays the selector flags fill (one per fact dimension), the app-metadata filters, and the
# grain/profile/format. _reset_selector clears them for a fresh parse.
_reset_selector() {
  SEL_SDK=() SEL_PP=() SEL_HOST=() SEL_URL=() SEL_PERM=() SEL_COMP=() SEL_LIB=() SEL_FW=()
  SEL_MATTR=() SEL_IDENT=() SEL_CERT=()
  SEL_CATEGORY=() SEL_IBAND=() SEL_CRATING=() SEL_DEV=() SEL_DEVID=() SEL_PLATFORM=() SEL_STATE=()
  SEL_MININSTALLS="" SEL_MINRATING="" SEL_BESTRANK="" SEL_USLISTED=""
  SEL_WHERE="" SEL_ANY=0
  SEL_BY="" SEL_ON="" SEL_PROFILE="" SEL_FORMAT="" SEL_FIELDS="" SEL_FIELDS_ONLY="" SEL_LIMIT=""
}

# _sel_flag FLAG VALUE-COUNT: consumes one known selector/grain flag from "$@" (called with the flag as
# $1 and the whole remaining argv length as $2). Returns 0 and sets _SEL_SHIFT to how many extra args it
# consumed (0 or 1), or returns 1 when the flag is not a selector flag (the caller handles it).
_SEL_SHIFT=0
_sel_flag() {
  local flag="$1" argc="$2"
  _SEL_SHIFT=0
  case "$flag" in
    --sdk) need_value "$flag" "$argc"; SEL_SDK+=("$VAL"); _SEL_SHIFT=1 ;;
    --package-path) need_value "$flag" "$argc"; SEL_PP+=("$VAL"); _SEL_SHIFT=1 ;;
    --host) need_value "$flag" "$argc"; SEL_HOST+=("$VAL"); _SEL_SHIFT=1 ;;
    --url) need_value "$flag" "$argc"; SEL_URL+=("$VAL"); _SEL_SHIFT=1 ;;
    --permission) need_value "$flag" "$argc"; SEL_PERM+=("$VAL"); _SEL_SHIFT=1 ;;
    --component) need_value "$flag" "$argc"; SEL_COMP+=("$VAL"); _SEL_SHIFT=1 ;;
    --native-lib) need_value "$flag" "$argc"; SEL_LIB+=("$VAL"); _SEL_SHIFT=1 ;;
    --framework) need_value "$flag" "$argc"; SEL_FW+=("$VAL"); _SEL_SHIFT=1 ;;
    --manifest-attr) need_value "$flag" "$argc"; SEL_MATTR+=("$(_kv "$VAL")"); _SEL_SHIFT=1 ;;
    --identifier) need_value "$flag" "$argc"; SEL_IDENT+=("$(_kv "$VAL")"); _SEL_SHIFT=1 ;;
    --cert-field) need_value "$flag" "$argc"; SEL_CERT+=("$(_kv "$VAL")"); _SEL_SHIFT=1 ;;
    --category) need_value "$flag" "$argc"; SEL_CATEGORY+=("$VAL"); _SEL_SHIFT=1 ;;
    --installs-band) need_value "$flag" "$argc"; SEL_IBAND+=("$VAL"); _SEL_SHIFT=1 ;;
    --content-rating) need_value "$flag" "$argc"; SEL_CRATING+=("$VAL"); _SEL_SHIFT=1 ;;
    --developer) need_value "$flag" "$argc"; SEL_DEV+=("$VAL"); _SEL_SHIFT=1 ;;
    --developer-id) need_value "$flag" "$argc"; SEL_DEVID+=("$VAL"); _SEL_SHIFT=1 ;;
    --platform) need_value "$flag" "$argc"; SEL_PLATFORM+=("$VAL"); _SEL_SHIFT=1 ;;
    --state) need_value "$flag" "$argc"; SEL_STATE+=("$VAL"); _SEL_SHIFT=1 ;;
    --min-installs) need_value "$flag" "$argc"; is_uint "$VAL" || usage_error "--min-installs needs a number"; SEL_MININSTALLS="$VAL"; _SEL_SHIFT=1 ;;
    --min-rating-count) need_value "$flag" "$argc"; is_uint "$VAL" || usage_error "--min-rating-count needs a number"; SEL_MINRATING="$VAL"; _SEL_SHIFT=1 ;;
    --best-rank-within) need_value "$flag" "$argc"; is_uint "$VAL" || usage_error "--best-rank-within needs a number"; SEL_BESTRANK="$VAL"; _SEL_SHIFT=1 ;;
    --us-listed) SEL_USLISTED=true ;;
    --not-us-listed) SEL_USLISTED=false ;;
    --where) need_value "$flag" "$argc"; SEL_WHERE="$VAL"; _SEL_SHIFT=1 ;;
    --any) SEL_ANY=1 ;;
    --by) need_value "$flag" "$argc"; SEL_BY="$VAL"; _SEL_SHIFT=1 ;;
    --on) need_value "$flag" "$argc"; SEL_ON="$VAL"; _SEL_SHIFT=1 ;;
    --profile) need_value "$flag" "$argc"; SEL_PROFILE="$VAL"; _SEL_SHIFT=1 ;;
    --fields) need_value "$flag" "$argc"; SEL_FIELDS="$VAL"; _SEL_SHIFT=1 ;;
    --fields-only) need_value "$flag" "$argc"; SEL_FIELDS_ONLY="$VAL"; _SEL_SHIFT=1 ;;
    --format) need_value "$flag" "$argc"; SEL_FORMAT="$VAL"; _SEL_SHIFT=1 ;;
    --limit) need_value "$flag" "$argc"; is_uint "$VAL" || usage_error "--limit needs a number"; SEL_LIMIT="$VAL"; _SEL_SHIFT=1 ;;
    *) return 1 ;;
  esac
  return 0
}

# _jarr NAME ELEM...: a JSON array of string elements (for the string dimensions).
_jarr() {
  local out="[]" e
  for e in "$@"; do out="$(jq -c --arg v "$e" '. + [$v]' <<<"$out")"; done
  printf '%s' "$out"
}

# _jkvarr ELEM...: a JSON array of already-JSON {term,value} objects.
_jkvarr() {
  local out="[]" e
  for e in "$@"; do out="$(jq -c --argjson o "$e" '. + [$o]' <<<"$out")"; done
  printf '%s' "$out"
}

# build_selector: assemble the CohortSelector JSON body from the parsed arrays into $SEL_BODY.
build_selector() {
  local flags app has_flags=0
  flags="$(jq -nc \
    --argjson sdk "$(_jarr ${SEL_SDK[@]+"${SEL_SDK[@]}"})" \
    --argjson pp "$(_jarr ${SEL_PP[@]+"${SEL_PP[@]}"})" \
    --argjson host "$(_jarr ${SEL_HOST[@]+"${SEL_HOST[@]}"})" \
    --argjson url "$(_jarr ${SEL_URL[@]+"${SEL_URL[@]}"})" \
    --argjson perm "$(_jarr ${SEL_PERM[@]+"${SEL_PERM[@]}"})" \
    --argjson comp "$(_jarr ${SEL_COMP[@]+"${SEL_COMP[@]}"})" \
    --argjson lib "$(_jarr ${SEL_LIB[@]+"${SEL_LIB[@]}"})" \
    --argjson fw "$(_jarr ${SEL_FW[@]+"${SEL_FW[@]}"})" \
    --argjson mattr "$(_jkvarr ${SEL_MATTR[@]+"${SEL_MATTR[@]}"})" \
    --argjson ident "$(_jkvarr ${SEL_IDENT[@]+"${SEL_IDENT[@]}"})" \
    --argjson cert "$(_jkvarr ${SEL_CERT[@]+"${SEL_CERT[@]}"})" \
    '{sdk:$sdk, package_path:$pp, host:$host, url:$url, permission:$perm, component:$comp,
      native_lib:$lib, framework:$fw, manifest_attr:$mattr, identifier:$ident, cert_field:$cert}
     | with_entries(select(.value | length > 0))')"
  app="$(jq -nc \
    --argjson category "$(_jarr ${SEL_CATEGORY[@]+"${SEL_CATEGORY[@]}"})" \
    --argjson iband "$(_jarr ${SEL_IBAND[@]+"${SEL_IBAND[@]}"})" \
    --argjson crating "$(_jarr ${SEL_CRATING[@]+"${SEL_CRATING[@]}"})" \
    --argjson dev "$(_jarr ${SEL_DEV[@]+"${SEL_DEV[@]}"})" \
    --argjson devid "$(_jarr ${SEL_DEVID[@]+"${SEL_DEVID[@]}"})" \
    --argjson platform "$(_jarr ${SEL_PLATFORM[@]+"${SEL_PLATFORM[@]}"})" \
    --argjson state "$(_jarr ${SEL_STATE[@]+"${SEL_STATE[@]}"})" \
    --arg mininstalls "$SEL_MININSTALLS" --arg minrating "$SEL_MINRATING" \
    --arg bestrank "$SEL_BESTRANK" --arg uslisted "$SEL_USLISTED" \
    '{category:$category, installs_band:$iband, content_rating:$crating, developer:$dev,
      developer_id:$devid, platform:$platform, state:$state,
      min_installs:(if $mininstalls=="" then null else ($mininstalls|tonumber) end),
      min_rating_count:(if $minrating=="" then null else ($minrating|tonumber) end),
      best_rank_within:(if $bestrank=="" then null else ($bestrank|tonumber) end),
      us_listed:(if $uslisted=="" then null else ($uslisted=="true") end)}
     | with_entries(select(.value != null and (.value | if type=="array" then length>0 else true end)))')"
  [ "$(jq 'length' <<<"$flags")" -gt 0 ] && has_flags=1
  if [ -n "$(jq -r 'keys[]? // empty' <<<"$app")" ]; then
    flags="$(jq -c --argjson a "$app" '. + {app:$a}' <<<"$flags")"
    has_flags=1
  fi
  if [ "$has_flags" = 1 ] && [ -n "$SEL_WHERE" ]; then
    usage_error "use selector flags or --where, not both"
  fi
  SEL_BODY="$(tmpfile cohort_selector)"
  jq -nc \
    --argjson flags "$flags" --arg where "$SEL_WHERE" --argjson any "$SEL_ANY" \
    --arg by "$SEL_BY" --arg on "$SEL_ON" --arg profile "$SEL_PROFILE" --arg format "$SEL_FORMAT" \
    --arg fields "$SEL_FIELDS" --arg fields_only "$SEL_FIELDS_ONLY" --arg limit "$SEL_LIMIT" \
    '{}
     + (if ($flags | length) > 0 then {flags:$flags} else {} end)
     + (if $where != "" then {where:$where} else {} end)
     + (if $any == 1 then {any:true} else {} end)
     + (if $by != "" then {by:$by} else {} end)
     + (if $on != "" then {on:$on} else {} end)
     + (if $profile != "" then {profile:$profile} else {} end)
     + (if $format != "" then {format:$format} else {} end)
     + (if $fields != "" then {fields:($fields|split(","))} else {} end)
     + (if $fields_only != "" then {fields_only:($fields_only|split(","))} else {} end)
     + (if $limit != "" then {limit:($limit|tonumber)} else {} end)' >"$SEL_BODY"
}

# --- citt atlas-cohort count / preview ---------------------------------------------------------

_cohort_read() {
  local sub="$1" path
  shift
  _reset_selector
  while [ $# -gt 0 ]; do
    VAL="${2:-}"
    if [ "$1" = --json ]; then CITT_JSON=1; shift; continue; fi
    if [ "$1" = --help ] || [ "$1" = -h ]; then help_atlas_cohort; exit 0; fi
    if _sel_flag "$1" "$#"; then shift "$((1 + _SEL_SHIFT))"; continue; fi
    usage_error "unknown option $1"
  done
  need_auth
  build_selector
  case "$sub" in
    count) path="$CITT_COHORT_BASE/count" ;;
    preview) path="$CITT_COHORT_BASE/preview" ;;
  esac
  cohort_call POST "$path" "$SEL_BODY"
  if [ "$CITT_JSON" = 1 ]; then cat "$RESP"; printf '\n'; return 0; fi
  if [ "$sub" = count ]; then
    jq -r '.data
      | "builds: \(.build_count)\(if .app_count != null then ", apps: \(.app_count)" else "" end)",
        (if .resolver then "resolved: \(.resolver.predicate // .resolver.source)"
           + (if (.resolver.signatures // []) | length > 0
                then "  (" + ([.resolver.signatures[] | "\(.value) \(.distinct_builds // "?") builds"] | join(", ")) + ")"
                else "" end) else empty end),
        (if (.build_count == 0) then "no match"
           + (if (.reason // "") != "" then " (\(.reason))" else "" end) else empty end),
        (if (.build_count == 0 and (.next_action // "") != "") then "next: \(.next_action)" else empty end)' "$RESP" \
      || die 1 "unparseable atlas response"
  else
    jq -r '.data[]? | "\(.package // "-")  \(.title // "-")"
      + (if (.developer // "") != "" then " by \(.developer)" else "" end)
      + "  (\(.category // "-"), \(.installs_band // .installs // "-"))"' "$RESP"
    jq -r '.meta | select(.returned == 0) | "no apps matched"
      + (if (.reason // "") != "" then " (\(.reason))" else "" end)
      + (if (.next_action // "") != "" then "\nnext: \(.next_action)" else "" end)' "$RESP" 2>/dev/null
  fi
}

# --- citt atlas-cohort jobs / status -----------------------------------------------------------

cmd_cohort_jobs() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) CITT_JSON=1 ;;
      --help | -h) help_atlas_cohort; exit 0 ;;
      -*) usage_error "unknown option $1" ;;
      *) usage_error "jobs takes no argument" ;;
    esac
    shift
  done
  need_auth
  cohort_call GET "$CITT_COHORT_BASE/exports"
  if [ "$CITT_JSON" = 1 ]; then cat "$RESP"; printf '\n'; return 0; fi
  if [ "$(jq '.data | length' "$RESP")" = 0 ]; then
    jq -r '.meta | "no export jobs yet" + (if (.next_action // "") != "" then "\nnext: \(.next_action)" else "" end)' "$RESP"
    return 0
  fi
  jq -r '.data[] | "\(.job_id)  \(.state)  \(.profile)/\(.format)"
    + (if .app_count != null then "  \(.app_count) apps" else "" end)
    + (if .build_count != null then ", \(.build_count) builds" else "" end)' "$RESP"
}

cmd_cohort_status() {
  local id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) CITT_JSON=1 ;;
      --help | -h) help_atlas_cohort; exit 0 ;;
      -*) usage_error "unknown option $1" ;;
      *) [ -z "$id" ] || usage_error "one JOB_ID only"; id="$1" ;;
    esac
    shift
  done
  [ -n "$id" ] || usage_error "give the JOB_ID"
  need_auth
  cohort_call GET "$CITT_COHORT_BASE/exports/$(urlenc "$id")"
  if [ "$CITT_JSON" = 1 ]; then cat "$RESP"; printf '\n'; return 0; fi
  _cohort_print_status "$RESP"
}

# _cohort_print_status RESP: the human line(s) for a job record envelope.
_cohort_print_status() {
  jq -r '.data
    | "job \(.job_id): \(.state)"
      + (if .rows_emitted != null and (.state=="running" or .state=="uploading") then "  \(.rows_emitted) rows" else "" end),
      (if .state == "ready" then
         "data: \(.data_url)",
         "manifest: \(.manifest_url)",
         "\(.bytes // 0) bytes, sha256 \(.sha256 // "-")"
       else empty end),
      (if (.reason // "") != "" then "reason: \(.reason)" else empty end),
      (if (.next_action // "") != "" then "next: \(.next_action)" else empty end)' "$1" \
    || die 1 "unparseable atlas response"
}

# --- citt atlas-cohort sdk-resolve -------------------------------------------------------------

cmd_cohort_sdk_resolve() {
  local name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) CITT_JSON=1 ;;
      --help | -h) help_atlas_cohort; exit 0 ;;
      -*) usage_error "unknown option $1" ;;
      *) [ -z "$name" ] || usage_error "one NAME only"; name="$1" ;;
    esac
    shift
  done
  [ -n "$name" ] || usage_error "give the SDK NAME"
  need_auth
  cohort_call GET "$CITT_SDK_RESOLVE$(query name "$name")"
  if [ "$CITT_JSON" = 1 ]; then cat "$RESP"; printf '\n'; return 0; fi
  jq -r '.data
    | "resolved \(.name // "-") via \(.source)",
      (if (.predicate // "") != "" then "predicate: \(.predicate)" else empty end),
      (.signatures[]? | "  \(.sdk_name)  \(.value)  \(.distinct_builds // "?") builds (\(.role))"),
      (if (.next_action // "") != "" then "next: \(.next_action)" else empty end)' "$RESP" \
    || die 1 "unparseable atlas response"
}

# --- citt atlas-cohort export ------------------------------------------------------------------

cmd_cohort_export() {
  local no_wait=0 job_id="" out="" timeout=540 start status st
  _reset_selector
  while [ $# -gt 0 ]; do
    VAL="${2:-}"
    case "$1" in
      --no-wait) no_wait=1; shift; continue ;;
      --job-id) need_value "$1" $#; job_id="$2"; shift 2; continue ;;
      --out) need_value "$1" $#; out="$2"; shift 2; continue ;;
      --timeout) need_value "$1" $#; is_uint "$2" || usage_error "--timeout needs a number"; timeout="$2"; shift 2; continue ;;
      --json) CITT_JSON=1; shift; continue ;;
      --help | -h) help_atlas_cohort; exit 0 ;;
    esac
    if _sel_flag "$1" "$#"; then shift "$((1 + _SEL_SHIFT))"; continue; fi
    usage_error "unknown option $1"
  done
  need_auth

  # Submit, unless resuming a known job id.
  if [ -z "$job_id" ]; then
    build_selector
    cohort_call POST "$CITT_COHORT_BASE/exports" "$SEL_BODY"
    job_id="$(body_field '.data.job_id')"
    [ -n "$job_id" ] || die 1 "unexpected response from the server"
    if [ "$no_wait" = 1 ]; then
      if [ "$CITT_JSON" = 1 ]; then cat "$RESP"; printf '\n'; else
        printf 'Export %s submitted (%s). Follow with: citt atlas-cohort status %s\n' \
          "$job_id" "$(body_field '.data.state')" "$job_id"
      fi
      return 0
    fi
  fi

  # Poll until ready/failed/cancelled, re-run line on a tool timeout.
  st="$(tmpfile cohort_status)"
  start="$(now_s)"
  wait_deadline "$timeout" "still running after $timeout s; re-run: citt atlas-cohort export --job-id $job_id"
  while :; do
    cohort_call GET "$CITT_COHORT_BASE/exports/$(urlenc "$job_id")"
    cp "$RESP" "$st"
    status="$(body_field '.data.state')"
    case "$status" in ready | failed | cancelled) break ;; esac
    if [ $(($(now_s) - start)) -ge "$timeout" ]; then
      if [ "$CITT_JSON" = 1 ]; then cat "$st"; printf '\n'; else _cohort_print_status "$st"; fi
      err "citt atlas-cohort: still running after $timeout s; re-run: citt atlas-cohort export --job-id $job_id"
      exit 12
    fi
    poll_sleep "$(jq -r '.data.poll_after_seconds // empty' "$st")"
  done
  wait_done

  if [ "$status" = failed ]; then
    die 8 "export $job_id failed: $(jq -r '.data.reason // "no reason given"' "$st")"
  fi
  if [ "$status" = cancelled ]; then
    die 8 "export $job_id was cancelled"
  fi

  # Ready: download the single presigned OVH data URL (no X-CITT-Client header), then report.
  local data_url manifest_url want file dir
  data_url="$(jq -r '.data.data_url // empty' "$st")"
  manifest_url="$(jq -r '.data.manifest_url // empty' "$st")"
  want="$(jq -r '.data.sha256 // empty' "$st")"
  [ -n "$data_url" ] || die 1 "export $job_id is ready but carries no download URL"

  dir="${out:-${CITT_COHORT_DIR:-./citt-cohorts}}"
  mkdir -p "$dir" 2>/dev/null || die 1 "cannot create $dir"
  file="$dir/$job_id.$(jq -r '.data.format // "jsonl.gz"' "$st")"
  # A presigned storage URL carries its own auth in the query; the bearer and the X-CITT-Client header
  # do not go to OVH (the storage-URL convention, matching the capture presigned download).
  HTTP_AUTH=0
  HTTP_CLIENT_HDR=0
  HTTP_OUT="$file"
  http GET "$data_url"
  case "$CODE" in 200 | 206) ;; *) rm -f "$file"; fail_http ;; esac
  if [ -n "$want" ] && [ "$(sha256_of "$file")" != "$want" ]; then
    rm -f "$file"
    die 11 "export $job_id failed verification: data sha256 differs from $want"
  fi

  if [ "$CITT_JSON" = 1 ]; then
    jq -c --arg f "$file" '{schema:"citt.plugin.cohort/1", job: .data, file:$f}' "$st"
    return 0
  fi
  printf 'Export %s ready: %s bytes.\n' "$job_id" "$(jq -r '.data.bytes // 0' "$st")"
  printf 'Wrote %s\n' "$file"
  [ -z "$manifest_url" ] || printf 'Manifest: %s\n' "$manifest_url"
  printf 'Data URL (expires %s): %s\n' "$(jq -r '.data.expires_at // "-"' "$st")" "$data_url"
}

# --- dispatch ----------------------------------------------------------------------------------

cmd_atlas_cohort() {
  local sub="${1:-}"
  case "$sub" in
    ''| --help | -h | help) help_atlas_cohort; [ "$sub" = "" ] && exit 2 || exit 0 ;;
  esac
  shift
  case "$sub" in
    count | preview) _cohort_read "$sub" "$@" ;;
    export) cmd_cohort_export "$@" ;;
    jobs) cmd_cohort_jobs "$@" ;;
    status) cmd_cohort_status "$@" ;;
    sdk-resolve) cmd_cohort_sdk_resolve "$@" ;;
    *) usage_error "unknown subcommand $sub (count, preview, export, jobs, status, sdk-resolve)" ;;
  esac
}
