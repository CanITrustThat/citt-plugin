#!/usr/bin/env bash
# =============================================================================
# lib/cmd-claim.sh — `citt claim` subcommand (CITT-339)
# =============================================================================
# App ownership claim via store-email OTP verification. Sourced by the `citt`
# dispatcher which has already sourced lib/citt-common.sh.
#
# Usage (routed by the dispatcher):
#   citt claim <pkg>           — initiate OTP claim + prompt for code on stdin
#   citt claim --status <pkg>  — read-only claim status
#
# Flow for `citt claim <pkg>`:
#   1. _prepare_auth (exits on missing/expired token)
#   2. POST /api/apps/{pkg}/claim  → server emails an OTP to the store-listed
#      contact; print ONE clear notice to stderr that the email has been sent.
#   3. Read the OTP code from stdin (interactive or piped).
#   4. POST /api/apps/{pkg}/claim/verify  body: {"code": "<otp>"}
#      (verify field name from ClaimVerifyRequest in api.py — it is "code")
#   5. On 200 emit {"status":"verified"} JSON to stdout + summary to stderr.
#      On error emit a clean NO-LEAK message to stderr + exit non-zero.
#
# Flow for `citt claim --status <pkg>`:
#   1. _prepare_auth
#   2. GET /api/apps/{pkg}/claim-status
#   3. Emit ClaimStatusResponse JSON to stdout; summary to stderr.
#
# SECRET ISOLATION (hard invariants — mirrors citt-common.sh):
#   - The auth token NEVER in stdout / argv / bash -x xtrace / logs.
#   - All token handling goes through citt-common.sh's 0600 curl --config file.
#   - The OTP code is a user-entered value (not the auth token), but we still
#     avoid writing it to argv; it is read from stdin into a 0600 temp file and
#     POSTed via --data @file (never on curl argv or printf/echo of the code).
#   - Host is HARDCODED in citt-common.sh. CITT_API_OVERRIDE honored ONLY when
#     CITT_TEST_MODE=1 (the seam is already active via the common lib).
#   - Error bodies are parsed for a single scalar; raw responses are NEVER echoed.
# =============================================================================

# Guard against double-sourcing.
[ "${_CITT_CMD_CLAIM_LOADED:-}" = "1" ] && return 0
_CITT_CMD_CLAIM_LOADED=1

# ---------------------------------------------------------------------------
# _claim_err: print a clean human error to stderr and exit non-zero.
# Never dumps raw API response bodies. $1 = message, $2 = optional HTTP code.
# ---------------------------------------------------------------------------
_claim_err() {
  local msg="$1" code="${2:-}"
  if [ -n "$code" ] && [ "$code" != "" ]; then
    emit_err "citt claim: $msg (HTTP $code)"
  else
    emit_err "citt claim: $msg"
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# _claim_parse_detail: safely extract the "detail" scalar from the 0600 resp
# file for clean error messages. Never echoes the full raw body.
# ---------------------------------------------------------------------------
_claim_parse_detail() {
  local body; body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"
  _json_get "detail" "$body"
}

# ---------------------------------------------------------------------------
# citt_cmd_claim — main entry point called by the dispatcher.
# ---------------------------------------------------------------------------
citt_cmd_claim() {
  # ---------------------------------------------------------------------------
  # Argument parsing
  # ---------------------------------------------------------------------------
  local pkg="" do_status=0

  # Quick flag check without getopts (avoids portability issues).
  case "${1:-}" in
    --status)
      do_status=1
      shift
      pkg="${1:-}"
      ;;
    --help|-h)
      cat >&1 <<'USAGE'
Usage: citt claim [--status] <package_id>

  citt claim <pkg>          Claim ownership of an app (sends OTP to store email)
  citt claim --status <pkg> Show current claim status for an app

