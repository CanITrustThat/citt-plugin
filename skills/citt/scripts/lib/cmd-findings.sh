#!/usr/bin/env bash
# lib/cmd-findings.sh: citt findings.
# shellcheck shell=bash disable=SC2034

cmd_findings() {
  local rule="" family="" severity="" source="" app="" verdict="" limit=500 all=0 csv=0 n
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --rule | --family | --severity | --source | --app | --verdict | --limit)
        need_value "$1" $#
        case "$1" in
          --rule) rule="$2" ;;
          --family) family="$2" ;;
          --severity) severity="$2" ;;
          --source) source="$2" ;;
          --app) app="$2" ;;
          --verdict) verdict="$2" ;;
          --limit) limit="$2" ;;
        esac
        shift
        ;;
      --all) all=1 ;;
      --json) CITT_JSON=1 ;;
      --csv) csv=1 ;;
      --help | -h)
        help_findings
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  check_project_flags
  is_uint "$limit" || usage_error "--limit needs a number"
  if [ "$csv" = 1 ] && [ "$CITT_JSON" = 1 ]; then usage_error "use --json or --csv, not both"; fi
  need_auth
  resolve_project
  local rows cursor="" more=""
  rows="$(tmpfile rows)"
  printf '[]' >"$rows"
  while :; do
    call GET "$CITT_V1/projects/$PROJECT_ID/findings$(query rule "$rule" family "$family" severity "$severity" \
      source "$source" package_id "$app" verdict "$verdict" limit "$limit" cursor "$cursor")"
    jq -e '.findings | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unparseable findings response"
    if [ "$all" = 0 ]; then
      if [ "$CITT_JSON" = 1 ]; then
        cat "$RESP"
        printf '\n'
        return 0
      fi
      jq '.findings' "$RESP" >"$rows"
      more="$(jq -r '.next_cursor // empty' "$RESP")"
      break
    fi
    jq -s '.[0] + .[1].findings' "$rows" "$RESP" >"$rows.n" && mv "$rows.n" "$rows"
    cursor="$(jq -r '.next_cursor // empty' "$RESP")"
    [ -n "$cursor" ] || break
  done
  if [ "$CITT_JSON" = 1 ]; then
    jq -c '{schema: "citt.plugin.findings/1", findings: .}' "$rows"
    return 0
  fi
  if [ "$csv" = 1 ]; then
    jq -r "$JQ_CSV"'
      ["finding_id", "package_id", "platform", "source", "rule_id", "family", "severity", "title", "subject", "evidence_total", "verdict"],
      (.[] | [.finding_id, .package_id, .platform, .source, .rule_id, .family, .severity, .title, .subject,
        .evidence_total, (if .latest_event.kind == "scrutiny" then .latest_event.verdict else null end)])
      | csvrow' "$rows"
  else
    jq -c '
      def cut($n): if length > $n then .[0:$n] + "..." else . end;
      [["SEVERITY", "FAMILY", "APP", "RULE", "SUBJECT", "VERDICT", "FINDING_ID"]]
      + [.[] | [.severity, .family, .package_id, (.rule_id // .source), (.subject // "" | gsub("[\r\n\t]"; " ") | cut(80)),
          (if .latest_event.kind == "scrutiny" then (.latest_event.verdict // "-") else "-" end), .finding_id]]' "$rows" | table
  fi
  if [ -n "$more" ]; then
    err "$(jq 'length' "$rows") findings shown and more exist; use --all or --limit"
  fi
}
