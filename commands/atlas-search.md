---
description: Search the atlas app corpus by package, title or developer
argument-hint: QUERY [--all] [--json]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt atlas-search $ARGUMENTS` and relay the result.

See the citt skill for every option and the exit codes. Needs an atlas-enabled account. Never read or print the token.
