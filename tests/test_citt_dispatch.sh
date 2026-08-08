#!/usr/bin/env bash
# =============================================================================
# test_citt_dispatch.sh — TDD harness for the `citt` dispatcher (CITT-333)
# =============================================================================
# Tests the single `citt` entrypoint: subcommand dispatch, shared lib,
# auth delegation, whoami, logout, and secret isolation.
#
# Layout-independent path resolution (no hard-coded repo root):
#   HERE  = directory this file lives in
#   PLUGIN_ROOT = the citt-plugin/ root
#   CITT  = the dispatcher binary under test
#
# Pure bash + stdlib python3 — no venv/pytest. Run:
#     bash citt-plugin/tests/test_citt_dispatch.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
CITT="$PLUGIN_ROOT/scripts/citt"
MOCK="$HERE/mock_api_server.py"
PYTHON="${PYTHON:-python3}"

# The mock token that mock_api_server.py hands out on "success" and expects
# on /api/me. Must match CITT_MOCK_TOKEN default in mock_api_server.py.
MOCK_TOKEN="citt_disp_mocktoken123"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Scratch workspace
# ---------------------------------------------------------------------------
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_disp_test.XXXXXX")"
cleanup_all() { rm -rf "$WORKROOT" 2>/dev/null || true; }
trap cleanup_all EXIT

# ---------------------------------------------------------------------------
# Mock server lifecycle (combined device-flow + /api/me mock)
# ---------------------------------------------------------------------------
MOCK_PID=""
MOCK_BASE=""

