---
description: Ask a question about an app build file, store link or package id, or run a custom prompt over a project's apps
argument-hint: (FILE.apk|FILE.ipa|LINK|PACKAGE) "QUESTION" [--wait] | --thread N "QUESTION" | --project NAME --apps all|A,B "QUESTION"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt prompt $ARGUMENTS`. A build file (`.apk`, `.xapk`, `.apks`, `.apkm`, `.ipa`) is uploaded first; on an interruption, run the same command again to resume the upload. With `--wait`, relay the answer, its `path:line` citations and the label. On exit 12 run the printed re-run command. Ask a follow-up with `--thread N`. The `--project` form queues answers as findings with source llm_prompt.

See the citt skill for every option and the exit codes. Never read or print the token.
