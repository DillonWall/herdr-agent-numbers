#!/usr/bin/env bash
# Tests the ordering derivation in isolation, against fixture snapshots, in both
# of herdr's agent_panel_sort modes.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0

run() { # run <mode> <fixture> <field>
  jq -r --arg mode "$1" -f "$DIR/../order.jq" < "$DIR/fixtures/$2" | cut -f"$3" | tr '\n' ' ' | sed 's/ $//'
}

check() { # check <name> <mode> <fixture> <expected-pane-id-order>
  local name="$1" got; got="$(run "$2" "$3" 1)"
  if [ "$got" = "$4" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; echo "  want: $4"; echo "  got:  $got"; fi
}

check_numbers() { # check_numbers <name> <mode> <fixture> <expected-ordinals>
  local name="$1" got; got="$(run "$2" "$3" 2)"
  if [ "$got" = "$4" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; echo "  want: $4"; echo "  got:  $got"; fi
}

check_ack() { # check_ack <name> <fixture> <ack-map-json> <expected-pane-id-order> [fixture-filter]
  local name="$1" got
  got="$(jq "${5:-.}" "$DIR/fixtures/$2" | jq -r --arg mode priority --argjson ack "$3" -f "$DIR/../order.jq" \
    | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" = "$4" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; echo "  want: $4"; echo "  got:  $got"; fi
}

# --- priority mode: status rank first, then state_change_seq descending. ---

# The live-verified case: all idle, ordered by state_change_seq descending.
check "idle-only order" priority idle-only.json "w1:p1 w2:p1 w1:p2"
check_numbers "idle-only ordinals" priority idle-only.json "1 2 3"

# The inferred case: status rank first, then seq descending within a status.
check "mixed-status order" priority mixed-status.json "w1:pBlocked w1:pDone w1:pWorkB w1:pWorkA w1:pIdle"
check_numbers "mixed-status ordinals" priority mixed-status.json "1 2 3 4 5"

# Regression: taken from the live panel. done outranks working even though the
# working agent has the HIGHER seq, so neither the original ranking nor plain
# seq-descending reproduces this. Under spaces the array order still wins.
check "done outranks working" priority done-outranks-working.json "w2:p4 w2:p3"
check "spaces ignores the ranking" spaces done-outranks-working.json "w2:p3 w2:p4"

# Agents past the ninth are still numbered; focus_agent only binds 1-9 but truncating
# the display would misrepresent the panel.
check_numbers "eleven agents all numbered" priority many-agents.json "1 2 3 4 5 6 7 8 9 10 11"

# --- spaces mode: the snapshot's agent array is ALREADY the panel order. ---

# Verified live: agents[] arrives grouped by workspace, ascending pane within one,
# identical to the panes array. So spaces mode reads the order instead of deriving it.
check "spaces keeps snapshot order" spaces idle-only.json "w1:p1 w1:p2 w2:p1"
check_numbers "spaces ordinals" spaces idle-only.json "1 2 3"

# The same fixture the priority sort reshuffles heavily -- proof spaces mode passes
# the array through rather than coincidentally agreeing with a sort.
check "spaces ignores status entirely" spaces mixed-status.json \
  "w1:pIdle w1:pDone w1:pWorkA w1:pBlocked w1:pWorkB"
check_numbers "spaces numbers all eleven" spaces many-agents.json "1 2 3 4 5 6 7 8 9 10 11"

# An unset or unknown mode must not silently produce a priority ordering; herdr's
# own default is spaces.
check "unknown mode falls back to spaces" bogus mixed-status.json \
  "w1:pIdle w1:pDone w1:pWorkA w1:pBlocked w1:pWorkB"

# --- priority mode with an ack map: the client's own idle/done projection. ---

# herdr's client shows an idle or done agent as done until its latest state change
# has been on screen, and sorts on that. The ack map is the last seq seen per pane.

# Regression, from the live panel: connectors (seq 5) and Static video (seq 6)
# finished off screen, so they show done and outrank idle agents with higher seqs.
check_ack "unacknowledged completions show as done" unacknowledged-completions.json \
  '{"wC:p6":10,"wC:p8":4,"wC:p9":8,"wC:pB":5,"wD:p1":9}' "wC:p6 wC:pB wC:p8 wD:p1 wC:p9"

# An agent that has never been on screen has no ack at all, which also means done.
check_ack "an agent with no ack shows as done" unacknowledged-completions.json \
  '{"wC:p6":10,"wC:p9":8,"wC:pB":6,"wD:p1":9}' "wC:p6 wC:p8 wD:p1 wC:p9 wC:pB"

# Once seen, the client shows even the server's own done as idle.
check_ack "an acknowledged server done shows as idle" done-outranks-working.json \
  '{"w2:p3":48,"w2:p4":45}' "w2:p3 w2:p4"

# Regression: restored on startup after the record began. Their seqs moved past the
# ack, but detection is no completion (no completion_seq), so herdr 0.9.2+ shows them
# idle in seq order. Only wC:p9 finished work.
restored='.result.snapshot.version = "0.9.3"
  | .result.snapshot.agents |= map(if .pane_id == "wC:p9" then . else del(.completion_seq) end)'
check_ack "restored agents without a completion stay idle" unacknowledged-completions.json \
  '{"wC:p6":10}' "wC:p6 wC:p9 wD:p1 wC:pB wC:p8" "$restored"

# herdr 0.9.0 and 0.9.1 had no completion_seq and showed any unseen change as done.
check_ack "0.9.1 shows any unacknowledged change as done" unacknowledged-completions.json \
  '{"wC:p6":10,"wC:p9":8}' "wC:p6 wD:p1 wC:pB wC:p8 wC:p9" \
  '.result.snapshot.version = "0.9.1" | .result.snapshot.agents[] |= del(.completion_seq)'

# Only idle and done are projected; working and blocked keep their rank.
check_ack "an empty ack map leaves working and blocked alone" mixed-status.json \
  '{}' "w1:pBlocked w1:pIdle w1:pDone w1:pWorkB w1:pWorkA"

echo "--- test_order.sh: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
