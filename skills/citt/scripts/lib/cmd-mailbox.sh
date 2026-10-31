#!/usr/bin/env bash
# lib/cmd-mailbox.sh: citt mailbox create|list|show (NP-867) and email ID --html FILE (NP-903). Lab addresses on the lab mail domain: one made by hand
# (POST /lab-mail/addresses, a manual credential with no password; the researcher signs up with a password of their own), the
# account's addresses (GET /lab-mail/addresses, every page), and one address with its emails, codes and links
# (GET /lab-mail/addresses/{address or credential id}). Mail to an address stays linked to its run and session with no time limit.
# shellcheck shell=bash disable=SC2016

# The lab mail domain (04 point 18); the service checks it, this names a local part in messages only.
MB_DOMAIN=pinegrovemail.com
MB_NOTE_MAX=500

# MB_JQ: `links`, the project, app, run and session of a LabAddress as words (needs $L from local_times); `kind_word`.
MB_JQ="$JQ_LT"'
def kind_word: if .kind == "manual" then "made by hand" else "sign-up session" end;
def links: [ (if .project_id then "project \(.project_id)" else empty end),
             (if .app.package_id then "app \(.app.label // .app.package_id)" else empty end),
             (if .run_id then "run \(.run_id)" else empty end),
             (if .session_id then "session \(.session_seq // .session_id)"
                + (if .session_ended_at then " (ended \(.session_ended_at | lt))" else "" end) else empty end) ]
  | if length == 0 then "none" else join(", ") end;'

cmd_mailbox() {
  local sub="${1:-}"
  CITT_CMD="citt mailbox"
  case "$sub" in
    --help | -h)
      help_mailbox
      exit 0
      ;;
    create | list | show | email) shift ;;
    '') usage_error "a subcommand is required: citt mailbox create|list|show|email" ;;
    *) usage_error "unknown subcommand $sub: citt mailbox create|list|show|email" ;;
  esac
  # shellcheck disable=SC2034  # read by err and fail_out in lib/common.sh
  CITT_CMD="citt mailbox $sub"
  "_mb_$sub" "$@"
}

_mb_create() {
  local local_part="" project="" app="" run="" session="" note="" have_note=0 pw_mode=generate password=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --local | --project | --app | --run | --session | --note)
        need_value "$1" $#
        case "$1" in
          --local) local_part="$2" ;;
          --project) project="$2" ;;
          --app) app="$2" ;;
          --run) run="$2" ;;
          --session) session="$2" ;;
          --note)
            note="$2"
            have_note=1
            ;;
        esac
        shift
        ;;
      --password-stdin) pw_mode=stdin ;;
      --no-password) pw_mode=none ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_mailbox
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  if [ "$pw_mode" = stdin ]; then
    IFS= read -r password || [ -n "$password" ] || usage_error "--password-stdin reads the password from the first line of stdin, and it is empty"
    [ -n "$password" ] || usage_error "--password-stdin reads the password from the first line of stdin, and it is empty"
  fi
  [ -z "$project" ] || is_uint "$project" || usage_error "--project takes the project id (a number), got: $project"
  [ -z "$run" ] || is_uint "$run" || usage_error "--run takes the run id (a number), got: $run"
  [ -z "$session" ] || is_uint "$session" || usage_error "--session takes the session id (a number), got: $session"
  [ -z "$app" ] || [ -n "$project" ] || [ -n "$run" ] || usage_error "--app needs --project (or --run, whose app it is)"
  [ "$(jq -rn --arg t "$note" '$t | length')" -le "$MB_NOTE_MAX" ] || usage_error "--note is at most $MB_NOTE_MAX characters"
  local body
  body="$(tmpfile mailbox_create)"
  # QA round 2 R2-P1: the password reaches jq on stdin (printf is a builtin), never as an argument in a process's argv.
  printf '%s\n' "$password" | jq -Rc --arg l "$local_part" --arg p "$project" --arg a "$app" --arg r "$run" --arg s "$session" --arg n "$note" --arg hn "$have_note" --arg pm "$pw_mode" '
    . as $pw | {} + (if $l != "" then {local_part: $l} else {} end) + (if $p != "" then {project_id: ($p | tonumber)} else {} end)
       + (if $a != "" then {package_id: $a} else {} end) + (if $r != "" then {run_id: ($r | tonumber)} else {} end)
       + (if $s != "" then {session_id: ($s | tonumber)} else {} end) + (if $hn == "1" then {note: $n} else {} end)
       + (if $pm == "stdin" then {password: $pw} elif $pm == "none" then {password_generate: false} else {} end)' >"$body"
  password=""
  need_auth
  # One attempt only: a retried POST could meet its own new address and read as taken.
  # shellcheck disable=SC2034  # read by http in lib/common.sh
  HTTP_RETRY=no
  http POST "$CITT_V1/lab-mail/addresses" "$body"
  if ok; then
    jq -e '.credential_id | type == "string"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from POST $CITT_V1/lab-mail/addresses"
    if [ "$CITT_JSON" = 1 ]; then
      jq -c . "$RESP"
      return 0
    fi
    jq -r --argjson L "$(local_times "$RESP")" --arg page "$(app_url "/mailboxes/$(jq -r .credential_id "$RESP")")" "$MB_JQ"'
      "Created \(.address) (credential \(.credential_id))", "Links: \(links)", "Mailbox page: \($page)",
      (if .has_password then "Password: stored; show it with: citt mailbox show \(.address) --reveal" else "Password: none stored" end),
      "Mail to it shows on that page and with: citt mailbox show \(.address)"' "$RESP"
    return 0
  fi
  local error shown="$local_part" what
  error="$(body_field '.error')"
  case "$shown" in '' | *@*) ;; *) shown="$shown@$MB_DOMAIN" ;; esac
  case "$CODE:$error" in
    409:address_taken)
      die 5 "${shown:-the generated address} is taken; choose another --local, or leave it out for a generated name"
      ;;
    409:address_has_mail)
      die 5 "${shown:-this address} received mail before it was created here, so it cannot be created by hand. Choose another address, or contact support to link that mail to a session."
      ;;
    404:not_found)
      what=""
      [ -z "$run" ] || what="run $run"
      [ -z "$session" ] || what="${what:+$what, }session $session"
      [ -n "$what" ] || what="project ${project:-?}"
      die 4 "$what is not among yours (a run is linked by the account that launched it); list your runs: citt captures"
      ;;
  esac
  fail_http
}

