#!/usr/bin/env bash
# =============================================================================
# test_citt_mine.sh — TDD harness for cmd-mine.sh (CITT-337)
# =============================================================================
# Runs `citt mine` against a local MOCK server (mock_mine_server.py) via the
# test-only CITT_API_OVERRIDE seam (honored only under CITT_TEST_MODE=1; the
# production host stays hardcoded). Mirrors the secret-isolation structure of
# test_citt_auth.sh.
#
# Asserts:
#   * Happy path: JSON array on stdout, human summary on stderr
#   * Each entry has package_id + scan_id (or null) + score + status
#   * Empty state: user has no submitted apps => JSON [] + graceful message
#   * 401: re-authenticate hint + non-zero exit, no app list
#   * No token: re-auth hint + non-zero exit
#   * Secret isolation: token NEVER in stdout, curl argv, or bash -x xtrace
#   * Gap notice: stderr mentions proxy/limitation (no dedicated owned-apps endpoint)
#
# Pure bash + stdlib python3 — no venv/pytest needed. Run:
#     bash citt-plugin/tests/test_citt_mine.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
CITT="$PLUGIN_ROOT/scripts/citt"
MOCK="$HERE/mock_mine_server.py"
PYTHON="${PYTHON:-python3}"

MOCK_TOKEN="citt_mine_mocktoken456"
SENTINEL_TOKEN="citt_mine_SENTINEL_SECRET789"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_mine_test.XXXXXX")"
cleanup_all() { rm -rf "$WORKROOT" 2>/dev/null || true; }
trap cleanup_all EXIT

MOCK_PID=""
MOCK_BASE=""

# start_mock [APPS_JSON] [LOGFILE]
start_mock() {
  local appsj="${1:-}" logf="${2:-/dev/null}" outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  local env_extras=""
  if [ -n "$appsj" ]; then
    CITT_MOCK_APPS="$appsj" CITT_MOCK_LOG="$logf" CITT_MOCK_TOKEN="$MOCK_TOKEN" \
      "$PYTHON" "$MOCK" >"$outf" 2>/dev/null &
  else
    CITT_MOCK_LOG="$logf" CITT_MOCK_TOKEN="$MOCK_TOKEN" \
      "$PYTHON" "$MOCK" >"$outf" 2>/dev/null &
  fi
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

# Write a 0600 token file in an isolated home dir, return the tokdir path.
new_env_dir() {
  local d
  d="$(mktemp -d "$WORKROOT/home.XXXXXX")"
  printf '%s' "$d"
}

write_token() {  # $1=tokdir  $2=token_value
  local tokdir="$1" tok="$2"
  mkdir -p "$tokdir"
  ( umask 077; printf '%s' "$tok" >"$tokdir/device_token" )
  chmod 600 "$tokdir/device_token"
}

# ---------------------------------------------------------------------------
# Test 1: happy path — two apps returned, JSON array on stdout
# ---------------------------------------------------------------------------
test_happy_path() {
  local envdir tokdir out err logf
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"

  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock "" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "happy: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" mine >"$out" 2>"$err"
  local rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "happy: exit 0"; else fail "happy: exit $rc (want 0)"; fi

  # stdout must be a JSON array
  local out_content
  out_content="$(cat "$out")"
  if printf '%s' "$out_content" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d,list)" 2>/dev/null; then
    pass "happy: stdout is a JSON array"
  else
    fail "happy: stdout is not a JSON array (got: $(head -c 200 "$out"))"
  fi

  # Array must have 2 entries (default mock data)
  local count
  count="$( printf '%s' "$out_content" | "$PYTHON" -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo -1)"
  if [ "$count" -eq 2 ]; then
    pass "happy: JSON array has 2 entries"
  else
    fail "happy: JSON array has $count entries (want 2)"
  fi

  # Each entry must have package_id, status
  local has_pkg has_status
  has_pkg="$( printf '%s' "$out_content" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); print(all('package_id' in e for e in d))" 2>/dev/null || echo False)"
  has_status="$( printf '%s' "$out_content" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); print(all('status' in e for e in d))" 2>/dev/null || echo False)"
  if [ "$has_pkg" = "True" ]; then pass "happy: all entries have package_id"; else fail "happy: some entries missing package_id"; fi
  if [ "$has_status" = "True" ]; then pass "happy: all entries have status"; else fail "happy: some entries missing status"; fi

  # Each entry must have an overall_score field (may be null for in-progress)
  local has_score
  has_score="$( printf '%s' "$out_content" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); print(all('overall_score' in e for e in d))" 2>/dev/null || echo False)"
  if [ "$has_score" = "True" ]; then pass "happy: all entries have overall_score"; else fail "happy: some entries missing overall_score"; fi

  # Each entry must have a scan_id field (for `citt report` pointer)
  local has_scanid
  has_scanid="$( printf '%s' "$out_content" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); print(all('scan_id' in e for e in d))" 2>/dev/null || echo False)"
  if [ "$has_scanid" = "True" ]; then pass "happy: all entries have scan_id"; else fail "happy: some entries missing scan_id"; fi

  # stderr must have a human summary (mentions count)
  if grep -qi "app\|mine\|owned\|submitted\|found\|total" "$err"; then
    pass "happy: stderr has human summary"
  else
    fail "happy: no human summary on stderr"
  fi

  # stderr should acknowledge the proxy limitation (no dedicated /api/me/apps)
  if grep -qi "submitted\|proxy\|submission\|note\|claim\|limit" "$err"; then
    pass "happy: stderr notes proxy limitation"
  else
    fail "happy: stderr does not note proxy limitation"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: empty state — user has no submitted apps
