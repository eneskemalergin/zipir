# zipir comparison tools

Status: **Active** (last updated: 2026-09-26)

These scripts build the peer codecs, fetch the test corpus, check every peer for correctness, and time peers against zipir. They are for development and publication numbers. The zipir library and CLI do not use anything here.

Linux x86_64 only. Everything the tools produce is gitignored: peers under `tools/.local/` and `tools/bin/`, the corpus under `data/`.

## Quick start

```bash
tools/install.sh prime      # build or link the prime peers and the bgzip oracle
tools/corpus.sh             # fetch and derive every corpus file
tools/qualify.sh            # check the prime peers (sanity and small files)
tools/bench.sh --list       # show what bench would time, and run nothing
tools/bench.sh              # matched timing, then the report
```

The default everywhere is the _prime_ peers at their three _lane_ levels on the sanity and small files. That is the daily set. `--peers all --levels all --full` is the publication set: every peer, every level, every file. It takes hours, so run it only when you need publication numbers.

## Files

- `common.sh`: sourced by every script. Pinned versions, paths, the peer table loader, peer and level selection, corpus rows, shared options, and `tool_cmd`, the one place that knows each tool's command line.
- `peers.tsv`: one row per peer. Format, tier, levels, lanes, decode mode, and the gzip checks that block qualify.
- `corpus.tsv`: one row per category, class, and format. A row is either a pinned download (size and SHA-256) or a recipe derived from the gzip row's plaintext.
- `install.sh`: builds or links peers and oracles, and checks installs.
- `corpus.sh`: fetches, derives, and verifies the corpus.
- `qualify.sh`: correctness checks per peer, with a receipt.
- `bench.sh`: matched Zebrac timing.
- `report.py`: the per-run facts table and Markdown summary.
- `build.zig`, `build.zig.zon`, `zig/`: Zig adapters. `zipir-gzip` and `zipir-zlib` import the repository as a path dependency, so they get the same CPU backend code as the library build.
- `c/`: the zlib API adapters (host libz, zlib-ng native API, libdeflate full buffer).
- `rust/`: the flate2 adapters, with tracked `Cargo.lock` files.

## Peers

Versions are pinned in `common.sh`. Levels are on each tool's own scale.

| Peer                 | Version       | Format  | Tier     | Levels  | Lanes (fast, balanced, dense) | Decode      | Origin                                        |
| -------------------- | ------------- | ------- | -------- | ------- | ----------------------------- | ----------- | --------------------------------------------- |
| `zipir-gzip`         | 0.1.2         | gzip    | prime    | 1, 5, 9 | 1, 5, 9                       | streaming   | this repository, Zig adapter                  |
| `zlib-ng`            | 2.3.3         | gzip    | prime    | 0-9     | 1, 5, 9                       | streaming   | static `minigzip`, native instructions        |
| `igzip`              | 2.32.1        | gzip    | prime    | 0-3     | 0, 1, 2                       | streaming   | ISA-L CLI, static, no shim, no `-T`           |
| `std-gzip`           | 0.16.0        | gzip    | prime    | 1-9     | 1, 5, 9                       | streaming   | Zig standard library adapter                  |
| `libdeflate-gzip`    | 1.26          | gzip    | extended | 1-12    | 1, 6, 12                      | full-buffer | libdeflate CLI, static                        |
| `gnu-gzip`           | 1.14          | gzip    | extended | 1-9     | 1, 5, 9                       | streaming   | host `/usr/bin/gzip -n`                       |
| `pigz`               | 2.8           | gzip    | all      | 0-9     | 1, 5, 9                       | streaming   | host `/usr/bin/pigz -p1`                      |
| `flate2-miniz`       | 1.1.10        | gzip    | all      | 0-9     | 1, 5, 9                       | streaming   | Rust flate2, `miniz_oxide`                    |
| `flate2-zlib-rs`     | 1.1.10        | gzip    | all      | 0-9     | 1, 5, 9                       | streaming   | Rust flate2, zlib-rs 0.6.7                    |
| `zipir-zlib`         | 0.1.2         | zlib    | prime    | 1, 5, 9 | 1, 5, 9                       | streaming   | this repository, Zig adapter                  |
| `zlib-ng-zlib`       | 2.3.3         | zlib    | prime    | 0-9     | 1, 5, 9                       | streaming   | zlib-ng native API, C adapter                 |
| `std-zlib`           | 0.16.0        | zlib    | prime    | decode  |                               | streaming   | Zig standard library adapter                  |
| `libdeflate-zlib`    | 1.26          | zlib    | extended | 1-12    | 1, 6, 12                      | full-buffer | libdeflate, C adapter, told the output size   |
| `system-zlib`        | 1.3.1.zlib-ng | zlib    | extended | 0-9     | 1, 5, 9                       | streaming   | host libz, C adapter                          |
| `zipir-deflate`      | 0.1.2         | deflate | prime    | 1, 5, 9 | 1, 5, 9                       | streaming   | this repository, Zig adapter                  |
| `zlib-ng-deflate`    | 2.3.3         | deflate | prime    | 0-9     | 1, 5, 9                       | streaming   | zlib-ng native API, C adapter, windowBits -15 |
| `libdeflate-deflate` | 1.26          | deflate | extended | 1-12    | 1, 6, 12                      | full-buffer | libdeflate, C adapter, told the output size   |
| `system-deflate`     | 1.3.1.zlib-ng | deflate | extended | 0-9     | 1, 5, 9                       | streaming   | host libz, C adapter, windowBits -15          |
| `zipir-bgzf`         | 0.1.2         | bgzf    | prime    | 1, 5, 9 | 1, 5, 9                       | streaming   | this repository, Zig adapter                  |
| `bgzip-libdeflate`   | 1.24          | bgzf    | prime    | 0-9     | 1, 5, 9                       | streaming   | htslib `bgzip -@1`, static libdeflate         |
| `bgzip-zlib-ng`      | 1.24          | bgzf    | prime    | 0-9     | 1, 5, 9                       | streaming   | htslib `bgzip -@1`, static zlib-ng (compat)   |

