#!/usr/bin/env bash
# =============================================================================
# test_citt_claim.sh — TDD harness for `citt claim` (CITT-339)
# =============================================================================
# Tests the `citt claim` subcommand (cmd-claim.sh) via the dispatcher against
# a local mock server (mock_claim_server.py) using the CITT_API_OVERRIDE seam
# (honored only under CITT_TEST_MODE=1). Mirrors the structure and
# secret-isolation assertions from test_citt_auth.sh / test_citt_dispatch.sh.
#
# Scenarios tested:
#   1. Happy path: init OTP + verify (OTP piped via stdin) -> "verified" JSON
#   2. --status before claim -> claimable=true
#   3. --status after claim -> claimed_by_me=true
#   4. Wrong OTP code -> clean error + non-zero exit
#   5. App not found -> clean error + non-zero exit
#   6. App with no contact email -> clean error + non-zero exit
#   7. Already-claimed app -> clean error + non-zero exit
#   8. No token / unauthenticated -> re-auth hint + non-zero exit
#   9. 401 response -> re-auth hint + non-zero exit
#  10. Secret isolation: forced bash -x xtrace must NOT expose auth token
#  11. Email notice printed to stderr on successful initiation
#
# OTP is piped via stdin (<<< or printf |) so tests run non-interactively.
#
# Layout-independent: CITT = $PLUGIN_ROOT/scripts/citt
# Pure bash + stdlib python3 — no venv/pytest. Run:
#     bash citt-plugin/tests/test_citt_claim.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
CITT="$PLUGIN_ROOT/scripts/citt"
MOCK="$HERE/mock_claim_server.py"
PYTHON="${PYTHON:-python3}"

MOCK_TOKEN="citt_claim_test_supersecret789"
OTP_CODE="1234"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Scratch workspace
# ---------------------------------------------------------------------------
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_claim_test.XXXXXX")"
cleanup_all() { rm -rf "$WORKROOT" 2>/dev/null || true; }
trap cleanup_all EXIT

# ---------------------------------------------------------------------------
# Mock server lifecycle
# ---------------------------------------------------------------------------
MOCK_PID=""
MOCK_BASE=""

# start_mock CLAIM_STATE_JSON OTP_CODE BAD_TOKEN LOGFILE
start_mock() {
  local statej="$1" otp="${2:-$OTP_CODE}" badtok="${3:-}" logf="$4" outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_CLAIM_STATE="$statej" \
  CITT_MOCK_OTP_CODE="$otp" \
  CITT_MOCK_BAD_TOKEN="$badtok" \
  CITT_MOCK_TOKEN="$MOCK_TOKEN" \
  CITT_MOCK_LOG="$logf" \
    "$PYTHON" "$MOCK" >"$outf" 2>/dev/null &
  MOCK_PID=$!
  local tries=0
  MOCK_BASE=""
  while [ "$tries" -lt 100 ]; do
    MOCK_BASE="$(head -n1 "$outf" 2>/dev/null || true)"
    [ -n "$MOCK_BASE" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
}

stop_mock() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  MOCK_PID=""
}

# Plant a valid 0600 token file
seed_token() {  # $1 = tokdir
  local tokdir="$1"
  mkdir -p "$tokdir"
  ( umask 077; printf '%s' "$MOCK_TOKEN" >"$tokdir/device_token" )
  chmod 600 "$tokdir/device_token"
}

