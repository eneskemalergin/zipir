# Comparison log

Live matrix: [`peers.tsv`](peers.tsv). Pins: [`versions.sh`](versions.sh), [`levels.tsv`](levels.tsv). This file is **why** a tool is live, dropped, later, or never.

**ST gzip only.** Linux x86_64. A row is `tool + format + operation + level + threads`. `threads` is `ST`. `nthreads` is `1`.

Do not add `pigz -p32`, `igzip -T`, `rapidgzip`, `gzp`, pigzpp, or any other thread pool. Host `pigz` is always invoked `-p1`. `igzip` is built and timed without `-T`. `pigz -11` is zopfli, not a gzip level.

Wrap a tool only if it answers a question we do not already have a named engine for. Check it (qualify + Zebrac). Then keep, drop, or never wrap. Dropped tools are **deleted**: adapter source, installer, invoke, pin, and `tools/.local` copies. Numbers that lost stay here. Re-entry needs a new changelog row.

## Changelog

| Date | Action | Tool | Pin | Why in one line |
| --- | --- | --- | --- | --- |
| 2026-09-07 | drop | `libflate` | 2.3.2 | Checked. Decode behind std. `-6` fatter than gzip `-1`. No 1-9 scale. ISIZE no. Adapter and install wiring deleted. |
| 2026-09-07 | include | `zgz` | 0.2.0 | Decode-only Zig CLI over zlib-ng. Same engine as `zlib-ng` minigzip; question is Zig Io + concat/cap CLI. |
| 2026-09-07 | include | `burakssen-libdeflate` | 0.1.0 / libdeflate 1.25 | Zig `@cImport` of ebiggers libdeflate. Same engine family as `libdeflate-gzip` 1.26; version gap is a confound. Zig cc cannot compile libdeflate AVX-512 dispatch (evex512); those paths are compiled out. |
| 2026-09-07 | drop | `cryptopp-gzip` | 8.9.0 | Checked. Decode 175 vs std 477. Encode `-6` 34 vs gzip 44. Concat is not `gzip -dc`. Adapter deleted. |
| 2026-09-07 | drop | `zgz` | 0.2.0 | Checked. Same engine as `zlib-ng`. Decode 992 vs 935, RSS 2.36 vs 1.90 MiB. No encode, so no kept. Deleted. |
| 2026-09-07 | drop | `burakssen-libdeflate` | 0.1.0 / 1.25 | Checked. Encode `-6` 100 vs C CLI 108, decode 497 vs 692, same kept 16.3%. Zig cc skips AVX-512. Deleted. |
| 2026-09-07 | never | Later set | (see Never) | zopfli, `bgzip`, madler zlib, MT CLIs are not this ST gzip table. Not parked. |

## Live

| Tool | Pin | Role |
| --- | --- | --- |
| `std-gzip` | Zig 0.16.0 | Baseline we replace. Stream, bound, smallest RSS. CRC/ISIZE/concat **no**. |
| `gnu-gzip` | 1.14 | Format, integrity, concat, default kept, RSS oracle. Host `/usr/bin/gzip`. |
| `libdeflate-gzip` | 1.26 | Same-ratio ST speed. Whole-buffer. Not the API shape. CLI `1-12` (no `-0`). |
| `igzip` | ISA-L 2.32.1 | Decode ceiling and the fast family. Scale **0-3**, default **2**. Never `-6`. No `-T`. |
| `zlib-ng` | 2.3.3 `minigzip` | SIMD zlib without pigz framing. Streaming encode/decode bar. |
| `pigz` | 2.8 `-p1` | Framing cost vs zlib-ng. Already timed. Do not re-run. Never default `nproc`. |
| `flate2-miniz` | flate2 1.1.10 + miniz_oxide 0.9.1 | Safe native analogue. CRC/ISIZE/concat yes. Not a speed target. |
| `flate2-zlib-rs` | flate2 1.1.10 + zlib-rs 0.6.7 | Native SIMD language bar. No `libz`. |

Default on gzip-family tools is **6**. ISA-L default is **2**. Integers are not comparable across rows. Decompress level is `-`.

## Dropped

Checked, then taken out of the live matrix. Adapter source, installer, invoke, pin, and `.local` copies are deleted. Pin and numbers that lost stay in this file.

Sequencing small `SRR389222_sub1.fastq.gz` (19.28 MiB uncompressed) unless noted. Zebrac 0.6.2, `-w 3 -i 25 -a 25`, classes sanity+small.

### `libflate` 2.3.2 (2026-09-07)

Independent native Rust gzip (`gzip::Encoder` / `MultiDecoder`). Qualify pass. Levels **0** (store) and **6** (only LZ77 setting).

