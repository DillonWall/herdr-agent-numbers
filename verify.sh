#!/usr/bin/env bash
# Prints the ordering this plugin computes, with the inputs it derived it from, so
# it can be diffed by eye against the rendered agents panel.
#
# This exists because the ordering is REPLICATED rather than read: the status
# ranking is inferred and unverified under non-idle states. Run this with agents
# actually blocked or working and compare against the sidebar before trusting the
# numbers.
set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
snap="$("$herdr" api snapshot)"

printf '%-4s %-10s %-9s %-6s %s\n' 'NUM' 'PANE' 'STATUS' 'SEQ' 'NAME'
printf '%s\n' "$snap" | jq -r -f "$here/order.jq" | while IFS=$'\t' read -r pane_id num; do
  printf '%s\n' "$snap" | jq -r --arg p "$pane_id" --arg n "$num" '
    .result.snapshot.agents[] | select(.pane_id == $p)
    | "\($n)    \(.pane_id)    \(.agent_status)   \(.state_change_seq)      \(.terminal_title_stripped)"'
done

echo
echo "Compare top-to-bottom against the agents panel. A mismatch means the"
echo "inferred status ranking in order.jq is wrong -- see the spec's Risks."
