#!/usr/bin/env bash
# =============================================================================
# lib/cmd-submit.sh — `citt submit` subcommand (CITT-334)
# =============================================================================
# Sourced by the `citt` dispatcher, which calls citt_cmd_submit() with the
# remaining args after "submit".
#
# Supports:
#   citt submit com.foo.bar                     single package id
#   citt submit com.a com.b                     multiple package ids
#   citt submit https://play.google.com/...     Play Store URL
#   citt submit https://apps.apple.com/...      App Store URL
#   citt submit apps.csv                        CSV file path (direct delegation)
#   citt submit com.a https://...apps.apple.com/...id123  mixed bag
#
# DELEGATION STRATEGY:
#   citt-submit.sh already has 24 passing tests covering dedup (<90d reuse),
#   per-app budget, forgiving CSV, partial summary, name-only confirmation, and
#   all secret-isolation invariants.  We PRESERVE that logic by delegating:
#
#   - If the sole argument is a readable file path → exec citt-submit.sh <path>
#     directly (zero overhead, all behaviour preserved).
#   - Otherwise → build a minimal temp CSV from the bare package-id / store-URL
#     arguments (one arg per row), then exec citt-submit.sh <tmp_csv>.
#     Each row gets: package_id (if looks like a package), store_url (if looks
#     like an http/https URL), platform defaulting to android.  citt-submit.sh's
#     own URL extraction and CSV parsing handle the rest.
#
# SECRET ISOLATION (inherits all invariants from citt-common.sh + citt-submit.sh):
#   - The token NEVER appears on argv, in stdout, or in a bash -x xtrace.
#   - All token handling is inside citt-submit.sh (same 0600 file / curl-cfg
#     discipline).  This wrapper never touches the token.
#   - Temp CSV is created 0600 and cleaned up on EXIT.
# =============================================================================

# _CITT_SELF_DIR is set by the dispatcher (the scripts/ directory).
# We resolve citt-submit.sh relative to it.
_CMD_SUBMIT_SCRIPT="${_CITT_SELF_DIR}/citt-submit.sh"

# ---------------------------------------------------------------------------
# _is_store_url: returns 0 if the argument looks like an http(s) URL.
# ---------------------------------------------------------------------------
_is_store_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# _is_readable_file: returns 0 if the argument is a readable regular file.
# ---------------------------------------------------------------------------
_is_readable_file() {
  [ -f "$1" ] && [ -r "$1" ]
}

# ---------------------------------------------------------------------------
# citt_cmd_submit — dispatcher entry point.
# $@ = everything after "submit" on the citt command line.
# ---------------------------------------------------------------------------
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

  # --- Single-argument CSV file path: delegate directly. ---
  if [ "$#" -eq 1 ] && _is_readable_file "$1"; then
    exec bash "${_CMD_SUBMIT_SCRIPT}" "$1"
    # exec replaces the process; if it fails (script not found) fall through:
    emit_err "citt submit: cannot exec citt-submit.sh"
    exit 1
  fi

  # --- One or more bare package ids / store URLs: build a temp CSV. ---
  # Create the temp CSV 0600 so it is never world-readable (it may later hold
  # package ids the user intends to keep private, and the mode is consistent
  # with the rest of the plugin's 0600 discipline).
  local tmp_csv
  tmp_csv="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_submit_args.XXXXXX")"
  # Arrange cleanup on EXIT (the dispatcher's EXIT trap handles the lib tmpdir;
  # this temp file is ours alone).
  _cmd_submit_cleanup() { rm -f "$tmp_csv" 2>/dev/null || true; }
  trap _cmd_submit_cleanup EXIT

  # Write the CSV header + one row per argument.
  {
    printf 'package_id,store_url,platform\n'
    local arg
    for arg in "$@"; do
      if _is_store_url "$arg"; then
        # store_url column; package_id empty; platform android (citt-submit.sh
        # extracts the id from the URL itself, same as CSV store_url rows).
        printf ',%s,android\n' "$arg"
      else
        # Treat as a bare package id.
        printf '%s,,android\n' "$arg"
      fi
    done
  } >"$tmp_csv"

  exec bash "${_CMD_SUBMIT_SCRIPT}" "$tmp_csv"
  # exec replaces the process; if it fails (script not found) fall through:
  emit_err "citt submit: cannot exec citt-submit.sh"
  exit 1
}
