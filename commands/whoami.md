---
description: Show which CITT account is signed in and its plan
allowed-tools: Bash
---

Show the currently connected CITT account.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt whoami`. On success it prints the account JSON (email, user type, subscription plan and usage). Summarize it for the user: who they are signed in as, their plan, and remaining submission and scan quota. If it exits non-zero, the user is not connected: tell them to run `/citt:auth`.
