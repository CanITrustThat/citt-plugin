#!/usr/bin/env bash
# lib/cmd-feedback.sh: citt feedback (TASK-541, EPIC-18 D276 revised), one free-text body to the CITT team.
# shellcheck shell=bash disable=SC2034

FEEDBACK_MAX_BYTES=1048576

cmd_feedback() {
  local file="" sources=0 from_stdin=0 have_text=0 src
  local -a words
  words=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --file)
        need_value "$1" $#
        [ -z "$file" ] || usage_error "give --file once"
        file="$2"
        sources=$((sources + 1))
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_feedback
        exit 0
        ;;
      -)
        [ "$from_stdin" = 0 ] || usage_error "give - once"
        from_stdin=1
        sources=$((sources + 1))
        ;;
      --)
        # End of the options: every word after it is TEXT, even one that starts with -.
        shift
        if [ $# -gt 0 ]; then
          words+=("$@")
          [ "$have_text" = 1 ] || sources=$((sources + 1))
          have_text=1
        fi
        break
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        words+=("$1")
        [ "$have_text" = 1 ] || sources=$((sources + 1))
        have_text=1
        ;;
    esac
    shift
  done
  [ "$sources" -le 1 ] || usage_error "give the feedback one way: TEXT, --file PATH or - (stdin)"
  [ "$sources" = 1 ] || usage_error "give the feedback as TEXT, --file PATH or - (stdin)"
  if [ -n "$file" ]; then
    { [ -f "$file" ] && [ -r "$file" ]; } || usage_error "cannot read --file $file"
    src="$file"
  else
    src="$(tmpfile feedback_text)"
    if [ "$from_stdin" = 1 ]; then
      # One byte over the limit is enough to refuse; the rest of stdin is never read.
      head -c $((FEEDBACK_MAX_BYTES + 1)) >"$src"
    else
      printf '%s' "${words[*]}" >"$src"
    fi
  fi
  local bytes
  bytes="$(wc -c <"$src" | tr -d ' ')"
  if [ "$bytes" -gt "$FEEDBACK_MAX_BYTES" ]; then
    # stdin is read only to one byte over the limit, so its full size is not known.
    [ "$from_stdin" = 0 ] || usage_error "the feedback on stdin is over the limit of 1,048,576 bytes (1 MiB)"
    usage_error "the feedback is $bytes bytes; the limit is 1,048,576 (1 MiB)"
  fi
  iconv -f UTF-8 -t UTF-8 "$src" >/dev/null 2>&1 || usage_error "the feedback is not valid UTF-8 text"
  # iconv passes some invalid sequences (above U+10FFFF); jq turns any invalid sequence into U+FFFD,
  # so the body is valid UTF-8 exactly when jq gives back the same bytes.
  jq -jn --rawfile b "$src" '$b' 2>/dev/null | cmp -s - "$src" || usage_error "the feedback is not valid UTF-8 text"
  jq -en --rawfile b "$src" '$b | test("\\S")' >/dev/null 2>&1 || usage_error "the feedback is empty"
  local body
  body="$(tmpfile feedback_body)"
  jq -nc --rawfile b "$src" '{body: $b}' >"$body"
  need_auth
  E_KIND=feedback
  # One attempt only: a retried POST could store the feedback twice.
  HTTP_RETRY=no
  call POST "$CITT_V1/feedback" "$body"
  # The id goes into the printed line: a number only.
  jq -e '(.id | type) == "number"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from POST $CITT_V1/feedback"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c . "$RESP"
    return 0
  fi
  jq -r '"Feedback sent (id \(.id)). Thank you."' "$RESP"
}
