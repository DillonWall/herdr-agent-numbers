# herdr-agent-numbers

Shows each agent's 1-based position in herdr's agents sidebar — the number
`focus_agent` (`prefix+1..9`) actually selects.

herdr computes an ordinal for spaces and tabs and exposes it as `number` in the
API. It does **not** do this for agents, and there is no built-in `agent_index`
row token. This plugin fills that gap the same way
[`abrose/herdr-numbered-workspaces`](https://github.com/abrose/herdr-numbered-workspaces)
does for spaces: it publishes an ordinal as pane metadata, which the sidebar
renders through a `"$num"` row token.

## The important caveat

`numbered-workspaces` *reads* a server-computed ordinal and mirrors it back. There
is no such number for agents, so this plugin **replicates herdr's ordering rather
than reading it**:

```
sort by agent status  (blocked < working < done < idle)
then by state_change_seq, descending
```

The `state_change_seq` half was verified against the live panel. The **status
ranking is inferred** from what a "priority" (attention-queue) sort would plausibly
do — herdr does not document it and does not expose it. If herdr's real ranking
differs, the numbers are quietly wrong rather than visibly broken.

That is why there is a `verify` action. Run it, with at least one agent actually
`blocked` or `working`, and diff its output against the rendered sidebar before
trusting the numbers:

```bash
herdr plugin action invoke agent-numbers.verify
```

If the two disagree, fix the `rank` function in `order.jq` from the evidence.

## Requirements

- `bash` and `jq` — no other runtime dependencies.
- `agent_panel_sort = "priority"` in your herdr config. This plugin replicates that
  specific sort. Under `agent_panel_sort = "spaces"` the ordering is structural and
  these numbers will be wrong.

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

`renumber.sh` reads `herdr api snapshot`, runs `order.jq` over it to derive the
ordering, and writes each agent's position:

```
herdr pane report-metadata <pane_id> --source agent-numbers --token num=<n>
```

It runs on `pane.agent_status_changed`, `pane.agent_detected`, `pane.created` and
`pane.closed`. The status event is the load-bearing one: under a priority sort the
status *is* the ordering input, so every reorder is preceded by it. Renames
deliberately trigger nothing — the order does not depend on the name.

Panes, unlike workspaces, do not expose their metadata tokens in the snapshot, so
there is nothing to read back and diff against. The last published ordering is
cached in the plugin state dir instead, and only panes whose ordinal actually moved
are rewritten.

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
bash tests/test_renumber.sh
shellcheck -x *.sh tests/*.sh
```

The tests run entirely against fixtures and a fake `herdr` on `PATH`; they never
touch a live session.
