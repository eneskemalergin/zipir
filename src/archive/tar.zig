//! Streaming tar (ustar, pax, GNU). `Reader(Visitor)` is a `std.Io.Writer` that calls
//! `entry(*Visitor, Entry) !Action`, then `data(*Visitor, []const u8) !void` when `entry` returned `.read`, then
//! `entryEnd(*Visitor) !void`; the archive ends at its first zero block, as in GNU tar. `Writer(Source)` is a
//! `std.Io.Reader` over `next(*Source) !?Entry` and `data(*Source) *std.Io.Reader`, of which exactly `Entry.size`
//! bytes are read (`SourceTooShort` otherwise); every header gets `options.mtime`, so the same entries give the same
//! bytes. After `WriteFailed` or `ReadFailed`, `finish` returns the cause.
//! `Entry.name` and `link_name` borrow the caller's `Names` until the next entry; over `MAX_NAME` is `NameTooLong`.
//! `Entry.size` is 0 for kinds that never carry data, whatever the header claims. The reader's writer has no buffer:
//! feed a plain file from its reader's buffer (`peekGreedy`, then `toss`). `isHeader` accepts a block that is not all
//! zeros and whose checksum is right; pre-POSIX headers have no magic, so it is not checked.

const std = @import("std");

pub const Error = error{ BadHeaderChecksum, BadNumber, BadPax, NameTooLong, UnsupportedEntry, Truncated };

pub const Kind = enum { file, directory, symlink, hardlink, char_device, block_device, fifo, other };

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