_mb_list() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_mailbox
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  need_auth
  local all cursor="" pages=0
  all="$(tmpfile mailbox_list)"
  printf '[]' >"$all"
  while :; do
    call GET "$CITT_V1/lab-mail/addresses$(query cursor "$cursor")"
    jq -e '.addresses | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unparseable response from GET $CITT_V1/lab-mail/addresses"
    jq -c --slurpfile p "$RESP" '. + $p[0].addresses' "$all" >"$all.n" && mv "$all.n" "$all"
    cursor="$(jq -r '.next_cursor // empty' "$RESP")"
    pages=$((pages + 1))
    if [ -z "$cursor" ] || [ "$pages" -ge 200 ]; then
      break
    fi
  done
  if [ "$CITT_JSON" = 1 ]; then
    jq -c '{addresses: .}' "$all"
    return 0
  fi
  if [ "$(jq 'length' "$all")" = 0 ]; then
    printf 'No lab addresses yet; make one: citt mailbox create\n'
    return 0
  fi
  jq -c --argjson L "$(local_times "$all")" "$MB_JQ"'
    [["Address", "Kind", "App", "Run", "Session", "Emails", "Last email"]]
    + [.[] | [.address, (if .kind == "manual" then "by hand" else "sign-up" end), (.app.label // .app.package_id), .run_id,
        .session_seq, .mail_count, (.last_received_at | lt)]]' "$all" | table
}

# _mb_clipboard: the clipboard command of this desktop (pbcopy on macOS, wl-copy under Wayland, xclip under X), or nothing;
# CITT_CLIPBOARD=off skips the clipboard.
_mb_clipboard() {
  [ "${CITT_CLIPBOARD:-}" != off ] || return 0
  if command -v pbcopy >/dev/null 2>&1 && [ "$(uname -s)" = Darwin ]; then
    printf 'pbcopy'
  elif [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
    printf 'wl-copy'
  elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then
    printf 'xclip'
  fi
}

# _mb_reveal_to CRED: puts the password of $RESP on the clipboard (prints `clipboard`) or in the mode-600 file
# $CITT_STATE/revealed/CRED.txt (prints its path). QA round 2 R2-P1, decision 31: stdout is a model's input when an agent runs
# the plugin, so the value goes to a place only the user opens; it passes through a pipe, never an argument.
_mb_reveal_to() {
  local clip dir file
  clip="$(_mb_clipboard)"
  case "$clip" in
    pbcopy | wl-copy)
      if jq -j '.password' "$RESP" | "$clip" >/dev/null 2>&1; then
        printf 'clipboard'
        return 0
      fi
      ;;
    xclip)
      if jq -j '.password' "$RESP" | xclip -selection clipboard >/dev/null 2>&1; then
        printf 'clipboard'
        return 0
      fi
      ;;
  esac
  dir="$CITT_STATE/revealed"
  file="$dir/$1.txt"
  (
    umask 077
    mkdir -p "$dir" && chmod 700 "$dir" && rm -f "$file" && jq -j '.password' "$RESP" >"$file" && chmod 600 "$file"
  ) || die 1 "could not write the password file $file"
  printf '%s' "$file"
}

