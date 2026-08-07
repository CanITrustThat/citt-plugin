#!/usr/bin/env bash
# =============================================================================
# test_citt_report.sh — TDD harness for cmd-report.sh / citt report (CITT-336)
# =============================================================================
# Runs `citt report` against a local mock server (mock_report_server.py) via
# the CITT_API_OVERRIDE test seam (honored only under CITT_TEST_MODE=1; the
# production host stays hardcoded). Mirrors the secret-isolation invariants
# of test_citt_auth.sh and test_citt_submit.sh.
#
# `citt report` serves the OWNER/RESEARCHER detailed (full) report via
#   GET /reports/{pkg}.md?report_type=detailed[&scan_id=…][&platform=…]
# The report (markdown) goes to stdout; a human summary to stderr.
#
# Asserts:
#   * pkg → detailed markdown report on stdout; summary on stderr
#   * --scan <id> forwards scan_id in the query string
#   * --platform forwards the platform query param
#   * No-leak on non-owner: 403 → clean denial, NO report bytes on stdout
#   * Locked report: 403 unlock_required → clean "locked" message, no bytes
#   * 404 (no completed scan) → clean informative message + non-zero
#   * Custom-scan fallback: detailed 404 + --scan → /api/scan/{id}/result JSON
#   * Bare scan_id as main arg → rejected with a hint (package-keyed endpoint)
#   * Missing token → re-auth hint + non-zero exit
#   * SECRET ISOLATION: token NEVER in stdout / curl argv / bash -x xtrace
#   * FORCED XTRACE test (bash -x 2>trace): token still absent
#   * no arg → usage + non-zero exit
#
# Pure bash + stdlib python3 — no venv/pytest. Run:
#     bash citt-plugin/tests/test_citt_report.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
CITT="$PLUGIN_ROOT/scripts/citt"
MOCK="$HERE/mock_report_server.py"
PYTHON="${PYTHON:-python3}"

MOCK_TOKEN="citt_rpt_mocktoken789"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Infrastructure: temp workspace, mock lifecycle
# ---------------------------------------------------------------------------
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_report_test.XXXXXX")"
cleanup_all() { rm -rf "$WORKROOT" 2>/dev/null || true; }
trap cleanup_all EXIT

MOCK_PID=""
MOCK_BASE=""

# start_mock  [$1=forced_scenario]  $2=logfile  $3=optional_token_override
# When forced_scenario is empty, the mock keys behavior off the package_id in
# the URL — so a single mock instance serves every package-scenario at once.
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

# ---------------------------------------------------------------------------
# Test 1: pkg → detailed markdown report on stdout; summary on stderr
# ---------------------------------------------------------------------------
test_pkg_detailed_report() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "pkg-detailed: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  "$CITT" report com.owner.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "pkg-detailed: exit 0"; else fail "pkg-detailed: exit $rc"; fi

  # stdout is the markdown detailed report
  if grep -q "Detailed Security & Privacy Report" "$out" && grep -q "## Findings" "$out"; then
    pass "pkg-detailed: markdown detailed report on stdout"
  else
    fail "pkg-detailed: stdout is not the detailed markdown report"
  fi

  # The endpoint hit was /reports/{pkg}.md with report_type=detailed
  if grep -q '"path": "/reports/com.owner.app.md"' "$logf" && grep -q 'report_type=detailed' "$logf"; then
    pass "pkg-detailed: hit /reports/{pkg}.md?report_type=detailed"
  else
    fail "pkg-detailed: did not hit the detailed reports endpoint"
  fi

  # human summary on stderr
  if grep -qi "report\|detailed\|com.owner.app" "$err"; then
    pass "pkg-detailed: human summary on stderr"
  else
    fail "pkg-detailed: no human summary on stderr"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: --scan <id> forwards scan_id in the query string
# ---------------------------------------------------------------------------
test_scan_flag() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "scan-flag: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  "$CITT" report com.owner.app --scan scan_owner123 >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "scan-flag: exit 0"; else fail "scan-flag: exit $rc"; fi
  if grep -q 'scan_id=scan_owner123' "$logf"; then
    pass "scan-flag: scan_id forwarded in query string"
  else
    fail "scan-flag: scan_id not forwarded"
  fi
  # The mock echoes the scan_id into the markdown when supplied.
  if grep -q 'scan_id: scan_owner123' "$out"; then
    pass "scan-flag: server received scan_id (echoed in report)"
  else
    fail "scan-flag: scan_id not received by server"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: --platform forwards the platform query param