# ---------------------------------------------------------------------------
test_empty_state() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock '[]'
  if [ -z "$MOCK_BASE" ]; then fail "empty: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" mine >"$out" 2>"$err"
  local rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "empty: exit 0"; else fail "empty: exit $rc (want 0)"; fi

  local out_content
  out_content="$(cat "$out")"
  if printf '%s' "$out_content" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); assert d==[]" 2>/dev/null; then
    pass "empty: stdout is empty JSON array []"
  else
    fail "empty: stdout is not [] (got: $(head -c 200 "$out"))"
  fi

  # stderr should acknowledge zero apps gracefully
  if grep -qi "no\|none\|zero\|0 app\|empty" "$err"; then
    pass "empty: stderr acknowledges no apps"
  else
    fail "empty: no empty-state message on stderr"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: 401 — bad/expired token => re-auth hint + non-zero exit
# ---------------------------------------------------------------------------
test_401_reauth() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  # Plant a bad token — mock only accepts MOCK_TOKEN
  write_token "$tokdir" "bad_token_will_401"
  start_mock
  if [ -z "$MOCK_BASE" ]; then fail "401: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" mine >"$out" 2>"$err"
  local rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "401: non-zero exit ($rc)"; else fail "401: exit 0 (should fail)"; fi
  if grep -qi "auth\|login\|citt auth" "$err"; then
    pass "401: re-auth hint on stderr"
  else
    fail "401: no re-auth hint on stderr"
  fi
  # stdout must NOT be a JSON list of apps
  if grep -qi "package_id\|overall_score" "$out"; then
    fail "401: app data leaked to stdout"
  else
    pass "401: no app data on stdout"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: no token stored => re-auth hint + non-zero exit
# ---------------------------------------------------------------------------
test_no_token() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  # Do NOT write a token file
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$CITT" mine >"$out" 2>"$err"
  local rc=$?

  if [ "$rc" -ne 0 ]; then pass "no-token: non-zero exit ($rc)"; else fail "no-token: exit 0 (should fail)"; fi
  if grep -qi "auth\|login\|citt auth" "$err"; then
    pass "no-token: re-auth hint on stderr"
  else
    fail "no-token: no re-auth hint on stderr"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: secret isolation — token NEVER in stdout, curl argv, or xtrace
