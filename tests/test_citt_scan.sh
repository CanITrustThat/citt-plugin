#!/usr/bin/env bash
# =============================================================================
# test_citt_scan.sh — TDD harness for cmd-scan.sh / citt scan (CITT-C1)
# =============================================================================
# Runs `citt scan` against a local mock server (mock_scan_server.py) via the
# CITT_API_OVERRIDE test seam (honored only under CITT_TEST_MODE=1; the
# production host stays hardcoded). Mirrors the secret-isolation invariants of
# test_citt_report.sh / test_citt_submit.sh.
#
# `citt scan "<prompt>" <app> [--platform android|ios]` builds a JSON body
#   {"package_id","platform"?,"scan_type":"custom","prompt","is_private":true}
# into a 0600 temp file and POSTs it to /api/submit. On 200/202 it prints the
# returned scan_id to stdout and a `→ citt result <scan_id>` hint to stderr.
#
# NOTE: the dispatcher (scripts/citt) does NOT yet route `scan` (ticket C3), so
# this harness drives the command via a direct-source RUNNER that sources
# lib/citt-common.sh then lib/cmd-scan.sh and calls citt_cmd_scan "$@".
#
# Asserts:
#   * Happy path (200): scan_id → stdout, hint → stderr, exit 0; body carried
#     scan_type=custom, is_private=true, exact prompt, package_id.
#   * 202 accepted behaves like happy path.
#   * Empty prompt → client-side rejection, NO http call, non-zero exit.
#   * Over-5000-char prompt → client-side rejection, non-zero exit.
#   * Bare app name (no dot, not a URL) → friendly rejection, non-zero exit.
#   * 403 → Research-plan message, non-zero exit.
#   * 401 → re-auth hint, non-zero exit.
#   * --platform ios → body carries platform=ios.
#   * SECRET/PROMPT NON-LEAK: under bash -x the token never appears, and the
#     prompt never appears on a curl argv line; body file is 0600 and removed.
#
# Pure bash + stdlib python3 — no venv/pytest. Run:
#     bash citt-plugin/tests/test_citt_scan.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
CITT="$PLUGIN_ROOT/scripts/citt"
LIB="$PLUGIN_ROOT/scripts/lib/citt-common.sh"
CMD="$PLUGIN_ROOT/scripts/lib/cmd-scan.sh"
MOCK="$HERE/mock_scan_server.py"
PYTHON="${PYTHON:-python3}"

MOCK_TOKEN="citt_scan_mocktoken789"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Infrastructure: temp workspace, mock lifecycle
# ---------------------------------------------------------------------------
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/citt_scan_test.XXXXXX")"
cleanup_all() { rm -rf "$WORKROOT" 2>/dev/null || true; }
trap cleanup_all EXIT

MOCK_PID=""
MOCK_BASE=""

