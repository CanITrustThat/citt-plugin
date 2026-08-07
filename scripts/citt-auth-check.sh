#!/usr/bin/env bash
# =============================================================================
# citt-auth-check.sh — fast local auth probe for the SessionStart nudge.
# =============================================================================
# Exits 0 if a CITT token is stored (keyring OR 0600 file), 1 otherwise.
# No network, no stdout, no token bytes read into a variable. Keeps the token
# store coordinates in sync with lib/citt-common.sh (_CITT_KR_SERVICE /
# _CITT_KR_ACCOUNT / _CITT_TOKEN_FILE). Used only to decide whether to tell the
# user to run /citt:auth; it never touches the token contents.
# =============================================================================
set -euo pipefail

TOKEN_FILE="${CLAUDE_PLUGIN_DATA:-$HOME/.config/citt}/device_token"
KR_SERVICE="canitrustthat-citt"
KR_ACCOUNT="device_token"

# 0600 file fallback store.
[ -s "$TOKEN_FILE" ] && exit 0

# macOS Keychain.
if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
  security find-generic-password -s "$KR_SERVICE" -a "$KR_ACCOUNT" >/dev/null 2>&1 && exit 0
fi

# Linux libsecret.
if command -v secret-tool >/dev/null 2>&1; then
  secret-tool lookup service "$KR_SERVICE" account "$KR_ACCOUNT" >/dev/null 2>&1 && exit 0
fi

exit 1
