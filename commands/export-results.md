---
description: Download the per-app JSON of a project
argument-hint: --project NAME --apps all|A,B
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt export-results $ARGUMENTS`. On exit 12 run the printed re-run command. The files are under ./citt-exports/<project>/results/.

See the citt skill for every option and the exit codes. Never read or print the token.
