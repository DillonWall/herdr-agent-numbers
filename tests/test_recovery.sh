#!/usr/bin/env bash
# Exercise event timing and overlapping processes against a stateful fake API.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export TEST_STATE_DIR="$tmp" HERDR_SOCKET_PATH="$tmp/herdr.sock"
export HERDR_BIN_PATH="$tmp/herdr" AGENT_NUMBERS_SORT=priority
cp "$DIR/fake_herdr.sh" "$HERDR_BIN_PATH"
chmod +x "$HERDR_BIN_PATH"

reset() {
  rm -f "$tmp/read-count" "$tmp/reads.log" "$tmp/calls.log"
  jq '.result.snapshot.panes = (.result.snapshot.agents | map({pane_id, tokens: {}}))' \
    "$DIR/fixtures/idle-only.json" > "$tmp/snapshot.json"
}
correct() {
  local want have
  want="$(jq -r --arg mode priority -f "$DIR/../order.jq" "$tmp/snapshot.json" | sort)"
  have="$(jq -r '.result.snapshot.panes[] | "\(.pane_id)\t\(.tokens.num)"' "$tmp/snapshot.json" | sort)"
  [ "$want" = "$have" ]
}
wait_for_write() {
  local attempt
  for ((attempt=0; attempt<200; attempt++)); do
    [ ! -f "$tmp/write-waiting" ] || return 0
    sleep 0.01
  done
  echo 'fake write did not start' >&2
  return 1
}

# Initial no-op must still recheck: the second snapshot moves the first agent last.
reset
bash "$DIR/../renumber.sh"
rm "$tmp/read-count"
jq '.result.snapshot.agents[0].state_change_seq = 0' "$tmp/snapshot.json" > "$tmp/next-snapshot.json"
bash "$DIR/../renumber.sh"
correct
[ ! -f "$tmp/next-snapshot.json" ]
[ "$(jq '.result.snapshot.agents[0].state_change_seq' "$tmp/snapshot.json")" = 0 ]
echo 'PASS: a reorder after an initial no-op is repaired without another event'

# A failed metadata call recovers in the SAME invocation.
reset
: > "$tmp/fail-once"
bash "$DIR/../renumber.sh"
correct
[ "$(wc -l < "$tmp/calls.log")" -eq 4 ]
echo 'PASS: transient write failure is retried without another event'

# A stale run holds a metadata call while another invocation arrives. The second
# must not even snapshot until the first has released its lock.
reset
: > "$tmp/hold-writes"
FAKE_RUN=first bash "$DIR/../renumber.sh" &
first=$!
wait_for_write
jq '.result.snapshot.agents[0].state_change_seq = 0' "$tmp/snapshot.json" > "$tmp/reordered.json"
mv "$tmp/reordered.json" "$tmp/snapshot.json"
FAKE_RUN=second bash "$DIR/../renumber.sh" &
second=$!
sleep 0.15
if grep -q second "$tmp/reads.log"; then exit 1; fi
rm "$tmp/hold-writes"
wait "$first"
wait "$second"
correct
[ "$(uniq "$tmp/reads.log")" = $'first\nsecond' ]
[ ! -d "$HERDR_SOCKET_PATH.agent-numbers.lock" ]
echo 'PASS: overlapping runs serialize and leave the latest ordering published'

# An interrupted parent must retain the lock until its metadata children finish.
reset
rm "$tmp/write-waiting"
: > "$tmp/hold-writes"
bash "$DIR/../renumber.sh" &
interrupted=$!
wait_for_write
kill -TERM "$interrupted"
sleep 0.1
[ -d "$HERDR_SOCKET_PATH.agent-numbers.lock" ]
rm "$tmp/hold-writes"
if wait "$interrupted"; then exit 1; else [ "$?" -eq 143 ]; fi
[ ! -d "$HERDR_SOCKET_PATH.agent-numbers.lock" ]
echo 'PASS: interruption waits for metadata children before releasing the lock'

# Errors release the lock; an unreadable API snapshot cannot report success.
reset
: > "$tmp/fail-snapshot"
if bash "$DIR/../renumber.sh" 2>/dev/null; then exit 1; fi
[ ! -d "$HERDR_SOCKET_PATH.agent-numbers.lock" ]
rm "$tmp/fail-snapshot"
bash "$DIR/../renumber.sh"
correct
echo 'PASS: snapshot failure is visible and releases the lock for recovery'

# Malformed API data must fail rather than silently report an empty panel.
printf '{"result":{"snapshot":{"panes":[]}}}\n' > "$tmp/snapshot.json"
if bash "$DIR/../renumber.sh" 2>/dev/null; then exit 1; fi
[ ! -d "$HERDR_SOCKET_PATH.agent-numbers.lock" ]
echo 'PASS: malformed snapshots fail visibly'
reset

# Empty panels are valid, and dry-run neither takes a lock nor writes metadata.
jq '.result.snapshot.agents = [] | .result.snapshot.panes = []' "$tmp/snapshot.json" > "$tmp/empty.json"
mv "$tmp/empty.json" "$tmp/snapshot.json"
bash "$DIR/../renumber.sh"
mkdir "$HERDR_SOCKET_PATH.agent-numbers.lock"
AGENT_NUMBERS_DRY_RUN=1 bash "$DIR/../renumber.sh"
rmdir "$HERDR_SOCKET_PATH.agent-numbers.lock"
echo 'PASS: empty panels and read-only dry runs work'

# Bound lock contention without stealing the existing lock. Fake only the sleeps
# in this case so the ten-second timeout can be exercised without waiting.
mkdir "$HERDR_SOCKET_PATH.agent-numbers.lock" "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"
if PATH="$tmp/bin:$PATH" bash "$DIR/../renumber.sh" 2> "$tmp/timeout.log"; then exit 1; fi
grep -q 'lock unavailable' "$tmp/timeout.log"
[ -d "$HERDR_SOCKET_PATH.agent-numbers.lock" ]
rmdir "$HERDR_SOCKET_PATH.agent-numbers.lock"
echo 'PASS: lock contention times out visibly without stealing ownership'
