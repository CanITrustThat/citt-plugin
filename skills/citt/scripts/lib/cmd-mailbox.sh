#!/usr/bin/env bash
# lib/cmd-mailbox.sh: citt mailbox create|list|show (NP-867) and email ID --html FILE (NP-903). Lab addresses on the lab mail domain: one made by hand
# (POST /lab-mail/addresses, a manual credential with no password; the researcher signs up with a password of their own), the
# account's addresses (GET /lab-mail/addresses, every page), and one address with its emails, codes and links
# (GET /lab-mail/addresses/{address or credential id}). Mail to an address stays linked to its run and session with no time limit.
# shellcheck shell=bash disable=SC2016

# The lab mail domain (04 point 18); the service checks it, this names a local part in messages only.
# NP-928 (Filip, 2026-11-03): new addresses on pelmu.me; --domain pinegrovemail.com makes one on the old domain, which keeps receiving.
MB_DOMAIN=pelmu.me
MB_NOTE_MAX=500

# MB_JQ: `links`, the project, app, run and session of a LabAddress as words (needs $L from local_times); `kind_word`.
# MASK_JQ (NP-924 QA rounds 1 and 2): the plugin's stdout is a model's input (decision 31), and Filip's rule keeps codes and phone
# numbers from models: `codetag` a code as its length, `clen` a code as its length in --json, `has_url`, `mask_meta` a subject or
# sender with its links, codes and digit tokens masked. No email snippet or SMS text is printed.
MASK_JQ='
def codetag: if test("^\\p{Nd}+$") then "[code, \(length) digits]" else "[code, \(length) characters]" end;
def clen: if type == "string" then length else . end;
# NP-1358 QA round 1 P1-1: --json prints only the fields named here (deny by default): no number, code, password, body, snippet or
# link reaches stdout, also from a field the server adds later
# QA round 2 R2-1: a named key keeps its value only when it is a scalar or a list of scalars; a nested object is printed only through
# its own pick (`safe_app`, `safe_credential`, ...), so no field inside it passes unnamed
def scalarish: (type | IN("string", "number", "boolean", "null")) or (type == "array" and all(.[]; type | IN("string", "number", "boolean", "null")));
def pick($ks): . as $o | reduce $ks[] as $k ({}; if ($o | type) == "object" and ($o | has($k)) and ($o[$k] | scalarish) then . + {($k): $o[$k]} else . end);
def safe_app: if type == "object" then pick(["project_app_id", "label", "package_id"]) else null end;
def safe_number: pick(["id", "number_last4", "state", "release_outcome", "run_id", "session_id", "session_seq"]);
def safe_phone: (pick(["id", "provider", "kind", "state", "service_name", "number_last4", "number_type", "cost_cents", "ends_at", "reusable_until",
    "renew", "mock", "user_id", "project_id", "project_app_id", "run_id", "session_id", "session_seq", "credential_id", "created_at",
    "updated_at", "sms_count", "last_code_at", "code_wait_until", "released_at", "release_reason", "release_outcome", "refund_cents"])
  + {last_code_length: (.last_code | clen)});
def safe_credential: pick(["credential_id", "address", "status", "kind", "note", "has_password", "project_id", "run_id", "session_id",
    "session_seq", "session_ended_at", "created_at", "mail_count", "last_received_at", "last_code_at", "user_id"]) + {app: (.app | safe_app)};
