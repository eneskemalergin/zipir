<!-- markdownlint-disable MD033 MD041 -->

<div align="center">
  <img src="assets/logo-readme.svg" alt="Zipir logo" width="170">
  <!-- <h1>ZIPIR</h1> -->
  <p><strong>Streaming DEFLATE-family compression for Zig, in fixed memory.</strong></p>
  <p>
    <a href="https://github.com/eneskemalergin/zipir/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/eneskemalergin/zipir/ci.yml?branch=main&amp;style=flat-square&amp;label=CI&amp;logo=githubactions" alt="CI status"></a>
    <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/version-0.2.0-2C8EBB?style=flat-square" alt="Version 0.2.0"></a>
    <a href="https://ziglang.org/download/"><img src="https://img.shields.io/badge/Zig-0.16.0-F7A41D?style=flat-square&amp;logo=zig&amp;logoColor=white" alt="Zig 0.16.0"></a>
    <a href="#a-few-honest-tradeoffs"><img src="https://img.shields.io/badge/status-development-4B9D6E?style=flat-square" alt="Status: development"></a>
    <img src="https://img.shields.io/badge/dependencies-none-2D7D46?style=flat-square" alt="No external dependencies">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4B9D6E?style=flat-square" alt="MIT License"></a>
  </p>
  <p>
    <a href="https://github.com/eneskemalergin/zipir/wiki/Home"><img src="https://img.shields.io/badge/wiki-documentation-2563EB?style=flat-square" alt="Wiki documentation"></a>
    <a href="https://github.com/eneskemalergin/zipir/wiki/API"><img src="https://img.shields.io/badge/API-reference-7C3AED?style=flat-square" alt="API reference"></a>
    <a href="bench/linux-x86-avx2/README.md"><img src="https://img.shields.io/badge/benchmarks-report-F59E0B?style=flat-square" alt="Benchmark report"></a>
  </p>
</div>

---

> [!NOTE]
> `zipir` takes its name from the Turkish word `zıpır`, meaning lively, restless, or mischievous. The ASCII spelling also hints at `zip` and keeps the name easy to use in source code and command lines. The playful name does not change the deliberately explicit API names or format terminology.

## Why zipir exists

I kept reaching for compression in my other projects. Zig's standard library already provides most commonly used algorithms and gives me a strong starting point, but my workflows keep raising the same questions: how much memory does a stream need, where does checksum work happen, and which hot paths are worth tuning? Calling C libraries is one of Zig's strengths, but it can add a static dependency and another build choice to every project that uses it. Zipir is my attempt to keep the common path in one small Zig package that my projects can share.

The library has no external dependencies, does not create threads, and does not allocate during codec operations. The goal is not to replace every compression library. The goal is to make the common bounded streaming path pleasant to use and straightforward to measure.

- **gzip, zlib, and raw DEFLATE**, compressed and decompressed, with three presets: `fast`, `even` (the default), and `dense`.
- **BGZF**, the blocked gzip of bioinformatics: blocks that end at text lines as `bgzip`'s do, `.gzi` indexes, and seeking by virtual or uncompressed offset.
- **tar** archives (ustar, pax, GNU), read and written through any of the formats above.
- A library of `std.Io` readers and writers over workspaces you own, a decoder for whole zlib and raw DEFLATE streams held in memory, and a `zipir` command for all of it.

<p align="center">
  <a href="bench/linux-x86-avx2/README.md">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="bench/linux-x86-avx2/figures/summary-dark.svg">
      <source media="(prefers-color-scheme: light)" srcset="bench/linux-x86-avx2/figures/summary-light.svg">
      <img src="bench/linux-x86-avx2/figures/summary-light.svg" alt="zipir against the fastest single-threaded peer for every format, operation, and level on Linux x86-64 with AVX2" width="100%">
    </picture>
  </a>
</p>
<p align="center"><sub>Whole-command time against the fastest single-threaded peer on one Linux x86-64 host (AMD Ryzen 9 3950X, AVX2). Left of 1 the peer is faster. For compression, a faster peer often writes larger files, so the hollow marker shows the fastest peer whose output is no larger than zipir's. Open the report for speed-ratio curves, memory, every measured value, and the method.</sub></p>

