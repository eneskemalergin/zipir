# Library guide

zipir's module is named `zipir`. Every decompressor is a `std.Io.Reader` over any input reader, and every compressor a `std.Io.Writer` into any output writer. You own each workspace, set it up in place with `init`, and reuse it; zipir allocates nothing and starts no threads.

## Add zipir as a dependency

Fetch the release's source package into your project. It holds only the build files, the source, the tests, and the license:

```sh
zig fetch --save=zipir https://github.com/eneskemalergin/zipir/releases/download/v0.2.0/zipir-0.2.0-source.tar.gz
```

Zig records the package and its hash in your `build.zig.zon`. Fetch the archive, never a live checkout or `.`: a fetch copies what it is given into Zig's package cache.

In your `build.zig`, with its existing `b`, `target`, `optimize`, and `exe`:

```zig
const zipir = b.dependency("zipir", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zipir", zipir.module("zipir"));
```

Your code can now `@import("zipir")`. Importing the module builds neither zipir's command nor its tests. To force every CPU kernel onto its portable path, pass `.@"kernel-backend" = .portable` beside `.target`; [Platforms and acceleration](Platforms-and-Acceleration) explains when that helps.

To build against a local checkout without editing `build.zig.zon`, run `zig build --fork=../zipir`: wherever your dependency tree names zipir (matched by package name and fingerprint, whatever the version), Zig uses the checkout, and it fetches nothing for it.

## Workspaces

A workspace is large, so allocate it once and reuse it:

- about 172 KB for any decompressor;
- 429 KB for a gzip, zlib, or raw DEFLATE compressor;
- 658 KB for a BGZF compressor, which stages two blocks of input to cut blocks as `bgzip` does.

`init` sets a workspace up in place and resets it, also after an error. The reader or writer lives inside it, so the workspace must not move while it is in use.

## Read a stream

```zig
const zipir = @import("zipir");

// Decoded bytes, borrowed a chunk at a time.
const decoder = try allocator.create(zipir.gzip.Decompressor);
defer allocator.destroy(decoder);
decoder.init(&file_reader.interface, .{});
while (decoder.reader.peekGreedy(1)) |chunk| {
    use(chunk);
    decoder.reader.toss(chunk.len);
} else |err| switch (err) {
    error.EndOfStream => {},
    error.ReadFailed => return decoder.err.?, // CrcMismatch, Truncated, ..., or the input's ReadFailed
}
```

A failed read is always `error.ReadFailed`; `decoder.err` then holds the reason, such as `CrcMismatch`, `Truncated`, `TrailingData`, or the input reader's own `ReadFailed`. Bytes read before that error came before the failed check, so treat them as unverified until the end of the stream ([when decoded bytes become readable](Formats-and-Limits#when-decoded-bytes-become-readable)). To decode a whole stream into a writer, use one pump: `decoder.reader.streamRemaining(writer)`. The input reader's buffer can be any size, except that `trailing_data = .leave` needs 16 bytes (28 for BGZF) to leave the following bytes in it.

Options bound what untrusted input can cost:

- `max_output_bytes` fails the stream with `OutputLimitExceeded` once decoded output would pass it.
- `trailing_data = .leave` stops at the end of the stream and leaves any following bytes in the input reader; the default, `.reject`, fails with `TrailingData`.
- gzip's `max_header_bytes` (1 MiB by default) bounds each member's optional header fields.

## Write a stream

```zig
// Plain bytes in, one gzip member out; the output does not depend on the write sizes.
const encoder = try allocator.create(zipir.gzip.Compressor);
defer allocator.destroy(encoder);
try encoder.init(&out.interface, .{ .preset = .even }); // .fast, .even, or .dense
try encoder.writer.writeAll(record);
_ = try encoder.finish();
try out.interface.flush();
```