# ---------------------------------------------------------------------------
test_platform_flag() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "platform-flag: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  "$CITT" report com.platform.app --platform android >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "platform-flag: exit 0"; else fail "platform-flag: exit $rc"; fi
  if grep -q 'platform=android' "$logf"; then
    pass "platform-flag: platform forwarded in query string"
  else
    fail "platform-flag: platform not forwarded"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: no-leak on non-owner (403 not-authorized) → clean denial, no bytes
# ---------------------------------------------------------------------------
test_noleak_nonowner() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "noleak: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  "$CITT" report com.other.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "noleak: non-zero exit on forbidden ($rc)"; else fail "noleak: exit 0 (should fail)"; fi

  local out_size; out_size="$(wc -c <"$out" 2>/dev/null || echo 0)"
  if [ "${out_size:-0}" -eq 0 ]; then
    pass "noleak: stdout empty (no report bytes leaked)"
  else
    fail "noleak: report bytes present on stdout for non-owner"
  fi

  if grep -qi "access denied\|not authorized\|must own\|ownership\|admin" "$err"; then
    pass "noleak: clean denial on stderr"
  else
    fail "noleak: no clean denial on stderr"
  fi
  # Raw API detail must NOT be dumped verbatim.
  if grep -q "Not authorized to view detailed report" "$out" "$err"; then
    fail "noleak: raw API error body leaked"
  else
    pass "noleak: raw API error body not dumped"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: locked report (403 unlock_required) → clean "locked" message
# ---------------------------------------------------------------------------
test_locked_report() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "locked: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  "$CITT" report com.locked.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "locked: non-zero exit"; else fail "locked: exit 0 (should fail)"; fi
  if grep -qi "locked\|unlock" "$err"; then
    pass "locked: clean 'locked/unlock' message on stderr"
  else
    fail "locked: no locked/unlock message on stderr"
  fi
  local out_size; out_size="$(wc -c <"$out" 2>/dev/null || echo 0)"
  if [ "${out_size:-0}" -eq 0 ]; then pass "locked: stdout empty"; else fail "locked: unexpected stdout output"; fi
}

# ---------------------------------------------------------------------------
# Test 6: 404 (no completed scan / app not found) → clean message + non-zero
# ---------------------------------------------------------------------------
test_notfound() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "notfound: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  "$CITT" report com.missing.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "notfound: non-zero exit"; else fail "notfound: exit 0 (should fail)"; fi
  if grep -qi "no completed report\|not found\|no report" "$err"; then pass "notfound: clean message on stderr"; else fail "notfound: no informative message on stderr"; fi
  local out_size; out_size="$(wc -c <"$out" 2>/dev/null || echo 0)"
  if [ "${out_size:-0}" -eq 0 ]; then pass "notfound: stdout empty"; else fail "notfound: unexpected stdout output"; fi
}

# ---------------------------------------------------------------------------
# Test 7: custom-scan fallback — detailed 404 + --scan → /result JSON
# ---------------------------------------------------------------------------
test_custom_fallback() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "custom-fallback: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  "$CITT" report com.custom.app --scan scan_custom999 >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "custom-fallback: exit 0"; else fail "custom-fallback: exit $rc"; fi
  # Detailed endpoint 404'd, then /api/scan/{id}/result was tried.
  if grep -q '"kind": "result_request"' "$logf"; then
    pass "custom-fallback: fell back to /api/scan/{id}/result"
  else
    fail "custom-fallback: did not fall back to /api/scan/{id}/result"
  fi
  # stdout is the custom-scan JSON.
  if python3 -c "import json; d=json.load(open('$out')); assert d.get('scan_id')=='scan_custom999' and 'result' in d" 2>/dev/null; then
    pass "custom-fallback: custom-scan JSON on stdout"
  else
    fail "custom-fallback: stdout is not the custom-scan JSON"
  fi
}

# ---------------------------------------------------------------------------
# Test 8: bare scan_id as main arg → rejected with a hint (package-keyed)
# ---------------------------------------------------------------------------
test_bare_scanid_rejected() {
  local envdir tokdir out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  # A UUID-format arg (no dot) → treated as scan_id → rejected before any network.
  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  "$CITT" report 00000000-0000-0000-0000-000000000000 >"$out" 2>"$err"
  rc=$?

  if [ "$rc" -ne 0 ]; then pass "bare-scanid: non-zero exit"; else fail "bare-scanid: exit 0 (should fail)"; fi
  if grep -qi "scan_id\|--scan\|package" "$err"; then
    pass "bare-scanid: hint to use <package_id> --scan"
  else
    fail "bare-scanid: no hint about the package-keyed form"
  fi
  local out_size; out_size="$(wc -c <"$out" 2>/dev/null || echo 0)"
  if [ "${out_size:-0}" -eq 0 ]; then pass "bare-scanid: stdout empty"; else fail "bare-scanid: unexpected stdout output"; fi
}

