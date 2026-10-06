#!/usr/bin/env bash
# Opens the tracker as a standalone app window once the local server is up.
# Used by the com.tracker.open login agent, and works if you double-click it too.
URL="http://127.0.0.1:8080/"
for _ in $(seq 1 40); do
  /usr/bin/curl -s -o /dev/null "$URL" && break
  sleep 0.5
done
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$CHROME" ]; then
  exec "$CHROME" --app="$URL"
else
  exec /usr/bin/open "$URL"
fi