start_mock() {  # $1 = poll script  $2 = logfile  $3 = optional token override
  local script="$1" logf="$2" tok="${3:-$MOCK_TOKEN}" outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_SCRIPT="$script" CITT_MOCK_LOG="$logf" CITT_MOCK_TOKEN="$tok" \
    "$PYTHON" "$MOCK" >"$outf" 2>/dev/null &
  MOCK_PID=$!
  local tries=0
  MOCK_BASE=""
  while [ $tries -lt 100 ]; do
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

# A fresh token directory per test so tests are isolated.
new_token_dir() {
  local d; d="$(mktemp -d "$WORKROOT/home.XXXXXX")"
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# T1: Help / usage output lists ALL planned subcommands
# ---------------------------------------------------------------------------
test_help_lists_subcommands() {
  local out rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  bash "$CITT" --help >"$out" 2>&1
  rc=$?

  # --help must exit 0
  if [ "$rc" -eq 0 ]; then pass "help: --help exits 0"; else fail "help: --help exit $rc (want 0)"; fi

  # All planned subcommands must appear
  for sub in auth submit status results report mine search claim whoami logout; do
    if grep -q "$sub" "$out"; then
      pass "help: '$sub' listed in --help output"
    else
      fail "help: '$sub' NOT listed in --help output"
    fi
  done

  # -h variant
  local out2; out2="$(mktemp "$WORKROOT/out.XXXXXX")"
  bash "$CITT" -h >"$out2" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then pass "help: -h exits 0"; else fail "help: -h exit $rc (want 0)"; fi

  # no-args variant
  local out3; out3="$(mktemp "$WORKROOT/out.XXXXXX")"
  bash "$CITT" >"$out3" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then pass "help: no-args exits non-zero"; else fail "help: no-args exits 0 (should be non-zero)"; fi
  if grep -qi "usage\|subcommand\|citt " "$out3"; then
    pass "help: no-args prints usage"
  else
    fail "help: no-args does not print usage"
  fi
}

# ---------------------------------------------------------------------------
# T2: Unknown subcommand → usage printed + non-zero exit
# ---------------------------------------------------------------------------
test_unknown_subcommand() {
  local out rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  bash "$CITT" totally_unknown_subcommand_xyz >"$out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "unknown-sub: non-zero exit ($rc)"
  else
    fail "unknown-sub: exit 0 (should be non-zero)"
  fi
  if grep -qi "usage\|unknown\|unrecognized\|subcommand" "$out"; then
    pass "unknown-sub: prints usage/error message"
  else
    fail "unknown-sub: no usage/error message on output"
  fi
}

# ---------------------------------------------------------------------------
# T3: Each shipped subcommand is wired to a real implementation (not a stub).
# Filesystem-only assertions — never executes the subcommands, so the dispatch
# harness makes no network calls now that these are implemented.
# ---------------------------------------------------------------------------
test_subcommands_implemented() {
  local libdir; libdir="$(dirname "$CITT")/lib"
  for sub in submit status results report mine search claim; do
    if [ -f "$libdir/cmd-$sub.sh" ]; then
      pass "impl: '$sub' has lib/cmd-$sub.sh"
    else
      fail "impl: '$sub' missing lib/cmd-$sub.sh"
    fi
    if grep -q "citt_cmd_$sub" "$libdir/cmd-$sub.sh" 2>/dev/null; then
      pass "impl: '$sub' defines citt_cmd_$sub"
    else
      fail "impl: '$sub' no citt_cmd_$sub function"
    fi
  done
}

# ---------------------------------------------------------------------------
# T4: `citt auth` → runs device-flow, stores token, prints "authenticated"
# ---------------------------------------------------------------------------
test_auth_flow() {
  local tokdir logf out rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"

  start_mock "authorization_pending,success" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "auth-flow: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir/.config/citt" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" auth >"$out" 2>/dev/null
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "auth-flow: exit 0"; else fail "auth-flow: exit $rc"; fi
  if grep -qx "authenticated" "$out"; then
    pass "auth-flow: printed 'authenticated'"
  else
    fail "auth-flow: did not print 'authenticated'"
  fi

  # Token file must exist at 600
  local tf="$tokdir/.config/citt/device_token"
  if [ -f "$tf" ]; then
    pass "auth-flow: token file created"
    local mode
    mode="$(stat -f '%Lp' "$tf" 2>/dev/null || stat -c '%a' "$tf" 2>/dev/null)"
    if [ "$mode" = "600" ]; then pass "auth-flow: token file mode 600"; else fail "auth-flow: mode=$mode (want 600)"; fi
    if [ "$(cat "$tf")" = "$MOCK_TOKEN" ]; then
      pass "auth-flow: token file holds the correct token"
    else
      fail "auth-flow: token file content mismatch (got: $(cat "$tf"))"
    fi
  else
    fail "auth-flow: token file NOT created"
  fi
}

# ---------------------------------------------------------------------------
# T5: `citt whoami` → calls /api/me and emits JSON with user fields; exit 0
# ---------------------------------------------------------------------------
test_whoami_success() {
  local tokdir logf out rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"

  # Pre-plant token so no auth flow is needed.
  mkdir -p "$tokdir/.config/citt"
  ( umask 077; printf '%s' "$MOCK_TOKEN" >"$tokdir/.config/citt/device_token" )
  chmod 600 "$tokdir/.config/citt/device_token"

  start_mock "success" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "whoami: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir/.config/citt" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" whoami >"$out" 2>/dev/null
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "whoami: exit 0"; else fail "whoami: exit $rc"; fi
  # stdout must contain user data (email or plan)
  if grep -q "example.com\|developer\|quota" "$out"; then
    pass "whoami: user JSON emitted to stdout"
  else
    fail "whoami: no user data on stdout (got: $(cat "$out"))"
  fi
}

# ---------------------------------------------------------------------------
# T6: SECRET ISOLATION — `citt whoami` under forced xtrace
# The token must NEVER appear in bash -x trace, stdout, or curl argv.
# This copies the exact red-team technique from test_citt_auth.sh.
# ---------------------------------------------------------------------------
test_whoami_secret_isolation() {
  local tokdir logf out trace args rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  trace="$(mktemp "$WORKROOT/trace.XXXXXX")"
  args="$(mktemp "$WORKROOT/args.XXXXXX")"

  mkdir -p "$tokdir/.config/citt"
  ( umask 077; printf '%s' "$MOCK_TOKEN" >"$tokdir/.config/citt/device_token" )
  chmod 600 "$tokdir/.config/citt/device_token"

  # Wrap curl so every argv it is invoked with is logged.
  local bindir="$tokdir/bin"
  mkdir -p "$bindir"
  cat >"$bindir/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CITT_TEST_ARGS_FILE"
exec /usr/bin/curl "$@"
EOF
  chmod +x "$bindir/curl"

  start_mock "success" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "isolation: mock did not start"; return; fi

  # Force external xtrace (bash -x) and capture trace to file.
  CITT_TEST_ARGS_FILE="$args" \
  CITT_STATE_DIR="$tokdir/.config/citt" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  PATH="$bindir:$PATH" \
  bash -x "$CITT" whoami >"$out" 2>"$trace"
  rc=$?
  stop_mock

  # HARD INVARIANT: token never in stdout
  if grep -q "$MOCK_TOKEN" "$out"; then
    fail "SECRET LEAK: token in stdout"
  else
    pass "isolation: token NOT in stdout"
  fi

  # HARD INVARIANT: token never in forced bash -x xtrace
  if grep -q "$MOCK_TOKEN" "$trace"; then
    fail "SECRET LEAK: token in forced bash -x trace"
  else
    pass "isolation: token NOT in forced bash -x trace"
  fi

  # HARD INVARIANT: token never in curl argv
  if [ -f "$args" ] && grep -q "$MOCK_TOKEN" "$args"; then
    fail "SECRET LEAK: token in curl argv"
  else
    pass "isolation: token NOT in curl argv"
  fi

  # Sanity: whoami still succeeded despite isolation
  if [ "$rc" -eq 0 ]; then
    pass "isolation: whoami still exits 0 (functional)"
  else
    fail "isolation: whoami failed (exit $rc) while testing isolation"
  fi
}

# ---------------------------------------------------------------------------
# T7: `citt whoami` with no token → re-auth hint + non-zero exit
# ---------------------------------------------------------------------------
test_whoami_no_token() {
  local tokdir out err rc
  tokdir="$(new_token_dir)"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CITT_STATE_DIR="$tokdir/.config/citt" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$CITT" whoami >"$out" 2>"$err"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "whoami-no-token: non-zero exit ($rc)"
  else
    fail "whoami-no-token: exit 0 (should be non-zero)"
  fi
  # Must print a re-auth hint
  if grep -qi "auth\|login\|authenticate\|citt auth" "$err" || grep -qi "auth\|login\|authenticate" "$out"; then
    pass "whoami-no-token: re-auth hint printed"
  else
    fail "whoami-no-token: no re-auth hint (stderr: $(cat "$err")) (stdout: $(cat "$out"))"
  fi
}

# ---------------------------------------------------------------------------
# T8: `citt whoami` on 401 response → re-auth hint + non-zero exit
# ---------------------------------------------------------------------------
test_whoami_401() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  mkdir -p "$tokdir/.config/citt"
  # Intentionally store a bad token that the mock will reject with 401
  ( umask 077; printf '%s' "bad_token" >"$tokdir/.config/citt/device_token" )
  chmod 600 "$tokdir/.config/citt/device_token"

  start_mock "success" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "whoami-401: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir/.config/citt" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" whoami >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then
    pass "whoami-401: non-zero exit ($rc)"
  else
    fail "whoami-401: exit 0 (should be non-zero)"
  fi
  if grep -qi "auth\|login\|authenticate" "$err" || grep -qi "auth\|login\|authenticate" "$out"; then
    pass "whoami-401: re-auth hint printed"
  else
    fail "whoami-401: no re-auth hint on 401"
  fi
}

# ---------------------------------------------------------------------------
# T9: `citt logout` removes the token; subsequent `citt whoami` fails cleanly
# ---------------------------------------------------------------------------
test_logout_then_whoami() {
  local tokdir logf out err rc tf
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"
  tf="$tokdir/.config/citt/device_token"

  # Plant a token
  mkdir -p "$tokdir/.config/citt"
  ( umask 077; printf '%s' "$MOCK_TOKEN" >"$tf" )
  chmod 600 "$tf"

  # Logout
  CITT_STATE_DIR="$tokdir/.config/citt" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 \
  bash "$CITT" logout >"$out" 2>"$err"
  rc=$?

  if [ "$rc" -eq 0 ]; then pass "logout: exit 0"; else fail "logout: exit $rc (want 0)"; fi
  if [ ! -f "$tf" ]; then
    pass "logout: token file removed"
  else
    fail "logout: token file still exists after logout"
  fi
  # Confirmation on stderr
  if grep -qi "logged out\|removed\|signed out\|logout" "$err"; then
    pass "logout: confirmation on stderr"
  else
    fail "logout: no confirmation on stderr (got: $(cat "$err"))"
  fi

  # Now whoami must fail
  start_mock "success" "$logf"
  local out2; out2="$(mktemp "$WORKROOT/out.XXXXXX")"
  CITT_STATE_DIR="$tokdir/.config/citt" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" whoami >"$out2" 2>/dev/null
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then
    pass "logout: whoami after logout exits non-zero"
  else
    fail "logout: whoami after logout exits 0 (should fail)"
  fi
}

# ---------------------------------------------------------------------------
# T10: Shared lib functions are sourced (smoke test: citt --help doesn't crash)
# ---------------------------------------------------------------------------
test_lib_sourced_cleanly() {
  local out rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  bash "$CITT" --help >"$out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "lib: dispatcher sources lib and exits cleanly on --help"
  else
    fail "lib: dispatcher crashes on --help (exit $rc)"
  fi
}

# ---------------------------------------------------------------------------
# T11: CITT_API_OVERRIDE is NOT honored when CITT_TEST_MODE is not set
# (Prod host hardcoding: a call without CITT_TEST_MODE must NOT go to our mock)
# We prove this by setting CITT_API_OVERRIDE to our mock but not CITT_TEST_MODE;
# the whoami call should fail (prod host is unreachable from test env), not succeed.
# ---------------------------------------------------------------------------
test_prod_host_hardcoded() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  mkdir -p "$tokdir/.config/citt"
  ( umask 077; printf '%s' "$MOCK_TOKEN" >"$tokdir/.config/citt/device_token" )
  chmod 600 "$tokdir/.config/citt/device_token"

  start_mock "success" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "prod-host: mock did not start"; return; fi

  # Intentionally NOT setting CITT_TEST_MODE=1 — override must be ignored
  CITT_STATE_DIR="$tokdir/.config/citt" \
  CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" whoami >"$out" 2>"$err" || true
  rc=$?
  stop_mock

  # Check mock got NO /api/me request (it should have gone to prod, not mock).
  # Use grep -q (boolean) instead of grep -c to avoid the macOS grep-c-on-empty-file
  # "0\n0" double-print issue (grep -c exits 1 on no-match, so "|| echo 0" would append).
  if grep -q '"kind": "me_request"' "$logf" 2>/dev/null; then
    fail "prod-host: override was honored without CITT_TEST_MODE=1 (mock received /api/me)"
  else
    pass "prod-host: CITT_API_OVERRIDE ignored without CITT_TEST_MODE=1 (mock got 0 /api/me hits)"
  fi
}