All peers run single-threaded. Every peer of a format decodes the same corpus file: Python zlib level 6 for zlib and raw DEFLATE, `bgzip -l 6` (htslib with host zlib) for BGZF. The zlib, raw DEFLATE, and BGZF compressors were added on 2026-09-26; `std-zlib` stays decode-only, and the standard library has no raw DEFLATE or BGZF peer. The zlib-API C adapter (`c/zlib_adapter.c`) and the libdeflate adapter serve both zlib and raw DEFLATE: `-DZIPIR_RAW` selects raw DEFLATE at build time.

The two `bgzip` peers are what bioinformatics users run: htslib's `bgzip` with one thread, built once with libdeflate (the usual distribution build) and once with zlib-ng in zlib-compatible mode. Both use htslib's default compiler flags; the codec libraries are built with native instructions like the other peers. `bgzip -l` takes 0 to 9; with libdeflate, htslib maps it to libdeflate levels (1, 5, 9 become 1, 6, 12). By default `bgzip` ends blocks at line breaks for text input; `zipir-bgzf` follows the same rule as the zipir CLI (line breaks unless the first 64 KiB contain a NUL byte).

A full-buffer decoder reads the whole input and allocates the whole output. Its throughput and memory are reported but never ranked against streaming decoders. `libdeflate-zlib` is also told the output size, which a streaming decoder never knows.

`bgzip` (no suffix) from htslib 1.24 is a format oracle, not a peer; the timed BGZF peers are `bgzip-libdeflate` and `bgzip-zlib-ng`. The oracle is built without libdeflate (`configure` links libdeflate silently when its headers exist), is never timed, and answers only format questions: `-t` integrity, `.gzi` indexes, block boundaries. Its compressed bytes depend on the linked zlib and are never compared with zipir's.

## Choosing peers and levels

`--peers` picks tiers, and the tiers nest:

- `prime` (default): zipir, zlib-ng, ISA-L, and the Zig standard library. This is the development set.
- `extended`: prime plus libdeflate, GNU gzip, and host zlib. Use it to check a claim more widely.
- `all`: extended plus pigz and both flate2 backends.

`--levels` picks compression levels:

- `lanes` (default): each compressor's fast, balanced, and dense level from `peers.tsv`.
- `all`: every level in `peers.tsv`.

Decode rows always run. A tool named on the command line runs whatever its tier. `--list` prints the planned matrix and the corpus size without running anything.

Lanes come from peer-only measurements, never from a zipir result. zipir's presets `fast`, `even`, and `dense` run in the lanes `fast`, `balanced`, and `dense` (levels 1, 5, and 9). zlib-ng uses 1, 5, and 9 too. igzip uses 0, 1, and 2 because level 3 was never on its own frontier in the 2026-09-23 run. libdeflate's 1, 6, and 12 are provisional until its frontier is measured.

## Corpus

`data/{category}/{format}/{class}/{file}` for categories `sequencing`, `ms`, `generalized`, classes `sanity`, `small`, `medium`, `large`, and formats `gzip`, `zlib`, `deflate`, `bgzf`. `corpus.sh` fetches the pinned rows first, then derives the others: `derive:zlib-6` (Python zlib level 6), `derive:deflate-6` (the same as raw DEFLATE; sanity, small, and medium only), and `derive:bgzip-6` (pinned `bgzip -l 6 -@ 1`). Each derived file gets a `.derive.tsv` sidecar with its recipe, tool version, and the size and mtime of its source and itself. `corpus.sh --check` decodes every file against its source; the BGZF check walks every block independently of zipir.

## Install

```bash
tools/install.sh [--rebuild | --check] [NAME | prime | extended | all]
tools/install.sh --list
```

