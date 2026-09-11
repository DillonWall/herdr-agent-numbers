#!/usr/bin/env bash
# Prints the ordering this plugin computes, alongside the number actually published
# to each pane, so both can be diffed against the rendered agents panel.
#
# Priority order is derived from the server snapshot; client-side completion
# acknowledgement can produce a different visible order. See README limitations.
set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="$("$here/sort-mode.sh")"
snap="$("$herdr" api snapshot)"
want="$(printf '%s\n' "$snap" | jq -r --arg mode "$mode" -f "$here/order.jq")"

echo "agent_panel_sort = \"$mode\""
if [ "$mode" = "priority" ]; then
  echo "(server-derived sort -- client completion acknowledgement can change visible order)"
else
  echo "(snapshot array order, read directly -- no inference)"
fi
echo

# One pass: join the computed ordering onto the agents and their published tokens.
# PUB is what the pane actually carries; it differs from NUM only between a reorder
# and the write that follows it, or if a write failed.
printf '%s\n' "$snap" | jq -r --arg want "$want" '
  ($want | split("\n") | map(select(length > 0) | split("\t"))
         | map({key: .[0], value: .[1]}) | from_entries)            as $ord
  | (.result.snapshot.panes | map({key: .pane_id, value: .tokens.num}) | from_entries) as $pub
  | [ .result.snapshot.agents[]
      | select($ord[.pane_id] != null)
      | { num: $ord[.pane_id], pub: ($pub[.pane_id] // "-"),
          pane: .pane_id, status: .agent_status,
          seq: .state_change_seq, name: .terminal_title_stripped } ]
  | sort_by(.num | tonumber)
  | (["NUM","PUB","PANE","STATUS","SEQ","NAME"],
     (.[] | [.num, (if .pub == .num then "ok" else .pub end),
             .pane, .status, (.seq | tostring), .name]))
  | @tsv' | awk -F'\t' '{printf "%-4s %-5s %-10s %-9s %-6s %s\n", $1, $2, $3, $4, $5, $6}'

echo
echo "Compare NUM top-to-bottom against the agents panel. A mismatch under \"priority\""
echo "may reflect client-specific done/idle state -- see the README."
echo "A mismatch under \"spaces\" means the snapshot array order is not the panel order."
echo "A PUB other than \"ok\" means a write has not landed; re-run renumber."
