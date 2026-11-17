//! The fast decode loop compiled with BMI1 and BMI2, built as an object that exports a C symbol for targets that do not
//! guarantee them. `variant` bit 0 is a full window of history, bit 1 is pair entries in the table.

const options = @import("kernel_options");
const loop = @import("huff_loop.zig");

comptime {
    if (options.as_object) @export(&runRaw, .{ .name = "zipir_huff_loop_x86_bmi2_run" });
}

const Input = struct { src: []const u8, i: usize, bits: u64, nbits: u32 };

const Run = struct {
    br: *Input,
    out: []u8,
    out_pos: usize,
    stream_start: u64,
    base: u64,

    pub fn position(self: *const Run) u64 {
        return self.base + self.out_pos;
    }
};

fn runRaw(state: *loop.State, variant: u32) callconv(.c) u32 {
    var input: Input = .{ .src = state.src[0..state.src_len], .i = state.at, .bits = state.bits, .nbits = state.nbits };
    var run: Run = .{
        .br = &input,
        .out = state.out[0..state.out_len],
        .out_pos = state.out_pos,
        .stream_start = state.out_pos -| state.history,
        .base = state.history -| state.out_pos,
    };
    const outcome = switch (variant) {
        0 => loop.run(&run, state.lit, state.dist, state.mask, false, false),
        1 => loop.run(&run, state.lit, state.dist, state.mask, true, false),
        2 => loop.run(&run, state.lit, state.dist, state.mask, false, true),
        else => loop.run(&run, state.lit, state.dist, state.mask, true, true),
    };
    const result: loop.Result = if (outcome) |ended| (if (ended) .end else .more) else |err| switch (err) {
        error.BadSymbol => .bad_symbol,
        error.BadDistance => .bad_distance,
    };
    state.at = input.i;
    state.bits = input.bits;
    state.nbits = input.nbits;
    state.out_pos = run.out_pos;
    return @intFromEnum(result);
}