Each peer goes into `tools/.local/installs/NAME/VERSION/` with a `receipt.tsv` (source, compiler, build profile, commit), and `tools/bin/NAME` links to it. `--check` confirms the version each binary reports and that native engines do not link Fedora's libdeflate, ISA-L, or zlib. A Zig adapter is stale when any of its sources (`src/` and the root build files for the zipir adapters, `tools/zig/` and the tools build files for all of them) is newer than its build; `--check` then fails and a plain install rebuilds it. After you change the library, `tools/install.sh prime` rebuilds the four zipir adapters. The staleness check covers Zig sources only: after changing a C adapter, run `tools/install.sh --rebuild NAME`. A reinstall renames the previous install to `tools/.local/installs/NAME/replaced/` instead of deleting it. Source archives (libdeflate, ISA-L, zlib-ng, htslib) are pinned by version in `common.sh` with a SHA-256 each, recorded from the archive as first downloaded (the publishers give none for GitHub tag archives); a download that does not match is refused before it is unpacked. Source builds use a `/tmp/zipir-tools.*` work directory and `TOOL_JOBS` jobs (default 2). The scripts never delete recursively: on exit they remove the files they made, and a directory that is not empty afterwards (a source build tree) is left in `/tmp` and printed (`KEEP_TOOL_WORK=1` keeps everything).

## Qualify

```bash
tools/qualify.sh [--peers SET] [--levels SET] [--category C] [--class C[,C...] | --full] [--list] [TOOL...]
```

For each peer and corpus file, `qualify.sh` checks decoded bytes against GNU gzip or Python zlib (raw DEFLATE with windowBits -15), never against another peer. Compressors of zlib, raw DEFLATE, and BGZF must write output that the reference decodes to the input (BGZF output must also pass the independent block walker in `common.sh`) and must round-trip it themselves. BGZF decoders must decode two joined BGZF files and reject a cut inside a data block; a missing EOF marker and a flipped block CRC are recorded, not required. Raw DEFLATE decoders must reject truncation and trailing data; a flipped body byte is recorded (the format has no check value). Compressors must write output that GNU gzip accepts and decodes to the input, and must round-trip it themselves. On sanity files it also checks stdin input, concatenated members, truncation, flipped body bytes, and flipped trailer fields; zlib peers must also reject a bad header, bad Adler-32, trailing data, and preset dictionaries. The `crc`, `isize`, and `concat` columns of `peers.tsv` say which gzip checks block a peer; the others are recorded as observed.

Results go to `tools/.local/qualify/TOOL/checks.tsv` and `receipt.tsv`. The receipt records the qualified levels, classes, and category, and the binary's path, size, and mtime.

## Bench

```bash
tools/bench.sh [--peers SET] [--levels SET] [--category C] [--class C[,C...] | --full] [--force] [--list] [TOOL...]
```

This is the matched method used for every comparison we report. For each corpus file and operation, all selected subjects run in one Zebrac batch: Zebrac runs every command once per round in a changing order, with 3 warmups and exactly 25 rounds, pinned to one CPU with `taskset -c $BENCH_CPU` (default 4). A busy machine then slows every subject in the same rounds, so the ratios stay fair. The 1-minute load average before and after each batch is recorded.

The zipir tool of each format is always in the batch as the anchor. Before timing, `bench.sh` compresses once with each subject, records the bytes, and checks that GNU gzip decodes them to the input. A tool is timed only if its qualify receipt passed on the same binary and covers the levels, classes, and category being timed; `--full` timing needs `qualify.sh --full` first.

Results go to `tools/.local/bench/RUN/FORMAT/OP/CATEGORY.CLASS.{json,tsv}`. RUN is `PEER_SET-LEVEL_SET` (for example `prime-lanes`), or `named-TOOL+TOOL-LEVEL_SET` when tools are named. A batch is skipped when its subjects, lanes, binaries, and input are unchanged; `--force` re-times it.

The default run (prime, lanes, sanity and small, all four formats) took 7 minutes 20 seconds on 2026-09-26 (48 batches). Medium files multiply that: decompression of the three medium files took 3.5 minutes, but compression of sequencing and MS medium took 59 minutes, most of it the slow level 9 peers (stdlib gzip 9 and `bgzip -l 9`, which is libdeflate 12). Check `--list` first, and use `--op` and `--category` to limit a run.

## Report

```bash
tools/report.py [--check] [RUN]
```

`bench.sh` runs it at the end. It writes `tools/.local/report/RUN/facts.tsv`, with one row per file, operation, tool, and level, and `summary.md`, with a lane table per format, operation, and class and a per-file table for each format and operation. Lane tables leave out the sanity files, which mostly measure process start-up, unless a run has nothing else. A run directory whose batches used different zipir binaries is reported as a problem. Every row is compared with zipir in the same batch: time and RSS against the same operation, size against zipir's level in the same lane. MB/s is uncompressed bytes per second (10^6). `--check` only validates the batches.

## Adding a peer

1. Add a row to `peers.tsv`, with lanes from a peer-only frontier measurement.
2. Pin its version in `common.sh` and add it to `version_for`.
3. If it is not a path-CLI adapter (`NAME compress --level N IN OUT`, `NAME decompress IN OUT`), add its command line to `tool_cmd` in `common.sh`.
4. Add its build to `build_target` in `install.sh`, and its version probe or forbidden libraries to `check_target` if they differ from the default.
5. Run `tools/install.sh NAME`, `tools/qualify.sh NAME`, and `tools/bench.sh NAME`.
