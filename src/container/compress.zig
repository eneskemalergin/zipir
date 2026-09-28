//! The `std.Io.Writer` shared by the gzip, zlib, and raw DEFLATE compressors: plain bytes are written straight
//! into the encoder's window, and each 32 KiB window is coded once more than a window is buffered.

const std = @import("std");
const engine = @import("../deflate/deflate.zig");

const RING = engine.RING;

/// `Format` is a container's framing around one DEFLATE stream. It declares `Check` (with `init() Check`),
/// `header(*std.Io.Writer, engine.Level) std.Io.Writer.Error!void`, and `trailer(*std.Io.Writer, *Check, size: u64)
/// std.Io.Writer.Error!void`.
pub fn Deflate(comptime Format: type) type {
    return struct {
        const Self = @This();
        const Check = Format.Check;
        pub const Options = engine.CompressOptions;

        /// Plain bytes go here, in any sizes; the output bytes depend only on the bytes, never on the write sizes.
        /// A contiguous request (`writableSlice`, `writeInt`, `print`) of up to 32 KiB always fits.
        /// `flush` ends what was written in a byte-aligned, non-final block and restarts the history, so everything
        /// written so far can be decoded (a full flush); it does not flush the output writer.
        writer: std.Io.Writer,
        encoder: engine.Encoder,
        check: Check,
        state: State,

        const State = enum { open, closed };

        const vtable: std.Io.Writer.VTable = .{
            .drain = drain,
            .flush = flush,
            .rebase = rebase,
        };

        /// Starts a stream into `output` and writes its header. Resets everything, including after errors.
        /// The workspace must stay at this address while `writer` is used: the writer's buffer is inside it.
        pub fn init(self: *Self, output: *std.Io.Writer, options: engine.CompressOptions) std.Io.Writer.Error!void {
            self.state = .closed;
            self.writer = .failing;
            self.encoder.begin(output, options.level, false);
            self.check = Check.init();
            try Format.header(output, options.level);
            self.writer = .{ .vtable = &vtable, .buffer = self.encoder.space(), .end = 0 };
            self.state = .open;
        }

        /// Codes what is buffered as the last block and writes the trailer; the result is the number of plain bytes.
        /// The writer then fails until `init`. The caller flushes the output writer.
        pub fn finish(self: *Self) std.Io.Writer.Error!u64 {
            if (self.state != .open) return error.WriteFailed;
            errdefer self.close();
            const w = &self.writer;
            if (w.end > RING) try self.code();
            try self.encoder.step(Check, &self.check, w.end, 0, true, true, false);
            try self.encoder.finish();
            try Format.trailer(self.encoder.out, &self.check, self.encoder.size);
            self.close();
            return self.encoder.size;
        }

        fn close(self: *Self) void {
            self.state = .closed;
            self.writer = .failing;
        }

        fn parent(w: *std.Io.Writer) *Self {
            return @alignCast(@fieldParentPtr("writer", w));
        }

        // Codes the first window of the buffer; the bytes after it begin the next window.
        fn code(self: *Self) std.Io.Writer.Error!void {
            const w = &self.writer;
            std.debug.assert(w.end > RING);
            const carried = w.end - RING;
            try self.encoder.step(Check, &self.check, RING, carried, false, false, false);
            w.buffer = self.encoder.space();
            w.end = carried;
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self = parent(w);
            if (self.state != .open) return error.WriteFailed;
            errdefer self.close();
            var consumed: usize = 0;
            copy: {
                for (data[0 .. data.len - 1]) |bytes| {
                    const n = take(w, bytes);
                    consumed += n;
                    if (n < bytes.len) break :copy;
                }
                const pattern = data[data.len - 1];
                for (0..splat) |_| {
                    const n = take(w, pattern);
                    consumed += n;
                    if (n < pattern.len) break :copy;
                }
            }
            if (w.end > RING) try self.code();
            return consumed;
        }

        fn take(w: *std.Io.Writer, bytes: []const u8) usize {
            const n = @min(bytes.len, w.buffer.len - w.end);
            @memcpy(w.buffer[w.end..][0..n], bytes[0..n]);
            w.end += n;
            return n;
        }

        fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
            const self = parent(w);
            if (self.state != .open) return error.WriteFailed;
            if (w.buffer.len - w.end >= capacity) return;
            // Coding a window frees 32 KiB; the preserved bytes must lie after it.
            if (w.end <= RING or w.end - RING < preserve) return error.WriteFailed;
            errdefer self.close();
            try self.code();
            if (w.buffer.len - w.end < capacity) return error.WriteFailed;
        }

        fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
            const self = parent(w);
            if (self.state != .open) return error.WriteFailed;
            errdefer self.close();
            if (w.end > RING) try self.code();
            try self.encoder.step(Check, &self.check, w.end, 0, true, false, false);
            try self.encoder.sync();
            w.buffer = self.encoder.space();
            w.end = 0;
        }
    };
}
