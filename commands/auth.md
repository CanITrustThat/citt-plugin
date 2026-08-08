---
description: Connect your CITT account so submit, scan, and report work
allowed-tools: Bash, Read
---

Connect the user's CITT account to this machine. Two steps, no polling gymnastics.

1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt auth --start`. It returns in about a second and prints a single verification URL. Show that URL to the user and tell them to open it, sign in to their CITT Developer or Researcher account, and click Authorize.

2. Then run `${CLAUDE_PLUGIN_ROOT}/scripts/citt auth --wait`. It blocks until they authorize (or the link expires), stores the token in the system keyring or a 0600 file, and prints `authenticated`. If it exits with "still waiting", run `--wait` again to keep waiting.

If `--start` prints `authenticated` instead of a URL, they are already connected. Never ask the user to paste a token, and never read the token file. See the `citt` skill for the full auth reference.
