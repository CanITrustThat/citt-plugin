#!/usr/bin/env bash
# =============================================================================
# test_citt_submit_cmd.sh — TDD harness for `citt submit` (CITT-334)
# =============================================================================
# Exercises the `citt submit` dispatcher subcommand defined in
# citt-plugin/scripts/lib/cmd-submit.sh.  The harness uses the SAME
# mock_submit_server.py (read-only) that test_citt_submit.sh uses for the
# underlying citt-submit.sh.
#
# Scenarios covered:
#   T1: single package id (one-off)              citt submit com.foo.bar
#   T2: multiple package ids (many)              citt submit com.a com.b
#   T3: CSV file path                            citt submit apps.csv
#   T4: Play Store URL                           citt submit https://play.google.com/...
#   T5: App Store URL                            citt submit https://apps.apple.com/...
#   T6: no args -> usage on stderr + non-zero exit
#   T7: no token -> re-auth hint + non-zero exit
#   T8: token NEVER in stdout / argv / bash -x xtrace (forced-xtrace test)
#   T9: 401 -> re-authenticate hint + non-zero exit
#  T10: CSV path with multiple rows              delegates correctly
#
# Layout-independent paths:
#   HERE        = directory this file lives in
#   PLUGIN_ROOT = citt-plugin/ root
#   CITT        = citt-plugin/scripts/citt dispatcher under test
#
# Pure bash + stdlib python3 — no venv/pytest needed. Run:
#     bash citt-plugin/tests/test_citt_submit_cmd.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
CITT="$PLUGIN_ROOT/scripts/citt"
MOCK="$HERE/mock_submit_server.py"
PYTHON="${PYTHON:-python3}"

MOCK_TOKEN="citt_cmd_submit_mocktoken789"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Scratch workspace
# ---------------------------------------------------------------------------
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_submit_cmd_test.XXXXXX")"
cleanup_all() { rm -rf "$WORKROOT" 2>/dev/null || true; }
trap cleanup_all EXIT

# ---------------------------------------------------------------------------
# Mock server lifecycle (reuses mock_submit_server.py read-only)
# ---------------------------------------------------------------------------
MOCK_PID=""
MOCK_BASE=""

# start_mock  STATUS_JSON  SEARCH_JSON  TIER_DENY  BAD_TOKEN  LOGFILE
start_mock() {
  local statusj="$1" searchj="$2" tierdeny="$3" badtok="$4" logf="$5" outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_STATUS="$statusj" CITT_MOCK_SEARCH="$searchj" \
  CITT_MOCK_TIER_DENY="$tierdeny" CITT_MOCK_BAD_TOKEN="$badtok" \
  CITT_MOCK_LOG="$logf" \
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

new_token_dir() {
  local d; d="$(mktemp -d "$WORKROOT/home.XXXXXX")"
  printf '%s' "$d"
}

seed_token() {  # $1 = tokdir  $2 = token (default MOCK_TOKEN)
  local tokdir="$1" val="${2:-$MOCK_TOKEN}"
  mkdir -p "$tokdir"
  ( umask 077; printf '%s' "$val" >"$tokdir/device_token" )
  chmod 600 "$tokdir/device_token"
}

count_submits() {  # $1 = logfile  $2 = pkg
  local n
  n="$(grep -c "\"path\": \"submit\", \"pkg\": \"$2\"" "$1" 2>/dev/null)"
  printf '%s' "${n:-0}"
}

# Speed knobs (same as test_citt_submit.sh)
export CITT_POLL_BASE_SLEEP="0.05"
export CITT_POLL_MAX_SLEEP="0.2"
export CITT_PER_APP_BUDGET="8"

# ===========================================================================
# T1: Single package id — `citt submit com.foo.bar`
#     A new (missing pre-check) app should be submitted and complete.
# ===========================================================================
test_single_package() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  local statusj='{"com.single.app":{"pre":"missing","poll":["completed"],"score":77}}'
  start_mock "$statusj" '{}' '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "single: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" submit com.single.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  local subs; subs="$(count_submits "$logf" com.single.app)"
  if [ "$subs" -ge 1 ]; then pass "single: app was submitted"; else fail "single: app NOT submitted (count=$subs)"; fi
  if [ "$rc" -eq 0 ]; then pass "single: exit 0"; else fail "single: exit $rc (want 0)"; fi
  if grep -q "com.single.app" "$out"; then pass "single: app in summary output"; else fail "single: app missing from output"; fi
}

