#!/usr/bin/env bash
# Prints the ordering this plugin computes, with the inputs it derived it from, so
# it can be diffed by eye against the rendered agents panel.
#
# It matters most under agent_panel_sort = "priority", where the ordering is
# REPLICATED rather than read and the status ranking is inferred. Run it with agents
# actually blocked or working and compare against the sidebar before trusting the
# numbers. Under "spaces" the order comes straight from the snapshot's array order,
# so this is a sanity check rather than a hypothesis test.
set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="$("$here/sort-mode.sh")"
snap="$("$herdr" api snapshot)"

echo "agent_panel_sort = \"$mode\""
if [ "$mode" = "priority" ]; then
  echo "(replicated sort -- the status ranking is INFERRED; a mismatch below means it is wrong)"
else
  echo "(snapshot array order, read directly -- no inference)"
fi
echo

printf '%-4s %-10s %-9s %-6s %s\n' 'NUM' 'PANE' 'STATUS' 'SEQ' 'NAME'
printf '%s\n' "$snap" | jq -r --arg mode "$mode" -f "$here/order.jq" | while IFS=$'\t' read -r pane_id num; do
  printf '%s\n' "$snap" | jq -r --arg p "$pane_id" --arg n "$num" '
    .result.snapshot.agents[] | select(.pane_id == $p)
    | [$n, .pane_id, .agent_status, (.state_change_seq|tostring), .terminal_title_stripped]
    | @tsv' | awk -F'\t' '{printf "%-4s %-10s %-9s %-6s %s\n", $1, $2, $3, $4, $5}'
done

echo
echo "Compare top-to-bottom against the agents panel. A mismatch under \"priority\""
echo "means the inferred status ranking in order.jq is wrong -- see the README."
echo "A mismatch under \"spaces\" means the snapshot array order is not the panel order."
