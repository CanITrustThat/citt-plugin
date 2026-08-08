#!/usr/bin/env bash
# lib/cmd-submit.sh — `citt submit` subcommand. Exposes citt_cmd_submit().
# Accepts one or more package ids and/or store URLs, or a CSV file path.
# Delegation: a lone readable file path is exec'd straight into citt-submit.sh;
# otherwise the args are written to a temp 0600 CSV (one row each) and that is
# exec'd. citt-submit.sh owns all token handling; this wrapper never touches it.

# _CITT_SELF_DIR is set by the dispatcher (the scripts/ directory).
_CMD_SUBMIT_SCRIPT="${_CITT_SELF_DIR}/citt-submit.sh"

# _is_store_url: returns 0 if the argument looks like an http(s) URL.
_is_store_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

# _is_readable_file: returns 0 if the argument is a readable regular file.
_is_readable_file() {
  [ -f "$1" ] && [ -r "$1" ]
}

# citt_cmd_submit — entry point. $@ = args after "submit".
citt_cmd_submit() {
  if [ "$#" -eq 0 ]; then
    printf 'usage: citt submit <package_id|store_url> [<package_id|store_url> ...]\n' >&2
    printf '       citt submit <path/to/apps.csv>\n' >&2
    printf '\nExamples:\n' >&2
    printf '  citt submit com.example.app\n' >&2
    printf '  citt submit com.a com.b\n' >&2
    printf '  citt submit https://play.google.com/store/apps/details?id=com.example.app\n' >&2
    printf '  citt submit apps.csv\n' >&2
    exit 2
  fi

  # Single-argument CSV file path: delegate directly.
  if [ "$#" -eq 1 ] && _is_readable_file "$1"; then
    exec bash "${_CMD_SUBMIT_SCRIPT}" "$1"
    # Only reached if exec fails.
    emit_err "citt submit: cannot exec citt-submit.sh"
    exit 1
  fi

  # One or more bare package ids / store URLs: build a temp CSV (0600).
  local tmp_csv
  tmp_csv="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_submit_args.XXXXXX")"
  # This temp file is ours alone (dispatcher's EXIT trap handles the lib tmpdir).
  _cmd_submit_cleanup() { rm -f "$tmp_csv" 2>/dev/null || true; }
  trap _cmd_submit_cleanup EXIT

  # CSV header + one row per argument.
  {
    printf 'package_id,store_url,platform\n'
    local arg
    for arg in "$@"; do
      if _is_store_url "$arg"; then
        # store_url column (citt-submit.sh extracts the id from the URL).
        printf ',%s,android\n' "$arg"
      else
        # Bare package id.
        printf '%s,,android\n' "$arg"
      fi
    done
  } >"$tmp_csv"

  exec bash "${_CMD_SUBMIT_SCRIPT}" "$tmp_csv"
  # Only reached if exec fails.
  emit_err "citt submit: cannot exec citt-submit.sh"
  exit 1
}
