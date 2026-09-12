# z-flate

Native Zig streaming compression APIs, starting with gzip decompression. Requires Zig 0.16.0. The library has no external dependencies and does not create threads or allocate during decompression.

Gzip decompression is implemented. Compression and other formats are not implemented yet.

## Library

`Decompressor(.gzip)` selects the gzip decoder at compile time. The caller owns reusable workspace and `std.Io.Reader` / `std.Io.Writer` buffers:

```zig
const std = @import("std");
const z_flate = @import("z_flate");

pub fn decompressFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: std.Io.File,
    output: std.Io.File,
) !u64 {
    const decoder = try allocator.create(z_flate.Decompressor(.gzip));
    defer allocator.destroy(decoder);
    var input_buffer: [32768]u8 = undefined;
    var output_buffer: [4096]u8 = undefined;
    var reader = input.readerStreaming(io, &input_buffer);
    var writer = output.writerStreaming(io, &output_buffer);
    const decoded = try decoder.decompress(&reader.interface, &writer.interface, .{});
    try writer.interface.flush();
    return decoded;
}
```

Use `gzip.Options.max_output_bytes` to cap decoded output, for example `.{ .max_output_bytes = 64 * 1024 * 1024 }`. Exceeding the limit returns `OutputLimitExceeded`. The result is a `u64` byte count across all members. Workspace can be reused without initialization after success or failure; simultaneous calls need separate workspaces.

The reader must have at least 16 bytes of buffer capacity; underlying reads may return one byte at a time. Fixed readers and writers work too. Input, output, and workspace must not overlap. The decoder borrows both interfaces and never closes them. The caller flushes the writer after success. Read/write errors abort the operation; externally resuming a failed call is not supported.

Stored, fixed-Huffman, and dynamic-Huffman blocks, optional gzip headers, header CRC, CRC32, ISIZE, and concatenated members are supported. Format references: [DEFLATE](https://www.rfc-editor.org/rfc/rfc1951) and [gzip](https://www.rfc-editor.org/rfc/rfc1952). History availability resets for each member. Malformed or truncated input returns a `gzip.Error`. Empty input is not a valid gzip stream; an empty gzip member is valid. Output is provisional until the call and writer flush succeed, so streaming failures may leave partial output.

Trailing data is rejected by default, including zero padding. Set `.trailing_data = .leave` to stop before a non-gzip suffix and retain it in the reader. A suffix beginning with gzip magic is parsed as another member and must be valid. Header names/comments are validated or skipped incrementally; they are not retained or exposed.

## Command line

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/z_flate decompress input.gz > output
cat input.gz | ./zig-out/bin/z_flate decompress > output
./zig-out/bin/z_flate test input.gz
./zig-out/bin/z_flate decompress --max-output-bytes 67108864 input.gz > output
```

`decompress` writes decoded bytes to stdout. `test` verifies and discards decoded output. Omit the input path or use `-` for stdin. Use `--` before a path starting with `-`. Input files are preserved. Reported errors print to stderr and exit with status 1; invalid arguments exit with status 2. A closed output pipe retains the default Unix SIGPIPE termination. No arguments or `--version` prints the version; `--help` prints usage.

## Memory and CPU targets

The gzip workspace is 200,704 bytes. With the example's 32 KiB input and 4 KiB output buffers, explicit storage is 237,568 bytes (232 KiB), plus bounded stack, shared tables, and runtime/code residency. Fixed Huffman blocks use 10 KiB of shared read-only tables generated at compile time. These are fixed reservations, not total process peak RSS. No complete input/output allocation or application-level memory mapping occurs inside the decoder.

CRC uses a portable implementation with compile-time guarded x86 PCLMUL and AArch64 CRC instructions. CPU selection follows Zig's target options: a native build targets the build machine. Use `-Dcpu=baseline` when distributing to other CPUs, or select a known minimum CPU explicitly. Linux and macOS on x86_64 and AArch64 are the intended targets. Cross-compilation is separate from runtime performance qualification.

## Verification

```sh
zig fmt --check src tests build.zig
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build test -Dcpu=baseline --summary all
```

The self-contained tests cover public streaming contracts, corruption, chunk boundaries, output limits, CLI behavior, and scalar/native kernel agreement. Test fixtures and verification outputs may occupy more memory than a standalone decoder. Performance and RSS must be measured in separate processes with fixed input/output buffers, without those retained oracle files.