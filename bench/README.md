# zipir benchmarks

Published benchmark reports, one directory per measured target. Each report states its host, build flags, inputs, method, and limits, and ships the measured rows as TSV next to its figures.

| Target | Host | zipir | Report |
| --- | --- | --- | --- |
| `linux-x86-avx2` | AMD Ryzen 9 3950X (Zen 2), Linux x86-64 | `fc81d52` (compression), `ff8e9e8` (decompression and peers) | [linux-x86-avx2/README.md](linux-x86-avx2/README.md) |

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

When only zipir's encoder changed, its compression rows can be re-timed without re-timing the peers: time the zipir adapters alone (`tools/bench.sh --op compress zipir-gzip zipir-zlib zipir-deflate zipir-bgzf` with the classes of the base run), re-time any batch disturbed by other jobs (a later run overrides an earlier one), then [`splice.py`](splice.py) writes a run with zipir's rows replaced and every other row as measured, and `report.py` states in the report that those rows were not timed in the same rounds as the peers:

```sh
python3 bench/splice.py prime-lanes prime-lanes-fc81d52b named-zipir-gzip+zipir-zlib+zipir-deflate+zipir-bgzf-lanes \
    named-zipir-gzip-lanes named-zipir-zlib-lanes named-zipir-deflate-lanes named-zipir-bgzf-lanes
python3 tools/report.py prime-lanes-fc81d52b
python3 bench/report.py prime-lanes-fc81d52b --target linux-x86-avx2 --frontier named-zlib-ng+igzip+libdeflate-gzip-all
```

`--frontier RUN` adds the frontier figure and the peer-equivalents table: zipir's presets against every level of each peer, from a run that timed every level (`tools/bench.sh --levels all --format gzip --op compress --class medium,small zlib-ng igzip libdeflate-gzip` names it `named-zlib-ng+igzip+libdeflate-gzip-all`).

A single command that runs the whole publication set (install, qualify, bench, checks, report) will replace these steps; until then, `tools/README.md` has the commands and their run times.
