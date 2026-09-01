#!/usr/bin/env bash
# Drives renumber.sh with a fake herdr on PATH, so nothing touches a real session.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1));
  echo "FAIL: $3"; echo "  want: $2"; echo "  got:  $1"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# Fake herdr: `api snapshot` prints the fixture, everything else logs its argv.
cat > "$tmp/bin/herdr" <<FAKE
#!/usr/bin/env bash
if [ "\$1" = "api" ] && [ "\$2" = "snapshot" ]; then cat "$DIR/fixtures/idle-only.json"; exit 0; fi
echo "\$@" >> "$tmp/calls.log"
if [ -n "\${FAKE_FAIL:-}" ]; then exit 1; fi
FAKE
chmod +x "$tmp/bin/herdr"
# HERDR_BIN_PATH is set in every pane herdr spawns, and renumber.sh prefers it over
# PATH -- so it must be pointed at the fake too, or this test writes to the live session.
export PATH="$tmp/bin:$PATH" HERDR_BIN_PATH="$tmp/bin/herdr" AGENT_NUMBERS_STATE_DIR="$tmp/state"
# Pin the sort mode so the suite does not read the developer's own herdr config.
export AGENT_NUMBERS_SORT=priority

# First run writes every agent's ordinal.
: > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "3" "first run writes all three"
assert_eq "$(grep -c 'num=1' "$tmp/calls.log")" "1" "writes ordinal 1"
assert_eq "$(grep -c 'w1:p1 --source agent-numbers --token num=1' "$tmp/calls.log")" "1" "p1 gets 1"
assert_eq "$(grep -c 'w2:p1 --source agent-numbers --token num=2' "$tmp/calls.log")" "1" "p3 gets 2"

# Second run is a no-op: panes do not expose their tokens, so the state cache is
# the only way to avoid rewriting unchanged values on every event.
: > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "0" "second run writes nothing"

# A changed ordering writes only what moved.
rm -rf "$tmp/state"
: > "$tmp/calls.log"
AGENT_NUMBERS_DRY_RUN=1 bash "$DIR/../renumber.sh" > "$tmp/dry.out"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "0" "dry run calls nothing"
assert_eq "$(grep -c 'report-metadata' "$tmp/dry.out")" "3" "dry run prints what it would do"

# The sort mode reaches order.jq: spaces mode numbers the same fixture differently,
# following the snapshot's array order instead of the status ranking.
rm -rf "$tmp/state"
: > "$tmp/calls.log"
AGENT_NUMBERS_SORT=spaces bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'w1:p2 --source agent-numbers --token num=2' "$tmp/calls.log")" "1" "spaces: p2 gets 2"
assert_eq "$(grep -c 'w2:p1 --source agent-numbers --token num=3' "$tmp/calls.log")" "1" "spaces: w2:p1 gets 3"

# Switching mode against a warm cache rewrites exactly the panes that moved. Under
# priority w1:p2 was 3 and w2:p1 was 2; both swap, while w1:p1 stays 1.
: > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "2" "mode switch rewrites only the two that moved"
assert_eq "$(grep -c 'w1:p1' "$tmp/calls.log")" "0" "mode switch leaves the unmoved pane alone"

# Metadata tokens are in-memory and die with the herdr server, but the cache would
# happily report "already published" and write nothing -- leaving the panel unnumbered
# until an ordinal happened to move. A new server instance must invalidate the cache.
sock="$tmp/herdr.sock"; : > "$sock"
export HERDR_SOCKET_PATH="$sock"
rm -rf "$tmp/state"
: > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "3" "restart: first run publishes all three"

: > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "0" "restart: same instance stays quiet"

# A restarted server means a new socket inode; the tokens it held are gone.
rm -f "$sock"; : > "$sock"
: > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "3" "restart: new instance republishes all three"

# A failed write must not be recorded as published, or that pane keeps its stale
# number until its ordinal happens to move again. The run reports failure and the
# cache stays untouched, so the next event retries the whole set.
rm -rf "$tmp/state"
: > "$tmp/calls.log"
FAKE_FAIL=1 bash "$DIR/../renumber.sh" 2>/dev/null
assert_eq "$?" "1" "a failed write makes the run fail"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "3" "every write is still attempted"

: > "$tmp/calls.log"
bash "$DIR/../renumber.sh"
assert_eq "$(grep -c 'report-metadata' "$tmp/calls.log")" "3" "the next run retries rather than trusting a poisoned cache"

echo "--- test_renumber.sh: $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
