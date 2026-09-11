#!/usr/bin/env bash
# Reconcile published numbers with fresh server snapshots after each event.
set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dry="${AGENT_NUMBERS_DRY_RUN:-0}"
socket="${HERDR_SOCKET_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock}"
lock="$socket.agent-numbers.lock"

# Serialize snapshot/read/write passes, but release ownership during retry delays
# so a burst of events does not queue a full settling window per invocation.
lock_owned=0
release_lock() {
  if [ "$lock_owned" = 1 ]; then
    # Interrupted parents retain ownership until metadata children finish.
    wait
    rm -f "$lock/pid"
    rmdir "$lock"
    lock_owned=0
  fi
}
acquire_lock() {
  local attempts=0
  until mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 100 ]; then
      printf 'agent-numbers: lock unavailable: %s (see README recovery)\n' "$lock" >&2
      return 1
    fi
    sleep 0.1
  done
  lock_owned=1
  printf '%s\n' "$$" > "$lock/pid"
}
trap release_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

changes() {
  local mode snap want have
  mode="$("$here/sort-mode.sh")" || return 1
  snap="$("$herdr" api snapshot)" || return 1
  printf '%s\n' "$snap" | jq -e '
    .result.snapshot | (.agents | type == "array") and (.panes | type == "array")
  ' >/dev/null || return 1
  want="$(printf '%s\n' "$snap" | jq -r --arg mode "$mode" -f "$here/order.jq")" || return 1
  have="$(printf '%s\n' "$snap" | jq -r '
    .result.snapshot.panes[] | select(.tokens.num != null) | "\(.pane_id)\t\(.tokens.num)"')" || return 1
  comm -23 <(printf '%s\n' "$want" | sort) <(printf '%s\n' "$have" | sort)
}

publish() {
  local changed="$1" pane_id num pid
  local pids=()
  while IFS=$'\t' read -r pane_id num; do
    [ -n "$pane_id" ] || continue
    if [ "$dry" = "1" ]; then
      printf '%s pane report-metadata %s --source agent-numbers --token num=%s\n' "$herdr" "$pane_id" "$num"
    else
      "$herdr" pane report-metadata "$pane_id" --source agent-numbers --token "num=$num" &
      pids+=("$!")
    fi
  done <<< "$changed"
  # A closed pane or transient failure must not prevent the other writes. The
  # next snapshot determines whether anything still needs repairing.
  for pid in ${pids[@]+"${pids[@]}"}; do
    wait "$pid" || true
  done
}

if [ "$dry" = "1" ]; then
  changed="$(changes)"
  publish "$changed"
  exit 0
fi

# Always recheck, even after an initial no-op: focus/status handling can still
# be settling. Bound the work so a continuously changing session cannot loop.
for delay in 0 0.2 0.5; do
  [ "$delay" = 0 ] || sleep "$delay"
  acquire_lock
  if changed="$(changes)"; then
    publish "$changed"
  fi
  release_lock
done
acquire_lock
changed="$(changes)" || exit 1
if [ -n "$changed" ]; then
  printf 'agent-numbers: numbers still differ after retries; next event will retry\n' >&2
  exit 1
fi