| | Encode MB/s | Decode MB/s | Kept |
| --- | ---: | ---: | ---: |
| `libflate` `-6` | 61.6 | 341.9 | 23.5% |
| `std-gzip` `-6` | 48.6 | 477.4 | 17.0% |
| `gnu-gzip` `-6` | 43.5 | 517.9 | 16.3% |
| `gnu-gzip` `-1` | 149.9 | 517.9 | 22.1% |

Why drop:

1. Decode is behind the baseline we must beat (341.9 vs 477.4).
2. Default encode is a worse product than gzip `-1`: fatter (23.5% vs 22.1%) and slower (61.6 vs 149.9).
3. No zlib 1-9 scale. Only store and one LZ77 setting.
4. ISIZE is **no**. CRC yes, concat yes.

Deleted: `tools/rust/libflate/`, `versions.sh` pin, `install.sh` / `invoke.sh` cases, `tools/.local/{zebrac,qualify,installs}/libflate`, `tools/bin/libflate`. Out of `peers.tsv`, `coverage.tsv`, `levels.tsv`.

### `cryptopp-gzip` 8.9.0 (2026-09-07)

Native C++ `Gzip` / `Gunzip`. Qualify pass except concat is **not** `gzip -dc`. Levels 0-9. Stream yes, bound no.

| | Encode MB/s | Decode MB/s | Kept | Decode RSS |
| --- | ---: | ---: | ---: | ---: |
| `cryptopp-gzip` `-6` | 34.3 | 175.3 | 16.6% | 5.02 MiB |
| `cryptopp-gzip` `-1` | 67.7 | 175.3 | 21.9% | 5.02 MiB |
| `std-gzip` `-6` | 48.6 | 477.4 | 17.0% | 0.94 MiB |
| `gnu-gzip` `-6` | 43.5 | 517.9 | 16.3% | 1.61 MiB |

Why drop:

1. Decode is far behind the baseline (175.3 vs 477.4).
2. Encode `-6` is slower than gzip (34.3 vs 43.5) at nearly the same kept (+0.3 pp).
3. Concat fails the gzip `-dc` check. CRC and ISIZE yes.

Deleted: `tools/cpp/cryptopp_gzip.cpp`, `versions.sh` pin, `install.sh` / `invoke.sh` cases, `tools/.local/{zebrac,qualify,installs}/cryptopp-gzip`, `tools/bin/cryptopp-gzip`. Out of `peers.tsv`, `coverage.tsv`, `levels.tsv`. `tools/cpp/` removed.

### `zgz` 0.2.0 (2026-09-07)

Decode-only Zig CLI over zlib-ng (`zgz FILE.gz` to stdout). No compressor, so no encode MB/s and no kept (`tool_bytes / uncompressed` needs a compress write). Peers row was gzip level `-`. Concat default on. `--max-output` exists. Not a Zig codec.

| | Encode MB/s | Decode MB/s | Kept | Decode RSS |
| --- | ---: | ---: | ---: | ---: |
| `zgz` | n/a | 991.8 | n/a | 2.36 MiB |
| `zlib-ng` `-6` | 92.1 | 935.4 | 16.1% | 1.90 MiB |

Why drop:

1. Same engine as the live `zlib-ng` minigzip row.
2. Decode is close (991.8 vs 935.4) with worse RSS (2.36 vs 1.90 MiB). Packaging, not a new codec.
3. No encode path, so it cannot sit on the encode/kept tables.

Deleted: `versions.sh` pin, `install.sh` / `invoke.sh` cases (fetched at install from the zgz tag; no tracked adapter source), `tools/.local/{zebrac,qualify,installs}/zgz`, `tools/bin/zgz`. Out of `peers.tsv`, `coverage.tsv`, `levels.tsv`. Decode-only plumbing in qualify/bench/report stays; it is small infrastructure, not a copy of zgz.

### `burakssen-libdeflate` 0.1.0 / engine libdeflate 1.25 (2026-09-07)

Zig `@cImport` of ebiggers libdeflate via package pin. Whole-buffer. Concat loops `libdeflate_gzip_decompress_ex`. Zig 0.16 cc cannot compile libdeflate AVX-512 dispatch (`evex512` ABI); those paths were compiled out (`LIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ`, `_AVX512VNNI`, `_AVX_VNNI`). Not a Zig codec.

| | Encode MB/s | Decode MB/s | Kept | Decode RSS |
| --- | ---: | ---: | ---: | ---: |
| `burakssen-libdeflate` `-6` | 100.3 | 497.4 | 16.3% | 25.84 MiB |
| `libdeflate-gzip` 1.26 `-6` | 108.4 | 691.7 | 16.3% | 23.71 MiB |