# ---------------------------------------------------------------------------
test_secret_isolation() {
  local envdir tokdir args xtrace out err logf
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  args="$(mktemp "$WORKROOT/args.XXXXXX")"
  xtrace="$(mktemp "$WORKROOT/xtrace.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"

  write_token "$tokdir" "$SENTINEL_TOKEN"

  # Start mock with SENTINEL token
  local outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_LOG="$logf" CITT_MOCK_TOKEN="$SENTINEL_TOKEN" \
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
  if [ -z "$MOCK_BASE" ]; then fail "isolation: mock did not start"; stop_mock; return; fi

  # Wrap curl to capture argv
  local bindir="$envdir/bin"
  mkdir -p "$bindir"
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
  bash -x "$CITT" mine >"$out" 2>"$err" 9>"$xtrace"
  stop_mock

  # HARD: token never in stdout
  if grep -q "$SENTINEL_TOKEN" "$out" 2>/dev/null; then
    fail "SECRET LEAK: token in stdout"
  else
    pass "secret: token NOT in stdout"
  fi
  # HARD: token never in any curl argv
  if grep -q "$SENTINEL_TOKEN" "$args" 2>/dev/null; then
    fail "SECRET LEAK: token in curl argv"
  else
    pass "secret: token NOT in curl argv"
  fi
  # HARD: token never in xtrace
  if grep -q "$SENTINEL_TOKEN" "$xtrace" 2>/dev/null; then
    fail "SECRET LEAK: token in set -x xtrace"
  else
    pass "secret: token NOT in set -x xtrace"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: forced external xtrace (bash -x ... 2>trace) — token must NOT appear
# ---------------------------------------------------------------------------
test_forced_xtrace_isolation() {
  local envdir tokdir trace out logf
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  trace="$(mktemp "$WORKROOT/trace.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"

  write_token "$tokdir" "$SENTINEL_TOKEN"

  local outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_LOG="$logf" CITT_MOCK_TOKEN="$SENTINEL_TOKEN" \
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
  if [ -z "$MOCK_BASE" ]; then fail "forced-xtrace: mock did not start"; stop_mock; return; fi

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash -x "$CITT" mine >"$out" 2>"$trace"
  stop_mock

  if ! grep -q "$SENTINEL_TOKEN" "$trace" 2>/dev/null; then
    pass "forced-xtrace: token NOT in forced bash -x trace"
  else
    local hits
    hits="$(grep -c "$SENTINEL_TOKEN" "$trace" 2>/dev/null || echo "?")"
    fail "SECRET LEAK: token appears $hits time(s) in forced bash -x trace"
  fi
}

# ---------------------------------------------------------------------------
# Test 7: JSON structure — each entry has the citt report pointer fields
# ---------------------------------------------------------------------------
test_json_structure() {
  local envdir tokdir out err
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  write_token "$tokdir" "$MOCK_TOKEN"
  start_mock
  if [ -z "$MOCK_BASE" ]; then fail "structure: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" mine >"$out" 2>"$err"
  local rc=$?
  stop_mock

  [ "$rc" -eq 0 ] || { fail "structure: exit $rc"; return; }

  # Validate that each item has the fields Claude needs to act on it
  local check_result
  check_result="$( "$PYTHON" - "$out" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
assert isinstance(data, list), f"Not a list: {type(data)}"
required = {"package_id", "status", "overall_score", "scan_id"}
missing = []
for i, entry in enumerate(data):
    for field in required:
        if field not in entry:
            missing.append(f"entry[{i}] missing {field!r}")
if missing:
    print("MISSING: " + "; ".join(missing))
else:
    print("OK")
PYEOF
    )"
  if [ "$check_result" = "OK" ]; then
    pass "structure: all required fields present in each entry"
  else
    fail "structure: $check_result"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "== citt mine harness (CITT-337) =="
test_happy_path
test_empty_state
test_401_reauth
test_no_token
test_secret_isolation
test_forced_xtrace_isolation
test_json_structure

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
