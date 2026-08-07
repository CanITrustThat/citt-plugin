#!/usr/bin/env bash
# =============================================================================
# test_citt_result.sh — TDD harness for cmd-result.sh / citt result (CITT-C2)
# =============================================================================
# Runs `citt result <scan_id>` against a local mock server
# (mock_result_server.py) via the CITT_API_OVERRIDE test seam (honored only
# under CITT_TEST_MODE=1; the production host stays hardcoded). Mirrors the
# secret-isolation invariants of test_citt_report.sh.
#
# The dispatcher does NOT route `result` yet (that glue is a separate ticket).
# So the command is invoked via a DIRECT-SOURCE runner: a child bash sources
# scripts/lib/citt-common.sh + scripts/lib/cmd-result.sh, then calls
# `citt_cmd_result "$@"`.
#
# `citt result` fetches a custom-scan result via
#   GET /api/scan/{scan_id}/result
# The result JSON goes to stdout (emit_json); a human summary to stderr.
#
# Asserts:
#   * happy path → completed result JSON on stdout, exit 0
#   * 404 → friendly "not ready yet" message on stderr, non-zero, stdout empty
#   * 403 → not-authorized message, non-zero
#   * 401 → re-auth hint, non-zero
#   * missing scan_id arg → usage + non-zero exit
#   * SECRET NON-LEAK: token NEVER in bash -x xtrace
#
# Pure bash + stdlib python3 — no venv/pytest. Run:
#     bash citt-plugin/tests/test_citt_result.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
COMMON="$PLUGIN_ROOT/scripts/lib/citt-common.sh"
CMD="$PLUGIN_ROOT/scripts/lib/cmd-result.sh"
MOCK="$HERE/mock_result_server.py"
PYTHON="${PYTHON:-python3}"

MOCK_TOKEN="citt_res_mocktoken789"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Infrastructure: temp workspace, mock lifecycle
# ---------------------------------------------------------------------------
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_result_test.XXXXXX")"
cleanup_all() { rm -rf "$WORKROOT" 2>/dev/null || true; }
trap cleanup_all EXIT

MOCK_PID=""
MOCK_BASE=""

