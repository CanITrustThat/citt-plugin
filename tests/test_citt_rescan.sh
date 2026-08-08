#!/usr/bin/env bash
# =============================================================================
# test_citt_rescan.sh — TDD harness for cmd-rescan.sh
# =============================================================================
# Runs `citt rescan` against a local MOCK server (mock_rescan_server.py) via the
# test-only CITT_API_OVERRIDE seam (honored only under CITT_TEST_MODE=1). Mirrors
# the secret-isolation structure of test_citt_mine.sh.
#
# Asserts:
#   * Happy path: 200 => RescanResponse JSON on stdout, "queued" summary on stderr
#   * 403 (not owner): non-zero exit, server detail relayed, no scan JSON on stdout
#   * 429 (quota): non-zero exit, limit message relayed
#   * 401: re-auth hint + non-zero exit
#   * No token: re-auth hint + non-zero exit
#   * --check: eligibility JSON on stdout (can_rescan), exit 0 even when false
#   * --platform ios reaches the body; bad --platform errors before any call
#   * --help prints usage, exit 0, no network
#   * Secret isolation: token NEVER in stdout, curl argv, or bash -x xtrace
#
# Pure bash + stdlib python3. Run: bash citt-plugin/tests/test_citt_rescan.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
CITT="$PLUGIN_ROOT/scripts/citt"
MOCK="$HERE/mock_rescan_server.py"
PYTHON="${PYTHON:-python3}"

MOCK_TOKEN="citt_rescan_mocktoken456"
SENTINEL_TOKEN="citt_rescan_SENTINEL_SECRET789"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_rescan_test.XXXXXX")"
cleanup_all() { rm -rf "$WORKROOT" 2>/dev/null || true; }
trap cleanup_all EXIT

MOCK_PID=""
MOCK_BASE=""

start_mock() {
  local logf="${1:-/dev/null}" tok="${2:-$MOCK_TOKEN}" outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_LOG="$logf" CITT_MOCK_TOKEN="$tok" \
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

new_env_dir() { mktemp -d "$WORKROOT/home.XXXXXX"; }

write_token() {  # $1=tokdir  $2=token
  local tokdir="$1" tok="$2"
  mkdir -p "$tokdir"
  ( umask 077; printf '%s' "$tok" >"$tokdir/device_token" )
  chmod 600 "$tokdir/device_token"
}

# run_rescan <tokdir> <out> <err> <args...>
run_rescan() {
  local tokdir="$1" out="$2" err="$3"; shift 3
  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" rescan "$@" >"$out" 2>"$err"
}

# ---------------------------------------------------------------------------
test_happy_path() {
  local envdir tokdir out err logf
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock "$logf"
  [ -n "$MOCK_BASE" ] || { fail "happy: mock did not start"; return; }

  run_rescan "$tokdir" "$out" "$err" com.example.app
  local rc=$?
  stop_mock

  [ "$rc" -eq 0 ] && pass "happy: exit 0" || fail "happy: exit $rc (want 0)"

  local body; body="$(cat "$out")"
  if printf '%s' "$body" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='queued' and d['scan_id']" 2>/dev/null; then
    pass "happy: stdout is a queued RescanResponse"
  else
    fail "happy: stdout not a queued RescanResponse (got: $(head -c 200 "$out"))"
  fi
  grep -qi "queued\|scan" "$err" && pass "happy: stderr summary present" || fail "happy: no stderr summary"
  # The rescan POST body must carry the package + is_private=false default
  if grep -q '"package_id": "com.example.app"' "$logf" && grep -q '"is_private": false' "$logf"; then
    pass "happy: POST body carries package + is_private=false"
  else
    fail "happy: POST body missing package/is_private (log: $(cat "$logf"))"
  fi
}

test_private_flag() {
  local envdir tokdir out err logf
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock "$logf"
  [ -n "$MOCK_BASE" ] || { fail "private: mock did not start"; return; }

  run_rescan "$tokdir" "$out" "$err" com.example.app --private
  stop_mock
  if grep -q '"is_private": true' "$logf"; then
    pass "private: --private sends is_private=true"
  else
    fail "private: is_private=true not in body (log: $(cat "$logf"))"
  fi
}

test_platform_ios() {
  local envdir tokdir out err logf
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock "$logf"
  [ -n "$MOCK_BASE" ] || { fail "ios: mock did not start"; return; }

  run_rescan "$tokdir" "$out" "$err" com.example.app --platform ios
  stop_mock
  grep -q '"platform": "ios"' "$logf" && pass "ios: --platform ios reaches body" || fail "ios: platform=ios not in body"
}

test_bad_platform() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  MOCK_BASE="http://127.0.0.1:1"  # must NOT be reached
  run_rescan "$tokdir" "$out" "$err" com.example.app --platform windows
  local rc=$?
  [ "$rc" -ne 0 ] && pass "bad-platform: non-zero exit" || fail "bad-platform: exit 0"
  grep -qi "platform" "$err" && pass "bad-platform: message names platform" || fail "bad-platform: no platform message"
}

test_forbidden_403() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock
  [ -n "$MOCK_BASE" ] || { fail "403: mock did not start"; return; }

  run_rescan "$tokdir" "$out" "$err" com.forbidden.app
  local rc=$?
  stop_mock
  [ "$rc" -ne 0 ] && pass "403: non-zero exit" || fail "403: exit 0 (should fail)"
  grep -qi "developer\|research\|authoriz" "$err" && pass "403: server detail relayed" || fail "403: detail not relayed"
  grep -qi '"status": "queued"' "$out" && fail "403: queued scan leaked to stdout" || pass "403: no scan JSON on stdout"
}

