---
description: Make a lab mail address by hand, list your lab addresses, or show one with its emails, codes and links
argument-hint: create [--local PART] [--run ID] [--note TEXT] | list | show ADDRESS
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/skills/citt/scripts/citt mailbox $ARGUMENTS` and relay the lines; give the user the Mailbox page link.

See the citt skill for every option and the exit codes. Never read or print the token.
