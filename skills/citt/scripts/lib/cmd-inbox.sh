#!/usr/bin/env bash
# lib/cmd-inbox.sh: citt inbox (NP-924 change point 6). The account's lab addresses and phone numbers (GET /inbox, every page),
# one number with its texts (GET /lab-phones/{id}), and one address (citt mailbox show).
# Filip's rule: phone numbers and SMS codes are never sent to a model. Stdout is a model's input when an agent runs the plugin
# (decision 31 in cmd-mailbox.sh), so a number prints as `•••• NNNN` for every token (a staff answer holds the full number),
# each code as `[code, N digits]`, also inside a text, and --json drops `number` and gives each code as its length.
# `citt inbox PHONE_ID --reveal` puts the codes on the clipboard or in a mode-600 file, as citt mailbox show --reveal does.
# shellcheck shell=bash disable=SC2016

# Needs lib/cmd-mailbox.sh (_mb_show, _mb_reveal_to), which scripts/citt sources first.

# IB_JQ (with MASK_JQ of cmd-mailbox.sh: `codetag`, `clen`, `has_url`, `mask_meta`): `m4` the masked number of a row;
# `kind_label`; `usd` cents as dollars.
IB_JQ="$JQ_LT$MASK_JQ"'
def m4: if (.number_last4 // "") != "" then "•••• \(.number_last4)" else "••••" end;
def kind_label: if .kind == "address" then "address"
  elif .identity_kind == "verification" then "number, verification"
  elif .identity_kind == "sim" then "number, lab SIM"
  elif (.identity_kind // "" | startswith("rental")) then "number, rental"
  else "number" end;
def usd: (if . < 0 then "-" else "" end) as $s | (if . < 0 then -. else . end) as $c
  | "\($s)$\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)";'

cmd_inbox() {
  local ref="" kind="" reveal=0
  # shellcheck disable=SC2034  # read by err and fail_out in lib/common.sh
  CITT_CMD="citt inbox"
  # shellcheck disable=SC2034  # read by mask_server_text and fail_out in lib/common.sh
  CITT_MASK_JQ="$MASK_JQ"
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind)
        need_value "$1" $#
        kind="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --reveal) reveal=1 ;;
      --help | -h)
        help_inbox
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$ref" ] || usage_error "one phone id, address or credential id"
        ref="$1"
        ;;
    esac
    shift
  done
  case "$kind" in '' | all | address | phone) ;; *) usage_error "--kind takes all, address or phone, got: $kind" ;; esac
  if [ -z "$ref" ]; then
    [ "$reveal" = 0 ] || usage_error "--reveal needs a phone id: citt inbox PHONE_ID --reveal (the ids are in citt inbox --json)"
    _ib_list "${kind:-all}"
    return
  fi
  [ -z "$kind" ] || usage_error "--kind is for the list; leave it out with $ref"
  case "$ref" in
    phone_*) _ib_phone "$ref" "$reveal" ;;
    cred_* | *@*)
      local args=("$ref")
      [ "$reveal" = 0 ] || args+=(--reveal)
      [ "$CITT_JSON" = 0 ] || args+=(--json)
      _mb_show ${args[@]+"${args[@]}"}
      ;;
    *) usage_error "$ref is not a phone id (phone_...), a credential id (cred_...) or an address; list them: citt inbox" ;;
  esac
}

# _ib_refusal: the plain line of a refused Inbox or number request (403, 404 with a code), else fail_http.
_ib_refusal() {
  local ref="${1:-}"
  case "$CODE:$(body_field '.error')" in
    403:inbox_not_allowed) die 3 "The Inbox is not available on this account; contact support to have it opened" ;;
    403:lab_phone_not_allowed) die 3 "Lab phone numbers are not available on this account; contact support to have them opened" ;;
    404:inbox_off) die 4 "The Inbox is not available right now: lab addresses and lab phone numbers are both off; try again later, or contact support" ;;
    404:textverified_off) die 4 "Lab phone numbers are not available right now; try again later, or contact support" ;;
    404:not_found) [ -z "$ref" ] || die 4 "$ref is not among your lab phone numbers; list them: citt inbox --kind phone" ;;
  esac
  fail_http
}

