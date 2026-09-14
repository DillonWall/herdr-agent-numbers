# Derives each agent's 1-based position in herdr's agents panel, for whichever
# agent_panel_sort mode is active. Pass it with `jq --arg mode <spaces|priority>`.
#
# herdr computes an ordinal for spaces and tabs but not for agents, and ships no
# agent_index row token (upstream discussion #2048), so the position has to come
# from the snapshot either way.
#
# "spaces" (herdr's default): the agents array ALREADY arrives grouped by workspace
# in ascending pane order -- byte-identical to the panes array. The order is
# therefore READ, not inferred, and this mode carries no risk of being wrong.
#
# "priority": matches herdr 0.9.0's rank and sequence sort. The client ranks its own
# idle/done view rather than the server's: an idle or done agent shows as done until
# its latest state change has been on screen. Pass that view as `--argjson ack`, a
# map of pane_id to the last seq on screen (kept by ack.jq). Without it the
# snapshot's statuses are ranked as given.
def rank: {"blocked":0,"done":1,"working":2,"idle":3}[.] // 4;

# herdr's EndpointAgentPresentation::projected_status, src/client/shell/endpoint_agent_state.rs.
def project($ack):
  if .agent_status == "idle" or .agent_status == "done"
  then .agent_status = (if ($ack[.pane_id] // -1) >= .state_change_seq then "idle" else "done" end)
  else . end;

[ .result.snapshot.agents[] | {pane_id, agent_status, state_change_seq}
  | if $ARGS.named | has("ack") then project($ARGS.named.ack) else . end ]
| (if $mode == "priority"
   then sort_by([(.agent_status | rank), -(.state_change_seq)])
   else .
   end)
| to_entries[]
| "\(.value.pane_id)\t\(.key + 1)"
