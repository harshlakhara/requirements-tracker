<img width="4108" height="2576" alt="image" src="https://github.com/user-attachments/assets/b99b53d4-b818-46ee-a506-ad2fecfa797f" />

# Requirements Tracker

A single-page, no-build personal workspace for feature requirements, notes, todos, pipelines and diagrams (Excalidraw) — with **hourly auto-sync of your assigned Jira tickets** (plus linked GitLab MRs/pipelines).

- Pure static app (`index.html`), installable as a PWA. Data is stored in your **browser's localStorage** (per browser/profile — use the in-app export to back up).
- Jira sync = a shell script writes `jira-inbox.json`; the app polls it every 5 min and merges new/updated tickets.
- macOS (launchd) scheduling is included. On Linux, use cron (see below).

## Quick start (app only)

```bash
python3 -m http.server 8080 --bind 127.0.0.1
# open http://127.0.0.1:8080
```

Needs internet on first load (React/Excalidraw come from unpkg).

## Jira auto-sync setup

**Prereqs:** `curl`, `jq` (`brew install jq`), a Jira Cloud account.

### 1. Create an Atlassian API token
https://id.atlassian.com/manage-profile/security/api-tokens → *Create API token*.

### 2. Create `~/.tracker.env`
```bash
cp .tracker.env.example ~/.tracker.env && chmod 600 ~/.tracker.env
```
Fill in:
```bash
CONFLUENCE_BASE_URL="https://yoursite.atlassian.net"
CONFLUENCE_EMAIL="you@company.com"
CONFLUENCE_API_TOKEN="<token from step 1>"
```
(The `CONFLUENCE_*` names are historical — they're your Jira Cloud credentials; same site/token.)

Optional keys:

| Key | Purpose |
|---|---|
| `TRACKER_JQL` | Override what's synced. Default: `assignee = currentUser() AND statusCategory != Done AND sprint in openSprints() ORDER BY updated DESC` |
| `TRACKER_GITLAB_PROJECT` + `GITLAB_TOKEN` | Group URL + PAT (`api`, `read_api`) → MRs/pipelines mentioning the Jira key are linked on each ticket |
| `GCHAT_NOTIFICATION_CHANNEL` | Google Chat webhook; pinged once per *new* ticket |

### 3. Test it
```bash
./sync-jira.sh
# → Wrote .../jira-inbox.json — 7 open issue(s).
```
Then reload the app, or click **⟳ Jira** in the header.

### 4. Schedule it (macOS)
```bash
./install.sh                    # server on :8080 + hourly sync
./install.sh --open-at-login    # ...also opens the app window at login
./uninstall.sh                  # remove everything
```
This installs launchd agents with paths filled in for wherever you cloned the repo (move the folder → re-run `install.sh`).
Sync runs at minute :07 each hour, **Mon–Fri 09:00–19:59 only** (edit the gate at the top of `sync-jira.sh`). Missed runs fire once on wake.

Logs: `/tmp/tracker-sync.log`, `/tmp/tracker-server.log`.

**Linux / cron alternative:**
```cron
7 9-19 * * 1-5 /path/to/requirements-tracker/sync-jira.sh >> /tmp/tracker-sync.log 2>&1
```
(Serve the folder with any static server, e.g. `python3 -m http.server`.)

## How the sync behaves

- New Jira keys → new requirement + a starter note, tagged `jira`.
- Existing keys → status, link and MR/pipeline info refreshed.
- Tickets that leave the sprint/JQL are removed **only if** auto-imported and untouched by you (`mine` flag unset).
- Deleting an imported ticket in the app stops it from being re-created.

## Files

| File | Role |
|---|---|
| `index.html` | The whole app |
| `sync-jira.sh` | Jira (+GitLab) → `jira-inbox.json` |
| `install.sh` / `uninstall.sh` / `launchd/` | macOS scheduling templates |
| `open-app.sh` | Opens the app as a Chrome app window |
| `sw.js`, `manifest.json`, icons | PWA support |
| `.tracker.env.example` | Credentials template |

`jira-inbox.json`, `.jira-seen` and `.tracker.env` are git-ignored — **never commit credentials or ticket data**.

## Troubleshooting

- **`set CONFLUENCE_BASE_URL in ~/.tracker.env`** → env file missing/unfilled.
- **`Jira query error`** → wrong email/token/site URL, or custom JQL typo.
- **Nothing appears in app** → the app must be served over http (not `file://`); check `jira-inbox.json` exists next to `index.html`.
- **No MR links** → set the two GitLab vars; the token needs access to the group.
