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

instance_file="$state_dir/instance"

mkdir -p "$state_dir"
[ -f "$state" ] || : > "$state"

# Metadata tokens live in the server's memory and do not survive a restart, but the
# cache cannot tell a restart from a quiet moment -- it would report everything as
# already published and leave the panel unnumbered. The socket is recreated with the
# server, so its inode and mtime identify the instance; a change means republish all.
socket="${HERDR_SOCKET_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock}"
instance="$(stat -c '%i:%Y' "$socket" 2>/dev/null || echo unknown)"
if [ "$(cat "$instance_file" 2>/dev/null || true)" != "$instance" ]; then
  : > "$state"
fi

# The panel order differs completely between herdr's two sort modes, so the active
# one selects which derivation order.jq applies.
mode="$("$here/sort-mode.sh")"

current="$("$herdr" api snapshot | jq -r --arg mode "$mode" -f "$here/order.jq")"

# Write only the panes whose ordinal differs from what we last wrote. comm needs
# sorted input; the ordering itself is already captured in the lines themselves.
changed="$(comm -23 <(printf '%s\n' "$current" | sort) <(sort "$state") || true)"

# The writes are independent, so they go out concurrently -- a full reorder touches
# every agent, and at ~2ms per round trip the sequential version spent most of its
# runtime waiting. The panel reorders from herdr's own state before any of this lands,
# so this shortens a visible lag rather than merely saving CPU.
pids=()
while IFS=$'\t' read -r pane_id num; do
  [ -n "$pane_id" ] || continue
  if [ "$dry" = "1" ]; then
    printf '%s pane report-metadata %s --source agent-numbers --token num=%s\n' "$herdr" "$pane_id" "$num"
  else
    "$herdr" pane report-metadata "$pane_id" --source agent-numbers --token "num=$num" &
    pids+=("$!")
  fi
done <<< "$changed"

# Every write is attempted before any failure is reported, so one bad pane cannot
# strand the rest at stale numbers.
rc=0
for pid in ${pids[@]+"${pids[@]}"}; do
  wait "$pid" || rc=1
done

# Record what we just published, so the next event can diff against it. On a failed
# write the cache is deliberately left alone: recording an ordinal that never landed
# would keep that pane stale until its number happened to change again.
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
if [ "$dry" != "1" ]; then
  printf '%s\n' "$current" > "$state"
  printf '%s\n' "$instance" > "$instance_file"
fi
