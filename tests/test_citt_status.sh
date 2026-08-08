#!/usr/bin/env bash
# =============================================================================
# test_citt_status.sh — TDD harness for cmd-status.sh
# =============================================================================
# Runs `citt status` against a local MOCK server (mock_status_server.py) via the
# test-only CITT_API_OVERRIDE seam (honored only under CITT_TEST_MODE=1).
#
# Asserts:
#   * Plain status: latest completed scan on stdout; current_scan_status flags a
#     background rescan; stderr nudges toward --scan-id.
#   * --scan-id: polls the SPECIFIC scan's live status (analyzing + current_stage);
#     the scan_id is passed through in the request query.
#   * --scan-number: passed through as ?scan_number=.
#   * Unknown --scan-id: non-zero exit, {"error":"not_found"} JSON on stdout.
#   * --scan-id + --scan-number together: usage error (exit 2), no network.
#   * Anonymous (no token): public scan resolves 200, NO Authorization header sent.
#   * Authenticated: Authorization header IS sent when a token exists.
#   * Private scan by id: 403 without token; 200 with token.
#   * Stale token on a public scan: 401 -> anonymous retry -> 200.
#   * --help: usage on stdout, exit 0, no network.
#   * Secret isolation: token NEVER in stdout, curl argv, or bash -x xtrace.
#
# Pure bash + stdlib python3. Run: bash citt-plugin/tests/test_citt_status.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
CITT="$PLUGIN_ROOT/scripts/citt"
MOCK="$HERE/mock_status_server.py"
PYTHON="${PYTHON:-python3}"

MOCK_TOKEN="citt_status_mocktoken456"
SENTINEL_TOKEN="citt_status_SENTINEL_SECRET789"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_status_test.XXXXXX")"
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

# run_status <tokdir> <out> <err> <args...>  (tokdir may be empty for anonymous)
run_status() {
  local tokdir="$1" out="$2" err="$3"; shift 3
  CITT_STATE_DIR="${tokdir:-$WORKROOT/empty_$$}" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" status "$@" >"$out" 2>"$err"
}

# ---------------------------------------------------------------------------
test_plain_shows_completed_and_flags_rescan() {
  local envdir tokdir out err logf
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock "$logf"
  [ -n "$MOCK_BASE" ] || { fail "plain: mock did not start"; return; }

  run_status "$tokdir" "$out" "$err" com.example.app
  local rc=$?
  stop_mock

  [ "$rc" -eq 0 ] && pass "plain: exit 0" || fail "plain: exit $rc (want 0)"
  if "$PYTHON" -c "import sys,json; d=json.load(open('$out')); assert d['status']=='completed' and d['overall_score']==22 and d['current_scan_status']=='analyzing'" 2>/dev/null; then
    pass "plain: completed scan + current_scan_status=analyzing"
  else
    fail "plain: unexpected JSON (got: $(head -c 200 "$out"))"
  fi
  grep -qi "scan-id\|background" "$err" && pass "plain: stderr nudges toward --scan-id" || fail "plain: no --scan-id nudge"
  # Auto-resolved the in-flight scan id into a ready-to-run poll command.
  if grep -q -- "--scan-id scan_inflight_1" "$err"; then
    pass "plain: auto-resolves in-flight scan_id into poll command"
  else
    fail "plain: no ready-to-run poll command (err: $(cat "$err"))"
  fi
}