pub fn Reader(comptime Visitor: type) type {
    return struct {
        const Self = @This();

        pub const ReadError = Error || VisitorError(Visitor);

        writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        visitor: *Visitor,
        names: Names,
        failure: ?ReadError = null,
        section: Section = .header,
        block: [BLOCK]u8 = undefined,
        block_len: usize = 0,
        remaining: u64 = 0,
        padding: u64 = 0,
        action: Action = .read,
        entries: u64 = 0,
        end_marker: bool = false,
        long_name: ?usize = null,
        long_link: ?usize = null,
        pax_size: ?u64 = null,
        pending: bool = false,
        meta: Meta = .{},

        pub fn init(visitor: *Visitor, names: Names) Self {
            return .{ .visitor = visitor, .names = names };
        }

        pub fn finish(self: *Self) ReadError!Summary {
            if (self.failure) |err| return err;
            switch (self.section) {
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
                switch (self.section) {
                    .header, .end => {
                        const n = @min(BLOCK - self.block_len, bytes.len);
                        @memcpy(self.block[self.block_len..][0..n], bytes[0..n]);
                        self.block_len += n;
                        bytes = bytes[n..];
                        if (self.block_len < BLOCK) continue;
                        self.block_len = 0;
                        if (self.section == .end) {
                            self.end_marker = byteSum(&self.block) == 0;
                            self.section = .after_end;
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
                        const out = if (self.section == .long_name) self.names.name else self.names.link;
                        try self.meta.longName(out, bytes[0..n]);
                        bytes = bytes[n..];
                        if (self.remaining == 0) {
                            if (self.section == .long_name) {
                                self.long_name = self.meta.len;
                            } else {
                                self.long_link = self.meta.len;
                            }
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
                self.section = .end;
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

        fn beginMeta(self: *Self, section: Section, size: u64) void {
            self.remaining = size;
            self.padding = pad(size);
            self.section = section;
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
            self.section = .data;
            if (size == 0) try self.endEntry();
        }

        fn endEntry(self: *Self) ReadError!void {
            try self.visitor.entryEnd();
            self.startPadding();
        }

        fn startPadding(self: *Self) void {
            self.remaining = self.padding;
            self.padding = 0;
            self.section = if (self.remaining == 0) .header else .skip;
        }

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

pub fn isHeader(block: *const [512]u8) bool {
    const sum = byteSum(block);
    if (sum == 0) return false;
    checkChecksum(block, sum) catch return false;
    return true;
}

pub const WriterOptions = struct { mtime: i64 = 0 };

pub const WriteError = error{ NameTooLong, UnsupportedEntry, SourceTooShort };

pub const MAX_NAME = 4095;

pub fn Writer(comptime Source: type) type {
    return struct {
        const Self = @This();

        pub const CreateError = WriteError || ErrorOf(Source.next) || error{ReadFailed};

        reader: std.Io.Reader,
        source: *Source,
        options: WriterOptions,
        failure: ?CreateError = null,
        state: enum { next, header, data, padding, end, done } = .next,
        remaining: u64 = 0,
        padding: usize = 0,
        entries: u64 = 0,
        header: [HEADER_ROOM]u8 = undefined,
        header_len: usize = 0,
        header_at: usize = 0,

        pub fn init(source: *Source, buffer: []u8, options: WriterOptions) Self {
            return .{
                .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
                .source = source,
                .options = options,
            };
        }

        pub fn finish(self: *Self) CreateError!u64 {
            if (self.failure) |err| return err;
            return self.entries;
        }

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *Self = @alignCast(@fieldParentPtr("reader", r));
            if (self.failure != null) return error.ReadFailed;
            return self.produce(w, limit) catch |err| switch (err) {
                error.EndOfStream => error.EndOfStream,
                error.WriteFailed => error.WriteFailed,
                else => |e| {
                    self.failure = e;
                    return error.ReadFailed;
                },
            };
        }

        fn produce(self: *Self, w: *std.Io.Writer, limit: std.Io.Limit) (CreateError || std.Io.Reader.StreamError)!usize {
            switch (self.state) {
                .next => {
                    const entry = try self.source.next() orelse {
                        self.padding = 2 * BLOCK;
                        self.state = .end;
                        return 0;
                    };
                    try self.formatEntry(entry);
                    self.entries += 1;
                    self.state = .header;
                    return 0;
                },
                .header => {
                    const n = limit.minInt(self.header_len - self.header_at);
                    try w.writeAll(self.header[self.header_at..][0..n]);
                    self.header_at += n;
                    if (self.header_at == self.header_len) self.state = if (self.remaining != 0) .data else .next;
                    return n;
                },
                .data => {
                    const n = self.source.data().stream(w, limit.min(.limited64(self.remaining))) catch |err| switch (err) {
                        error.EndOfStream => return error.SourceTooShort,
                        else => |e| return e,
                    };
                    self.remaining -= n;
                    if (self.remaining == 0) self.state = if (self.padding != 0) .padding else .next;
                    return n;
                },
                .padding, .end => {
                    const n = limit.minInt(@min(self.padding, ZEROS.len));
                    try w.writeAll(ZEROS[0..n]);
                    self.padding -= n;
                    if (self.padding == 0) self.state = if (self.state == .end) .done else .next;
                    return n;
                },
                .done => return error.EndOfStream,
            }
        }

        fn formatEntry(self: *Self, entry: Entry) WriteError!void {
            const typeflag: u8 = switch (entry.kind) {
                .file => '0',
                .hardlink => '1',
                .symlink => '2',
                .directory => '5',
                else => return error.UnsupportedEntry,
            };
            if (entry.name.len > MAX_NAME or entry.link_name.len > MAX_NAME) return error.NameTooLong;
            const size = if (entry.kind == .file) entry.size else 0;
            var at: usize = 0;
            var name = entry.name;
            var prefix: []const u8 = "";
            if (name.len > 100) {
                if (splitUstar(name)) |parts| {
                    prefix = parts[0];
                    name = parts[1];
                } else {
                    at = longName(&self.header, at, 'L', name);
                    name = name[0..100];
                }
            }
            var link = entry.link_name;
            if (link.len > 100) {
                at = longName(&self.header, at, 'K', link);
                link = link[0..100];
            }
            formatHeader(self.header[at..][0..BLOCK], .{
                .name = name,
                .prefix = prefix,
                .link = link,
                .typeflag = typeflag,
                .size = size,
                .mode = entry.mode & 0o7777,
                .mtime = self.options.mtime,
            });
            self.header_len = at + BLOCK;
            self.header_at = 0;
            self.remaining = size;
            self.padding = @intCast(pad(size));
        }
    };
}

const BLOCK = 512;

const HEADER_ROOM = 3 * BLOCK + 2 * (MAX_NAME + 1);

const ZEROS = [_]u8{0} ** (2 * BLOCK);

const Section = enum { header, data, skip, long_name, long_link, pax, end, after_end };

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

const HeaderFields = struct {
    name: []const u8,
    prefix: []const u8 = "",
    link: []const u8 = "",
    typeflag: u8,
    size: u64,
    mode: u32,
    mtime: i64,
};

fn formatHeader(h: *[BLOCK]u8, f: HeaderFields) void {
    @memset(h, 0);
    @memcpy(h[0..f.name.len], f.name);
    putNumber(h[100..108], f.mode);
    putNumber(h[108..116], 0);
    putNumber(h[116..124], 0);
    putNumber(h[124..136], f.size);
    putNumber(h[136..148], f.mtime);
    h[156] = f.typeflag;
    @memcpy(h[157..][0..f.link.len], f.link);
    @memcpy(h[257..265], "ustar\x0000");
    putNumber(h[329..337], 0);
    putNumber(h[337..345], 0);
    @memcpy(h[345..][0..f.prefix.len], f.prefix);
    @memset(h[148..156], ' ');
    _ = std.fmt.bufPrint(h[148..155], "{o:0>6}\x00", .{byteSum(h)}) catch unreachable;
}

fn putNumber(field: []u8, value: i128) void {
    const digits = field.len - 1;
    if (value >= 0 and value >> @intCast(3 * digits) == 0) {
        var v = value;
        var i = digits;
        while (i > 0) {
            i -= 1;
            field[i] = '0' + @as(u8, @intCast(v & 7));
            v >>= 3;
        }
        field[digits] = 0;
        return;
    }
    var v = value;
    var i = field.len;
    while (i > 0) {
        i -= 1;
        field[i] = @truncate(@as(u128, @bitCast(v)));
        v >>= 8;
    }
    field[0] |= 0x80;
}

fn splitUstar(path: []const u8) ?[2][]const u8 {
    if (path.len > 256) return null;
    var i = @min(path.len - 1, 155);
    while (i > 0) : (i -= 1) {
        const rest = path.len - i - 1;
        if (path[i] == '/' and rest > 0 and rest <= 100) return .{ path[0..i], path[i + 1 ..] };
    }
    return null;
}

fn longName(out: []u8, at: usize, typeflag: u8, name: []const u8) usize {
    formatHeader(out[at..][0..BLOCK], .{ .name = "././@LongLink", .typeflag = typeflag, .size = name.len + 1, .mode = 0, .mtime = 0 });
    const data = out[at + BLOCK ..][0..@intCast(name.len + 1 + pad(name.len + 1))];
    @memset(data, 0);
    @memcpy(data[0..name.len], name);
    return at + BLOCK + data.len;
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
