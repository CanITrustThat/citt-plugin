#!/usr/bin/env bash
# =============================================================================
# test_citt_submit.sh — TDD harness for citt-submit.sh (CITT-268)
# =============================================================================
# Runs citt-submit.sh against a local MOCK submit/status/search server
# (mock_submit_server.py) via the test-only CITT_API_OVERRIDE seam (honored only
# under CITT_TEST_MODE=1; the production host stays hardcoded). Mirrors the
# structure + secret-isolation assertions of test_citt_auth.sh (CITT-267).
#
# Asserts:
#   * Dedup: a package with a fresh (<90d) completed scan is NOT re-submitted,
#     and an idempotent re-run creates no duplicate POST /api/submit.
#   * Resilience: a stuck/failed app does not strand the rest — the others still
#     complete and a PARTIAL summary is still emitted.
#   * Secret isolation: the token NEVER appears in stdout, captured curl argv, or
#     a `bash -x` xtrace (BASH_XTRACEFD technique from citt-auth's harness).
#   * Name-only row requires confirmation (unresolved section, not auto-submitted).
#   * 401 -> prints "re-authenticate: run citt-auth.sh" + non-zero exit.
#   * Tier 403 -> upgrade nudge with pricing link + stop.
#
# Pure bash + stdlib python3 — no venv/pytest needed. Run:
#     bash citt-plugin/tests/test_citt_submit.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
SUBMIT="$PLUGIN_ROOT/scripts/citt-submit.sh"
MOCK="$HERE/mock_submit_server.py"
PYTHON="${PYTHON:-python3}"

MOCK_TOKEN="citt_tokid123_supersecretvalue456"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_submit_test.XXXXXX")"
cleanup_all() { rm -rf "$WORKROOT" 2>/dev/null || true; }
trap cleanup_all EXIT

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

new_env_dir() {
  local d
  d="$(mktemp -d "$WORKROOT/home.XXXXXX")"
  printf '%s' "$d"
}

# Seed a valid 0600 token file so the script authenticates via TOKEN_FILE.
seed_token() {  # $1 = tokdir  ; $2 = token value (default MOCK_TOKEN)
  local tokdir="$1" val="${2:-$MOCK_TOKEN}"
  mkdir -p "$tokdir"
  ( umask 077; printf '%s' "$val" >"$tokdir/device_token" )
  chmod 600 "$tokdir/device_token"
}

# Count POST /api/submit records for a package in the mock log. Always emits a
# single integer (grep -c prints 0 and exits 1 on no match, so swallow status).
count_submits() {  # $1 = logfile  $2 = pkg
  local n
  n="$(grep -c "\"path\": \"submit\", \"pkg\": \"$2\"" "$1" 2>/dev/null)"
  printf '%s' "${n:-0}"
}

# Fast backoff so the harness is quick.
export CITT_POLL_BASE_SLEEP="0.05"
export CITT_POLL_MAX_SLEEP="0.2"
export CITT_PER_APP_BUDGET="8"

# ---------------------------------------------------------------------------
# Test 1: DEDUP — a fresh (<90d) completed scan is NOT re-submitted; a stale
# (>90d) one IS. And a second identical run makes NO new submit for the fresh
# app (idempotent client-side).
# ---------------------------------------------------------------------------
test_dedup() {
  local envdir tokdir logf out csv rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  csv="$(mktemp "$WORKROOT/apps.XXXXXX")"
  cat >"$csv" <<'CSV'
package_id,platform
com.fresh.app,android
com.stale.app,android
CSV

  local statusj='{"com.fresh.app":{"pre":"fresh","score":88},"com.stale.app":{"pre":"stale","poll":["completed"],"score":64}}'
  start_mock "$statusj" '{}' '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "dedup: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$SUBMIT" "$csv" >"$out" 2>/dev/null
  rc=$?

  local fresh_subs stale_subs
  fresh_subs="$(count_submits "$logf" com.fresh.app)"
  stale_subs="$(count_submits "$logf" com.stale.app)"
  if [ "$fresh_subs" -eq 0 ]; then pass "dedup: fresh app NOT re-submitted"; else fail "dedup: fresh app submitted $fresh_subs times (want 0)"; fi
  if [ "$stale_subs" -ge 1 ]; then pass "dedup: stale app WAS submitted"; else fail "dedup: stale app not submitted"; fi
  if [ "$rc" -eq 0 ]; then pass "dedup: exit 0"; else fail "dedup: exit $rc"; fi
  if grep -q "com.fresh.app" "$out"; then pass "dedup: fresh app in summary"; else fail "dedup: fresh app missing from summary"; fi

  # Idempotent re-run: submit count for the fresh app must stay 0.
  local out2; out2="$(mktemp "$WORKROOT/out.XXXXXX")"
  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$SUBMIT" "$csv" >"$out2" 2>/dev/null
  fresh_subs="$(count_submits "$logf" com.fresh.app)"
  if [ "$fresh_subs" -eq 0 ]; then pass "dedup: re-run made no duplicate submit for fresh app"; else fail "dedup: re-run duplicated submit ($fresh_subs)"; fi
  stop_mock
}

