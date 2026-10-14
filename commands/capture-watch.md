---
description: Follow a network capture run to its end
argument-hint: RUN [--timeout 540]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt capture-watch $ARGUMENTS` and relay the lines; on exit 12 run the printed re-run: line.

See the citt skill for every option and the exit codes. Never read or print the token.