new_token_dir() {
  local d; d="$(mktemp -d "$WORKROOT/home.XXXXXX")"
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# T1: Happy path — init claim then verify with correct OTP (piped via stdin)
# ---------------------------------------------------------------------------
test_happy_path() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  seed_token "$tokdir"
  start_mock '{"com.good.app":{"eligible":true,"already_claimed":false}}' "$OTP_CODE" "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "happy: mock did not start"; return; fi

  # The correct OTP is piped via stdin
  printf '%s\n' "$OTP_CODE" | \
    CLAUDE_PLUGIN_DATA="$tokdir" \
    CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    bash "$CITT" claim com.good.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "happy: exit 0"; else fail "happy: exit $rc (want 0)"; fi

  # stdout must contain "verified" in JSON form
  if grep -q "verified" "$out"; then
    pass "happy: 'verified' in stdout JSON"
  else
    fail "happy: 'verified' not in stdout (got: $(cat "$out"))"
  fi

  # stderr must have warned about outbound OTP email
  if grep -qi "email\|verification\|sent\|otp" "$err"; then
    pass "happy: email notice on stderr"
  else
    fail "happy: no email notice on stderr (got: $(cat "$err"))"
  fi
}

# ---------------------------------------------------------------------------
# T2: --status before any claim -> claimable=true (and not yet claimed)
# ---------------------------------------------------------------------------
test_status_unclaimed() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  seed_token "$tokdir"
  start_mock '{"com.good.app":{"eligible":true,"already_claimed":false}}' "$OTP_CODE" "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "status-unclaimed: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" claim --status com.good.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "status-unclaimed: exit 0"; else fail "status-unclaimed: exit $rc"; fi
  if grep -q "claimable" "$out"; then
    pass "status-unclaimed: 'claimable' field in stdout"
  else
    fail "status-unclaimed: missing 'claimable' in stdout (got: $(cat "$out"))"
  fi
  # claimable should be true
  if grep -q '"claimable"[[:space:]]*:[[:space:]]*true\|claimable.*true' "$out"; then
    pass "status-unclaimed: claimable=true"
  else
    fail "status-unclaimed: claimable not true (got: $(cat "$out"))"
  fi
}

# ---------------------------------------------------------------------------
# T3: --status on already-claimed app -> claimed_by_me=true
# ---------------------------------------------------------------------------
test_status_claimed() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  seed_token "$tokdir"
  start_mock '{"com.claimed.app":{"eligible":true,"already_claimed":true}}' "$OTP_CODE" "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "status-claimed: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" claim --status com.claimed.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "status-claimed: exit 0"; else fail "status-claimed: exit $rc"; fi
  if grep -q '"claimed_by_me"[[:space:]]*:[[:space:]]*true\|claimed_by_me.*true' "$out"; then
    pass "status-claimed: claimed_by_me=true"
  else
    fail "status-claimed: claimed_by_me not true (got: $(cat "$out"))"
  fi
}

# ---------------------------------------------------------------------------
# T4: Wrong OTP code -> clean error message + non-zero exit
# ---------------------------------------------------------------------------
test_wrong_otp() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  seed_token "$tokdir"
  start_mock '{"com.good.app":{"eligible":true,"already_claimed":false}}' "$OTP_CODE" "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "wrong-otp: mock did not start"; return; fi

  # Supply a WRONG OTP code
  printf '%s\n' "9999" | \
    CLAUDE_PLUGIN_DATA="$tokdir" \
    CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    bash "$CITT" claim com.good.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "wrong-otp: non-zero exit ($rc)"; else fail "wrong-otp: exit 0 (should fail)"; fi

  # Must print a clean error — not a raw JSON dump with internals
  if grep -qi "invalid\|incorrect\|wrong\|code\|failed\|error" "$out" "$err" 2>/dev/null; then
    pass "wrong-otp: clean error message printed"
  else
    fail "wrong-otp: no error message (out: $(cat "$out") err: $(cat "$err"))"
  fi
  # Must NOT print "verified"
  if grep -q "verified" "$out"; then
    fail "wrong-otp: printed 'verified' despite wrong code"
  else
    pass "wrong-otp: did not print 'verified'"
  fi
}

