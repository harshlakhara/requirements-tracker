#!/usr/bin/env bash
# Installs 3 macOS launchd agents (paths auto-filled for this folder):
#   com.tracker.local  - serves the app at http://127.0.0.1:8080 (always on)
#   com.tracker.sync   - runs sync-jira.sh at :07 every hour (Mon-Fri 09-19 gating is in the script)
#   com.tracker.open   - (optional, --open-at-login) opens the app window at login
# Usage: ./install.sh [--open-at-login]      Remove with: ./uninstall.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
PY="$(command -v python3 || true)"; [ -n "$PY" ] || { echo "python3 not found"; exit 1; }
[ -f "$HOME/.tracker.env" ] || [ -f "$DIR/.tracker.env" ] || echo "⚠ No ~/.tracker.env yet - copy .tracker.env.example there and fill it in (see README)."
chmod +x "$DIR/sync-jira.sh" "$DIR/open-app.sh"
mkdir -p "$AGENTS"

for t in local sync open; do
  [ "$t" = open ] && [ "${1:-}" != "--open-at-login" ] && continue
  out="$AGENTS/com.tracker.$t.plist"
  sed -e "s#__DIR__#$DIR#g" -e "s#__PYTHON__#$PY#g" "$DIR/launchd/com.tracker.$t.plist" > "$out"
  launchctl bootout "gui/$(id -u)/com.tracker.$t" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$out"
  echo "loaded com.tracker.$t"
done
echo "Running a first sync..."; "$DIR/sync-jira.sh" || echo "Sync failed - check ~/.tracker.env"
echo "Done. Open http://127.0.0.1:8080"