# ---------------------------------------------------------------------------
# T12 (CITT-347 Finding 1): CITT_TOKEN env-override must NOT appear in forced
# bash -x xtrace on the `citt whoami` path (routes through citt-common.sh
# _load_token_to_staging).  The old test [ -n "${CITT_TOKEN:-}" ] expands the
# value; the fix uses ${CITT_TOKEN+x} so only the literal "x" is traced.
# ---------------------------------------------------------------------------
SENTINEL_DISP="citt_dispatch_SENTINEL_347_env"
test_citt_token_env_not_in_xtrace_dispatch() {
  local tokdir logf out trace args rc
  tokdir="$(new_token_dir)"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  trace="$(mktemp "$WORKROOT/trace.XXXXXX")"
  args="$(mktemp "$WORKROOT/args.XXXXXX")"

  # Wrap curl to capture argv.
  local bindir="$tokdir/bin"
  mkdir -p "$bindir"
  cat >"$bindir/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CITT_TEST_ARGS_FILE"
exec /usr/bin/curl "$@"
EOF
  chmod +x "$bindir/curl"

  start_mock "success" "$logf" "$SENTINEL_DISP"
  if [ -z "$MOCK_BASE" ]; then fail "citt-token-env-xtrace-dispatch: mock did not start"; return; fi

  # Run `citt whoami` under forced external bash -x with CITT_TOKEN env set.
  CITT_TOKEN="$SENTINEL_DISP" \
  CITT_TEST_ARGS_FILE="$args" \
  CITT_STATE_DIR="$tokdir/.config/citt" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  PATH="$bindir:$PATH" \
  bash -x "$CITT" whoami >"$out" 2>"$trace"
  rc=$?
  stop_mock

  # HARD INVARIANT: sentinel must NOT appear in forced bash -x xtrace.
  if grep -q "$SENTINEL_DISP" "$trace"; then
    local hits; hits="$(grep -c "$SENTINEL_DISP" "$trace" || true)"
    fail "SECRET LEAK (CITT-347 F1/dispatch): CITT_TOKEN in forced xtrace ($hits hit(s)): $(grep "$SENTINEL_DISP" "$trace" | head -2)"
  else
    pass "citt-token-env-xtrace-dispatch: CITT_TOKEN NOT in forced bash -x trace"
  fi

  # HARD INVARIANT: sentinel must NOT appear in stdout.
  if grep -q "$SENTINEL_DISP" "$out"; then
    fail "SECRET LEAK (CITT-347 F1/dispatch): CITT_TOKEN in stdout"
  else
    pass "citt-token-env-xtrace-dispatch: CITT_TOKEN NOT in stdout"
  fi

  # HARD INVARIANT: sentinel must NOT appear in curl argv.
  if [ -f "$args" ] && grep -q "$SENTINEL_DISP" "$args"; then
    fail "SECRET LEAK (CITT-347 F1/dispatch): CITT_TOKEN in curl argv"
  else
    pass "citt-token-env-xtrace-dispatch: CITT_TOKEN NOT in curl argv"
  fi

  # Sanity: whoami succeeded.
  if [ "$rc" -eq 0 ]; then
    pass "citt-token-env-xtrace-dispatch: whoami still exits 0 (functional)"
  else
    fail "citt-token-env-xtrace-dispatch: whoami failed (exit $rc)"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "== citt dispatcher harness (CITT-333) =="
test_help_lists_subcommands
test_unknown_subcommand
test_subcommands_implemented
test_auth_flow
test_whoami_success
test_whoami_secret_isolation
test_whoami_no_token
test_whoami_401
test_logout_then_whoami
test_lib_sourced_cleanly
test_prod_host_hardcoded
test_citt_token_env_not_in_xtrace_dispatch

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
