---
description: Start a network capture run of an Android app on a lab phone
argument-hint: APP --project NAME|ID --duration 3h --state CA [--language TAG] [--phone NAME|ID] [--wait]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt capture-start $ARGUMENTS` and relay the run line and the Next: commands.

See the citt skill for every option and the exit codes. Never read or print the token.
