---
description: Send feedback to the CITT team, one body of free text (Markdown is recommended)
argument-hint: TEXT | --file PATH | -
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt feedback $ARGUMENTS`.

The feedback is one body of free text; Markdown is recommended. See the citt skill for every option and the exit codes. Never read or print the token.
