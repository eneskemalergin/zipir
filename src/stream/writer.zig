//! The `std.Io.Writer` the gzip, zlib, and raw DEFLATE compressors are. A `Framing` declares `Check`, `header`, and
//! `trailer`.

const std = @import("std");
const encode = @import("../engine/encode.zig");
const codes = @import("../engine/codes.zig");

const WINDOW = codes.WINDOW;

pub const Options = struct {
    preset: encode.Preset = .even,
};

pub fn Compressor(comptime Framing: type) type {
    return struct {
        const Self = @This();
        const Check = Framing.Check;
        pub const CompressOptions = Options;
        pub const CompressError = std.Io.Writer.Error;

        writer: std.Io.Writer,
        encoder: encode.Encoder,
        check: Check,
        phase: Phase,

        const Phase = enum { open, closed };

        const vtable: std.Io.Writer.VTable = .{
            .drain = drain,
            .flush = flush,
            .rebase = rebase,
        };

        pub fn init(self: *Self, output: *std.Io.Writer, options: CompressOptions) CompressError!void {
            self.phase = .closed;
            self.writer = .failing;
            self.encoder.begin(output, options.preset, false);
            self.check = Check.init();
            try Framing.header(output, options.preset);
            self.writer = .{ .vtable = &vtable, .buffer = self.encoder.windowSpace(), .end = 0 };
            self.phase = .open;
        }

        pub fn finish(self: *Self) CompressError!u64 {
            if (self.phase != .open) return error.WriteFailed;
            errdefer self.close();
            const w = &self.writer;
            if (w.end > WINDOW) try self.codeWindow();
            try self.encoder.codeWindow(Check, &self.check, w.end, 0, true, true, false);
            try self.encoder.finish();
            try Framing.trailer(self.encoder.out, &self.check, self.encoder.size);
            self.close();
            return self.encoder.size;
        }

        fn close(self: *Self) void {
            self.phase = .closed;
            self.writer = .failing;
        }

        fn parent(w: *std.Io.Writer) *Self {
            return @alignCast(@fieldParentPtr("writer", w));
        }

        fn codeWindow(self: *Self) CompressError!void {
            const w = &self.writer;
            std.debug.assert(w.end > WINDOW);
            const carried = w.end - WINDOW;
            try self.encoder.codeWindow(Check, &self.check, WINDOW, carried, false, false, false);
            w.buffer = self.encoder.windowSpace();
            w.end = carried;
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) CompressError!usize {
            const self = parent(w);
            if (self.phase != .open) return error.WriteFailed;
            errdefer self.close();
            var consumed: usize = 0;
            copy: {
                for (data[0 .. data.len - 1]) |bytes| {
                    const n = copyIn(w, bytes);
                    consumed += n;
                    if (n < bytes.len) break :copy;
                }
                const pattern = data[data.len - 1];
                for (0..splat) |_| {
                    const n = copyIn(w, pattern);
                    consumed += n;
                    if (n < pattern.len) break :copy;
                }
            }
            if (w.end > WINDOW) try self.codeWindow();
            return consumed;
        }

        fn copyIn(w: *std.Io.Writer, bytes: []const u8) usize {
            const n = @min(bytes.len, w.buffer.len - w.end);
            @memcpy(w.buffer[w.end..][0..n], bytes[0..n]);
            w.end += n;
            return n;
        }

        fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) CompressError!void {
            const self = parent(w);
            if (self.phase != .open) return error.WriteFailed;
            if (w.buffer.len - w.end >= capacity) return;
            if (w.end <= WINDOW or w.end - WINDOW < preserve) return error.WriteFailed;
            errdefer self.close();
            try self.codeWindow();
            if (w.buffer.len - w.end < capacity) return error.WriteFailed;
        }

        fn flush(w: *std.Io.Writer) CompressError!void {
            const self = parent(w);
            if (self.phase != .open) return error.WriteFailed;
            errdefer self.close();
            if (w.end > WINDOW) try self.codeWindow();
            try self.encoder.codeWindow(Check, &self.check, w.end, 0, true, false, false);
            try self.encoder.fullFlush();
            w.buffer = self.encoder.windowSpace();
            w.end = 0;
        }
    };
}