# ---------------------------------------------------------------------------
# Test 2: RESILIENCE — a stuck app (never completes within budget) must NOT
# strand the rest. The healthy app still completes and a summary is emitted.
# ---------------------------------------------------------------------------
test_resilience() {
  local envdir tokdir logf out csv rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  csv="$(mktemp "$WORKROOT/apps.XXXXXX")"
  cat >"$csv" <<'CSV'
package_id,platform
com.stuck.app,android
com.ok.app,android
CSV

  # stuck: always "analyzing" (never completes) -> time-boxed out.
  # ok:    queued then completed.
  local statusj='{"com.stuck.app":{"pre":"missing","poll":["analyzing","analyzing","analyzing","analyzing","analyzing","analyzing","analyzing","analyzing","analyzing","analyzing"]},"com.ok.app":{"pre":"missing","poll":["queued","completed"],"score":79}}'
  start_mock "$statusj" '{}' '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "resilience: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  CITT_PER_APP_BUDGET="2" \
  bash "$SUBMIT" "$csv" >"$out" 2>/dev/null
  rc=$?
  stop_mock

  if grep -q "com.ok.app" "$out"; then pass "resilience: healthy app completed + in summary"; else fail "resilience: healthy app missing from summary"; fi
  # The stuck app is reported somewhere (in-progress / incomplete / timed-out).
  if grep -qi "com.stuck.app" "$out"; then pass "resilience: stuck app still reported (not silently dropped)"; else fail "resilience: stuck app absent from summary"; fi
  # A PARTIAL / incomplete indication is surfaced.
  if grep -qi "partial\|incomplete\|in progress\|timed out\|still running\|pending" "$out"; then
    pass "resilience: partial-summary indicated"
  else
    fail "resilience: no partial/incomplete indication in summary"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: SECRET ISOLATION — token never in stdout / curl argv / bash -x trace.
# ---------------------------------------------------------------------------
test_secret_isolation() {
  local envdir tokdir logf out csv args xtrace rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  args="$(mktemp "$WORKROOT/args.XXXXXX")"
  xtrace="$(mktemp "$WORKROOT/xtrace.XXXXXX")"
  csv="$(mktemp "$WORKROOT/apps.XXXXXX")"
  cat >"$csv" <<'CSV'
package_id,platform
com.fresh.app,android
com.ok.app,android
CSV

  local statusj='{"com.fresh.app":{"pre":"fresh","score":90},"com.ok.app":{"pre":"missing","poll":["completed"],"score":70}}'
  start_mock "$statusj" '{}' '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "secret: mock did not start"; return; fi

  # Wrap curl so every argv is logged — proves the token is never argv.
  local bindir="$envdir/bin"
  mkdir -p "$bindir"
  cat >"$bindir/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$args"
exec /usr/bin/curl "\$@"
EOF
  chmod +x "$bindir/curl"

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  PATH="$bindir:$PATH" \
  BASH_XTRACEFD=9 \
  bash -x "$SUBMIT" "$csv" >"$out" 2>/dev/null 9>"$xtrace"
  rc=$?
  stop_mock

  if grep -q "$MOCK_TOKEN" "$out"; then fail "SECRET LEAK: token in stdout"; else pass "secret: token NOT in stdout"; fi
  if grep -q "$MOCK_TOKEN" "$args"; then fail "SECRET LEAK: token in curl argv"; else pass "secret: token NOT in curl argv"; fi
  if grep -q "$MOCK_TOKEN" "$xtrace"; then fail "SECRET LEAK: token in set -x trace"; else pass "secret: token NOT in set -x trace"; fi
  # Also assert no bare "Authorization: Bearer" appears in captured argv.
  if grep -qi "Authorization: Bearer" "$args"; then fail "SECRET LEAK: Authorization header on curl argv"; else pass "secret: no Authorization header on curl argv"; fi
}

# ---------------------------------------------------------------------------
# Test 4: NAME-ONLY row requires confirmation — appears in an unresolved /
# needs-confirmation section, and is NOT auto-submitted.
# ---------------------------------------------------------------------------
test_name_only_needs_confirmation() {
  local envdir tokdir logf out csv rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  csv="$(mktemp "$WORKROOT/apps.XXXXXX")"
  # A header-only style CSV with just app_name column values.
  cat >"$csv" <<'CSV'
app_name
Signal Private Messenger
CSV

  # search resolves the name to a candidate package, but it must NOT be submitted.
  local searchj='{"signal private messenger":[{"package_id":"org.thoughtcrime.securesms","app_name":"Signal","developer":"Signal","platform":"android"}]}'
  start_mock '{}' "$searchj" '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "name-only: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$SUBMIT" "$csv" >"$out" 2>/dev/null
  rc=$?
  stop_mock

  local subs
  subs="$(count_submits "$logf" org.thoughtcrime.securesms)"
  if [ "$subs" -eq 0 ]; then pass "name-only: guessed match NOT auto-submitted"; else fail "name-only: guessed match was submitted ($subs)"; fi
  if grep -qi "unresolved\|needs confirmation\|confirm" "$out"; then
    pass "name-only: surfaced in unresolved / needs-confirmation section"
  else
    fail "name-only: no unresolved/needs-confirmation section"
  fi
  # The candidate it found should be shown so the user can confirm it.
  if grep -q "org.thoughtcrime.securesms" "$out"; then pass "name-only: candidate package shown for confirmation"; else fail "name-only: candidate package not shown"; fi
}

# ---------------------------------------------------------------------------
# Test 5: 401 -> "re-authenticate: run citt-auth.sh" on stderr + non-zero exit.
# We seed a BAD token the mock rejects (models revoked/expired skill token).
# ---------------------------------------------------------------------------
test_401_reauth() {
  local envdir tokdir logf out err csv rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  seed_token "$tokdir" "$MOCK_TOKEN"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"
  csv="$(mktemp "$WORKROOT/apps.XXXXXX")"
  cat >"$csv" <<'CSV'
package_id,platform
com.any.app,android
CSV

  # Mock treats MOCK_TOKEN as the BAD token -> every call 401s.
  start_mock '{"com.any.app":{"pre":"missing"}}' '{}' '' "$MOCK_TOKEN" "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "401: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$SUBMIT" "$csv" >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "401: non-zero exit ($rc)"; else fail "401: exit 0 (should fail)"; fi
  if grep -q "re-authenticate: run citt-auth.sh" "$err"; then
    pass "401: printed re-authenticate hint to stderr"
  else
    fail "401: missing 're-authenticate: run citt-auth.sh' on stderr"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: MISSING token -> re-authenticate hint + non-zero exit (no network).
# ---------------------------------------------------------------------------
test_missing_token() {
  local envdir tokdir out err csv rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"
  csv="$(mktemp "$WORKROOT/apps.XXXXXX")"
  printf 'package_id,platform\ncom.any.app,android\n' >"$csv"

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$SUBMIT" "$csv" >"$out" 2>"$err"
  rc=$?

  if [ "$rc" -ne 0 ]; then pass "missing-token: non-zero exit ($rc)"; else fail "missing-token: exit 0 (should fail)"; fi
  if grep -q "re-authenticate: run citt-auth.sh" "$err"; then
    pass "missing-token: printed re-authenticate hint"
  else
    fail "missing-token: missing re-authenticate hint"
  fi
}

# ---------------------------------------------------------------------------
# Test 7: TIER 403 -> upgrade nudge with pricing link, and stop.
# ---------------------------------------------------------------------------
test_tier_denied() {
  local envdir tokdir logf out err csv rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"
  csv="$(mktemp "$WORKROOT/apps.XXXXXX")"
  printf 'package_id,platform\ncom.gated.app,android\n' >"$csv"

  start_mock '{"com.gated.app":{"pre":"missing"}}' '{}' 'com.gated.app' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "tier: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$SUBMIT" "$csv" >"$out" 2>"$err"
  rc=$?
  stop_mock

  if grep -qi "pricing" "$out$err" 2>/dev/null || grep -qi "canitrustthat.com/pricing" "$out" "$err"; then
    pass "tier: pricing link surfaced"
  else
    fail "tier: no pricing link surfaced"
  fi
  if grep -qi "Developer\|Research\|upgrade" "$out" "$err"; then
    pass "tier: upgrade nudge surfaced"
  else
    fail "tier: no upgrade nudge"
  fi
}

# ---------------------------------------------------------------------------
# Test 8: FORGIVING CSV — header row, quoted fields, blank lines, store_url, and
# a deep link to /apps/{pkg} in the summary.
# ---------------------------------------------------------------------------
test_forgiving_csv_and_deeplink() {
  local envdir tokdir logf out csv rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  csv="$(mktemp "$WORKROOT/apps.XXXXXX")"
  cat >"$csv" <<'CSV'
package_id,store_url,app_name,platform
com.fresh.app,,"Fresh App",android

,https://play.google.com/store/apps/details?id=com.url.app,,android
CSV

  local statusj='{"com.fresh.app":{"pre":"fresh","score":85},"com.url.app":{"pre":"fresh","score":55}}'
  start_mock "$statusj" '{}' '' '' "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "csv: mock did not start"; return; fi

  CITT_STATE_DIR="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$SUBMIT" "$csv" >"$out" 2>/dev/null
  rc=$?
  stop_mock

  if grep -q "com.url.app" "$out"; then pass "csv: store_url row resolved to package"; else fail "csv: store_url row not resolved"; fi
  if grep -q "canitrustthat.com/apps/com.fresh.app" "$out"; then pass "csv: deep link to /apps/{pkg} present"; else fail "csv: no /apps/{pkg} deep link"; fi
  if [ "$rc" -eq 0 ]; then pass "csv: exit 0"; else fail "csv: exit $rc"; fi
}

echo "== citt-submit.sh batch harness =="
test_dedup
test_resilience
test_secret_isolation
test_name_only_needs_confirmation
test_401_reauth
test_missing_token
test_tier_denied
test_forgiving_csv_and_deeplink

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
