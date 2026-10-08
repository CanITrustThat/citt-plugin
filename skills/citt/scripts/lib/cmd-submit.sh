#!/usr/bin/env bash
# lib/cmd-submit.sh: citt submit.
# shellcheck shell=bash disable=SC2034

SUBMIT_LIMIT=2097152

# _package_of ARG: a package id or the id of a Google Play URL; "ios <id>" for an App Store URL or a
# numeric App Store id (D227).
_package_of() {
  local a="$1" id
  case "$a" in
    *apps.apple.com* | *itunes.apple.com*)
      id="$(printf '%s' "$a" | sed -n 's#.*/id\([0-9][0-9]*\).*#\1#p')"
      [ -n "$id" ] || usage_error "no id in the App Store URL: $a"
      printf 'ios %s' "$id"
      ;;
    http://* | https://*)
      case "$a" in *play.google.com*) ;; *) usage_error "not a package id, Google Play URL or App Store URL: $a" ;; esac
      id="$(printf '%s' "$a" | sed -n 's/.*[?&]id=\([^&#]*\).*/\1/p')"
      [ -n "$id" ] || usage_error "no id parameter in the Google Play URL: $a"
      printf '%s' "$id"
      ;;
    *[!0-9]* | "") printf '%s' "$a" ;;
    *) printf 'ios %s' "$a" ;;
  esac
}

# _submit_free_text: a free scan's response (D217): the app, its project, and the next step.
_submit_free_text() {
  jq -r '.project as $p | .project_id as $id | .apps[]
    | if .status == "not_found" then "Not found, \(.platform): \(.package_id) (\(.reason // "-"))."
      elif .outcome == "existing" and (.up_to_date == true) then "Free scan: \(.package_id) is up to date with the current rule pack in \"\($p)\" (project id \($id))."
      elif .outcome == "existing" then "Free scan: \(.package_id) is already in \"\($p)\" (project id \($id)), status \(.status)."
      else "Free scan: \(.package_id) queued in \"\($p)\" (project id \($id))." end' "$RESP" \
    || die 1 "unparseable response from POST $CITT_V1/submit"
  printf 'Next: citt status --wait, then citt app PACKAGE\n'
}

