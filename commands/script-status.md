---
description: Show the state of a capture run's script runs, one per session, with the reason and next step
argument-hint: RUN [--session S] [--watch]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt script-status $ARGUMENTS` and relay the lines; on exit 12 run the printed re-run: line.

See the citt skill for every option and the exit codes. Never read or print the token.
