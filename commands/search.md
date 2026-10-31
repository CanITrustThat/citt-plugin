---
description: Find captured requests across the capture sessions of a date range, inline or as a CSV file
argument-hint: TEXT --days 30 [--project NAME|ID]... [--inside-words] [--inline | --out FILE.csv] [--load-older]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt search $ARGUMENTS`. The range is required: when the arguments give none, add `--days 30` (with `--inside-words`, `--days 1`). Relay the result: the inline table, or the CSV path, row count and preview; read a CSV with a tool to count or group rows. Relay a stderr line about older sessions with its `--load-older` command, and run that command only when the user asks for those sessions. On exit 12, run the printed `re-run:` command. On exit 13, the CSV holds the rows before the search stopped early: relay that the result is incomplete, with the printed next-rows command.

See the citt skill for every option and the exit codes. Never read or print the token.
