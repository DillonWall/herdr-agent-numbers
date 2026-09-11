# Contributing

## The most useful thing you can report

This plugin **replicates** herdr's `priority` ordering rather than reading it, because
herdr computes no agent ordinal and exposes no `agent_index` token. The ranking is:

```
blocked  <  done  <  working  <  idle          then most recent state change first
```

The rank matches herdr 0.9.0's source, but the server snapshot can disagree with
the client's completion acknowledgement state. See the README's priority-mode
limitation. Reports should include the verify output and actual sidebar order;
do not change the rank to compensate for stale metadata or client-only state.

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
| `tests/test_recovery.sh` | delayed reorders, overlap, retries, and lock cleanup |

## Constraints

- **`bash` and `jq` only.** No other runtime dependencies. This matches
  `numbered-workspaces` and keeps the plugin installable anywhere herdr runs.
- **`shellcheck -x` clean.** Use a targeted `# shellcheck disable=SCxxxx  # reason`
  for a deliberate pattern; don't change logic just to silence a warning.
- **Portable `bash`.** macOS ships bash 3.2, so no associative arrays and no
  `${var,,}`. Use portable locking; do not introduce a Linux-only `flock` dependency.
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
