# Development tools

Optional maintainer tooling for comparison adapters. End users do not need it to build or run z-flate.

Linux x86_64 only. One installer. Tracked files describe the toolchain. Everything it generates stays under ignored `tools/.local/` and `tools/bin/`. Qualify and bench decompress one file at a time into `/tmp` and delete it. They do not cache uncompressed copies under `.local/`.

The comparison row is `tool + format + operation + level + threads + category + class + file + host`. `tools/peers.tsv` is the run matrix (what we time). `tools/levels.tsv` is the scale, default, and fast knob for each tool. `tools/coverage.tsv` is the capability matrix (yes/no/size). `tools/LOG.md` is why a tool is live, dropped, later, or never. This table is ST gzip only: no `pigz -p32`, no `igzip -T`. Zebrac JSON is keyed on disk as `tools/.local/zebrac/TOOL/FORMAT/LEVEL/THREADS/category.class.op.json`. Decompress `LEVEL` is `-`. `tools/report.sh` unions those into `tools/.local/report/facts.tsv`, `headline.tsv`, and `gmean.tsv`, and fills the generated sections below. Do not type digits into those sections.

```bash
tools/install.sh
tools/install.sh std-gzip
tools/install.sh --rebuild std-gzip
tools/install.sh --check all
tools/install.sh --list
tools/corpus.sh
tools/corpus.sh --check
tools/corpus.sh --list
tools/qualify.sh std-gzip
tools/bench.sh std-gzip
tools/bench.sh --force std-gzip
tools/report.sh
tools/report.sh --check
tools/qualify.sh --full std-gzip
tools/bench.sh --full std-gzip
```

Requires `zig` 0.16.0 on `PATH` for `std-gzip`. `libdeflate-gzip`, `igzip`, and `zlib-ng` need `cmake` (`igzip` also `nasm`) to build the native C CLIs. `flate2-miniz` and `flate2-zlib-rs` need `cargo`/`rustc`. Corpus fetch needs `curl`, `gzip`, and `sha256sum`. Host `gzip` 1.14 and `pigz` 2.8 are used in place (`pigz` always `-p1`). C CLIs are not spawned from a Zig parent. Zebrac execs the native program; it already sinks child stdout. Caches stay under `/tmp/z-flate-tools.*`. Does not install system packages, write `/usr` or `/usr/local`, or change the shell.

## Current tools

| Tool | Version | Source |
| --- | --- | --- |
| `std-gzip` | 0.16.0 | Zig 0.16 `std.compress.flate` gzip |
| `gnu-gzip` | 1.14 | host `/usr/bin/gzip`, ST, `-n` |
| `libdeflate-gzip` | 1.26 | local native `libdeflate-gzip` CLI |
| `igzip` | 2.32.1 | local native ISA-L CLI, ST, no `-T` |
| `pigz` | 2.8 | host `/usr/bin/pigz -p1` |
| `flate2-miniz` | 1.1.10 | Rust flate2 `rust_backend` (miniz_oxide) |
| `flate2-zlib-rs` | 1.1.10 | Rust flate2 `zlib-rs` 0.6.7 |
| `zlib-ng` | 2.3.3 | local native zlib-ng `minigzip` CLI |

```bash
tools/bin/std-gzip --version
tools/bin/std-gzip compress --level 6 IN OUT
/usr/bin/gzip -n -6 -c IN
/usr/bin/pigz -p1 -n -6 -c IN
tools/bin/igzip -n -2 -c IN
```

Language adapters (`std-gzip`, `flate2-miniz`, `flate2-zlib-rs`) take `IN` and `OUT` paths. Use `-` for stdin or stdout. C/host tools use their own CLI. Zebrac does not run shell redirects; for native CLIs it execs `gzip -c` / `igzip -c` / `zlib-ng -c` and sinks the child's stdout.

Qualify a tool before timing it. Peer Zebrac JSON is captured once after the tool is set. `bench.sh` skips complete JSON (`sample_count=25`, no failures) unless `--force`. Rebuild, flag, runtime, or corpus changes require a new qualify and `--force` Zebrac.

## Comparison matrix

Coverage first, then the numbers we actually measured. Coverage cells are `yes`, `no`, a size, or `-`. One row per installed peer.

### Work

<!-- generated:work -->
| Tool | Format | Compress | Decompress | Level | ST | MT |
| --- | --- | --- | --- | --- | --- | --- |
| `std-gzip` | gzip | yes | yes | 1 2 3 4 5 6 7 8 9 | yes | no |
| `gnu-gzip` | gzip | yes | yes | 1 2 3 4 5 6 7 8 9 | yes | no |
| `libdeflate-gzip` | gzip | yes | yes | 1 2 3 4 5 6 7 8 9 10 11 12 | yes | no |
| `igzip` | gzip | yes | yes | 0 1 2 3 | yes | no |
| `pigz` | gzip | yes | yes | 0 1 2 3 4 5 6 7 8 9 | yes | no |
| `flate2-miniz` | gzip | yes | yes | 0 1 2 3 4 5 6 7 8 9 | yes | no |
| `flate2-zlib-rs` | gzip | yes | yes | 0 1 2 3 4 5 6 7 8 9 | yes | no |
| `zlib-ng` | gzip | yes | yes | 0 1 2 3 4 5 6 7 8 9 | yes | no |
<!-- /generated:work -->

### Shape

<!-- generated:shape -->
| Tool | Stream | Bound | Window | Heap |
| --- | --- | --- | --- | --- |
| `std-gzip` | yes | yes | 32 KiB | no |
| `gnu-gzip` | yes | yes | 32 KiB | no |
| `libdeflate-gzip` | no | no | 32 KiB | yes |
| `igzip` | yes | yes | 32 KiB | yes |
| `pigz` | yes | yes | 32 KiB | no |
| `flate2-miniz` | yes | no | 32 KiB | yes |
| `flate2-zlib-rs` | yes | no | 32 KiB | yes |
| `zlib-ng` | yes | yes | 32 KiB | no |
<!-- /generated:shape -->

### Integrity

<!-- generated:integrity -->
| Tool | CRC | ISIZE | Concat | Cap | Dict |
| --- | --- | --- | --- | --- | --- |
| `std-gzip` | no | no | no | no | no |
| `gnu-gzip` | yes | yes | yes | no | no |
| `libdeflate-gzip` | yes | hint | yes | no | no |
| `igzip` | yes | yes | yes | no | no |
| `pigz` | yes | yes | yes | no | no |
| `flate2-miniz` | yes | yes | yes | no | no |
| `flate2-zlib-rs` | yes | yes | yes | no | no |
| `zlib-ng` | yes | yes | yes | no | no |
<!-- /generated:integrity -->

### Keys

- **`Format`:** container on the wire. gzip is DEFLATE plus a header and footer, not a different algorithm.
- **`Compress` / `Decompress`:** that operation exists on this tool.
- **`Level`:** levels we qualify and time, on that tool's own scale. See `tools/levels.tsv`. Defaults: gzip-family `6` (GNU gzip, pigz, libdeflate, flate2, zlib-ng, std-gzip); ISA-L `2`. Full sets: GNU/std `1-9` (no `0`); pigz/flate2/zlib-ng `0-9`; libdeflate CLI `1-12` (library `0` exists, this binary skips `-0`); igzip `0-3`. Those integers are not interchangeable: `igzip -2` is not `gzip -6`. `igzip -6` is invalid. pigz `-11` is zopfli, not a gzip level, and is not timed. Compare rows, not the numeral. Decompress is `-`. Drops and exclusions: `tools/LOG.md`.
- **`ST` / `MT`:** has a single-thread mode; has a multi-thread mode. Not a thread count.
- **`Stream`:** reads and writes in chunks. Does not require the whole file in RAM.
- **`Bound`:** working set is a fixed window and I/O buffers, not sized from the input or from ISIZE.
- **`Window`:** history the decoder must keep. DEFLATE is 32 KiB. zstd defaults to 8 MiB. This dominates RAM more than the 64 KiB I/O buffer.
- **`Heap`:** codec allocates beyond those fixed buffers (xz/lzma dictionaries do; this adapter does not).
- **`CRC`:** gzip footer CRC-32 of the uncompressed bytes. `gzip -t` checks it. Inflate success is not the same thing. Zig std reads the footer and never compares the hash, so this is `no`.
- **`ISIZE`:** uncompressed length stored mod 2^32. `gzip -t` checks it. It is not an output cap. Files larger than 4 GiB wrap. Zig std ignores it.
- **`Concat`:** further gzip members after the first. `gzip -dc` concatenates them. std stops after one member and leaves the rest unread.
- **`Cap`:** caller-imposed max output. Independent of ISIZE. Stops a decompression bomb when the footer lies or is missing.
- **`Dict`:** preset dictionary (zlib `FDICT`, zstd dictionary). Normal gzip has none.
- **`gzip-rel`:** this tool's uncompressed MB/s divided by host `gnu-gzip` on the same file, format, threads, and host. Decode has no level. Encode vs gzip `-6` is only a ranking inside the default-ratio band. Encode vs gzip `-1` is only a ranking inside the fast band. Same-integer gzip-rel is empty when GNU gzip has no that level (`0`, `10-12`, igzip `0-3`).
- **`Band`:** kept vs this file's gzip oracles, not vs the tool's level name. `store` if kept >= 99% or this tool's store level. `default` if `|kept - gzip -6 kept| <= 1.5` percentage points. `fast` if not default and `|kept - gzip -1 kept| <= 3.0`. Closer oracle wins if both match. `out` otherwise. igzip `-2` is not gzip `-6`.
- **`RSS / file`:** Zebrac peak RSS / uncompressed bytes. Bound codecs stay a small fraction of the 19 MiB FASTQ. libdeflate scales with the file. Do not rank by MB/s per MiB RSS.
- **`gmean`:** geometric mean of gzip-rel across the `class=small` files in that band. Encode ranking requires the sequencing file in-band. Sanity is startup and is not mixed in.

### Normalized

`class=small` only. Oracle is host `gnu-gzip`. Tool default and fast knobs come from `tools/levels.tsv`.

<!-- generated:normalized -->
- Host: fedora-pc. Oracle: `gnu-gzip`. `class=small` only.
- Store if kept >= 99% or this tool's store level. Default band: `|kept - gzip -6 kept| <= 1.5` pp. Fast band: `|kept - gzip -1 kept| <= 3` pp. Closer oracle wins if both match.
- gzip-rel is this tool's uncompressed MB/s divided by host `gnu-gzip` on the same file, format, threads, and host. Decode has no level. Encode vs `-6` ranks only inside the default band. Encode vs `-1` ranks only inside the fast band.
- Geometric mean is over the small files in that band. Encode ranking tables require the sequencing file in-band; other files can drop out (`n` < 3). Tool defaults whose sequencing kept is not gzip `-6` go to the out table, not the default-ratio ranking.
- RSS / file is peak RSS / uncompressed bytes. Do not rank by MB/s per MiB RSS.

#### Decode gzip-rel

| Tool | Sequencing | MS | Generalized | gmean | n |
| --- | ---: | ---: | ---: | ---: | ---: |
| `igzip` | 2.15x | 1.46x | 1.79x | 1.78x | 3 |
| `zlib-ng` | 1.81x | 1.50x | 1.77x | 1.69x | 3 |
| `libdeflate-gzip` | 1.34x | 1.52x | 1.49x | 1.45x | 3 |
| `flate2-zlib-rs` | 1.40x | 1.31x | 1.47x | 1.39x | 3 |
| `pigz` | 1.28x | 1.24x | 1.29x | 1.27x | 3 |
| `flate2-miniz` | 1.09x | 1.16x | 1.21x | 1.15x | 3 |
| `gnu-gzip` | 1.00x | 1.00x | 1.00x | 1.00x | 3 |
| `std-gzip` | 0.92x | 0.97x | 0.92x | 0.94x | 3 |

#### Encode, gzip -6 kept band

Each tool at its `levels.tsv` default. Sequencing kept must be in the gzip `-6` band. Rel is vs gzip `-6`. Kept and MB/s are the sequencing file. A blank category is a small file outside the band.

| Tool | Level | Kept | vs gzip -6 | Band | Encode MB/s | Sequencing | MS | Generalized | gmean | n |
| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `libdeflate-gzip` | 6 | 16.3% | -0.1 | default | 108.4 | 2.49x |  | 3.02x | 2.74x | 2 |
| `zlib-ng` | 6 | 16.1% | -0.2 | default | 92.1 | 2.11x | 2.08x | 2.87x | 2.33x | 3 |
| `flate2-zlib-rs` | 6 | 16.1% | -0.2 | default | 91.5 | 2.10x | 1.99x | 2.85x | 2.29x | 3 |
| `pigz` | 6 | 16.0% | -0.4 | default | 78.3 | 1.80x | 1.77x | 1.94x | 1.84x | 3 |
| `std-gzip` | 6 | 17.0% | +0.6 | default | 48.6 | 1.12x | 0.92x | 1.16x | 1.06x | 3 |
| `gnu-gzip` | 6 | 16.3% | +0.0 | default | 43.5 | 1.00x | 1.00x | 1.00x | 1.00x | 3 |
| `flate2-miniz` | 6 | 16.2% | -0.2 | default | 36.5 | 0.84x | 0.94x | 0.80x | 0.86x | 3 |

#### Encode, gzip -1 kept band

Each tool at its `levels.tsv` fast level. Sequencing kept must be in the gzip `-1` band. Rel is vs gzip `-1`. zlib-ng / zlib-rs `-1` is fatter than this band and is not here.

| Tool | Level | Kept | vs gzip -6 | Band | Encode MB/s | Sequencing | MS | Generalized | gmean | n |
| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `igzip` | 0 | 24.4% | +8.0 | fast | 562.1 | 3.75x |  | 3.29x | 3.51x | 2 |
| `libdeflate-gzip` | 1 | 19.9% | +3.6 | fast | 274.0 | 1.83x |  | 2.04x | 1.93x | 2 |
| `flate2-miniz` | 1 | 25.1% | +8.7 | fast | 227.5 | 1.52x | 1.48x |  | 1.50x | 2 |
| `pigz` | 1 | 19.1% | +2.8 | fast | 217.5 | 1.45x |  | 1.35x | 1.40x | 2 |
| `gnu-gzip` | 1 | 22.1% | +5.8 | fast | 149.9 | 1.00x | 1.00x | 1.00x | 1.00x | 3 |
| `std-gzip` | 1 | 22.3% | +6.0 | fast | 90.5 | 0.60x | 0.63x | 0.74x | 0.66x | 3 |

#### Encode, tool default outside gzip -6 band

Not a ranking. Tool default whose sequencing kept is not in the gzip `-6` band. Rel vs gzip `-6` is shown for all three small files. igzip `-2` lives here.

| Tool | Level | Kept | vs gzip -6 | Band | Encode MB/s | Sequencing | MS | Generalized | gmean | n |
| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `igzip` | 2 | 20.3% | +4.0 | fast | 503.0 | 11.55x | 5.60x | 11.89x | 9.16x | 3 |

#### RSS at tool default, sequencing small

| Tool | Level | Encode MB/s | Decode MB/s | Encode RSS | Decode RSS | Enc RSS/file | Dec RSS/file | Bound |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `flate2-miniz` | 6 | 36.5 | 565.7 | 2.15 MiB | 2.16 MiB | 0.112 | 0.112 | no |
| `flate2-zlib-rs` | 6 | 91.5 | 724.9 | 2.36 MiB | 2.09 MiB | 0.123 | 0.109 | no |
| `gnu-gzip` | 6 | 43.5 | 517.9 | 1.86 MiB | 1.61 MiB | 0.097 | 0.084 | yes |
| `igzip` | 2 | 503.0 | 1112.2 | 3.34 MiB | 3.60 MiB | 0.173 | 0.187 | yes |
| `libdeflate-gzip` | 6 | 108.4 | 691.7 | 23.68 MiB | 23.71 MiB | 1.228 | 1.230 | no |
| `pigz` | 6 | 78.3 | 663.2 | 2.66 MiB | 2.17 MiB | 0.138 | 0.112 | yes |
| `std-gzip` | 6 | 48.6 | 477.4 | 0.94 MiB | 0.95 MiB | 0.049 | 0.049 | yes |
| `zlib-ng` | 6 | 92.1 | 935.4 | 2.09 MiB | 1.90 MiB | 0.109 | 0.099 | yes |
<!-- /generated:normalized -->

### Measured

<!-- generated:measured -->
- Host: fedora-pc, AMD Ryzen 9 3950X 16-Core Processor, Linux 7.1.13-200.fc44.x86_64 x86_64
- Tools: `flate2-miniz`, `flate2-zlib-rs`, `gnu-gzip`, `igzip`, `libdeflate-gzip`, `pigz`, `std-gzip`, `zlib-ng`. Format `gzip`, threads ST. Compress levels are per tool in the tables.
- Zebrac 0.6.2: `-w 3 -i 25 -a 25`, sink `/dev/null`, no `-f`
- **Encode MB/s** / **Decode MB/s:** uncompressed bytes / median wall seconds / `10^6`. Same work unit for both directions.
- **Ratio:** uncompressed / this tool's compressed bytes. Higher is more compression.
- **Kept:** compressed / uncompressed as a percent. Lower is more compression.
- **gzip -6 kept:** host `gzip -6` on the same plaintext when format is gzip.
- **gzip-rel:** this tool's MB/s / `gnu-gzip` MB/s on the same file. Encode vs `-6` is `encode_gzip_rel_l6`. Decode has no level.
- **RSS / file:** peak RSS / uncompressed bytes. **Band:** store / default / fast / out from kept vs gzip `-6` and gzip `-1`.
- **RSS:** Zebrac peak RSS median.
- Sanity files are tens to hundreds of KiB. Those MB/s numbers are startup-heavy. Small is the class that actually times the codec. Headline views filter `class=small`. Normalized tables above use small only.

Machine-readable copies: `tools/.local/report/facts.tsv` (long, one row per key), `headline.tsv` (`class=small`, encode and decode joined), and `gmean.tsv` (suite gzip-rel). Per-tool `summary.tsv` and `measured.tsv` stay under `tools/.local/zebrac/TOOL/`.

#### Headline (`class=small`)

