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
However, the client [tracks whether you have viewed a completion independently](https://github.com/herdrdev/herdr/blob/v0.9.0/src/client/shell/endpoint_agent_state.rs),
which can change its displayed `done`/`idle` status and ordering without a matching
server event. Server snapshots do not expose that client-specific view. Numbers
can therefore disagree with the sidebar even after a successful refresh; more
frequent refreshes cannot guarantee an exact match. Separate clients may have
different orders for the same panes.

The verify action compares the plugin's computed order with published metadata;
compare its output against the rendered sidebar too:

```bash
herdr plugin action invoke agent-numbers.verify
```

## Requirements

`bash` and `jq`. No other runtime dependencies.

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

Each invocation takes a per-socket lock **before** reading a snapshot, so older
runs cannot overwrite newer runs. Waiting invocations read fresh state once they
acquire the lock. Only differing tokens are written, concurrently within a run.
The script rechecks after 0.2 seconds and another 0.5 seconds, including when the
first check found nothing to change. This catches changes while handling the
event and retries failed writes without needing another user action. A final
read reports failure if numbers still disagree or the snapshot cannot be read.
Work is bounded; further events retry if the server keeps changing.

No ordering is cached. Missing metadata after a restart is republished on the
next subscribed event. This is event-driven recovery, not a background poller,
and does not fix client-only ordering changes described above.

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

Both run in CI on every push and pull request. The tests use fixture snapshots,
synthetic config dirs and a fake `herdr` on `PATH`; they never touch a live session.

## License

[MIT](LICENSE) — © 2026 Dillon Wall.