# ---------------------------------------------------------------------------
# Test 9: missing token → re-auth hint + non-zero exit (no network)
# ---------------------------------------------------------------------------
test_missing_token() {
  local envdir tokdir out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  "$CITT" report com.any.app >"$out" 2>"$err"
  rc=$?

  if [ "$rc" -ne 0 ]; then pass "missing-token: non-zero exit"; else fail "missing-token: exit 0 (should fail)"; fi
  if grep -qi "auth\|authenticate\|citt auth" "$err"; then
    pass "missing-token: re-auth hint on stderr"
  else
    fail "missing-token: no re-auth hint on stderr"
  fi
}

# ---------------------------------------------------------------------------
# Test 10: SECRET ISOLATION — token never in stdout / curl argv / bash -x xtrace
# ---------------------------------------------------------------------------
test_secret_isolation() {
  local envdir tokdir logf out err args xtrace rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"
  args="$(mktemp "$WORKROOT/args.XXXXXX")"
  xtrace="$(mktemp "$WORKROOT/xtrace.XXXXXX")"

  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "secret: mock did not start"; return; fi

  # Wrap curl to log every argv — proves token never passed as argument.
  local bindir="$envdir/bin"
  mkdir -p "$bindir"
  cat >"$bindir/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$args"
exec /usr/bin/curl "\$@"
EOF
  chmod +x "$bindir/curl"

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  PATH="$bindir:$PATH" \
  BASH_XTRACEFD=9 \
  bash -x "$CITT" report com.owner.app >"$out" 2>"$err" 9>"$xtrace"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "secret: exit 0"; else fail "secret: exit $rc (want 0)"; fi

  if grep -q "$MOCK_TOKEN" "$out"; then fail "SECRET LEAK: token in stdout"; else pass "secret: token NOT in stdout"; fi
  if grep -q "$MOCK_TOKEN" "$args"; then fail "SECRET LEAK: token in curl argv"; else pass "secret: token NOT in curl argv"; fi
  if grep -q "$MOCK_TOKEN" "$xtrace"; then fail "SECRET LEAK: token in set -x trace"; else pass "secret: token NOT in set -x trace"; fi
  if grep -qi "Authorization: Bearer" "$args"; then fail "SECRET LEAK: Authorization header on curl argv"; else pass "secret: no Authorization header on curl argv"; fi
}

# ---------------------------------------------------------------------------
# Test 11: FORCED XTRACE — bash -x 2>trace; token must NOT appear in trace
# ---------------------------------------------------------------------------
SENTINEL_TOKEN="citt_rpt_SENTINELSECRET999"

test_token_not_in_forced_xtrace() {
  local envdir tokdir logf out trace rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  seed_token "$tokdir" "$SENTINEL_TOKEN"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  trace="$(mktemp "$WORKROOT/trace.XXXXXX")"

  start_mock "" "$logf" "$SENTINEL_TOKEN"
  if [ -z "$MOCK_BASE" ]; then fail "xtrace: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash -x "$CITT" report com.owner.app >"$out" 2>"$trace"
  rc=$?
  stop_mock

  if ! grep -q "$SENTINEL_TOKEN" "$trace" 2>/dev/null; then
    pass "xtrace(forced -x): token NOT in trace"
  else
    local hits; hits="$(grep -c "$SENTINEL_TOKEN" "$trace" 2>/dev/null | head -n1)"
    fail "SECRET LEAK: token appears ${hits} time(s) in forced bash -x trace"
  fi

  if [ "$rc" -eq 0 ]; then pass "xtrace: exit 0 (extraction intact)"; else fail "xtrace: expected exit 0 (exit $rc)"; fi
  if grep -q "Detailed Security & Privacy Report" "$out"; then
    pass "xtrace: detailed report on stdout"
  else
    fail "xtrace: stdout is not the detailed report"
  fi
}

# ---------------------------------------------------------------------------
# Test 12: no arg → usage + non-zero exit
# ---------------------------------------------------------------------------
test_no_arg() {
  local envdir tokdir out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  "$CITT" report >"$out" 2>"$err"
  rc=$?

  if [ "$rc" -ne 0 ]; then pass "no-arg: non-zero exit"; else fail "no-arg: exit 0 (should fail)"; fi
  if grep -qi "usage\|package_id\|scan" "$err"; then
    pass "no-arg: usage hint on stderr"
  else
    fail "no-arg: no usage hint on stderr"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "== citt report harness (CITT-336) =="
test_pkg_detailed_report
test_scan_flag
test_platform_flag
test_noleak_nonowner
test_locked_report
test_notfound
test_custom_fallback
test_bare_scanid_rejected
test_missing_token
test_secret_isolation
test_token_not_in_forced_xtrace
test_no_arg

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
