#!/usr/bin/env bash
# lib/cmd-owners.sh: citt owners. TASK-781a: --add shows the inviter warning of decision E1 (lib/invite-ack.sh) and invites
# only with --confirm; the invite carries the acknowledgment of the service's current warning version.
# shellcheck shell=bash disable=SC2034

cmd_owners() {
  local n op email confirm=0
  local -a ops adds
  ops=()
  adds=()
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --add | --remove)
        need_value "$1" $#
        ops+=("$1 $2")
        shift
        ;;
      --confirm) confirm=1 ;;
      --ack-version)
        need_value "$1" $#
        INVITE_ACK_ACCEPT="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_owners
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  check_project_flags
  if [ "${#ops[@]}" -gt 0 ]; then
    for op in ${ops[@]+"${ops[@]}"}; do
      email="${op#* }"
      case "$email" in
        *@*@* | @* | *@ | *[[:space:]]*) usage_error "not an email address: $email" ;;
        *@*) ;;
        *) usage_error "not an email address: $email" ;;
      esac
      case "$op" in --add*) adds+=("$email") ;; esac
    done
  fi
  if [ "${#adds[@]}" -gt 0 ] && [ "$confirm" = 0 ]; then
    invite_ack_refuse ${adds[@]+"${adds[@]}"}
  fi
  need_auth
  resolve_project
  [ "${#adds[@]}" -eq 0 ] || invite_ack_fetch ${adds[@]+"${adds[@]}"}
  if [ "${#ops[@]}" -eq 0 ]; then
    call GET "$CITT_V1/projects/$PROJECT_ID/owners"
  else
    local body
    body="$(tmpfile owner_body)"
    for op in ${ops[@]+"${ops[@]}"}; do
      email="${op#* }"
      E_EMAIL="$email"
      case "$op" in
        --add*)
          jq -nc --arg e "$email" --arg v "$INVITE_ACK_TEXT_VERSION" '{email: $e, ack: {text_version: $v, confirmed: true}}' >"$body"
          call POST "$CITT_V1/projects/$PROJECT_ID/owners" "$body"
          ;;
        *)
          E_KIND=owner
          call DELETE "$CITT_V1/projects/$PROJECT_ID/owners/$(urlenc "$email")"
          E_KIND=project
          ;;
      esac
    done
  fi
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    printf '\n'
    return 0
  fi
  if [ -n "$PROJECT_NAME" ]; then
    printf 'Owners of %s (id %s):\n' "$PROJECT_NAME" "$PROJECT_ID"
  else
    printf 'Owners of project %s:\n' "$PROJECT_ID"
  fi
  jq -r '(.owners // []) | (map(.email | length) | max // 0) as $w
    | .[] | "  " + .email + ([range(0; $w - (.email | length) + 3)] | map(" ") | join("")) + "added \(.added_at)"' "$RESP" \
    || die 1 "unparseable owners response"
}
