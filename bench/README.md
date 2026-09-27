# zipir benchmarks

Published benchmark reports, one directory per measured target. Each report states its host, build flags, inputs, method, and limits, and ships the measured rows as TSV next to its figures.

| Target | Host | zipir | Report |
| --- | --- | --- | --- |
| `linux-x86-avx2` | AMD Ryzen 9 3950X (Zen 2), Linux x86-64 | `ff8e9e8` | [linux-x86-avx2/README.md](linux-x86-avx2/README.md) |

## How the numbers are made

The measurements come from the comparison harness in [`tools/`](../tools/README.md):

1. `tools/install.sh` builds or links every peer and records how it was built.
2. `tools/qualify.sh` checks every peer, and zipir, against independent references before anything is timed.
3. `tools/bench.sh` times matched Zebrac batches: every tool for one file and operation runs in the same interleaved rounds on one pinned CPU.
4. [`report.py`](report.py) turns a finished run into a report directory here: `README.md`, `measurements.tsv`, `summary.tsv`, and light and dark figures.

`report.py` measures nothing itself. To regenerate a report from an existing run:

```sh
python3 bench/report.py prime-lanes --target linux-x86-avx2
```

A single command that runs the whole publication set (install, qualify, bench, checks, report) will replace these steps; until then, `tools/README.md` has the commands and their run times.
