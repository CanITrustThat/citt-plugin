---
description: Sign out and delete the stored CITT token
allowed-tools: Bash
---

Sign the user out of CITT.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt logout`. It removes the stored token from the keyring and the 0600 file and exits 0 whether or not a token was present. Confirm to the user that they are signed out, and mention that any account command will ask them to run `/citt:auth` again.