# ===========================================================================
# T2: Multiple package ids — `citt submit com.a com.b`
#     Both apps should be submitted and appear in the summary.
# ===========================================================================
test_multiple_packages() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  local statusj='{"com.alpha.app":{"pre":"missing","poll":["completed"],"score":82},"com.beta.app":{"pre":"missing","poll":["completed"],"score":65}}'
  start_mock "$statusj" '{}' '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "multi: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" submit com.alpha.app com.beta.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  local subs_a; subs_a="$(count_submits "$logf" com.alpha.app)"
  local subs_b; subs_b="$(count_submits "$logf" com.beta.app)"
  if [ "$subs_a" -ge 1 ]; then pass "multi: com.alpha.app submitted"; else fail "multi: com.alpha.app NOT submitted"; fi
  if [ "$subs_b" -ge 1 ]; then pass "multi: com.beta.app submitted"; else fail "multi: com.beta.app NOT submitted"; fi
  if [ "$rc" -eq 0 ]; then pass "multi: exit 0"; else fail "multi: exit $rc (want 0)"; fi
  if grep -q "com.alpha.app" "$out" && grep -q "com.beta.app" "$out"; then
    pass "multi: both apps in summary output"
  else
    fail "multi: one or both apps missing from output"
  fi
}

# ===========================================================================
# T3: CSV file path — `citt submit apps.csv`
#     When given a readable file path, delegates directly to citt-submit.sh.
# ===========================================================================
test_csv_file_path() {
  local tokdir logf out err csv rc
  tokdir="$(new_token_dir)/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"
  csv="$(mktemp "$WORKROOT/apps.XXXXXX")"; mv "$csv" "${csv}.csv"; csv="${csv}.csv"
  cat >"$csv" <<'CSV'
package_id,platform
com.csv.appone,android
com.csv.apptwo,android
CSV

  local statusj='{"com.csv.appone":{"pre":"fresh","score":88},"com.csv.apptwo":{"pre":"missing","poll":["completed"],"score":72}}'
  start_mock "$statusj" '{}' '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "csv: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" submit "$csv" >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "csv: exit 0"; else fail "csv: exit $rc (want 0)"; fi
  if grep -q "com.csv.appone" "$out"; then pass "csv: first app in output"; else fail "csv: first app missing from output"; fi
  if grep -q "com.csv.apptwo" "$out"; then pass "csv: second app in output"; else fail "csv: second app missing from output"; fi
  # Fresh app (com.csv.appone) must NOT be re-submitted.
  local fresh_subs; fresh_subs="$(count_submits "$logf" com.csv.appone)"
  if [ "$fresh_subs" -eq 0 ]; then pass "csv: fresh app NOT re-submitted (dedup honored)"; else fail "csv: fresh app was submitted $fresh_subs time(s) (want 0)"; fi
}

# ===========================================================================
# T4: Play Store URL — `citt submit https://play.google.com/store/apps/details?id=com.play.app`
#     The adapter must extract the package id and submit it.
# ===========================================================================
test_play_store_url() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  local statusj='{"com.play.app":{"pre":"missing","poll":["completed"],"score":80}}'
  start_mock "$statusj" '{}' '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "play: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" submit "https://play.google.com/store/apps/details?id=com.play.app" \
    >"$out" 2>"$err"
  rc=$?
  stop_mock

  local subs; subs="$(count_submits "$logf" com.play.app)"
  if [ "$subs" -ge 1 ]; then pass "play: app submitted from Play Store URL"; else fail "play: app NOT submitted (count=$subs)"; fi
  if [ "$rc" -eq 0 ]; then pass "play: exit 0"; else fail "play: exit $rc (want 0)"; fi
  if grep -q "com.play.app" "$out"; then pass "play: app in output"; else fail "play: app missing from output"; fi
}

