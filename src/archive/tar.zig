//! Streaming tar (ustar, pax, GNU) reading as a `std.Io.Writer` that calls a caller's visitor per entry.

const std = @import("std");

pub const Error = error{ BadHeaderChecksum, BadNumber, BadPax, NameTooLong, UnsupportedEntry, Truncated };

pub const Kind = enum { file, directory, symlink, hardlink, char_device, block_device, fifo, other };

/// `size` is the number of data bytes that follow, 0 for kinds that never carry data whatever their
/// header claims, as GNU tar and Python `tarfile` read them. `name` and `link_name` borrow the
/// caller's `Names` until the next entry.
pub const Entry = struct {
    name: []const u8,
    link_name: []const u8,
    kind: Kind,
    size: u64,
    mode: u32,
    mtime: i64,
};

pub const Action = enum { read, skip };

pub const Names = struct { name: []u8, link: []u8 };

pub const Summary = struct { entries: u64, end_marker: bool };

/// Bytes of a tar stream are written to `writer`, which has no buffer: feed a plain file from its
/// reader's buffer (`peekGreedy`, then `toss`), since std's file reader streams into the destination's
/// buffer. `Visitor` declares `pub fn entry(*Visitor, Entry) !Action`, `pub fn data(*Visitor, []const u8) !void`
/// (the entry's bytes in order, when `entry` returned `.read`), and `pub fn entryEnd(*Visitor) !void`.
/// A failed write is `WriteFailed`; `finish` then returns the cause. The archive ends at its first zero
/// block, as in GNU tar; later bytes are ignored. No allocation occurs.
pub fn Reader(comptime Visitor: type) type {
    return struct {
        const Self = @This();

        pub const ReadError = Error || VisitorError(Visitor);

        writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        visitor: *Visitor,
        names: Names,
        failure: ?ReadError = null,
        state: State = .header,
        block: [BLOCK]u8 = undefined,
        block_len: usize = 0,
        remaining: u64 = 0,
        padding: u64 = 0,
        action: Action = .read,
        entries: u64 = 0,
        end_marker: bool = false,
        // Overrides from GNU long-name headers and pax records, for the next entry only.
        long_name: ?usize = null,
        long_link: ?usize = null,
        pax_size: ?u64 = null,
        // A long-name or pax header was read and the entry it describes has not started.
        pending: bool = false,
        meta: Meta = .{},

        pub fn init(visitor: *Visitor, names: Names) Self {
            return .{ .visitor = visitor, .names = names };
        }

        pub fn finish(self: *Self) ReadError!Summary {
            if (self.failure) |err| return err;
            switch (self.state) {
                .header => if (self.block_len != 0 or self.pending) return error.Truncated,
                .end, .after_end => {},
                else => return error.Truncated,
            }
            return .{ .entries = self.entries, .end_marker = self.end_marker };
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("writer", w));
            if (self.failure != null) return error.WriteFailed;
            var total: usize = 0;
            for (data, 0..) |bytes, i| {
                for (0..if (i + 1 == data.len) splat else 1) |_| {
                    self.feed(bytes) catch |err| {
                        self.failure = err;
                        return error.WriteFailed;
                    };
                    total += bytes.len;
                }
            }
            return total;
        }

        fn feed(self: *Self, input: []const u8) ReadError!void {
            var bytes = input;
            while (bytes.len != 0) {
                switch (self.state) {
                    .header, .end => {
                        const n = @min(BLOCK - self.block_len, bytes.len);
                        @memcpy(self.block[self.block_len..][0..n], bytes[0..n]);
                        self.block_len += n;
                        bytes = bytes[n..];
                        if (self.block_len < BLOCK) continue;
                        self.block_len = 0;
                        if (self.state == .end) {
                            self.end_marker = byteSum(&self.block) == 0;
                            self.state = .after_end;
                        } else try self.header();
                    },
                    .after_end => return,
                    .data => {
                        const n = take(&self.remaining, bytes.len);
                        if (self.action == .read) try self.visitor.data(bytes[0..n]);
                        bytes = bytes[n..];
                        if (self.remaining == 0) try self.endEntry();
                    },
                    .skip => {
                        bytes = bytes[take(&self.remaining, bytes.len)..];
                        if (self.remaining == 0) self.startPadding();
                    },
                    .long_name, .long_link => {
                        const n = take(&self.remaining, bytes.len);
                        const out = if (self.state == .long_name) self.names.name else self.names.link;
                        try self.meta.longName(out, bytes[0..n]);
                        bytes = bytes[n..];
                        if (self.remaining == 0) {
                            if (self.state == .long_name) self.long_name = self.meta.len else self.long_link = self.meta.len;
                            self.startPadding();
                        }
                    },
                    .pax => {
                        const n = take(&self.remaining, bytes.len);
                        for (bytes[0..n]) |b| try self.paxByte(b);
                        bytes = bytes[n..];
                        if (self.remaining == 0) {
                            if (self.meta.phase != .length or self.meta.digits != 0) return error.BadPax;
                            self.startPadding();
                        }
                    },
                }
            }
        }

        fn header(self: *Self) ReadError!void {
            const h = &self.block;
            const sum = byteSum(h);
            if (sum == 0) {
                self.state = .end;
                return;
            }
            try checkChecksum(h, sum);
            const size = try unsignedNumber(h[124..136]);
            const typeflag = h[156];
            switch (typeflag) {
                'L', 'K' => {
                    self.pending = true;
                    self.meta = .{};
                    self.beginMeta(if (typeflag == 'L') .long_name else .long_link, size);
                },
                'x' => {
                    self.pending = true;
                    self.meta = .{};
                    self.beginMeta(.pax, size);
                },
                'g' => self.beginMeta(.skip, size),
                'S' => return error.UnsupportedEntry,
                else => try self.startEntry(typeflag, size),
            }
        }

        fn beginMeta(self: *Self, state: State, size: u64) void {
            self.remaining = size;
            self.padding = pad(size);
            self.state = state;
            if (size == 0) self.startPadding();
        }

        fn startEntry(self: *Self, typeflag: u8, header_size: u64) ReadError!void {
            const h = &self.block;
            const name_len = self.long_name orelse try ustarName(h, self.names.name);
            const link_len = self.long_link orelse try copyField(cstr(h[157..257]), self.names.link);
            var kind: Kind = switch (typeflag) {
                '0', 0, '7' => .file,
                '1' => .hardlink,
                '2' => .symlink,
                '3' => .char_device,
                '4' => .block_device,
                '5' => .directory,
                '6' => .fifo,
                else => .other,
            };
            // Pre-POSIX archives mark directories by a trailing slash on a regular-file entry.
            if (typeflag == 0 and name_len != 0 and self.names.name[name_len - 1] == '/') kind = .directory;
            const carries_data = kind == .file or kind == .other;
            const size = if (carries_data) self.pax_size orelse header_size else 0;
            const entry: Entry = .{
                .name = self.names.name[0..name_len],
                .link_name = self.names.link[0..link_len],
                .kind = kind,
                .size = size,
                .mode = @intCast(try unsignedNumber(h[100..108]) & 0o7777),
                .mtime = try number(h[136..148]),
            };
            self.long_name = null;
            self.long_link = null;
            self.pax_size = null;
            self.pending = false;
            self.entries += 1;
            self.action = try self.visitor.entry(entry);
            self.remaining = size;
            self.padding = pad(size);
            self.state = .data;
            if (size == 0) try self.endEntry();
        }

        fn endEntry(self: *Self) ReadError!void {
            try self.visitor.entryEnd();
            self.startPadding();
        }

        fn startPadding(self: *Self) void {
            self.remaining = self.padding;
            self.padding = 0;
            self.state = if (self.remaining == 0) .header else .skip;
        }

        // One byte of a pax extended header: records are `LENGTH KEY=VALUE\n`, LENGTH counting the whole
        // record. Only `path`, `linkpath`, and `size` are kept; values stream into the caller's buffers.
        fn paxByte(self: *Self, b: u8) ReadError!void {
            const m = &self.meta;
            m.used += 1;
            switch (m.phase) {
                .length => {
                    if (b == ' ' and m.digits != 0) {
                        if (m.length < m.used + 3) return error.BadPax;
                        m.phase = .key;
                        m.key_len = 0;
                        return;
                    }
                    if (b < '0' or b > '9' or m.digits == 20) return error.BadPax;
                    m.length = std.math.mul(u64, m.length, 10) catch return error.BadPax;
                    m.length = std.math.add(u64, m.length, b - '0') catch return error.BadPax;
                    m.digits += 1;
                },
                .key => {
                    if (m.used == m.length) return error.BadPax;
                    if (b == '=' and m.key_len == 0) return error.BadPax;
                    if (b != '=') {
                        if (m.key_len < m.key.len) m.key[m.key_len] = b;
                        m.key_len += 1;
                        return;
                    }
                    m.target = if (m.key_len > m.key.len) .other else paxTarget(m.key[0..m.key_len]);
                    m.len = 0;
                    m.value = 0;
                    m.phase = .value;
                },
                .value => {
                    if (m.used == m.length) {
                        if (b != '\n') return error.BadPax;
                        switch (m.target) {
                            .path => self.long_name = if (m.len == 0) null else m.len,
                            .linkpath => self.long_link = if (m.len == 0) null else m.len,
                            .size => self.pax_size = if (m.len == 0) null else m.value,
                            .other => {},
                        }
                        m.* = .{};
                        return;
                    }
                    switch (m.target) {
                        .path => try m.append(self.names.name, b),
                        .linkpath => try m.append(self.names.link, b),
                        .size => {
                            if (b < '0' or b > '9') return error.BadPax;
                            m.value = std.math.mul(u64, m.value, 10) catch return error.BadPax;
                            m.value = std.math.add(u64, m.value, b - '0') catch return error.BadPax;
                            m.len += 1;
                        },
                        .other => {},
                    }
                },
            }
        }
    };
}

