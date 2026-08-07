---
description: Connect your CITT account so submit, scan, and report work
allowed-tools: Bash, Read
---

Connect the user's CITT account to this machine.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt auth`. It prints a verification URL and a user code to stderr. Show both to the user and tell them to open the URL, sign in to their CITT Developer or Researcher account, and click Authorize. The command polls until they finish, then stores the token in the system keyring or a 0600 file. Wait for it to exit 0 before doing anything else. Never ask the user to paste a token, and never read the token file.

See the `citt` skill for the full auth reference.
