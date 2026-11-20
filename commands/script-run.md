---
description: Run a script version once per session of a capture run that has no script run (input folder, output folder, one run per session)
argument-hint: RUN --script NAME@VERSION [--session S]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt script-run $ARGUMENTS` and relay the lines.

See the citt skill for every option and the exit codes. Never read or print the token.
