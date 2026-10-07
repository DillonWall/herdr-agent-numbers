#!/usr/bin/env bash
# One background watcher per server socket. Event hooks only ensure it is running.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
herdr="${HERDR_BIN_PATH:-herdr}"
socket="${HERDR_SOCKET_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock}"
registry="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins.json"
[ -S "$socket" ] || exit 0
socket_id="$(ls -id "$socket")"
# A recreated server socket gets a new lock, even after an unclean shutdown.
read -r socket_inode _ <<< "$socket_id"
lock="$socket.agent-numbers-watch.$socket_inode.lock"

case "${1:-start}" in
  start)
    # Detach all inherited pipes so herdr can finish the startup/event command.
    nohup "$here/watch.sh" run </dev/null >/dev/null 2>&1 &
    exit 0
    ;;
  run) ;;
  *) echo 'usage: watch.sh [start|run]' >&2; exit 2 ;;
esac
mkdir "$lock" 2>/dev/null || exit 0
# Nothing keeps the on-screen record current once this watcher stops, so it goes
# with the lock and the next pass starts a fresh one (see ack.jq).
cleanup() { rm -f "$lock/pid" "$socket.agent-numbers.ack"; rmdir "$lock"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$$" > "$lock/pid"
version="$(cksum "$here/watch.sh")"
previous=""
failures=0
while [ -S "$socket" ] && [ "$(ls -id "$socket")" = "$socket_id" ]; do
  # Recheck each poll: tool-manager cleanup can remove it mid-session.
  [ -x "$herdr" ] || herdr=herdr
  # Reinstallation replaces files at the same path. Hand off to the new code.
  if [ "$(cksum "$here/watch.sh" 2>/dev/null || true)" != "$version" ]; then
    cleanup
    trap - EXIT
    [ ! -f "$here/watch.sh" ] || exec "$here/watch.sh" run
    exit 0
  fi
  # Reading the registry also stops the watcher after disable/uninstall/unlink.
  if ! fingerprint="$("$herdr" api snapshot | jq -cer --slurpfile registry "$registry" --arg root "$here" '
    if any($registry[0][]; .plugin_id == "agent-numbers" and .enabled and .plugin_root == $root)
    then .result.snapshot | [ .focused_pane_id,
      [.agents[] | [.pane_id, .agent_status, .state_change_seq]],
      [.panes[] | [.pane_id, .tokens.num]],
      # What is on screen feeds ack.jq, so zooms and splits count as changes too.
      [.focused_tab_id as $tab | .layouts[]? | select(.tab_id == $tab) | [.zoomed, [.panes[]?.pane_id]]] ]
    else "disabled" end')"; then
    failures=$((failures + 1))
    [ "$failures" -lt 3 ] || exit 1
  else
    [ "$fingerprint" != disabled ] || exit 0
    failures=0
    if [ "$fingerprint" != "$previous" ]; then
      if "$here/renumber.sh" --once; then previous="$fingerprint"; fi
    fi
  fi
  sleep 0.5
done
