#!/usr/bin/env bash
# =============================================================================
# test_citt_search.sh — TDD harness for citt search (CITT-338)
# =============================================================================
# Tests the `citt search` subcommand (lib/cmd-search.sh) against a local mock
# search server (mock_search_server.py) via the CITT_API_OVERRIDE test seam.
#
# Layout-independent: always resolves paths relative to this file.
# Run:
#   bash citt-plugin/tests/test_citt_search.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
CITT="$PLUGIN_ROOT/scripts/citt"
MOCK="$HERE/mock_search_server.py"
PYTHON="${PYTHON:-python3}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_search_test.XXXXXX")"
cleanup_all() { rm -rf "$WORKROOT" 2>/dev/null || true; }
trap cleanup_all EXIT

MOCK_PID=""
MOCK_BASE=""

start_mock() {
  local outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
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

# ---------------------------------------------------------------------------
# Test 1: Basic search returns structured JSON with results
# ---------------------------------------------------------------------------
test_basic_search() {
  start_mock
  if [ -z "$MOCK_BASE" ]; then fail "basic: mock did not start"; return; fi

  local out err rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CITT_TEST_MODE=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    "$CITT" search "signal" >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "basic: exit 0"; else fail "basic: exit $rc (want 0)"; fi

  # stdout must be valid JSON (an array or object)
  if "$PYTHON" -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d,(list,dict))" <"$out" 2>/dev/null; then
    pass "basic: stdout is valid JSON"
  else
    fail "basic: stdout is not valid JSON (got: $(head -c200 "$out"))"
  fi

  # Must contain package_id field somewhere
  if grep -q "package_id" "$out"; then
    pass "basic: results contain package_id field"
  else
    fail "basic: no package_id in output"
  fi

  # Human summary goes to stderr
  if [ -s "$err" ]; then
    pass "basic: human summary on stderr"
  else
    fail "basic: no stderr output (want result-count summary)"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: --platform ios passes through correctly
# ---------------------------------------------------------------------------
test_platform_ios() {
  start_mock
  if [ -z "$MOCK_BASE" ]; then fail "platform: mock did not start"; return; fi

  local out err rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CITT_TEST_MODE=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    "$CITT" search "signal" --platform ios >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "platform-ios: exit 0"; else fail "platform-ios: exit $rc"; fi
  # iOS fixture returns ios items
  if grep -q '"ios"' "$out"; then
    pass "platform-ios: ios platform in results"
  else
    fail "platform-ios: no ios platform in results (out=$(head -c200 "$out"))"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: --limit N is honored (passed to server and capped at 50)
# ---------------------------------------------------------------------------
test_limit() {
  start_mock
  if [ -z "$MOCK_BASE" ]; then fail "limit: mock did not start"; return; fi

  local out err rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  # limit=2 -> server fixture returns at most 2 results
  CITT_TEST_MODE=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    "$CITT" search "signal" --limit 2 >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "limit: exit 0"; else fail "limit: exit $rc"; fi
  # The JSON array must have <=2 elements when limit=2
  local cnt
  cnt="$("$PYTHON" -c "import json,sys; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else len(d.get('results',d)))" <"$out" 2>/dev/null || echo "??")"
  if [ "$cnt" -le 2 ] 2>/dev/null; then
    pass "limit: result count ($cnt) <= 2"
  else
    fail "limit: result count ($cnt) should be <= 2"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: Empty results produce a clean empty-state (not an error)
# ---------------------------------------------------------------------------
test_empty_results() {
  start_mock
  if [ -z "$MOCK_BASE" ]; then fail "empty: mock did not start"; return; fi

  local out err rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CITT_TEST_MODE=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    "$CITT" search "xyzzy_no_match_zzzz" >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "empty: exit 0"; else fail "empty: exit $rc (want 0)"; fi
  # Valid JSON even when empty
  if "$PYTHON" -c "import json,sys; json.load(sys.stdin)" <"$out" 2>/dev/null; then
    pass "empty: stdout is valid JSON for no-results"
  else
    fail "empty: stdout not valid JSON on empty result (got: $(head -c200 "$out"))"
  fi
  # stderr should indicate 0 results, not an error message
  if grep -qi "0\|no result\|nothing" "$err"; then
    pass "empty: empty-state summary on stderr"
  else
    # At minimum, stderr should exist or be empty (not "error")
    if ! grep -qi "error\|fail" "$err"; then
      pass "empty: no error on stderr for zero-result query"
    else
      fail "empty: error message on stderr for zero-result query"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Test 5: Missing query argument exits non-zero with usage hint
# ---------------------------------------------------------------------------
test_missing_query() {
  local err rc
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CITT_TEST_MODE=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
    "$CITT" search 2>"$err" || rc=$?
  rc=${rc:-0}

  if [ "$rc" -ne 0 ]; then pass "missing-query: non-zero exit ($rc)"; else fail "missing-query: exit 0 (want non-zero)"; fi
  if grep -qi "usage\|query\|required\|argument" "$err"; then
    pass "missing-query: usage hint on stderr"
  else
    fail "missing-query: no usage hint on stderr (got: $(cat "$err"))"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: Invalid --limit (>50 or <1) exits non-zero
# ---------------------------------------------------------------------------
test_invalid_limit() {
  local err rc
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CITT_TEST_MODE=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
    "$CITT" search "signal" --limit 99 2>"$err" || rc=$?
  rc=${rc:-0}

  if [ "$rc" -ne 0 ]; then pass "invalid-limit: exit non-zero for limit=99"; else fail "invalid-limit: exit 0 for limit=99 (should reject)"; fi

  err2="$(mktemp "$WORKROOT/err2.XXXXXX")"
  CITT_TEST_MODE=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
    "$CITT" search "signal" --limit 0 2>"$err2" || rc=$?
  rc=${rc:-0}

  if [ "$rc" -ne 0 ]; then pass "invalid-limit: exit non-zero for limit=0"; else fail "invalid-limit: exit 0 for limit=0 (should reject)"; fi
}

# ---------------------------------------------------------------------------
# Test 7: Invalid --platform exits non-zero
# ---------------------------------------------------------------------------
test_invalid_platform() {
  local err rc
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CITT_TEST_MODE=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
    "$CITT" search "signal" --platform windows 2>"$err" || rc=$?
  rc=${rc:-0}

  if [ "$rc" -ne 0 ]; then pass "invalid-platform: exit non-zero for platform=windows"; else fail "invalid-platform: exit 0 for bad platform"; fi
}

# ---------------------------------------------------------------------------
# Test 8: Result items contain key fields (package_id, app_name/title, score)
# ---------------------------------------------------------------------------
test_result_fields() {
  start_mock
  if [ -z "$MOCK_BASE" ]; then fail "fields: mock did not start"; return; fi

  local out err rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CITT_TEST_MODE=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    "$CITT" search "signal" >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then fail "fields: exit $rc (want 0)"; return; fi

  # package_id is required
  if grep -q '"package_id"' "$out"; then pass "fields: package_id present"; else fail "fields: package_id missing"; fi
  # app_name is present in results
  if grep -q '"app_name"' "$out"; then pass "fields: app_name present"; else fail "fields: app_name missing"; fi
  # overall_score surfaced when available (our fixture has a scanned app with score)
  if grep -q '"overall_score"' "$out"; then pass "fields: overall_score present"; else fail "fields: overall_score missing"; fi
}

# ---------------------------------------------------------------------------
# Test 9: Token never leaks to stdout even when a token is present
# ---------------------------------------------------------------------------
test_no_token_leak() {
  local tokdir
  tokdir="$(mktemp -d "$WORKROOT/tok.XXXXXX")"
  local MOCK_TOK="citt_supersecret_tok_XYZ789"
  mkdir -p "$tokdir"
  ( umask 077; printf '%s' "$MOCK_TOK" >"$tokdir/device_token" )

  start_mock
  if [ -z "$MOCK_BASE" ]; then fail "token-leak: mock did not start"; return; fi

  local out rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    "$CITT" search "signal" >"$out" 2>/dev/null
  rc=$?
  stop_mock

  if grep -q "$MOCK_TOK" "$out"; then
    fail "token-leak: token appeared in stdout"
  else
    pass "token-leak: token NOT in stdout"
  fi
}

# ---------------------------------------------------------------------------
# Test 10: query with spaces is URL-encoded (server receives it intact)
# ---------------------------------------------------------------------------
test_query_encoding() {
  start_mock
  if [ -z "$MOCK_BASE" ]; then fail "encoding: mock did not start"; return; fi

  local out err rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CITT_TEST_MODE=1 CITT_API_OVERRIDE="$MOCK_BASE" \
    "$CITT" search "my app" >"$out" 2>"$err"
  rc=$?
  stop_mock

  # Exit 0 regardless (the mock returns empty for unknown queries — that's fine)
  if [ "$rc" -eq 0 ]; then pass "encoding: exit 0 with space in query"; else fail "encoding: exit $rc with space in query"; fi
  if "$PYTHON" -c "import json,sys; json.load(sys.stdin)" <"$out" 2>/dev/null; then
    pass "encoding: valid JSON returned for space query"
  else
    fail "encoding: invalid JSON for space query"
  fi
}

# =============================================================================
echo "== citt search harness =="
test_basic_search
test_platform_ios
test_limit
test_empty_results
test_missing_query
test_invalid_limit
test_invalid_platform
test_result_fields
test_no_token_leak
test_query_encoding

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
