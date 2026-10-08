---
description: List a project's findings
argument-hint: --project NAME [--family F] [--severity S] [--all] [--csv]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt findings $ARGUMENTS`. Subjects are printed as found, keys included.

See the citt skill for every option and the exit codes. Never read or print the token.
