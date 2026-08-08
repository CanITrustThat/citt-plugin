# citt

A Claude Code plugin that connects Claude Code to [canitrustthat.com](https://canitrustthat.com), a security and privacy trust analysis service for Android and iOS apps. Ask Claude in plain language; it runs the `citt` CLI for you.

## Quick start

Run these in Claude Code, in order:

```
/plugin marketplace add CanITrustThat/citt-plugin   # 1. register the marketplace
/plugin install citt@citt                           # 2. install the plugin
/reload-plugins                                     # 3. load it without restarting
/citt:auth                                          # 4. sign in (opens a browser link)
/citt:submit com.spotify.music                      # 5. run your first analysis
```

Step 4 is required before `submit`, `rescan`, `scan`, `result`, `report`, `mine`, and `claim`. It prints a link, you sign in and click Authorize once, and the token is stored on your machine. The commands `search`, `status`, and `results` work without signing in, so you can skip straight to step 5 with those.

Prefer the terminal? Steps 1 and 2 are one line, then auth from inside Claude Code:
```
claude plugin marketplace add CanITrustThat/citt-plugin && claude plugin install citt@citt
```

## Commands

- `auth`: sign in via browser device flow, same idea as `gh auth login`
- `submit`: full trust analysis of one app or many. Takes package IDs, store URLs, or a CSV file. Returns the public scorecard with a letter grade. Reuses any scan from the last 90 days
- `rescan`: force a fresh full scan of an app that already exists. Use this, not `submit`, when results are stale (submit reuses recent scans). Owner or admin; Researcher plans can rescan any app
- `scan`: custom prompt scan against one app. Ask a focused question and Claude writes the prompt. Private, with no public scorecard
- `result`: fetch a custom scan's answer by scan id
- `status`: scan status and score for any app
- `results`: full public scorecard data for any app
- `report`: detailed private report for an app you own, in markdown
- `mine`: apps you've submitted, with their latest scores
- `search`: search the public app index by name or package id
- `claim`: claim ownership of an app you own. A code is emailed to the store contact address to verify
- `whoami` shows the signed-in account. `logout` removes the stored token

In Claude Code every command is also a slash command: `/citt:auth`, `/citt:scan`, `/citt:submit`, and so on. Type `/citt:` to see the full list.

## First scan

The first ever scan of an app has to download and decompile it first. 
Download takes a few minutes. 
iOS IPA decryption can take 5-10 min. 
iOS decompilation can take anywhere between 30min and 3-4h. Android takes ~15-30 min.
The 9 stages agentic AI pipeline can take between 20 min and 2h. Depending on the app size. 
Repeat custom scans or full scans for the same app will reuse already existing assets. 
A rescan must be requested for a fresh file download

## Auth

In Claude Code, run `/citt:auth`. Claude prints a link; sign in and click Authorize once. The token is stored in the system keyring or a 0600 file. If the plugin is installed but not connected, a fresh session reminds you to run it. The public commands (`search`, `status`, `results`) work without an account.

## Requirements

- `submit`, `rescan`, `scan`, `result`, `report`, `mine`, and `claim` need a Developer or Researcher account ([canitrustthat.com](https://canitrustthat.com)).
- A custom `scan` against an app you don't own needs the Researcher plan. Developer covers your own apps and brand new targets.
- `search`, `status`, and `results` read the public index and need no account.

## CSV format

`submit` reads a file with a `package_id` column, one app per row:
```csv
package_id
com.spotify.music
com.instagram.android
com.whatsapp
```
Store URLs and a bare package id passed directly also work.