const BLOCK = 512;

const State = enum { header, data, skip, long_name, long_link, pax, end, after_end };

// Parse state of one GNU long-name or pax extended header.
const Meta = struct {
    len: usize = 0,
    nul: bool = false,
    phase: enum { length, key, value } = .length,
    length: u64 = 0,
    digits: u8 = 0,
    used: u64 = 0,
    key: [8]u8 = undefined,
    key_len: usize = 0,
    target: PaxTarget = .other,
    value: u64 = 0,

    // GNU long names end at their first NUL; the rest of the data is padding.
    fn longName(self: *Meta, out: []u8, bytes: []const u8) Error!void {
        if (self.nul) return;
        const end = std.mem.findScalar(u8, bytes, 0);
        const name = bytes[0 .. end orelse bytes.len];
        if (name.len > out.len - self.len) return error.NameTooLong;
        @memcpy(out[self.len..][0..name.len], name);
        self.len += name.len;
        self.nul = end != null;
    }

    fn append(self: *Meta, out: []u8, b: u8) Error!void {
        if (self.len == out.len) return error.NameTooLong;
        out[self.len] = b;
        self.len += 1;
    }
};

const PaxTarget = enum { path, linkpath, size, other };

fn paxTarget(key: []const u8) PaxTarget {
    inline for (.{ PaxTarget.path, PaxTarget.linkpath, PaxTarget.size }) |target| {
        if (std.mem.eql(u8, key, @tagName(target))) return target;
    }
    return .other;
}