The claim flow emails an OTP to the app's store-listed contact address. You
will be prompted to enter the code. Run `citt auth` first if not authenticated.
USAGE
      return 0
      ;;
    "")
      emit_err "citt claim: missing package_id"
      emit_err "Usage: citt claim [--status] <package_id>"
      exit 1
      ;;
    -*)
      emit_err "citt claim: unknown flag: $1"
      emit_err "Usage: citt claim [--status] <package_id>"
      exit 1
      ;;
    *)
      pkg="${1:-}"
      shift
      ;;
  esac

  if [ -z "$pkg" ]; then
    emit_err "citt claim: missing package_id"
    emit_err "Usage: citt claim [--status] <package_id>"
    exit 1
  fi

  # ---------------------------------------------------------------------------
  # Auth: load token + build curl config. Exits with re-auth hint if missing.
  # ---------------------------------------------------------------------------
  _prepare_auth

  # ---------------------------------------------------------------------------
  # Subcommand: --status
  # ---------------------------------------------------------------------------
  if [ "$do_status" = "1" ]; then
    local code body
    code="$(_curl_auth_get "/api/apps/${pkg}/claim-status")"

    case "$code" in
      200)
        body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"
        emit_json "$body"
        local claimed
        claimed="$(_json_get "claimed_by_me" "$body")"
        local claimable
        claimable="$(_json_get "claimable" "$body")"
        if [ "$claimed" = "true" ]; then
          emit_err "claim status: you own this app."
        elif [ "$claimable" = "true" ]; then
          emit_err "claim status: app is claimable — run: citt claim ${pkg}"
        else
          emit_err "claim status: app is not claimable (no store contact email on file)."
        fi
        ;;
      401)
        _reauth_hint
        ;;
      404)
        _claim_err "app not found: ${pkg}" "$code"
        ;;
      "")
        _claim_err "could not reach the CITT API"
        ;;
      *)
        _claim_err "unexpected response from claim-status" "$code"
        ;;
    esac
    return 0
  fi

  # ---------------------------------------------------------------------------
  # Subcommand: initiate claim
  # ---------------------------------------------------------------------------

  # Step 1: POST /api/apps/{pkg}/claim to trigger the OTP email.
  local init_code
  init_code="$(_curl_auth_post "/api/apps/${pkg}/claim" "${_CITT_BODY_FILE}")"
  # Note: the claim endpoint requires no request body (POST with empty body is OK).
  # We pass _CITT_BODY_FILE which is an empty 0600 temp (it was created by citt-common.sh).
  # The server ignores the body; we just need to trigger the POST.

  case "$init_code" in
    200)
      # Parse the masked email and expiry from the response.
      local init_body masked expires_min
      init_body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"
      masked="$(_json_get "masked_email" "$init_body")"
      expires_min="$(_json_get "expires_in_minutes" "$init_body")"

      # ONE clear notice to stderr that the OTP email has been sent.
      if [ -n "$masked" ]; then
        emit_err "Verification email sent to ${masked} — check your inbox for the OTP code."
      else
        emit_err "Verification email sent — check your inbox for the OTP code."
      fi
      if [ -n "$expires_min" ]; then
        emit_err "The code expires in ${expires_min} minutes."
      fi
      ;;
    401)
      _reauth_hint
      ;;
    400)
      local detail; detail="$(_claim_parse_detail)"
      if [ -n "$detail" ]; then
        _claim_err "$detail" "$init_code"
      else
        _claim_err "could not initiate claim (bad request)" "$init_code"
      fi
      ;;
    404)
      _claim_err "app not found: ${pkg}" "$init_code"
      ;;
    "")
      _claim_err "could not reach the CITT API"
      ;;
    *)
      local detail; detail="$(_claim_parse_detail)"
      if [ -n "$detail" ]; then
        _claim_err "$detail" "$init_code"
      else
        _claim_err "claim initiation failed" "$init_code"
      fi
      ;;
  esac

  # Step 2: Read the OTP code from stdin into a 0600 temp file.
  # We do NOT use `read -p` (prints to stdout, which is the model's output channel).
  # Instead, print the prompt to stderr and read from stdin.
  emit_err "Enter the verification code from the email:"

  # Create a fresh 0600 temp for the OTP so it never appears on argv.
  local otp_file
  otp_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_otp.XXXXXX")"

  # Read one line from stdin DIRECTLY into the 0600 temp file — no intermediary
  # shell variable is ever set, so bash -x never traces the OTP value. (CITT-347 F2)
  # `head -n1` reads exactly one line and writes it to the file without tracing
  # the content.  Then `sed` strips leading/trailing whitespace in-place.
  ( umask 077; head -n1 >"$otp_file" ) <&0 || true
  # Strip leading/trailing whitespace in the file (in-place, no variable).
  sed -i '' 's/^[[:space:]]*//;s/[[:space:]]*$//' "$otp_file" 2>/dev/null \
    || sed -i 's/^[[:space:]]*//;s/[[:space:]]*$//' "$otp_file" 2>/dev/null \
    || true

  if [ ! -s "$otp_file" ]; then
    rm -f "$otp_file" 2>/dev/null || true
    _claim_err "no OTP code provided"
  fi

  # Step 3: Build the verify body file. The OTP flows from 0600 file → 0600 body
  # file via `jq --rawfile` (reads from file, never on argv) or the no-jq
  # fallback which assembles the JSON via printf+cat (OTP bytes come from cat,
  # not from a shell variable or argv). (CITT-347 F2)
  local verify_body
  verify_body="$(umask 077; mktemp "${TMPDIR:-/tmp}/citt_vbody.XXXXXX")"
  # Register cleanup for both OTP temp and verify body temp using captured paths
  # in the trap string (not function references that would trigger unbound-var errors).
  local _otp_f="$otp_file" _vbody_f="$verify_body"
  trap "rm -f '${_otp_f}' '${_vbody_f}' 2>/dev/null || true; _citt_common_cleanup" EXIT

  ( umask 077
    if command -v jq >/dev/null 2>&1; then
      # --rawfile reads the OTP from the 0600 file directly — never on argv.
      jq -nc --rawfile c "$otp_file" '{"code":($c|rtrimstr("\n"))}' >"$verify_body"
    else
      # No-jq fallback: assemble JSON via printf (static parts) + cat (OTP bytes
      # from file) — the OTP never touches a shell variable or printf's arg list.
      { printf '{"code":"'; cat "$otp_file"; printf '"}'; } >"$verify_body"
    fi
  )

  # Step 4: POST /api/apps/{pkg}/claim/verify
  local verify_code
  verify_code="$(_curl_auth_post "/api/apps/${pkg}/claim/verify" "$verify_body")"

  case "$verify_code" in
    200)
      local verify_body_resp
      verify_body_resp="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"
      emit_json "$verify_body_resp"
      emit_err "Ownership claim verified. You are now the registered owner of ${pkg}."
      ;;
    400)
      local detail; detail="$(_claim_parse_detail)"
      case "$detail" in
        *"Invalid code"*|*"invalid code"*)
          _claim_err "invalid verification code — check the email and try again" "$verify_code"
          ;;
        *"expired"*)
          _claim_err "verification code has expired — run 'citt claim ${pkg}' to start again" "$verify_code"
          ;;
        *"Too many"*|*"too many"*)
          _claim_err "too many failed attempts — run 'citt claim ${pkg}' to start a new challenge" "$verify_code"
          ;;
        *"No pending"*|*"no pending"*)
          _claim_err "no pending claim found — run 'citt claim ${pkg}' to initiate a new challenge" "$verify_code"
          ;;
        *)
          if [ -n "$detail" ]; then
            _claim_err "$detail" "$verify_code"
          else
            _claim_err "verification failed" "$verify_code"
          fi
          ;;
      esac
      ;;
    401)
      _reauth_hint
      ;;
    404)
      _claim_err "app not found during verification: ${pkg}" "$verify_code"
      ;;
    429)
      _claim_err "too many failed verification attempts — start a new challenge with: citt claim ${pkg}" "$verify_code"
      ;;
    "")
      _claim_err "could not reach the CITT API during verification"
      ;;
    *)
      local detail; detail="$(_claim_parse_detail)"
      if [ -n "$detail" ]; then
        _claim_err "$detail" "$verify_code"
      else
        _claim_err "unexpected error during verification" "$verify_code"
      fi
      ;;
  esac
}