test_overquota_429() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock
  [ -n "$MOCK_BASE" ] || { fail "429: mock did not start"; return; }

  run_rescan "$tokdir" "$out" "$err" com.overquota.app
  local rc=$?
  stop_mock
  [ "$rc" -ne 0 ] && pass "429: non-zero exit" || fail "429: exit 0 (should fail)"
  grep -qi "limit\|upgrade" "$err" && pass "429: quota message relayed" || fail "429: no quota message"
}

test_401() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  write_token "$tokdir" "bad_token_will_401"
  start_mock
  [ -n "$MOCK_BASE" ] || { fail "401: mock did not start"; return; }

  run_rescan "$tokdir" "$out" "$err" com.example.app
  local rc=$?
  stop_mock
  [ "$rc" -ne 0 ] && pass "401: non-zero exit" || fail "401: exit 0 (should fail)"
  grep -qi "auth\|citt auth" "$err" && pass "401: re-auth hint" || fail "401: no re-auth hint"
}

test_no_token() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  MOCK_BASE="http://127.0.0.1:1"
  run_rescan "$tokdir" "$out" "$err" com.example.app
  local rc=$?
  [ "$rc" -ne 0 ] && pass "no-token: non-zero exit" || fail "no-token: exit 0 (should fail)"
  grep -qi "auth\|citt auth" "$err" && pass "no-token: re-auth hint" || fail "no-token: no re-auth hint"
}

test_check_eligibility() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock
  [ -n "$MOCK_BASE" ] || { fail "check: mock did not start"; return; }

  run_rescan "$tokdir" "$out" "$err" --check com.example.app
  local rc=$?
  stop_mock
  [ "$rc" -eq 0 ] && pass "check: exit 0" || fail "check: exit $rc (want 0)"
  if printf '%s' "$(cat "$out")" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); assert 'can_rescan' in d" 2>/dev/null; then
    pass "check: eligibility JSON on stdout"
  else
    fail "check: no eligibility JSON (got: $(head -c 200 "$out"))"
  fi
}

test_check_forbidden_exit0() {
  # --check is a probe: can_rescan=false must still exit 0 (not an error).
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock
  [ -n "$MOCK_BASE" ] || { fail "check-forbidden: mock did not start"; return; }

  run_rescan "$tokdir" "$out" "$err" --check com.forbidden.app
  local rc=$?
  stop_mock
  [ "$rc" -eq 0 ] && pass "check-forbidden: exit 0 (probe)" || fail "check-forbidden: exit $rc (want 0)"
  grep -qi "cannot rescan\|not_owner\|not eligible" "$err" && pass "check-forbidden: reason relayed" || fail "check-forbidden: reason not relayed"
}

test_help_no_network() {
  local out err
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  # No mock, unreachable override — --help must not touch the network.
  CITT_STATE_DIR="$WORKROOT/nohome" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$CITT" rescan --help >"$out" 2>"$err"
  local rc=$?
  [ "$rc" -eq 0 ] && pass "help: exit 0" || fail "help: exit $rc (want 0)"
  grep -qi "Usage: citt rescan" "$out" && pass "help: usage on stdout" || fail "help: no usage on stdout"
}

test_secret_isolation() {
  local envdir tokdir args xtrace out err logf bindir outf
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  args="$(mktemp "$WORKROOT/args.XXXXXX")"; xtrace="$(mktemp "$WORKROOT/xtrace.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  write_token "$tokdir" "$SENTINEL_TOKEN"

  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_LOG="$logf" CITT_MOCK_TOKEN="$SENTINEL_TOKEN" \
    "$PYTHON" "$MOCK" >"$outf" 2>/dev/null &
  MOCK_PID=$!
  local tries=0; MOCK_BASE=""
  while [ $tries -lt 100 ]; do
    MOCK_BASE="$(head -n1 "$outf" 2>/dev/null || true)"
    [ -n "$MOCK_BASE" ] && break
    sleep 0.05; tries=$((tries + 1))
  done
  [ -n "$MOCK_BASE" ] || { fail "isolation: mock did not start"; stop_mock; return; }

  bindir="$envdir/bin"; mkdir -p "$bindir"
  cat >"$bindir/curl" <<'CURLEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${_CITT_ARGLOG}"
exec /usr/bin/curl "$@"
CURLEOF
  chmod +x "$bindir/curl"

  _CITT_ARGLOG="$args" \
  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  PATH="$bindir:$PATH" \
  BASH_XTRACEFD=9 \
  bash -x "$CITT" rescan com.example.app >"$out" 2>"$err" 9>"$xtrace"
  stop_mock

  grep -q "$SENTINEL_TOKEN" "$out" 2>/dev/null && fail "SECRET LEAK: token in stdout" || pass "secret: token NOT in stdout"
  grep -q "$SENTINEL_TOKEN" "$args" 2>/dev/null && fail "SECRET LEAK: token in curl argv" || pass "secret: token NOT in curl argv"
  grep -q "$SENTINEL_TOKEN" "$xtrace" 2>/dev/null && fail "SECRET LEAK: token in xtrace" || pass "secret: token NOT in xtrace"
}

echo "== citt rescan harness =="
test_happy_path
test_private_flag
test_platform_ios
test_bad_platform
test_forbidden_403
test_overquota_429
test_401
test_no_token
test_check_eligibility
test_check_forbidden_exit0
test_help_no_network
test_secret_isolation

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
