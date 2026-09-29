//! The `std.Io.Reader` every decompressor is: decoded bytes are read from the workspace's own buffer. A `Framing`
//! declares `Check`, `DecompressOptions` (with `trailing_data`), `DecompressError`, `min_input_buffer`, `init`,
//! `header` (true when a stream follows), and `trailer`. One with `max_stream_bytes` decodes each stream whole before
//! it is readable and may declare `streamError` and a `seeking` field, which enables `seek` and `seekUncompressed`.
//! An input reader whose buffer is under `min_input_buffer` is read through a staging buffer in the workspace, which
//! may take bytes past the stream from it, so with `trailing_data = .leave` it is `InputBufferTooSmall`.

const std = @import("std");
const decode = @import("../engine/decode.zig");
const codes = @import("../engine/codes.zig");

pub const TrailingData = enum { reject, leave };

pub const Options = struct {
    max_output_bytes: u64 = std.math.maxInt(u64),
    trailing_data: TrailingData = .reject,
};

pub const Error = error{ InputBufferTooSmall, PeekTooLarge };

pub fn Decompressor(comptime Framing: type) type {
    return struct {
        const Self = @This();
        const Check = Framing.Check;
        const whole_streams = @hasDecl(Framing, "max_stream_bytes");
        const min_room = if (whole_streams) Framing.max_stream_bytes else codes.WINDOW;
        pub const DecompressOptions = Framing.DecompressOptions;
        pub const DecompressError = Framing.DecompressError;

        reader: std.Io.Reader,
        err: ?DecompressError,
        framing: Framing,
        decoder: decode.Decoder align(8),
        input: *std.Io.Reader,
        staging: Staging,
        session: decode.Session(Check),
        br: decode.BitReader,
        check: Check,
        phase: Phase,
        deferred: ?DecompressError,

        const Phase = enum { header, body, done, failed };

        const Staging = struct {
            reader: std.Io.Reader,
            buffer: [Framing.min_input_buffer]u8,

            const staging_vtable: std.Io.Reader.VTable = .{ .stream = forward };

            fn init(self: *Staging) *std.Io.Reader {
                self.reader = .{ .vtable = &staging_vtable, .buffer = &self.buffer, .seek = 0, .end = 0 };
                return &self.reader;
            }

            fn forward(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                const staging: *Staging = @alignCast(@fieldParentPtr("reader", r));
                const owner: *Self = @alignCast(@fieldParentPtr("staging", staging));
                return owner.input.stream(w, limit);
            }
        };

        const vtable: std.Io.Reader.VTable = .{
            .stream = stream,
            .discard = discard,
            .readVec = readVec,
            .rebase = rebase,
        };

        pub fn init(self: *Self, input: *std.Io.Reader, options: DecompressOptions) void {
            self.reader = .{ .vtable = &vtable, .buffer = &self.decoder.buffer, .seek = 0, .end = 0 };
            self.err = null;
            self.input = input;
            const small = input.buffer.len < Framing.min_input_buffer;
            self.deferred = if (small and options.trailing_data == .leave) error.InputBufferTooSmall else null;
            self.session = .{ .decoder = &self.decoder, .max_output_bytes = options.max_output_bytes };
            if (whole_streams) self.session.max_stream_bytes = Framing.max_stream_bytes;
            self.br = .{ .reader = if (small) self.staging.init() else input };
            self.framing = Framing.init(options);
            self.phase = .header;
        }

        pub const seek = if (@hasField(Framing, "seeking")) seekVirtual else @compileError("only BGZF seeks");

        pub const seekUncompressed = if (@hasField(Framing, "seeking")) seekIndexed else @compileError("only BGZF seeks");

        fn seekVirtual(self: *Self, source: *std.Io.File.Reader, offset: anytype) DecompressError!void {
            return self.seekTo(source, offset.coffset, offset.uoffset, true);
        }

        fn seekIndexed(self: *Self, source: *std.Io.File.Reader, entries: anytype, uoffset: u64) DecompressError!void {
            var low: usize = 0;
            var high: usize = entries.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (entries[mid].uoffset <= uoffset) low = mid + 1 else high = mid;
            }
            const coffset: u64 = if (low == 0) 0 else entries[low - 1].coffset;
            const from: u64 = if (low == 0) 0 else entries[low - 1].uoffset;
            return self.seekTo(source, coffset, uoffset - from, false);
        }

        fn seekTo(self: *Self, source: *std.Io.File.Reader, coffset: u64, skip: u64, in_block: bool) DecompressError!void {
            std.debug.assert(self.input == &source.interface);
            const options = self.framing.options;
            source.seekTo(coffset) catch return error.ReadFailed;
            self.init(&source.interface, options);
            self.framing.seeking = true;
            const r = &self.reader;
            const reached = if (skip == 0) r.fill(1) else r.discardAll64(skip);
            reached catch |e| switch (e) {
                error.EndOfStream => if (in_block and skip != 0) return error.BadVirtualOffset,
                error.ReadFailed => return self.err.?,
            };
            if (in_block and self.framing.first_size < skip) return error.BadVirtualOffset;
        }

        fn parent(r: *std.Io.Reader) *Self {
            return @alignCast(@fieldParentPtr("reader", r));
        }

        fn fill(self: *Self) std.Io.Reader.Error!void {
            const r = &self.reader;
            if (self.deferred) |e| {
                self.deferred = null;
                return self.fail(e);
            }
            switch (self.phase) {
                .done => return error.EndOfStream,
                .failed => return error.ReadFailed,
                .header, .body => {},
            }
            if (r.buffer.len - r.end < min_room) {
                r.seek -= self.session.rebase(r.seek);
                r.end = self.session.out_pos;
            }
            const start = r.end;
            while (true) {
                switch (self.phase) {
                    .header => {
                        if (r.buffer.len - self.session.out_pos < (if (whole_streams) min_room else 1)) break;
                        const more = self.framing.header(&self.br) catch |e| return self.fault(e, start);
                        if (!more) {
                            self.phase = .done;
                            self.br.release();
                            break;
                        }
                        self.check = Check.init();
                        self.session.begin(&self.br, &self.check);
                        self.phase = .body;
                    },
                    .body => {
                        const stop = self.session.run() catch |e| {
                            if (!whole_streams) r.end = self.session.out_pos;
                            const renamed = if (@hasDecl(Framing, "streamError")) self.framing.streamError(e, self.session.stream_start) else e;
                            return self.fault(renamed, start);
                        };
                        if (stop == .full) {
                            std.debug.assert(!whole_streams);
                            r.end = self.session.out_pos;
                            break;
                        }
                        self.framing.trailer(&self.br, &self.check, self.session.position() - self.session.stream_start) catch |e| {
                            if (!whole_streams) r.end = self.session.out_pos;
                            return self.fault(e, start);
                        };
                        r.end = self.session.out_pos;
                        self.phase = .header;
                    },
                    .done, .failed => unreachable,
                }
            }
            if (r.end == start) return if (self.phase == .done) error.EndOfStream else self.fail(error.PeekTooLarge);
        }

        fn fault(self: *Self, e: DecompressError, start: usize) std.Io.Reader.Error!void {
            self.br.release();
            if (self.reader.end > start) {
                self.phase = .failed;
                self.deferred = e;
                return;
            }
            return self.fail(e);
        }

        fn fail(self: *Self, e: DecompressError) error{ReadFailed} {
            self.phase = .failed;
            self.err = e;
            return error.ReadFailed;
        }

        fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
            _ = data;
            try parent(r).fill();
            return 0;
        }

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self = parent(r);
            if (r.seek == 0 and r.end == r.buffer.len) {
                const n = try w.write(limit.slice(r.buffer[r.seek..r.end]));
                r.seek += n;
                return n;
            }
            try self.fill();
            return 0;
        }

        fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
            try parent(r).fill();
            const n = limit.minInt(r.end - r.seek);
            r.seek += n;
            return n;
        }

        fn rebase(r: *std.Io.Reader, capacity: usize) std.Io.Reader.RebaseError!void {
            const self = parent(r);
            r.seek -= self.session.rebase(r.seek);
            r.end = self.session.out_pos;
            if (r.buffer.len - r.seek < capacity and self.phase != .done) return self.fail(error.PeekTooLarge);
        }
    };
}
