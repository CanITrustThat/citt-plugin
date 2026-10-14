---
description: List submissions (scans, questions, captures, exports, native code) with status, progress and times
argument-hint: [--project NAME] [--running] [--failed] [--watch]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt tasks $ARGUMENTS` and relay the table.

See the citt skill for every option and the exit codes. Never read or print the token.
