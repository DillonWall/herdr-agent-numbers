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
# "priority" (attention queue): no such luck. The sort is REPLICATED from the two
# fields it plausibly uses. `state_change_seq` descending was verified against the
# live panel; the status ranking below is INFERRED. See the spec's Risks section
# and the README's caveat -- run the verify action before trusting these numbers.
# It is an attention queue, so it ranks by who is waiting on YOU: a blocked agent
# wants input, a done agent wants review, a working agent wants nothing yet.
# done-above-working was VERIFIED against the live panel -- with one done at seq 45
# and one working at seq 48, the panel put done first, which neither the original
# guess (working above done) nor plain seq-descending predicts. See the regression
# fixture done-outranks-working.json. blocked's rung is still inferred: no agent was
# blocked during the observation.
def rank: {"blocked":0,"done":1,"working":2,"idle":3}[.] // 4;

[ .result.snapshot.agents[] | {pane_id, agent_status, state_change_seq} ]
| (if $mode == "priority"
   then sort_by([(.agent_status | rank), -(.state_change_seq)])
   else .
   end)
| to_entries[]
| "\(.value.pane_id)\t\(.key + 1)"