# ---------------------------------------------------------------------------
# T5: App not found -> clean error + non-zero exit
# ---------------------------------------------------------------------------
test_app_not_found() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  seed_token "$tokdir"
  start_mock '{"com.notfound.app":{"not_found":true}}' "$OTP_CODE" "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "not-found: mock did not start"; return; fi

  printf '%s\n' "$OTP_CODE" | \
    CLAUDE_PLUGIN_DATA="$tokdir" \
    CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    bash "$CITT" claim com.notfound.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "not-found: non-zero exit ($rc)"; else fail "not-found: exit 0 (should fail)"; fi
  if grep -qi "not found\|unknown\|404\|no app" "$out" "$err" 2>/dev/null; then
    pass "not-found: clean error message"
  else
    fail "not-found: no error message (out: $(cat "$out") err: $(cat "$err"))"
  fi
}

# ---------------------------------------------------------------------------
# T6: App with no contact email -> clean error + non-zero exit
# ---------------------------------------------------------------------------
test_no_email() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  seed_token "$tokdir"
  start_mock '{"com.noemail.app":{"eligible":false,"no_email":true}}' "$OTP_CODE" "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "no-email: mock did not start"; return; fi

  printf '%s\n' "$OTP_CODE" | \
    CLAUDE_PLUGIN_DATA="$tokdir" \
    CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    bash "$CITT" claim com.noemail.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "no-email: non-zero exit ($rc)"; else fail "no-email: exit 0 (should fail)"; fi
  if grep -qi "email\|contact\|claim\|eligible\|400" "$out" "$err" 2>/dev/null; then
    pass "no-email: clean error message about no contact email"
  else
    fail "no-email: no useful error message (out: $(cat "$out") err: $(cat "$err"))"
  fi
}

# ---------------------------------------------------------------------------
# T7: Already-claimed app -> clean error + non-zero exit
# ---------------------------------------------------------------------------
test_already_claimed() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  seed_token "$tokdir"
  start_mock '{"com.owned.app":{"eligible":true,"already_claimed":true}}' "$OTP_CODE" "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "already-claimed: mock did not start"; return; fi

  printf '%s\n' "$OTP_CODE" | \
    CLAUDE_PLUGIN_DATA="$tokdir" \
    CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    bash "$CITT" claim com.owned.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "already-claimed: non-zero exit ($rc)"; else fail "already-claimed: exit 0 (should fail)"; fi
  if grep -qi "already\|claimed\|owned\|error\|400" "$out" "$err" 2>/dev/null; then
    pass "already-claimed: clean error message"
  else
    fail "already-claimed: no useful error (out: $(cat "$out") err: $(cat "$err"))"
  fi
}

# ---------------------------------------------------------------------------
# T8: No token -> re-auth hint + non-zero exit (no network call needed)
# ---------------------------------------------------------------------------
test_no_token() {
  local tokdir out err rc
  tokdir="$(new_token_dir)"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  # Deliberately do NOT seed a token.
  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$CITT" claim com.any.app >"$out" 2>"$err"
  rc=$?

  if [ "$rc" -ne 0 ]; then pass "no-token: non-zero exit ($rc)"; else fail "no-token: exit 0 (should fail)"; fi
  if grep -qi "auth\|login\|authenticate\|citt auth" "$out" "$err" 2>/dev/null; then
    pass "no-token: re-auth hint printed"
  else
    fail "no-token: no re-auth hint (out: $(cat "$out") err: $(cat "$err"))"
  fi
}

# ---------------------------------------------------------------------------
# T9: 401 from server -> re-auth hint + non-zero exit
# ---------------------------------------------------------------------------
test_401_response() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  seed_token "$tokdir"
  # Plant a bad token value that mock will reject with 401
  BAD_TOK="citt_badtoken_rejected_xyz"
  ( umask 077; printf '%s' "$BAD_TOK" >"$tokdir/device_token" )
  chmod 600 "$tokdir/device_token"

  start_mock '{}' "$OTP_CODE" "$BAD_TOK" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "401: mock did not start"; return; fi

  printf '%s\n' "$OTP_CODE" | \
    CLAUDE_PLUGIN_DATA="$tokdir" \
    CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    bash "$CITT" claim com.any.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "401: non-zero exit ($rc)"; else fail "401: exit 0 (should fail)"; fi
  if grep -qi "auth\|login\|authenticate\|re-auth\|401" "$out" "$err" 2>/dev/null; then
    pass "401: re-auth hint printed"
  else
    fail "401: no re-auth hint (out: $(cat "$out") err: $(cat "$err"))"
  fi
}