| Tool | Format | Level | Threads | Category | File | Encode MB/s | Decode MB/s | Ratio | Kept | gzip-rel vs -6 | Decode gzip-rel | Enc RSS/file | Band | Encode RSS | Decode RSS |
| --- | --- | ---: | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| `flate2-miniz` | gzip | 0 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 232.0 | 565.7 | 1.00x | 100.0% | 5.33x | 1.09x | 0.112 | store | 2.16 MiB | 2.16 MiB |
| `flate2-miniz` | gzip | 0 | ST | ms | `55merge_tandem.mzid.gz` | 187.9 | 320.3 | 1.00x | 100.0% | 3.88x | 1.16x | 1.982 | store | 2.34 MiB | 2.35 MiB |
| `flate2-miniz` | gzip | 0 | ST | generalized | `cantrbry.tar.gz` | 207.9 | 382.8 | 1.00x | 100.0% | 8.29x | 1.21x | 0.883 | store | 2.38 MiB | 2.36 MiB |
| `flate2-miniz` | gzip | 1 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 227.5 | 565.7 | 3.99x | 25.1% | 5.22x | 1.09x | 0.112 | fast | 2.16 MiB | 2.16 MiB |
| `flate2-miniz` | gzip | 1 | ST | ms | `55merge_tandem.mzid.gz` | 192.6 | 320.3 | 4.04x | 24.7% | 3.98x | 1.16x | 1.989 | fast | 2.35 MiB | 2.35 MiB |
| `flate2-miniz` | gzip | 1 | ST | generalized | `cantrbry.tar.gz` | 160.1 | 382.8 | 2.83x | 35.4% | 6.39x | 1.21x | 0.801 | out | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | gzip | 2 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 126.8 | 565.7 | 4.68x | 21.4% | 2.91x | 1.09x | 0.110 | fast | 2.13 MiB | 2.16 MiB |
| `flate2-miniz` | gzip | 2 | ST | ms | `55merge_tandem.mzid.gz` | 110.1 | 320.3 | 4.23x | 23.7% | 2.28x | 1.16x | 1.833 | fast | 2.16 MiB | 2.35 MiB |
| `flate2-miniz` | gzip | 2 | ST | generalized | `cantrbry.tar.gz` | 104.3 | 382.8 | 3.45x | 29.0% | 4.16x | 1.21x | 0.804 | fast | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | gzip | 3 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 87.1 | 565.7 | 5.57x | 18.0% | 2.00x | 1.09x | 0.111 | out | 2.14 MiB | 2.16 MiB |
| `flate2-miniz` | gzip | 3 | ST | ms | `55merge_tandem.mzid.gz` | 74.2 | 320.3 | 4.37x | 22.9% | 1.53x | 1.16x | 2.005 | default | 2.37 MiB | 2.35 MiB |
| `flate2-miniz` | gzip | 3 | ST | generalized | `cantrbry.tar.gz` | 60.4 | 382.8 | 3.58x | 28.0% | 2.41x | 1.21x | 0.797 | fast | 2.14 MiB | 2.36 MiB |
| `flate2-miniz` | gzip | 4 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 75.5 | 565.7 | 5.57x | 18.0% | 1.73x | 1.09x | 0.112 | out | 2.16 MiB | 2.16 MiB |
| `flate2-miniz` | gzip | 4 | ST | ms | `55merge_tandem.mzid.gz` | 59.1 | 320.3 | 4.44x | 22.5% | 1.22x | 1.16x | 2.012 | default | 2.38 MiB | 2.35 MiB |
| `flate2-miniz` | gzip | 4 | ST | generalized | `cantrbry.tar.gz` | 53.1 | 382.8 | 3.73x | 26.8% | 2.12x | 1.21x | 0.812 | default | 2.18 MiB | 2.36 MiB |
| `flate2-miniz` | gzip | 5 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 62.2 | 565.7 | 5.82x | 17.2% | 1.43x | 1.09x | 0.111 | default | 2.15 MiB | 2.16 MiB |
| `flate2-miniz` | gzip | 5 | ST | ms | `55merge_tandem.mzid.gz` | 52.2 | 320.3 | 4.47x | 22.4% | 1.08x | 1.16x | 1.995 | default | 2.36 MiB | 2.35 MiB |
| `flate2-miniz` | gzip | 5 | ST | generalized | `cantrbry.tar.gz` | 39.7 | 382.8 | 3.76x | 26.6% | 1.58x | 1.21x | 0.801 | default | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | gzip | 6 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 36.5 | 565.7 | 6.18x | 16.2% | 0.84x | 1.09x | 0.112 | default | 2.15 MiB | 2.16 MiB |
| `flate2-miniz` | gzip | 6 | ST | ms | `55merge_tandem.mzid.gz` | 45.4 | 320.3 | 4.51x | 22.2% | 0.94x | 1.16x | 2.012 | default | 2.38 MiB | 2.35 MiB |
| `flate2-miniz` | gzip | 6 | ST | generalized | `cantrbry.tar.gz` | 20.0 | 382.8 | 3.81x | 26.3% | 0.80x | 1.21x | 0.804 | default | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | gzip | 7 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 28.7 | 565.7 | 6.26x | 16.0% | 0.66x | 1.09x | 0.111 | default | 2.14 MiB | 2.16 MiB |
| `flate2-miniz` | gzip | 7 | ST | ms | `55merge_tandem.mzid.gz` | 41.7 | 320.3 | 4.53x | 22.1% | 0.86x | 1.16x | 1.979 | default | 2.34 MiB | 2.35 MiB |
| `flate2-miniz` | gzip | 7 | ST | generalized | `cantrbry.tar.gz` | 15.4 | 382.8 | 3.79x | 26.4% | 0.62x | 1.21x | 0.804 | default | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | gzip | 8 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 24.3 | 565.7 | 6.29x | 15.9% | 0.56x | 1.09x | 0.111 | default | 2.14 MiB | 2.16 MiB |
| `flate2-miniz` | gzip | 8 | ST | ms | `55merge_tandem.mzid.gz` | 39.5 | 320.3 | 4.53x | 22.1% | 0.82x | 1.16x | 1.833 | default | 2.16 MiB | 2.35 MiB |
| `flate2-miniz` | gzip | 8 | ST | generalized | `cantrbry.tar.gz` | 11.6 | 382.8 | 3.80x | 26.3% | 0.46x | 1.21x | 0.804 | default | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | gzip | 9 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 22.7 | 565.7 | 6.30x | 15.9% | 0.52x | 1.09x | 0.111 | default | 2.14 MiB | 2.16 MiB |
| `flate2-miniz` | gzip | 9 | ST | ms | `55merge_tandem.mzid.gz` | 38.2 | 320.3 | 4.54x | 22.0% | 0.79x | 1.16x | 2.025 | default | 2.39 MiB | 2.35 MiB |
| `flate2-miniz` | gzip | 9 | ST | generalized | `cantrbry.tar.gz` | 9.7 | 382.8 | 3.80x | 26.3% | 0.39x | 1.21x | 0.881 | default | 2.37 MiB | 2.36 MiB |
| `flate2-zlib-rs` | gzip | 0 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 2127.7 | 724.9 | 1.00x | 100.0% | 48.87x | 1.40x | 0.122 | store | 2.36 MiB | 2.09 MiB |
| `flate2-zlib-rs` | gzip | 0 | ST | ms | `55merge_tandem.mzid.gz` | 707.8 | 362.4 | 1.00x | 100.0% | 14.63x | 1.31x | 1.985 | store | 2.34 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 0 | ST | generalized | `cantrbry.tar.gz` | 1184.5 | 464.2 | 1.00x | 100.0% | 47.26x | 1.47x | 0.868 | store | 2.34 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 1 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 385.9 | 724.9 | 3.65x | 27.4% | 8.86x | 1.40x | 0.121 | out | 2.33 MiB | 2.09 MiB |
| `flate2-zlib-rs` | gzip | 1 | ST | ms | `55merge_tandem.mzid.gz` | 209.6 | 362.4 | 3.01x | 33.2% | 4.33x | 1.31x | 1.863 | out | 2.20 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 1 | ST | generalized | `cantrbry.tar.gz` | 249.2 | 464.2 | 2.45x | 40.8% | 9.94x | 1.47x | 0.819 | out | 2.20 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 2 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 225.1 | 724.9 | 5.24x | 19.1% | 5.17x | 1.40x | 0.123 | fast | 2.37 MiB | 2.09 MiB |
| `flate2-zlib-rs` | gzip | 2 | ST | ms | `55merge_tandem.mzid.gz` | 132.5 | 362.4 | 4.34x | 23.0% | 2.74x | 1.31x | 2.005 | default | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 2 | ST | generalized | `cantrbry.tar.gz` | 145.0 | 464.2 | 3.44x | 29.1% | 5.78x | 1.47x | 0.874 | fast | 2.35 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 3 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 159.4 | 724.9 | 5.42x | 18.5% | 3.66x | 1.40x | 0.123 | out | 2.37 MiB | 2.09 MiB |
| `flate2-zlib-rs` | gzip | 3 | ST | ms | `55merge_tandem.mzid.gz` | 113.8 | 362.4 | 4.42x | 22.6% | 2.35x | 1.31x | 2.008 | default | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 3 | ST | generalized | `cantrbry.tar.gz` | 114.0 | 464.2 | 3.64x | 27.5% | 4.55x | 1.47x | 0.873 | default | 2.35 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 4 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 138.1 | 724.9 | 5.85x | 17.1% | 3.17x | 1.40x | 0.123 | default | 2.38 MiB | 2.09 MiB |
| `flate2-zlib-rs` | gzip | 4 | ST | ms | `55merge_tandem.mzid.gz` | 108.2 | 362.4 | 4.55x | 22.0% | 2.24x | 1.31x | 1.989 | default | 2.35 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 4 | ST | generalized | `cantrbry.tar.gz` | 93.1 | 464.2 | 3.71x | 27.0% | 3.71x | 1.47x | 0.883 | default | 2.38 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 5 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 126.0 | 724.9 | 6.00x | 16.7% | 2.90x | 1.40x | 0.123 | default | 2.37 MiB | 2.09 MiB |
| `flate2-zlib-rs` | gzip | 5 | ST | ms | `55merge_tandem.mzid.gz` | 101.5 | 362.4 | 4.66x | 21.5% | 2.10x | 1.31x | 2.008 | default | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 5 | ST | generalized | `cantrbry.tar.gz` | 85.5 | 464.2 | 3.76x | 26.6% | 3.41x | 1.47x | 0.874 | default | 2.35 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 6 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 91.5 | 724.9 | 6.21x | 16.1% | 2.10x | 1.40x | 0.123 | default | 2.36 MiB | 2.09 MiB |
| `flate2-zlib-rs` | gzip | 6 | ST | ms | `55merge_tandem.mzid.gz` | 96.4 | 362.4 | 4.70x | 21.3% | 1.99x | 1.31x | 2.008 | default | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 6 | ST | generalized | `cantrbry.tar.gz` | 71.5 | 464.2 | 3.78x | 26.5% | 2.85x | 1.47x | 0.881 | default | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 7 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 64.9 | 724.9 | 6.34x | 15.8% | 1.49x | 1.40x | 0.122 | default | 2.36 MiB | 2.09 MiB |
| `flate2-zlib-rs` | gzip | 7 | ST | ms | `55merge_tandem.mzid.gz` | 81.9 | 362.4 | 4.72x | 21.2% | 1.69x | 1.31x | 2.002 | default | 2.36 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 7 | ST | generalized | `cantrbry.tar.gz` | 41.4 | 464.2 | 3.84x | 26.0% | 1.65x | 1.47x | 0.880 | default | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 8 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 36.5 | 724.9 | 6.43x | 15.6% | 0.84x | 1.40x | 0.122 | default | 2.34 MiB | 2.09 MiB |
| `flate2-zlib-rs` | gzip | 8 | ST | ms | `55merge_tandem.mzid.gz` | 67.5 | 362.4 | 4.77x | 21.0% | 1.40x | 1.31x | 2.008 | default | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 8 | ST | generalized | `cantrbry.tar.gz` | 13.1 | 464.2 | 3.86x | 25.9% | 0.52x | 1.47x | 0.870 | default | 2.34 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 9 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 47.4 | 724.9 | 6.26x | 16.0% | 1.09x | 1.40x | 0.121 | default | 2.34 MiB | 2.09 MiB |
| `flate2-zlib-rs` | gzip | 9 | ST | ms | `55merge_tandem.mzid.gz` | 50.2 | 362.4 | 4.52x | 22.1% | 1.04x | 1.31x | 1.998 | default | 2.36 MiB | 2.11 MiB |
| `flate2-zlib-rs` | gzip | 9 | ST | generalized | `cantrbry.tar.gz` | 11.1 | 464.2 | 3.85x | 26.0% | 0.44x | 1.47x | 0.880 | default | 2.37 MiB | 2.11 MiB |
| `gnu-gzip` | gzip | 1 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 149.9 | 517.9 | 4.53x | 22.1% | 3.44x | 1.00x | 0.097 | fast | 1.88 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 1 | ST | ms | `55merge_tandem.mzid.gz` | 130.5 | 276.3 | 4.02x | 24.9% | 2.70x | 1.00x | 1.605 | fast | 1.89 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 1 | ST | generalized | `cantrbry.tar.gz` | 104.7 | 315.2 | 3.23x | 30.9% | 4.18x | 1.00x | 0.707 | fast | 1.90 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 2 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 139.8 | 517.9 | 4.89x | 20.5% | 3.21x | 1.00x | 0.096 | fast | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 2 | ST | ms | `55merge_tandem.mzid.gz` | 118.1 | 276.3 | 4.09x | 24.5% | 2.44x | 1.00x | 1.595 | fast | 1.88 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 2 | ST | generalized | `cantrbry.tar.gz` | 94.8 | 315.2 | 3.35x | 29.8% | 3.78x | 1.00x | 0.697 | fast | 1.88 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 3 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 109.3 | 517.9 | 5.31x | 18.8% | 2.51x | 1.00x | 0.096 | out | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 3 | ST | ms | `55merge_tandem.mzid.gz` | 95.2 | 276.3 | 4.17x | 24.0% | 1.97x | 1.00x | 1.605 | fast | 1.89 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 3 | ST | generalized | `cantrbry.tar.gz` | 69.2 | 315.2 | 3.47x | 28.8% | 2.76x | 1.00x | 0.700 | fast | 1.88 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 4 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 93.8 | 517.9 | 5.33x | 18.8% | 2.15x | 1.00x | 0.096 | out | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 4 | ST | ms | `55merge_tandem.mzid.gz` | 71.9 | 276.3 | 4.25x | 23.5% | 1.49x | 1.00x | 1.578 | fast | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 4 | ST | generalized | `cantrbry.tar.gz` | 68.0 | 315.2 | 3.57x | 28.0% | 2.71x | 1.00x | 0.697 | fast | 1.88 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 5 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 66.0 | 517.9 | 5.74x | 17.4% | 1.52x | 1.00x | 0.096 | default | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 5 | ST | ms | `55merge_tandem.mzid.gz` | 53.5 | 276.3 | 4.41x | 22.7% | 1.11x | 1.00x | 1.611 | default | 1.90 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 5 | ST | generalized | `cantrbry.tar.gz` | 42.1 | 315.2 | 3.76x | 26.6% | 1.68x | 1.00x | 0.693 | default | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 6 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 43.5 | 517.9 | 6.12x | 16.3% | 1.00x | 1.00x | 0.097 | default | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 6 | ST | ms | `55merge_tandem.mzid.gz` | 48.4 | 276.3 | 4.52x | 22.1% | 1.00x | 1.00x | 1.565 | default | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 6 | ST | generalized | `cantrbry.tar.gz` | 25.1 | 315.2 | 3.82x | 26.2% | 1.00x | 1.00x | 0.690 | default | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 7 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 33.6 | 517.9 | 6.21x | 16.1% | 0.77x | 1.00x | 0.094 | default | 1.82 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 7 | ST | ms | `55merge_tandem.mzid.gz` | 47.5 | 276.3 | 4.54x | 22.0% | 0.98x | 1.00x | 1.572 | default | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 7 | ST | generalized | `cantrbry.tar.gz` | 20.4 | 315.2 | 3.81x | 26.3% | 0.82x | 1.00x | 0.688 | default | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 8 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 18.3 | 517.9 | 6.31x | 15.8% | 0.42x | 1.00x | 0.086 | default | 1.66 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 8 | ST | ms | `55merge_tandem.mzid.gz` | 40.7 | 276.3 | 4.59x | 21.8% | 0.84x | 1.00x | 1.565 | default | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 8 | ST | generalized | `cantrbry.tar.gz` | 8.9 | 315.2 | 3.83x | 26.1% | 0.36x | 1.00x | 0.685 | default | 1.84 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 9 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 15.3 | 517.9 | 6.32x | 15.8% | 0.35x | 1.00x | 0.086 | default | 1.66 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 9 | ST | ms | `55merge_tandem.mzid.gz` | 37.3 | 276.3 | 4.59x | 21.8% | 0.77x | 1.00x | 1.565 | default | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | gzip | 9 | ST | generalized | `cantrbry.tar.gz` | 4.9 | 315.2 | 3.83x | 26.1% | 0.20x | 1.00x | 0.675 | default | 1.82 MiB | 1.61 MiB |
| `igzip` | gzip | 0 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 562.1 | 1112.2 | 4.11x | 24.4% | 12.91x | 2.15x | 0.147 | fast | 2.84 MiB | 3.60 MiB |
| `igzip` | gzip | 0 | ST | ms | `55merge_tandem.mzid.gz` | 298.1 | 404.7 | 2.96x | 33.7% | 6.16x | 1.46x | 2.624 | out | 3.10 MiB | 2.88 MiB |
| `igzip` | gzip | 0 | ST | generalized | `cantrbry.tar.gz` | 344.1 | 565.0 | 2.96x | 33.8% | 13.73x | 1.79x | 1.151 | fast | 3.10 MiB | 3.38 MiB |
| `igzip` | gzip | 1 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 532.0 | 1112.2 | 4.88x | 20.5% | 12.22x | 2.15x | 0.161 | fast | 3.10 MiB | 3.60 MiB |
| `igzip` | gzip | 1 | ST | ms | `55merge_tandem.mzid.gz` | 271.4 | 404.7 | 4.29x | 23.3% | 5.61x | 1.46x | 2.624 | default | 3.10 MiB | 2.88 MiB |
| `igzip` | gzip | 1 | ST | generalized | `cantrbry.tar.gz` | 302.6 | 565.0 | 3.23x | 31.0% | 12.07x | 1.79x | 1.244 | fast | 3.35 MiB | 3.38 MiB |
| `igzip` | gzip | 2 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 503.0 | 1112.2 | 4.92x | 20.3% | 11.55x | 2.15x | 0.173 | fast | 3.34 MiB | 3.60 MiB |
| `igzip` | gzip | 2 | ST | ms | `55merge_tandem.mzid.gz` | 270.8 | 404.7 | 4.36x | 22.9% | 5.60x | 1.46x | 2.660 | default | 3.14 MiB | 2.88 MiB |
| `igzip` | gzip | 2 | ST | generalized | `cantrbry.tar.gz` | 298.1 | 565.0 | 3.28x | 30.5% | 11.89x | 1.79x | 1.244 | fast | 3.35 MiB | 3.38 MiB |
| `igzip` | gzip | 3 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 175.3 | 1112.2 | 4.92x | 20.3% | 4.03x | 2.15x | 0.174 | fast | 3.35 MiB | 3.60 MiB |
| `igzip` | gzip | 3 | ST | ms | `55merge_tandem.mzid.gz` | 143.9 | 404.7 | 4.35x | 23.0% | 2.97x | 1.46x | 2.667 | default | 3.15 MiB | 2.88 MiB |
| `igzip` | gzip | 3 | ST | generalized | `cantrbry.tar.gz` | 147.0 | 565.0 | 3.38x | 29.6% | 5.87x | 1.79x | 1.260 | fast | 3.39 MiB | 3.38 MiB |
| `libdeflate-gzip` | gzip | 1 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 274.0 | 691.7 | 5.03x | 19.9% | 6.29x | 1.34x | 1.268 | fast | 24.44 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 1 | ST | ms | `55merge_tandem.mzid.gz` | 185.5 | 418.9 | 4.42x | 22.6% | 3.83x | 1.52x | 2.445 | default | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 1 | ST | generalized | `cantrbry.tar.gz` | 214.0 | 471.0 | 3.56x | 28.1% | 8.54x | 1.49x | 1.816 | fast | 4.89 MiB | 4.88 MiB |
| `libdeflate-gzip` | gzip | 10 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 8.7 | 691.7 | 6.62x | 15.1% | 0.20x | 1.34x | 1.446 | default | 27.88 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 10 | ST | ms | `55merge_tandem.mzid.gz` | 11.6 | 418.9 | 4.97x | 20.1% | 0.24x | 1.52x | 7.081 | out | 8.36 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 10 | ST | generalized | `cantrbry.tar.gz` | 12.0 | 471.0 | 4.16x | 24.0% | 0.48x | 1.49x | 4.065 | out | 10.94 MiB | 4.88 MiB |
| `libdeflate-gzip` | gzip | 11 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 4.6 | 691.7 | 6.70x | 14.9% | 0.10x | 1.34x | 1.510 | default | 29.11 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 11 | ST | ms | `55merge_tandem.mzid.gz` | 6.3 | 418.9 | 5.14x | 19.4% | 0.13x | 1.52x | 7.709 | out | 9.10 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 11 | ST | generalized | `cantrbry.tar.gz` | 7.2 | 471.0 | 4.18x | 23.9% | 0.29x | 1.49x | 4.033 | out | 10.85 MiB | 4.88 MiB |
| `libdeflate-gzip` | gzip | 12 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 3.6 | 691.7 | 6.70x | 14.9% | 0.08x | 1.34x | 1.498 | default | 28.88 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 12 | ST | ms | `55merge_tandem.mzid.gz` | 2.8 | 418.9 | 5.16x | 19.4% | 0.06x | 1.52x | 9.195 | out | 10.86 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 12 | ST | generalized | `cantrbry.tar.gz` | 4.9 | 471.0 | 4.18x | 23.9% | 0.20x | 1.49x | 3.962 | out | 10.66 MiB | 4.88 MiB |
| `libdeflate-gzip` | gzip | 2 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 197.7 | 691.7 | 5.38x | 18.6% | 4.54x | 1.34x | 1.269 | out | 24.48 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 2 | ST | ms | `55merge_tandem.mzid.gz` | 145.2 | 418.9 | 4.42x | 22.6% | 3.00x | 1.52x | 2.670 | default | 3.15 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 2 | ST | generalized | `cantrbry.tar.gz` | 135.3 | 471.0 | 3.76x | 26.6% | 5.40x | 1.49x | 1.911 | default | 5.14 MiB | 4.88 MiB |
| `libdeflate-gzip` | gzip | 3 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 180.6 | 691.7 | 5.61x | 17.8% | 4.15x | 1.34x | 1.254 | default | 24.17 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 3 | ST | ms | `55merge_tandem.mzid.gz` | 137.5 | 418.9 | 4.45x | 22.5% | 2.84x | 1.52x | 2.670 | default | 3.15 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 3 | ST | generalized | `cantrbry.tar.gz` | 116.8 | 471.0 | 3.82x | 26.2% | 4.66x | 1.49x | 1.895 | default | 5.10 MiB | 4.88 MiB |
| `libdeflate-gzip` | gzip | 4 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 165.4 | 691.7 | 5.77x | 17.3% | 3.80x | 1.34x | 1.241 | default | 23.92 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 4 | ST | ms | `55merge_tandem.mzid.gz` | 137.6 | 418.9 | 4.56x | 21.9% | 2.84x | 1.52x | 2.657 | default | 3.14 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 4 | ST | generalized | `cantrbry.tar.gz` | 110.2 | 471.0 | 3.84x | 26.0% | 4.40x | 1.49x | 1.898 | default | 5.11 MiB | 4.88 MiB |
| `libdeflate-gzip` | gzip | 5 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 137.2 | 691.7 | 5.94x | 16.8% | 3.15x | 1.34x | 1.235 | default | 23.81 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 5 | ST | ms | `55merge_tandem.mzid.gz` | 114.1 | 418.9 | 4.76x | 21.0% | 2.36x | 1.52x | 2.452 | default | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 5 | ST | generalized | `cantrbry.tar.gz` | 91.5 | 471.0 | 3.88x | 25.8% | 3.65x | 1.49x | 1.895 | default | 5.10 MiB | 4.88 MiB |
| `libdeflate-gzip` | gzip | 6 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 108.4 | 691.7 | 6.14x | 16.3% | 2.49x | 1.34x | 1.228 | default | 23.68 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 6 | ST | ms | `55merge_tandem.mzid.gz` | 106.3 | 418.9 | 4.85x | 20.6% | 2.20x | 1.52x | 2.445 | out | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 6 | ST | generalized | `cantrbry.tar.gz` | 75.8 | 471.0 | 3.90x | 25.6% | 3.02x | 1.49x | 1.895 | default | 5.10 MiB | 4.88 MiB |
| `libdeflate-gzip` | gzip | 7 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 74.0 | 691.7 | 6.35x | 15.7% | 1.70x | 1.34x | 1.222 | default | 23.56 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 7 | ST | ms | `55merge_tandem.mzid.gz` | 98.7 | 418.9 | 4.92x | 20.3% | 2.04x | 1.52x | 2.445 | out | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 7 | ST | generalized | `cantrbry.tar.gz` | 55.7 | 471.0 | 3.92x | 25.5% | 2.22x | 1.49x | 1.898 | default | 5.11 MiB | 4.88 MiB |
| `libdeflate-gzip` | gzip | 8 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 42.5 | 691.7 | 6.47x | 15.5% | 0.98x | 1.34x | 1.205 | default | 23.24 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 8 | ST | ms | `55merge_tandem.mzid.gz` | 71.8 | 418.9 | 4.96x | 20.2% | 1.48x | 1.52x | 2.445 | out | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 8 | ST | generalized | `cantrbry.tar.gz` | 25.9 | 471.0 | 4.04x | 24.7% | 1.03x | 1.49x | 1.895 | default | 5.10 MiB | 4.88 MiB |
| `libdeflate-gzip` | gzip | 9 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 33.7 | 691.7 | 6.50x | 15.4% | 0.77x | 1.34x | 1.199 | default | 23.12 MiB | 23.71 MiB |
| `libdeflate-gzip` | gzip | 9 | ST | ms | `55merge_tandem.mzid.gz` | 56.4 | 418.9 | 4.97x | 20.1% | 1.17x | 1.52x | 2.445 | out | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | gzip | 9 | ST | generalized | `cantrbry.tar.gz` | 17.2 | 471.0 | 4.05x | 24.7% | 0.69x | 1.49x | 1.843 | out | 4.96 MiB | 4.88 MiB |
| `pigz` | gzip | 0 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 2660.8 | 663.2 | 1.00x | 100.0% | 61.11x | 1.28x | 0.150 | store | 2.90 MiB | 2.17 MiB |
| `pigz` | gzip | 0 | ST | ms | `55merge_tandem.mzid.gz` | 727.5 | 341.5 | 1.00x | 100.0% | 15.03x | 1.24x | 2.462 | store | 2.91 MiB | 2.20 MiB |
| `pigz` | gzip | 0 | ST | generalized | `cantrbry.tar.gz` | 1214.0 | 407.4 | 1.00x | 100.0% | 48.43x | 1.29x | 1.057 | store | 2.84 MiB | 2.20 MiB |
| `pigz` | gzip | 1 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 217.5 | 663.2 | 5.23x | 19.1% | 5.00x | 1.28x | 0.151 | fast | 2.91 MiB | 2.17 MiB |
| `pigz` | gzip | 1 | ST | ms | `55merge_tandem.mzid.gz` | 130.6 | 341.5 | 4.35x | 23.0% | 2.70x | 1.24x | 2.458 | default | 2.90 MiB | 2.20 MiB |
| `pigz` | gzip | 1 | ST | generalized | `cantrbry.tar.gz` | 141.5 | 407.4 | 3.45x | 29.0% | 5.64x | 1.29x | 1.085 | fast | 2.92 MiB | 2.20 MiB |
| `pigz` | gzip | 2 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 208.4 | 663.2 | 5.46x | 18.3% | 4.79x | 1.28x | 0.147 | out | 2.84 MiB | 2.17 MiB |
| `pigz` | gzip | 2 | ST | ms | `55merge_tandem.mzid.gz` | 127.8 | 341.5 | 4.40x | 22.7% | 2.64x | 1.24x | 2.472 | default | 2.92 MiB | 2.20 MiB |
| `pigz` | gzip | 2 | ST | generalized | `cantrbry.tar.gz` | 124.2 | 407.4 | 3.55x | 28.2% | 4.96x | 1.29x | 1.079 | fast | 2.90 MiB | 2.20 MiB |
| `pigz` | gzip | 3 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 175.4 | 663.2 | 5.62x | 17.8% | 4.03x | 1.28x | 0.138 | default | 2.67 MiB | 2.17 MiB |
| `pigz` | gzip | 3 | ST | ms | `55merge_tandem.mzid.gz` | 126.5 | 341.5 | 4.47x | 22.4% | 2.61x | 1.24x | 2.462 | default | 2.91 MiB | 2.20 MiB |
| `pigz` | gzip | 3 | ST | generalized | `cantrbry.tar.gz` | 104.9 | 407.4 | 3.61x | 27.7% | 4.18x | 1.29x | 1.083 | default | 2.91 MiB | 2.20 MiB |
| `pigz` | gzip | 4 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 141.7 | 663.2 | 5.68x | 17.6% | 3.25x | 1.28x | 0.138 | default | 2.66 MiB | 2.17 MiB |
| `pigz` | gzip | 4 | ST | ms | `55merge_tandem.mzid.gz` | 102.5 | 341.5 | 4.44x | 22.5% | 2.12x | 1.24x | 2.472 | default | 2.92 MiB | 2.20 MiB |
| `pigz` | gzip | 4 | ST | generalized | `cantrbry.tar.gz` | 91.2 | 407.4 | 3.71x | 26.9% | 3.64x | 1.29x | 1.079 | default | 2.90 MiB | 2.20 MiB |
| `pigz` | gzip | 5 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 109.6 | 663.2 | 6.02x | 16.6% | 2.52x | 1.28x | 0.138 | default | 2.65 MiB | 2.17 MiB |
| `pigz` | gzip | 5 | ST | ms | `55merge_tandem.mzid.gz` | 91.1 | 341.5 | 4.61x | 21.7% | 1.88x | 1.24x | 2.452 | default | 2.89 MiB | 2.20 MiB |
| `pigz` | gzip | 5 | ST | generalized | `cantrbry.tar.gz` | 65.5 | 407.4 | 3.81x | 26.3% | 2.61x | 1.29x | 1.080 | default | 2.91 MiB | 2.20 MiB |
| `pigz` | gzip | 6 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 78.3 | 663.2 | 6.26x | 16.0% | 1.80x | 1.28x | 0.138 | default | 2.66 MiB | 2.17 MiB |
| `pigz` | gzip | 6 | ST | ms | `55merge_tandem.mzid.gz` | 85.8 | 341.5 | 4.71x | 21.2% | 1.77x | 1.24x | 2.468 | default | 2.91 MiB | 2.20 MiB |
| `pigz` | gzip | 6 | ST | generalized | `cantrbry.tar.gz` | 48.6 | 407.4 | 3.84x | 26.1% | 1.94x | 1.29x | 1.080 | default | 2.91 MiB | 2.20 MiB |
| `pigz` | gzip | 7 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 63.4 | 663.2 | 6.33x | 15.8% | 1.46x | 1.28x | 0.138 | default | 2.65 MiB | 2.17 MiB |
| `pigz` | gzip | 7 | ST | ms | `55merge_tandem.mzid.gz` | 82.6 | 341.5 | 4.73x | 21.1% | 1.71x | 1.24x | 2.472 | default | 2.92 MiB | 2.20 MiB |
| `pigz` | gzip | 7 | ST | generalized | `cantrbry.tar.gz` | 40.8 | 407.4 | 3.85x | 26.0% | 1.63x | 1.29x | 1.076 | default | 2.89 MiB | 2.20 MiB |
| `pigz` | gzip | 8 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 34.8 | 663.2 | 6.43x | 15.6% | 0.80x | 1.28x | 0.138 | default | 2.65 MiB | 2.17 MiB |
| `pigz` | gzip | 8 | ST | ms | `55merge_tandem.mzid.gz` | 66.9 | 341.5 | 4.78x | 20.9% | 1.38x | 1.24x | 2.472 | default | 2.92 MiB | 2.20 MiB |
| `pigz` | gzip | 8 | ST | generalized | `cantrbry.tar.gz` | 12.4 | 407.4 | 3.87x | 25.9% | 0.50x | 1.29x | 1.079 | default | 2.90 MiB | 2.20 MiB |
| `pigz` | gzip | 9 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 43.6 | 663.2 | 6.25x | 16.0% | 1.00x | 1.28x | 0.135 | default | 2.59 MiB | 2.17 MiB |
| `pigz` | gzip | 9 | ST | ms | `55merge_tandem.mzid.gz` | 46.1 | 341.5 | 4.52x | 22.1% | 0.95x | 1.24x | 2.472 | default | 2.92 MiB | 2.20 MiB |
| `pigz` | gzip | 9 | ST | generalized | `cantrbry.tar.gz` | 10.2 | 407.4 | 3.86x | 25.9% | 0.41x | 1.29x | 1.079 | default | 2.90 MiB | 2.20 MiB |
| `std-gzip` | gzip | 1 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 90.5 | 477.4 | 4.49x | 22.3% | 2.08x | 0.92x | 0.049 | fast | 0.94 MiB | 0.95 MiB |
| `std-gzip` | gzip | 1 | ST | ms | `55merge_tandem.mzid.gz` | 82.6 | 268.9 | 3.97x | 25.2% | 1.71x | 0.97x | 0.797 | fast | 0.94 MiB | 0.95 MiB |
| `std-gzip` | gzip | 1 | ST | generalized | `cantrbry.tar.gz` | 77.0 | 288.9 | 3.30x | 30.3% | 3.07x | 0.92x | 0.350 | fast | 0.94 MiB | 0.95 MiB |
| `std-gzip` | gzip | 2 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 87.9 | 477.4 | 4.65x | 21.5% | 2.02x | 0.92x | 0.049 | fast | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 2 | ST | ms | `55merge_tandem.mzid.gz` | 76.0 | 268.9 | 4.06x | 24.6% | 1.57x | 0.97x | 0.801 | fast | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 2 | ST | generalized | `cantrbry.tar.gz` | 73.4 | 288.9 | 3.39x | 29.5% | 2.93x | 0.92x | 0.351 | fast | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 3 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 81.3 | 477.4 | 5.04x | 19.8% | 1.87x | 0.92x | 0.049 | fast | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 3 | ST | ms | `55merge_tandem.mzid.gz` | 65.3 | 268.9 | 4.23x | 23.7% | 1.35x | 0.97x | 0.801 | fast | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 3 | ST | generalized | `cantrbry.tar.gz` | 61.5 | 288.9 | 3.53x | 28.3% | 2.45x | 0.92x | 0.351 | fast | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 4 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 81.9 | 477.4 | 4.90x | 20.4% | 1.88x | 0.92x | 0.049 | fast | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 4 | ST | ms | `55merge_tandem.mzid.gz` | 62.6 | 268.9 | 4.17x | 24.0% | 1.29x | 0.97x | 0.801 | fast | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 4 | ST | generalized | `cantrbry.tar.gz` | 65.5 | 288.9 | 3.51x | 28.5% | 2.61x | 0.92x | 0.351 | fast | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 5 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 63.8 | 477.4 | 5.54x | 18.1% | 1.47x | 0.92x | 0.049 | out | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 5 | ST | ms | `55merge_tandem.mzid.gz` | 46.9 | 268.9 | 4.30x | 23.3% | 0.97x | 0.97x | 0.801 | default | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 5 | ST | generalized | `cantrbry.tar.gz` | 41.5 | 288.9 | 3.69x | 27.1% | 1.66x | 0.92x | 0.351 | default | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 6 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 48.6 | 477.4 | 5.90x | 17.0% | 1.12x | 0.92x | 0.049 | default | 0.94 MiB | 0.95 MiB |
| `std-gzip` | gzip | 6 | ST | ms | `55merge_tandem.mzid.gz` | 44.5 | 268.9 | 4.41x | 22.7% | 0.92x | 0.97x | 0.797 | default | 0.94 MiB | 0.95 MiB |
| `std-gzip` | gzip | 6 | ST | generalized | `cantrbry.tar.gz` | 29.0 | 288.9 | 3.75x | 26.7% | 1.16x | 0.92x | 0.350 | default | 0.94 MiB | 0.95 MiB |
| `std-gzip` | gzip | 7 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 39.4 | 477.4 | 6.02x | 16.6% | 0.90x | 0.92x | 0.049 | default | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 7 | ST | ms | `55merge_tandem.mzid.gz` | 43.2 | 268.9 | 4.44x | 22.5% | 0.89x | 0.97x | 0.801 | default | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 7 | ST | generalized | `cantrbry.tar.gz` | 24.3 | 288.9 | 3.77x | 26.5% | 0.97x | 0.92x | 0.351 | default | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 8 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 22.1 | 477.4 | 6.20x | 16.1% | 0.51x | 0.92x | 0.049 | default | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 8 | ST | ms | `55merge_tandem.mzid.gz` | 38.4 | 268.9 | 4.47x | 22.3% | 0.79x | 0.97x | 0.801 | default | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 8 | ST | generalized | `cantrbry.tar.gz` | 11.2 | 288.9 | 3.80x | 26.3% | 0.45x | 0.92x | 0.351 | default | 0.95 MiB | 0.95 MiB |
| `std-gzip` | gzip | 9 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 18.9 | 477.4 | 6.21x | 16.1% | 0.44x | 0.92x | 0.049 | default | 0.94 MiB | 0.95 MiB |
| `std-gzip` | gzip | 9 | ST | ms | `55merge_tandem.mzid.gz` | 37.1 | 268.9 | 4.48x | 22.3% | 0.77x | 0.97x | 0.797 | default | 0.94 MiB | 0.95 MiB |
| `std-gzip` | gzip | 9 | ST | generalized | `cantrbry.tar.gz` | 6.6 | 288.9 | 3.80x | 26.3% | 0.26x | 0.92x | 0.350 | default | 0.94 MiB | 0.95 MiB |
| `zlib-ng` | gzip | 0 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 3391.4 | 935.4 | 1.00x | 100.0% | 77.89x | 1.81x | 0.109 | store | 2.09 MiB | 1.90 MiB |
| `zlib-ng` | gzip | 0 | ST | ms | `55merge_tandem.mzid.gz` | 839.5 | 415.5 | 1.00x | 100.0% | 17.35x | 1.50x | 1.774 | store | 2.09 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 0 | ST | generalized | `cantrbry.tar.gz` | 1439.5 | 557.7 | 1.00x | 100.0% | 57.43x | 1.77x | 0.781 | store | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 1 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 362.4 | 935.4 | 3.65x | 27.4% | 8.32x | 1.81x | 0.109 | out | 2.11 MiB | 1.90 MiB |
| `zlib-ng` | gzip | 1 | ST | ms | `55merge_tandem.mzid.gz` | 210.3 | 415.5 | 3.01x | 33.2% | 4.35x | 1.50x | 1.780 | out | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 1 | ST | generalized | `cantrbry.tar.gz` | 237.8 | 557.7 | 2.45x | 40.8% | 9.49x | 1.77x | 0.781 | out | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 2 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 233.9 | 935.4 | 5.24x | 19.1% | 5.37x | 1.81x | 0.109 | fast | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | gzip | 2 | ST | ms | `55merge_tandem.mzid.gz` | 139.1 | 415.5 | 4.34x | 23.0% | 2.88x | 1.50x | 1.780 | default | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 2 | ST | generalized | `cantrbry.tar.gz` | 145.0 | 557.7 | 3.44x | 29.1% | 5.78x | 1.77x | 0.781 | fast | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 3 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 164.9 | 935.4 | 5.42x | 18.5% | 3.79x | 1.81x | 0.109 | out | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | gzip | 3 | ST | ms | `55merge_tandem.mzid.gz` | 118.0 | 415.5 | 4.42x | 22.6% | 2.44x | 1.50x | 1.774 | default | 2.09 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 3 | ST | generalized | `cantrbry.tar.gz` | 119.4 | 557.7 | 3.64x | 27.5% | 4.76x | 1.77x | 0.778 | default | 2.09 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 4 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 141.0 | 935.4 | 5.85x | 17.1% | 3.24x | 1.81x | 0.109 | default | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | gzip | 4 | ST | ms | `55merge_tandem.mzid.gz` | 112.8 | 415.5 | 4.55x | 22.0% | 2.33x | 1.50x | 1.780 | default | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 4 | ST | generalized | `cantrbry.tar.gz` | 94.4 | 557.7 | 3.71x | 27.0% | 3.77x | 1.77x | 0.781 | default | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 5 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 129.8 | 935.4 | 6.00x | 16.7% | 2.98x | 1.81x | 0.109 | default | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | gzip | 5 | ST | ms | `55merge_tandem.mzid.gz` | 108.1 | 415.5 | 4.66x | 21.5% | 2.23x | 1.50x | 1.780 | default | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 5 | ST | generalized | `cantrbry.tar.gz` | 88.7 | 557.7 | 3.76x | 26.6% | 3.54x | 1.77x | 0.781 | default | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 6 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 92.1 | 935.4 | 6.21x | 16.1% | 2.11x | 1.81x | 0.109 | default | 2.09 MiB | 1.90 MiB |
| `zlib-ng` | gzip | 6 | ST | ms | `55merge_tandem.mzid.gz` | 100.5 | 415.5 | 4.70x | 21.3% | 2.08x | 1.50x | 1.780 | default | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 6 | ST | generalized | `cantrbry.tar.gz` | 72.0 | 557.7 | 3.78x | 26.5% | 2.87x | 1.77x | 0.781 | default | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 7 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 63.9 | 935.4 | 6.34x | 15.8% | 1.47x | 1.81x | 0.109 | default | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | gzip | 7 | ST | ms | `55merge_tandem.mzid.gz` | 85.2 | 415.5 | 4.72x | 21.2% | 1.76x | 1.50x | 1.780 | default | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 7 | ST | generalized | `cantrbry.tar.gz` | 41.3 | 557.7 | 3.84x | 26.0% | 1.65x | 1.77x | 0.781 | default | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 8 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 34.9 | 935.4 | 6.43x | 15.6% | 0.80x | 1.81x | 0.109 | default | 2.11 MiB | 1.90 MiB |
| `zlib-ng` | gzip | 8 | ST | ms | `55merge_tandem.mzid.gz` | 69.9 | 415.5 | 4.77x | 21.0% | 1.45x | 1.50x | 1.774 | default | 2.09 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 8 | ST | generalized | `cantrbry.tar.gz` | 12.5 | 557.7 | 3.86x | 25.9% | 0.50x | 1.77x | 0.778 | default | 2.09 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 9 | ST | sequencing | `SRR389222_sub1.fastq.gz` | 43.6 | 935.4 | 6.26x | 16.0% | 1.00x | 1.81x | 0.109 | default | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | gzip | 9 | ST | ms | `55merge_tandem.mzid.gz` | 47.3 | 415.5 | 4.52x | 22.1% | 0.98x | 1.50x | 1.780 | default | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | gzip | 9 | ST | generalized | `cantrbry.tar.gz` | 10.2 | 557.7 | 3.85x | 26.0% | 0.41x | 1.77x | 0.781 | default | 2.10 MiB | 1.91 MiB |

