#!/usr/bin/env bash
for t in local sync open; do
  launchctl bootout "gui/$(id -u)/com.tracker.$t" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.tracker.$t.plist"
done
echo "Removed tracker launch agents."
