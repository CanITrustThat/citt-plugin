#!/usr/bin/env bash
# lib/cmd-apps.sh: citt apps.
# shellcheck shell=bash disable=SC2034

cmd_apps() {
  local status="" family="" severity="" regime="" regime_status="" q="" csv=0 n
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --status | --family | --severity | --regime | --regime-status | --q)
        need_value "$1" $#
        case "$1" in
          --status) status="$2" ;;
          --family) family="$2" ;;
          --severity) severity="$2" ;;
          --regime) regime="$2" ;;
          --regime-status) regime_status="$2" ;;
          --q) q="$2" ;;
        esac
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --csv) csv=1 ;;
      --help | -h)
        help_apps
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  check_project_flags optional
  if [ -n "$regime_status" ] && [ -z "$regime" ]; then usage_error "--regime-status needs --regime"; fi
  if [ "$csv" = 1 ] && [ "$CITT_JSON" = 1 ]; then usage_error "use --json or --csv, not both"; fi
  need_auth
  resolve_project
  call GET "$CITT_V1/projects/$PROJECT_ID/apps$(query status "$status" family "$family" severity "$severity" \
    regime "$regime" status_regime "$regime_status" q "$q")"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
  elif [ "$csv" = 1 ]; then
    jq -r "$JQ_CSV"'
      ["project_app_id", "platform", "package_id", "label", "status", "failure_reason", "key_findings"],
      (.apps[] | [.project_app_id, .platform, .package_id, .label, .status, .failure_reason,
        ((.key_findings // []) | map("\(.severity):\(.rule_id)") | join(";"))])
      | csvrow' "$RESP" || die 1 "unparseable apps response"
  else
    jq -c '
      def sev: ["critical", "high", "medium", "low", "info"];
      def summary: (.key_findings // []) as $k
        | if ($k | length) > 0 then
            "\($k | length) (" + ([sev[] as $s | ($k | map(select(.severity == $s)) | length) as $c
              | select($c > 0) | "\($s) \($c)"] | join(", ")) + ")"
          elif .status == "done" then "0"
          else (.failure_reason // "-") end;
      [["PACKAGE", "PLATFORM", "LABEL", "STATUS", "KEY FINDINGS"]]
      + [.apps[] | [.package_id, .platform, (.label // "-"), .status, summary]]' "$RESP" | table
  fi
}
