---
description: Show the phones, exit states, session lengths and measured size a capture run of an app can use
argument-hint: APP --project NAME|ID [--duration 3h]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt capture-options $ARGUMENTS` and relay the output.

See the citt skill for every option and the exit codes. Never read or print the token.