# start_mock  $1=forced_scenario  $2=logfile  $3=optional_token_override
# When forced_scenario is empty, the mock keys behavior off the scan_id in the
# URL — so a single mock instance serves every scan-scenario at once.
start_mock() {
  local scenario="$1" logf="$2" tok="${3:-$MOCK_TOKEN}" outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_SCENARIO="$scenario" CITT_MOCK_LOG="$logf" CITT_MOCK_TOKEN="$tok" \
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

new_env_dir() {
  local d; d="$(mktemp -d "$WORKROOT/home.XXXXXX")"; printf '%s' "$d"
}

# Seed a valid 0600 token file.
seed_token() {  # $1=tokdir  $2=optional_token_value
  local tokdir="$1" val="${2:-$MOCK_TOKEN}"
  mkdir -p "$tokdir"
  ( umask 077; printf '%s' "$val" >"$tokdir/device_token" )
}

# run_result: direct-source runner. Sources the shared lib + cmd-result.sh in a
# child bash and calls citt_cmd_result "$@". Because the dispatcher does not yet
# route `result`, this is how we exercise the command in isolation. All env
# (CLAUDE_PLUGIN_DATA, CITT_TEST_MODE, CITT_API_OVERRIDE, …) is inherited from
# the caller. Extra args after the runner path are the command's argv.
#   run_result [--xtrace <tracefile>] -- <args...>
RUNNER=""
build_runner() {
  RUNNER="$(mktemp "$WORKROOT/runner.XXXXXX.sh")"
  cat >"$RUNNER" <<EOF
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "$COMMON"
# shellcheck source=/dev/null
. "$CMD"
citt_cmd_result "\$@"
EOF
  chmod +x "$RUNNER"
}

# ---------------------------------------------------------------------------
# Test 1: happy path → completed result JSON on stdout, exit 0
# ---------------------------------------------------------------------------
test_happy_path() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "happy: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" scan_ok_abc123 >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "happy: exit 0"; else fail "happy: exit $rc"; fi

  # stdout is the completed custom-scan JSON with known fields.
  if python3 -c "import json; d=json.load(open('$out')); assert d.get('scan_id')=='scan_ok_abc123'; assert d.get('package_id')=='com.foo.bar'; assert d.get('status')=='completed'; assert 'result' in d" 2>/dev/null; then
    pass "happy: completed result JSON on stdout (scan_id/package_id/status/result)"
  else
    fail "happy: stdout is not the expected completed result JSON"
  fi

  # The endpoint hit was /api/scan/{scan_id}/result
  if grep -q '"path": "/api/scan/scan_ok_abc123/result"' "$logf"; then
    pass "happy: hit /api/scan/{scan_id}/result"
  else
    fail "happy: did not hit the result endpoint"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: 404 not-ready → friendly "not ready yet" stderr, non-zero, no stdout
# ---------------------------------------------------------------------------
test_notready() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "notready: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" scan_notready_xyz >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "notready: non-zero exit"; else fail "notready: exit 0 (should fail)"; fi
  if grep -qi "not ready\|still processing\|try again" "$err"; then
    pass "notready: friendly 'not ready yet' message on stderr"
  else
    fail "notready: no 'not ready yet' message on stderr"
  fi
  local out_size; out_size="$(wc -c <"$out" 2>/dev/null || echo 0)"
  if [ "${out_size:-0}" -eq 0 ]; then pass "notready: stdout empty"; else fail "notready: unexpected stdout output"; fi
  # Raw API detail must NOT be dumped verbatim.
  if grep -q "Scan result not ready" "$out" "$err"; then
    fail "notready: raw API error body leaked"
  else
    pass "notready: raw API error body not dumped"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: 403 → not-authorized message, non-zero, no stdout
# ---------------------------------------------------------------------------
test_forbidden() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "forbidden: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" scan_forbidden_zzz >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "forbidden: non-zero exit"; else fail "forbidden: exit 0 (should fail)"; fi
  if grep -qi "not authorized" "$err"; then
    pass "forbidden: not-authorized message on stderr"
  else
    fail "forbidden: no not-authorized message on stderr"
  fi
  local out_size; out_size="$(wc -c <"$out" 2>/dev/null || echo 0)"
  if [ "${out_size:-0}" -eq 0 ]; then pass "forbidden: stdout empty"; else fail "forbidden: unexpected stdout output"; fi
  # Raw API detail must NOT be dumped verbatim.
  if grep -q "Not authorized to view this scan" "$out" "$err"; then
    fail "forbidden: raw API error body leaked"
  else
    pass "forbidden: raw API error body not dumped"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: 401 → re-auth hint, non-zero
# ---------------------------------------------------------------------------
test_unauth() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "unauth: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" scan_unauth_qqq >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "unauth: non-zero exit"; else fail "unauth: exit 0 (should fail)"; fi
  if grep -qi "auth\|authenticate\|citt auth" "$err"; then
    pass "unauth: re-auth hint on stderr"
  else
    fail "unauth: no re-auth hint on stderr"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: missing scan_id arg → usage + non-zero exit
# ---------------------------------------------------------------------------
test_missing_arg() {
  local envdir tokdir out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$RUNNER" >"$out" 2>"$err"
  rc=$?

  if [ "$rc" -ne 0 ]; then pass "missing-arg: non-zero exit"; else fail "missing-arg: exit 0 (should fail)"; fi
  if grep -qi "usage\|scan_id\|scan id" "$err"; then
    pass "missing-arg: usage hint on stderr"
  else
    fail "missing-arg: no usage hint on stderr"
  fi
  local out_size; out_size="$(wc -c <"$out" 2>/dev/null || echo 0)"
  if [ "${out_size:-0}" -eq 0 ]; then pass "missing-arg: stdout empty"; else fail "missing-arg: unexpected stdout output"; fi
}

# ---------------------------------------------------------------------------
# Test 6: SECRET NON-LEAK — token never in bash -x xtrace (happy path)
# ---------------------------------------------------------------------------
SENTINEL_TOKEN="citt_res_SENTINELSECRET999"

test_secret_non_leak() {
  local envdir tokdir logf out trace rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  seed_token "$tokdir" "$SENTINEL_TOKEN"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  trace="$(mktemp "$WORKROOT/trace.XXXXXX")"

  start_mock "" "$logf" "$SENTINEL_TOKEN"
  if [ -z "$MOCK_BASE" ]; then fail "secret: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash -x "$RUNNER" scan_ok_secret >"$out" 2>"$trace"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "secret: exit 0 (extraction intact)"; else fail "secret: exit $rc (want 0)"; fi

  if grep -q "$SENTINEL_TOKEN" "$out"; then fail "SECRET LEAK: token in stdout"; else pass "secret: token NOT in stdout"; fi
  if ! grep -q "$SENTINEL_TOKEN" "$trace" 2>/dev/null; then
    pass "secret(bash -x): token NOT in trace"
  else
    local hits; hits="$(grep -c "$SENTINEL_TOKEN" "$trace" 2>/dev/null | head -n1)"
    fail "SECRET LEAK: token appears ${hits} time(s) in bash -x trace"
  fi

  # The result JSON should still land on stdout under xtrace.
  if python3 -c "import json; d=json.load(open('$out')); assert d.get('status')=='completed'" 2>/dev/null; then
    pass "secret: completed result JSON on stdout"
  else
    fail "secret: stdout is not the completed result JSON"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "== citt result harness (CITT-C2) =="
build_runner
test_happy_path
test_notready
test_forbidden
test_unauth
test_missing_arg
test_secret_non_leak

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
