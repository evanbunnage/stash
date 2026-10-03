//! Property tests for stash layouts. Each case generates a random input for every layout below and
//! checks properties that should hold for any input, instead of hand-picking examples:
//!
//! - Sizing agrees: encodedSize(), write(), alloc(), Sizer, and initializedSize() report the same size
//! - Round trip: re-encoding what view() returns reproduces the written bytes exactly
//! - Accepted buffers are canonical: after random corruption, any buffer that view() still accepts
//!   must re-encode to exactly the same bytes. A missing validation check usually breaks this even
//!   when it doesn't crash, which a "doesn't panic" fuzzer would miss
//! - viewAssumeValid() and viewMutable() agree with view(), and all three reject misaligned buffers
//! - In-place edits through viewMutable() keep the buffer valid and canonical
//!
//! Each zig build test run uses a new seed, and zig build test --seed replays a failing run

const std = @import("std");
const stash = @import("stash");
const Allocator = std.mem.Allocator;

// Keep most generated slices short so each case is fast and covers empty and small lengths often.
// About one slice in 32 is long enough to need multi-byte counts and offsets
const max_len = 6;
const max_long_len = 300;
const corruptions_per_case = 32;

const Status = enum(u8) { pending, active, stale };
const Mode = enum(u2) { parked, driving, charging };
const Open = enum(u8) { known, _ };
const Pair = packed struct(u6) { level: u3, mode: Mode, enabled: bool };
const Header = extern struct { version: u8, status: Status, reserved: [2]u8, count: u32 };
const Record = extern struct { key: u64, value: i32, enabled: bool, status: Status, reserved: [2]u8 };
const Row = struct { id: u32, name: []const u8, ok: bool, mode: Mode, scores: []const u16, big: u64 };

/// Each layout covers different storage kinds and alignment combinations
const layouts = .{
    stash.Layout(struct { tag: u8, big: u64, small: []const u16, flag: bool, status: Status, ratio: f32 }),
    stash.Layout(struct { names: []const []const u8, groups: []const []const u64, flags: []const []const bool }),
    stash.Layout(struct {
        bits: stash.PackedSlice(bool),
        modes: stash.PackedSlice(Mode),
        small: stash.PackedSlice(i5),
        wide: stash.PackedSlice(u65),
        pairs: stash.PackedSlice(Pair),
    }),
    stash.Layout(struct { empty: extern struct {}, flags: [3]bool, records: []const Record, open: Open }),
    stash.Layout(struct { header: Header, rows: stash.Columns(Row, .{ .packed_fields = &.{ .ok, .mode } }) }),
    stash.Layout(struct {
        points: stash.Columns(struct { x: u8, y: u64 }, .{}),
        labels: stash.Columns(struct { label: []const u8 }, .{}),
        version: u16,
    }),
    stash.Layout(struct { wide: u128, pairs: []const [2]Record, codes: []const []const Status }),
    stash.Layout(struct { ones: stash.PackedSlice(u1), text: []const u8, sevens: stash.PackedSlice(u7), last: u8 }),
    stash.Layout(struct {
        flags: stash.Columns(struct { on: bool, mode: Mode, level: u3 }, .{ .packed_fields = &.{ .on, .mode, .level } }),
        tail: []const u64,
    }),
    stash.Layout(struct {
        marker: u8,
        entries: stash.Columns(struct { key: u128, flag: bool, text: []const u8, values: []const i64 }, .{}),
    }),
    stash.Layout(struct {}),
};

/// Check every layout once using inputs generated from seed
fn runCase(gpa: Allocator, seed: u64) !void {
    inline for (layouts, 0..) |Format, index| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var prng: std.Random.DefaultPrng = .init(seed ^ (index *% 0x9e3779b97f4a7c15));
        try checkLayout(Format, prng.random(), arena.allocator());
    }
}

test "layout properties hold for generated inputs and corrupted buffers" {
    // zig build test chooses a new seed each run, so CI covers different inputs over time.
    // A failed run's output includes --seed=0x..., and zig build test --seed 0x... replays it
    const base: u64 = @as(u64, std.testing.random_seed) << 32;
    for (0..300) |index| try runCase(std.testing.allocator, base | index);
}

