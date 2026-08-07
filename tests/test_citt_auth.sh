#!/usr/bin/env bash
# =============================================================================
# test_citt_auth.sh — TDD harness for citt-auth.sh (CITT-267)
# =============================================================================
# Runs citt-auth.sh against a local MOCK device-flow server (mock_device_server.py)
# via the test-only CITT_API_OVERRIDE seam (honored only under CITT_TEST_MODE=1;
# the production host stays hardcoded). Asserts the hard secret-isolation
# invariants (token never in stdout / argv / xtrace) plus the poll transitions,
# the already-authenticated short-circuit, and the CITT_TOKEN override.
#
# Pure bash + stdlib python3 — no venv/pytest needed. Run:
#     bash citt-plugin/tests/test_citt_auth.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
AUTH="$PLUGIN_ROOT/scripts/citt-auth.sh"
MOCK="$HERE/mock_device_server.py"
PYTHON="${PYTHON:-python3}"

MOCK_TOKEN="citt_tokid123_supersecretvalue456"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

# Per-test scratch dir + mock lifecycle -------------------------------------
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_auth_test.XXXXXX")"
cleanup_all() { rm -rf "$WORKROOT" 2>/dev/null || true; }
trap cleanup_all EXIT

MOCK_PID=""
MOCK_BASE=""
start_mock() {  # $1 = comma-separated poll script, $2 = log file, $3 = optional token override
  local script="$1" logf="$2" tok="${3:-$MOCK_TOKEN}" outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_SCRIPT="$script" CITT_MOCK_LOG="$logf" CITT_MOCK_TOKEN="$tok" \
    "$PYTHON" "$MOCK" >"$outf" 2>/dev/null &
  MOCK_PID=$!
  # Wait for the base URL line.
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

# A fresh HOME/token dir per test so short-circuit tests start clean and keyring
# is bypassed (we force the file fallback by unsetting keyring on CI-like runs).
new_env_dir() {
  local d
  d="$(mktemp -d "$WORKROOT/home.XXXXXX")"
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# Test 1: full success flow — token stored 0600, "authenticated" printed,
# and the TOKEN NEVER appears in stdout, argv, or an xtrace.
# ---------------------------------------------------------------------------
test_success_flow_and_secret_isolation() {
  local envdir tokdir logf out args xtrace rc
  envdir="$(new_env_dir)"
  tokdir="$envdir/.config/citt"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  args="$(mktemp "$WORKROOT/args.XXXXXX")"
  xtrace="$(mktemp "$WORKROOT/xtrace.XXXXXX")"

  start_mock "authorization_pending,success" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "success: mock did not start"; return; fi

  # Wrap curl so every argv it is invoked with is logged — this is how we prove
  # the token is never passed as an argument to an external command.
  local bindir="$envdir/bin"
  mkdir -p "$bindir"
  cat >"$bindir/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$args"
exec /usr/bin/curl "\$@"
EOF
  chmod +x "$bindir/curl"

  # Run the script under `set -x` with the xtrace redirected to a file, so we can
  # prove the token never appears on a traced line either.
  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  PATH="$bindir:$PATH" \
  BASH_XTRACEFD=9 \
  bash -x "$AUTH" >"$out" 2>/dev/null 9>"$xtrace"
  rc=$?
  stop_mock

  # Exit 0 + "authenticated".
  if [ "$rc" -eq 0 ]; then pass "success: exit 0"; else fail "success: exit $rc"; fi
  if grep -qx "authenticated" "$out"; then
    pass "success: printed 'authenticated'"
  else
    fail "success: did not print 'authenticated'"
  fi

  # Token stored in the fallback file at mode 600 with exactly the token value.
  local tf="$tokdir/device_token"
  if [ -f "$tf" ]; then
    pass "success: token file created"
    local mode
    mode="$(stat -f '%Lp' "$tf" 2>/dev/null || stat -c '%a' "$tf" 2>/dev/null)"
    if [ "$mode" = "600" ]; then pass "success: token file mode 600"; else fail "success: token file mode=$mode (want 600)"; fi
    if [ "$(cat "$tf")" = "$MOCK_TOKEN" ]; then
      pass "success: token file holds exactly the minted token"
    else
      fail "success: token file content mismatch"
    fi
  else
    fail "success: token file NOT created"
  fi

  # HARD INVARIANT: token never in stdout.
  if grep -q "$MOCK_TOKEN" "$out"; then fail "SECRET LEAK: token in stdout"; else pass "secret: token NOT in stdout"; fi
  # HARD INVARIANT: token never in any curl argv.
  if grep -q "$MOCK_TOKEN" "$args"; then fail "SECRET LEAK: token in curl argv"; else pass "secret: token NOT in curl argv"; fi
  # HARD INVARIANT: token never on an xtrace line.
  if grep -q "$MOCK_TOKEN" "$xtrace"; then fail "SECRET LEAK: token in set -x trace"; else pass "secret: token NOT in set -x trace"; fi
  # Sanity: the verification link WAS printed.
  if grep -q "link?dc=" "$out"; then pass "success: verification link printed"; else fail "success: no verification link on stdout"; fi
}

# ---------------------------------------------------------------------------
# Test 1b (QA-270 Finding A / CITT-272): under a FORCED EXTERNAL xtrace
# (`bash -x ... 2>trace`), the minted access_token must NOT appear on any traced
# line. This catches the regression where the 200-response body was read into a
# shell var ($BODY) on the success iteration — xtrace then dumps the token. The
# fix reads the token file->file, so it never lands in a shell variable. We still
# assert the token was stored correctly to prove extraction wasn't broken.
# ---------------------------------------------------------------------------
SENTINEL_TOKEN="citt_ridtest_SENTINELSECRET123"
test_token_not_in_forced_xtrace() {
  local envdir tokdir logf out trace rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  trace="$(mktemp "$WORKROOT/trace.XXXXXX")"

  # Mock hands out the SENTINEL token on the success poll.
  start_mock "authorization_pending,success" "$logf" "$SENTINEL_TOKEN"
  if [ -z "$MOCK_BASE" ]; then fail "xtrace: mock did not start"; return; fi

  # Force xtrace EXTERNALLY (`bash -x`, no `set -x` in the script) with the trace
  # captured to a file via stderr — exactly the red-team invocation from the finding.
  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash -x "$AUTH" >"$out" 2>"$trace"
  rc=$?
  stop_mock

  # HARD INVARIANT: sentinel token never appears on a forced-xtrace line.
  # (Use grep -q, not grep -c: `grep -c` exits 1 with output "0" on no-match, and
  # a `|| echo 0` fallback would double it — so branch on the match itself.)
  local hits
  hits="$(grep -c "$SENTINEL_TOKEN" "$trace" 2>/dev/null | head -n1)"
  if ! grep -q "$SENTINEL_TOKEN" "$trace" 2>/dev/null; then
    pass "xtrace(forced -x): token NOT in trace (0 hits)"
  else
    fail "SECRET LEAK: token appears $hits time(s) in forced bash -x trace"
  fi

  # Prove the fix didn't break extraction: exit 0, authenticated, token stored 0600.
  if [ "$rc" -eq 0 ] && grep -qx "authenticated" "$out"; then
    pass "xtrace: still authenticated (extraction intact)"
  else
    fail "xtrace: expected authenticated (exit $rc)"
  fi
  local tf="$tokdir/device_token"
  if [ -f "$tf" ] && [ "$(cat "$tf")" = "$SENTINEL_TOKEN" ]; then
    pass "xtrace: token file holds exactly the minted token"
  else
    fail "xtrace: token file missing or content mismatch"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: authorization_pending keeps polling, slow_down backs off, then success.
# (We assert multiple /api/device/token requests were made => it kept polling.)
# ---------------------------------------------------------------------------
test_poll_transitions() {
  local envdir tokdir logf out rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"

  start_mock "authorization_pending,slow_down,authorization_pending,success" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "transitions: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$AUTH" >"$out" 2>/dev/null
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ] && grep -qx "authenticated" "$out"; then
    pass "transitions: pending+slow_down then success -> authenticated"
  else
    fail "transitions: expected authenticated (exit $rc)"
  fi

  local polls
  polls="$(grep -c '"kind": "device_token"' "$logf" 2>/dev/null || echo 0)"
  if [ "$polls" -ge 4 ]; then
    pass "transitions: polled the token endpoint $polls times (kept polling through pending/slow_down)"
  else
    fail "transitions: only $polls token polls (expected >=4)"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: access_denied (tier) -> prints upgrade message + non-zero exit, no token.
# ---------------------------------------------------------------------------
test_access_denied_tier() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "authorization_pending,access_denied" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "denied: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$AUTH" >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "denied: non-zero exit ($rc)"; else fail "denied: exit 0 (should fail)"; fi
  if grep -qi "upgrade\|Developer\|Research\|pricing" "$err"; then
    pass "denied: upgrade nudge printed to stderr"
  else
    fail "denied: no upgrade nudge on stderr"
  fi
  if [ -f "$tokdir/device_token" ]; then fail "denied: token file should NOT exist"; else pass "denied: no token stored"; fi
  if grep -qx "authenticated" "$out"; then fail "denied: must not print authenticated"; else pass "denied: did not print authenticated"; fi
}

# ---------------------------------------------------------------------------
# Test 4: already-authenticated short-circuit — valid TOKEN_FILE => no network.
# We point the override at a DEAD port; if the script makes a call it will hang/
# fail, so success (fast "authenticated") proves no network call was attempted.
# ---------------------------------------------------------------------------
test_already_authenticated_no_network() {
  local envdir tokdir out rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  mkdir -p "$tokdir"
  ( umask 077; printf '%s' "$MOCK_TOKEN" >"$tokdir/device_token" )
  chmod 600 "$tokdir/device_token"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"

  # Dead endpoint: if a network call is made it would error; short-circuit avoids it.
  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$AUTH" >"$out" 2>/dev/null
  rc=$?

  if [ "$rc" -eq 0 ] && grep -qx "authenticated" "$out"; then
    pass "short-circuit: valid token file -> authenticated, no network"
  else
    fail "short-circuit: expected authenticated w/o network (exit $rc)"
  fi
  if grep -q "$MOCK_TOKEN" "$out"; then fail "SECRET LEAK: token in stdout on short-circuit"; else pass "short-circuit: token not echoed"; fi
}

# ---------------------------------------------------------------------------
# Test 5: CITT_TOKEN override — authenticated w/o network, value never echoed.
# ---------------------------------------------------------------------------
test_citt_token_override() {
  local envdir tokdir out rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TOKEN="citt_envoverride_secretenvvalue" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$AUTH" >"$out" 2>/dev/null
  rc=$?

  if [ "$rc" -eq 0 ] && grep -qx "authenticated" "$out"; then
    pass "env-override: CITT_TOKEN -> authenticated"
  else
    fail "env-override: expected authenticated (exit $rc)"
  fi
  if grep -q "citt_envoverride_secretenvvalue" "$out"; then
    fail "SECRET LEAK: CITT_TOKEN value echoed"
  else
    pass "env-override: CITT_TOKEN value not echoed"
  fi
  if [ -f "$tokdir/device_token" ]; then fail "env-override: must not write a token file"; else pass "env-override: no token file written"; fi
}

# ---------------------------------------------------------------------------
# Test 6: KEYRING round-trip (only if an OS keyring backend exists). Runs the
# real success flow WITHOUT the force-file override so the keyring path executes:
# the token must land in the keyring (NOT the fallback file), the token must not
# leak to stdout, and a subsequent run must short-circuit via keyring presence.
# Cleans up the keychain/secret-service entry afterwards.
# ---------------------------------------------------------------------------
KR_SERVICE="canitrustthat-citt"
KR_ACCOUNT="device_token"
_kr_backend() {
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then echo security; return; fi
  if command -v secret-tool >/dev/null 2>&1; then echo secret-tool; return; fi
  echo ""
}
_kr_cleanup() {
  case "$1" in
    security) security delete-generic-password -s "$KR_SERVICE" -a "$KR_ACCOUNT" >/dev/null 2>&1 || true ;;
    secret-tool) secret-tool clear service "$KR_SERVICE" account "$KR_ACCOUNT" >/dev/null 2>&1 || true ;;
  esac
}
test_keyring_roundtrip() {
  local backend; backend="$(_kr_backend)"
  if [ -z "$backend" ]; then
    printf '  skip - keyring: no OS keyring backend on this host\n'
    return
  fi
  local envdir tokdir logf out rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"

  _kr_cleanup "$backend"        # ensure clean slate
  start_mock "success" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "keyring: mock did not start"; _kr_cleanup "$backend"; return; fi

  # Note: NO CITT_FORCE_FILE_TOKEN here -> the real keyring path runs.
  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$AUTH" >"$out" 2>/dev/null
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ] && grep -qx "authenticated" "$out"; then
    pass "keyring: success flow via $backend -> authenticated"
  else
    fail "keyring: expected authenticated (exit $rc)"
  fi
  if grep -q "$MOCK_TOKEN" "$out"; then fail "SECRET LEAK: token in stdout (keyring path)"; else pass "keyring: token not echoed"; fi
  if [ -f "$tokdir/device_token" ]; then
    fail "keyring: token should be in keyring, NOT the fallback file"
  else
    pass "keyring: no fallback file written (token went to keyring)"
  fi

  # Second run must short-circuit purely on keyring presence (dead endpoint).
  local out2; out2="$(mktemp "$WORKROOT/out.XXXXXX")"
  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$AUTH" >"$out2" 2>/dev/null
  if [ "$?" -eq 0 ] && grep -qx "authenticated" "$out2"; then
    pass "keyring: second run short-circuits on keyring presence (no network)"
  else
    fail "keyring: second run did not short-circuit on keyring presence"
  fi

  _kr_cleanup "$backend"
}

