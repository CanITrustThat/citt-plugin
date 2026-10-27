---
description: List the help requests of your capture runs, or watch for new ones
argument-hint: [--state open] [--watch]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt help-requests $ARGUMENTS` and relay the lines; on exit 16 give the user each Live page link with its reason and deadline, then run the printed re-run: line; on exit 12 run the printed re-run: line.

See the citt skill for every option and the exit codes. Never read or print the token.
