# Contributing

## The most useful thing you can report

This plugin **replicates** herdr's `priority` ordering rather than reading it, because
herdr computes no agent ordinal and exposes no `agent_index` token. The ranking is:

```
blocked  <  done  <  working  <  idle          then most recent state change first
```

`done < working < idle` was verified against a live panel. **`blocked` has never been
observed** — no agent was blocked during any check, so its position is still a guess.

If you have an agent that is genuinely `blocked`, please run:

```bash
herdr plugin action invoke agent-numbers.verify
```

and open an issue with that output plus the actual top-to-bottom order your sidebar
shows. That single observation is worth more than any amount of reasoning about it.

The same applies to any ordering mismatch: **report what the panel actually shows**.
Please don't adjust a fixture so the tests agree with a guess — the fixtures encode
observed behaviour, and one of them
(`tests/fixtures/done-outranks-working.json`) exists precisely because the original
guess turned out to be backwards.

## Running the tests

```bash
bash tests/run.sh                       # every suite
shellcheck -x ./*.sh tests/*.sh         # must be clean
```

Both run in CI on every push and pull request. The suites need only `bash` and `jq`,
and never touch a live herdr session: they run against fixture snapshots and a fake
`herdr` placed on `PATH`.

| Suite | Covers |
|---|---|
| `tests/test_order.sh` | the ordering derivation, in both sort modes |
| `tests/test_sort_mode.sh` | detecting `agent_panel_sort` from `config.toml` |
| `tests/test_renumber.sh` | which panes get written, and when |

## Constraints

- **`bash` and `jq` only.** No other runtime dependencies. This matches
  `numbered-workspaces` and keeps the plugin installable anywhere herdr runs.
- **`shellcheck -x` clean.** Use a targeted `# shellcheck disable=SCxxxx  # reason`
  for a deliberate pattern; don't change logic just to silence a warning.
- **Portable `bash`.** macOS still ships bash 3.2, so no associative arrays and no
  `${var,,}`. `stat` differs too — GNU takes `-c`, BSD takes `-f`; see `renumber.sh`.
- **Write only what changed.** `renumber.sh` reads each pane's published token back
  and writes only the ones that disagree. Keep that property: these events fire often,
  and a plugin that rewrites every pane on every event is a plugin people uninstall.

## Testing a change by hand

`renumber.sh` honours two environment variables, which is usually enough to avoid
touching a real session:

```bash
AGENT_NUMBERS_DRY_RUN=1 ./renumber.sh    # print the herdr commands instead of running them
AGENT_NUMBERS_SORT=priority ./verify.sh  # force a sort mode, ignoring config.toml
```
