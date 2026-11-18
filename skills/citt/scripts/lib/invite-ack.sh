#!/usr/bin/env bash
# lib/invite-ack.sh: the inviter warning of decision E1 (TASK-781a), shown before every project invite of the plugin (citt
# owners --add, tortscope invite). Without --confirm the command prints this text with the address and exits 2 before any
# request. With --confirm it reads GET /invite-ack-text and sends {ack: {text_version, confirmed: true}} when the service's
# current version is the one printed here (or the one given with --ack-version); a newer text is printed and the command
# exits 2 without inviting.
# shellcheck shell=bash disable=SC2034

INVITE_ACK_VERSION="e1-2026-11-17"
INVITE_ACK_BODY="[Name] will see everything in this project: recordings, network records, findings and exports. You are responsible for inviting only people who are allowed to see it."

# invite_ack_line BODY EMAIL: BODY with EMAIL in place of [Name].
invite_ack_line() {
  case "$1" in
    *"[Name]"*) printf '%s%s%s\n' "${1%%\[Name\]*}" "$2" "${1#*\[Name\]}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# invite_ack_refuse EMAIL...: the warning for each address on stdout and the --confirm line on stderr; exit 2.
invite_ack_refuse() {
  local e
  for e in "$@"; do
    printf 'Before you invite %s:\n' "$e"
    invite_ack_line "$INVITE_ACK_BODY" "$e"
  done
  err "$CITT_CMD: read the warning above; to invite, run the same command again with --confirm"
  exit 2
}

# invite_ack_fetch EMAIL...: GET /invite-ack-text; sets INVITE_ACK_TEXT_VERSION to the service's current version when it is
# the accepted one (--ack-version, else INVITE_ACK_VERSION). Otherwise prints the current text for each address and exits 2.
invite_ack_fetch() {
  local v body e accept="${INVITE_ACK_ACCEPT:-$INVITE_ACK_VERSION}"
  call GET "$CITT_V1/invite-ack-text"
  v="$(body_field '.version')"
  body="$(body_field '.body')"
  if [ -z "$v" ] || [ -z "$body" ]; then die 1 "unexpected response from the server"; fi
  if [ "$v" != "$accept" ]; then
    for e in "$@"; do
      printf 'Before you invite %s:\n' "$e"
      invite_ack_line "$body" "$e" | clean
    done
    err "$CITT_CMD: the warning changed (version $v); read it above, then run the same command again with --confirm --ack-version $v"
    exit 2
  fi
  INVITE_ACK_TEXT_VERSION="$v"
}
