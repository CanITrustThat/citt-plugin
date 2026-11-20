---
description: Make a script version run after each capture run of a project
argument-hint: NAME@VERSION --project NAME [--pending]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt script-activate $ARGUMENTS` and relay the lines.

See the citt skill for every option and the exit codes. Never read or print the token.