Why drop:

1. Same engine family as the live C CLI. Version gap (1.25 vs 1.26) plus skipped AVX-512 is a confound, not a Zig lesson.
2. Encode `-6` is slower (100.3 vs 108.4) at the same kept.
3. Decode is slower (497.4 vs 691.7) and RSS is worse (25.84 vs 23.71 MiB).

Deleted: `tools/zig/burakssen_libdeflate.zig`, `tools/build.zig.zon`, burakssen branch of `tools/build.zig`, `versions.sh` pin, `install.sh` / `invoke.sh` cases, `tools/.local/{zebrac,qualify,installs}/burakssen-libdeflate`, `tools/bin/burakssen-libdeflate`, leftover `tools/zig-pkg/`. Out of `peers.tsv`, `coverage.tsv`, `levels.tsv`. `tools/build.zig` is std-gzip only.

## Next

Not in the live matrix. Wrap only if we still need the question.

| Tool | Pin | Question | Notes |
| --- | --- | --- | --- |
| klauspost gzip | 1.20.0 | Unique non-C ST SIMD besides zlib-rs? | Go + amd64 asm. Only ST engine we do not already name. |
| Go `compress/gzip` | go std | Control for klauspost? | Same adapter family. Not a library target. |

Do not wrap unless asked.

## Later

Empty. 2026-09-07: parked items examined. None belong on this ST gzip table. Moved to Never.

## Never

Same engine as a live row, or the wrong product, or a license we will not take.

| Tool | Pin | Why never |
| --- | --- | --- |
| flate2 `zlib-ng` | 1.1.10 + libz-ng-sys | C row with extra Rust. Use `zlib-ng` minigzip. |
| `libdeflater` | 1.26.0 | libdeflate C. Use the C CLI. |
| `isal-rs` | 0.5.3 | ISA-L C. Use `igzip`. 16 KiB wrapper buffer. |
| gzippy | 0.8.0 | Multiplexer over ISA-L / libdeflate / zlib-ng / zopfli. Non-standard MT format at some levels. |
| zgz / burakssen-class wraps | (dropped) | Packaging over a live C engine. Checked once. Do not wrap more of this class. |
| Cloudflare zlib | fork | Bun dropped it for zlib-ng 2.3.3. |
| madler zlib `minigzip` | 1.3.2 | Fedora `libz` is zlib-ng. We already time zlib-ng 2.3.3. |
| zopfli | 1.0.3 / rust 0.8.3 | Not a gzip level. Iterations. `pigz -11` is how you invoke it. Different product. |
| `bgzip` | HTSlib 1.24 | BGZF extra + 64 KiB members. Named BGZF would be a new format, not a parked gzip peer. |
| `pigz -p32` / `igzip -T` / `rapidgzip` | MT CLIs | Product is ST. No second table unless the product changes. |
| `gzp` / pigzpp | 2.0.4 / 2026 | Schedulers over engines already timed. MT by design. |
| comprezz, gzig, ianic/flate | Zig forks | Old std, compress-only, or archived into std. |
| omen-mc / neurocyte libdeflate | stale | Not Zig 0.16. Use the C CLI. |
| miniz Zig packs | various | No gzip round-trip. |
| zenflate | 0.4.0 | AGPL-3.0-only or commercial. |
| QAT / NX-GZIP / IAA | QATzip 2.0.0 | Device, driver, DMA RSS. Not a 3950X library number. |
| Python / Java / .NET gzip | FFI | zlib, zlib-ng, or ISA-L underneath. |
| yazi, `inflate`/`deflate` crates | various | No gzip round-trip. |
| `zip` / `rc-zip` | 8.x / 5.x | Zip method 8 is raw DEFLATE, not gzip members. |
| niffler, async-compression | 3.0.1 / 0.4.x | Sniff or async IO over flate2. |
| `gzip` crate | 0.1.2 | Name squat. Last publish 2020. Unfinished. |
| `rust-htslib` | 1.0.1 | BGZF/HTSlib, not `.gz` FASTQ. |

## How to drop

1. Qualify and bench once (or skip if JSON is already complete).
2. Add a changelog row and a **Dropped** subsection with pin, what we checked, and the numbers that lost.
3. Remove the tool from `peers.tsv`, `coverage.tsv`, and `levels.tsv`.
4. Delete adapter source, the `versions.sh` pin, `install.sh` / `invoke.sh` cases, and `tools/.local/{zebrac,qualify,installs}/NAME` plus `tools/bin/NAME`. Do not leave an "archived but still installable" copy.
5. Run `tools/report.sh --check`. Live README sections follow `peers.tsv`. Leftover JSON for a deleted tool is ignored once the name is gone from `peers.tsv`.
