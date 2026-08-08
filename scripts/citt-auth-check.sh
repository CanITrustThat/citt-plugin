#!/usr/bin/env bash
# citt-auth-check.sh — fast local auth probe for the SessionStart nudge.
# Exits 0 if a CITT token is stored (keyring or 0600 file), 1 otherwise.
# No network, no stdout, never reads token bytes. Store coordinates must stay in
# sync with lib/citt-common.sh (_CITT_KR_SERVICE/_CITT_KR_ACCOUNT/_CITT_TOKEN_FILE).
set -euo pipefail

# State dir PINNED to a stable path (CITT_STATE_DIR override, else $HOME/.config/citt),
# matching lib/citt-common.sh. CLAUDE_PLUGIN_DATA is only a legacy migration source.
TOKEN_FILE="${CITT_STATE_DIR:-$HOME/.config/citt}/device_token"
KR_SERVICE="canitrustthat-citt"
KR_ACCOUNT="device_token"

# 0600 file fallback store (or a token left by an older build under CLAUDE_PLUGIN_DATA).
[ -s "$TOKEN_FILE" ] && exit 0
[ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -s "${CLAUDE_PLUGIN_DATA}/device_token" ] && exit 0

# macOS Keychain.
if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
  security find-generic-password -s "$KR_SERVICE" -a "$KR_ACCOUNT" >/dev/null 2>&1 && exit 0
fi

# Linux libsecret.
if command -v secret-tool >/dev/null 2>&1; then
  secret-tool lookup service "$KR_SERVICE" account "$KR_ACCOUNT" >/dev/null 2>&1 && exit 0
fi

exit 1
