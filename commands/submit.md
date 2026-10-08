---
description: Add apps or a CSV to a research project and queue scans
argument-hint: --project NAME (--csv FILE | --apps A,B | PACKAGE...) [--deep]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt submit $ARGUMENTS`. Relay the counts and the rows not found, then offer `citt status --project NAME --wait`.

See the citt skill for every option and the exit codes. Never read or print the token.