fn VisitorError(comptime Visitor: type) type {
    return ErrorOf(Visitor.entry) || ErrorOf(Visitor.data) || ErrorOf(Visitor.entryEnd);
}

fn ErrorOf(comptime function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.error_set;
}

fn take(remaining: *u64, available: usize) usize {
    const n: usize = @intCast(@min(remaining.*, available));
    remaining.* -= n;
    return n;
}

fn pad(size: u64) u64 {
    return (BLOCK - size % BLOCK) % BLOCK;
}

// Zig 0.16 does not vectorize loops; as a scalar loop, this pass over every header block was 5% of the
// instructions of listing the Linux tarball through the gzip decoder (`tmp/tar/20-reader/RECORD.md`).
fn byteSum(block: *const [BLOCK]u8) u32 {
    const Lanes = @Vector(64, u16);
    var lanes: Lanes = @splat(0);
    var i: usize = 0;
    while (i < BLOCK) : (i += 64) {
        const bytes: @Vector(64, u8) = block[i..][0..64].*;
        lanes += @as(Lanes, bytes);
    }
    return @reduce(.Add, @as(@Vector(64, u32), lanes));
}

fn cstr(field: []const u8) []const u8 {
    return field[0 .. std.mem.findScalar(u8, field, 0) orelse field.len];
}

