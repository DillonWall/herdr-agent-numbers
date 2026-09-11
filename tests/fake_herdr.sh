#!/usr/bin/env bash
# Stateful fake. All API reads and writes stay inside the test's private directory.
set -euo pipefail
: "${TEST_STATE_DIR:?}"
cd "$TEST_STATE_DIR"

if [ "$1" = pane ] && [ -f hold-writes ]; then
  : > write-waiting
  while [ -f hold-writes ]; do sleep 0.01; done
fi
until mkdir api-lock 2>/dev/null; do sleep 0.01; done
trap 'rmdir api-lock' EXIT
if [ "$1" = api ] && [ "$2" = snapshot ]; then
  echo "${FAKE_RUN:-test}" >> reads.log
  count=0
  [ ! -f read-count ] || read -r count < read-count
  count=$((count + 1))
  echo "$count" > read-count
  if [ "$count" = 2 ] && [ -f next-snapshot.json ]; then
    mv next-snapshot.json snapshot.json
  fi
  if [ -f fail-snapshot ]; then exit 1; fi
  cat snapshot.json
  exit 0
fi
echo "$*" >> calls.log
if [ -n "${FAKE_FAIL:-}" ]; then exit 1; fi
if [ -f fail-once ]; then rm fail-once; exit 1; fi
jq --arg pane "$3" --arg num "${7#num=}" '
  (.result.snapshot.panes[] | select(.pane_id == $pane) | .tokens.num) = $num
' snapshot.json > snapshot.tmp
mv snapshot.tmp snapshot.json
