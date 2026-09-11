#!/usr/bin/env bash
# A fake API and a socket pathname let us test polling with NO plugin events.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
watcher=""
cleanup() {
  if [ -n "$watcher" ]; then kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
export TEST_STATE_DIR="$tmp" HERDR_SOCKET_PATH="$tmp/herdr.sock"
export HERDR_BIN_PATH="$tmp/herdr" AGENT_NUMBERS_SORT=priority XDG_CONFIG_HOME="$tmp/config"
cp "$DIR/fake_herdr.sh" "$HERDR_BIN_PATH"
chmod +x "$HERDR_BIN_PATH"
mkdir -p "$tmp/config/herdr"
python3 - "$HERDR_SOCKET_PATH" <<'PY'
import socket,sys
s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.close()
PY
jq -n --arg root "$(cd "$DIR/.." && pwd)" '[{plugin_id:"agent-numbers",enabled:true,plugin_root:$root}]' > "$tmp/config/herdr/plugins.json"
jq '.result.snapshot.panes = (.result.snapshot.agents | map({pane_id,tokens:{}}))' "$DIR/fixtures/idle-only.json" > "$tmp/snapshot.json"
bash "$DIR/../watch.sh" run &
watcher=$!
correct() {
  local want have
  want="$(jq -r --arg mode priority -f "$DIR/../order.jq" "$tmp/snapshot.json" | sort)"
  have="$(jq -r '.result.snapshot.panes[] | "\(.pane_id)\t\(.tokens.num)"' "$tmp/snapshot.json" | sort)"
  [ "$want" = "$have" ]
}
settle() {
  local i
  for ((i=0;i<60;i++)); do if correct; then return 0; fi; sleep 0.1; done
  echo 'watcher did not converge' >&2; return 1
}
stopped() {
  local i
  for ((i=0;i<40;i++)); do
    if ! kill -0 "$watcher" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo 'watcher did not stop' >&2; return 1
}
settle
# Wait for the first write's changed metadata to be observed; it must not rewrite.
sleep 1
writes="$(wc -l < "$tmp/calls.log")"
sleep 1
[ "$(wc -l < "$tmp/calls.log")" = "$writes" ]
echo 'PASS: watcher starts numbering and leaves unchanged metadata alone'

# No event command runs when focus and status change in this fake server.
jq '.result.snapshot.focused_pane_id = .result.snapshot.agents[0].pane_id | .result.snapshot.agents[0].state_change_seq = 0' "$tmp/snapshot.json" > "$tmp/next.json"
mv "$tmp/next.json" "$tmp/snapshot.json"
settle
echo 'PASS: focus/order changes without events are repaired'

# Ten starts must leave the same single owner.
for ((i=0;i<10;i++)); do bash "$DIR/../watch.sh" start; done
sleep 0.3
owners=("$HERDR_SOCKET_PATH".agent-numbers-watch.*.lock/pid)
[ "${#owners[@]}" = 1 ]
[ "$(cat "${owners[0]}")" = "$watcher" ]
echo 'PASS: duplicate starts retain one watcher'

# Disable without emitting a plugin event. The watcher must stop and clean up.
jq '.[0].enabled = false' "$tmp/config/herdr/plugins.json" > "$tmp/disabled.json"
mv "$tmp/disabled.json" "$tmp/config/herdr/plugins.json"
stopped
wait "$watcher"
watcher=""
[ ! -f "${owners[0]}" ]
echo 'PASS: disabling the plugin stops the watcher and releases its lock'

# Socket disappearance must also end the watcher.
jq '.[0].enabled = true' "$tmp/config/herdr/plugins.json" > "$tmp/enabled.json"
mv "$tmp/enabled.json" "$tmp/config/herdr/plugins.json"
bash "$DIR/../watch.sh" run &
watcher=$!
sleep 0.2
rm "$HERDR_SOCKET_PATH"
stopped
wait "$watcher"
watcher=""
[ ! -f "${owners[0]}" ]
echo 'PASS: server socket removal stops the watcher'
