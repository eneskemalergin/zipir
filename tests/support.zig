//! Bounded input and output adapters and shared checks for the contract suites.

const std = @import("std");

pub const Source = struct {
    reader: std.Io.Reader,
    bytes: []const u8,
    position: usize = 0,
    chunk: usize,
    fail_at: usize = std.math.maxInt(usize),
    split_at: usize = std.math.maxInt(usize),

    pub fn init(bytes: []const u8, buffer: []u8, chunk: usize) Source {
        return .{ .reader = .{ .vtable = &.{ .stream = read }, .buffer = buffer, .seek = 0, .end = 0 }, .bytes = bytes, .chunk = chunk };
    }

    fn read(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Source = @alignCast(@fieldParentPtr("reader", reader));
        if (self.position >= self.fail_at) return error.ReadFailed;
        if (self.position == self.bytes.len) return error.EndOfStream;
        const split_left = if (self.position < self.split_at) self.split_at - self.position else std.math.maxInt(usize);
        const n = limit.minInt(@min(self.chunk, self.bytes.len - self.position, self.fail_at - self.position, split_left));
        const written = try writer.write(self.bytes[self.position..][0..n]);
        self.position += written;
        return written;
    }
};

pub const Sink = struct {
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    output: []u8,
    sink: ?[]u8 = null,
    oracle: ?*std.Io.Reader = null,
    count: usize = 0,
    fail_at: usize = std.math.maxInt(usize),
    mismatch: bool = false,
    max_drain: usize = std.math.maxInt(usize),

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("writer", writer));
        const start = self.count;
        for (data, 0..) |bytes, i| {
            const repeats = if (i + 1 == data.len) splat else 1;
            for (0..repeats) |_| {
                var offset: usize = 0;
                while (offset < bytes.len) {
                    if (self.count - start == self.max_drain) return self.count - start;
                    const n = @min(bytes.len - offset, self.output.len, self.max_drain - (self.count - start));
                    if (n == 0 or self.count > self.fail_at or n > self.fail_at - self.count) return error.WriteFailed;
                    @memcpy(self.output[0..n], bytes[offset..][0..n]);
                    std.mem.doNotOptimizeAway(self.output.ptr);
                    if (self.sink) |dest| {
                        if (self.count > dest.len or n > dest.len - self.count) return error.WriteFailed;
                        @memcpy(dest[self.count..][0..n], self.output[0..n]);
                    }
                    if (self.oracle) |oracle| {
                        const expected = oracle.take(n) catch {
                            self.mismatch = true;
                            return error.WriteFailed;
                        };
                        if (!std.mem.eql(u8, expected, self.output[0..n])) {
                            self.mismatch = true;
                            return error.WriteFailed;
                        }
                    }
                    self.count += n;
                    offset += n;
                }
            }
        }
        return self.count - start;
    }
};

/// A whole stream through a decompressor's reader, as the removed `decompress(reader, writer, options)` did:
/// the decode error itself rather than `ReadFailed`, and the decoded length.
pub fn decompress(decoder: anytype, reader: *std.Io.Reader, writer: *std.Io.Writer, options: std.meta.Child(@TypeOf(decoder)).Options) !u64 {
    decoder.init(reader, options);
    return decoder.reader.streamRemaining(writer) catch |err| switch (err) {
        error.ReadFailed => decoder.err.?,
        error.WriteFailed => error.WriteFailed,
    };
}

pub fn encodeRoundtrip(
    comptime Codec: type,
    encoder: *Codec.Compressor,
    container: std.compress.flate.Container,
    plain: []const u8,
    options: Codec.CompressOptions,
    chunk: usize,
    capacity: usize,
    encoded: []u8,
) ![]const u8 {
    return encodeRoundtripOut(Codec, encoder, container, plain, options, chunk, capacity, 13, 7, encoded);
}

/// As `encodeRoundtrip`, with a writer buffer of `out_capacity` bytes (at most 64) that drains at most
/// `max_drain` bytes per call.
pub fn encodeRoundtripOut(
    comptime Codec: type,
    encoder: *Codec.Compressor,
    container: std.compress.flate.Container,
    plain: []const u8,
    options: Codec.CompressOptions,
    chunk: usize,
    capacity: usize,
    out_capacity: usize,
    max_drain: usize,
    encoded: []u8,
) ![]const u8 {
    var in_buffer: [17]u8 = undefined;
    var source = Source.init(plain, in_buffer[0..capacity], chunk);
    var out_buffer: [64]u8 = undefined;
    var output = Sink{ .output = out_buffer[0..out_capacity], .sink = encoded, .max_drain = max_drain };
    try std.testing.expectEqual(@as(u64, plain.len), try encoder.compress(&source.reader, &output.writer, options));
    const stream = encoded[0..output.count];
    var compressed = std.Io.Reader.fixed(stream);
    var oracle = std.Io.Reader.fixed(plain);
    var decoded_buffer: [1031]u8 = undefined;
    var sink = Sink{ .output = &decoded_buffer, .oracle = &oracle };
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decoder: std.compress.flate.Decompress = .init(&compressed, container, &window);
    try std.testing.expectEqual(@as(u64, plain.len), try decoder.reader.streamRemaining(&sink.writer));
    try std.testing.expect(!sink.mismatch);
    try std.testing.expectEqual(plain.len, sink.count);
    return stream;
}

pub fn expectErrorNames(comptime Set: type, expected: []const []const u8) !void {
    const actual = @typeInfo(Set).error_set.?;
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected) |name| {
        for (actual) |err| {
            if (std.mem.eql(u8, err.name, name)) break;
        } else return error.MissingError;
    }
}
