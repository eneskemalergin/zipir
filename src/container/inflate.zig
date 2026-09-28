//! The `std.Io.Reader` shared by the gzip, zlib, and raw DEFLATE decompressors: decoded bytes are pulled from
//! the workspace's own buffer, which keeps 32 KiB of history and decodes up to 128 KiB ahead.

const std = @import("std");
const engine = @import("../deflate/deflate.zig");

/// `Format` is a container's framing around DEFLATE streams. It declares `Check` (with `init() Check`), `Error`
/// (a superset of `engine.Error`), `Options` (with `max_output_bytes`), `min_input_buffer`, `init(Options)`,
/// `begin(*Format, *engine.BitReader) Error!bool` (reads what precedes a stream: true when one follows, false
/// when the input has ended as the container allows), and `end(*Format, *engine.BitReader, *Check, size: u64)
/// Error!void` (reads and checks what follows a stream).
pub fn Inflate(comptime Format: type) type {
    return struct {
        const Self = @This();
        const Check = Format.Check;
        pub const Options = Format.Options;
        pub const Error = Format.Error;

        /// The decoded bytes. `ReadFailed` means `err` holds the reason.
        reader: std.Io.Reader,
        /// Set when `reader` fails: a decode error, or `ReadFailed` from the input reader.
        err: ?Format.Error,
        decoder: engine.Decoder,
        session: engine.Session(Check),
        br: engine.BitReader,
        check: Check,
        format: Format,
        state: State,
        // An error met after this call had decoded bytes; reported on the next call.
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
            self.br = .{ .reader = input };
            self.format = Format.init(options);
            self.state = .start;
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
            // Room is made only when little is left, so reads that each take a little do not move history.
            if (r.buffer.len - r.end < engine.RING) {
                r.seek -= self.session.rebase(r.seek);
                r.end = self.session.out_pos;
            }
            if (r.end == r.buffer.len) return self.fail(error.PeekTooLarge);
            const start = r.end;
            while (true) {
                switch (self.state) {
                    .start => {
                        const more = self.format.begin(&self.br) catch |e| return self.fault(e, start);
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
                            r.end = self.session.out_pos;
                            return self.fault(e, start);
                        };
                        r.end = self.session.out_pos;
                        if (stop == .full) break;
                        self.format.end(&self.br, &self.check, self.session.position() - self.session.stream_start) catch |e| return self.fault(e, start);
                        self.state = .start;
                    },
                    .done, .failed => unreachable,
                }
            }
            if (r.end == start) return error.EndOfStream;
        }

        // Bytes decoded in this call are delivered first; the error waits for the next call.
        fn fault(self: *Self, e: Format.Error, start: usize) std.Io.Reader.Error!void {
            self.br.release();
            if (self.reader.end > start) {
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
            if (r.buffer.len - r.seek < capacity) return self.fail(error.PeekTooLarge);
        }
    };
}
