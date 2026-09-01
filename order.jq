# Derives each agent's 1-based position in herdr's agents panel.
#
# herdr computes an ordinal for spaces and tabs but not for agents, and ships no
# agent_index row token (upstream discussion #2048). The panel order under
# agent_panel_sort = "priority" is therefore REPLICATED here, not read.
#
# Ordering: attention state first, then most-recent state change.
# `state_change_seq` descending was verified against the live panel; the status
# ranking below is INFERRED. See the spec's Risks section.
def rank: {"blocked":0,"working":1,"done":2,"idle":3}[.] // 4;

[ .result.snapshot.agents[] | {pane_id, agent_status, state_change_seq} ]
| sort_by([(.agent_status | rank), -(.state_change_seq)])
| to_entries[]
| "\(.value.pane_id)\t\(.key + 1)"
