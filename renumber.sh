#!/usr/bin/env bash
# Publishes each agent's 1-based panel position as a `num` metadata token, which
# ui.sidebar.agents renders via the "$num" row token.
#
# Unlike the equivalent plugin for spaces, this cannot skip unchanged values by
# reading the current token back: the snapshot exposes `tokens` on workspaces but
# NOT on panes or agents. Last-written ordinals are cached in the plugin state dir
# instead, so a burst of status events does not rewrite every pane every time.
set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_dir="${AGENT_NUMBERS_STATE_DIR:-${HERDR_PLUGIN_STATE_DIR:-$HOME/.local/state/herdr-agent-numbers}}"
state="$state_dir/last-order"
dry="${AGENT_NUMBERS_DRY_RUN:-0}"

mkdir -p "$state_dir"
[ -f "$state" ] || : > "$state"

# The panel order differs completely between herdr's two sort modes, so the active
# one selects which derivation order.jq applies.
mode="$("$here/sort-mode.sh")"

current="$("$herdr" api snapshot | jq -r --arg mode "$mode" -f "$here/order.jq")"

# Write only the panes whose ordinal differs from what we last wrote. comm needs
# sorted input; the ordering itself is already captured in the lines themselves.
changed="$(comm -23 <(printf '%s\n' "$current" | sort) <(sort "$state") || true)"

while IFS=$'\t' read -r pane_id num; do
  [ -n "$pane_id" ] || continue
  if [ "$dry" = "1" ]; then
    printf '%s pane report-metadata %s --source agent-numbers --token num=%s\n' "$herdr" "$pane_id" "$num"
  else
    "$herdr" pane report-metadata "$pane_id" --source agent-numbers --token "num=$num"
  fi
done <<< "$changed"

# Record what we just published, so the next event can diff against it.
if [ "$dry" != "1" ]; then printf '%s\n' "$current" > "$state"; fi
