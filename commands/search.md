---
description: Find captured requests across the capture sessions of a date range, inline or as a CSV file
argument-hint: TEXT --days 30 | --query 'QUERY' [--facet FIELD]... | --fields [--project NAME|ID]... [--inside-words] [--inline | --out FILE.csv] [--load-older]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt search $ARGUMENTS`. With TEXT the range is required: when the arguments give none, add `--days 30` (with `--inside-words`, `--days 1`); with `--query` it is optional. Relay a stderr `try:` line as a suggested correction; on exit 2 with two `try:` commands, ask which reading the user means. Relay the result: the inline table, or the CSV path, row count and preview; read a CSV with a tool to count or group rows. Relay a stderr line about older sessions with its `--load-older` command, and run that command only when the user asks for those sessions. On exit 12, run the printed `re-run:` command. On exit 13, the CSV holds the rows before the search stopped early (or the `Searched N of M sessions` line says how much of the range was read): relay that the result is incomplete, with the printed next-rows command. Quote the last line of `--facet` counts with any count.

See the citt skill for every option and the exit codes. Never read or print the token.
