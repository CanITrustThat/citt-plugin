---
description: Find an app in the public index by name or package id
argument-hint: <query> [--platform android|ios] [--limit N]
allowed-tools: Bash
---

Search the public app index. Public, so no account is needed.

Query: $ARGUMENTS

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt search "<query>"`, passing through `--platform` (android or ios) and `--limit` (1 to 50) if the user gave them. It prints an array of matches with package id, developer, and whether each is already scanned. When there are several close matches, list them and let the user pick the right package id, then move on to `/citt:results` or `/citt:scan`.