def safe_session: pick(["run_id", "seq", "session_id", "ended_at", "address", "phone_ids"]);
# NP-924 QA round 2 (decision): stdout prints no email snippet or SMS text. A subject or sender keeps its words, with every link
# (any `scheme://`, `www.`, `host.tld/path` and `host.tld?query`, hosts in any script) as `[link]`, the token after a code word
# (code, PIN, OTP, passcode, verification, confirm...) and the token before "is your ... code" as `[code]`, every all-capital token
# of 4 to 14 letters (any script, dashes inside) and every token holding a digit (any script) as `[masked]` (QA round 3 R3-2).
def has_url: test("(?i)(?:https?://|www\\.)\\S|\\b[a-z0-9-]+(?:\\.[a-z0-9-]+)+/");
# `mask_message`: a server message (an error answer) with the masks below but the all-capital rule, which would take words such as HTML.
def mask_message: if type != "string" then . else
  gsub("(?i)\\b[a-z][a-z0-9+.-]*://\\S+"; "[link]")
  | gsub("(?i)\\bwww\\.\\S+"; "[link]")
  | gsub("(?i)\\b[\\p{L}\\p{N}-]+(?:\\.[\\p{L}\\p{N}-]+)+[/?]\\S*"; "[link]")
  | gsub("(?i)(?<w>\\b(?:code|pin|otp|passcode|verification|confirm[a-z]*)\\b[^\\p{L}\\p{N}]{0,3}(?:(?:is|was)[^\\p{L}\\p{N}]{1,3})?)(?!(?:code|pin|otp|passcode|is|was)\\b)(?<t>[\\p{L}\\p{N}](?:[\\p{L}\\p{N}]|-(?=[\\p{L}\\p{N}])){3,63})(?![\\p{L}\\p{N}])"; "\(.w)[code]")
  | gsub("(?i)\\b[\\p{L}\\p{N}](?:[\\p{L}\\p{N}]|-(?=[\\p{L}\\p{N}])){3,31}(?=\\s+(?:is|was|=)\\s+(?:your|the|a)\\s+(?:\\S+\\s+){0,2}(?:code|pin|otp|passcode|verification|confirm[a-z]*)\\b)"; "[code]")
  | gsub("\\S*\\p{N}\\S*"; "[masked]")
  end;
def mask_meta: if type != "string" then . else
  gsub("(?i)\\b[a-z][a-z0-9+.-]*://\\S+"; "[link]")
  | gsub("(?i)\\bwww\\.\\S+"; "[link]")
  | gsub("(?i)\\b[\\p{L}\\p{N}-]+(?:\\.[\\p{L}\\p{N}-]+)+[/?]\\S*"; "[link]")
  | gsub("(?i)(?<w>\\b(?:code|pin|otp|passcode|verification|confirm[a-z]*)\\b[^\\p{L}\\p{N}]{0,3}(?:(?:is|was)[^\\p{L}\\p{N}]{1,3})?)(?!(?:code|pin|otp|passcode|is|was)\\b)(?<t>[\\p{L}\\p{N}](?:[\\p{L}\\p{N}]|-(?=[\\p{L}\\p{N}])){3,63})(?![\\p{L}\\p{N}])"; "\(.w)[code]")
  | gsub("(?i)\\b[\\p{L}\\p{N}](?:[\\p{L}\\p{N}]|-(?=[\\p{L}\\p{N}])){3,31}(?=\\s+(?:is|was|=)\\s+(?:your|the|a)\\s+(?:\\S+\\s+){0,2}(?:code|pin|otp|passcode|verification|confirm[a-z]*)\\b)"; "[code]")
  | gsub("(?<![\\p{L}\\p{N}])\\p{Lu}(?:\\p{Lu}|-(?=\\p{Lu})){3,13}(?![\\p{L}\\p{N}])"; "[masked]")
  | gsub("\\S*\\p{N}\\S*"; "[masked]")
  end;
'

MB_JQ="$JQ_LT$MASK_JQ"'
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
  # shellcheck disable=SC2034  # read by mask_server_text and fail_out in lib/common.sh
  CITT_MASK_JQ="$MASK_JQ"
  "_mb_$sub" "$@"
}

