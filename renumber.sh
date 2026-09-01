#!/usr/bin/env bash
# Publishes each agent's 1-based panel position as a `num` metadata token, which
# ui.sidebar.agents renders via the "$num" row token.
#
# The published token is read back out of the same snapshot and only the panes that
# disagree are written, which makes this self-healing: a token lost to a server
# restart, or one clobbered by something else, is simply republished on the next
# event. Nothing is cached, so there is no stored state to drift from reality.
set -euo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dry="${AGENT_NUMBERS_DRY_RUN:-0}"

# The panel order differs completely between herdr's two sort modes, so the active
# one selects which derivation order.jq applies.
mode="$("$here/sort-mode.sh")"

# One snapshot for both halves of the comparison, so the wanted ordering and the
# published tokens can never be read a moment apart.
snap="$("$herdr" api snapshot)"
want="$(printf '%s\n' "$snap" | jq -r --arg mode "$mode" -f "$here/order.jq")"
have="$(printf '%s\n' "$snap" | jq -r '
  .result.snapshot.panes[] | select(.tokens.num != null) | "\(.pane_id)\t\(.tokens.num)"')"

# comm needs sorted input; the ordering itself is carried in the lines themselves.
changed="$(comm -23 <(printf '%s\n' "$want" | sort) <(printf '%s\n' "$have" | sort) || true)"

# The writes are independent, so they go out concurrently -- a full reorder touches
# every agent, and at ~2ms per round trip the sequential version spent most of its
# runtime waiting. The panel reorders from herdr's own state before any of this lands,
# so this shortens a visible lag rather than merely saving CPU.
pids=()
while IFS=$'\t' read -r pane_id num; do
  [ -n "$pane_id" ] || continue
  if [ "$dry" = "1" ]; then
    printf '%s pane report-metadata %s --source agent-numbers --token num=%s\n' "$herdr" "$pane_id" "$num"
  else
    "$herdr" pane report-metadata "$pane_id" --source agent-numbers --token "num=$num" &
    pids+=("$!")
  fi
done <<< "$changed"

# Every write is attempted before any failure is reported, so one bad pane cannot
# strand the rest at stale numbers. A failure needs no special handling beyond a
# non-zero exit: the token stays wrong, so the next event notices and retries.
rc=0
for pid in ${pids[@]+"${pids[@]}"}; do
  wait "$pid" || rc=1
done
exit "$rc"