<p align="center">
  <a href="bench/linux-x86-avx2/README.md#memory">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="bench/linux-x86-avx2/figures/memory-summary-dark.svg">
      <source media="(prefers-color-scheme: light)" srcset="bench/linux-x86-avx2/figures/memory-summary-light.svg">
      <img src="bench/linux-x86-avx2/figures/memory-summary-light.svg" alt="Peak memory of zipir and every peer for each format and operation on Linux x86-64: zipir about 0.6 MiB on every path, the C peers 1.6 to 3.6 MiB" width="100%">
    </picture>
  </a>
</p>
<p align="center"><sub>Peak memory of the whole process on the same runs. zipir holds each stream in one fixed workspace, so its peak stays near 0.6 MiB on every path and every file. The Zig standard library, also a static Zig program, lands at the same place but takes two to six times as long; part of the gap to the C tools is their libc runtime, not only their codec state.</sub></p>

## A few honest tradeoffs

> [!NOTE]
> zipir supports Linux and macOS on x86-64 and ARM64, and CI tests all four. Windows is not supported. I would like to support it properly, but keeping native Windows builds reliable takes more time than I can justify, and I would rather say so than publish something I cannot support well. WSL with the Linux build may work; I have not tested it.
>
> Acceleration is x86-64 first. The CRC-32 (PCLMUL) and Adler-32 (AVX2) kernels are chosen at run time, and every speed number I publish is from Linux x86-64 with AVX2. On ARM64, CRC-32 uses the ARMv8 CRC instruction when the build targets a CPU that has it; the rest runs on the portable path. Every accelerated kernel keeps a portable fallback, so no feature depends on the CPU, only speed does.

The benchmark report predates this release: its zipir compression rows were measured at commit `5f25547` and its decompression rows at `ff8e9e8`. A matched run of the same peers on the small files at the release code showed decompression faster and gzip, zlib, and raw DEFLATE compression a few percent slower, the cost of making every compressor a `std.Io.Writer`. Compressed bytes did not change.

zipir lists, tests, and creates tar archives, but it does not extract them: writing files named by an archive needs a filesystem-safety policy, and GNU tar already has one. Zstandard, LZ4, XZ, and bzip2 are possible later formats, not promises.

## Start

Build with Zig 0.16.0 from the repository root:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/zipir compress input > input.gz
./zig-out/bin/zipir decompress input.gz > input.out
./zig-out/bin/zipir compress --format bgzf reads.fastq > reads.fastq.gz
./zig-out/bin/zipir bgzf index reads.fastq.gz
./zig-out/bin/zipir tar create notes > notes.tar.gz
```

The [getting-started guide](https://github.com/eneskemalergin/zipir/wiki/Getting-Started) walks through these and the tests. To use the library, [add zipir as a dependency](https://github.com/eneskemalergin/zipir/wiki/Library-Guide#add-zipir-as-a-dependency) from its release source package.

## Documentation

The [wiki](https://github.com/eneskemalergin/zipir/wiki/Home) holds the guides and the reference:

[Getting started](https://github.com/eneskemalergin/zipir/wiki/Getting-Started) | [Command line](https://github.com/eneskemalergin/zipir/wiki/Command-Line) | [Library guide](https://github.com/eneskemalergin/zipir/wiki/Library-Guide) | [API reference](https://github.com/eneskemalergin/zipir/wiki/API)

[Formats and limits](https://github.com/eneskemalergin/zipir/wiki/Formats-and-Limits) | [Platforms and acceleration](https://github.com/eneskemalergin/zipir/wiki/Platforms-and-Acceleration) | [Benchmarking](https://github.com/eneskemalergin/zipir/wiki/Benchmarking) | [Development](https://github.com/eneskemalergin/zipir/wiki/Development)

## License

MIT. See [LICENSE](LICENSE).

---

<p align="center"><em>
  Narrow banks hold fast -<br>
  great rivers fold into mist,<br>
  no new soil disturbed.
</em></p>