#### Codec throughput (`class=small`)

| Tool | Level | Category | Class | File | Uncomp | Encode MB/s | Encode ms | Decode MB/s | Decode ms | Encode RSS | Decode RSS |
| --- | ---: | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `flate2-miniz` | 0 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 232.0 | 87.16 | 565.7 | 35.74 | 2.16 MiB | 2.16 MiB |
| `flate2-miniz` | 0 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 187.9 | 6.59 | 320.3 | 3.87 | 2.34 MiB | 2.35 MiB |
| `flate2-miniz` | 0 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 207.9 | 13.57 | 382.8 | 7.37 | 2.38 MiB | 2.36 MiB |
| `flate2-miniz` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 227.5 | 88.88 | 565.7 | 35.74 | 2.16 MiB | 2.16 MiB |
| `flate2-miniz` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 192.6 | 6.43 | 320.3 | 3.87 | 2.35 MiB | 2.35 MiB |
| `flate2-miniz` | 1 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 160.1 | 17.62 | 382.8 | 7.37 | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 126.8 | 159.51 | 565.7 | 35.74 | 2.13 MiB | 2.16 MiB |
| `flate2-miniz` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 110.1 | 11.24 | 320.3 | 3.87 | 2.16 MiB | 2.35 MiB |
| `flate2-miniz` | 2 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 104.3 | 27.04 | 382.8 | 7.37 | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 87.1 | 232.09 | 565.7 | 35.74 | 2.14 MiB | 2.16 MiB |
| `flate2-miniz` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 74.2 | 16.69 | 320.3 | 3.87 | 2.37 MiB | 2.35 MiB |
| `flate2-miniz` | 3 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 60.4 | 46.69 | 382.8 | 7.37 | 2.14 MiB | 2.36 MiB |
| `flate2-miniz` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 75.5 | 267.70 | 565.7 | 35.74 | 2.16 MiB | 2.16 MiB |
| `flate2-miniz` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 59.1 | 20.95 | 320.3 | 3.87 | 2.38 MiB | 2.35 MiB |
| `flate2-miniz` | 4 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 53.1 | 53.15 | 382.8 | 7.37 | 2.18 MiB | 2.36 MiB |
| `flate2-miniz` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 62.2 | 324.79 | 565.7 | 35.74 | 2.15 MiB | 2.16 MiB |
| `flate2-miniz` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 52.2 | 23.70 | 320.3 | 3.87 | 2.36 MiB | 2.35 MiB |
| `flate2-miniz` | 5 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 39.7 | 71.12 | 382.8 | 7.37 | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 36.5 | 553.77 | 565.7 | 35.74 | 2.15 MiB | 2.16 MiB |
| `flate2-miniz` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 45.4 | 27.26 | 320.3 | 3.87 | 2.38 MiB | 2.35 MiB |
| `flate2-miniz` | 6 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 20.0 | 141.30 | 382.8 | 7.37 | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 28.7 | 704.91 | 565.7 | 35.74 | 2.14 MiB | 2.16 MiB |
| `flate2-miniz` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 41.7 | 29.66 | 320.3 | 3.87 | 2.34 MiB | 2.35 MiB |
| `flate2-miniz` | 7 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 15.4 | 182.84 | 382.8 | 7.37 | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 24.3 | 833.60 | 565.7 | 35.74 | 2.14 MiB | 2.16 MiB |
| `flate2-miniz` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 39.5 | 31.35 | 320.3 | 3.87 | 2.16 MiB | 2.35 MiB |
| `flate2-miniz` | 8 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 11.6 | 243.01 | 382.8 | 7.37 | 2.16 MiB | 2.36 MiB |
| `flate2-miniz` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 22.7 | 891.13 | 565.7 | 35.74 | 2.14 MiB | 2.16 MiB |
| `flate2-miniz` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 38.2 | 32.43 | 320.3 | 3.87 | 2.39 MiB | 2.35 MiB |
| `flate2-miniz` | 9 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 9.7 | 292.04 | 382.8 | 7.37 | 2.37 MiB | 2.36 MiB |
| `flate2-zlib-rs` | 0 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 2127.7 | 9.50 | 724.9 | 27.89 | 2.36 MiB | 2.09 MiB |
| `flate2-zlib-rs` | 0 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 707.8 | 1.75 | 362.4 | 3.42 | 2.34 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 0 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 1184.5 | 2.38 | 464.2 | 6.08 | 2.34 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 385.9 | 52.39 | 724.9 | 27.89 | 2.33 MiB | 2.09 MiB |
| `flate2-zlib-rs` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 209.6 | 5.91 | 362.4 | 3.42 | 2.20 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 1 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 249.2 | 11.32 | 464.2 | 6.08 | 2.20 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 225.1 | 89.83 | 724.9 | 27.89 | 2.37 MiB | 2.09 MiB |
| `flate2-zlib-rs` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 132.5 | 9.34 | 362.4 | 3.42 | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 2 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 145.0 | 19.46 | 464.2 | 6.08 | 2.35 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 159.4 | 126.87 | 724.9 | 27.89 | 2.37 MiB | 2.09 MiB |
| `flate2-zlib-rs` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 113.8 | 10.88 | 362.4 | 3.42 | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 3 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 114.0 | 24.75 | 464.2 | 6.08 | 2.35 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 138.1 | 146.41 | 724.9 | 27.89 | 2.38 MiB | 2.09 MiB |
| `flate2-zlib-rs` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 108.2 | 11.44 | 362.4 | 3.42 | 2.35 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 4 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 93.1 | 30.31 | 464.2 | 6.08 | 2.38 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 126.0 | 160.41 | 724.9 | 27.89 | 2.37 MiB | 2.09 MiB |
| `flate2-zlib-rs` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 101.5 | 12.20 | 362.4 | 3.42 | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 5 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 85.5 | 32.98 | 464.2 | 6.08 | 2.35 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 91.5 | 221.04 | 724.9 | 27.89 | 2.36 MiB | 2.09 MiB |
| `flate2-zlib-rs` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 96.4 | 12.84 | 362.4 | 3.42 | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 6 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 71.5 | 39.48 | 464.2 | 6.08 | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 64.9 | 311.36 | 724.9 | 27.89 | 2.36 MiB | 2.09 MiB |
| `flate2-zlib-rs` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 81.9 | 15.11 | 362.4 | 3.42 | 2.36 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 7 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 41.4 | 68.09 | 464.2 | 6.08 | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 36.5 | 553.81 | 724.9 | 27.89 | 2.34 MiB | 2.09 MiB |
| `flate2-zlib-rs` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 67.5 | 18.33 | 362.4 | 3.42 | 2.37 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 8 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 13.1 | 214.99 | 464.2 | 6.08 | 2.34 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 47.4 | 426.67 | 724.9 | 27.89 | 2.34 MiB | 2.09 MiB |
| `flate2-zlib-rs` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 50.2 | 24.66 | 362.4 | 3.42 | 2.36 MiB | 2.11 MiB |
| `flate2-zlib-rs` | 9 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 11.1 | 254.72 | 464.2 | 6.08 | 2.37 MiB | 2.11 MiB |
| `gnu-gzip` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 149.9 | 134.85 | 517.9 | 39.04 | 1.88 MiB | 1.61 MiB |
| `gnu-gzip` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 130.5 | 9.49 | 276.3 | 4.48 | 1.89 MiB | 1.61 MiB |
| `gnu-gzip` | 1 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 104.7 | 26.94 | 315.2 | 8.95 | 1.90 MiB | 1.61 MiB |
| `gnu-gzip` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 139.8 | 144.58 | 517.9 | 39.04 | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 118.1 | 10.48 | 276.3 | 4.48 | 1.88 MiB | 1.61 MiB |
| `gnu-gzip` | 2 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 94.8 | 29.75 | 315.2 | 8.95 | 1.88 MiB | 1.61 MiB |
| `gnu-gzip` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 109.3 | 184.91 | 517.9 | 39.04 | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 95.2 | 13.01 | 276.3 | 4.48 | 1.89 MiB | 1.61 MiB |
| `gnu-gzip` | 3 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 69.2 | 40.78 | 315.2 | 8.95 | 1.88 MiB | 1.61 MiB |
| `gnu-gzip` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 93.8 | 215.63 | 517.9 | 39.04 | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 71.9 | 17.21 | 276.3 | 4.48 | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | 4 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 68.0 | 41.47 | 315.2 | 8.95 | 1.88 MiB | 1.61 MiB |
| `gnu-gzip` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 66.0 | 306.12 | 517.9 | 39.04 | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 53.5 | 23.14 | 276.3 | 4.48 | 1.90 MiB | 1.61 MiB |
| `gnu-gzip` | 5 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 42.1 | 66.98 | 315.2 | 8.95 | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 43.5 | 464.37 | 517.9 | 39.04 | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 48.4 | 25.58 | 276.3 | 4.48 | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | 6 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 25.1 | 112.55 | 315.2 | 8.95 | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 33.6 | 602.14 | 517.9 | 39.04 | 1.82 MiB | 1.61 MiB |
| `gnu-gzip` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 47.5 | 26.04 | 276.3 | 4.48 | 1.86 MiB | 1.61 MiB |
| `gnu-gzip` | 7 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 20.4 | 138.01 | 315.2 | 8.95 | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 18.3 | 1107.83 | 517.9 | 39.04 | 1.66 MiB | 1.61 MiB |
| `gnu-gzip` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 40.7 | 30.43 | 276.3 | 4.48 | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | 8 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 8.9 | 316.23 | 315.2 | 8.95 | 1.84 MiB | 1.61 MiB |
| `gnu-gzip` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 15.3 | 1319.56 | 517.9 | 39.04 | 1.66 MiB | 1.61 MiB |
| `gnu-gzip` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 37.3 | 33.20 | 276.3 | 4.48 | 1.85 MiB | 1.61 MiB |
| `gnu-gzip` | 9 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 4.9 | 571.76 | 315.2 | 8.95 | 1.82 MiB | 1.61 MiB |
| `igzip` | 0 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 562.1 | 35.97 | 1112.2 | 18.18 | 2.84 MiB | 3.60 MiB |
| `igzip` | 0 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 298.1 | 4.15 | 404.7 | 3.06 | 3.10 MiB | 2.88 MiB |
| `igzip` | 0 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 344.1 | 8.20 | 565.0 | 4.99 | 3.10 MiB | 3.38 MiB |
| `igzip` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 532.0 | 38.01 | 1112.2 | 18.18 | 3.10 MiB | 3.60 MiB |
| `igzip` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 271.4 | 4.56 | 404.7 | 3.06 | 3.10 MiB | 2.88 MiB |
| `igzip` | 1 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 302.6 | 9.32 | 565.0 | 4.99 | 3.35 MiB | 3.38 MiB |
| `igzip` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 503.0 | 40.19 | 1112.2 | 18.18 | 3.34 MiB | 3.60 MiB |
| `igzip` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 270.8 | 4.57 | 404.7 | 3.06 | 3.14 MiB | 2.88 MiB |
| `igzip` | 2 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 298.1 | 9.46 | 565.0 | 4.99 | 3.35 MiB | 3.38 MiB |
| `igzip` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 175.3 | 115.35 | 1112.2 | 18.18 | 3.35 MiB | 3.60 MiB |
| `igzip` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 143.9 | 8.60 | 404.7 | 3.06 | 3.15 MiB | 2.88 MiB |
| `igzip` | 3 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 147.0 | 19.19 | 565.0 | 4.99 | 3.39 MiB | 3.38 MiB |
| `libdeflate-gzip` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 274.0 | 73.80 | 691.7 | 29.23 | 24.44 MiB | 23.71 MiB |
| `libdeflate-gzip` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 185.5 | 6.68 | 418.9 | 2.96 | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | 1 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 214.0 | 13.18 | 471.0 | 5.99 | 4.89 MiB | 4.88 MiB |
| `libdeflate-gzip` | 10 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 8.7 | 2319.55 | 691.7 | 29.23 | 27.88 MiB | 23.71 MiB |
| `libdeflate-gzip` | 10 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 11.6 | 106.39 | 418.9 | 2.96 | 8.36 MiB | 2.89 MiB |
| `libdeflate-gzip` | 10 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 12.0 | 235.51 | 471.0 | 5.99 | 10.94 MiB | 4.88 MiB |
| `libdeflate-gzip` | 11 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 4.6 | 4438.67 | 691.7 | 29.23 | 29.11 MiB | 23.71 MiB |
| `libdeflate-gzip` | 11 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 6.3 | 197.27 | 418.9 | 2.96 | 9.10 MiB | 2.89 MiB |
| `libdeflate-gzip` | 11 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 7.2 | 390.76 | 471.0 | 5.99 | 10.85 MiB | 4.88 MiB |
| `libdeflate-gzip` | 12 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 3.6 | 5593.68 | 691.7 | 29.23 | 28.88 MiB | 23.71 MiB |
| `libdeflate-gzip` | 12 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 2.8 | 441.06 | 418.9 | 2.96 | 10.86 MiB | 2.89 MiB |
| `libdeflate-gzip` | 12 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 4.9 | 577.14 | 471.0 | 5.99 | 10.66 MiB | 4.88 MiB |
| `libdeflate-gzip` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 197.7 | 102.27 | 691.7 | 29.23 | 24.48 MiB | 23.71 MiB |
| `libdeflate-gzip` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 145.2 | 8.53 | 418.9 | 2.96 | 3.15 MiB | 2.89 MiB |
| `libdeflate-gzip` | 2 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 135.3 | 20.84 | 471.0 | 5.99 | 5.14 MiB | 4.88 MiB |
| `libdeflate-gzip` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 180.6 | 111.96 | 691.7 | 29.23 | 24.17 MiB | 23.71 MiB |
| `libdeflate-gzip` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 137.5 | 9.00 | 418.9 | 2.96 | 3.15 MiB | 2.89 MiB |
| `libdeflate-gzip` | 3 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 116.8 | 24.15 | 471.0 | 5.99 | 5.10 MiB | 4.88 MiB |
| `libdeflate-gzip` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 165.4 | 122.22 | 691.7 | 29.23 | 23.92 MiB | 23.71 MiB |
| `libdeflate-gzip` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 137.6 | 9.00 | 418.9 | 2.96 | 3.14 MiB | 2.89 MiB |
| `libdeflate-gzip` | 4 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 110.2 | 25.59 | 471.0 | 5.99 | 5.11 MiB | 4.88 MiB |
| `libdeflate-gzip` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 137.2 | 147.31 | 691.7 | 29.23 | 23.81 MiB | 23.71 MiB |
| `libdeflate-gzip` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 114.1 | 10.85 | 418.9 | 2.96 | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | 5 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 91.5 | 30.84 | 471.0 | 5.99 | 5.10 MiB | 4.88 MiB |
| `libdeflate-gzip` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 108.4 | 186.56 | 691.7 | 29.23 | 23.68 MiB | 23.71 MiB |
| `libdeflate-gzip` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 106.3 | 11.65 | 418.9 | 2.96 | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | 6 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 75.8 | 37.21 | 471.0 | 5.99 | 5.10 MiB | 4.88 MiB |
| `libdeflate-gzip` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 74.0 | 273.39 | 691.7 | 29.23 | 23.56 MiB | 23.71 MiB |
| `libdeflate-gzip` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 98.7 | 12.54 | 418.9 | 2.96 | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | 7 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 55.7 | 50.61 | 471.0 | 5.99 | 5.11 MiB | 4.88 MiB |
| `libdeflate-gzip` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 42.5 | 475.76 | 691.7 | 29.23 | 23.24 MiB | 23.71 MiB |
| `libdeflate-gzip` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 71.8 | 17.25 | 418.9 | 2.96 | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | 8 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 25.9 | 109.00 | 471.0 | 5.99 | 5.10 MiB | 4.88 MiB |
| `libdeflate-gzip` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 33.7 | 599.32 | 691.7 | 29.23 | 23.12 MiB | 23.71 MiB |
| `libdeflate-gzip` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 56.4 | 21.94 | 418.9 | 2.96 | 2.89 MiB | 2.89 MiB |
| `libdeflate-gzip` | 9 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 17.2 | 163.93 | 471.0 | 5.99 | 4.96 MiB | 4.88 MiB |
| `pigz` | 0 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 2660.8 | 7.60 | 663.2 | 30.49 | 2.90 MiB | 2.17 MiB |
| `pigz` | 0 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 727.5 | 1.70 | 341.5 | 3.63 | 2.91 MiB | 2.20 MiB |
| `pigz` | 0 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 1214.0 | 2.32 | 407.4 | 6.93 | 2.84 MiB | 2.20 MiB |
| `pigz` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 217.5 | 92.95 | 663.2 | 30.49 | 2.91 MiB | 2.17 MiB |
| `pigz` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 130.6 | 9.48 | 341.5 | 3.63 | 2.90 MiB | 2.20 MiB |
| `pigz` | 1 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 141.5 | 19.94 | 407.4 | 6.93 | 2.92 MiB | 2.20 MiB |
| `pigz` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 208.4 | 97.02 | 663.2 | 30.49 | 2.84 MiB | 2.17 MiB |
| `pigz` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 127.8 | 9.69 | 341.5 | 3.63 | 2.92 MiB | 2.20 MiB |
| `pigz` | 2 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 124.2 | 22.71 | 407.4 | 6.93 | 2.90 MiB | 2.20 MiB |
| `pigz` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 175.4 | 115.28 | 663.2 | 30.49 | 2.67 MiB | 2.17 MiB |
| `pigz` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 126.5 | 9.78 | 341.5 | 3.63 | 2.91 MiB | 2.20 MiB |
| `pigz` | 3 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 104.9 | 26.90 | 407.4 | 6.93 | 2.91 MiB | 2.20 MiB |
| `pigz` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 141.7 | 142.69 | 663.2 | 30.49 | 2.66 MiB | 2.17 MiB |
| `pigz` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 102.5 | 12.07 | 341.5 | 3.63 | 2.92 MiB | 2.20 MiB |
| `pigz` | 4 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 91.2 | 30.94 | 407.4 | 6.93 | 2.90 MiB | 2.20 MiB |
| `pigz` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 109.6 | 184.42 | 663.2 | 30.49 | 2.65 MiB | 2.17 MiB |
| `pigz` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 91.1 | 13.59 | 341.5 | 3.63 | 2.89 MiB | 2.20 MiB |
| `pigz` | 5 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 65.5 | 43.10 | 407.4 | 6.93 | 2.91 MiB | 2.20 MiB |
| `pigz` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 78.3 | 258.29 | 663.2 | 30.49 | 2.66 MiB | 2.17 MiB |
| `pigz` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 85.8 | 14.42 | 341.5 | 3.63 | 2.91 MiB | 2.20 MiB |
| `pigz` | 6 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 48.6 | 58.01 | 407.4 | 6.93 | 2.91 MiB | 2.20 MiB |
| `pigz` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 63.4 | 318.69 | 663.2 | 30.49 | 2.65 MiB | 2.17 MiB |
| `pigz` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 82.6 | 15.00 | 341.5 | 3.63 | 2.92 MiB | 2.20 MiB |
| `pigz` | 7 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 40.8 | 69.20 | 407.4 | 6.93 | 2.89 MiB | 2.20 MiB |
| `pigz` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 34.8 | 580.98 | 663.2 | 30.49 | 2.65 MiB | 2.17 MiB |
| `pigz` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 66.9 | 18.52 | 341.5 | 3.63 | 2.92 MiB | 2.20 MiB |
| `pigz` | 8 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 12.4 | 226.84 | 407.4 | 6.93 | 2.90 MiB | 2.20 MiB |
| `pigz` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 43.6 | 463.95 | 663.2 | 30.49 | 2.59 MiB | 2.17 MiB |
| `pigz` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 46.1 | 26.87 | 341.5 | 3.63 | 2.92 MiB | 2.20 MiB |
| `pigz` | 9 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 10.2 | 277.75 | 407.4 | 6.93 | 2.90 MiB | 2.20 MiB |
| `std-gzip` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 90.5 | 223.33 | 477.4 | 42.35 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 82.6 | 14.98 | 268.9 | 4.60 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 1 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 77.0 | 36.64 | 288.9 | 9.77 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 87.9 | 229.95 | 477.4 | 42.35 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 76.0 | 16.30 | 268.9 | 4.60 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 2 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 73.4 | 38.42 | 288.9 | 9.77 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 81.3 | 248.61 | 477.4 | 42.35 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 65.3 | 18.97 | 268.9 | 4.60 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 3 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 61.5 | 45.90 | 288.9 | 9.77 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 81.9 | 246.92 | 477.4 | 42.35 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 62.6 | 19.78 | 268.9 | 4.60 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 4 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 65.5 | 43.05 | 288.9 | 9.77 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 63.8 | 316.96 | 477.4 | 42.35 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 46.9 | 26.40 | 268.9 | 4.60 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 5 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 41.5 | 67.96 | 288.9 | 9.77 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 48.6 | 416.28 | 477.4 | 42.35 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 44.5 | 27.85 | 268.9 | 4.60 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 6 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 29.0 | 97.22 | 288.9 | 9.77 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 39.4 | 513.38 | 477.4 | 42.35 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 43.2 | 28.68 | 268.9 | 4.60 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 7 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 24.3 | 115.98 | 288.9 | 9.77 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 22.1 | 912.92 | 477.4 | 42.35 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 38.4 | 32.28 | 268.9 | 4.60 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 8 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 11.2 | 251.34 | 288.9 | 9.77 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 18.9 | 1067.10 | 477.4 | 42.35 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 37.1 | 33.37 | 268.9 | 4.60 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 9 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 6.6 | 430.08 | 288.9 | 9.77 | 0.94 MiB | 0.95 MiB |
| `zlib-ng` | 0 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 3391.4 | 5.96 | 935.4 | 21.61 | 2.09 MiB | 1.90 MiB |
| `zlib-ng` | 0 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 839.5 | 1.47 | 415.5 | 2.98 | 2.09 MiB | 1.91 MiB |
| `zlib-ng` | 0 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 1439.5 | 1.96 | 557.7 | 5.06 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 362.4 | 55.79 | 935.4 | 21.61 | 2.11 MiB | 1.90 MiB |
| `zlib-ng` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 210.3 | 5.89 | 415.5 | 2.98 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 1 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 237.8 | 11.86 | 557.7 | 5.06 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 233.9 | 86.44 | 935.4 | 21.61 | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 139.1 | 8.90 | 415.5 | 2.98 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 2 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 145.0 | 19.46 | 557.7 | 5.06 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 164.9 | 122.58 | 935.4 | 21.61 | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 118.0 | 10.49 | 415.5 | 2.98 | 2.09 MiB | 1.91 MiB |
| `zlib-ng` | 3 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 119.4 | 23.62 | 557.7 | 5.06 | 2.09 MiB | 1.91 MiB |
| `zlib-ng` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 141.0 | 143.43 | 935.4 | 21.61 | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 112.8 | 10.98 | 415.5 | 2.98 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 4 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 94.4 | 29.88 | 557.7 | 5.06 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 129.8 | 155.71 | 935.4 | 21.61 | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 108.1 | 11.45 | 415.5 | 2.98 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 5 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 88.7 | 31.79 | 557.7 | 5.06 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 92.1 | 219.59 | 935.4 | 21.61 | 2.09 MiB | 1.90 MiB |
| `zlib-ng` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 100.5 | 12.32 | 415.5 | 2.98 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 6 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 72.0 | 39.21 | 557.7 | 5.06 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 63.9 | 316.22 | 935.4 | 21.61 | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 85.2 | 14.53 | 415.5 | 2.98 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 7 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 41.3 | 68.25 | 557.7 | 5.06 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 34.9 | 580.11 | 935.4 | 21.61 | 2.11 MiB | 1.90 MiB |
| `zlib-ng` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 69.9 | 17.70 | 415.5 | 2.98 | 2.09 MiB | 1.91 MiB |
| `zlib-ng` | 8 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 12.5 | 226.43 | 557.7 | 5.06 | 2.09 MiB | 1.91 MiB |
| `zlib-ng` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 19.28 MiB | 43.6 | 464.04 | 935.4 | 21.61 | 2.10 MiB | 1.90 MiB |
| `zlib-ng` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1.18 MiB | 47.3 | 26.19 | 415.5 | 2.98 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 9 | generalized | small | `cantrbry.tar.gz` | 2.69 MiB | 10.2 | 276.88 | 557.7 | 5.06 | 2.10 MiB | 1.91 MiB |