_ib_list() {
  local kind="$1" all cursor="" pages=0
  need_auth
  all="$(tmpfile inbox_list)"
  printf '[]' >"$all"
  while :; do
    http GET "$CITT_V1/inbox$(query kind "$kind" cursor "$cursor")"
    ok || _ib_refusal
    jq -e '.rows | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
    jq -c --slurpfile p "$RESP" '. + $p[0].rows' "$all" >"$all.n" && mv "$all.n" "$all"
    cursor="$(jq -r '.next_cursor // empty' "$RESP")"
    pages=$((pages + 1))
    if [ -z "$cursor" ] || [ "$pages" -ge 200 ]; then
      break
    fi
  done
  local flags
  flags="$(jq -c '{addresses_on: (.addresses_on != false), addresses_off: .addresses_off, phones_on: (.phones_on != false)}' "$RESP")"
  if [ "$CITT_JSON" = 1 ]; then
    # NP-1358 QA round 1 P1-1: the fields named here only (deny by default); numbers as their last 4 digits, codes as their length
    jq -c --argjson f "$flags" "$IB_JQ"'{rows: map(pick(["kind", "id", "address", "credential_id", "number_last4", "identity_kind", "provider",
        "state", "release_outcome", "project_id", "run_id", "session_id", "session_seq", "persona_age", "count", "last_at",
        "last_code_at", "created_at", "user_id", "has_password"])
      + {app: (.app | safe_app), last_code: (.last_code | clen), numbers: ((.numbers // []) | map(safe_number))})} + $f' "$all"
    return 0
  fi
  jq -rn --argjson f "$flags" --arg k "$kind" '
    (if $f.addresses_on or $k == "phone" then empty
     elif $f.addresses_off == "not_admitted" then "Lab addresses are not shown: they are not available on this account; contact support to turn them on."
     else "Lab addresses are not shown: lab mail is off on this server; contact support to have it turned on." end),
    (if $f.phones_on or $k == "address" then empty
     else "Phone numbers are not shown: lab phone numbers are off on this server; contact support to have them turned on." end)'
  if [ "$(jq 'length' "$all")" = 0 ]; then
    case "$kind" in
      address) printf 'No lab addresses in the Inbox yet. ' ;;
      phone) printf 'No phone numbers in the Inbox yet. ' ;;
      *) printf 'Nothing in the Inbox yet. ' ;;
    esac
    printf 'Addresses and numbers appear here when a session signs up to an app that asks for an email or a phone number; start one with: citt capture-start APP --project ID --goal TEXT --allow-signup\n'
    return 0
  fi
  jq -c --argjson L "$(local_times "$all")" "$IB_JQ"'
    [["Kind", "Identity", "State", "App", "Session", "Persona", "Newest", "Code"]]
    + [.[] | [kind_label, (if .kind == "address" then .address else m4 end), .state, (.app.label // .app.package_id),
        (if .run_id and .session_id then "run \(.run_id), session \(.session_seq // .session_id)"
         elif .run_id then "run \(.run_id)" elif .session_id then "session \(.session_seq // .session_id)" else null end),
        (if .persona_age then "age \(.persona_age)" else null end), (.last_at | lt),
        (if (.last_code | type) == "string" then (.last_code | codetag) else "" end)]]' "$all" | table
}