# ===========================================================================
# T5: App Store URL — `citt submit https://apps.apple.com/...`
#     The adapter must pass the store_url column and the server resolves it.
#     (The mock serves status for com.apple.app which citt-submit.sh extracts
#     from the URL as id<digits>; we use a numeric-id style URL that maps to
#     the numeric id in the status map.)
# ===========================================================================
test_app_store_url() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  # citt-submit.sh extracts the last path segment (id123456789) as the pkg id.
  local statusj='{"id123456789":{"pre":"missing","poll":["completed"],"score":76}}'
  start_mock "$statusj" '{}' '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "ios: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" submit "https://apps.apple.com/us/app/some-app/id123456789" \
    >"$out" 2>"$err"
  rc=$?
  stop_mock

  local subs; subs="$(count_submits "$logf" id123456789)"
  if [ "$subs" -ge 1 ]; then pass "ios: app submitted from App Store URL"; else fail "ios: app NOT submitted from App Store URL (count=$subs)"; fi
  if [ "$rc" -eq 0 ]; then pass "ios: exit 0"; else fail "ios: exit $rc (want 0)"; fi
}

# ===========================================================================
# T6: No args -> usage on stderr + non-zero exit
# ===========================================================================
test_no_args_usage() {
  local tokdir out err rc
  tokdir="$(new_token_dir)/.config/citt"; seed_token "$tokdir"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$CITT" submit >"$out" 2>"$err"
  rc=$?

  if [ "$rc" -ne 0 ]; then pass "no-args: non-zero exit ($rc)"; else fail "no-args: exit 0 (should fail)"; fi
  if grep -qi "usage\|package\|csv\|submit\|argument" "$out" "$err"; then
    pass "no-args: usage hint printed"
  else
    fail "no-args: no usage hint (stdout: $(cat "$out") stderr: $(cat "$err"))"
  fi
}

# ===========================================================================
# T7: No token -> re-auth hint + non-zero exit
# ===========================================================================
test_no_token() {
  local tokdir out err rc
  tokdir="$(new_token_dir)/.config/citt"   # token dir exists but no token file
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$CITT" submit com.any.app >"$out" 2>"$err"
  rc=$?

  if [ "$rc" -ne 0 ]; then pass "no-token: non-zero exit ($rc)"; else fail "no-token: exit 0 (should fail)"; fi
  if grep -qi "auth\|authenticate\|login\|citt auth" "$out" "$err"; then
    pass "no-token: re-auth hint printed"
  else
    fail "no-token: no re-auth hint (stdout: $(cat "$out") stderr: $(cat "$err"))"
  fi
}

# ===========================================================================
# T8: SECRET ISOLATION — token never in stdout / curl argv / bash -x xtrace.
#     This copies the forced-xtrace technique from test_citt_auth.sh's
#     test_token_not_in_forced_xtrace.
# ===========================================================================
SENTINEL_TOKEN="citt_cmd_SENTINELSECRET_submit_9x7"
test_token_not_in_forced_xtrace() {
  local tokdir out trace args rc
  tokdir="$(new_token_dir)/.config/citt"
  seed_token "$tokdir" "$SENTINEL_TOKEN"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  trace="$(mktemp "$WORKROOT/trace.XXXXXX")"
  args="$(mktemp "$WORKROOT/args.XXXXXX")"
  local logf; logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"

  local statusj='{"com.sentinel.app":{"pre":"missing","poll":["completed"],"score":85}}'
  start_mock "$statusj" '{}' '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "xtrace: mock did not start"; return; fi

  # Wrap curl to capture all argv.
  local bindir="$WORKROOT/bin_xtrace"
  mkdir -p "$bindir"
  cat >"$bindir/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CITT_TEST_ARGS_FILE"
exec /usr/bin/curl "$@"
EOF
  chmod +x "$bindir/curl"

  # Force external xtrace and capture both stderr (xtrace) and stdout separately.
  CITT_TEST_ARGS_FILE="$args" \
  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  PATH="$bindir:$PATH" \
  bash -x "$CITT" submit com.sentinel.app >"$out" 2>"$trace"
  rc=$?
  stop_mock

  # HARD INVARIANT: token NEVER in stdout
  if grep -q "$SENTINEL_TOKEN" "$out"; then
    fail "SECRET LEAK: token in stdout"
  else
    pass "xtrace: token NOT in stdout"
  fi

  # HARD INVARIANT: token NEVER in forced bash -x trace
  if grep -q "$SENTINEL_TOKEN" "$trace"; then
    fail "SECRET LEAK: token in forced bash -x xtrace"
  else
    pass "xtrace: token NOT in forced bash -x xtrace"
  fi

  # HARD INVARIANT: token NEVER in curl argv
  if [ -f "$args" ] && grep -q "$SENTINEL_TOKEN" "$args"; then
    fail "SECRET LEAK: token in curl argv"
  else
    pass "xtrace: token NOT in curl argv"
  fi

  # No raw Authorization header on curl argv either
  if [ -f "$args" ] && grep -qi "Authorization: Bearer" "$args"; then
    fail "SECRET LEAK: Authorization header on curl argv"
  else
    pass "xtrace: no Authorization header on curl argv"
  fi

  # Sanity: command still produced useful output
  if [ "$rc" -eq 0 ]; then
    pass "xtrace: submit still exits 0 (functional)"
  else
    fail "xtrace: submit failed (exit $rc) while testing isolation"
  fi
}