#### Startup throughput (`class=sanity`)

| Tool | Level | Category | Class | File | Uncomp | Encode MB/s | Encode ms | Decode MB/s | Decode ms | Encode RSS | Decode RSS |
| --- | ---: | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `flate2-miniz` | 0 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 24.9 | 1.39 | 29.4 | 1.18 | 2.34 MiB | 2.34 MiB |
| `flate2-miniz` | 0 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 67.0 | 1.73 | 94.3 | 1.23 | 2.16 MiB | 2.34 MiB |
| `flate2-miniz` | 0 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 121.2 | 2.54 | 162.3 | 1.89 | 2.36 MiB | 2.35 MiB |
| `flate2-miniz` | 1 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 25.4 | 1.36 | 29.4 | 1.18 | 2.34 MiB | 2.34 MiB |
| `flate2-miniz` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 77.2 | 1.50 | 94.3 | 1.23 | 2.35 MiB | 2.34 MiB |
| `flate2-miniz` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 95.5 | 3.22 | 162.3 | 1.89 | 2.37 MiB | 2.35 MiB |
| `flate2-miniz` | 2 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 20.6 | 1.68 | 29.4 | 1.18 | 2.38 MiB | 2.34 MiB |
| `flate2-miniz` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 59.1 | 1.96 | 94.3 | 1.23 | 2.35 MiB | 2.34 MiB |
| `flate2-miniz` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 69.7 | 4.40 | 162.3 | 1.89 | 2.19 MiB | 2.35 MiB |
| `flate2-miniz` | 3 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 18.5 | 1.87 | 29.4 | 1.18 | 2.22 MiB | 2.34 MiB |
| `flate2-miniz` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 53.6 | 2.16 | 94.3 | 1.23 | 2.16 MiB | 2.34 MiB |
| `flate2-miniz` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 48.1 | 6.39 | 162.3 | 1.89 | 2.25 MiB | 2.35 MiB |
| `flate2-miniz` | 4 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 16.8 | 2.06 | 29.4 | 1.18 | 2.37 MiB | 2.34 MiB |
| `flate2-miniz` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 52.2 | 2.22 | 94.3 | 1.23 | 2.34 MiB | 2.34 MiB |
| `flate2-miniz` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 42.9 | 7.16 | 162.3 | 1.89 | 2.16 MiB | 2.35 MiB |
| `flate2-miniz` | 5 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 14.6 | 2.37 | 29.4 | 1.18 | 2.36 MiB | 2.34 MiB |
| `flate2-miniz` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 48.4 | 2.39 | 94.3 | 1.23 | 2.34 MiB | 2.34 MiB |
| `flate2-miniz` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 35.1 | 8.74 | 162.3 | 1.89 | 2.34 MiB | 2.35 MiB |
| `flate2-miniz` | 6 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 10.8 | 3.20 | 29.4 | 1.18 | 2.35 MiB | 2.34 MiB |
| `flate2-miniz` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 42.4 | 2.73 | 94.3 | 1.23 | 2.34 MiB | 2.34 MiB |
| `flate2-miniz` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 25.3 | 12.14 | 162.3 | 1.89 | 2.16 MiB | 2.35 MiB |
| `flate2-miniz` | 7 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 8.2 | 4.21 | 29.4 | 1.18 | 2.16 MiB | 2.34 MiB |
| `flate2-miniz` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 37.7 | 3.07 | 94.3 | 1.23 | 2.16 MiB | 2.34 MiB |
| `flate2-miniz` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 21.9 | 14.02 | 162.3 | 1.89 | 2.37 MiB | 2.35 MiB |
| `flate2-miniz` | 8 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 7.5 | 4.64 | 29.4 | 1.18 | 2.39 MiB | 2.34 MiB |
| `flate2-miniz` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 34.1 | 3.40 | 94.3 | 1.23 | 2.34 MiB | 2.34 MiB |
| `flate2-miniz` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 20.4 | 15.09 | 162.3 | 1.89 | 2.38 MiB | 2.35 MiB |
| `flate2-miniz` | 9 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 7.1 | 4.86 | 29.4 | 1.18 | 2.16 MiB | 2.34 MiB |
| `flate2-miniz` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 35.8 | 3.23 | 94.3 | 1.23 | 2.34 MiB | 2.34 MiB |
| `flate2-miniz` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 20.5 | 14.98 | 162.3 | 1.89 | 2.36 MiB | 2.35 MiB |
| `flate2-zlib-rs` | 0 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 27.4 | 1.26 | 28.7 | 1.21 | 2.37 MiB | 2.14 MiB |
| `flate2-zlib-rs` | 0 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 86.9 | 1.33 | 94.4 | 1.23 | 2.35 MiB | 2.13 MiB |
| `flate2-zlib-rs` | 0 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 215.1 | 1.43 | 180.5 | 1.70 | 2.36 MiB | 2.12 MiB |
| `flate2-zlib-rs` | 1 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 24.9 | 1.39 | 28.7 | 1.21 | 2.36 MiB | 2.14 MiB |
| `flate2-zlib-rs` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 79.1 | 1.47 | 94.4 | 1.23 | 2.36 MiB | 2.13 MiB |
| `flate2-zlib-rs` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 117.5 | 2.62 | 180.5 | 1.70 | 2.36 MiB | 2.12 MiB |
| `flate2-zlib-rs` | 2 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 24.0 | 1.44 | 28.7 | 1.21 | 2.22 MiB | 2.14 MiB |
| `flate2-zlib-rs` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 71.7 | 1.62 | 94.4 | 1.23 | 2.16 MiB | 2.13 MiB |
| `flate2-zlib-rs` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 85.1 | 3.61 | 180.5 | 1.70 | 2.38 MiB | 2.12 MiB |
| `flate2-zlib-rs` | 3 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 21.5 | 1.61 | 28.7 | 1.21 | 2.32 MiB | 2.14 MiB |
| `flate2-zlib-rs` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 64.8 | 1.79 | 94.4 | 1.23 | 2.32 MiB | 2.13 MiB |
| `flate2-zlib-rs` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 71.5 | 4.29 | 180.5 | 1.70 | 2.36 MiB | 2.12 MiB |
| `flate2-zlib-rs` | 4 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 19.2 | 1.80 | 28.7 | 1.21 | 2.32 MiB | 2.14 MiB |
| `flate2-zlib-rs` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 61.1 | 1.90 | 94.4 | 1.23 | 2.36 MiB | 2.13 MiB |
| `flate2-zlib-rs` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 64.0 | 4.80 | 180.5 | 1.70 | 2.37 MiB | 2.12 MiB |
| `flate2-zlib-rs` | 5 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 19.2 | 1.80 | 28.7 | 1.21 | 2.32 MiB | 2.14 MiB |
| `flate2-zlib-rs` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 57.6 | 2.01 | 94.4 | 1.23 | 2.38 MiB | 2.13 MiB |
| `flate2-zlib-rs` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 58.4 | 5.26 | 180.5 | 1.70 | 2.37 MiB | 2.12 MiB |
| `flate2-zlib-rs` | 6 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 18.4 | 1.88 | 28.7 | 1.21 | 2.37 MiB | 2.14 MiB |
| `flate2-zlib-rs` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 55.6 | 2.08 | 94.4 | 1.23 | 2.17 MiB | 2.13 MiB |
| `flate2-zlib-rs` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 52.6 | 5.85 | 180.5 | 1.70 | 2.37 MiB | 2.12 MiB |
| `flate2-zlib-rs` | 7 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 14.6 | 2.37 | 28.7 | 1.21 | 2.33 MiB | 2.14 MiB |
| `flate2-zlib-rs` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 51.3 | 2.26 | 94.4 | 1.23 | 2.38 MiB | 2.13 MiB |
| `flate2-zlib-rs` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 37.4 | 8.21 | 180.5 | 1.70 | 2.36 MiB | 2.12 MiB |
| `flate2-zlib-rs` | 8 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 10.9 | 3.17 | 28.7 | 1.21 | 2.32 MiB | 2.14 MiB |
| `flate2-zlib-rs` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 42.4 | 2.73 | 94.4 | 1.23 | 2.36 MiB | 2.13 MiB |
| `flate2-zlib-rs` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 34.2 | 8.97 | 180.5 | 1.70 | 2.38 MiB | 2.12 MiB |
| `flate2-zlib-rs` | 9 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 8.4 | 4.13 | 28.7 | 1.21 | 2.32 MiB | 2.14 MiB |
| `flate2-zlib-rs` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 42.5 | 2.73 | 94.4 | 1.23 | 2.37 MiB | 2.13 MiB |
| `flate2-zlib-rs` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 28.5 | 10.80 | 180.5 | 1.70 | 2.35 MiB | 2.12 MiB |
| `gnu-gzip` | 1 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 25.9 | 1.34 | 37.0 | 0.94 | 1.64 MiB | 1.36 MiB |
| `gnu-gzip` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 79.9 | 1.45 | 114.5 | 1.01 | 1.62 MiB | 1.38 MiB |
| `gnu-gzip` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 68.6 | 4.48 | 162.0 | 1.90 | 1.62 MiB | 1.60 MiB |
| `gnu-gzip` | 2 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 24.3 | 1.42 | 37.0 | 0.94 | 1.63 MiB | 1.36 MiB |
| `gnu-gzip` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 76.8 | 1.51 | 114.5 | 1.01 | 1.64 MiB | 1.38 MiB |
| `gnu-gzip` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 64.5 | 4.76 | 162.0 | 1.90 | 1.63 MiB | 1.60 MiB |
| `gnu-gzip` | 3 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 18.7 | 1.85 | 37.0 | 0.94 | 1.63 MiB | 1.36 MiB |
| `gnu-gzip` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 74.4 | 1.56 | 114.5 | 1.01 | 1.61 MiB | 1.38 MiB |
| `gnu-gzip` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 54.1 | 5.68 | 162.0 | 1.90 | 1.62 MiB | 1.60 MiB |
| `gnu-gzip` | 4 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 20.8 | 1.66 | 37.0 | 0.94 | 1.62 MiB | 1.36 MiB |
| `gnu-gzip` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 66.9 | 1.73 | 114.5 | 1.01 | 1.60 MiB | 1.38 MiB |
| `gnu-gzip` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 51.1 | 6.02 | 162.0 | 1.90 | 1.64 MiB | 1.60 MiB |
| `gnu-gzip` | 5 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 14.0 | 2.47 | 37.0 | 0.94 | 1.65 MiB | 1.36 MiB |
| `gnu-gzip` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 58.2 | 1.99 | 114.5 | 1.01 | 1.64 MiB | 1.38 MiB |
| `gnu-gzip` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 35.8 | 8.58 | 162.0 | 1.90 | 1.63 MiB | 1.60 MiB |
| `gnu-gzip` | 6 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 9.4 | 3.69 | 37.0 | 0.94 | 1.64 MiB | 1.36 MiB |
| `gnu-gzip` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 51.7 | 2.24 | 114.5 | 1.01 | 1.64 MiB | 1.38 MiB |
| `gnu-gzip` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 25.8 | 11.90 | 162.0 | 1.90 | 1.61 MiB | 1.60 MiB |
| `gnu-gzip` | 7 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 7.4 | 4.67 | 37.0 | 0.94 | 1.63 MiB | 1.36 MiB |
| `gnu-gzip` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 47.6 | 2.44 | 114.5 | 1.01 | 1.64 MiB | 1.38 MiB |
| `gnu-gzip` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 23.0 | 13.33 | 162.0 | 1.90 | 1.63 MiB | 1.60 MiB |
| `gnu-gzip` | 8 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 5.2 | 6.66 | 37.0 | 0.94 | 1.60 MiB | 1.36 MiB |
| `gnu-gzip` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 37.9 | 3.06 | 114.5 | 1.01 | 1.65 MiB | 1.38 MiB |
| `gnu-gzip` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 19.9 | 15.46 | 162.0 | 1.90 | 1.63 MiB | 1.60 MiB |
| `gnu-gzip` | 9 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 3.5 | 9.82 | 37.0 | 0.94 | 1.62 MiB | 1.36 MiB |
| `gnu-gzip` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 33.7 | 3.44 | 114.5 | 1.01 | 1.65 MiB | 1.38 MiB |
| `gnu-gzip` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 19.0 | 16.16 | 162.0 | 1.90 | 1.60 MiB | 1.60 MiB |
| `igzip` | 0 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 35.3 | 0.98 | 34.2 | 1.01 | 1.65 MiB | 1.60 MiB |
| `igzip` | 0 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 108.1 | 1.07 | 102.7 | 1.13 | 1.89 MiB | 1.89 MiB |
| `igzip` | 0 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 162.0 | 1.90 | 212.3 | 1.45 | 2.15 MiB | 2.14 MiB |
| `igzip` | 1 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 38.3 | 0.90 | 34.2 | 1.01 | 1.65 MiB | 1.60 MiB |
| `igzip` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 112.5 | 1.03 | 102.7 | 1.13 | 1.90 MiB | 1.89 MiB |
| `igzip` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 146.6 | 2.09 | 212.3 | 1.45 | 2.35 MiB | 2.14 MiB |
| `igzip` | 2 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 33.5 | 1.03 | 34.2 | 1.01 | 1.88 MiB | 1.60 MiB |
| `igzip` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 102.2 | 1.13 | 102.7 | 1.13 | 1.88 MiB | 1.89 MiB |
| `igzip` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 139.7 | 2.20 | 212.3 | 1.45 | 2.35 MiB | 2.14 MiB |
| `igzip` | 3 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 29.4 | 1.18 | 34.2 | 1.01 | 1.85 MiB | 1.60 MiB |
| `igzip` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 72.7 | 1.59 | 102.7 | 1.13 | 1.89 MiB | 1.89 MiB |
| `igzip` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 99.5 | 3.09 | 212.3 | 1.45 | 2.35 MiB | 2.14 MiB |
| `libdeflate-gzip` | 1 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 31.9 | 1.08 | 40.9 | 0.84 | 1.67 MiB | 1.38 MiB |
| `libdeflate-gzip` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 92.9 | 1.25 | 124.6 | 0.93 | 1.68 MiB | 1.38 MiB |
| `libdeflate-gzip` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 122.0 | 2.52 | 227.6 | 1.35 | 1.91 MiB | 1.67 MiB |
| `libdeflate-gzip` | 10 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 4.8 | 7.22 | 40.9 | 0.84 | 2.59 MiB | 1.38 MiB |
| `libdeflate-gzip` | 10 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 8.8 | 13.13 | 124.6 | 0.93 | 2.87 MiB | 1.38 MiB |
| `libdeflate-gzip` | 10 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 10.7 | 28.83 | 227.6 | 1.35 | 3.59 MiB | 1.67 MiB |
| `libdeflate-gzip` | 11 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 3.2 | 10.71 | 40.9 | 0.84 | 2.60 MiB | 1.38 MiB |
| `libdeflate-gzip` | 11 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 3.8 | 30.44 | 124.6 | 0.93 | 3.35 MiB | 1.38 MiB |
| `libdeflate-gzip` | 11 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 7.2 | 42.75 | 227.6 | 1.35 | 4.59 MiB | 1.67 MiB |
| `libdeflate-gzip` | 12 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 2.5 | 13.73 | 40.9 | 0.84 | 2.62 MiB | 1.38 MiB |
| `libdeflate-gzip` | 12 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 2.3 | 50.25 | 124.6 | 0.93 | 3.34 MiB | 1.38 MiB |
| `libdeflate-gzip` | 12 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 5.5 | 55.36 | 227.6 | 1.35 | 4.60 MiB | 1.67 MiB |
| `libdeflate-gzip` | 2 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 27.6 | 1.25 | 40.9 | 0.84 | 1.63 MiB | 1.38 MiB |
| `libdeflate-gzip` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 77.9 | 1.49 | 124.6 | 0.93 | 1.62 MiB | 1.38 MiB |
| `libdeflate-gzip` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 90.4 | 3.40 | 227.6 | 1.35 | 2.07 MiB | 1.67 MiB |
| `libdeflate-gzip` | 3 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 26.2 | 1.32 | 40.9 | 0.84 | 1.63 MiB | 1.38 MiB |
| `libdeflate-gzip` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 79.2 | 1.46 | 124.6 | 0.93 | 1.63 MiB | 1.38 MiB |
| `libdeflate-gzip` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 82.8 | 3.71 | 227.6 | 1.35 | 2.14 MiB | 1.67 MiB |
| `libdeflate-gzip` | 4 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 26.1 | 1.32 | 40.9 | 0.84 | 1.62 MiB | 1.38 MiB |
| `libdeflate-gzip` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 76.9 | 1.51 | 124.6 | 0.93 | 1.63 MiB | 1.38 MiB |
| `libdeflate-gzip` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 80.5 | 3.81 | 227.6 | 1.35 | 2.13 MiB | 1.67 MiB |
| `libdeflate-gzip` | 5 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 24.3 | 1.43 | 40.9 | 0.84 | 1.61 MiB | 1.38 MiB |
| `libdeflate-gzip` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 74.9 | 1.55 | 124.6 | 0.93 | 1.63 MiB | 1.38 MiB |
| `libdeflate-gzip` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 68.4 | 4.49 | 227.6 | 1.35 | 2.08 MiB | 1.67 MiB |
| `libdeflate-gzip` | 6 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 21.2 | 1.63 | 40.9 | 0.84 | 1.63 MiB | 1.38 MiB |
| `libdeflate-gzip` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 68.7 | 1.69 | 124.6 | 0.93 | 1.63 MiB | 1.38 MiB |
| `libdeflate-gzip` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 58.4 | 5.26 | 227.6 | 1.35 | 1.92 MiB | 1.67 MiB |
| `libdeflate-gzip` | 7 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 18.4 | 1.88 | 40.9 | 0.84 | 1.65 MiB | 1.38 MiB |
| `libdeflate-gzip` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 59.2 | 1.96 | 124.6 | 0.93 | 1.65 MiB | 1.38 MiB |
| `libdeflate-gzip` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 49.5 | 6.21 | 227.6 | 1.35 | 2.06 MiB | 1.67 MiB |
| `libdeflate-gzip` | 8 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 14.2 | 2.44 | 40.9 | 0.84 | 1.63 MiB | 1.38 MiB |
| `libdeflate-gzip` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 48.0 | 2.42 | 124.6 | 0.93 | 1.62 MiB | 1.38 MiB |
| `libdeflate-gzip` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 37.0 | 8.30 | 227.6 | 1.35 | 2.14 MiB | 1.67 MiB |
| `libdeflate-gzip` | 9 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 12.5 | 2.77 | 40.9 | 0.84 | 1.62 MiB | 1.38 MiB |
| `libdeflate-gzip` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 42.9 | 2.70 | 124.6 | 0.93 | 1.60 MiB | 1.38 MiB |
| `libdeflate-gzip` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 33.7 | 9.11 | 227.6 | 1.35 | 2.13 MiB | 1.67 MiB |
| `pigz` | 0 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 28.9 | 1.20 | 27.7 | 1.25 | 2.42 MiB | 2.17 MiB |
| `pigz` | 0 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 84.7 | 1.37 | 94.6 | 1.22 | 2.66 MiB | 2.17 MiB |
| `pigz` | 0 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 207.3 | 1.48 | 163.0 | 1.88 | 2.92 MiB | 2.17 MiB |
| `pigz` | 1 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 21.2 | 1.63 | 27.7 | 1.25 | 2.42 MiB | 2.17 MiB |
| `pigz` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 73.0 | 1.59 | 94.6 | 1.22 | 2.66 MiB | 2.17 MiB |
| `pigz` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 79.5 | 3.87 | 163.0 | 1.88 | 2.91 MiB | 2.17 MiB |
| `pigz` | 2 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 22.4 | 1.54 | 27.7 | 1.25 | 2.45 MiB | 2.17 MiB |
| `pigz` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 70.1 | 1.65 | 94.6 | 1.22 | 2.65 MiB | 2.17 MiB |
| `pigz` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 74.2 | 4.14 | 163.0 | 1.88 | 2.90 MiB | 2.17 MiB |
| `pigz` | 3 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 20.9 | 1.66 | 27.7 | 1.25 | 2.42 MiB | 2.17 MiB |
| `pigz` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 67.6 | 1.72 | 94.6 | 1.22 | 2.65 MiB | 2.17 MiB |
| `pigz` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 65.9 | 4.66 | 163.0 | 1.88 | 2.90 MiB | 2.17 MiB |
| `pigz` | 4 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 19.8 | 1.75 | 27.7 | 1.25 | 2.45 MiB | 2.17 MiB |
| `pigz` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 61.9 | 1.87 | 94.6 | 1.22 | 2.66 MiB | 2.17 MiB |
| `pigz` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 59.9 | 5.13 | 163.0 | 1.88 | 2.90 MiB | 2.17 MiB |
| `pigz` | 5 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 17.8 | 1.94 | 27.7 | 1.25 | 2.45 MiB | 2.17 MiB |
| `pigz` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 58.1 | 1.99 | 94.6 | 1.22 | 2.67 MiB | 2.17 MiB |
| `pigz` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 46.3 | 6.64 | 163.0 | 1.88 | 2.91 MiB | 2.17 MiB |
| `pigz` | 6 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 14.0 | 2.47 | 27.7 | 1.25 | 2.42 MiB | 2.17 MiB |
| `pigz` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 50.8 | 2.28 | 94.6 | 1.22 | 2.65 MiB | 2.17 MiB |
| `pigz` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 38.7 | 7.94 | 163.0 | 1.88 | 2.90 MiB | 2.17 MiB |
| `pigz` | 7 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 14.8 | 2.33 | 27.7 | 1.25 | 2.42 MiB | 2.17 MiB |
| `pigz` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 49.7 | 2.33 | 94.6 | 1.22 | 2.66 MiB | 2.17 MiB |
| `pigz` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 35.9 | 8.55 | 163.0 | 1.88 | 2.91 MiB | 2.17 MiB |
| `pigz` | 8 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 10.5 | 3.28 | 27.7 | 1.25 | 2.42 MiB | 2.17 MiB |
| `pigz` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 42.6 | 2.72 | 94.6 | 1.22 | 2.67 MiB | 2.17 MiB |
| `pigz` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 32.9 | 9.33 | 163.0 | 1.88 | 2.89 MiB | 2.17 MiB |
| `pigz` | 9 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 7.3 | 4.71 | 27.7 | 1.25 | 2.41 MiB | 2.17 MiB |
| `pigz` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 41.1 | 2.82 | 94.6 | 1.22 | 2.67 MiB | 2.17 MiB |
| `pigz` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 25.6 | 12.01 | 163.0 | 1.88 | 2.90 MiB | 2.17 MiB |
| `std-gzip` | 1 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 29.0 | 1.19 | 55.8 | 0.62 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 64.2 | 1.80 | 159.7 | 0.73 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 62.9 | 4.88 | 187.4 | 1.64 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 2 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 28.6 | 1.21 | 55.8 | 0.62 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 61.5 | 1.89 | 159.7 | 0.73 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 59.6 | 5.15 | 187.4 | 1.64 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 3 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 27.0 | 1.28 | 55.8 | 0.62 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 62.5 | 1.85 | 159.7 | 0.73 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 49.8 | 6.17 | 187.4 | 1.64 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 4 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 28.5 | 1.21 | 55.8 | 0.62 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 60.4 | 1.92 | 159.7 | 0.73 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 54.1 | 5.68 | 187.4 | 1.64 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 5 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 20.1 | 1.72 | 55.8 | 0.62 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 58.1 | 2.00 | 159.7 | 0.73 | 0.90 MiB | 0.95 MiB |
| `std-gzip` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 37.2 | 8.26 | 187.4 | 1.64 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 6 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 14.1 | 2.45 | 55.8 | 0.62 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 54.6 | 2.12 | 159.7 | 0.73 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 27.4 | 11.21 | 187.4 | 1.64 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 7 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 11.5 | 3.00 | 55.8 | 0.62 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 49.0 | 2.37 | 159.7 | 0.73 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 23.7 | 12.96 | 187.4 | 1.64 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 8 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 7.7 | 4.50 | 55.8 | 0.62 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 39.9 | 2.90 | 159.7 | 0.73 | 0.84 MiB | 0.95 MiB |
| `std-gzip` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 20.0 | 15.39 | 187.4 | 1.64 | 0.95 MiB | 0.95 MiB |
| `std-gzip` | 9 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 5.6 | 6.15 | 55.8 | 0.62 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 37.3 | 3.11 | 159.7 | 0.73 | 0.94 MiB | 0.95 MiB |
| `std-gzip` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 19.8 | 15.55 | 187.4 | 1.64 | 0.94 MiB | 0.95 MiB |
| `zlib-ng` | 0 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 37.4 | 0.92 | 39.0 | 0.89 | 1.86 MiB | 1.60 MiB |
| `zlib-ng` | 0 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 99.7 | 1.16 | 108.9 | 1.06 | 2.09 MiB | 1.85 MiB |
| `zlib-ng` | 0 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 253.1 | 1.21 | 196.8 | 1.56 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 1 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 31.3 | 1.11 | 39.0 | 0.89 | 1.85 MiB | 1.60 MiB |
| `zlib-ng` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 90.8 | 1.28 | 108.9 | 1.06 | 2.10 MiB | 1.85 MiB |
| `zlib-ng` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 120.1 | 2.56 | 196.8 | 1.56 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 2 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 27.5 | 1.26 | 39.0 | 0.89 | 1.86 MiB | 1.60 MiB |
| `zlib-ng` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 79.2 | 1.46 | 108.9 | 1.06 | 2.09 MiB | 1.85 MiB |
| `zlib-ng` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 86.1 | 3.57 | 196.8 | 1.56 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 3 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 27.7 | 1.25 | 39.0 | 0.89 | 1.86 MiB | 1.60 MiB |
| `zlib-ng` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 73.9 | 1.57 | 108.9 | 1.06 | 2.10 MiB | 1.85 MiB |
| `zlib-ng` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 74.3 | 4.13 | 196.8 | 1.56 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 4 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 25.8 | 1.34 | 39.0 | 0.89 | 1.85 MiB | 1.60 MiB |
| `zlib-ng` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 70.2 | 1.65 | 108.9 | 1.06 | 2.10 MiB | 1.85 MiB |
| `zlib-ng` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 63.2 | 4.86 | 196.8 | 1.56 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 5 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 23.7 | 1.46 | 39.0 | 0.89 | 1.85 MiB | 1.60 MiB |
| `zlib-ng` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 66.7 | 1.74 | 108.9 | 1.06 | 2.09 MiB | 1.85 MiB |
| `zlib-ng` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 58.7 | 5.23 | 196.8 | 1.56 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 6 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 21.0 | 1.65 | 39.0 | 0.89 | 1.86 MiB | 1.60 MiB |
| `zlib-ng` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 62.1 | 1.87 | 108.9 | 1.06 | 2.10 MiB | 1.85 MiB |
| `zlib-ng` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 53.2 | 5.78 | 196.8 | 1.56 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 7 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 15.5 | 2.24 | 39.0 | 0.89 | 1.86 MiB | 1.60 MiB |
| `zlib-ng` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 55.1 | 2.10 | 108.9 | 1.06 | 2.10 MiB | 1.85 MiB |
| `zlib-ng` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 37.7 | 8.14 | 196.8 | 1.56 | 2.10 MiB | 1.91 MiB |
| `zlib-ng` | 8 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 12.0 | 2.88 | 39.0 | 0.89 | 1.84 MiB | 1.60 MiB |
| `zlib-ng` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 43.7 | 2.65 | 108.9 | 1.06 | 2.09 MiB | 1.85 MiB |
| `zlib-ng` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 35.0 | 8.77 | 196.8 | 1.56 | 2.09 MiB | 1.91 MiB |
| `zlib-ng` | 9 | sequencing | sanity | `test_1.fastq.gz` | 33.8 KiB | 8.1 | 4.25 | 39.0 | 0.89 | 1.86 MiB | 1.60 MiB |
| `zlib-ng` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 113.2 KiB | 44.2 | 2.62 | 108.9 | 1.06 | 2.10 MiB | 1.85 MiB |
| `zlib-ng` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 300.0 KiB | 26.9 | 11.43 | 196.8 | 1.56 | 2.10 MiB | 1.91 MiB |

