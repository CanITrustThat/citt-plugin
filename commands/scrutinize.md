---
description: Ask for LLM scrutiny of findings
argument-hint: FINDING_ID... [--project NAME] [--wait]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt scrutinize $ARGUMENTS`. On exit 12 run the printed re-run command.

See the citt skill for every option and the exit codes. Never read or print the token.
