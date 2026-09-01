#!/usr/bin/env bash
# Prints herdr's active agent_panel_sort mode: "spaces" or "priority".
#
# The panel order differs completely between the two, so the plugin has to know
# which one is in force. herdr does not expose it: `herdr api snapshot` carries no
# config, and `herdr config` has no getter. So config.toml is read directly.
#
# The config dir is the socket's parent -- herdr sets HERDR_SOCKET_PATH in every
# pane it spawns, which keeps this correct under a non-default config location.
set -euo pipefail

if [ -n "${AGENT_NUMBERS_SORT:-}" ]; then
  printf '%s\n' "$AGENT_NUMBERS_SORT"
  exit 0
fi

if [ -n "${HERDR_SOCKET_PATH:-}" ]; then
  config_dir="$(dirname "$HERDR_SOCKET_PATH")"
else
  config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
fi
config="$config_dir/config.toml"

mode=""
if [ -f "$config" ]; then
  # Leading '#' excludes herdr's own commented-out default line. agent_panel_sort is
  # only valid under [ui], so an unanchored match cannot collide with another table.
  mode="$(sed -n 's/^[[:space:]]*agent_panel_sort[[:space:]]*=[[:space:]]*"\([a-z]*\)".*/\1/p' "$config" | tail -1)"
fi

# "workspaces" is herdr's documented alias for "spaces". Anything unrecognised --
# including an absent key -- falls back to herdr's own default rather than guessing.
case "$mode" in
  priority) printf 'priority\n' ;;
  *)        printf 'spaces\n' ;;
esac