#### Compression

| Tool | Level | Category | Class | File | Uncomp B | Corpus gz | Tool bytes | Ratio | Kept | gzip -6 | gzip -6 kept |
| --- | ---: | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `flate2-miniz` | 0 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 34618 | 1.00x | 100.1% | 9402 | 27.2% |
| `flate2-miniz` | 0 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 20221285 | 1.00x | 100.0% | 3301992 | 16.3% |
| `flate2-miniz` | 0 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 115949 | 1.00x | 100.0% | 14079 | 12.1% |
| `flate2-miniz` | 0 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 1238148 | 1.00x | 100.0% | 273965 | 22.1% |
| `flate2-miniz` | 0 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 307268 | 1.00x | 100.0% | 87948 | 28.6% |
| `flate2-miniz` | 0 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 2821583 | 1.00x | 100.0% | 739057 | 26.2% |
| `flate2-miniz` | 1 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 12875 | 2.69x | 37.2% | 9402 | 27.2% |
| `flate2-miniz` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 5066476 | 3.99x | 25.1% | 3301992 | 16.3% |
| `flate2-miniz` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 17803 | 6.51x | 15.4% | 14079 | 12.1% |
| `flate2-miniz` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 306121 | 4.04x | 24.7% | 273965 | 22.1% |
| `flate2-miniz` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 119472 | 2.57x | 38.9% | 87948 | 28.6% |
| `flate2-miniz` | 1 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 998293 | 2.83x | 35.4% | 739057 | 26.2% |
| `flate2-miniz` | 2 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10725 | 3.23x | 31.0% | 9402 | 27.2% |
| `flate2-miniz` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4321311 | 4.68x | 21.4% | 3301992 | 16.3% |
| `flate2-miniz` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15803 | 7.33x | 13.6% | 14079 | 12.1% |
| `flate2-miniz` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 292879 | 4.23x | 23.7% | 273965 | 22.1% |
| `flate2-miniz` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 97809 | 3.14x | 31.8% | 87948 | 28.6% |
| `flate2-miniz` | 2 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 817100 | 3.45x | 29.0% | 739057 | 26.2% |
| `flate2-miniz` | 3 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9939 | 3.48x | 28.7% | 9402 | 27.2% |
| `flate2-miniz` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3631184 | 5.57x | 18.0% | 3301992 | 16.3% |
| `flate2-miniz` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14753 | 7.86x | 12.7% | 14079 | 12.1% |
| `flate2-miniz` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 283578 | 4.37x | 22.9% | 273965 | 22.1% |
| `flate2-miniz` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 91063 | 3.37x | 29.6% | 87948 | 28.6% |
| `flate2-miniz` | 3 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 788645 | 3.58x | 28.0% | 739057 | 26.2% |
| `flate2-miniz` | 4 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10003 | 3.46x | 28.9% | 9402 | 27.2% |
| `flate2-miniz` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3630031 | 5.57x | 18.0% | 3301992 | 16.3% |
| `flate2-miniz` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14221 | 8.15x | 12.3% | 14079 | 12.1% |
| `flate2-miniz` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 279043 | 4.44x | 22.5% | 273965 | 22.1% |
| `flate2-miniz` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 89794 | 3.42x | 29.2% | 87948 | 28.6% |
| `flate2-miniz` | 4 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 756630 | 3.73x | 26.8% | 739057 | 26.2% |
| `flate2-miniz` | 5 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9793 | 3.53x | 28.3% | 9402 | 27.2% |
| `flate2-miniz` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3474406 | 5.82x | 17.2% | 3301992 | 16.3% |
| `flate2-miniz` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14101 | 8.22x | 12.2% | 14079 | 12.1% |
| `flate2-miniz` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 276725 | 4.47x | 22.4% | 273965 | 22.1% |
| `flate2-miniz` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88783 | 3.46x | 28.9% | 87948 | 28.6% |
| `flate2-miniz` | 5 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 750238 | 3.76x | 26.6% | 739057 | 26.2% |
| `flate2-miniz` | 6 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9328 | 3.71x | 27.0% | 9402 | 27.2% |
| `flate2-miniz` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3270215 | 6.18x | 16.2% | 3301992 | 16.3% |
| `flate2-miniz` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13899 | 8.34x | 12.0% | 14079 | 12.1% |
| `flate2-miniz` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 274211 | 4.51x | 22.2% | 273965 | 22.1% |
| `flate2-miniz` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87972 | 3.49x | 28.6% | 87948 | 28.6% |
| `flate2-miniz` | 6 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 740877 | 3.81x | 26.3% | 739057 | 26.2% |
| `flate2-miniz` | 7 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9266 | 3.73x | 26.8% | 9402 | 27.2% |
| `flate2-miniz` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3227269 | 6.26x | 16.0% | 3301992 | 16.3% |
| `flate2-miniz` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13823 | 8.39x | 11.9% | 14079 | 12.1% |
| `flate2-miniz` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 273459 | 4.53x | 22.1% | 273965 | 22.1% |
| `flate2-miniz` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87862 | 3.50x | 28.6% | 87948 | 28.6% |
| `flate2-miniz` | 7 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 743814 | 3.79x | 26.4% | 739057 | 26.2% |
| `flate2-miniz` | 8 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9246 | 3.74x | 26.7% | 9402 | 27.2% |
| `flate2-miniz` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3213817 | 6.29x | 15.9% | 3301992 | 16.3% |
| `flate2-miniz` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13805 | 8.40x | 11.9% | 14079 | 12.1% |
| `flate2-miniz` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 273116 | 4.53x | 22.1% | 273965 | 22.1% |
| `flate2-miniz` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87840 | 3.50x | 28.6% | 87948 | 28.6% |
| `flate2-miniz` | 8 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 742391 | 3.80x | 26.3% | 739057 | 26.2% |
| `flate2-miniz` | 9 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9239 | 3.74x | 26.7% | 9402 | 27.2% |
| `flate2-miniz` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3208629 | 6.30x | 15.9% | 3301992 | 16.3% |
| `flate2-miniz` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13799 | 8.40x | 11.9% | 14079 | 12.1% |
| `flate2-miniz` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 272915 | 4.54x | 22.0% | 273965 | 22.1% |
| `flate2-miniz` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87801 | 3.50x | 28.6% | 87948 | 28.6% |
| `flate2-miniz` | 9 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 741468 | 3.80x | 26.3% | 739057 | 26.2% |
| `flate2-zlib-rs` | 0 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 34618 | 1.00x | 100.1% | 9402 | 27.2% |
| `flate2-zlib-rs` | 0 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 20221190 | 1.00x | 100.0% | 3301992 | 16.3% |
| `flate2-zlib-rs` | 0 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 115949 | 1.00x | 100.0% | 14079 | 12.1% |
| `flate2-zlib-rs` | 0 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 1238143 | 1.00x | 100.0% | 273965 | 22.1% |
| `flate2-zlib-rs` | 0 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 307268 | 1.00x | 100.0% | 87948 | 28.6% |
| `flate2-zlib-rs` | 0 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 2821573 | 1.00x | 100.0% | 739057 | 26.2% |
| `flate2-zlib-rs` | 1 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 16143 | 2.14x | 46.7% | 9402 | 27.2% |
| `flate2-zlib-rs` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 5538962 | 3.65x | 27.4% | 3301992 | 16.3% |
| `flate2-zlib-rs` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 19800 | 5.85x | 17.1% | 14079 | 12.1% |
| `flate2-zlib-rs` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 411520 | 3.01x | 33.2% | 273965 | 22.1% |
| `flate2-zlib-rs` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 128247 | 2.40x | 41.7% | 87948 | 28.6% |
| `flate2-zlib-rs` | 1 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 1151612 | 2.45x | 40.8% | 739057 | 26.2% |
| `flate2-zlib-rs` | 2 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10632 | 3.25x | 30.7% | 9402 | 27.2% |
| `flate2-zlib-rs` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3860844 | 5.24x | 19.1% | 3301992 | 16.3% |
| `flate2-zlib-rs` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 16318 | 7.10x | 14.1% | 14079 | 12.1% |
| `flate2-zlib-rs` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 285079 | 4.34x | 23.0% | 273965 | 22.1% |
| `flate2-zlib-rs` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 99091 | 3.10x | 32.3% | 87948 | 28.6% |
| `flate2-zlib-rs` | 2 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 820110 | 3.44x | 29.1% | 739057 | 26.2% |
| `flate2-zlib-rs` | 3 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10031 | 3.45x | 29.0% | 9402 | 27.2% |
| `flate2-zlib-rs` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3733462 | 5.42x | 18.5% | 3301992 | 16.3% |
| `flate2-zlib-rs` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15560 | 7.45x | 13.4% | 14079 | 12.1% |
| `flate2-zlib-rs` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 279994 | 4.42x | 22.6% | 273965 | 22.1% |
| `flate2-zlib-rs` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 92185 | 3.33x | 30.0% | 87948 | 28.6% |
| `flate2-zlib-rs` | 3 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 775746 | 3.64x | 27.5% | 739057 | 26.2% |
| `flate2-zlib-rs` | 4 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9590 | 3.61x | 27.7% | 9402 | 27.2% |
| `flate2-zlib-rs` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3456706 | 5.85x | 17.1% | 3301992 | 16.3% |
| `flate2-zlib-rs` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15036 | 7.71x | 13.0% | 14079 | 12.1% |
| `flate2-zlib-rs` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 272122 | 4.55x | 22.0% | 273965 | 22.1% |
| `flate2-zlib-rs` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 90470 | 3.40x | 29.4% | 87948 | 28.6% |
| `flate2-zlib-rs` | 4 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 761056 | 3.71x | 27.0% | 739057 | 26.2% |
| `flate2-zlib-rs` | 5 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9439 | 3.66x | 27.3% | 9402 | 27.2% |
| `flate2-zlib-rs` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3370413 | 6.00x | 16.7% | 3301992 | 16.3% |
| `flate2-zlib-rs` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14257 | 8.13x | 12.3% | 14079 | 12.1% |
| `flate2-zlib-rs` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 265568 | 4.66x | 21.5% | 273965 | 22.1% |
| `flate2-zlib-rs` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 89113 | 3.45x | 29.0% | 87948 | 28.6% |
| `flate2-zlib-rs` | 5 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 750475 | 3.76x | 26.6% | 739057 | 26.2% |
| `flate2-zlib-rs` | 6 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9350 | 3.70x | 27.0% | 9402 | 27.2% |
| `flate2-zlib-rs` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3255615 | 6.21x | 16.1% | 3301992 | 16.3% |
| `flate2-zlib-rs` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14003 | 8.28x | 12.1% | 14079 | 12.1% |
| `flate2-zlib-rs` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 263220 | 4.70x | 21.3% | 273965 | 22.1% |
| `flate2-zlib-rs` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88926 | 3.45x | 28.9% | 87948 | 28.6% |
| `flate2-zlib-rs` | 6 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 746793 | 3.78x | 26.5% | 739057 | 26.2% |
| `flate2-zlib-rs` | 7 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9202 | 3.76x | 26.6% | 9402 | 27.2% |
| `flate2-zlib-rs` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3190139 | 6.34x | 15.8% | 3301992 | 16.3% |
| `flate2-zlib-rs` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13929 | 8.32x | 12.0% | 14079 | 12.1% |
| `flate2-zlib-rs` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 262472 | 4.72x | 21.2% | 273965 | 22.1% |
| `flate2-zlib-rs` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87961 | 3.49x | 28.6% | 87948 | 28.6% |
| `flate2-zlib-rs` | 7 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 734114 | 3.84x | 26.0% | 739057 | 26.2% |
| `flate2-zlib-rs` | 8 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9141 | 3.78x | 26.4% | 9402 | 27.2% |
| `flate2-zlib-rs` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3144693 | 6.43x | 15.6% | 3301992 | 16.3% |
| `flate2-zlib-rs` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13645 | 8.49x | 11.8% | 14079 | 12.1% |
| `flate2-zlib-rs` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 259707 | 4.77x | 21.0% | 273965 | 22.1% |
| `flate2-zlib-rs` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87878 | 3.50x | 28.6% | 87948 | 28.6% |
| `flate2-zlib-rs` | 8 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 730183 | 3.86x | 25.9% | 739057 | 26.2% |
| `flate2-zlib-rs` | 9 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9212 | 3.75x | 26.6% | 9402 | 27.2% |
| `flate2-zlib-rs` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3231752 | 6.26x | 16.0% | 3301992 | 16.3% |
| `flate2-zlib-rs` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13979 | 8.29x | 12.1% | 14079 | 12.1% |
| `flate2-zlib-rs` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 273807 | 4.52x | 22.1% | 273965 | 22.1% |
| `flate2-zlib-rs` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87880 | 3.50x | 28.6% | 87948 | 28.6% |
| `flate2-zlib-rs` | 9 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 733404 | 3.85x | 26.0% | 739057 | 26.2% |
| `gnu-gzip` | 1 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 11358 | 3.05x | 32.8% | 9402 | 27.2% |
| `gnu-gzip` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4464780 | 4.53x | 22.1% | 3301992 | 16.3% |
| `gnu-gzip` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 16907 | 6.86x | 14.6% | 14079 | 12.1% |
| `gnu-gzip` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 308219 | 4.02x | 24.9% | 273965 | 22.1% |
| `gnu-gzip` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 104086 | 2.95x | 33.9% | 87948 | 28.6% |
| `gnu-gzip` | 1 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 872555 | 3.23x | 30.9% | 739057 | 26.2% |
| `gnu-gzip` | 2 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10847 | 3.19x | 31.4% | 9402 | 27.2% |
| `gnu-gzip` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4136840 | 4.89x | 20.5% | 3301992 | 16.3% |
| `gnu-gzip` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 16412 | 7.06x | 14.2% | 14079 | 12.1% |
| `gnu-gzip` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 302750 | 4.09x | 24.5% | 273965 | 22.1% |
| `gnu-gzip` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 100124 | 3.07x | 32.6% | 87948 | 28.6% |
| `gnu-gzip` | 2 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 841636 | 3.35x | 29.8% | 739057 | 26.2% |
| `gnu-gzip` | 3 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10187 | 3.40x | 29.5% | 9402 | 27.2% |
| `gnu-gzip` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3808833 | 5.31x | 18.8% | 3301992 | 16.3% |
| `gnu-gzip` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 16050 | 7.22x | 13.8% | 14079 | 12.1% |
| `gnu-gzip` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 296565 | 4.17x | 24.0% | 273965 | 22.1% |
| `gnu-gzip` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 97124 | 3.16x | 31.6% | 87948 | 28.6% |
| `gnu-gzip` | 3 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 813258 | 3.47x | 28.8% | 739057 | 26.2% |
| `gnu-gzip` | 4 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10167 | 3.40x | 29.4% | 9402 | 27.2% |
| `gnu-gzip` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3792271 | 5.33x | 18.8% | 3301992 | 16.3% |
| `gnu-gzip` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15330 | 7.56x | 13.2% | 14079 | 12.1% |
| `gnu-gzip` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 291152 | 4.25x | 23.5% | 273965 | 22.1% |
| `gnu-gzip` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 91544 | 3.36x | 29.8% | 87948 | 28.6% |
| `gnu-gzip` | 4 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 789773 | 3.57x | 28.0% | 739057 | 26.2% |
| `gnu-gzip` | 5 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9823 | 3.52x | 28.4% | 9402 | 27.2% |
| `gnu-gzip` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3522934 | 5.74x | 17.4% | 3301992 | 16.3% |
| `gnu-gzip` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14547 | 7.97x | 12.6% | 14079 | 12.1% |
| `gnu-gzip` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 280667 | 4.41x | 22.7% | 273965 | 22.1% |
| `gnu-gzip` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88770 | 3.46x | 28.9% | 87948 | 28.6% |
| `gnu-gzip` | 5 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 750036 | 3.76x | 26.6% | 739057 | 26.2% |
| `gnu-gzip` | 6 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9396 | 3.68x | 27.2% | 9402 | 27.2% |
| `gnu-gzip` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3301986 | 6.12x | 16.3% | 3301992 | 16.3% |
| `gnu-gzip` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14073 | 8.24x | 12.1% | 14079 | 12.1% |
| `gnu-gzip` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 273959 | 4.52x | 22.1% | 273965 | 22.1% |
| `gnu-gzip` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87942 | 3.49x | 28.6% | 87948 | 28.6% |
| `gnu-gzip` | 6 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 739051 | 3.82x | 26.2% | 739057 | 26.2% |
| `gnu-gzip` | 7 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9263 | 3.73x | 26.8% | 9402 | 27.2% |
| `gnu-gzip` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3254970 | 6.21x | 16.1% | 3301992 | 16.3% |
| `gnu-gzip` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13882 | 8.35x | 12.0% | 14079 | 12.1% |
| `gnu-gzip` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 272844 | 4.54x | 22.0% | 273965 | 22.1% |
| `gnu-gzip` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87861 | 3.50x | 28.6% | 87948 | 28.6% |
| `gnu-gzip` | 7 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 740947 | 3.81x | 26.3% | 739057 | 26.2% |
| `gnu-gzip` | 8 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9203 | 3.76x | 26.6% | 9402 | 27.2% |
| `gnu-gzip` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3204476 | 6.31x | 15.8% | 3301992 | 16.3% |
| `gnu-gzip` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13584 | 8.53x | 11.7% | 14079 | 12.1% |
| `gnu-gzip` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 269638 | 4.59x | 21.8% | 273965 | 22.1% |
| `gnu-gzip` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87758 | 3.50x | 28.6% | 87948 | 28.6% |
| `gnu-gzip` | 8 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 736786 | 3.83x | 26.1% | 739057 | 26.2% |
| `gnu-gzip` | 9 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9175 | 3.77x | 26.5% | 9402 | 27.2% |
| `gnu-gzip` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3200018 | 6.32x | 15.8% | 3301992 | 16.3% |
| `gnu-gzip` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13570 | 8.54x | 11.7% | 14079 | 12.1% |
| `gnu-gzip` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 269410 | 4.59x | 21.8% | 273965 | 22.1% |
| `gnu-gzip` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87724 | 3.50x | 28.6% | 87948 | 28.6% |
| `gnu-gzip` | 9 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 736208 | 3.83x | 26.1% | 739057 | 26.2% |
| `igzip` | 0 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 12235 | 2.83x | 35.4% | 9402 | 27.2% |
| `igzip` | 0 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4923764 | 4.11x | 24.4% | 3301992 | 16.3% |
| `igzip` | 0 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 19573 | 5.92x | 16.9% | 14079 | 12.1% |
| `igzip` | 0 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 417554 | 2.96x | 33.7% | 273965 | 22.1% |
| `igzip` | 0 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 104875 | 2.93x | 34.1% | 87948 | 28.6% |
| `igzip` | 0 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 954171 | 2.96x | 33.8% | 739057 | 26.2% |
| `igzip` | 1 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10737 | 3.22x | 31.0% | 9402 | 27.2% |
| `igzip` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4145764 | 4.88x | 20.5% | 3301992 | 16.3% |
| `igzip` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 16325 | 7.10x | 14.1% | 14079 | 12.1% |
| `igzip` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 288373 | 4.29x | 23.3% | 273965 | 22.1% |
| `igzip` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 101322 | 3.03x | 33.0% | 87948 | 28.6% |
| `igzip` | 1 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 874762 | 3.23x | 31.0% | 739057 | 26.2% |
| `igzip` | 2 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10716 | 3.23x | 31.0% | 9402 | 27.2% |
| `igzip` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4111482 | 4.92x | 20.3% | 3301992 | 16.3% |
| `igzip` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 16211 | 7.15x | 14.0% | 14079 | 12.1% |
| `igzip` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 283828 | 4.36x | 22.9% | 273965 | 22.1% |
| `igzip` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 99643 | 3.08x | 32.4% | 87948 | 28.6% |
| `igzip` | 2 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 859685 | 3.28x | 30.5% | 739057 | 26.2% |
| `igzip` | 3 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10729 | 3.22x | 31.0% | 9402 | 27.2% |
| `igzip` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4112831 | 4.92x | 20.3% | 3301992 | 16.3% |
| `igzip` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 16484 | 7.03x | 14.2% | 14079 | 12.1% |
| `igzip` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 284320 | 4.35x | 23.0% | 273965 | 22.1% |
| `igzip` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 96089 | 3.20x | 31.3% | 87948 | 28.6% |
| `igzip` | 3 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 835858 | 3.38x | 29.6% | 739057 | 26.2% |
| `libdeflate-gzip` | 1 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10372 | 3.33x | 30.0% | 9402 | 27.2% |
| `libdeflate-gzip` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4021931 | 5.03x | 19.9% | 3301992 | 16.3% |
| `libdeflate-gzip` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15735 | 7.37x | 13.6% | 14079 | 12.1% |
| `libdeflate-gzip` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 280034 | 4.42x | 22.6% | 273965 | 22.1% |
| `libdeflate-gzip` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 94986 | 3.23x | 30.9% | 87948 | 28.6% |
| `libdeflate-gzip` | 1 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 792877 | 3.56x | 28.1% | 739057 | 26.2% |
| `libdeflate-gzip` | 10 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 8660 | 3.99x | 25.0% | 9402 | 27.2% |
| `libdeflate-gzip` | 10 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3053953 | 6.62x | 15.1% | 3301992 | 16.3% |
| `libdeflate-gzip` | 10 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 12746 | 9.09x | 11.0% | 14079 | 12.1% |
| `libdeflate-gzip` | 10 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 249130 | 4.97x | 20.1% | 273965 | 22.1% |
| `libdeflate-gzip` | 10 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 84306 | 3.64x | 27.4% | 87948 | 28.6% |
| `libdeflate-gzip` | 10 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 677348 | 4.16x | 24.0% | 739057 | 26.2% |
| `libdeflate-gzip` | 11 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 8626 | 4.01x | 24.9% | 9402 | 27.2% |
| `libdeflate-gzip` | 11 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3018110 | 6.70x | 14.9% | 3301992 | 16.3% |
| `libdeflate-gzip` | 11 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 12302 | 9.42x | 10.6% | 14079 | 12.1% |
| `libdeflate-gzip` | 11 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 240681 | 5.14x | 19.4% | 273965 | 22.1% |
| `libdeflate-gzip` | 11 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 83985 | 3.66x | 27.3% | 87948 | 28.6% |
| `libdeflate-gzip` | 11 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 674872 | 4.18x | 23.9% | 739057 | 26.2% |
| `libdeflate-gzip` | 12 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 8621 | 4.01x | 24.9% | 9402 | 27.2% |
| `libdeflate-gzip` | 12 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3018036 | 6.70x | 14.9% | 3301992 | 16.3% |
| `libdeflate-gzip` | 12 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 12279 | 9.44x | 10.6% | 14079 | 12.1% |
| `libdeflate-gzip` | 12 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 239768 | 5.16x | 19.4% | 273965 | 22.1% |
| `libdeflate-gzip` | 12 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 84050 | 3.65x | 27.4% | 87948 | 28.6% |
| `libdeflate-gzip` | 12 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 674139 | 4.18x | 23.9% | 739057 | 26.2% |
| `libdeflate-gzip` | 2 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10088 | 3.43x | 29.2% | 9402 | 27.2% |
| `libdeflate-gzip` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3755315 | 5.38x | 18.6% | 3301992 | 16.3% |
| `libdeflate-gzip` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15495 | 7.48x | 13.4% | 14079 | 12.1% |
| `libdeflate-gzip` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 280014 | 4.42x | 22.6% | 273965 | 22.1% |
| `libdeflate-gzip` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 92216 | 3.33x | 30.0% | 87948 | 28.6% |
| `libdeflate-gzip` | 2 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 749449 | 3.76x | 26.6% | 739057 | 26.2% |
| `libdeflate-gzip` | 3 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9755 | 3.55x | 28.2% | 9402 | 27.2% |
| `libdeflate-gzip` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3603641 | 5.61x | 17.8% | 3301992 | 16.3% |
| `libdeflate-gzip` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15079 | 7.69x | 13.0% | 14079 | 12.1% |
| `libdeflate-gzip` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 278109 | 4.45x | 22.5% | 273965 | 22.1% |
| `libdeflate-gzip` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 90780 | 3.38x | 29.6% | 87948 | 28.6% |
| `libdeflate-gzip` | 3 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 737843 | 3.82x | 26.2% | 739057 | 26.2% |
| `libdeflate-gzip` | 4 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9620 | 3.60x | 27.8% | 9402 | 27.2% |
| `libdeflate-gzip` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3505590 | 5.77x | 17.3% | 3301992 | 16.3% |
| `libdeflate-gzip` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14608 | 7.93x | 12.6% | 14079 | 12.1% |
| `libdeflate-gzip` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 271442 | 4.56x | 21.9% | 273965 | 22.1% |
| `libdeflate-gzip` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 90293 | 3.40x | 29.4% | 87948 | 28.6% |
| `libdeflate-gzip` | 4 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 734599 | 3.84x | 26.0% | 739057 | 26.2% |
| `libdeflate-gzip` | 5 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9509 | 3.64x | 27.5% | 9402 | 27.2% |
| `libdeflate-gzip` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3403167 | 5.94x | 16.8% | 3301992 | 16.3% |
| `libdeflate-gzip` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14022 | 8.27x | 12.1% | 14079 | 12.1% |
| `libdeflate-gzip` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 260121 | 4.76x | 21.0% | 273965 | 22.1% |
| `libdeflate-gzip` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88461 | 3.47x | 28.8% | 87948 | 28.6% |
| `libdeflate-gzip` | 5 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 727604 | 3.88x | 25.8% | 739057 | 26.2% |
| `libdeflate-gzip` | 6 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9310 | 3.72x | 26.9% | 9402 | 27.2% |
| `libdeflate-gzip` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3291448 | 6.14x | 16.3% | 3301992 | 16.3% |
| `libdeflate-gzip` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13688 | 8.47x | 11.8% | 14079 | 12.1% |
| `libdeflate-gzip` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 255319 | 4.85x | 20.6% | 273965 | 22.1% |
| `libdeflate-gzip` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88155 | 3.48x | 28.7% | 87948 | 28.6% |
| `libdeflate-gzip` | 6 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 722640 | 3.90x | 25.6% | 739057 | 26.2% |
| `libdeflate-gzip` | 7 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9184 | 3.77x | 26.6% | 9402 | 27.2% |
| `libdeflate-gzip` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3182321 | 6.35x | 15.7% | 3301992 | 16.3% |
| `libdeflate-gzip` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13283 | 8.73x | 11.5% | 14079 | 12.1% |
| `libdeflate-gzip` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 251669 | 4.92x | 20.3% | 273965 | 22.1% |
| `libdeflate-gzip` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87908 | 3.49x | 28.6% | 87948 | 28.6% |
| `libdeflate-gzip` | 7 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 719824 | 3.92x | 25.5% | 739057 | 26.2% |
| `libdeflate-gzip` | 8 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9110 | 3.80x | 26.3% | 9402 | 27.2% |
| `libdeflate-gzip` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3124855 | 6.47x | 15.5% | 3301992 | 16.3% |
| `libdeflate-gzip` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 12994 | 8.92x | 11.2% | 14079 | 12.1% |
| `libdeflate-gzip` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 249560 | 4.96x | 20.2% | 273965 | 22.1% |
| `libdeflate-gzip` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87367 | 3.52x | 28.4% | 87948 | 28.6% |
| `libdeflate-gzip` | 8 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 697790 | 4.04x | 24.7% | 739057 | 26.2% |
| `libdeflate-gzip` | 9 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9095 | 3.80x | 26.3% | 9402 | 27.2% |
| `libdeflate-gzip` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3111202 | 6.50x | 15.4% | 3301992 | 16.3% |
| `libdeflate-gzip` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 12987 | 8.93x | 11.2% | 14079 | 12.1% |
| `libdeflate-gzip` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 248978 | 4.97x | 20.1% | 273965 | 22.1% |
| `libdeflate-gzip` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87324 | 3.52x | 28.4% | 87948 | 28.6% |
| `libdeflate-gzip` | 9 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 696036 | 4.05x | 24.7% | 739057 | 26.2% |
| `pigz` | 0 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 34613 | 1.00x | 100.1% | 9402 | 27.2% |
| `pigz` | 0 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 20220415 | 1.00x | 100.0% | 3301992 | 16.3% |
| `pigz` | 0 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 115939 | 1.00x | 100.0% | 14079 | 12.1% |
| `pigz` | 0 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 1238093 | 1.00x | 100.0% | 273965 | 22.1% |
| `pigz` | 0 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 307253 | 1.00x | 100.0% | 87948 | 28.6% |
| `pigz` | 0 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 2821463 | 1.00x | 100.0% | 739057 | 26.2% |
| `pigz` | 1 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10632 | 3.25x | 30.7% | 9402 | 27.2% |
| `pigz` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3864053 | 5.23x | 19.1% | 3301992 | 16.3% |
| `pigz` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 16318 | 7.10x | 14.1% | 14079 | 12.1% |
| `pigz` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 284280 | 4.35x | 23.0% | 273965 | 22.1% |
| `pigz` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 99088 | 3.10x | 32.3% | 87948 | 28.6% |
| `pigz` | 1 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 817870 | 3.45x | 29.0% | 739057 | 26.2% |
| `pigz` | 2 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10151 | 3.41x | 29.3% | 9402 | 27.2% |
| `pigz` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3702598 | 5.46x | 18.3% | 3301992 | 16.3% |
| `pigz` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15759 | 7.36x | 13.6% | 14079 | 12.1% |
| `pigz` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 281223 | 4.40x | 22.7% | 273965 | 22.1% |
| `pigz` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 96571 | 3.18x | 31.4% | 87948 | 28.6% |
| `pigz` | 2 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 794756 | 3.55x | 28.2% | 739057 | 26.2% |
| `pigz` | 3 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9786 | 3.53x | 28.3% | 9402 | 27.2% |
| `pigz` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3598895 | 5.62x | 17.8% | 3301992 | 16.3% |
| `pigz` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15573 | 7.44x | 13.4% | 14079 | 12.1% |
| `pigz` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 277162 | 4.47x | 22.4% | 273965 | 22.1% |
| `pigz` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 94933 | 3.24x | 30.9% | 87948 | 28.6% |
| `pigz` | 3 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 780500 | 3.61x | 27.7% | 739057 | 26.2% |
| `pigz` | 4 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9746 | 3.55x | 28.2% | 9402 | 27.2% |
| `pigz` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3556563 | 5.68x | 17.6% | 3301992 | 16.3% |
| `pigz` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15440 | 7.51x | 13.3% | 14079 | 12.1% |
| `pigz` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 278795 | 4.44x | 22.5% | 273965 | 22.1% |
| `pigz` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 90738 | 3.39x | 29.5% | 87948 | 28.6% |
| `pigz` | 4 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 760023 | 3.71x | 26.9% | 739057 | 26.2% |
| `pigz` | 5 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9372 | 3.69x | 27.1% | 9402 | 27.2% |
| `pigz` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3357366 | 6.02x | 16.6% | 3301992 | 16.3% |
| `pigz` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14629 | 7.92x | 12.6% | 14079 | 12.1% |
| `pigz` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 268402 | 4.61x | 21.7% | 273965 | 22.1% |
| `pigz` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88519 | 3.47x | 28.8% | 87948 | 28.6% |
| `pigz` | 5 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 741269 | 3.81x | 26.3% | 739057 | 26.2% |
| `pigz` | 6 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9273 | 3.73x | 26.8% | 9402 | 27.2% |
| `pigz` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3231006 | 6.26x | 16.0% | 3301992 | 16.3% |
| `pigz` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14109 | 8.22x | 12.2% | 14079 | 12.1% |
| `pigz` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 262787 | 4.71x | 21.2% | 273965 | 22.1% |
| `pigz` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88125 | 3.49x | 28.7% | 87948 | 28.6% |
| `pigz` | 6 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 735444 | 3.84x | 26.1% | 739057 | 26.2% |
| `pigz` | 7 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9202 | 3.76x | 26.6% | 9402 | 27.2% |
| `pigz` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3191842 | 6.33x | 15.8% | 3301992 | 16.3% |
| `pigz` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13929 | 8.32x | 12.0% | 14079 | 12.1% |
| `pigz` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 261692 | 4.73x | 21.1% | 273965 | 22.1% |
| `pigz` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88068 | 3.49x | 28.7% | 87948 | 28.6% |
| `pigz` | 7 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 733096 | 3.85x | 26.0% | 739057 | 26.2% |
| `pigz` | 8 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9141 | 3.78x | 26.4% | 9402 | 27.2% |
| `pigz` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3146509 | 6.43x | 15.6% | 3301992 | 16.3% |
| `pigz` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13645 | 8.49x | 11.8% | 14079 | 12.1% |
| `pigz` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 258925 | 4.78x | 20.9% | 273965 | 22.1% |
| `pigz` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87983 | 3.49x | 28.6% | 87948 | 28.6% |
| `pigz` | 8 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 729487 | 3.87x | 25.9% | 739057 | 26.2% |
| `pigz` | 9 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9212 | 3.75x | 26.6% | 9402 | 27.2% |
| `pigz` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3234557 | 6.25x | 16.0% | 3301992 | 16.3% |
| `pigz` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13979 | 8.29x | 12.1% | 14079 | 12.1% |
| `pigz` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 273666 | 4.52x | 22.1% | 273965 | 22.1% |
| `pigz` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87852 | 3.50x | 28.6% | 87948 | 28.6% |
| `pigz` | 9 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 731556 | 3.86x | 25.9% | 739057 | 26.2% |
| `std-gzip` | 1 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10877 | 3.18x | 31.4% | 9402 | 27.2% |
| `std-gzip` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4506533 | 4.49x | 22.3% | 3301992 | 16.3% |
| `std-gzip` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 17987 | 6.44x | 15.5% | 14079 | 12.1% |
| `std-gzip` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 311856 | 3.97x | 25.2% | 273965 | 22.1% |
| `std-gzip` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 101043 | 3.04x | 32.9% | 87948 | 28.6% |
| `std-gzip` | 1 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 854452 | 3.30x | 30.3% | 739057 | 26.2% |
| `std-gzip` | 2 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10661 | 3.24x | 30.8% | 9402 | 27.2% |
| `std-gzip` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4345342 | 4.65x | 21.5% | 3301992 | 16.3% |
| `std-gzip` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 16600 | 6.98x | 14.3% | 14079 | 12.1% |
| `std-gzip` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 304622 | 4.06x | 24.6% | 273965 | 22.1% |
| `std-gzip` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 97630 | 3.15x | 31.8% | 87948 | 28.6% |
| `std-gzip` | 2 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 831478 | 3.39x | 29.5% | 739057 | 26.2% |
| `std-gzip` | 3 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10276 | 3.37x | 29.7% | 9402 | 27.2% |
| `std-gzip` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4012080 | 5.04x | 19.8% | 3301992 | 16.3% |
| `std-gzip` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15613 | 7.42x | 13.5% | 14079 | 12.1% |
| `std-gzip` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 292814 | 4.23x | 23.7% | 273965 | 22.1% |
| `std-gzip` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 93222 | 3.30x | 30.3% | 87948 | 28.6% |
| `std-gzip` | 3 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 798580 | 3.53x | 28.3% | 739057 | 26.2% |
| `std-gzip` | 4 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10503 | 3.29x | 30.4% | 9402 | 27.2% |
| `std-gzip` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 4127694 | 4.90x | 20.4% | 3301992 | 16.3% |
| `std-gzip` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15962 | 7.26x | 13.8% | 14079 | 12.1% |
| `std-gzip` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 297034 | 4.17x | 24.0% | 273965 | 22.1% |
| `std-gzip` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 93755 | 3.28x | 30.5% | 87948 | 28.6% |
| `std-gzip` | 4 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 803539 | 3.51x | 28.5% | 739057 | 26.2% |
| `std-gzip` | 5 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9956 | 3.47x | 28.8% | 9402 | 27.2% |
| `std-gzip` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3649356 | 5.54x | 18.1% | 3301992 | 16.3% |
| `std-gzip` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15193 | 7.63x | 13.1% | 14079 | 12.1% |
| `std-gzip` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 288160 | 4.30x | 23.3% | 273965 | 22.1% |
| `std-gzip` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 89629 | 3.43x | 29.2% | 87948 | 28.6% |
| `std-gzip` | 5 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 764899 | 3.69x | 27.1% | 739057 | 26.2% |
| `std-gzip` | 6 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9485 | 3.65x | 27.4% | 9402 | 27.2% |
| `std-gzip` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3427839 | 5.90x | 17.0% | 3301992 | 16.3% |
| `std-gzip` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14608 | 7.93x | 12.6% | 14079 | 12.1% |
| `std-gzip` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 280544 | 4.41x | 22.7% | 273965 | 22.1% |
| `std-gzip` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88571 | 3.47x | 28.8% | 87948 | 28.6% |
| `std-gzip` | 6 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 752116 | 3.75x | 26.7% | 739057 | 26.2% |
| `std-gzip` | 7 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9365 | 3.69x | 27.1% | 9402 | 27.2% |
| `std-gzip` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3356824 | 6.02x | 16.6% | 3301992 | 16.3% |
| `std-gzip` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14396 | 8.05x | 12.4% | 14079 | 12.1% |
| `std-gzip` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 278796 | 4.44x | 22.5% | 273965 | 22.1% |
| `std-gzip` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88421 | 3.47x | 28.8% | 87948 | 28.6% |
| `std-gzip` | 7 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 747650 | 3.77x | 26.5% | 739057 | 26.2% |
| `std-gzip` | 8 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9280 | 3.73x | 26.8% | 9402 | 27.2% |
| `std-gzip` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3259422 | 6.20x | 16.1% | 3301992 | 16.3% |
| `std-gzip` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14150 | 8.19x | 12.2% | 14079 | 12.1% |
| `std-gzip` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 276638 | 4.47x | 22.3% | 273965 | 22.1% |
| `std-gzip` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88315 | 3.48x | 28.7% | 87948 | 28.6% |
| `std-gzip` | 8 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 742668 | 3.80x | 26.3% | 739057 | 26.2% |
| `std-gzip` | 9 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9250 | 3.74x | 26.7% | 9402 | 27.2% |
| `std-gzip` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3253926 | 6.21x | 16.1% | 3301992 | 16.3% |
| `std-gzip` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14125 | 8.21x | 12.2% | 14079 | 12.1% |
| `std-gzip` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 276489 | 4.48x | 22.3% | 273965 | 22.1% |
| `std-gzip` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88246 | 3.48x | 28.7% | 87948 | 28.6% |
| `std-gzip` | 9 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 741973 | 3.80x | 26.3% | 739057 | 26.2% |
| `zlib-ng` | 0 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 34613 | 1.00x | 100.1% | 9402 | 27.2% |
| `zlib-ng` | 0 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 20219645 | 1.00x | 100.0% | 3301992 | 16.3% |
| `zlib-ng` | 0 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 115939 | 1.00x | 100.0% | 14079 | 12.1% |
| `zlib-ng` | 0 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 1238048 | 1.00x | 100.0% | 273965 | 22.1% |
| `zlib-ng` | 0 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 307243 | 1.00x | 100.0% | 87948 | 28.6% |
| `zlib-ng` | 0 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 2821358 | 1.00x | 100.0% | 739057 | 26.2% |
| `zlib-ng` | 1 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 16143 | 2.14x | 46.7% | 9402 | 27.2% |
| `zlib-ng` | 1 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 5541886 | 3.65x | 27.4% | 3301992 | 16.3% |
| `zlib-ng` | 1 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 19799 | 5.85x | 17.1% | 14079 | 12.1% |
| `zlib-ng` | 1 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 411520 | 3.01x | 33.2% | 273965 | 22.1% |
| `zlib-ng` | 1 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 128263 | 2.40x | 41.8% | 87948 | 28.6% |
| `zlib-ng` | 1 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 1151785 | 2.45x | 40.8% | 739057 | 26.2% |
| `zlib-ng` | 2 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10632 | 3.25x | 30.7% | 9402 | 27.2% |
| `zlib-ng` | 2 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3860844 | 5.24x | 19.1% | 3301992 | 16.3% |
| `zlib-ng` | 2 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 16318 | 7.10x | 14.1% | 14079 | 12.1% |
| `zlib-ng` | 2 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 285079 | 4.34x | 23.0% | 273965 | 22.1% |
| `zlib-ng` | 2 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 99091 | 3.10x | 32.3% | 87948 | 28.6% |
| `zlib-ng` | 2 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 820110 | 3.44x | 29.1% | 739057 | 26.2% |
| `zlib-ng` | 3 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 10031 | 3.45x | 29.0% | 9402 | 27.2% |
| `zlib-ng` | 3 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3733462 | 5.42x | 18.5% | 3301992 | 16.3% |
| `zlib-ng` | 3 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15560 | 7.45x | 13.4% | 14079 | 12.1% |
| `zlib-ng` | 3 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 279994 | 4.42x | 22.6% | 273965 | 22.1% |
| `zlib-ng` | 3 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 92185 | 3.33x | 30.0% | 87948 | 28.6% |
| `zlib-ng` | 3 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 775746 | 3.64x | 27.5% | 739057 | 26.2% |
| `zlib-ng` | 4 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9590 | 3.61x | 27.7% | 9402 | 27.2% |
| `zlib-ng` | 4 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3456706 | 5.85x | 17.1% | 3301992 | 16.3% |
| `zlib-ng` | 4 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 15036 | 7.71x | 13.0% | 14079 | 12.1% |
| `zlib-ng` | 4 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 272122 | 4.55x | 22.0% | 273965 | 22.1% |
| `zlib-ng` | 4 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 90470 | 3.40x | 29.4% | 87948 | 28.6% |
| `zlib-ng` | 4 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 761056 | 3.71x | 27.0% | 739057 | 26.2% |
| `zlib-ng` | 5 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9439 | 3.66x | 27.3% | 9402 | 27.2% |
| `zlib-ng` | 5 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3370061 | 6.00x | 16.7% | 3301992 | 16.3% |
| `zlib-ng` | 5 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14257 | 8.13x | 12.3% | 14079 | 12.1% |
| `zlib-ng` | 5 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 265546 | 4.66x | 21.5% | 273965 | 22.1% |
| `zlib-ng` | 5 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 89102 | 3.45x | 29.0% | 87948 | 28.6% |
| `zlib-ng` | 5 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 750404 | 3.76x | 26.6% | 739057 | 26.2% |
| `zlib-ng` | 6 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9351 | 3.70x | 27.0% | 9402 | 27.2% |
| `zlib-ng` | 6 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3255257 | 6.21x | 16.1% | 3301992 | 16.3% |
| `zlib-ng` | 6 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 14003 | 8.28x | 12.1% | 14079 | 12.1% |
| `zlib-ng` | 6 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 263198 | 4.70x | 21.3% | 273965 | 22.1% |
| `zlib-ng` | 6 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 88917 | 3.45x | 28.9% | 87948 | 28.6% |
| `zlib-ng` | 6 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 746709 | 3.78x | 26.5% | 739057 | 26.2% |
| `zlib-ng` | 7 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9202 | 3.76x | 26.6% | 9402 | 27.2% |
| `zlib-ng` | 7 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3190139 | 6.34x | 15.8% | 3301992 | 16.3% |
| `zlib-ng` | 7 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13929 | 8.32x | 12.0% | 14079 | 12.1% |
| `zlib-ng` | 7 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 262472 | 4.72x | 21.2% | 273965 | 22.1% |
| `zlib-ng` | 7 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87961 | 3.49x | 28.6% | 87948 | 28.6% |
| `zlib-ng` | 7 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 734114 | 3.84x | 26.0% | 739057 | 26.2% |
| `zlib-ng` | 8 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9141 | 3.78x | 26.4% | 9402 | 27.2% |
| `zlib-ng` | 8 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3144693 | 6.43x | 15.6% | 3301992 | 16.3% |
| `zlib-ng` | 8 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13645 | 8.49x | 11.8% | 14079 | 12.1% |
| `zlib-ng` | 8 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 259707 | 4.77x | 21.0% | 273965 | 22.1% |
| `zlib-ng` | 8 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87878 | 3.50x | 28.6% | 87948 | 28.6% |
| `zlib-ng` | 8 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 730183 | 3.86x | 25.9% | 739057 | 26.2% |
| `zlib-ng` | 9 | sequencing | sanity | `test_1.fastq.gz` | 34590 | 9413 | 9212 | 3.75x | 26.6% | 9402 | 27.2% |
| `zlib-ng` | 9 | sequencing | small | `SRR389222_sub1.fastq.gz` | 20218082 | 3302006 | 3231752 | 6.26x | 16.0% | 3301992 | 16.3% |
| `zlib-ng` | 9 | ms | sanity | `55merge_omssa.mzid.gz` | 115911 | 14109 | 13979 | 8.29x | 12.1% | 14079 | 12.1% |
| `zlib-ng` | 9 | ms | small | `55merge_tandem.mzid.gz` | 1237935 | 268700 | 273807 | 4.52x | 22.1% | 273965 | 22.1% |
| `zlib-ng` | 9 | generalized | sanity | `hello-1.3.tar.gz` | 307200 | 87942 | 87880 | 3.50x | 28.6% | 87948 | 28.6% |
| `zlib-ng` | 9 | generalized | small | `cantrbry.tar.gz` | 2821120 | 739071 | 733404 | 3.85x | 26.0% | 739057 | 26.2% |

