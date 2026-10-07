# Keeps this plugin's copy of herdr's client record of what has been on screen: for
# each agent pane, the last state_change_seq the client has shown. order.jq ranks
# idle/done from it, since that is what the client's priority panel sorts on.
#
# Mirrors herdr 0.9.x's EndpointAgentPresentation (src/client/shell/endpoint_agent_state.rs):
# - a new server starts a baseline in which every agent present counts as seen;
# - agents that have gone are forgotten, so one that comes back starts unseen;
# - panes on screen are acknowledged up to their current seq, and an ack only rises.
#   On screen is the focused tab, or only its focused pane when zoomed (src/ui/panes.rs).
#
# The client also skips acknowledging while its terminal window is unfocused, and
# restarts its baseline whenever it attaches. The API shows neither, so neither is
# mirrored. See README limitations.
#
# Input: `herdr api snapshot`. Args: `--argjson prev <previous output, or null>` and
# `--arg server <identity of the server socket>`. Output: {server, ack}.
.result.snapshot as $s
| ($s.agents | map({key: .pane_id, value: .state_change_seq}) | from_entries) as $seq
| (if ($prev | type) == "object" and $prev.server == $server
   then ($prev.ack // {}) | with_entries(select($seq[.key] != null))
   else $seq
   end) as $kept
| [ $s.layouts[]? | select(.tab_id == $s.focused_tab_id)
    | if .zoomed then .focused_pane_id else .panes[]?.pane_id end
    | select(type == "string") | select($seq[.] != null) ] as $shown
| {server: $server,
   ack: (reduce $shown[] as $pane ($kept; .[$pane] = ([.[$pane] // 0, $seq[$pane]] | max)))}