fn checkLayout(comptime Format: type, random: std.Random, arena: Allocator) !void {
    const input = try generate(Format.Input, random, arena);

    const size = try Format.encodedSize(input);
    const encoded = try Format.alloc(arena, input);
    try std.testing.expectEqual(size, encoded.len);
    const buffer = try alignedBuffer(Format, arena, size);
    try std.testing.expectEqualSlices(u8, encoded, try Format.write(buffer, input));
    if (size > 0) try std.testing.expectError(error.NoSpaceLeft, Format.write(buffer[0 .. size - 1], input));

    try expectCanonical(Format, arena, encoded);
    try expectMisalignedRejected(Format, arena, encoded);
    if (comptime supportsSizer(Format)) try checkSizer(Format, input, size);
    if (comptime supportsInitialize(Format)) try checkInitialize(Format, arena, input, encoded);
    try checkEdits(Format, random, arena, encoded);
    for (0..corruptions_per_case) |_| try checkCorrupted(Format, random, arena, encoded);
}

// view() must accept the buffer, and re-encoding its views must reproduce the buffer exactly
fn expectCanonical(comptime Format: type, arena: Allocator, encoded: []const u8) !void {
    const checked = try Format.view(encoded);
    try std.testing.expectEqualSlices(u8, encoded, try Format.alloc(arena, try toInput(Format, arena, checked)));
    const assumed = try Format.viewAssumeValid(encoded);
    try std.testing.expectEqualSlices(u8, encoded, try Format.alloc(arena, try toInput(Format, arena, assumed)));
}

// The same valid bytes starting one byte past an aligned address must be rejected
fn expectMisalignedRejected(comptime Format: type, arena: Allocator, encoded: []const u8) !void {
    const buffer = try alignedBuffer(Format, arena, encoded.len + 1);
    const shifted = buffer[1..];
    @memcpy(shifted, encoded);
    try std.testing.expectError(error.MisalignedBuffer, Format.view(shifted));
    try std.testing.expectError(error.MisalignedBuffer, Format.viewAssumeValid(shifted));
    try std.testing.expectError(error.MisalignedBuffer, Format.viewMutable(shifted));
}

fn checkCorrupted(comptime Format: type, random: std.Random, arena: Allocator, encoded: []const u8) !void {
    const buffer = try alignedBuffer(Format, arena, encoded.len + 4 * Format.alignment);
    @memcpy(buffer[0..encoded.len], encoded);
    var len = encoded.len;
    if (random.boolean()) resizeBlock(Format, random, buffer, &len, encoded);
    for (0..random.uintAtMost(usize, 2) + 1) |_| corrupt(Format, random, buffer, &len);
    const corrupted = buffer[0..len];

    if (Format.view(corrupted)) |_| {
        try expectCanonical(Format, arena, corrupted);
        _ = try Format.viewMutable(corrupted);
    } else |err| {
        try std.testing.expectError(err, Format.viewMutable(corrupted));
    }
}

// Insert or remove bytes inside one block and update its size table entry to match. Changing whole
// multiples of the buffer alignment keeps later blocks aligned, so the result passes the layout's
// size table checks and reaches the block's own validation
fn resizeBlock(comptime Format: type, random: std.Random, buffer: []u8, len: *usize, encoded: []const u8) void {
    const ranges = (Format.inspect(encoded) catch unreachable).ranges;
    if (ranges.len == 0) return;
    const index = random.uintLessThan(usize, ranges.len);
    const range = ranges[index];
    const amount = Format.alignment * (random.uintLessThan(usize, 2) + 1);
    var new_size = range.size;
    if (random.boolean()) {
        const at = range.offset + random.uintAtMost(usize, range.size);
        std.mem.copyBackwards(u8, buffer[at + amount .. len.* + amount], buffer[at..len.*]);
        for (buffer[at..][0..amount]) |*byte| byte.* = if (random.boolean()) 0 else random.int(u8);
        len.* += amount;
        new_size += amount;
    } else {
        if (range.size < amount) return;
        const at = range.offset + random.uintAtMost(usize, range.size - amount);
        std.mem.copyForwards(u8, buffer[at .. len.* - amount], buffer[at + amount .. len.*]);
        len.* -= amount;
        new_size -= amount;
    }
    const entry = len.* - (ranges.len - index) * @sizeOf(u64);
    std.mem.writeInt(u64, buffer[entry..][0..@sizeOf(u64)], new_size, .little);
}

