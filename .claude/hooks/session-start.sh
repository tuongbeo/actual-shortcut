#!/bin/bash
# Cloud-session bootstrap with two independent steps. Each one is skipped when
# its inputs are unchanged since its last successful run, and a failed step
# leaves no hash file so the next session retries it.
#   1. Claude Code marketplaces/plugins declared in .claude/settings.json
#   2. npm dependencies from package.json (shortcutkit)
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}"

failed=0

# --- 1. Plugins ---------------------------------------------------------
# A fresh container does not clone marketplaces just because settings.json
# enables them. The hash file lives next to the installed plugins, so it
# vanishes with them when a new container keeps the checkout but not
# ~/.claude/plugins.
settings=.claude/settings.json
plugin_hashes="$HOME/.claude/plugins/.session-start.sha256"
if [ -f "$settings" ] && ! sha256sum --check --status "$plugin_hashes" 2>/dev/null; then
  rm -f "$plugin_hashes"
  mkdir -p "$(dirname "$plugin_hashes")"
  plugin_failed=0

  for tool in jq claude git; do
    command -v "$tool" >/dev/null || { echo "session-start: '$tool' not found" >&2; plugin_failed=1; }
  done

  if [ "$plugin_failed" -eq 0 ]; then
    installed_marketplaces="$(timeout 120 claude plugin marketplace list --json)" || plugin_failed=1
    installed_plugins="$(timeout 120 claude plugin list --json)" || plugin_failed=1
  fi

  if [ "$plugin_failed" -eq 0 ]; then
    while read -r name; do
      if echo "$installed_marketplaces" | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
        continue
      fi
      repo="$(jq -r --arg n "$name" '.extraKnownMarketplaces[$n].source | select(.source == "github") | .repo' "$settings")"
      if [ -z "$repo" ]; then
        echo "session-start: marketplace '$name' has no github source, skipping" >&2
        plugin_failed=1
        continue
      fi
      echo "session-start: adding marketplace $name ($repo)"
      timeout 300 claude plugin marketplace add "$repo" || plugin_failed=1
    done < <(jq -r '.extraKnownMarketplaces // {} | keys[]' "$settings")

    while read -r plugin; do
      if echo "$installed_plugins" | jq -e --arg p "$plugin" 'any(.[]; .id == $p)' >/dev/null; then
        continue
      fi
      echo "session-start: installing plugin $plugin"
      timeout 300 claude plugin install "$plugin" || plugin_failed=1
    done < <(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$settings")
  fi

  if [ "$plugin_failed" -eq 0 ]; then
    sha256sum .claude/hooks/session-start.sh "$settings" > "$plugin_hashes"
  else
    echo "session-start: plugin setup failed; will retry next session" >&2
    failed=1
  fi
fi

# --- 2. npm dependencies ------------------------------------------------
# Lifecycle scripts stay off: shortcutkit ships prebuilt and needs none.
npm_hashes=node_modules/.session-start.sha256
if [ -f package.json ] && ! sha256sum --check --status "$npm_hashes" 2>/dev/null; then
  rm -f "$npm_hashes"
  if ! command -v npm >/dev/null; then
    echo "session-start: 'npm' not found" >&2
    failed=1
  elif npm install --ignore-scripts --no-audit --no-fund; then
    sha256sum .claude/hooks/session-start.sh package.json package-lock.json > "$npm_hashes" || rm -f "$npm_hashes"
  else
    echo "session-start: npm install failed; will retry next session" >&2
    failed=1
  fi
fi

exit "$failed"
