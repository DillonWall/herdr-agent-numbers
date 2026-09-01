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

There is no ordinal to read, so the sort is reconstructed from the two fields it
plausibly uses:

```
sort by agent status  (blocked < working < done < idle)
then by state_change_seq, descending
```

The `state_change_seq` half was verified against the live panel. The **status
ranking is inferred** from what an attention-queue sort would plausibly do — herdr
neither documents nor exposes it. If herdr's real ranking differs, the numbers are
quietly wrong rather than visibly broken.

`done` above `working` has since been **verified** against a live panel — with one
`done` agent at seq 45 and one `working` at seq 48, the panel put `done` first, which
neither a working-first ranking nor plain seq-descending predicts. **`blocked` remains
unverified**: no agent was blocked during any observation.

That is why there is a `verify` action. Under `priority`, run it and diff its output
against the rendered sidebar before trusting the numbers:

```bash
herdr plugin action invoke agent-numbers.verify
```

If the two disagree, fix the `rank` function in `order.jq` from the evidence.

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

It runs on `pane.agent_status_changed` — load-bearing under `priority`, where the
status *is* the ordering input — plus `pane.agent_detected`, `pane.created` and
`pane.closed` for agents appearing and disappearing, and `pane.moved` /
`workspace.moved`, which reorder the panel under `spaces` with no status change at
all. Renames deliberately trigger nothing: the order does not depend on the name.

The token each pane already carries is read back out of the same snapshot, and only
the panes that disagree are written. Nothing is cached, so there is no stored state
to drift out of sync with reality — a token lost to a server restart, or clobbered by
something else, is simply republished on the next event. `pane.focused` is what makes
recovery prompt: it is the first event after reattaching.

(Metadata tokens are in-memory and die with the herdr server. That needs no special
handling here: a restarted server has no tokens, so every ordinal differs and every
pane is rewritten. Switching `agent_panel_sort` is the same story — the published
numbers simply disagree with the new ordering and get corrected.)

Those writes go out concurrently. A full reorder touches every agent, and the panel
has already reordered from herdr's own state by the time any of them land, so the
round trips are a visible lag rather than just CPU. Every write is attempted even if
one fails; a failure needs no bookkeeping, since the token stays wrong and the next
event notices.

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
