#!/usr/bin/env bash
# Tests ack.jq, the plugin's copy of herdr's client record of which agent state
# changes have been on screen. order.jq ranks idle/done from that record.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0

# snap <focused-tab> <zoomed> -- tab w1:t1 splits w1:p1 (focused) and w1:p2; tab w1:t2
# holds w1:p3 alone. The seqs are p1=5, p2=6, p3=7. <zoomed> applies to w1:t1.
snap() {
  jq -n --arg tab "$1" --argjson zoomed "$2" '{result: {snapshot: {
    focused_tab_id: $tab,
    agents: [
      {pane_id: "w1:p1", state_change_seq: 5},
      {pane_id: "w1:p2", state_change_seq: 6},
      {pane_id: "w1:p3", state_change_seq: 7}],
    layouts: [
      {tab_id: "w1:t1", zoomed: $zoomed, focused_pane_id: "w1:p1",
       panes: [{pane_id: "w1:p1"}, {pane_id: "w1:p2"}]},
      {tab_id: "w1:t2", zoomed: false, focused_pane_id: "w1:p3",
       panes: [{pane_id: "w1:p3"}]}]}}}'
}

check() { # check <name> <snapshot> <previous-record> <expected-ack-map>
  local name="$1" got want
  got="$(printf '%s\n' "$2" | jq -c --argjson prev "$3" --arg server s1 -f "$DIR/../ack.jq" | jq -cS .ack)"
  want="$(printf '%s\n' "$4" | jq -cS .)"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; echo "  want: $want"; echo "  got:  $got"; fi
}

old='{"server":"s1","ack":{"w1:p1":1,"w1:p2":2,"w1:p3":3}}'

# A new server starts a baseline, as the client does for a new boot: every agent
# already present counts as seen, whether or not it is on screen.
check "the first record counts every agent as seen" "$(snap w1:t2 false)" null \
  '{"w1:p1":5,"w1:p2":6,"w1:p3":7}'
check "a different server starts a new baseline" "$(snap w1:t2 false)" \
  '{"server":"s0","ack":{"w1:p1":1}}' '{"w1:p1":5,"w1:p2":6,"w1:p3":7}'

# Only what is on screen is acknowledged; everything else keeps its old seq.
check "the focused tab is acknowledged, others are not" "$(snap w1:t2 false)" "$old" \
  '{"w1:p1":1,"w1:p2":2,"w1:p3":7}'
check "every pane of a split tab is on screen" "$(snap w1:t1 false)" "$old" \
  '{"w1:p1":5,"w1:p2":6,"w1:p3":3}'
check "a zoomed tab shows only its focused pane" "$(snap w1:t1 true)" "$old" \
  '{"w1:p1":5,"w1:p2":2,"w1:p3":3}'

# Agents that have gone are forgotten, so one that returns starts unseen. A new
# agent off screen has no entry until it is shown.
check "a closed agent is forgotten" "$(snap w1:t2 false)" \
  '{"server":"s1","ack":{"w1:p1":1,"w1:p2":2,"w1:p3":3,"w1:p9":4}}' \
  '{"w1:p1":1,"w1:p2":2,"w1:p3":7}'
check "a new agent off screen stays unseen" "$(snap w1:t2 false)" \
  '{"server":"s1","ack":{"w1:p3":3}}' '{"w1:p3":7}'

# The client only ever raises an ack.
check "an ack never moves backwards" "$(snap w1:t2 false)" \
  '{"server":"s1","ack":{"w1:p1":1,"w1:p2":2,"w1:p3":9}}' '{"w1:p1":1,"w1:p2":2,"w1:p3":9}'

echo "--- test_ack.sh: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