_mb_create() {
  local local_part="" project="" app="" run="" session="" note="" have_note=0 pw_mode=generate password="" domain=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --local | --project | --app | --run | --session | --note | --domain)
        need_value "$1" $#
        case "$1" in
          --local) local_part="$2" ;;
          --domain) domain="$2" ;;
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
  printf '%s\n' "$password" | jq -Rc --arg l "$local_part" --arg p "$project" --arg a "$app" --arg r "$run" --arg s "$session" --arg n "$note" --arg hn "$have_note" --arg pm "$pw_mode" --arg d "$domain" '
    . as $pw | {} + (if $l != "" then {local_part: $l} else {} end) + (if $d != "" then {domain: $d} else {} end) + (if $p != "" then {project_id: ($p | tonumber)} else {} end)
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
    jq -e '.credential_id | type == "string"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
    if [ "$CITT_JSON" = 1 ]; then
      jq -c . "$RESP"
      return 0
    fi
    jq -r --argjson L "$(local_times "$RESP")" --arg page "$(app_url "/inbox/$(jq -r .credential_id "$RESP")")" "$MB_JQ"'
      "Created \(.address) (credential \(.credential_id))", "Links: \(links)", "Inbox page: \($page)",
      (if .has_password then "Password: stored; show it with: citt mailbox show \(.address) --reveal" else "Password: none stored" end),
      "Mail to it shows on that page and with: citt mailbox show \(.address)"' "$RESP"
    return 0
  fi
  local error shown="$local_part" what
  error="$(body_field '.error')"
  case "$shown" in '' | *@*) ;; *) shown="$shown@${domain:-$MB_DOMAIN}" ;; esac
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
    jq -e '.addresses | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
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

