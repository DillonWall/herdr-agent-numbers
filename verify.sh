#!/usr/bin/env bash
# Prints the ordering this plugin computes, alongside the number actually published
# to each pane, so both can be diffed against the rendered agents panel.
#
# Priority order follows the client's idle/done view, from the on-screen record
# renumber.sh keeps (ack.jq). ACK is the last seq seen: an idle agent that completed
# work at a SEQ past it shows as done. See README limitations for what the record cannot see.
set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
socket="${HERDR_SOCKET_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock}"
mode="$("$here/sort-mode.sh")"
snap="$("$herdr" api snapshot)"
# The record renumber.sh keeps, brought up to this snapshot but not saved.
state="$(jq -cn '[inputs] | if length == 1 and (.[0] | type) == "object" then .[0] else null end' \
  "$socket.agent-numbers.ack" 2>/dev/null)" || state=null
ack="$(printf '%s\n' "$snap" | jq -c --argjson prev "$state" --arg server "$(ls -id "$socket" 2>/dev/null || true)" \
  -f "$here/ack.jq" | jq -c .ack)"
want="$(printf '%s\n' "$snap" | jq -r --arg mode "$mode" --argjson ack "$ack" -f "$here/order.jq")"

echo "agent_panel_sort = \"$mode\""
if [ "$mode" = "priority" ]; then
  echo "(idle/done as the client shows them: a completion past its ACK ranks as done)"
else
  echo "(snapshot array order, read directly -- no inference)"
fi
echo

# One pass: join the computed ordering onto the agents and their published tokens.
# PUB is what the pane actually carries; it differs from NUM only between a reorder
# and the write that follows it, or if a write failed.
printf '%s\n' "$snap" | jq -r --arg want "$want" --argjson ack "$ack" '
  ($want | split("\n") | map(select(length > 0) | split("\t"))
         | map({key: .[0], value: .[1]}) | from_entries)            as $ord
  | (.result.snapshot.panes | map({key: .pane_id, value: .tokens.num}) | from_entries) as $pub
  | [ .result.snapshot.agents[]
      | select($ord[.pane_id] != null)
      | { num: $ord[.pane_id], pub: ($pub[.pane_id] // "-"),
          pane: .pane_id, status: .agent_status,
          seq: .state_change_seq, ack: ($ack[.pane_id] // "-"), name: .terminal_title_stripped } ]
  | sort_by(.num | tonumber)
  | (["NUM","PUB","PANE","STATUS","SEQ","ACK","NAME"],
     (.[] | [.num, (if .pub == .num then "ok" else .pub end),
             .pane, .status, (.seq | tostring), (.ack | tostring), .name]))
  | @tsv' | awk -F'\t' '{printf "%-4s %-5s %-10s %-9s %-6s %-6s %s\n", $1, $2, $3, $4, $5, $6, $7}'

echo
echo "Compare NUM top-to-bottom against the agents panel. A mismatch under \"priority\""
echo "may reflect client-specific done/idle state -- see the README."
echo "A mismatch under \"spaces\" means the snapshot array order is not the panel order."
echo "A PUB other than \"ok\" means a write has not landed; re-run renumber."
