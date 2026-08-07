---
description: Claim an app you own via a code emailed to the store contact
argument-hint: <package-id>
allowed-tools: Bash
---

Claim ownership of an app the user owns.

Package id: $ARGUMENTS

Warning to give the user first: running this sends a one-time code to the app's store-listed contact email. Confirm they can access that inbox before proceeding.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt claim <package-id>`. It emails the code, shows the masked address and expiry, and prompts for the code at stdin. Relay the masked address to the user, ask them to read the code from the email, and let them enter it. Do not store or repeat the code. To check state without sending anything, run `${CLAUDE_PLUGIN_ROOT}/scripts/citt claim --status <package-id>`. Needs an account, so run `/citt:auth` first if it fails.
