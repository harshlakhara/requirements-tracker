#!/usr/bin/env bash
# Hourly producer for the Requirements Tracker.
# Pulls Jira issues assigned to you (open) + discovers related GitLab MRs/pipelines,
# writes ./jira-inbox.json (the tracker auto-ingests it), and pings Google Chat on NEW keys.
#
# Credentials live in ~/.tracker.env (see keys below) so scheduled/non-interactive runs work
# (cron and non-interactive shells do NOT read ~/.zshrc).
#   CONFLUENCE_BASE_URL    e.g. https://yoursite.atlassian.net
#   CONFLUENCE_EMAIL       your atlassian login email
#   CONFLUENCE_API_TOKEN   id.atlassian.com/manage-profile/security/api-tokens
#   TRACKER_GITLAB_PROJECT a GitLab group URL or path (a group is fine), e.g. https://host/wog/hpb/...
#   GITLAB_TOKEN           a PAT for that GitLab instance (scopes: api,read_api)
# Optional: GITLAB_HOST (else derived from TRACKER_GITLAB_PROJECT), GCHAT_NOTIFICATION_CHANNEL,
#           TRACKER_JQL (override which Jira issues are pulled). GitLab vars may be omitted entirely.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$HOME/.local/bin:$PATH"

# When launched by the scheduler (--scheduled), only run Mon-Fri 09:00-19:59.
# Manual runs (no flag) always proceed. launchd fires a missed run once on wake.
if [ "${1:-}" = "--scheduled" ]; then
  dow="$(date +%u)"; hr="$(date +%H)"
  if [ "$dow" -gt 5 ] || [ "$hr" -lt 9 ] || [ "$hr" -gt 19 ]; then
    echo "$(date '+%F %T') skipped (outside Mon-Fri 09-19)"; exit 0
  fi
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/jira-inbox.json"
SEEN="$DIR/.jira-seen"

for f in "$HOME/.tracker.env" "$DIR/.tracker.env"; do [ -f "$f" ] && . "$f"; done

: "${CONFLUENCE_BASE_URL:?set CONFLUENCE_BASE_URL in ~/.tracker.env}"
: "${CONFLUENCE_EMAIL:?set CONFLUENCE_EMAIL in ~/.tracker.env}"
: "${CONFLUENCE_API_TOKEN:?set CONFLUENCE_API_TOKEN in ~/.tracker.env}"

# --- GitLab config (dedicated instance; group-level search) ---
GL_RAW="${TRACKER_GITLAB_PROJECT:-}"
if [ -n "${GITLAB_HOST:-}" ]; then GL_HOST="$GITLAB_HOST"
else GL_HOST="$(printf '%s' "$GL_RAW" | sed -nE 's#^https?://([^/]+).*#\1#p')"; fi
GL_GROUP="$(printf '%s' "$GL_RAW" | sed -E 's#^https?://[^/]+/##; s#/+$##')"
GL_ENC="$(printf '%s' "$GL_GROUP" | jq -sRr @uri)"

# --- 1) Jira: open issues assigned to me (new /search/jql endpoint) ---
JQL="${TRACKER_JQL:-assignee = currentUser() AND statusCategory != Done AND sprint in openSprints() ORDER BY updated DESC}"
jira="$(curl -sS -u "$CONFLUENCE_EMAIL:$CONFLUENCE_API_TOKEN" -G \
  --data-urlencode "jql=$JQL" \
  --data-urlencode "maxResults=50" \
  --data-urlencode "fields=summary,status,priority,reporter,labels,duedate" \
  "$CONFLUENCE_BASE_URL/rest/api/3/search/jql")" || { echo "Jira request failed"; exit 1; }

if ! echo "$jira" | jq -e '.issues' >/dev/null 2>&1; then
  echo "Jira query error: $(echo "$jira" | jq -r '(.errorMessages // [.message // "unknown"]) | join("; ")' 2>/dev/null)"
  exit 1
fi

# --- 2) discover GitLab MRs (+latest pipeline) for a Jira key, across the group ---
gitlab_links() { # $1 = jira key -> prints links JSON array
  local key="$1" mrs enriched='[]' mr pid iid pl
  [ -z "$GL_HOST" ] || [ -z "$GL_GROUP" ] && { echo '[]'; return; }
  mrs="$(curl -sS --header "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
    "https://$GL_HOST/api/v4/groups/$GL_ENC/merge_requests?scope=all&state=all&search=$key&in=title,description&per_page=20" 2>/dev/null || echo '[]')"
  echo "$mrs" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo '[]'; return; }
  while read -r mr; do
    [ -z "$mr" ] && continue
    pid="$(echo "$mr" | jq -r '.project_id')"
    iid="$(echo "$mr" | jq -r '.iid')"
    pl="$(curl -sS --header "PRIVATE-TOKEN: ${GITLAB_TOKEN:-}" \
      "https://$GL_HOST/api/v4/projects/$pid/merge_requests/$iid/pipelines?per_page=1" 2>/dev/null | jq '.[0] // empty' 2>/dev/null || true)"
    enriched="$(jq -n --argjson e "$enriched" \
      --argjson mr "$(echo "$mr" | jq '{type:"MR", title:.title, url:.web_url, status:.state}')" \
      --argjson pl "${pl:-null}" \
      '$e + [$mr] + (if $pl and $pl!=null then [{type:"pipeline", title:("pipeline #"+($pl.id|tostring)), url:$pl.web_url, status:$pl.status}] else [] end)')"
  done < <(echo "$mrs" | jq -c '.[]')
  echo "$enriched"
}

tmp="$(mktemp)"
while read -r iss; do
  key="$(echo "$iss" | jq -r '.key')"
  links="$(gitlab_links "$key")"
  echo "$iss" | jq -c --argjson links "$links" --arg base "$CONFLUENCE_BASE_URL" '{
    key: .key,
    title: .fields.summary,
    summary: .fields.summary,
    status: (.fields.status.name // ""),
    priority: (.fields.priority.name // ""),
    requester: (.fields.reporter.displayName // ""),
    labels: (.fields.labels // []),
    duedate: (.fields.duedate // ""),
    url: ($base + "/browse/" + .key),
    links: $links
  }'
done < <(echo "$jira" | jq -c '.issues[]') | jq -s '.' > "$tmp"

# --- 3) write inbox ---
gen="$(date "+%Y-%m-%dT%H:%M:%S")"
jq -n --arg gen "$gen" --slurpfile issues "$tmp" '{generatedAt: $gen, issues: $issues[0]}' > "$OUT"
rm -f "$tmp"
count="$(jq '.issues | length' "$OUT")"

# --- 4) GChat alert on NEW keys (dedup via .jira-seen so we don't spam hourly) ---
touch "$SEEN"
newkeys=""
while read -r k; do
  [ -z "$k" ] && continue
  grep -qxF "$k" "$SEEN" || { newkeys="$newkeys $k"; echo "$k" >> "$SEEN"; }
done < <(jq -r '.issues[].key' "$OUT")

if [ -n "${newkeys// /}" ] && [ -n "${GCHAT_NOTIFICATION_CHANNEL:-}" ]; then
  msg="🆕 New Jira assigned to you:${newkeys} — added to your tracker (http://127.0.0.1:8080)."
  curl -sS -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg t "$msg" '{text:$t}')" "$GCHAT_NOTIFICATION_CHANNEL" >/dev/null 2>&1 || true
fi

echo "Wrote $OUT — $count open issue(s).${newkeys:+ NEW:$newkeys}"