# start_mock $1=logfile [$2=forced_status] [$3=token_override]
start_mock() {
  local logf="$1" status="${2:-}" tok="${3:-$MOCK_TOKEN}" outf
  outf="$(mktemp "$WORKROOT/mockout.XXXXXX")"
  CITT_MOCK_STATUS="$status" CITT_MOCK_LOG="$logf" CITT_MOCK_TOKEN="$tok" \
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
# The RUNNER: the dispatcher does not route `scan` yet (ticket C3), so we
# source the lib + cmd module and invoke citt_cmd_scan directly. This mirrors
# exactly what the dispatcher case-branch does for report/submit/etc.
# We write a tiny runner script so it runs in its own process (clean traps,
# faithful bash -x behavior) and can be invoked via `bash -x` for the leak test.
# ---------------------------------------------------------------------------
RUNNER="$WORKROOT/run_scan.sh"
cat >"$RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
_CITT_SELF_DIR="$PLUGIN_ROOT/scripts"
. "$LIB"
. "$CMD"
citt_cmd_scan "\$@"
EOF
chmod +x "$RUNNER"

# run_scan <envargs...> -- <scan args...>   (helper wraps env + runner)
# For simplicity each test invokes `bash "$RUNNER" ...` with env prefixed.

# ---------------------------------------------------------------------------
# Test 1: happy path (200) — scan_id to stdout, hint to stderr, exit 0
# ---------------------------------------------------------------------------
test_happy_path() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "happy: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" "Does this app leak location to third parties?" com.ok.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "happy: exit 0"; else fail "happy: exit $rc"; fi
  if grep -q 'abc123' "$out"; then pass "happy: scan_id on stdout"; else fail "happy: scan_id not on stdout"; fi
  if grep -q 'citt result abc123' "$err"; then pass "happy: 'citt result' hint on stderr"; else fail "happy: no follow-up hint on stderr"; fi

  # Assert the mock received the right body.
  if python3 -c "
import json,sys
found=False
for line in open('$logf'):
    e=json.loads(line)
    if e.get('kind')=='submit':
        b=e['body']['body']
        assert b.get('scan_type')=='custom', b
        assert b.get('is_private') is True, b
        assert b.get('prompt')=='Does this app leak location to third parties?', b
        assert b.get('package_id')=='com.ok.app', b
        found=True
assert found
" 2>/dev/null; then
    pass "happy: body carried scan_type=custom,is_private=true,prompt,package_id"
  else
    fail "happy: submitted body was wrong"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: 202 accepted behaves like happy path
# ---------------------------------------------------------------------------
test_202_accepted() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "202: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" "Check crypto usage" com.accepted.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "202: exit 0"; else fail "202: exit $rc"; fi
  if grep -q 'abc123' "$out"; then pass "202: scan_id on stdout"; else fail "202: scan_id not on stdout"; fi
}

# ---------------------------------------------------------------------------
# Test 3: empty prompt → client-side rejection, NO http call, non-zero exit
# ---------------------------------------------------------------------------
test_empty_prompt() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "empty: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" "" com.ok.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "empty: non-zero exit"; else fail "empty: exit 0 (should fail)"; fi
  if grep -qi "prompt" "$err"; then pass "empty: friendly prompt message on stderr"; else fail "empty: no friendly message on stderr"; fi
  # No submit should have hit the mock.
  if [ -s "$logf" ] && grep -q '"kind": "submit"' "$logf"; then
    fail "empty: made an HTTP submit call (should be client-side reject)"
  else
    pass "empty: no HTTP call made"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: over-5000-char prompt → client-side rejection, non-zero exit
# ---------------------------------------------------------------------------
test_too_long_prompt() {
  local envdir tokdir logf out err rc bigprompt
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"
  bigprompt="$(head -c 5001 /dev/zero | tr '\0' 'a')"

  start_mock "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "toolong: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" "$bigprompt" com.ok.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "toolong: non-zero exit"; else fail "toolong: exit 0 (should fail)"; fi
  if grep -qi "5000\|too long\|prompt" "$err"; then pass "toolong: friendly message on stderr"; else fail "toolong: no friendly message on stderr"; fi
  if grep -q '"kind": "submit"' "$logf" 2>/dev/null; then
    fail "toolong: made an HTTP submit call (should be client-side reject)"
  else
    pass "toolong: no HTTP call made"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: bare app name (no dot, not a URL) → friendly rejection, non-zero exit
# ---------------------------------------------------------------------------
test_bare_name() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "bare: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" "Some question" Instagram >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "bare: non-zero exit"; else fail "bare: exit 0 (should fail)"; fi
  if grep -qi "package_id\|store URL\|url" "$err"; then pass "bare: friendly id/URL hint on stderr"; else fail "bare: no id/URL hint on stderr"; fi
  if grep -q '"kind": "submit"' "$logf" 2>/dev/null; then
    fail "bare: made an HTTP submit call (should be client-side reject)"
  else
    pass "bare: no HTTP call made"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: 403 → Research-plan message, non-zero exit
# ---------------------------------------------------------------------------
test_403_research() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "403: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" "Cross-app custom question" com.cross.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "403: non-zero exit"; else fail "403: exit 0 (should fail)"; fi
  if grep -qi "Research plan" "$err"; then pass "403: Research-plan message on stderr"; else fail "403: no Research-plan message on stderr"; fi
  local out_size; out_size="$(wc -c <"$out" 2>/dev/null || echo 0)"
  if [ "${out_size:-0}" -eq 0 ]; then pass "403: stdout empty"; else fail "403: unexpected stdout output"; fi
}

