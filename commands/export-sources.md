---
description: Download APKs and decompiled sources
argument-hint: --project NAME --apps A,B
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt export-sources $ARGUMENTS`. On exit 12 run the printed re-run command with --export-id. The files are under ./citt-exports/<project>/sources/.

See the citt skill for every option and the exit codes. Never read or print the token.