fn copyField(field: []const u8, out: []u8) Error!usize {
    if (field.len > out.len) return error.NameTooLong;
    @memcpy(out[0..field.len], field);
    return field.len;
}

// The POSIX prefix field holds the leading directories of a long name; old GNU headers use that
// space for other fields and carry the magic "ustar  " instead.
fn ustarName(h: *const [BLOCK]u8, out: []u8) Error!usize {
    const name = cstr(h[0..100]);
    const prefix = if (std.mem.eql(u8, h[257..263], "ustar\x00")) cstr(h[345..500]) else "";
    if (prefix.len == 0) return copyField(name, out);
    if (prefix.len + 1 + name.len > out.len) return error.NameTooLong;
    @memcpy(out[0..prefix.len], prefix);
    out[prefix.len] = '/';
    @memcpy(out[prefix.len + 1 ..][0..name.len], name);
    return prefix.len + 1 + name.len;
}

// The checksum counts its own field as spaces. Writers disagree on whether header bytes are signed,
// so either sum is accepted, as GNU tar does.
fn checkChecksum(h: *const [BLOCK]u8, sum: u32) Error!void {
    const stored = try unsignedNumber(h[148..156]);
    var field: u32 = 0;
    for (h[148..156]) |b| field += b;
    if (stored == sum - field + 8 * ' ') return;
    var signed: i64 = 8 * ' ';
    for (h, 0..) |b, i| {
        if (i < 148 or i >= 156) signed += @as(i8, @bitCast(b));
    }
    if (@as(i64, @intCast(stored)) != signed) return error.BadHeaderChecksum;
}

fn unsignedNumber(field: []const u8) Error!u64 {
    const value = try number(field);
    if (value < 0) return error.BadNumber;
    return @intCast(value);
}

// Octal digits between optional spaces and a space or NUL terminator, or GNU base-256: the first
// byte's top bit set, then a big-endian two's complement value in the remaining bits.
fn number(field: []const u8) Error!i64 {
    if (field[0] & 0x80 != 0) {
        var value: i64 = if (field[0] & 0x40 != 0) -1 else 0;
        value = (value << 7) | (field[0] & 0x7f);
        for (field[1..]) |b| {
            if (value >> 55 != 0 and value >> 55 != -1) return error.BadNumber;
            value = (value << 8) | b;
        }
        return value;
    }
    var value: i64 = 0;
    var digits = false;
    for (field) |b| {
        switch (b) {
            '0'...'7' => {
                if (value >> 60 != 0) return error.BadNumber;
                value = value * 8 + (b - '0');
                digits = true;
            },
            ' ' => if (digits) break,
            0 => break,
            else => return error.BadNumber,
        }
    }
    return value;
}
