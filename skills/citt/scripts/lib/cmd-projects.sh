#!/usr/bin/env bash
# lib/cmd-projects.sh: citt projects.
# shellcheck shell=bash disable=SC2034

cmd_projects() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_projects
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  need_auth
  call GET "$CITT_V1/projects"
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  if [ "$(jq '.projects | length' "$RESP" 2>/dev/null)" = 0 ]; then
    printf 'No projects. Create one with: citt submit --project NAME --csv FILE\n'
    return 0
  fi
  jq -c '[["ID", "NAME", "APPS", "QUEUED", "ACQUIRING", "SCANNING", "DONE", "FAILED", "NOT_FOUND", "ACTIVE_JOBS", "CREATED"]]
    + [.projects | sort_by(.project_id)[] | .apps_by_status as $a | .jobs_by_status as $j
       | [.project_id, .name, .app_count, ($a.queued // 0), ($a.acquiring // 0), ($a.scanning // 0),
          ($a.done // 0), ($a.failed // 0), ($a.not_found // 0),
          (($j.queued // 0) + ($j.running // 0) + ($j.waiting_legacy // 0) + ($j.waiting_restore // 0)),
          .created_at]]' "$RESP" | table
}
