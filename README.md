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

That is why there is a `verify` action. Under `priority`, run it with at least one
agent actually `blocked` or `working` and diff its output against the rendered
sidebar before trusting the numbers:

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

Panes, unlike workspaces, do not expose their metadata tokens in the snapshot, so
there is nothing to read back and diff against. The last published ordering is
cached in the plugin state dir instead, and only panes whose ordinal actually moved
are rewritten. Changing `agent_panel_sort` needs no cache reset: the cached lines
carry the ordinals, so the next run rewrites exactly the panes that moved.

Tokens are in-memory and die with the herdr server, which the cache alone cannot
detect — it would report everything as already published and leave the panel blank.
So the cache is keyed on the socket's inode and mtime, which change when the server
restarts, and `pane.focused` acts as the recovery hook: the first event after
reattaching republishes the lot.

All agents are numbered, including past the ninth. Only 1–9 are bindable via
`focus_agent`, but truncating the display would misrepresent the panel.

## When to delete this plugin

If herdr ships a native `agent_index` row token
([discussion #2048](https://github.com/herdrdev/herdr/discussions/2048)), delete
this plugin and use it. A replicated sort tracking undocumented internal behaviour
is worth maintaining only while there is no alternative.

## Development

```bash
bash tests/test_order.sh
bash tests/test_sort_mode.sh
bash tests/test_renumber.sh
shellcheck -x *.sh tests/*.sh
```

The tests run entirely against fixtures, synthetic config dirs and a fake `herdr` on
`PATH`; they never touch a live session.