// Corruptions aim at the bytes most likely to slip past validation: counts, offsets, the block
// size table, lengths, and single bits
fn corrupt(comptime Format: type, random: std.Random, buffer: []u8, len: *usize) void {
    const field_count = std.meta.fields(Format.View).len;
    switch (random.uintLessThan(u8, 7)) {
        0 => if (len.* > 0) {
            buffer[random.uintLessThan(usize, len.*)] ^= @as(u8, 1) << random.int(u3);
        },
        1 => if (len.* > 0) {
            buffer[random.uintLessThan(usize, len.*)] = random.int(u8);
        },
        2 => if (len.* > 0) {
            len.* = random.uintLessThan(usize, len.*);
        },
        3 => {
            const extra = random.uintAtMost(usize, @min(8, buffer.len - len.*));
            for (buffer[len.*..][0..extra]) |*byte| byte.* = if (random.boolean()) 0 else random.int(u8);
            len.* += extra;
        },
        // Replace a u32 count or offset with a small value near the buffer size
        4 => if (len.* >= 4) {
            const offset = random.uintAtMost(usize, (len.* - 4) / 4) * 4;
            std.mem.writeInt(u32, buffer[offset..][0..4], random.uintAtMost(u32, @intCast(len.* + 2)), .little);
        },
        // Nudge a u32 by a small amount to find off-by-one checks
        5 => if (len.* >= 4) {
            const offset = random.uintAtMost(usize, (len.* - 4) / 4) * 4;
            const current = std.mem.readInt(u32, buffer[offset..][0..4], .little);
            const delta = random.uintAtMost(u32, 2) + 1;
            const next = if (random.boolean()) current +% delta else current -% delta;
            std.mem.writeInt(u32, buffer[offset..][0..4], next, .little);
        },
        // Change one entry in the block size table at the end of the buffer
        6 => if (field_count > 0 and len.* >= field_count * 8) {
            const entry = len.* - (random.uintLessThan(usize, field_count) + 1) * 8;
            std.mem.writeInt(u64, buffer[entry..][0..8], random.uintAtMost(u64, len.*), .little);
        },
        else => unreachable,
    }
}

// Write random values through every kind of mutable view, then check the buffer is still canonical
fn checkEdits(comptime Format: type, random: std.Random, arena: Allocator, encoded: []const u8) !void {
    const buffer = try alignedBuffer(Format, arena, encoded.len);
    @memcpy(buffer, encoded);
    const mutable = try Format.viewMutable(buffer);
    inline for (std.meta.fields(Format.MutableView)) |field| {
        const Element = InputElement(Format, field.name);
        const block = @field(mutable, field.name);
        switch (comptime kindOf(field.type)) {
            .value => block.* = try generate(@TypeOf(block.*), random, arena),
            .slice => if (block.len > 0) {
                block[random.uintLessThan(usize, block.len)] = try generate(Element, random, arena);
            },
            .ragged => if (block.len() > 0) {
                const child = block.get(random.uintLessThan(usize, block.len()));
                if (child.len > 0) child[random.uintLessThan(usize, child.len)] = try generate(@TypeOf(child[0]), random, arena);
            },
            .packed_slice => if (block.len() > 0) {
                block.set(random.uintLessThan(usize, block.len()), try generate(Element, random, arena));
            },
            .columns => if (block.len() > 0) {
                const row = random.uintLessThan(usize, block.len());
                inline for (std.meta.fields(Element)) |column_field| {
                    const column = block.column(@field(std.meta.FieldEnum(Element), column_field.name));
                    switch (comptime kindOf(@TypeOf(column))) {
                        .slice => column[row] = try generate(column_field.type, random, arena),
                        .packed_slice => column.set(row, try generate(column_field.type, random, arena)),
                        .ragged => {
                            const child = column.get(row);
                            if (child.len > 0) child[random.uintLessThan(usize, child.len)] = try generate(@TypeOf(child[0]), random, arena);
                        },
                        else => unreachable,
                    }
                }
            },
        }
    }
    try expectCanonical(Format, arena, buffer);
}

// Measure every Columns row with Sizer. An exact budget accepts every row, and one byte less rejects one
fn checkSizer(comptime Format: type, input: Format.Input, size: usize) !void {
    const FieldId = @typeInfo(@TypeOf(Format.Sizer.tryAppend)).@"fn".params[1].type.?;
    var row_count: usize = 0;
    inline for (.{ size, size -| 1 }, 0..) |budget, attempt| {
        var sizer: Format.Sizer = .{};
        var accepted: usize = 0;
        inline for (std.meta.fields(Format.Input)) |field| {
            if (comptime kindOf(@FieldType(Format.View, field.name)) == .columns) {
                for (@field(input, field.name)) |row| {
                    if (try sizer.tryAppend(@field(FieldId, field.name), row, .{ .max_size = budget })) accepted += 1;
                }
                if (attempt == 0) row_count += @field(input, field.name).len;
            }
        }
        if (attempt == 0) {
            try std.testing.expectEqual(row_count, accepted);
            try std.testing.expectEqual(size, try sizer.encodedSize());
        } else if (row_count > 0) {
            try std.testing.expect(accepted < row_count);
        }
    }
}

