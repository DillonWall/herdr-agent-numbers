#!/usr/bin/env bash
# Drives renumber.sh with a fake herdr on PATH, so nothing touches a real session.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1));
  echo "FAIL: $3"; echo "  want: $2"; echo "  got:  $1"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# Fake herdr: `api snapshot` prints whatever snapshot the current case set up,
# everything else logs its argv (and can be told to fail).
cat > "$tmp/bin/herdr" <<FAKE
#!/usr/bin/env bash
if [ "\$1" = "api" ] && [ "\$2" = "snapshot" ]; then cat "$tmp/snapshot.json"; exit 0; fi
echo "\$@" >> "$tmp/calls.log"
if [ -n "\${FAKE_FAIL:-}" ]; then exit 1; fi
FAKE
chmod +x "$tmp/bin/herdr"
# HERDR_BIN_PATH is set in every pane herdr spawns, and renumber.sh prefers it over
# PATH -- so it must be pointed at the fake too, or this test writes to the live session.
export PATH="$tmp/bin:$PATH" HERDR_BIN_PATH="$tmp/bin/herdr"
# Pin the sort mode so the suite does not read the developer's own herdr config.
export AGENT_NUMBERS_SORT=priority

# publish <pane=num,...> -- builds a snapshot whose panes carry those num tokens.
# An empty spec means no pane has been numbered yet, which is also what a restarted
# server looks like: the tokens live in its memory and die with it.
publish() {
  jq --arg spec "$1" '
    ($spec | if . == "" then [] else split(",") end
      | map(split("=") | {key: .[0], value: {num: .[1]}}) | from_entries) as $tok
    | .result.snapshot.panes = (.result.snapshot.agents
        | map({pane_id, agent: "claude"}
              + (if $tok[.pane_id] then {tokens: $tok[.pane_id]} else {} end)))
  ' "$DIR/fixtures/idle-only.json" > "$tmp/snapshot.json"
}

# Priority order for idle-only.json is w1:p1=1, w2:p1=2, w1:p2=3.

# Nothing published yet: every agent gets numbered.
publish ""; : > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "3" "unnumbered panel publishes all three"
assert_eq "$(grep -c 'w1:p1 --source agent-numbers --token num=1' "$tmp/calls.log")" "1" "p1 gets 1"
assert_eq "$(grep -c 'w2:p1 --source agent-numbers --token num=2' "$tmp/calls.log")" "1" "w2:p1 gets 2"
assert_eq "$(grep -c 'w1:p2 --source agent-numbers --token num=3' "$tmp/calls.log")" "1" "p2 gets 3"

# Already correct: nothing is rewritten. This is the common case -- most events do
# not reorder anything, and a no-op must stay silent.
publish "w1:p1=1,w2:p1=2,w1:p2=3"; : > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "0" "correct panel writes nothing"

# One pane drifted: only that pane is corrected. Reading the live token back is what
# makes this self-healing -- a cache would have called this pane already-published.
publish "w1:p1=1,w2:p1=9,w1:p2=3"; : > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "1" "only the drifted pane is rewritten"
assert_eq "$(grep -c 'w2:p1 --source agent-numbers --token num=2' "$tmp/calls.log")" "1" "and it is corrected to 2"

# A server restart drops every token. No restart detection is needed: the tokens are
# simply absent, so they all differ and all get republished.
publish ""; : > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "3" "restart republishes all three"

# Partially numbered, e.g. an agent that appeared after the last run.
publish "w1:p1=1,w2:p1=2"; : > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "1" "a new agent is numbered on its own"
assert_eq "$(grep -c 'w1:p2 --source agent-numbers --token num=3' "$tmp/calls.log")" "1" "and gets the free ordinal"

# The sort mode reaches order.jq: spaces mode numbers the same agents differently,
# following the snapshot's array order instead of the status ranking.
publish ""; : > "$tmp/calls.log"
AGENT_NUMBERS_SORT=spaces bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'w1:p2 --source agent-numbers --token num=2' "$tmp/calls.log")" "1" "spaces: p2 gets 2"
assert_eq "$(grep -c 'w2:p1 --source agent-numbers --token num=3' "$tmp/calls.log")" "1" "spaces: w2:p1 gets 3"

# Dry run prints what it would do and touches nothing.
publish ""; : > "$tmp/calls.log"
AGENT_NUMBERS_DRY_RUN=1 bash "$DIR/../renumber.sh" > "$tmp/dry.out"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "0" "dry run calls nothing"
assert_eq "$(grep -c 'report-metadata' "$tmp/dry.out")" "3" "dry run prints what it would do"

# A failed write is reported, and every write is still attempted so one bad pane
# cannot strand the rest. Nothing is cached, so the next event simply retries.
publish ""; : > "$tmp/calls.log"
FAKE_FAIL=1 bash "$DIR/../renumber.sh" 2>/dev/null
assert_eq "$?" "1" "a failed write makes the run fail"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "3" "every write is still attempted"

: > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "3" "the next run retries the failed writes"

echo "--- test_renumber.sh: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