# _ib_phone ID REVEAL: one number with its texts newest first.
_ib_phone() {
  local id="$1" reveal="$2" shown=""
  need_auth
  http GET "$CITT_V1/lab-phones/$(urlenc "$id")"
  ok || _ib_refusal "$id"
  jq -e '(.id | type == "string") and (.texts | type == "array")' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
  # NP-924 QA round 2 (decision): stdout prints no SMS text; --reveal puts the codes on the clipboard (else in a mode-600 file) and
  # writes the texts, newest first, to a mode-600 file
  local texts_file=""
  if [ "$reveal" = 1 ]; then
    local ncodes ntexts
    ncodes="$(jq '[.texts[].code | select(type == "string" and length > 0)] | length' "$RESP")"
    ntexts="$(jq '.texts | length' "$RESP")"
    [ "$ntexts" != 0 ] || die 4 "no code and no text has been received on $id yet; nothing to reveal. Check again: citt inbox $id"
    if [ "$ncodes" != 0 ]; then
      shown="$(_mb_reveal_to "$id-codes" '[.texts | sort_by(.received_at) | reverse | .[].code | select(type == "string" and length > 0)] | join("\n")')" || exit 1
    fi
    local dir="$CITT_STATE/revealed"
    texts_file="$dir/$id-texts.txt"
    (
      umask 077
      mkdir -p "$dir" && chmod 700 "$dir" && rm -f "$texts_file" \
        && jq -r '.texts | sort_by(.received_at) | reverse | .[] | "\(.received_at) from \(.sender // "unknown sender"): \(.content // "")"' "$RESP" >"$texts_file" \
        && chmod 600 "$texts_file"
    ) || die 1 "could not write the file $texts_file"
  fi
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --arg shown "$shown" --arg texts "$texts_file" "$IB_JQ"'
      (safe_phone + pick(["persona_age", "charged_cents", "refunded_cents"])
        + {app: (.app | safe_app), credential: (if .credential then (.credential | pick(["credential_id", "address", "has_password"])) else null end),
           refresh_error: (if .refresh_error then (.refresh_error | pick(["code"])) else null end), texts}
        | .last_code = .last_code_length | del(.last_code_length))
      | .texts |= map({id, received_at, source, sender: (.sender | mask_meta), length: ((.content // "") | length),
          has_link: ((.content // "") | has_url), has_code: ((.code // "") != ""), code_length: (.code | clen)})
      | (if $shown == "clipboard" then . + {codes_copied: true} elif $shown != "" then . + {codes_file: $shown} else . end)
      | (if $texts != "" then . + {texts_file: $texts} else . end)' "$RESP"
    return 0
  fi
  local page
  page="$(app_url "/inbox/phones/$id")"
  jq -r --argjson L "$(local_times "$RESP")" --arg page "$page" --arg shown "$shown" "$IB_JQ"'
    "Number: \(m4) (\(.id))",
    "Provider: \(if .provider == "textverified" then "TextVerified" elif .provider == "lab_sim" then "lab SIM" else (.provider // "-") end)",
    "Kind: \(if .kind == "verification" then "verification" elif .kind == "rental_renewable" then "rental, renewable"
      elif .kind == "rental_nonrenewable" then "rental, not renewable" elif .kind == "sim" then "lab SIM" else (.kind // "-") end)",
    "State: \(.state)\(if .release_outcome then " (\(.release_outcome))" else "" end)",
    "Ends at: \(.ends_at | lt)",
    "Renewal: \(if .kind == "rental_renewable" then (if .renew then "on" else "off" end) else "this kind does not renew" end)",
    (if .credential then "Account: \(.credential.address) (credential \(.credential.credential_id))"
       + (if .credential.has_password then "; password stored, reveal it with: citt mailbox show \(.credential.address) --reveal" else "" end)
     else "Account: none; the number was rented without a sign-up" end),
    "App: \(.app.label // .app.package_id // "-")\(if .app.label and .app.package_id then " (\(.app.package_id))" else "" end)",
    "Persona: \(if .persona_age then "age \(.persona_age)" else "-" end)",
    "Run: \(.run_id // "-")",
    "Session: \(.session_seq // .session_id // "-")",
    "Cost so far: \((.charged_cents // 0) | usd) charged, \((.refunded_cents // 0) | usd) refunded, \(((.charged_cents // 0) - (.refunded_cents // 0)) | usd) net",
    "Texts: \(.texts | length)",
    "Number page: \($page)",
    (if .refresh_error then "The newest texts could not be read just now, so this list may be behind; check again shortly: citt inbox \(.id)" else empty end)' "$RESP"
  if [ "$(jq '.texts | length' "$RESP")" = 0 ]; then
    jq -r --argjson L "$(local_times "$RESP")" "$IB_JQ"'
      if .released_at then "No texts were received; the number is released."
      else "No texts yet.\(if .code_wait_until then " The wait for a code ends at \(.code_wait_until | lt)." else "" end) Check again: citt inbox \(.id)" end' "$RESP"
    return 0
  fi
  jq -c --argjson L "$(local_times "$RESP")" "$IB_JQ"'
    [["Received", "Sender", "Text", "Link", "Code"]]
    + [.texts | sort_by(.received_at | ts) | reverse | .[]
        | [(.received_at | lt), (.sender | mask_meta), "\((.content // "") | length) characters",
           (if (.content // "") | has_url then "yes" else "" end), (if (.code // "") != "" then (.code | codetag) else "" end)]]' "$RESP" | table
  case "$shown" in
    '') [ -n "$texts_file" ] || jq -r '([.texts[].code | select(type == "string" and length > 0)] | length) as $n
          | "Texts and codes are not printed here (\($n) codes received); put the codes on the clipboard or in a file and the texts in a file with: citt inbox \(.id) --reveal"' "$RESP" ;;
    clipboard) printf 'Codes: copied to the clipboard, newest first\n' ;;
    *) printf 'Codes: written to %s (mode 600), newest first; open it yourself and delete it after use\n' "$shown" ;;
  esac
  [ -z "$texts_file" ] || printf 'Texts: written to %s (mode 600), newest first; open it yourself\n' "$texts_file"
}