// initialize() followed by filling each slice through its mutable view must match write()
fn checkInitialize(comptime Format: type, arena: Allocator, input: Format.Input, encoded: []const u8) !void {
    var initial: Format.Init = undefined;
    inline for (std.meta.fields(Format.Init)) |field| {
        const value = @field(input, field.name);
        @field(initial, field.name) = switch (comptime kindOf(@FieldType(Format.View, field.name))) {
            .value => value,
            // The fill value is overwritten below, so any element works
            .slice => .{ .count = value.len, .value = std.mem.zeroes(@TypeOf(value[0])) },
            else => unreachable,
        };
    }
    try std.testing.expectEqual(encoded.len, try Format.initializedSize(initial));
    const buffer = try alignedBuffer(Format, arena, encoded.len);
    const initialized = try Format.initialize(buffer, initial);
    inline for (std.meta.fields(Format.Init)) |field| {
        if (comptime kindOf(@FieldType(Format.View, field.name)) == .slice) {
            @memcpy(@field(initialized.view, field.name), @field(input, field.name));
        }
    }
    try std.testing.expectEqualSlices(u8, encoded, initialized.bytes);
}

const Kind = enum { value, slice, ragged, packed_slice, columns };

// Identify a block from its view type, which differs for each storage kind
fn kindOf(comptime ViewType: type) Kind {
    return switch (@typeInfo(ViewType)) {
        .pointer => |pointer| if (pointer.size == .one) .value else .slice,
        .@"struct" => if (@hasField(ViewType, "offsets"))
            .ragged
        else if (@hasField(ViewType, "data"))
            .packed_slice
        else if (@hasField(ViewType, "row_count"))
            .columns
        else
            @compileError("unrecognized view type " ++ @typeName(ViewType)),
        else => @compileError("unrecognized view type " ++ @typeName(ViewType)),
    };
}

fn supportsSizer(comptime Format: type) bool {
    for (std.meta.fields(Format.View)) |field| {
        if (kindOf(field.type) != .value and kindOf(field.type) != .columns) return false;
    }
    return true;
}

fn supportsInitialize(comptime Format: type) bool {
    for (std.meta.fields(Format.View)) |field| {
        if (kindOf(field.type) != .value and kindOf(field.type) != .slice) return false;
    }
    return true;
}

fn InputElement(comptime Format: type, comptime name: []const u8) type {
    const Input = @FieldType(Format.Input, name);
    return if (@typeInfo(Input) == .pointer) @typeInfo(Input).pointer.child else Input;
}

// Copy every view back into an Input so it can be written again
fn toInput(comptime Format: type, arena: Allocator, view: anytype) Allocator.Error!Format.Input {
    var input: Format.Input = undefined;
    inline for (std.meta.fields(@TypeOf(view))) |field| {
        const block = @field(view, field.name);
        @field(input, field.name) = switch (comptime kindOf(field.type)) {
            .value => block.*,
            .slice => block,
            .ragged, .packed_slice, .columns => items: {
                const items = try arena.alloc(InputElement(Format, field.name), block.len());
                for (items, 0..) |*item, index| item.* = block.get(index);
                break :items items;
            },
        };
    }
    return input;
}

// Generate any valid input value, favoring boundary integers and short slices
fn generate(comptime T: type, random: std.Random, arena: Allocator) Allocator.Error!T {
    switch (@typeInfo(T)) {
        .int => return switch (random.uintLessThan(u8, 8)) {
            0 => 0,
            1 => std.math.maxInt(T),
            2 => std.math.minInt(T),
            else => random.int(T),
        },
        .bool => return random.boolean(),
        .float => return @bitCast(random.int(std.meta.Int(.unsigned, @bitSizeOf(T)))),
        .@"enum" => |info| {
            if (!info.is_exhaustive) return @enumFromInt(random.int(info.tag_type));
            const choice = random.uintLessThan(usize, info.fields.len);
            inline for (info.fields, 0..) |field, index| {
                if (index == choice) return @enumFromInt(field.value);
            }
            unreachable;
        },
        .array => |info| {
            var result: T = undefined;
            for (&result) |*item| item.* = try generate(info.child, random, arena);
            return result;
        },
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.fields) |field| @field(result, field.name) = try generate(field.type, random, arena);
            return result;
        },
        .pointer => |info| {
            const len = if (random.uintLessThan(u8, 32) == 0) random.uintAtMost(usize, max_long_len) else random.uintAtMost(usize, max_len);
            const items = try arena.alloc(info.child, len);
            for (items) |*item| item.* = try generate(info.child, random, arena);
            return items;
        },
        else => @compileError("cannot generate " ++ @typeName(T)),
    }
}

fn alignedBuffer(comptime Format: type, arena: Allocator, len: usize) Allocator.Error![]align(Format.alignment) u8 {
    return arena.alignedAlloc(u8, .fromByteUnits(Format.alignment), len);
}
