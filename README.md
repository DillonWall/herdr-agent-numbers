# herdr-agent-numbers

Shows each agent's 1-based position in herdr's agents sidebar — the number
`focus_agent` (`prefix+1..9`) actually selects.

herdr computes an ordinal for spaces and tabs and exposes it as `number` in the
API. It does **not** do this for agents, and there is no built-in `agent_index`
row token. This plugin fills that gap the same way
[`abrose/herdr-numbered-workspaces`](https://github.com/abrose/herdr-numbered-workspaces)
does for spaces: it publishes an ordinal as pane metadata, which the sidebar
renders through a `"$num"` row token.

## Both sort modes

The agents panel orders itself two different ways, and the numbers are only right
if the plugin knows which is in force. herdr does not expose the setting —
`herdr api snapshot` carries no config and `herdr config` has no getter — so
`sort-mode.sh` reads `agent_panel_sort` out of `config.toml` directly, locating it
from `HERDR_SOCKET_PATH`. Unset or unrecognised falls back to `spaces`, herdr's own
default. `AGENT_NUMBERS_SORT` overrides it.

### `agent_panel_sort = "spaces"` — read, not guessed

The snapshot's `agents` array already arrives grouped by workspace in ascending
pane order, byte-identical to the `panes` array. The panel order is therefore taken
straight from it. Nothing is inferred and there is nothing to get wrong.

### `agent_panel_sort = "priority"` — replicated, and worth checking

There is no ordinal to read, so the plugin reconstructs the sort:

```
blocked < done < working < idle < unknown
then state_change_seq, descending
```

This matches [herdr 0.9.0's status ranking](https://github.com/herdrdev/herdr/blob/v0.9.0/src/client/shell.rs)
and [sidebar sort](https://github.com/herdrdev/herdr/blob/v0.9.0/src/client/shell/agent_sidebar.rs).
The statuses it ranks are the client's, not the server's: the client
[shows an idle agent as done](https://github.com/herdrdev/herdr/blob/v0.9.3/src/client/shell/endpoint_agent_state.rs)
until its latest completion has been on screen, so an agent that finishes in a
tab you are not looking at jumps to the top. From herdr 0.9.2 only a completion
counts (the snapshot's `completion_seq` at the current `state_change_seq`), so
agents detected or restored at startup stay idle; on 0.9.0 and 0.9.1 any unseen
state change shows as done. Server snapshots do not carry that
view, so `ack.jq` keeps a copy of it in `<socket>.agent-numbers.ack`. Every agent
present when the plugin first sees a server counts as seen; after that, each pass
records the seq of whatever is on screen (the focused tab, or only its focused pane
when zoomed).

The copy cannot see everything the client does, so numbers can still disagree with
the sidebar:

- **Terminal window unfocused.** The client stops acknowledging and the plugin
  cannot tell. An agent that finishes on screen shows as done in the sidebar until
  you focus the window again.
- **Very short visits.** A tab shown for less than one 500 ms poll, with no focus
  event caught in time, is acknowledged by the client but not here. That agent stays
  wrong until it changes again or you look at it again.
- **Reattaching.** A client that reattaches to a running server restarts its record
  and shows every agent as idle. The API exposes no clients or attach events, so the
  plugin keeps its old record.
- **Installing mid-session, or any gap in watching.** The record starts over when
  the plugin first runs and whenever its watcher stops (reinstall, disable), so
  agents the sidebar already shows as done count as seen here until you view them.
- **Several clients.** Each keeps its own record; the plugin follows the server's
  focused tab.

The verify action prints the computed order next to each agent's status, seq, and
acknowledged seq; compare its output against the rendered sidebar:

```bash
herdr plugin action invoke agent-numbers.verify
```

## Requirements

`bash` and `jq`, on herdr 0.9.0 or newer. No separate service is required.

## Install

```bash
herdr plugin install DillonWall/herdr-agent-numbers --yes
```

Then add the `$num` token to your agent rows in `~/.config/herdr/config.toml`:

```toml
[ui.sidebar.agents.rows_by_agent]
claude = [
  [{ token = "$num", bold = true }, "state_icon",
   { token = "terminal_title_stripped", bold = true, dim = false, fg = "#cdd6f4" }],
  [{ token = "workspace", bold = false, dim = true }],
]
```

and reload:

```bash
herdr config check
herdr server reload-config
herdr plugin action invoke agent-numbers.renumber
```

## How it works

`renumber.sh` reads `herdr api snapshot`, runs `order.jq` over it in the active sort
mode, and writes each agent's position:

```
herdr pane report-metadata <pane_id> --source agent-numbers --token num=<n>
```

It runs on status, detection, creation, closure, pane/workspace moves, and
pane/tab/workspace focus events. Renames do not trigger it.

Each snapshot/read/write pass takes a per-socket lock **before** reading state,
so older snapshots cannot overwrite newer runs. The lock is released during
retry delays so bursts do not queue an entire settling window per event. Waiting
invocations read fresh state once they acquire the lock. Only differing tokens are written, concurrently within a run.
The script rechecks after 0.2 seconds and another 0.5 seconds, including when the
first check found nothing to change. This catches changes while handling the
event and retries failed writes without needing another user action. A final
read reports failure if numbers still disagree or the snapshot cannot be read.
Work is bounded; further events retry if the server keeps changing.

No ordering is cached by the renumber command. Missing metadata after a restart
is republished automatically by the watcher.

### Automatic focus recovery

The plugin includes a background watcher; no separate service or manual launch
is needed. Herdr starts it through the plugin startup hook. The renumber action
and event hooks also ensure it is running, so installing into an already-running
server works after invoking `agent-numbers.renumber` once.

One watcher per server socket checks snapshots every 500 ms. It compares focus,
what is on screen, agent status/sequence/order, and published numbers, and runs
one reconciliation pass only when those inputs change. Stable snapshots cause no
metadata writes. This covers client navigation that updates server state without
emitting the API focus events, and keeps the on-screen record current; the
priority-mode section lists what that record cannot see.

The watcher exits when the socket disappears, after three consecutive failed
reads, or when the plugin is disabled/uninstalled. Reinstallation hands it over
to the new watcher code. A subsequent subscribed event restarts a stopped watcher.
Whenever it stops or hands over, it deletes the on-screen record too, since nothing
keeps that record current in between; the next pass starts a fresh one.
Its lock is `<socket>.agent-numbers-watch.<inode>.lock`, containing its PID; a new
server socket uses a new lock. Like the renumber lock, SIGKILL can require manual
cleanup after confirming that the recorded process has stopped.

Measured on Linux with herdr 0.9.0: about 3.7 MiB resident memory, 5.9 MiB sampled
including child processes, and 1.6–1.8% of one CPU core over two 17-second idle samples.
These are observations, not limits; session size and hardware affect the cost.

### Interrupted-run recovery

The portable lock is a directory next to the session socket:
`<socket-path>.agent-numbers.lock`, containing the owning process ID in `pid`.
Normal exits and handled interrupts release it after outstanding writes finish.
A waiter fails visibly after about 10 seconds rather than running concurrently.

SIGKILL or a machine crash can leave the directory behind. Check its `pid` and
confirm that the owner and its metadata commands have stopped, then remove only
that lock's `pid` file and empty directory. Invoke `agent-numbers.renumber` again.
The plugin deliberately never steals a lock that might still protect a writer.

All agents are numbered, including past the ninth. Only 1–9 are bindable via
`focus_agent`, but truncating the display would misrepresent the panel.

## When to delete this plugin

If herdr ships a native `agent_index` row token
([discussion #2048](https://github.com/herdrdev/herdr/discussions/2048)), delete
this plugin and use it. A replicated sort tracking undocumented internal behaviour
is worth maintaining only while there is no alternative.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The single most useful contribution is an
observation of the panel with a **`blocked`** agent in it — that rung of the ranking
is still unverified.

```bash
bash tests/run.sh                  # every suite
shellcheck -x ./*.sh tests/*.sh    # must be clean
```

Both run in CI on every push and pull request. Tests additionally need `python3`
(to create a disposable socket pathname). They use fixture snapshots,
synthetic config dirs and a fake `herdr` on `PATH`; they never touch a live session.

## License

[MIT](LICENSE) — © 2026 Dillon Wall.
