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

# Unzooming puts a pane on screen without moving focus or emitting an event. The
# client acknowledges what it now shows, so the watcher has to notice the layout.
numbered() { # numbered <pane> <num> -- waits for the watcher to publish it
  local i
  for ((i=0;i<60;i++)); do
    [ "$(jq -r --arg p "$1" '.result.snapshot.panes[] | select(.pane_id == $p) | .tokens.num' "$tmp/snapshot.json")" != "$2" ] || return 0
    sleep 0.1
  done
  echo "watcher did not number $1 as $2" >&2; return 1
}
# w1:p2 finishes behind the zoom, so it shows as done and goes first.
jq '.result.snapshot.focused_tab_id = "w1:t1"
  | .result.snapshot.layouts = [{tab_id: "w1:t1", zoomed: true, focused_pane_id: "w1:p1",
      panes: [{pane_id: "w1:p1"}, {pane_id: "w1:p2"}]}]
  | .result.snapshot.agents |= map(if .pane_id == "w1:p1" then .state_change_seq = 8
      elif .pane_id == "w1:p2" then .state_change_seq = 4 else . end)' "$tmp/snapshot.json" > "$tmp/next.json"
mv "$tmp/next.json" "$tmp/snapshot.json"
numbered w1:p2 1; numbered w1:p1 2; numbered w2:p1 3
# Let the watcher observe its own writes, so the unzoom below is the only change.
sleep 1
jq '.result.snapshot.layouts[0].zoomed = false' "$tmp/snapshot.json" > "$tmp/next.json"
mv "$tmp/next.json" "$tmp/snapshot.json"
numbered w1:p1 1; numbered w1:p2 2
echo 'PASS: unzooming acknowledges the revealed pane without an event'

# Ten starts must leave the same single owner.
for ((i=0;i<10;i++)); do bash "$DIR/../watch.sh" start; done
sleep 0.3
owners=("$HERDR_SOCKET_PATH".agent-numbers-watch.*.lock/pid)
[ "${#owners[@]}" = 1 ]
[ "$(cat "${owners[0]}")" = "$watcher" ]
# A duplicate that loses the race must not touch the owner's on-screen record.
[ -f "$HERDR_SOCKET_PATH.agent-numbers.ack" ] || { echo 'a duplicate start dropped the record' >&2; exit 1; }
echo 'PASS: duplicate starts retain one watcher and its record'

# Disable without emitting a plugin event. The watcher must stop and clean up.
jq '.[0].enabled = false' "$tmp/config/herdr/plugins.json" > "$tmp/disabled.json"
mv "$tmp/disabled.json" "$tmp/config/herdr/plugins.json"
stopped
wait "$watcher"
watcher=""
[ ! -f "${owners[0]}" ]
# Nothing watches while the plugin is off, so its on-screen record must not outlive it.
[ ! -e "$HERDR_SOCKET_PATH.agent-numbers.ack" ] || { echo 'the record outlived the watcher' >&2; exit 1; }
echo 'PASS: disabling the plugin stops the watcher, releases its lock and drops its record'

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