# ---------------------------------------------------------------------------
# Test 7b (CITT-347 Finding 1): CITT_TOKEN env-override must NOT appear in a
# forced external bash -x xtrace.  Under the OLD code [ -n "${CITT_TOKEN:-}" ]
# expands the VALUE — the sentinel appears as:
#   + '[' -n citt_SENTINEL_123 ']'
# The fix: use ${CITT_TOKEN+x} (key-presence test) so the value is never
# expanded by the trace.
# ---------------------------------------------------------------------------
SENTINEL_ENV_OVERRIDE="citt_envoverride_SENTINEL_347_auth"
test_citt_token_env_not_in_xtrace() {
  local out trace rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  trace="$(mktemp "$WORKROOT/trace.XXXXXX")"

  # Run citt-auth.sh with CITT_TOKEN set and an unreachable API (we exit early
  # on the override path so network is never needed).
  CITT_TOKEN="$SENTINEL_ENV_OVERRIDE" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash -x "$AUTH" >"$out" 2>"$trace"
  rc=$?

  # Must still exit 0 and print "authenticated".
  if [ "$rc" -eq 0 ] && grep -qx "authenticated" "$out"; then
    pass "citt-token-env-xtrace: exit 0 + authenticated (functional)"
  else
    fail "citt-token-env-xtrace: expected authenticated (exit $rc)"
  fi

  # HARD INVARIANT (CITT-347 Finding 1): the sentinel value must NOT appear in
  # the forced bash -x trace — not even inside '[' ... ']'.
  if grep -q "$SENTINEL_ENV_OVERRIDE" "$trace"; then
    local hits; hits="$(grep -c "$SENTINEL_ENV_OVERRIDE" "$trace" || true)"
    fail "SECRET LEAK (CITT-347 F1): CITT_TOKEN value in forced xtrace ($hits hit(s)): $(grep "$SENTINEL_ENV_OVERRIDE" "$trace" | head -2)"
  else
    pass "citt-token-env-xtrace: CITT_TOKEN value NOT in forced bash -x trace (0 hits)"
  fi

  # HARD INVARIANT: value must not appear in stdout either.
  if grep -q "$SENTINEL_ENV_OVERRIDE" "$out"; then
    fail "SECRET LEAK (CITT-347 F1): CITT_TOKEN value in stdout"
  else
    pass "citt-token-env-xtrace: CITT_TOKEN value NOT in stdout"
  fi
}

echo "== citt-auth.sh device-flow harness =="
test_success_flow_and_secret_isolation
test_token_not_in_forced_xtrace
test_poll_transitions
test_access_denied_tier
test_already_authenticated_no_network
test_citt_token_override
test_keyring_roundtrip
test_citt_token_env_not_in_xtrace

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