_mb_show() {
  local ref="" reveal=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) CITT_JSON=1 ;;
      --reveal) reveal=1 ;;
      --help | -h)
        help_mailbox
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$ref" ] || usage_error "one address or credential id"
        ref="$1"
        ;;
    esac
    shift
  done
  [ -n "$ref" ] || usage_error "an address or credential id is required: citt mailbox show ADDRESS"
  need_auth
  http GET "$CITT_V1/lab-mail/addresses/$(urlenc "$ref")"
  if ! ok; then
    [ "$CODE:$(body_field '.error')" != 404:not_found ] || die 4 "$ref is not among your lab addresses; list them: citt mailbox list"
    fail_http
  fi
  jq -e '.credential.credential_id | type == "string"' "$RESP" >/dev/null 2>&1 || die 1 "unparseable response from GET $CITT_V1/lab-mail/addresses"
  local cred shown=""
  cred="$(jq -r .credential.credential_id "$RESP")"
  if [ "$reveal" = 1 ]; then
    local saved
    saved="$(tmpfile mailbox_show)"
    cp "$RESP" "$saved"
    http GET "$CITT_V1/lab-mail/addresses/$cred/password"
    if ! ok; then
      case "$CODE:$(body_field '.error')" in
        404:no_password) die 4 "no password is stored for $ref; the account was made with a password of its own" ;;
        503:seal_key_missing) die 5 "$(body_field '.message')" ;;
      esac
      fail_http
    fi
    jq -e '.password | type == "string" and length > 0' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from GET $CITT_V1/lab-mail/addresses/$cred/password"
    shown="$(_mb_reveal_to "$cred")" || exit 1
    cp "$saved" "$RESP"
  fi
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --arg shown "$shown" '
      if $shown == "clipboard" then . + {password_copied: true}
      elif $shown != "" then . + {password_file: $shown} else . end' "$RESP"
    return 0
  fi
  local page
  page="$(app_url "/mailboxes/$cred")"
  jq -r --argjson L "$(local_times "$RESP")" --arg page "$page" --arg shown "$shown" "$MB_JQ"'
    .credential | "\(.address) (credential \(.credential_id), \(kind_word))",
      (if .note then "Note: \(.note)" else empty end), "Links: \(links)",
      (if $shown == "clipboard" then "Password: copied to the clipboard"
       elif $shown != "" then "Password: written to \($shown) (mode 600); open it yourself and delete it after signing in"
       elif .has_password then "Password: stored; reveal it with --reveal" else "Password: none stored" end),
      "Mailbox page: \($page)", "Emails: \(.mail_count)"' "$RESP"
  [ "$(jq '.emails | length' "$RESP")" != 0 ] || return 0
  jq -c --argjson L "$(local_times "$RESP")" "$MB_JQ"'
    (.credential.session_ended_at | ts) as $end
    | [["Received", "After the session", "From", "Subject", "Code"]]
    + [.emails[] | [(.received_at | lt),
        (if $end == 0 then "-" elif (.received_at | ts) < $end then "during the session" else "\((.received_at | ts) - $end | dur) after" end),
        .sender, (.subject // "(no subject)"), .code]]' "$RESP" | table
  jq -r '.emails[] | select(.link) | "Email \(.id) link: \(.link)"' "$RESP"
  jq -r '.emails[0].id | "Save an email'"'"'s HTML: citt mailbox email \(.) --html \(.).html"' "$RESP"
  [ -z "$(jq -r '.next_cursor // empty' "$RESP")" ] || printf 'Older emails are on the Mailbox page: %s\n' "$page"
}

# _mb_email ID --html FILE (NP-903): GET /lab-mail/emails/{id}/html (the HTML part decoded to UTF-8, its head starting with a CSP
# meta tag so a browser opening the file loads no remote image or tracking pixel) written to FILE, mode 600. The body is never
# printed: stdout is a model's input when an agent runs the plugin.
_mb_email() {
  local id="" file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --html)
        need_value "$1" $#
        file="$2"
        shift
        ;;
      --help | -h)
        help_mailbox
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$id" ] || usage_error "one email id"
        id="$1"
        ;;
    esac
    shift
  done
  case "$id" in '' | *[!0-9]* | 0*) usage_error "an email id is required: citt mailbox email ID --html FILE (the ids are in citt mailbox show)" ;; esac
  [ -n "$file" ] || usage_error "--html FILE is required: citt mailbox email $id --html $id.html"
  [ ! -e "$file" ] || usage_error "$file exists; give a new file"
  need_auth
  local out
  out="$(tmpfile mailbox_html)"
  HTTP_OUT="$out" http GET "$CITT_V1/lab-mail/emails/$id/html"
  if ! ok; then
    cp "$out" "$RESP"
    case "$CODE:$(body_field '.error')" in
      404:not_found) die 4 "email $id is not among the emails you can read; list an address's emails: citt mailbox show ADDRESS" ;;
      404:no_html_part) die 4 "$(body_field '.message') Download the raw message from the Mailboxes page, or list the address's emails: citt mailbox show ADDRESS" ;;
    esac
    fail_http
  fi
  (
    umask 077
    cp "$out" "$file" && chmod 600 "$file"
  ) || die 1 "could not write $file"
  printf 'Wrote the HTML of email %s to %s (mode 600). Remote images and tracking pixels are blocked when you open it.\n' "$id" "$file"
}