# ===========================================================================
# T9: 401 response -> re-authenticate hint + non-zero exit
# ===========================================================================
test_401_reauth() {
  local tokdir logf out err rc
  tokdir="$(new_token_dir)/.config/citt"
  seed_token "$tokdir" "$MOCK_TOKEN"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  # Mock treats MOCK_TOKEN as BAD -> every call 401s.
  start_mock '{"com.any.app":{"pre":"missing"}}' '{}' '' "$MOCK_TOKEN" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "401: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" submit com.any.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "401: non-zero exit ($rc)"; else fail "401: exit 0 (should fail)"; fi
  if grep -qi "re-authenticate\|auth\|authenticate\|citt auth" "$out" "$err"; then
    pass "401: re-auth hint printed"
  else
    fail "401: no re-auth hint (stdout: $(cat "$out") stderr: $(cat "$err"))"
  fi
}

# ===========================================================================
# T10: CSV file with multiple rows (stress the delegation path)
#      Exercises that a CSV file argument correctly delegates to citt-submit.sh
#      with all its dedup + batch + deep-link behavior intact.
# ===========================================================================
test_csv_multi_row_delegation() {
  local tokdir logf out err csv rc
  tokdir="$(new_token_dir)/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"
  csv="$(mktemp "$WORKROOT/apps.XXXXXX")"; mv "$csv" "${csv}.csv"; csv="${csv}.csv"
  cat >"$csv" <<'CSV'
package_id,store_url,platform
com.multi.one,,android
,https://play.google.com/store/apps/details?id=com.multi.two,android
CSV

  local statusj='{"com.multi.one":{"pre":"fresh","score":91},"com.multi.two":{"pre":"missing","poll":["completed"],"score":58}}'
  start_mock "$statusj" '{}' '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "csv-multi: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$CITT" submit "$csv" >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "csv-multi: exit 0"; else fail "csv-multi: exit $rc (want 0)"; fi
  if grep -q "com.multi.one" "$out"; then pass "csv-multi: first app in output"; else fail "csv-multi: first app missing"; fi
  if grep -q "com.multi.two" "$out"; then pass "csv-multi: second app (URL row) in output"; else fail "csv-multi: second app missing"; fi
  # Deep link must be present
  if grep -q "canitrustthat.com/apps/com.multi.one" "$out"; then
    pass "csv-multi: deep link present for first app"
  else
    fail "csv-multi: no deep link for first app"
  fi
  # Fresh app must NOT be re-submitted
  local fresh_subs; fresh_subs="$(count_submits "$logf" com.multi.one)"
  if [ "$fresh_subs" -eq 0 ]; then
    pass "csv-multi: fresh app NOT re-submitted (dedup honored via delegation)"
  else
    fail "csv-multi: fresh app submitted $fresh_subs time(s) (want 0)"
  fi
}

# ===========================================================================
# Run all tests
# ===========================================================================
echo "== citt submit dispatch harness (CITT-334) =="
test_single_package
test_multiple_packages
test_csv_file_path
test_play_store_url
test_app_store_url
test_no_args_usage
test_no_token
test_token_not_in_forced_xtrace
test_401_reauth
test_csv_multi_row_delegation

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
