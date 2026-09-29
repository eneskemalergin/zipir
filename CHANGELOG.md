# Changelog

Changes by version. Publication dates are added when a version is released.

## [Unreleased]

## [0.2.0]

zipir grows from a gzip and zlib library into streaming compression for the whole DEFLATE family, and its interface changes with it: every decompressor is now a `std.Io.Reader` and every compressor a `std.Io.Writer`. Built with Zig 0.16.0. The last release with the old interface is 0.1.2.

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
