#!/usr/bin/env bash
# Tests the ordering derivation in isolation, against fixture snapshots.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0

check() { # check <name> <fixture> <expected-pane-id-order>
  local name="$1" fixture="$2" want="$3" got
  got="$(jq -r -f "$DIR/../order.jq" < "$DIR/fixtures/$fixture" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; echo "  want: $want"; echo "  got:  $got"; fi
}

check_numbers() { # check_numbers <name> <fixture> <expected-ordinals>
  local name="$1" fixture="$2" want="$3" got
  got="$(jq -r -f "$DIR/../order.jq" < "$DIR/fixtures/$fixture" | cut -f2 | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; echo "  want: $want"; echo "  got:  $got"; fi
}

# The live-verified case: all idle, ordered by state_change_seq descending.
check "idle-only order" idle-only.json "w1:p1 w2:p1 w1:p2"
check_numbers "idle-only ordinals" idle-only.json "1 2 3"

# The inferred case: status rank first, then seq descending within a status.
check "mixed-status order" mixed-status.json "w1:pBlocked w1:pWorkB w1:pWorkA w1:pDone w1:pIdle"
check_numbers "mixed-status ordinals" mixed-status.json "1 2 3 4 5"

# Agents past the ninth are still numbered; focus_agent only binds 1-9 but truncating
# the display would misrepresent the panel.
check_numbers "eleven agents all numbered" many-agents.json "1 2 3 4 5 6 7 8 9 10 11"

echo "--- test_order.sh: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
