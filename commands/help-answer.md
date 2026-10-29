---
description: Answer a bring-me-in help request of a capture run by text
argument-hint: REQUEST "TEXT"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt help-answer $ARGUMENTS` with the text the user gave, and relay the lines; on exit 5 tell the user the printed reason and, when a Live page link is printed, give them the link to take over.

See the citt skill for every option and the exit codes. Never read or print the token.
