---
description: List the lab addresses and phone numbers of your sessions, or show one number with its texts (numbers as the last 4 digits, codes as their length)
argument-hint: "[--kind all|address|phone] | PHONE_ID [--reveal] | ADDRESS"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt inbox $ARGUMENTS` and relay the lines; give the user the Number page link.

See the citt skill for every option and the exit codes. Never read or print the token. After `--reveal`, tell the user where the codes are (the clipboard or the file path) and never open the file.