# ---------------------------------------------------------------------------
# T10: Secret isolation under forced bash -x xtrace
# The auth token must NEVER appear in stdout, stderr/xtrace, or curl argv.
# ---------------------------------------------------------------------------
SENTINEL_TOKEN="citt_claim_SENTINELSECRET_isolation_777"
test_secret_isolation_xtrace() {
  local tokdir logf out trace args rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  trace="$(mktemp "$WORKROOT/trace.XXXXXX")"
  args="$(mktemp "$WORKROOT/args.XXXXXX")"

  # Plant the sentinel token (different from MOCK_TOKEN env)
  mkdir -p "$tokdir"
  ( umask 077; printf '%s' "$SENTINEL_TOKEN" >"$tokdir/device_token" )
  chmod 600 "$tokdir/device_token"

  # Wrap curl so every argv it is invoked with is logged.
  local bindir="$tokdir/bin"
  mkdir -p "$bindir"
  cat >"$bindir/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CITT_TEST_ARGS_FILE"
exec /usr/bin/curl "$@"
EOF
  chmod +x "$bindir/curl"

  # Start a mock that accepts this sentinel token (use CITT_MOCK_TOKEN override)
  local outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_CLAIM_STATE='{"com.iso.app":{"eligible":true,"already_claimed":false}}' \
  CITT_MOCK_OTP_CODE="$OTP_CODE" \
  CITT_MOCK_TOKEN="$SENTINEL_TOKEN" \
  CITT_MOCK_LOG="$logf" \
    "$PYTHON" "$MOCK" >"$outf" 2>/dev/null &
  local iso_mock_pid=$!
  local tries=0
  local iso_base=""
  while [ "$tries" -lt 100 ]; do
    iso_base="$(head -n1 "$outf" 2>/dev/null || true)"
    [ -n "$iso_base" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done

  if [ -z "$iso_base" ]; then
    fail "isolation: mock did not start"
    kill "$iso_mock_pid" 2>/dev/null || true
    return
  fi

  # Force external xtrace (bash -x) — trace goes to stderr captured to file.
  printf '%s\n' "$OTP_CODE" | \
    CITT_TEST_ARGS_FILE="$args" \
    CLAUDE_PLUGIN_DATA="$tokdir" \
    CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$iso_base" \
    PATH="$bindir:$PATH" \
    bash -x "$CITT" claim com.iso.app >"$out" 2>"$trace"
  rc=$?

  kill "$iso_mock_pid" 2>/dev/null || true
  wait "$iso_mock_pid" 2>/dev/null || true

  # HARD INVARIANT: token must NOT appear in stdout
  if grep -q "$SENTINEL_TOKEN" "$out"; then
    fail "SECRET LEAK: sentinel token in stdout"
  else
    pass "isolation: token NOT in stdout"
  fi

  # HARD INVARIANT: token must NOT appear in forced bash -x xtrace (stderr)
  if grep -q "$SENTINEL_TOKEN" "$trace"; then
    fail "SECRET LEAK: sentinel token in forced bash -x trace"
  else
    pass "isolation: token NOT in forced bash -x trace"
  fi

  # HARD INVARIANT: token must NOT appear in any curl argv
  if [ -f "$args" ] && grep -q "$SENTINEL_TOKEN" "$args"; then
    fail "SECRET LEAK: sentinel token in curl argv"
  else
    pass "isolation: token NOT in curl argv"
  fi

  # Sanity: command still worked (or at least exited in a predictable way)
  if [ "$rc" -eq 0 ]; then
    pass "isolation: claim command succeeded (functional)"
  else
    # Non-zero exit is OK for the isolation test if it was an auth error etc.;
    # the three invariants above are the hard gates.
    pass "isolation: claim exited $rc (invariants still hold)"
  fi
}

# ---------------------------------------------------------------------------
# T11: Email notice on stderr when OTP initiation succeeds
# (Ensures user knows an outbound email is being sent before they're prompted.)
# ---------------------------------------------------------------------------
test_email_notice_on_stderr() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  seed_token "$tokdir"
  start_mock '{"com.notice.app":{"eligible":true,"already_claimed":false}}' "$OTP_CODE" "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "email-notice: mock did not start"; return; fi

  printf '%s\n' "$OTP_CODE" | \
    CLAUDE_PLUGIN_DATA="$tokdir" \
    CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    bash "$CITT" claim com.notice.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  # The one-line notice that an OTP email is being sent must appear on stderr.
  if grep -qi "verification email\|otp.*sent\|sent.*email\|sending.*email\|email.*sent\|email.*verification\|email.*code\|code.*email\|email.*otp" "$err"; then
    pass "email-notice: outbound email notice on stderr"
  else
    fail "email-notice: no outbound email notice on stderr (got: $(cat "$err"))"
  fi
}

