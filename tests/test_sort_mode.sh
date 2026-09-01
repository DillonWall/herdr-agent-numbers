#!/usr/bin/env bash
# Tests sort-mode detection against synthetic herdr config dirs.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1));
  echo "FAIL: $3"; echo "  want: $2"; echo "  got:  $1"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# mode <config-body> -- builds a config dir and reports the detected mode.
mode() {
  local d; d="$(mktemp -d "$tmp/cfg.XXXXXX")"
  [ "$1" = "__NOFILE__" ] || printf '%s\n' "$1" > "$d/config.toml"
  HERDR_SOCKET_PATH="$d/herdr.sock" bash "$DIR/../sort-mode.sh"
}

assert_eq "$(mode '[ui]
agent_panel_sort = "priority"')" "priority" "explicit priority"

assert_eq "$(mode '[ui]
agent_panel_sort = "spaces"')" "spaces" "explicit spaces"

# herdr ships the key commented out; a commented line must not be read as a setting.
assert_eq "$(mode '[ui]
# agent_panel_sort = "priority"')" "spaces" "commented key falls back to the default"

# herdr documents "workspaces" as an alias for "spaces".
assert_eq "$(mode '[ui]
agent_panel_sort = "workspaces"')" "spaces" "workspaces alias normalises to spaces"

# Nothing configured at all: herdr's own default is "spaces".
assert_eq "$(mode '[ui]
show_agent_labels_on_pane_borders = false')" "spaces" "absent key defaults to spaces"

assert_eq "$(mode __NOFILE__)" "spaces" "missing config file defaults to spaces"

# Explicit override, for testing and for forcing a mode by hand.
assert_eq "$(AGENT_NUMBERS_SORT=priority mode '[ui]
agent_panel_sort = "spaces"')" "priority" "env override wins over the config"

echo "--- test_sort_mode.sh: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