test_scan_id_live_status() {
  local envdir tokdir out err logf
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock "$logf"
  [ -n "$MOCK_BASE" ] || { fail "scan-id: mock did not start"; return; }

  run_status "$tokdir" "$out" "$err" com.example.app --scan-id scan_inflight_1
  local rc=$?
  stop_mock

  [ "$rc" -eq 0 ] && pass "scan-id: exit 0" || fail "scan-id: exit $rc (want 0)"
  if "$PYTHON" -c "import sys,json; d=json.load(open('$out')); assert d['id']=='scan_inflight_1' and d['status']=='analyzing' and d['current_stage']=='decompiling'" 2>/dev/null; then
    pass "scan-id: live analyzing status + stage on stdout"
  else
    fail "scan-id: unexpected JSON (got: $(head -c 200 "$out"))"
  fi
  if grep -q '"scan_id": "scan_inflight_1"' "$logf"; then
    pass "scan-id: scan_id passed through in request"
  else
    fail "scan-id: scan_id not in request (log: $(cat "$logf"))"
  fi
  grep -qi "analyzing" "$err" && pass "scan-id: stderr reports analyzing" || fail "scan-id: no analyzing in stderr"
}

test_scan_number_passthrough() {
  local envdir tokdir out err logf
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock "$logf"
  [ -n "$MOCK_BASE" ] || { fail "scan-number: mock did not start"; return; }

  run_status "$tokdir" "$out" "$err" com.example.app --scan-number 3
  local rc=$?
  stop_mock
  [ "$rc" -eq 0 ] && pass "scan-number: exit 0" || fail "scan-number: exit $rc (want 0)"
  grep -q '"scan_number": "3"' "$logf" && pass "scan-number: passed through as ?scan_number=" || fail "scan-number: not in request (log: $(cat "$logf"))"
}

test_scan_id_not_found() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock
  [ -n "$MOCK_BASE" ] || { fail "notfound: mock did not start"; return; }

  run_status "$tokdir" "$out" "$err" com.example.app --scan-id nope_does_not_exist
  local rc=$?
  stop_mock
  [ "$rc" -ne 0 ] && pass "notfound: non-zero exit" || fail "notfound: exit 0 (should fail)"
  if "$PYTHON" -c "import sys,json; d=json.load(open('$out')); assert d['error']=='not_found'" 2>/dev/null; then
    pass "notfound: not_found JSON on stdout"
  else
    fail "notfound: no not_found JSON (got: $(head -c 200 "$out"))"
  fi
  grep -qi "not found" "$err" && pass "notfound: stderr reports not found" || fail "notfound: no stderr message"
}

test_both_selectors_error() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  MOCK_BASE="http://127.0.0.1:1"  # must NOT be reached
  run_status "$tokdir" "$out" "$err" com.example.app --scan-id x --scan-number 3
  local rc=$?
  [ "$rc" -eq 2 ] && pass "both-selectors: exit 2 (usage)" || fail "both-selectors: exit $rc (want 2)"
  grep -qi "not both\|scan-id OR" "$err" && pass "both-selectors: message explains" || fail "both-selectors: no explanation"
}

test_anonymous_public() {
  # No token at all — a public scan must still resolve, with NO auth header.
  local out err logf
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  start_mock "$logf"
  [ -n "$MOCK_BASE" ] || { fail "anon: mock did not start"; return; }

  run_status "" "$out" "$err" com.public.app
  local rc=$?
  stop_mock
  [ "$rc" -eq 0 ] && pass "anon: exit 0" || fail "anon: exit $rc (want 0)"
  "$PYTHON" -c "import sys,json; d=json.load(open('$out')); assert d['status']=='completed'" 2>/dev/null \
    && pass "anon: public scan JSON on stdout" || fail "anon: no scan JSON"
  # The request for com.public.app must have carried no Authorization header.
  if "$PYTHON" -c "
import json,sys
ok=True
for l in open('$logf'):
    e=json.loads(l)
    if 'com.public.app' in e['body']['path'] and e['body']['has_auth']:
        ok=False
sys.exit(0 if ok else 1)" 2>/dev/null; then
    pass "anon: no Authorization header sent"
  else
    fail "anon: Authorization header leaked on anonymous call"
  fi
}

test_authenticated_sends_header() {
  local envdir tokdir out err logf
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock "$logf"
  [ -n "$MOCK_BASE" ] || { fail "authed: mock did not start"; return; }

  run_status "$tokdir" "$out" "$err" com.example.app
  stop_mock
  if "$PYTHON" -c "
import json,sys
ok=False
for l in open('$logf'):
    e=json.loads(l)
    if e['body']['has_auth']:
        ok=True
sys.exit(0 if ok else 1)" 2>/dev/null; then
    pass "authed: Authorization header sent when token present"
  else
    fail "authed: no Authorization header despite token"
  fi
}

