# Validation

The long and heavy correctness checks of zipir. They are development checks, run to close a piece of work and before a release; they are not part of the package and not what `zig build test` runs. This folder is its own Zig package that imports zipir by path, so every check sees only zipir's public module, as a dependent does. Nothing here is timed.

A failure found here becomes a small unit test in `tests/` before its fix is accepted. A check that could not run counts as incomplete, never as passed.

## Running

From this folder:

```sh
zig build check                     # seed: seconds; what CI runs
zig build check -Dbudget=full       # the contract suites at the size each long property was written for
zig build check -Dbudget=long       # a campaign
zig build suites -Dbudget=full      # only the contract suites
```

`-Dbudget` sets the size of every check:

- `seed` builds the contract suites and runs this folder's own checks over their seed inputs only.
- `full` runs the contract suites of `tests/` at full scale: the same test files `zig build test` runs, with every long property at the size it was written for instead of the bounded size that keeps `tests/` quick.
- `long` runs them past that size, as a campaign.

Run heavy budgets under a memory and CPU cap, for example `systemd-run --user --scope -p CPUQuota=400% -p MemoryMax=4G zig build check -Dbudget=long -j4`.

## Checks

- `suites`: the contract suites `gzip`, `zlib`, `deflate`, `bgzf`, `tar`, `reader`, and `writer` from `tests/`. A test that is bounded in `tests/` takes its sizes from `support.pick(unit, full, long)`; this package compiles it at `full` or `long`.
