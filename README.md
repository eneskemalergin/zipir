<!-- markdownlint-disable MD033 MD041 -->

<div align="center">
  <img src="assets/logo-readme.svg" alt="Zipir logo" width="170">
  <!-- <h1>ZIPIR</h1> -->
  <p><strong>Native Zig gzip compression and bounded streaming gzip/zlib decompression.</strong></p>
  <p>
    <img src="https://img.shields.io/badge/version-0.1.2-2C8EBB?style=flat-square" alt="Version 0.1.2">
    <a href="https://ziglang.org/download/"><img src="https://img.shields.io/badge/Zig-0.16.0-F7A41D?style=flat-square&amp;logo=zig&amp;logoColor=white" alt="Zig 0.16.0"></a>
    <img src="https://img.shields.io/badge/status-development-4B9D6E?style=flat-square" alt="Status: development">
    <img src="https://img.shields.io/badge/dependencies-none-2D7D46?style=flat-square" alt="No external dependencies">
  </p>
</div>

<!-- Future status links. Replace REPOSITORY with the actual GitHub owner/repository before enabling these links.
<p align="center">
  <a href="https://github.com/REPOSITORY/actions/workflows/ci.yml"><img src="https://github.com/REPOSITORY/actions/workflows/ci.yml/badge.svg?style=flat-square" alt="CI status"></a>
  <a href="https://github.com/REPOSITORY/releases/latest"><img src="https://img.shields.io/github/v/release/REPOSITORY?style=flat-square" alt="Latest release"></a>
</p>
<p align="center">
  <a href="https://github.com/REPOSITORY/wiki"><img height="18" src="https://img.shields.io/badge/wiki-documentation-2563EB?style=flat-square" alt="Wiki"></a>
  <a href="bench/"><img height="18" src="https://img.shields.io/badge/benchmarks-reports-F59E0B?style=flat-square" alt="Benchmark reports"></a>
  <a href="CHANGELOG.md"><img height="18" src="https://img.shields.io/badge/changelog-history-7C3AED?style=flat-square" alt="Changelog"></a>
  <a href="docs/"><img height="18" src="https://img.shields.io/badge/docs-reference-0891B2?style=flat-square" alt="Documentation"></a>
  <a href="LICENSE"><img height="18" src="https://img.shields.io/badge/license-MIT-4B9D6E?style=flat-square" alt="MIT License"></a>
</p>
-->

---

> [!NOTE]
> `zipir` takes its name from the Turkish word `zıpır`, meaning lively, restless, or mischievous. The ASCII spelling also hints at `zip` and keeps the name easy to use in source code and command lines. The playful name does not change the deliberately explicit API names or format terminology.

## Why zipir exists

I kept reaching for compression in my other projects. Zig's standard library already provides most commonly used algorithms and gives me a strong starting point, but my workflows keep raising the same questions: how much memory does a stream need, where does checksum work happen, and which hot paths are worth tuning? Calling C libraries is one of Zig's strengths, but it can add a static dependency and another build choice to every project that uses it. Zipir is my attempt to keep the common path in one small Zig package that my projects can share.

The library has no external dependencies, does not create threads, and does not allocate during codec operations. The goal is not to replace every compression library. The goal is to make the common bounded streaming path pleasant to use and straightforward to measure.

## Supported codecs

| Format    | Compress | Decompress | Note                   |
| --------- | -------- | ---------- | ---------------------- |
| Gzip      | Yes      | Yes        | n/a                    |
| zlib      | No       | Yes        | only decoder (for now) |
| ZIP       | No       | No         | Possible future format |
| Zstandard | No       | No         | Possible future format |
| LZ4       | No       | No         | Possible future format |
| XZ        | No       | No         | Possible future format |
| bzip2     | No       | No         | Possible future format |

The future rows are possibilities, not a delivery order or a promise to support every format. Zipir will stay focused on formats that fit its Zig-first, bounded-streaming goals.

- Gzip compression with fast, balanced, and dense presets.
- Streaming gzip decompression with header checks, CRC32, ISIZE, and concatenated members.
- Streaming zlib decompression with RFC 1950 header checks, Adler-32, trailing-data policy, and an output limit.
- Caller-owned `std.Io.Reader` and `std.Io.Writer` interfaces with reusable bounded workspaces.

Raw DEFLATE and zlib compression are not implemented yet.

> [!NOTE]
> `zipir` will slowly build its accelerators in the form of hand-rolled SIMD tested on specific architecture. Currently I cannot promise a full and comprehensive support. I am building things that specifically suits my needs and will target my computer and my os first. I always keep in mind portability, and compatibility but for the work for actually pushing performance they are extremely time consuming to build for across a wide range of cpu, os archtectures. So I wanted to mention I will always keep fallbacks so the there won't be missing functionality, but speed and memory optimizations might be missing. My first target is `linux, x86-64, axv2`. I have test environments for various others but they will have to come later.

## Quick start

Requires Zig 0.16.0.

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/zipir compress --level 5 input > output.gz
./zig-out/bin/zipir decompress input.gz > output
cat input.gz | ./zig-out/bin/zipir test > /dev/null
```

The default build targets the host CPU. `-Dcpu=baseline` builds a portable binary that still picks the PCLMUL CRC-32 and AVX2 Adler-32 kernels at run time when the CPU has them.

## Library

The API borrows the reader and writer, keeps codec storage with the caller, and returns the decoded or consumed byte count.

```zig
const zipir = @import("zipir");

const decoder = try allocator.create(zipir.Decompressor(.zlib));
defer allocator.destroy(decoder);

const decoded = try decoder.decompress(&reader, &writer, .{});
try writer.flush();
```

Use `zipir.gzip.Options.max_output_bytes` or `zipir.zlib.Options.max_output_bytes` when decoded output needs a caller-defined bound. The full format behavior and error contracts will move into the project wiki as they settle.

## Benchmarks

> [!WARNING]
> Public-facing benchmark reports will live in `bench/` once that directory is ready. It is not ready yet, so the comparisons described here are local development measurements rather than published benchmark results.

The comparison adapters, corpus definitions, qualification checks, and report generation live in [`tools/`](tools/). The README will keep only the small conclusions that remain useful after the benchmark work changes.

## Roadmap

- Keep tuning gzip and zlib against real corpus shapes without losing bounded streaming behavior.
- Publish compact speed and peak-RSS summaries once the comparison layout settles.
- Move the complete API, format notes, and benchmark methods into the wiki.

## Development

```sh
zig fmt --check src tests build.zig
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Dkernel-backend=portable --summary all
zig build test -Dcpu=baseline --summary all
```

---

<p align="center"><em>
  Narrow banks hold fast -<br>
  great rivers fold into mist,<br>
  no new soil disturbed.
</em></p>
