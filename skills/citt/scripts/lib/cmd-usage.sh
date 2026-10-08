#!/usr/bin/env bash
# lib/cmd-usage.sh: citt usage.
# shellcheck shell=bash disable=SC2034

cmd_usage() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_usage
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  need_auth
  call GET "$CITT_V1/usage"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  jq -r '"Usage for \(.month) (UTC):"' "$RESP" || die 1 "unparseable response from GET $CITT_V1/usage"
  # The allowances /pricing names, as the dashboard's Usage page lists them; other meters are left out.
  jq -c '{"rule_scan": "Rule scans", "deep_scan": "Deep scans", "llm_prompt": "Questions"} as $name
    | [["ACTION", "USED", "LIMIT", "REMAINING"]]
      + [.actions[] | select($name[.action]) | [$name[.action], .used, .limit, .remaining]]' "$RESP" | table
  jq -r '.actions[] | select(.action == "rule_scan" and .daily_limit != null)
    | "Rule scans in the last 24 hours: \(.daily_used // 0) of \(.daily_limit) in the plan; past them, each is charged from the prepaid balance"' "$RESP"
  printf "Past the plan's count, rule scans and questions are charged from the prepaid balance: %s/settings/billing\n" "$CITT_APP_HOST"
  printf 'Exports are unlimited and leave these counts unchanged.\n'
  # The deep-scan lines apply to a plan with Deep scans.
  jq -r 'if .deep_scan_charged == null or ([.actions[] | select(.action == "deep_scan" and (.limit // 0) > 0)] | length) == 0 then empty
    else "Deep scans started on the dashboard count as deep_scan when they complete.",
      (if .deep_scan_charged then "Project deep scans (submit --deep) are counted as deep_scan: the loaded rule pack has deep rules."
      else "Project deep scans (submit --deep) are not counted as deep_scan: the loaded rule pack has no deep rules." end) end' "$RESP"
}