cmd_submit() {
  local csv="" apps_opt="" deep=false fresh=false rescan=false prompt="" prompt_file="" key="" n
  local -a pkgs
  pkgs=()
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --csv)
        need_value "$1" $#
        csv="$2"
        shift
        ;;
      --apps)
        need_value "$1" $#
        apps_opt="$2"
        shift
        ;;
      --deep) deep=true ;;
      --fresh) fresh=true ;;
      --rescan) rescan=true ;;
      --prompt)
        need_value "$1" $#
        prompt="$2"
        shift
        ;;
      --prompt-file)
        need_value "$1" $#
        prompt_file="$2"
        shift
        ;;
      --idempotency-key)
        need_value "$1" $#
        key="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_submit
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *) pkgs+=("$1") ;;
    esac
    shift
  done
  check_project_flags optional
  local sources=0
  [ -n "$csv" ] && sources=$((sources + 1))
  [ -n "$apps_opt" ] && sources=$((sources + 1))
  [ "${#pkgs[@]}" -gt 0 ] && sources=$((sources + 1))
  [ "$sources" = 1 ] || usage_error "use exactly one of --csv, --apps or package arguments"
  if [ -n "$prompt" ] && [ -n "$prompt_file" ]; then usage_error "use --prompt or --prompt-file, not both"; fi
  if [ -n "$prompt_file" ]; then
    [ -r "$prompt_file" ] || usage_error "cannot read $prompt_file"
    prompt="$(cat "$prompt_file")"
  fi
  [ -n "$prompt" ] && deep=true
  [ -n "$key" ] || key="plugin-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"

  # The app list, one package per line.
  local list
  list="$(tmpfile apps)"
  if [ -n "$apps_opt" ]; then
    local IFS=,
    for n in $apps_opt; do
      [ -n "$n" ] && { _package_of "$n" || exit 2; printf '\n'; } >>"$list"
    done
    unset IFS
  elif [ "${#pkgs[@]}" -gt 0 ]; then
    for n in "${pkgs[@]}"; do
      { _package_of "$n" || exit 2; printf '\n'; } >>"$list"
    done
  fi
  if [ -n "$csv" ]; then [ -r "$csv" ] || usage_error "cannot read $csv"; fi

  need_auth
  local project="$OPT_PROJECT" project_id=null free=0
  # D217: without a project, an account without `research` scans into its free project.
  if [ -z "$OPT_PROJECT" ] && [ -z "$OPT_PROJECT_ID" ]; then
    free_account
    free=1
    E_KIND=free_submit
  fi
  if [ -n "$OPT_PROJECT_ID" ]; then
    E_PROJECT_ID="$OPT_PROJECT_ID"
    call GET "$CITT_V1/projects"
    project="$(jq -r --argjson id "$OPT_PROJECT_ID" '.projects[] | select(.project_id == $id) | .name' "$RESP")"
    [ -n "$project" ] || die 4 "project $OPT_PROJECT_ID not found, or you are not an owner"
    project_id="$OPT_PROJECT_ID"
  fi
  E_PROJECT_LABEL="$project"

  local body
  body="$(tmpfile submit_body)"
  if [ -n "$csv" ]; then
    jq -nc --arg p "$project" --argjson pid "$project_id" --rawfile csv "$csv" --argjson deep "$deep" \
      --arg prompt "$prompt" --argjson fresh "$fresh" --argjson rescan "$rescan" --arg key "$key" \
      '{project: $p} + (if $pid == null then {} else {project_id: $pid} end)
       + {csv: $csv, actions: {rule_scan: {deep: $deep}, prompt: (if $prompt == "" then null else $prompt end)},
          fresh: $fresh, rescan: $rescan, idempotency_key: $key}' >"$body" || die 1 "cannot read $csv"
    n="$(file_bytes "$body")"
    [ "$n" -le "$SUBMIT_LIMIT" ] || usage_error "CSV too large ($n bytes, limit $SUBMIT_LIMIT); split the file"
  else
    jq -Rn --arg p "$project" --argjson pid "$project_id" --argjson deep "$deep" \
      --arg prompt "$prompt" --argjson fresh "$fresh" --argjson rescan "$rescan" --arg key "$key" \
      '{project: $p} + (if $pid == null then {} else {project_id: $pid} end)
       + {apps: [inputs | select(. != "") | if startswith("ios ") then {package_id: .[4:], platform: "ios"} else {package_id: .} end],
          actions: {rule_scan: {deep: $deep}, prompt: (if $prompt == "" then null else $prompt end)},
          fresh: $fresh, rescan: $rescan, idempotency_key: $key}' <"$list" >"$body"
    n="$(file_bytes "$body")"
    [ "$n" -le "$SUBMIT_LIMIT" ] || usage_error "request too large ($n bytes, limit $SUBMIT_LIMIT); split the list"
  fi

  HTTP_RETRY=yes
  call POST "$CITT_V1/submit" "$body"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  if [ "$free" = 1 ]; then
    _submit_free_text
    return 0
  fi
  jq -r '
    "Project \(.project) (id \(.project_id)), \(if .project_created then "created" else "existing" end).",
    "Rows: \(.apps | length) (\(.counts.added) added, \(.counts.existing) existing); queued \(.counts.queued), not_found \(.counts.not_found).",
    ([.jobs[] | select(.outcome == "created")] as $c
     | ([.jobs[] | select(.outcome != "created")] | length) as $e
     | ($c | reduce .[] as $j ([]; if any(.[]; .[0] == $j.kind) then map(if .[0] == $j.kind then [.[0], .[1] + 1] else . end) else . + [[$j.kind, 1]] end)) as $k
     | "Jobs: \($c | length) created\(if ($c | length) > 0 then " (" + ($k | map("\(.[0]) \(.[1])") | join(", ")) + ")" else "" end), \($e) existing.")' "$RESP" \
    || die 1 "unparseable response from POST $CITT_V1/submit"
  # A deep request is up to date when the decompiled code is already prepared with the current rule pack.
  local current="Up to date with the current rule pack"
  [ "$deep" = true ] && current="Decompiled code already prepared with the current rule pack"
  jq -r --arg current "$current" '[.apps[] | select(.up_to_date == true) | .package_id]
    | select(length > 0)
    | "\($current) (\(length)): " + join(", ")' "$RESP"
  local android
  android="$(jq -c '[.apps[] | select(.platform == "android" and .status == "not_found")]' "$RESP")"
  if [ "$(jq 'length' <<<"$android")" -gt 0 ]; then
    jq -r '"Not found, android (\(length)):"' <<<"$android"
    jq -r '(map(.package_id | length) | max) as $w
      | .[] | "  " + .package_id + ([range(0; $w - (.package_id | length) + 3)] | map(" ") | join("")) + (.reason // "-")' <<<"$android"
  fi
  jq -r '[.apps[] | select(.platform == "ios" and .status == "not_found")]
    | select(length > 0)
    | "Not found, ios (\(length)): " + (group_by(.reason) | map([(.[0].reason // "-"), length])
        | sort_by(-.[1], .[0]) | map("\(.[0]) \(.[1])") | join(", "))' "$RESP"
  printf 'Next: citt status --project %s --wait\n' "$(shq "$(jq -r .project "$RESP")")"
}