# ---------------------------------------------------------------------------
# Test 7: 401 → re-auth hint, non-zero exit
# ---------------------------------------------------------------------------
test_401_reauth() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"
  # Seed a token that the mock will REJECT (mock expects MOCK_TOKEN) → 401.
  seed_token "$tokdir" "citt_scan_WRONGTOKEN000"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "401: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" "A question" com.ok.app >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -ne 0 ]; then pass "401: non-zero exit"; else fail "401: exit 0 (should fail)"; fi
  if grep -qi "auth\|authenticate" "$err"; then pass "401: re-auth hint on stderr"; else fail "401: no re-auth hint on stderr"; fi
}

# ---------------------------------------------------------------------------
# Test 8: --platform ios → body carries platform=ios
# ---------------------------------------------------------------------------
test_platform_ios() {
  local envdir tokdir logf out err rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  start_mock "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "platform: mock did not start"; return; fi

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  bash "$RUNNER" "iOS question" com.ok.app --platform ios >"$out" 2>"$err"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "platform: exit 0"; else fail "platform: exit $rc"; fi
  if python3 -c "
import json
found=False
for line in open('$logf'):
    e=json.loads(line)
    if e.get('kind')=='submit':
        assert e['body']['body'].get('platform')=='ios', e['body']['body']
        found=True
assert found
" 2>/dev/null; then
    pass "platform: body carried platform=ios"
  else
    fail "platform: platform=ios not in body"
  fi
}

# ---------------------------------------------------------------------------
# Test 9: SECRET/PROMPT NON-LEAK under bash -x + curl-argv capture
# ---------------------------------------------------------------------------
SENTINEL_PROMPT="SENTINELPROMPT_should_never_be_a_curl_arg_42"

test_secret_and_prompt_noleak() {
  local envdir tokdir logf out err args xtrace rc
  envdir="$(new_env_dir)"; tokdir="$envdir/.config/citt"; seed_token "$tokdir"
  logf="$(mktemp "$WORKROOT/mocklog.XXXXXX")"
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"
  args="$(mktemp "$WORKROOT/args.XXXXXX")"
  xtrace="$(mktemp "$WORKROOT/xtrace.XXXXXX")"

  start_mock "$logf"
  if [ -z "$MOCK_BASE" ]; then fail "secret: mock did not start"; return; fi

  # Wrap curl to log every argv — proves the token AND the prompt are never
  # passed as an argument to curl. Also, for any --data @<file> argument, record
  # the referenced body file's PATH and octal MODE at call time so we can assert
  # it was created 0600 (and later removed).
  local bindir="$envdir/bin"
  local bodymeta; bodymeta="$(mktemp "$WORKROOT/bodymeta.XXXXXX")"
  mkdir -p "$bindir"
  cat >"$bindir/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$args"
for a in "\$@"; do
  case "\$a" in
    @*|--data=@*)
      f="\${a#--data=}"; f="\${f#@}"
      if [ -f "\$f" ]; then
        m="\$(stat -f '%Lp' "\$f" 2>/dev/null || stat -c '%a' "\$f" 2>/dev/null)"
        printf '%s %s\n' "\$m" "\$f" >>"$bodymeta"
      fi
      ;;
  esac
