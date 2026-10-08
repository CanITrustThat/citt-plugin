#!/usr/bin/env bash
# lib/tus.sh: resumable upload of a build with tus 1.0 (CUSTOM-PROMPT section 2).
# Resume state: ${XDG_STATE_HOME:-~/.local/state}/citt/uploads/<sha256>.json, mode 600,
# {upload_url, size, mtime}; written before the first PATCH, removed once the upload is settled.
# shellcheck shell=bash disable=SC2034,SC2153

TUS_CHUNK=33554432
TUS_HDR="Tus-Resumable: 1.0.0"

# Set by tus_upload.
UPLOAD_ID=""
UPLOAD_URL=""
TUS_STATE=""
TUS_OFF=0

# The fixed text after a failed request that left resumable state.
_tus_resume_hint() { err "$CITT_CMD: the upload stopped at $1 of $2 bytes; re-run: $PROMPT_RERUN"; }

_tus_state_dir() {
  local base="${XDG_STATE_HOME:-}"
  [ -n "$base" ] || base="$HOME/.local/state"
  printf '%s/citt/uploads' "$base"
}

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# _tus_url_ok URL: an upload URL of this host's upload route.
_tus_url_ok() {
  local id
  case "$1" in "$CITT_HOST$CITT_V1/uploads/"*) ;; *) return 1 ;; esac
  id="${1#"$CITT_HOST$CITT_V1/uploads/"}"
  case "$id" in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
  return 0
}

# _tus_write_state FILE URL SIZE MTIME: the 0600 state file, replaced atomically.
_tus_write_state() {
  local f="$1" tmp="$1.tmp.$$"
  ( umask 077
    jq -nc --arg u "$2" --argjson s "$3" --argjson m "$4" '{upload_url: $u, size: $s, mtime: $m}' >"$tmp" ) \
    || die 1 "cannot write the upload state $f"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f" || die 1 "cannot write the upload state $f"
}

# _tus_offset: the server's Upload-Offset for UPLOAD_URL (HEAD) into TUS_OFF; returns 1 when the
# upload is gone (404, 410). Any other failure exits through prompt_fail.
_tus_offset() {
  HTTP_HEADERS="$TUS_HDR"
  http HEAD "$UPLOAD_URL"
  case "$CODE" in
    200 | 204) ;;
    404 | 410) return 1 ;;
    *) prompt_fail ;;
  esac
  TUS_OFF="$(hdr Upload-Offset)"
  is_uint "$TUS_OFF" || die 1 "HEAD $REQ_PATH answered without an Upload-Offset"
}

