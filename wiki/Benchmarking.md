# Benchmarking

The published report is [bench/linux-x86-avx2](https://github.com/eneskemalergin/zipir/blob/main/bench/linux-x86-avx2/README.md). It compares zipir with the fastest single-threaded tools on one Linux x86-64 host (AMD Ryzen 9 3950X, AVX2), on sequencing, mass spectrometry, and general corpus files, for every format zipir writes and reads.

## What it measures

- **Whole commands.** Each sample is a complete process: start-up, reading the input, and writing the output. This is what a user running the command sees, not a library inner loop.
- **Matched rounds.** Every tool for one file and operation runs in the same interleaved rounds, so load on the machine slows all of them alike. Times are medians of 25 rounds.
- **Correctness before timing.** Every tool is checked against an independent decoder before it is timed, and every compressed output is decoded again during the run.
- **Speed and size together.** A faster compressor often writes larger files, so every compression result shows both.
- **Memory.** Peak resident memory of the whole process.

## Peers

zlib-ng, ISA-L igzip, the Zig standard library, and htslib `bgzip` built with libdeflate and with zlib-ng, each single-threaded, at the levels the report lists. The preset frontier figures add every level of libdeflate's own command.

## This release

The report predates 0.2.0's code: its zipir compression rows were measured at commit `5f25547` and its decompression rows at `ff8e9e8`. A matched run of the same peers on the small files at the release code showed decompression faster and gzip, zlib, and raw DEFLATE compression a few percent slower, the cost of making every compressor a `std.Io.Writer`. Compressed bytes did not change.

## Run it yourself

The comparison tools live in [`tools/`](https://github.com/eneskemalergin/zipir/tree/main/tools): installing the peers, fetching the corpus, checking every peer's output, and timing with [Zebrac](https://github.com/eneskemalergin/zebrac) 0.6.2. Their README gives the commands and how long each run takes. Timing needs Linux x86-64.
