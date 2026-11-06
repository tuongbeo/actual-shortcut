#!/bin/bash
# Cloud-session bootstrap: makes sure every marketplace/plugin declared in
# .claude/settings.json is actually installed. A fresh container does not clone
# marketplaces just because settings.json enables them.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}"
settings=.claude/settings.json
[ -f "$settings" ] || exit 0

for tool in jq claude git; do
  command -v "$tool" >/dev/null || { echo "session-start: '$tool' not found" >&2; exit 1; }
done

# The hash file lives next to the installed plugins, so it vanishes with them
# when a new container keeps the checkout but not ~/.claude/plugins.
hashes="$HOME/.claude/plugins/.session-start.sha256"
if sha256sum --check --status "$hashes" 2>/dev/null; then
  exit 0
fi
# Delete first so a failed install runs again next session.
rm -f "$hashes"
mkdir -p "$(dirname "$hashes")"

failed=0

installed_marketplaces="$(timeout 120 claude plugin marketplace list --json)"
while read -r name; do
  if echo "$installed_marketplaces" | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
    continue
  fi
  repo="$(jq -r --arg n "$name" '.extraKnownMarketplaces[$n].source | select(.source == "github") | .repo' "$settings")"
  if [ -z "$repo" ]; then
    echo "session-start: marketplace '$name' has no github source, skipping" >&2
    failed=1
    continue
  fi
  echo "session-start: adding marketplace $name ($repo)"
  timeout 300 claude plugin marketplace add "$repo" || failed=1
done < <(jq -r '.extraKnownMarketplaces // {} | keys[]' "$settings")

installed_plugins="$(timeout 120 claude plugin list --json)"
while read -r plugin; do
  if echo "$installed_plugins" | jq -e --arg p "$plugin" 'any(.[]; .id == $p)' >/dev/null; then
    continue
  fi
  echo "session-start: installing plugin $plugin"
  timeout 300 claude plugin install "$plugin" || failed=1
done < <(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$settings")

if [ "$failed" -ne 0 ]; then
  echo "session-start: some marketplaces/plugins failed to install; will retry next session" >&2
  exit 1
fi

sha256sum .claude/hooks/session-start.sh "$settings" > "$hashes"
