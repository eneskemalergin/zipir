# API reference

Everything below is reached through `@import("zipir")`. The [library guide](Library-Guide) shows the calls in use.

## Package root

- `gzip`, `zlib`, `deflate`, `bgzf`, `tar`: the format namespaces below.
- `Format`: `enum { gzip, zlib, deflate }`.
- `Decompressor(format)`, `Compressor(format)`: the namespace's `Decompressor` or `Compressor` for a comptime `Format`.
- `Preset`: `enum { fast = 1, even = 5, dense = 9 }`. The tag values are what the command's `--level 1|5|9` spelling maps onto, not zlib levels: compare presets with another compressor by measured speed and size, not by number.
- `version`: a `std.SemanticVersion`.

## The shared shape of gzip, zlib, and deflate

Each of `zipir.gzip`, `zipir.zlib`, and `zipir.deflate` declares:

- `Decompressor`: `init(self, input: *std.Io.Reader, options: DecompressOptions) void`; fields `reader: std.Io.Reader` (the decoded bytes) and `err: ?DecompressError` (the reason for a `ReadFailed`).
- `DecompressOptions`: `max_output_bytes: u64 = maxInt(u64)`, `trailing_data: enum { reject, leave } = .reject`; gzip adds `max_header_bytes: u64 = 1 << 20`.
- `DecompressError`: the errors below, plus `InputBufferTooSmall` (`trailing_data = .leave` with an input reader whose buffer is under 16 bytes, 28 for BGZF) and `PeekTooLarge` (a peek larger than the decoded-byte buffer can hold).
- `Compressor`: `init(self, output: *std.Io.Writer, options: CompressOptions) CompressError!void`; field `writer: std.Io.Writer`; `finish(self) CompressError!u64` returns the number of plain bytes.
- `CompressOptions`: `preset: Preset = .even`.
- `CompressError`: `std.Io.Writer.Error`.

Every decoder can fail with `Truncated`, `BadHuffman`, `BadSymbol`, `BadDistance`, `BadStored`, `BadBlock`, `OutputLimitExceeded`, or the input's `ReadFailed`, and with `TrailingData` under `.reject`. The formats add:

- gzip: `BadHeader`, `UnsupportedMethod`, `ReservedFlag`, `HeaderCrcMismatch`, `HeaderTooLong`, `IsizeMismatch`, `CrcMismatch`.
- zlib: `BadHeader`, `UnsupportedMethod`, `WindowTooLarge`, `DictionaryUnsupported`, `BadAdler`.
- deflate: nothing more; raw DEFLATE has no header or check.

## Slice decoding: zlib and deflate

`zipir.zlib` and `zipir.deflate` also declare `SliceDecoder`, for a complete stream held in memory:

- `decode(self, input: []const u8, output: []u8) DecompressError!usize` decodes the stream in `input` into `output` and returns the decoded length. `OutputLimitExceeded` means the stream needs more room than `output`; bytes after the stream are `TrailingData`. `output` past the returned length, and all of it after an error, is unspecified. `input` and `output` must not overlap.
- The workspace holds only tables (7,704 bytes), keeps nothing between calls, and may be moved or copied between them. An output under 16 KiB is decoded into a stack buffer and copied, so a call uses up to about 16.3 KiB of stack.

## bgzf

- `Decompressor`, `DecompressOptions`, `DecompressError`: as above. `DecompressOptions` has `max_output_bytes`, `trailing_data`, and `require_eof_marker: bool = false`. The decompressor also has `seek(self, source: *std.Io.File.Reader, offset: VirtualOffset)` and `seekUncompressed(self, source: *std.Io.File.Reader, entries: []const IndexEntry, uoffset: u64)`, and its `framing.blocks` and `framing.eof_marker` tell what was read.
- `DecompressError` adds to gzip's: `NotBgzf`, `BadBlockSize`, `BlockSizeMismatch`, `BlockTooLarge`, `MissingEofMarker`, `BadVirtualOffset`, `BadIndex`.
- `Compressor`: `init(self, output, options) std.Io.Writer.Error!void`, `writer`, `err: ?CompressError`, `finish(self) std.Io.Writer.Error!Totals`.
- `CompressOptions`: `preset: Preset = .even`, `split: Split = .fill`, `index: ?*IndexBuilder = null`. `CompressError`: `error{ WriteFailed, IndexFull }`. `Totals`: `uncompressed: u64`, `compressed: u64`.
- `Split`: `enum { fill, lines }`. `.lines` gives the block boundaries of `bgzip` 1.24 on text.
- `VirtualOffset`: `packed struct(u64) { uoffset: u16, coffset: u48 }`.
- `scan(reader, options: ScanOptions) Scanner`; `Scanner.next() DecompressError!?Block`; `Block`: `coffset: u64`, `size: u32`, `data_size: u32`; `ScanOptions`: `trailing_data`, `require_eof_marker`. The scanner reads block headers and trailers without decoding.
- `BlockDecoder`: `decodeBlock(self, block: []const u8, out: *[MAX_BLOCK]u8) DecompressError!usize` decodes one whole block and writes `out` only once the block's checks pass.
- `BlockSplitter`: `init(split)`, `next(self, available: []const u8, at_end: bool) ?usize` returns the length of the next block, never 0; `LOOKAHEAD`.
- `BlockEncoder`: `compressBlock(self, input: []const u8, out: *[MAX_BLOCK]u8, preset) usize` asserts at most `BLOCK_INPUT` bytes of input.
- `IndexEntry`: `coffset: u64`, `uoffset: u64`. `IndexBuilder`: `init(entries: []IndexEntry)`, `add(self, coffset, data_size) error{IndexFull}!void`, `slice(self)`. `writeIndex(writer, entries)`. `IndexReader`: `init(reader, file_size) DecompressError!IndexReader`, `next(self) DecompressError!?IndexEntry`.
- Constants: `MAX_BLOCK = 65536`, `BLOCK_INPUT = 65280`, `EOF_MARKER` (the 28-byte empty block).

## tar

- `Entry`: `name`, `link_name`, `kind: Kind`, `size: u64`, `mode: u32`, `mtime: i64`. `Kind`: `file`, `directory`, `symlink`, `hardlink`, `char_device`, `block_device`, `fifo`, `other`.
- `Reader(Visitor)`: `init(visitor: *Visitor, names: Names)`; field `writer: std.Io.Writer`; `finish(self) ReadError!Summary`. `Names`: the caller's `name` and `link` buffers. `Summary`: `entries: u64`, `end_marker: bool`. `Action`: `read`, `skip`.
- `Writer(Source)`: `init(source: *Source, buffer: []u8, options: WriterOptions)`; field `reader: std.Io.Reader`; `finish(self) CreateError!u64` returns the number of entries. `WriterOptions`: `mtime: i64 = 0`.
- `isHeader(block: *const [512]u8) bool`: a block that is not all zeros and has a valid checksum.
- `MAX_NAME = 4095`.
- `Error`: `BadHeaderChecksum`, `BadNumber`, `BadPax`, `NameTooLong`, `UnsupportedEntry`, `Truncated`. `WriteError`: `NameTooLong`, `UnsupportedEntry`, `SourceTooShort`.
