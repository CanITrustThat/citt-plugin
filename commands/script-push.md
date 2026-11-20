---
description: Check, pack and upload a script folder as the next version of a customer script
argument-hint: DIR --project NAME --name NAME [--activate]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt script-push $ARGUMENTS` and relay the lines; on exit 7 relay the reason, the path and the fix line; on exit 12 run the printed re-run: line.

See the citt skill for every option and the exit codes. Never read or print the token.