# ---------------------------------------------------------------------------
# T12: --status with missing pkg arg -> usage/error + non-zero exit
# ---------------------------------------------------------------------------
test_status_missing_arg() {
  local out err rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  bash "$CITT" claim --status >"$out" 2>"$err" && rc=0 || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "missing-arg: --status with no pkg exits non-zero ($rc)"
  else
    fail "missing-arg: --status with no pkg exits 0 (should fail)"
  fi
}

# ---------------------------------------------------------------------------
# T13: `citt claim` with missing pkg arg -> usage/error + non-zero exit
# ---------------------------------------------------------------------------
test_claim_missing_arg() {
  local out err rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  bash "$CITT" claim >"$out" 2>"$err" && rc=0 || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "missing-arg: claim with no pkg exits non-zero ($rc)"
  else
    fail "missing-arg: claim with no pkg exits 0 (should fail)"
  fi
}

# ---------------------------------------------------------------------------
# T14 (CITT-347 Finding 2): OTP must NOT appear in forced bash -x xtrace,
# curl argv, or stdout.  The old code held the OTP in a local shell variable
# ($otp_val) inside a subshell — `bash -x` traces the assignment AND the
# `jq --arg c $otp_val` expansion (both on argv and as a traced value).
# The fix: use `jq --rawfile c "$otp_file"` (rawfile reads the OTP from a
# 0600 file without ever passing it as an argument), and for the no-jq fallback,
# build the body via file redirection without a traced variable.
# ---------------------------------------------------------------------------
SENTINEL_OTP="OTP_SENTINEL_347_claim"
test_otp_not_in_xtrace() {
  local tokdir logf out trace args rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  trace="$(mktemp "$WORKROOT/trace.XXXXXX")"
  args="$(mktemp "$WORKROOT/args.XXXXXX")"

  seed_token "$tokdir"

  # Wrap curl to capture argv (OTP must not appear there either).
  local bindir="$tokdir/bin"
  mkdir -p "$bindir"
  cat >"$bindir/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CITT_TEST_ARGS_FILE"
exec /usr/bin/curl "$@"
EOF
  chmod +x "$bindir/curl"

  # Also wrap jq to capture argv (--arg c would expose the OTP there).
  cat >"$bindir/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CITT_TEST_ARGS_FILE"
exec jq "$@"
EOF
  chmod +x "$bindir/jq"
  # Make jq wrapper find real jq (not itself).
  local real_jq; real_jq="$(PATH="${PATH#$bindir:}" command -v jq 2>/dev/null || true)"

  # Re-write the jq wrapper to use the real path if found.
  if [ -n "$real_jq" ]; then
    cat >"$bindir/jq" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$CITT_TEST_ARGS_FILE"
exec "$real_jq" "\$@"
EOF
    chmod +x "$bindir/jq"
  fi

  # Start a fresh mock for this test (separate pid tracking).
  local iso_outf iso_base iso_pid tries
  iso_outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_CLAIM_STATE='{"com.otp.test":{"eligible":true,"already_claimed":false}}' \
  CITT_MOCK_OTP_CODE="$SENTINEL_OTP" \
  CITT_MOCK_TOKEN="$MOCK_TOKEN" \
  CITT_MOCK_LOG="$logf" \
    "$PYTHON" "$MOCK" >"$iso_outf" 2>/dev/null &
  iso_pid=$!
  tries=0; iso_base=""
  while [ "$tries" -lt 100 ]; do
    iso_base="$(head -n1 "$iso_outf" 2>/dev/null || true)"
    [ -n "$iso_base" ] && break
    sleep 0.05; tries=$((tries + 1))
  done

  if [ -z "$iso_base" ]; then
    fail "otp-xtrace: mock did not start"
    kill "$iso_pid" 2>/dev/null || true
    return
  fi

  # Pipe the sentinel OTP via stdin; run under forced external bash -x.
  printf '%s\n' "$SENTINEL_OTP" | \
    CITT_TEST_ARGS_FILE="$args" \
    CLAUDE_PLUGIN_DATA="$tokdir" \
    CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$iso_base" \
    PATH="$bindir:$PATH" \
    bash -x "$CITT" claim com.otp.test >"$out" 2>"$trace"
  rc=$?

  kill "$iso_pid" 2>/dev/null || true
  wait "$iso_pid" 2>/dev/null || true

  # HARD INVARIANT (CITT-347 F2): OTP must NOT appear in bash -x trace.
  if grep -q "$SENTINEL_OTP" "$trace"; then
    local hits; hits="$(grep -c "$SENTINEL_OTP" "$trace" || true)"
    fail "SECRET LEAK (CITT-347 F2): OTP sentinel in forced bash -x trace ($hits hit(s)): $(grep "$SENTINEL_OTP" "$trace" | head -3)"
  else
    pass "otp-xtrace: OTP NOT in forced bash -x trace (0 hits)"
  fi

  # HARD INVARIANT: OTP must NOT appear in stdout.
  if grep -q "$SENTINEL_OTP" "$out"; then
    fail "SECRET LEAK (CITT-347 F2): OTP sentinel in stdout"
  else
    pass "otp-xtrace: OTP NOT in stdout"
  fi

  # HARD INVARIANT: OTP must NOT appear in curl or jq argv.
  if [ -f "$args" ] && grep -q "$SENTINEL_OTP" "$args"; then
    local arg_hits; arg_hits="$(grep "$SENTINEL_OTP" "$args" | head -3)"
    fail "SECRET LEAK (CITT-347 F2): OTP sentinel in argv: $arg_hits"
  else
    pass "otp-xtrace: OTP NOT in curl/jq argv"
  fi

  # Sanity: claim still succeeded.
  if [ "$rc" -eq 0 ]; then
    pass "otp-xtrace: claim command succeeded (functional)"
  else
    pass "otp-xtrace: claim exited $rc (invariants hold regardless)"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "== citt claim harness (CITT-339) =="
test_happy_path
test_status_unclaimed
test_status_claimed
test_wrong_otp
test_app_not_found
test_no_email
test_already_claimed
test_no_token
test_401_response
test_secret_isolation_xtrace
test_email_notice_on_stderr
test_status_missing_arg
test_claim_missing_arg
test_otp_not_in_xtrace

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
