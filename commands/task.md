---
description: One task with its status, parts, timeline and result link
argument-hint: ID [--cancel] [--watch]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt task $ARGUMENTS` and relay the output; on exit 12 run the printed re-run: line.

See the citt skill for every option and the exit codes. Never read or print the token.
