---
description: One task with its status, parts, timeline and result link
argument-hint: ID [--cancel] [--watch]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt task $ARGUMENTS` and relay the output; on exit 12 run the printed re-run: line.

In a scan task, the part of an app that waits for its build states the step and the number of jobs ahead in the NOTE column, such as `In the download queue, 3 ahead; 2 accounts take turns`, `Downloading`, `In the decompile queue, 1 ahead` or `Decompiling`; the note is empty once the part is done.

See the citt skill for every option and the exit codes. Never read or print the token.