`finish` writes the final block and the trailer and returns the number of plain bytes; the writer then fails until the next `init`. `encoder.writer.flush()` is a full flush: everything written so far can be decoded, and the next bytes start a new history. Neither flushes your output writer; flush it yourself. A contiguous request of up to 32 KiB (`writableSlice`, `writeInt`, `print`) always fits.

## zlib and raw DEFLATE

Every format namespace (`zipir.gzip`, `zipir.zlib`, `zipir.deflate`, `zipir.bgzf`) has the same `Decompressor`, `DecompressOptions`, `DecompressError`, `Compressor`, `CompressOptions`, and `CompressError`, so zlib and raw DEFLATE read and write exactly as above. `zipir.Decompressor(.zlib)` and `zipir.Compressor(.zlib)` name the same types when the format is a comptime value.

## BGZF, indexes, and seeking

The BGZF compressor can fill a `.gzi` index as it writes, and the decompressor seeks by virtual offset (`seek`) or by uncompressed offset through the index (`seekUncompressed`). Both seeks need the positional `std.Io.File.Reader` the decompressor was given.

```zig
var entries: [4096]zipir.bgzf.IndexEntry = undefined;
var index: zipir.bgzf.IndexBuilder = .init(&entries);
const writer = try allocator.create(zipir.bgzf.Compressor);
defer allocator.destroy(writer);
try writer.init(&out.interface, .{ .preset = .fast, .split = .lines, .index = &index });
try writer.writer.writeAll(reads);
_ = try writer.finish();
try out.interface.flush();
try zipir.bgzf.writeIndex(&gzi.interface, index.slice());

const reader = try allocator.create(zipir.bgzf.Decompressor);
defer allocator.destroy(reader);
reader.init(&file_reader.interface, .{});
try reader.seekUncompressed(&file_reader, index.slice(), 1_000_000);
const line = try reader.reader.takeDelimiterExclusive('\n');
```

The index storage is yours; when it is full, the compressor's writer fails and `writer.err` is `IndexFull`. `.split = .lines` gives exactly the block boundaries of `bgzip` 1.24 on text; `.fill` makes full blocks. `zipir.bgzf.IndexReader` reads a `.gzi` file back and rejects entries that do not increase strictly.

For work on single blocks, `zipir.bgzf.scan` walks block headers without decoding, `BlockDecoder` decodes one whole block, and `BlockSplitter` with `BlockEncoder` write blocks one at a time.

## tar through any format

`zipir.tar.Writer(Source)` is a reader of the archive it builds, so a compressor pulls from it, and `zipir.tar.Reader(Visitor)` is a writer that calls the visitor per entry, so a decompressor pushes into it. A `.tar.gz` round trip:

```zig
// Source declares `next(*Source) !?zipir.tar.Entry` and `data(*Source) *std.Io.Reader`.
var tar_buffer: [4096]u8 = undefined;
var archive: zipir.tar.Writer(Source) = .init(&source, &tar_buffer, .{});
try gz.init(&out.interface, .{});
_ = try archive.reader.streamRemaining(&gz.writer);
_ = try gz.finish();
try out.interface.flush();

// Visitor declares `entry(*Visitor, Entry) !Action`, `data(*Visitor, []const u8) !void`, and `entryEnd(*Visitor) !void`.
var name: [zipir.tar.MAX_NAME + 1]u8 = undefined;
var link: [zipir.tar.MAX_NAME + 1]u8 = undefined;
var tar_reader: zipir.tar.Reader(Visitor) = .init(&visitor, .{ .name = &name, .link = &link });
gunzip.init(&in.interface, .{});
_ = try gunzip.reader.streamRemaining(&tar_reader.writer);
const summary = try tar_reader.finish(); // entries, and whether the end blocks were there
```

`Source.data` must hand out exactly `Entry.size` bytes; fewer is `SourceTooShort`. The visitor's `entry` returns `.read` to receive the entry's bytes through `data`, or `.skip`. Entry names borrow the `Names` buffers until the next entry. After a failed write or read, `finish` returns the cause.

The [API reference](API) lists every name, option, and error.
