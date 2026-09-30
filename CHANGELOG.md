# Changelog

Changes by version, newest first. Before 1.0, a minor version may change the API; every such change is listed here with what replaces it.

## [Unreleased]

## [0.2.1] - 2026-09-30

0.2.1 makes zipir lighter for the projects that decode many small streams held in memory: a zlib or raw DEFLATE stream can now be decoded straight into your own buffer, and every decompressor's workspace is smaller. It also removes the minimum input reader buffer size (16 bytes, 28 for BGZF) that two dependents had to work around.

### Added

- `zlib.SliceDecoder` and `deflate.SliceDecoder` decode one complete stream held in memory straight into your buffer, with a workspace of tables only (7,704 bytes) and at most about 16.3 KiB of stack. Reading ten mzML files through zmz, they decode as fast as the reader or up to 2% faster, and the process peaks about 250 KiB lower than with the reader.

### Changed

- Every decompressor's workspace is 25,064 bytes smaller (about 172 KB): the decoding tables are sized to the exact worst case, computed with zlib's `enough`. A process's peak memory does not change, because the unused entries were never touched.
- `bgzf.BlockDecoder` is 73,240 bytes instead of 196,608. It still writes `out` only once the block's checks pass.
- At the exact output limit, a damaged length and distance pair reports its damage, such as `BadDistance`, instead of `OutputLimitExceeded`, so the reader and the slice decoder report the same error for the same stream.

### Fixed

- Decompressors and `bgzf.scan` accept an input reader whose buffer has any size; a buffer under 16 bytes (28 for `bgzf.Decompressor`) used to fail with `InputBufferTooSmall`. The error remains only with `trailing_data = .leave`, where the bytes after the stream must stay in the caller's reader.

## [0.2.0] - 2026-09-28

The first public release.

I started zipir because I kept reaching for compression in my other projects and wanted one small Zig package they could share, without a C library in every build. 0.1.2 was that package for gzip, and it stayed private. 0.2.0 is the first version I am comfortable putting in front of other people, and the one my own projects will depend on.

What it is now:

- **The whole DEFLATE family.** gzip, zlib, and raw DEFLATE in both directions, and BGZF, the blocked gzip of bioinformatics, with `.gzi` indexes and seeking. tar archives are read and written through any of them.
- **Plain `std.Io` streams.** Every decompressor is a `std.Io.Reader` and every compressor a `std.Io.Writer`, over a workspace you own. No allocation during codec work, no threads, no dependencies.
- **Small and steady in memory.** In the [benchmark report](https://github.com/eneskemalergin/zipir/blob/v0.2.0/bench/linux-x86-avx2/README.md), zipir's whole process peaks at 0.55 to 0.62 MiB on every path, on small and medium files alike.
- **Ready to depend on.** A source package for `zig fetch` and binaries for Linux and macOS on x86-64 and ARM64 come with every release, tested on all four systems, with a [wiki](https://github.com/eneskemalergin/zipir/wiki) for the command line and the library.

Coming from 0.1.2, the API changed: decoding and encoding moved to readers and writers, and the `level` option with `balanced` became the `preset` option with `even`. The sections below list every change and its replacement.

A few things this release does not do: Windows is not supported, the accelerated kernels are x86-64 first, and tar archives can be listed, tested, and created but not extracted.

### Added

- zlib compression, with the header `78 01`, `78 5E`, or `78 DA` by preset.
- Raw DEFLATE compression and decompression (`zipir.deflate`).
- BGZF (`zipir.bgzf`): a decompressor that makes a block readable only after its size fields, CRC-32, and ISIZE pass, caps every block at 64 KiB, and seeks by virtual offset (`seek`) or by uncompressed offset through `.gzi` entries (`seekUncompressed`); a compressor that cuts blocks at text lines exactly as `bgzip` 1.24 does, or at full size; `.gzi` indexes written while compressing or from a scan (`IndexBuilder`, `writeIndex`, `IndexReader`); and block-level `scan`, `BlockDecoder`, `BlockSplitter`, and `BlockEncoder`.
- tar (`zipir.tar`): `Reader(Visitor)`, a writer that calls a visitor per entry, and `Writer(Source)`, a reader of the archive it builds, for ustar, pax, and GNU archives. They join any format through `std.Io`, so a `.tar.gz` is one pump each way.
- The command: `--format gzip|zlib|deflate|bgzf` for `compress`, and `--format auto`, the new default, for `decompress` and `test`, which detects gzip, BGZF, and zlib; `bgzf index`; `tar list`, `tar test`, and `tar create`; and `--binary` for full-size BGZF blocks.
- The PCLMUL CRC-32 and AVX2 Adler-32 kernels are chosen at run time, so a `-Dcpu=baseline` build keeps them; ARM64 builds use the ARMv8 CRC instruction when the target CPU has it.
- gzip's `max_header_bytes` option (1 MiB by default, `HeaderTooLong`) bounds the optional header fields of each member.
- A source package for dependents (`zig build source`, published with each release), release binaries for Linux and macOS on x86-64 and ARM64, CI on all four, the wiki, and the MIT license.

### Changed

- Decompressors are `std.Io.Reader`s. `Decompressor.decompress(reader, writer, options)` is replaced by `init(input, options)` and the `reader` field; a failed read is `ReadFailed`, with the reason in `err`. `Error` is renamed `DecompressError` and `Options` `DecompressOptions`; `WriteFailed` leaves the decode errors, since output goes to your own writer.
- Compressors are `std.Io.Writer`s. `Compressor.compress(reader, writer, options)` is replaced by `init(output, options)`, the `writer` field, and `finish()`. The output does not depend on the write sizes, and `writer.flush()` is a full flush.
- The presets are `fast`, `even`, and `dense` (`zipir.Preset`, option field `preset`), in place of `level` with `balanced`. The command takes `--fast`, `--even` (the default), and `--dense`; `--level 1|5|9` still works.
- Compressed bytes differ from 0.1.2: every preset searches and codes differently. Output still decodes to exactly the input, and within one version the same input and preset give the same bytes on every CPU and build.
- `-Dkernel-backend=dispatch|portable` replaces `-Dadler-backend=dispatch|scalar` and covers every kernel.
- The switch to the writer interface costs gzip, zlib, and raw DEFLATE compression a few percent of speed, measured against the commit just before it, and 28 KiB of memory for the room that lets any contiguous write of up to 32 KiB fit.

### Fixed

- The command no longer reads out of bounds when started with an empty argument vector (possible through `execve`); it prints the version instead.

## [0.1.2] - 2026-09-21

The first version under the name zipir (it began as z-flate). It was tagged but never published as a release.

### Added

- gzip compression with three levels, `fast`, `balanced` (the default), and `dense`, and `--level 1|5|9` on the command line.
- Streaming gzip decompression with header checks, CRC-32, ISIZE, concatenated members, and an output limit.
- Streaming zlib decompression with RFC 1950 header checks, Adler-32 (an AVX2 kernel when the CPU has it), a trailing-data policy, and an output limit.
- The `zipir compress`, `decompress`, and `test` commands for gzip.

[Unreleased]: https://github.com/eneskemalergin/zipir/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/eneskemalergin/zipir/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/eneskemalergin/zipir/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/eneskemalergin/zipir/tree/v0.1.2
