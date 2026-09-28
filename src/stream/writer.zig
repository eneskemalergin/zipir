//! `Compressor(Framing)`: the `std.Io.Writer` shared by the gzip, zlib, and raw DEFLATE compressors. Plain bytes are
//! written straight into the encoder's window buffer, and a window is coded once more than a window is buffered.
//! (BGZF's compressor, which cuts its input into BGZF blocks, is in `format/bgzf.zig`.)

const std = @import("std");
const encode = @import("../engine/encode.zig");
const codes = @import("../engine/codes.zig");

const WINDOW = codes.WINDOW;

/// The compress options of gzip, zlib, and raw DEFLATE (each format's `CompressOptions`); BGZF extends them.
pub const Options = struct {
    preset: encode.Preset = .even,
};

/// `Framing` is a format's framing around one DEFLATE stream. It declares `Check` (with `init() Check`, `update`,
/// `final`), `header(*std.Io.Writer, encode.Preset) std.Io.Writer.Error!void`, and
/// `trailer(*std.Io.Writer, *Check, size: u64) std.Io.Writer.Error!void`.
pub fn Compressor(comptime Framing: type) type {
    return struct {
        const Self = @This();
        const Check = Framing.Check;
        pub const CompressOptions = Options;
        pub const CompressError = std.Io.Writer.Error;

        /// Plain bytes go here, in any sizes; the output depends only on the bytes, never on the write sizes. A
        /// contiguous request (`writableSlice`, `writeInt`, `print`) of up to 32 KiB always fits. `flush` is a full
        /// flush: what was written ends in a non-final DEFLATE block and an empty stored block, and the history
        /// restarts, so everything so far can be decoded; it does not flush the output writer.
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

        /// Starts a stream into `output` and writes its header; resets everything, including after errors.
        /// The workspace must stay at this address while `writer` is used: the writer's buffer is inside it.
        pub fn init(self: *Self, output: *std.Io.Writer, options: CompressOptions) CompressError!void {
            self.phase = .closed;
            self.writer = .failing;
            self.encoder.begin(output, options.preset, false);
            self.check = Check.init();
            try Framing.header(output, options.preset);
            self.writer = .{ .vtable = &vtable, .buffer = self.encoder.windowSpace(), .end = 0 };
            self.phase = .open;
        }

        /// Codes what is buffered as the final DEFLATE block and writes the trailer; the result is the number of
        /// plain bytes. The writer then fails until `init`. The caller flushes the output writer.
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

        // Codes the first window of the buffer; the bytes after it begin the next window.
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
            // Coding a window frees a window's room; the preserved bytes must lie after it.
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