test_private_scan_requires_token() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  start_mock
  [ -n "$MOCK_BASE" ] || { fail "private: mock did not start"; return; }

  # Anonymous -> 403.
  run_status "" "$out" "$err" com.example.app --scan-id scan_private_9
  local rc=$?
  grep -qi "private\|denied" "$err" && pass "private: anonymous gets access-denied" || fail "private: no denial message"
  [ "$rc" -ne 0 ] && pass "private: anonymous non-zero exit" || fail "private: anonymous exit 0 (should fail)"

  # With token -> 200.
  write_token "$tokdir" "$MOCK_TOKEN"
  run_status "$tokdir" "$out" "$err" com.example.app --scan-id scan_private_9
  rc=$?
  stop_mock
  [ "$rc" -eq 0 ] && pass "private: owner token resolves 200" || fail "private: owner exit $rc (want 0)"
  "$PYTHON" -c "import sys,json; d=json.load(open('$out')); assert d['id']=='scan_private_9' and d['status']=='completed'" 2>/dev/null \
    && pass "private: owner sees the private scan" || fail "private: owner JSON wrong (got: $(head -c 200 "$out"))"
}

test_stale_token_falls_back_anonymous() {
  # A bad token yields 401; a PUBLIC scan must still resolve via anonymous retry.
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  write_token "$tokdir" "stale_bad_token_401"
  start_mock
  [ -n "$MOCK_BASE" ] || { fail "stale: mock did not start"; return; }

  run_status "$tokdir" "$out" "$err" com.example.app
  local rc=$?
  stop_mock
  [ "$rc" -eq 0 ] && pass "stale: exit 0 (anonymous fallback)" || fail "stale: exit $rc (want 0)"
  "$PYTHON" -c "import sys,json; d=json.load(open('$out')); assert d['status']=='completed'" 2>/dev/null \
    && pass "stale: public scan resolved after fallback" || fail "stale: no scan JSON after fallback"
}

test_help_no_network() {
  local out err
  out="$(mktemp "$WORKROOT/out.XXXXXX")"; err="$(mktemp "$WORKROOT/err.XXXXXX")"
  CITT_STATE_DIR="$WORKROOT/nohome" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$CITT" status --help >"$out" 2>"$err"
  local rc=$?
  [ "$rc" -eq 0 ] && pass "help: exit 0" || fail "help: exit $rc (want 0)"
  grep -qi "Usage: citt status" "$out" && pass "help: usage on stdout" || fail "help: no usage on stdout"
  grep -qi "scan-id" "$out" && pass "help: documents --scan-id" || fail "help: --scan-id not documented"
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
  bash -x "$CITT" status com.example.app --scan-id scan_inflight_1 >"$out" 2>"$err" 9>"$xtrace"
  stop_mock

  grep -q "$SENTINEL_TOKEN" "$out" 2>/dev/null && fail "SECRET LEAK: token in stdout" || pass "secret: token NOT in stdout"
  grep -q "$SENTINEL_TOKEN" "$args" 2>/dev/null && fail "SECRET LEAK: token in curl argv" || pass "secret: token NOT in curl argv"
  grep -q "$SENTINEL_TOKEN" "$xtrace" 2>/dev/null && fail "SECRET LEAK: token in xtrace" || pass "secret: token NOT in xtrace"
}

echo "== citt status harness =="
test_plain_shows_completed_and_flags_rescan
test_scan_id_live_status
test_scan_number_passthrough
test_scan_id_not_found
test_both_selectors_error
test_anonymous_public
test_authenticated_sends_header
test_private_scan_requires_token
test_stale_token_falls_back_anonymous
test_help_no_network
test_secret_isolation

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