# _mb_reveal_to NAME [FILTER]: puts the string FILTER makes of $RESP (default: the password) on the clipboard (prints
# `clipboard`) or in the mode-600 file $CITT_STATE/revealed/NAME.txt (prints its path). QA round 2 R2-P1, decision 31: stdout
# is a model's input when an agent runs the plugin, so the value goes to a place only the user opens; it passes through a
# pipe, never an argument. NP-924: citt inbox PHONE_ID --reveal hands over the codes of a number this way.
_mb_reveal_to() {
  local clip dir file filter="${2:-.password}"
  clip="$(_mb_clipboard)"
  case "$clip" in
    pbcopy | wl-copy)
      if jq -j "$filter" "$RESP" | "$clip" >/dev/null 2>&1; then
        printf 'clipboard'
        return 0
      fi
      ;;
    xclip)
      if jq -j "$filter" "$RESP" | xclip -selection clipboard >/dev/null 2>&1; then
        printf 'clipboard'
        return 0
      fi
      ;;
  esac
  dir="$CITT_STATE/revealed"
  file="$dir/$1.txt"
  (
    umask 077
    mkdir -p "$dir" && chmod 700 "$dir" && rm -f "$file" && jq -j "$filter" "$RESP" >"$file" && chmod 600 "$file"
  ) || die 1 "could not write the file $file"
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
    # NP-924 QA round 3 R3-6: lab mail off on the server
    [ "$CODE:$(body_field '.error')" != 404:lab_mail_off ] || die 4 "Lab addresses are not available right now: lab mail is off on this server; try again later, or contact support"
    fail_http
  fi
  jq -e '.credential.credential_id | type == "string"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  local cred shown="" codes_file="" has_secrets addr
  cred="$(jq -r .credential.credential_id "$RESP")"
  addr="$(tmpfile mailbox_show)"
  cp "$RESP" "$addr"
  # NP-924 QA round 1 Q11: email codes and links are not printed (decision 31); --reveal writes them to a mode-600 file
  has_secrets="$(jq '[.emails[] | select((.code // "") != "" or (.link // "") != "" or (.snippet // "") != "")] | length > 0' "$addr")"
  if [ "$reveal" = 1 ]; then
    local has_pw
    has_pw="$(jq -r '.credential.has_password == true' "$addr")"
    [ "$has_pw" = true ] || [ "$has_secrets" = true ] || die 4 "no password is stored for $ref and no email on this page has a code or a link"
    if [ "$has_pw" = true ]; then
      http GET "$CITT_V1/lab-mail/addresses/$cred/password"
      if ! ok; then
        case "$CODE:$(body_field '.error')" in
          404:no_password) die 4 "no password is stored for $ref; the account was made with a password of its own" ;;
          503:seal_key_missing) die 5 "the stored password cannot be read right now; try again later, or ask the CITT team" ;;
        esac
        fail_http
      fi
      jq -e '.password | type == "string" and length > 0' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
      shown="$(_mb_reveal_to "$cred")" || exit 1
    fi
    if [ "$has_secrets" = true ]; then
      local dir="$CITT_STATE/revealed"
      codes_file="$dir/$cred-codes.txt"
      (
        umask 077
        mkdir -p "$dir" && chmod 700 "$dir" && rm -f "$codes_file" \
          && jq -r '.emails[] | (if (.code // "") != "" then "Email \(.id) code: \(.code)" else empty end),
              (if (.link // "") != "" then "Email \(.id) link: \(.link)" else empty end),
              (if (.snippet // "") != "" then "Email \(.id) snippet: \(.snippet)" else empty end)' "$addr" >"$codes_file" \
          && chmod 600 "$codes_file"
      ) || die 1 "could not write the file $codes_file"
    fi
  fi
  cp "$addr" "$RESP"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --arg shown "$shown" --arg codes "$codes_file" "$MASK_JQ"'
      {credential: (.credential | safe_credential), phones: ((.phones // []) | map(safe_phone)),
        sessions: ((.sessions // []) | map(safe_session)), next_cursor,
        emails: ((.emails // []) | map((pick(["id", "credential_id", "recipient", "received_at", "body_state", "spam_verdict", "virus_verdict"])
          + {subject: (.subject | mask_meta), sender: (.sender | mask_meta), has_link: ((.link // "") != ""),
             has_code: ((.code // "") != ""), code_length: (.code | clen), snippet_length: ((.snippet // "") | length)})))}
      | (if $shown == "clipboard" then . + {password_copied: true}
         elif $shown != "" then . + {password_file: $shown} else . end)
      | (if $codes != "" then . + {codes_file: $codes} else . end)' "$RESP"
    return 0
  fi
  local page
  page="$(app_url "/inbox/$cred")"
  jq -r --argjson L "$(local_times "$RESP")" --arg page "$page" --arg shown "$shown" "$MB_JQ"'
    .credential | "\(.address) (credential \(.credential_id), \(kind_word))",
      (if .note then "Note: \(.note)" else empty end), "Links: \(links)",
      (if $shown == "clipboard" then "Password: copied to the clipboard"
       elif $shown != "" then "Password: written to \($shown) (mode 600); open it yourself and delete it after signing in"
       elif .has_password then "Password: stored; reveal it with --reveal" else "Password: none stored" end),
      "Inbox page: \($page)", "Emails: \(.mail_count)"' "$RESP"
  [ "$(jq '.emails | length' "$RESP")" != 0 ] || return 0
  jq -c --argjson L "$(local_times "$RESP")" "$MB_JQ"'
    (.credential.session_ended_at | ts) as $end
    | ([.emails[].code | select(type == "string" and length > 0)] | unique | sort_by(-length)) as $cs
    | [["Received", "After the session", "From", "Subject", "Snippet", "Code", "Link"]]
    + [.emails[] | [(.received_at | lt),
        (if $end == 0 then "-" elif (.received_at | ts) < $end then "during the session" else "\((.received_at | ts) - $end | dur) after" end),
        (.sender | mask_meta), (.subject // "(no subject)" | mask_meta), "\((.snippet // "") | length) characters",
        (if (.code // "") != "" then (.code | codetag) else "" end), (if (.link // "") != "" then "yes" else "" end)]]' "$RESP" | table
  if [ -n "$codes_file" ]; then
    printf 'Codes, links and snippets: written to %s (mode 600); open it yourself\n' "$codes_file"
  elif [ "$has_secrets" = true ]; then
    printf 'Codes, links and snippets are not printed here; write them to a mode-600 file: citt mailbox show %s --reveal\n' "$ref"
  fi
  jq -r '.emails[0].id | "Save an email'"'"'s HTML: citt mailbox email \(.) --html \(.).html"' "$RESP"
  [ -z "$(jq -r '.next_cursor // empty' "$RESP")" ] || printf 'Older emails are on the Inbox page of the address: %s\n' "$page"
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
      404:no_html_part) die 4 "$(mask_server_text "$(body_field '.message')") Download the raw message from the Mailboxes page, or list the address's emails: citt mailbox show ADDRESS" ;;
    esac
    fail_http
  fi
  (
    umask 077
    cp "$out" "$file" && chmod 600 "$file"
  ) || die 1 "could not write $file"
  printf 'Wrote the HTML of email %s to %s (mode 600). Remote images and tracking pixels are blocked when you open it.\n' "$id" "$file"
}
