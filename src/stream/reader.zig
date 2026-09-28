//! The `std.Io.Reader` shared by the gzip, zlib, raw DEFLATE, and BGZF decompressors: decoded bytes are pulled
//! from the workspace's own buffer, which keeps 32 KiB of history and decodes up to 128 KiB ahead.

const std = @import("std");
const decode = @import("../engine/decode.zig");
const codes = @import("../engine/codes.zig");

/// `Format` is a container's framing around DEFLATE streams. It declares `Check` (with `init() Check`), `Error`
/// (a superset of `decode.Error`), `Options` (with `max_output_bytes`), `min_input_buffer`, `init(Options)`,
/// `begin(*Format, *decode.BitReader) Error!bool` (reads what precedes a stream: true when one follows, false
/// when the input has ended as the container allows), and `end(*Format, *decode.BitReader, *Check, size: u64)
/// Error!void` (reads and checks what follows a stream).
///
/// A format with `stream_limit` has small streams (BGZF blocks): each is capped at that many bytes, decoded
/// whole, and readable only after `end` accepts it; it may declare `streamError(*const Format, Error, start: u64)
/// Error` to rename an error of the stream that began at output position `start`, and `seeking: bool` to get
/// `seek` and `seekUncompressed`.
pub fn Inflate(comptime Format: type) type {
    return struct {
        const Self = @This();
        const Check = Format.Check;
        const whole = @hasDecl(Format, "stream_limit");
        // Room needed to start decoding: a whole stream, or enough that reads taking a little do not move history.
        const min_room = if (whole) Format.stream_limit else codes.RING;
        pub const Options = Format.Options;
        pub const Error = Format.Error;

        /// The decoded bytes. `ReadFailed` means `err` holds the reason.
        reader: std.Io.Reader,
        /// Set when `reader` fails: a decode error, or `ReadFailed` from the input reader.
        err: ?Format.Error,
        /// The container's state, such as what it has read so far.
        container: Format,
        decoder: decode.Decoder,
        session: decode.Session(Check),
        br: decode.BitReader,
        check: Check,
        state: State,
        // An error met after this call had delivered bytes; reported on the next call.
        held: ?Format.Error,

        const State = enum { start, body, done, failed };

        const vtable: std.Io.Reader.VTable = .{
            .stream = stream,
            .discard = discard,
            .readVec = readVec,
            .rebase = rebase,
        };

        /// Starts decoding `input` from its current position. Resets everything, including after errors.
        /// The workspace must stay at this address while `reader` is used: the reader's buffer is inside it.
        /// After the end, `input` stands just after the compressed data; after an error its position is unspecified.
        pub fn init(self: *Self, input: *std.Io.Reader, options: Format.Options) void {
            self.reader = .{ .vtable = &vtable, .buffer = &self.decoder.buffer, .seek = 0, .end = 0 };
            self.err = null;
            self.held = if (input.buffer.len < Format.min_input_buffer) error.InputBufferTooSmall else null;
            self.session = .{ .decoder = &self.decoder, .max_output_bytes = options.max_output_bytes };
            if (whole) self.session.stream_limit = Format.stream_limit;
            self.br = .{ .reader = input };
            self.container = Format.init(options);
            self.state = .start;
        }

        /// Moves to a BGZF virtual offset: `offset.coffset` must be a block start in `source`, which must be the
        /// reader `init` was given, and `offset.uoffset` bytes of that block are skipped. A block start that is not
        /// one, or a skip past the block's end, is `BadVirtualOffset`.
        pub const seek = if (@hasField(Format, "seeking")) seekVirtual else @compileError("only BGZF seeks");

        /// Moves to uncompressed offset `uoffset` of a BGZF file through `.gzi` entries (from `IndexReader`, which
        /// checked them; sparse or empty is fine, the skip then spans blocks). `source` as for `seek`. An offset past
        /// the end leaves the reader at the end.
        pub const seekUncompressed = if (@hasField(Format, "seeking")) seekIndexed else @compileError("only BGZF seeks");

        fn seekVirtual(self: *Self, source: *std.Io.File.Reader, offset: anytype) Format.Error!void {
            return self.seekTo(source, offset.coffset, offset.uoffset, true);
        }

        fn seekIndexed(self: *Self, source: *std.Io.File.Reader, entries: anytype, uoffset: u64) Format.Error!void {
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

        // The first block is decoded here, so an offset that is not a block start fails now, not on a later read.
        fn seekTo(self: *Self, source: *std.Io.File.Reader, coffset: u64, skip: u64, in_block: bool) Format.Error!void {
            std.debug.assert(self.br.reader == &source.interface);
            const options = self.container.options;
            source.seekTo(coffset) catch return error.ReadFailed;
            self.init(&source.interface, options);
            self.container.seeking = true;
            const r = &self.reader;
            const reached = if (skip == 0) r.fill(1) else r.discardAll64(skip);
            reached catch |e| switch (e) {
                error.EndOfStream => if (in_block and skip != 0) return error.BadVirtualOffset,
                error.ReadFailed => return self.err.?,
            };
            if (in_block and self.container.first_size < skip) return error.BadVirtualOffset;
        }

        fn parent(r: *std.Io.Reader) *Self {
            return @alignCast(@fieldParentPtr("reader", r));
        }

        // Decodes into the buffer until it is full or the input ends. EndOfStream only when nothing is left.
        fn fill(self: *Self) std.Io.Reader.Error!void {
            const r = &self.reader;
            if (self.held) |e| {
                self.held = null;
                return self.fail(e);
            }
            switch (self.state) {
                .done => return error.EndOfStream,
                .failed => return error.ReadFailed,
                .start, .body => {},
            }
            if (r.buffer.len - r.end < min_room) {
                r.seek -= self.session.rebase(r.seek);
                r.end = self.session.out_pos;
            }
            const start = r.end;
            while (true) {
                switch (self.state) {
                    .start => {
                        if (r.buffer.len - self.session.out_pos < (if (whole) min_room else 1)) break;
                        const more = self.container.begin(&self.br) catch |e| return self.fault(e, start);
                        if (!more) {
                            self.state = .done;
                            self.br.release();
                            break;
                        }
                        self.check = Check.init();
                        self.session.begin(&self.br, &self.check);
                        self.state = .body;
                    },
                    .body => {
                        const stop = self.session.run() catch |e| {
                            if (!whole) r.end = self.session.out_pos;
                            const renamed = if (@hasDecl(Format, "streamError")) self.container.streamError(e, self.session.stream_start) else e;
                            return self.fault(renamed, start);
                        };
                        if (stop == .full) {
                            // A whole stream always has room: its cap ends it first.
                            std.debug.assert(!whole);
                            r.end = self.session.out_pos;
                            break;
                        }
                        self.container.end(&self.br, &self.check, self.session.position() - self.session.stream_start) catch |e| {
                            if (!whole) r.end = self.session.out_pos;
                            return self.fault(e, start);
                        };
                        r.end = self.session.out_pos;
                        self.state = .start;
                    },
                    .done, .failed => unreachable,
                }
            }
            if (r.end == start) return if (self.state == .done) error.EndOfStream else self.fail(error.PeekTooLarge);
        }

        // Bytes delivered in this call come first; the error waits for the next call.
        fn fault(self: *Self, e: Format.Error, start: usize) std.Io.Reader.Error!void {
            self.br.release();
            if (self.reader.end > start) {
                self.state = .failed;
                self.held = e;
                return;
            }
            return self.fail(e);
        }

        fn fail(self: *Self, e: Format.Error) error{ReadFailed} {
            self.state = .failed;
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
            // Every buffered byte unread and no room: hand bytes on, so a caller waiting for room can progress.
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

        // Keeps the unread bytes and 32 KiB of history before them.
        fn rebase(r: *std.Io.Reader, capacity: usize) std.Io.Reader.RebaseError!void {
            const self = parent(r);
            r.seek -= self.session.rebase(r.seek);
            r.end = self.session.out_pos;
            if (r.buffer.len - r.seek < capacity and self.state != .done) return self.fail(error.PeekTooLarge);
        }
    };
}