# _tus_create SIZE NAME: POST /uploads; sets UPLOAD_URL.
_tus_create() {
  local loc meta
  meta="filename $(printf '%s' "$2" | base64 | tr -d '\n')"
  HTTP_HEADERS="$TUS_HDR
Upload-Length: $1
Upload-Metadata: $meta"
  http POST "$CITT_V1/uploads"
  [ "$CODE" = 201 ] || prompt_fail
  loc="$(hdr Location)"
  case "$loc" in /*) loc="$CITT_HOST$loc" ;; esac
  _tus_url_ok "$loc" || die 1 "POST $CITT_V1/uploads answered with an unexpected Location: $loc"
  UPLOAD_URL="$loc"
}

# _tus_send FILE SIZE OFFSET: PATCHes from OFFSET to SIZE in chunks of 32 MiB. Returns 1 when the
# upload is gone on the server (404, 410), so the caller starts again.
_tus_send() {
  local file="$1" size="$2" off="$3" len next fails=0
  while [ "$off" -lt "$size" ]; do
    len=$((size - off))
    [ "$len" -le "$TUS_CHUNK" ] || len="$TUS_CHUNK"
    HTTP_HEADERS="$TUS_HDR
Upload-Offset: $off"
    HTTP_CHUNK="$file"
    HTTP_CHUNK_OFF="$off"
    HTTP_CHUNK_LEN="$len"
    http PATCH "$UPLOAD_URL"
    case "$CODE" in
      204 | 200)
        next="$(hdr Upload-Offset)"
        is_uint "$next" || next=$((off + len))
        off="$next"
        fails=0
        [ "$size" -le "$TUS_CHUNK" ] || err "$CITT_CMD: uploaded $((off / 1048576)) of $((size / 1048576)) MiB"
        continue
        ;;
      404 | 410) return 1 ;;
      409 | 000 | 5??) ;;
      *) prompt_fail ;;
    esac
    # 409 (offset mismatch), a network failure or a 5xx: read the server's offset and go on.
    fails=$((fails + 1))
    if [ "$fails" -gt 3 ]; then
      _tus_resume_hint "$off" "$size"
      prompt_fail
    fi
    sleep "$(_retry_delay "$fails")"
    _tus_offset || return 1
    off="$TUS_OFF"
  done
  return 0
}

# _tus_settle TIMEOUT: polls GET /uploads/{id} until validated. A rejected upload exits 7.
_tus_settle() {
  local timeout="$1" start st code
  start="$(now_s)"
  while :; do
    HTTP_HEADERS="$TUS_HDR"
    call_prompt GET "$UPLOAD_URL"
    st="$(body_field '.status')"
    case "$st" in
      validated) return 0 ;;
      rejected)
        code="$(body_field '.rejection')"
        rm -f "$TUS_STATE"
        prompt_exit 7 upload_rejected "the service rejected the file: ${code:-no code given}" "$code"
        ;;
      expired) return 1 ;;
    esac
    if [ $(($(now_s) - start)) -ge "$timeout" ]; then
      err "$CITT_CMD: the upload is still being validated (status ${st:-unknown}) after $timeout s; re-run: $PROMPT_RERUN"
      exit 12
    fi
    poll_sleep "$(body_field '.poll_after_seconds')"
  done
}

# tus_upload FILE TIMEOUT: uploads FILE (resuming from the state file when the server still has
# the upload) and waits until it is validated; sets UPLOAD_ID.
tus_upload() {
  local file="$1" timeout="$2" dir sha size mtime state off attempt=0 url s m
  dir="$(_tus_state_dir)"
  ( umask 077; mkdir -p "$dir" ) || die 1 "cannot create $dir"
  chmod 700 "$dir" 2>/dev/null || true
  sha="$(sha256_of "$file")" || die 1 "cannot read $file"
  size="$(file_bytes "$file")"
  mtime="$(file_mtime "$file")"
  if ! is_uint "$size" || [ "$size" -eq 0 ]; then usage_error "$file is empty"; fi
  state="$dir/$sha.json"
  TUS_STATE="$state"
  while :; do
    attempt=$((attempt + 1))
    [ "$attempt" -le 3 ] || die 8 "the server dropped the upload of $file three times"
    UPLOAD_URL=""
    off=""
    if [ -f "$state" ]; then
      url="$(jq -r '.upload_url // empty' "$state" 2>/dev/null)"
      s="$(jq -r '.size // empty' "$state" 2>/dev/null)"
      m="$(jq -r '.mtime // empty' "$state" 2>/dev/null)"
      if [ "$s" = "$size" ] && [ "$m" = "$mtime" ] && _tus_url_ok "$url"; then
        UPLOAD_URL="$url"
        if _tus_offset; then
          off="$TUS_OFF"
          err "$CITT_CMD: resuming the upload of $file at $off of $size bytes"
        else
          UPLOAD_URL=""
        fi
      fi
      [ -n "$UPLOAD_URL" ] || rm -f "$state"
    fi
    if [ -z "$UPLOAD_URL" ]; then
      _tus_create "$size" "$(basename "$file")"
      _tus_write_state "$state" "$UPLOAD_URL" "$size" "$mtime"
      off=0
    fi
    UPLOAD_ID="${UPLOAD_URL##*/}"
    if ! _tus_send "$file" "$size" "$off"; then
      rm -f "$state"
      continue
    fi
    if _tus_settle "$timeout"; then
      rm -f "$state"
      return 0
    fi
    rm -f "$state"
  done
}