Ratio and kept use the qualify compress write size, not Zebrac (Zebrac discards output to `/dev/null`). Corpus gz is the downloaded file, which was not necessarily produced by this tool or by host `gzip -6`.
<!-- /generated:measured -->

## Tracked contents

- `install.sh` prepares and checks local command installations.
- `versions.sh` owns selected versions.
- `peers.tsv` is the run matrix: one row per `tool + format + compress-level + threads` that we qualify and time. Decompress is not a separate row; it uses level `-` at the same format and threads. ST only.
- `LOG.md` is why a tool is live, dropped, later, or never. Dropped tools are deleted from the tree and from `.local`. Numbers that lost stay in `LOG.md`. Do not add MT rows.
- `levels.tsv` is the scale, CLI default, fast knob, store level, and full set we store for each tool. Integers are not comparable across rows.
- `coverage.tsv` is the capability matrix: work, shape, and integrity for each `tool + format + version`.
- `report.sh` / `report.py` migrate legacy JSON, write `tools/.local/report/` (`facts.tsv`, `headline.tsv`, `gmean.tsv`), and fill generated README sections. `--check` verifies default-class JSON, keys, coverage rows, band rules, `gnu-gzip` gzip-rel identity, and that `.local/plain` does not exist.
- `build.zig` and `zig/` are the `std-gzip` comparison adapter. They are not the z-flate library. They do not spawn C CLIs.
- `invoke.sh` maps each tool to native argv (C/host) or the path CLI (Zig/Rust).
- `rust/flate2-miniz` and `rust/flate2-zlib-rs` are the flate2 adapters. Dropped tools are deleted, not archived in-tree. See `LOG.md`.
- `corpus.sh` and `corpus.tsv` fetch public gzip files into gitignored `data/`.
- `qualify.sh` runs blocking checks against system `gzip`. Default classes are `sanity` and `small`. Mutation checks run on `sanity` only. `--full` adds `medium` and `large`. Writes `sizes.tsv`. Does not keep uncompressed corpus copies.
- `bench.sh` runs Zebrac only after that receipt passes, on the same default classes. JSON is keyed by format, level, and threads. Complete JSON is kept; only missing or `--force` cells are timed. Compress input is a `/tmp` plaintext that is deleted after each file. Bench then runs `report.sh`.
