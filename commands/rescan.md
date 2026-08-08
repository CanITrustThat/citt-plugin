---
description: Force a fresh full scan of an existing app (never reuses an old scan)
argument-hint: <package-id> [--platform android|ios] [--private]
allowed-tools: Bash
---

Force a brand-new full scan of an app that already exists in CITT. Use this when the user
wants up-to-date results, not the cached scorecard. Unlike `submit` (which reuses any scan
completed in the last 90 days), rescan always creates a NEW scan and runs the full pipeline.

App to rescan: $ARGUMENTS

Run `${CLAUDE_PLUGIN_ROOT}/scripts/citt rescan <package-id>`, passing `--platform ios` for
iOS apps and `--private` if the user wants a private scan instead of refreshing the public
scorecard (the default is a public refresh). To only check whether the user is allowed to
rescan and how much quota is left, run `${CLAUDE_PLUGIN_ROOT}/scripts/citt rescan --check
<package-id>` first (read-only, never starts a scan).

Who may rescan is decided by the server, not by you, so just run the command and relay the
result. Admins can rescan any app; developers can rescan apps they own; Research and custom
plans can rescan any app (metered against their scan-others quota). On success the command
prints the new scan id and number and queues it: tell the user it is running and poll
`/citt:status <package-id>` for progress. Error meanings: 401 run `/citt:auth`; 403 the
user's plan cannot rescan this app (relay the message verbatim); 429 monthly rescan quota
reached (relay the upgrade hint); 400 bad request.