done
exec /usr/bin/curl "\$@"
EOF
  chmod +x "$bindir/curl"

  CLAUDE_PLUGIN_DATA="$tokdir" \
  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="$MOCK_BASE" \
  PATH="$bindir:$PATH" \
  BASH_XTRACEFD=9 \
  bash -x "$RUNNER" "$SENTINEL_PROMPT" com.ok.app >"$out" 2>"$err" 9>"$xtrace"
  rc=$?
  stop_mock

  if [ "$rc" -eq 0 ]; then pass "secret: exit 0"; else fail "secret: exit $rc (want 0)"; fi

  # Token isolation.
  if grep -q "$MOCK_TOKEN" "$out"; then fail "SECRET LEAK: token in stdout"; else pass "secret: token NOT in stdout"; fi
  if grep -q "$MOCK_TOKEN" "$args"; then fail "SECRET LEAK: token in curl argv"; else pass "secret: token NOT in curl argv"; fi
  if grep -q "$MOCK_TOKEN" "$xtrace"; then fail "SECRET LEAK: token in set -x trace"; else pass "secret: token NOT in set -x trace"; fi

  # Prompt isolation: the prompt must NEVER appear on a curl argv line.
  if grep -q "$SENTINEL_PROMPT" "$args"; then
    fail "PROMPT LEAK: prompt appears on curl argv"
  else
    pass "secret: prompt NOT on curl argv"
  fi
  # And it must not be passed via -d inline (defensive: no --data <prompt>).
  if grep -Eq -- "-d[ =].*$SENTINEL_PROMPT|--data[ =].*$SENTINEL_PROMPT" "$args"; then
    fail "PROMPT LEAK: prompt passed via -d/--data inline"
  else
    pass "secret: prompt NOT passed via -d/--data inline"
  fi
  # The mock must still have RECEIVED the exact prompt (via the body file).
  if python3 -c "
import json
for line in open('$logf'):
    e=json.loads(line)
    if e.get('kind')=='submit' and e['body']['body'].get('prompt')=='$SENTINEL_PROMPT':
        raise SystemExit(0)
raise SystemExit(1)
" 2>/dev/null; then
    pass "secret: prompt delivered to server via body file"
  else
    fail "secret: prompt not delivered to server"
  fi

  # Body file was 0600 at curl-call time.
  if [ -s "$bodymeta" ] && awk '{ if ($1 != "600") exit 1 } END { if (NR==0) exit 1 }' "$bodymeta"; then
    pass "secret: body file was 0600 at POST time"
  else
    fail "secret: body file was not 0600 (or none captured): $(cat "$bodymeta" 2>/dev/null)"
  fi
  # Body file was removed after the command exited (cleanup trap fired).
  local leftover=0 f
  while read -r _m f; do
    [ -n "$f" ] && [ -e "$f" ] && leftover=1
  done <"$bodymeta"
  if [ "$leftover" -eq 0 ]; then
    pass "secret: body file removed after exit"
  else
    fail "secret: body file left behind after exit"
  fi
}

# ---------------------------------------------------------------------------
# Test 10: -h/--help prints usage to stderr, exit 0
# ---------------------------------------------------------------------------
test_help() {
  local out err rc
  out="$(mktemp "$WORKROOT/out.XXXXXX")"
  err="$(mktemp "$WORKROOT/err.XXXXXX")"

  CITT_TEST_MODE=1 CITT_FORCE_FILE_TOKEN=1 CITT_API_OVERRIDE="http://127.0.0.1:1" \
  bash "$RUNNER" -h >"$out" 2>"$err"
  rc=$?

  if [ "$rc" -eq 0 ]; then pass "help: exit 0"; else fail "help: exit $rc"; fi
  if grep -qi "usage" "$err"; then pass "help: usage on stderr"; else fail "help: no usage on stderr"; fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "== citt scan harness (CITT-C1) =="
test_happy_path
test_202_accepted
test_empty_prompt
test_too_long_prompt
test_bare_name
test_403_research
test_401_reauth
test_platform_ios
test_secret_and_prompt_noleak
test_help

echo
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
