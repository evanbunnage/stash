//! Stash uses SliceBlock to represent a single slice, such as []const u32 or []Record.
//! A slice of slices, such as []const []const u8, uses RaggedSliceBlock

const std = @import("std");
const blocks = @import("../blocks.zig");
const bytes = @import("../bytes.zig");
const comptime_validation = @import("../comptime_validation.zig");
const runtime_validation = @import("../runtime_validation.zig");

pub fn SliceBlock(comptime T: type) type {
    comptime comptime_validation.assertStorable(T);
    if (@sizeOf(T) == 0) {
        @compileError("stash: slices cannot store zero-sized elements\n" ++
            "  element type '" ++ @typeName(T) ++ "' has zero size\n" ++
            "  the byte size would not tell us how many elements there are");
    }

    return struct {
        pub const stash_block_info = .{ .kind = .slice, .Element = T };
        pub const alignment = @alignOf(T);
        pub const Input = []const T;
        pub const Init = struct { count: usize, value: T };
        pub const View = []const T;
        pub const MutableView = []T;

        pub fn encodedSize(input: Input) blocks.BufferSizeError!usize {
            return std.math.mul(usize, input.len, @sizeOf(T)) catch return error.InputTooLarge;
        }

        /// Copy the elements from the input slice into the destination buffer and return
        /// the number of bytes written. The destination must be aligned for T
        pub fn encode(dest_buffer: []u8, input: Input) blocks.WriteError!usize {
            const values = try encodeMutable(dest_buffer, input);
            return values.len * @sizeOf(T);
        }

        /// Copy the elements from the input slice into the destination buffer (aligned for T).
        /// return a slice that can be used to modify the elements in place
        pub fn encodeMutable(dest_buffer: []u8, input: Input) blocks.WriteError!MutableView {
            const byte_count = try encodedSize(input);
            if (dest_buffer.len < byte_count) return error.NoSpaceLeft;
            const values = bytes.viewMutableSlice(T, dest_buffer, input.len) catch |err| switch (err) {
                error.BufferTooSmall => unreachable,
                error.MisalignedBuffer => return error.MisalignedBuffer,
            };
            @memcpy(values, input);
            return values;
        }

        pub fn initializedSize(initial_values: Init) blocks.BufferSizeError!usize {
            return std.math.mul(usize, initial_values.count, @sizeOf(T)) catch return error.InputTooLarge;
        }

        /// When you want to create elements directly in the destination buffer, use initialize().
        /// It creates initial_values.count elements, sets each one to initial_values.value, and
        /// returns a mutable slice that can be used to fill in the values.
        /// Use encode() when the elements already exist in an input slice.
        pub fn initialize(dest_buffer: []u8, initial_values: Init) blocks.WriteError!MutableView {
            const byte_count = try initializedSize(initial_values);
            if (dest_buffer.len < byte_count) return error.NoSpaceLeft;
            const values = bytes.viewMutableSlice(T, dest_buffer, initial_values.count) catch |err| switch (err) {
                error.BufferTooSmall => unreachable,
                error.MisalignedBuffer => return error.MisalignedBuffer,
            };
            @memset(values, initial_values.value);
            return values;
        }

        /// Return a slice of the stored elements after checking any boolean and enum values.
        /// The buffer must be aligned for T and contain a whole number of elements
        pub fn view(buffer: []const u8) blocks.ViewError!View {
            const values = try viewAssumeValid(buffer);
            try runtime_validation.validateValues(T, buffer, values.len);
            return values;
        }

        /// Return a slice of the stored elements after checking the buffer's size and alignment.
        /// Any boolean and enum values in the elements must already be valid. Be careful using this
        /// on values that haven't been validated somehow, if a value is corrupted it can crash
        /// your program or behave unexpectedly
        pub fn viewAssumeValid(buffer: []const u8) blocks.ViewError!View {
            if (buffer.len % @sizeOf(T) != 0) return error.InvalidFormat;
            return bytes.viewSlice(T, buffer, buffer.len / @sizeOf(T));
        }

        /// Check the stored elements and return a slice that can be used to modify them in place
        pub fn viewMutable(buffer: []u8) blocks.ViewError!MutableView {
            const values = try view(buffer);
            return bytes.viewMutableSlice(T, buffer, values.len);
        }
    };
}

test "SliceBlock encode() writes consecutive elements without changing trailing bytes" {
    const Block = SliceBlock(u16);
    const items = [_]u16{ 0x0102, 0x0304 };
    var buffer: [5]u8 align(@alignOf(u16)) = .{99} ** 5;
    try std.testing.expectEqual(4, try Block.encodedSize(&items));
    try std.testing.expectEqual(4, try Block.encode(&buffer, &items));
    // There is no header, and the byte after the elements should not be changed
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 4, 3, 99 }, &buffer);
    const values = try Block.view(buffer[0..4]);
    try std.testing.expectEqual(@intFromPtr(&buffer), @intFromPtr(values.ptr));
    try std.testing.expectEqualSlices(u16, &items, values);
}

test "SliceBlock encodeMutable() and viewMutable() modify the stored records in place" {
    const Row = extern struct { key: u64, value: i64 };
    const Block = SliceBlock(Row);
    const input = [_]Row{ .{ .key = 1, .value = -1 }, .{ .key = 2, .value = -2 } };
    const byte_count = @sizeOf(@TypeOf(input));
    var buffer: [byte_count + 1]u8 align(Block.alignment) = @splat(99);
    try std.testing.expectEqual(byte_count, try Block.encodedSize(&input));
    const values = try Block.encodeMutable(&buffer, &input);
    try std.testing.expectEqualDeep(&input, values);
    values[0].value = -3;
    const mutable = try Block.viewMutable(buffer[0..byte_count]);
    try std.testing.expectEqual(@as(i64, -3), mutable[0].value);
    mutable[1].key = 4;
    const expected = [_]Row{ .{ .key = 1, .value = -3 }, .{ .key = 4, .value = -2 } };
    try std.testing.expectEqualDeep(&expected, try Block.view(buffer[0..byte_count]));
    try std.testing.expectEqual(@as(u8, 99), buffer[byte_count]);
}

test "SliceBlock rejects a destination buffer that is too small" {
    const Block = SliceBlock(u16);
    var buffer: [4]u8 align(@alignOf(u16)) = .{99} ** 4;
    for (0..4) |length| {
        try std.testing.expectError(error.NoSpaceLeft, Block.encode(buffer[0..length], &.{ 1, 2 }));
        try std.testing.expectError(
            error.NoSpaceLeft,
            Block.encodeMutable(buffer[0..length], &.{ 1, 1 }),
        );
    }
    try std.testing.expectEqualSlices(u8, &.{ 99, 99, 99, 99 }, &buffer);
}

test "SliceBlock views reject a buffer that ends in the middle of an element" {
    var buffer: [5]u8 align(@alignOf(u16)) = .{0} ** 5;
    for ([_]usize{ 1, 3, 5 }) |length| {
        try std.testing.expectError(error.InvalidFormat, SliceBlock(u16).view(buffer[0..length]));
        try std.testing.expectError(
            error.InvalidFormat,
            SliceBlock(u16).viewMutable(buffer[0..length]),
        );
    }
}

test "SliceBlock rejects misaligned buffers without writing" {
    const Block = SliceBlock(u16);
    var buffer: [5]u8 align(@alignOf(u16)) = .{99} ** 5;
    try std.testing.expectError(error.MisalignedBuffer, Block.encode(buffer[1..], &.{ 1, 2 }));
    try std.testing.expectError(
        error.MisalignedBuffer,
        Block.encodeMutable(buffer[1..], &.{ 1, 1 }),
    );
    try std.testing.expectError(error.MisalignedBuffer, Block.view(buffer[1..]));
    try std.testing.expectError(error.MisalignedBuffer, Block.viewMutable(buffer[1..]));
    try std.testing.expectEqualSlices(u8, &.{ 99, 99, 99, 99, 99 }, &buffer);
}

test "SliceBlock view() and viewMutable() check boolean and enum fields in every element" {
    const Status = enum(u8) { pending, complete };
    const Item = extern struct { status: Status, enabled: bool };
    const Block = SliceBlock(Item);
    var buffer = [_]u8{ 0, 1, 1, 0 };
    try std.testing.expectEqual(2, (try Block.view(&buffer)).len);
    // Change each enum or boolean byte in turn, including those in the second element
    for (0..buffer.len) |index| {
        const original = buffer[index];
        buffer[index] = 2;
        try std.testing.expectError(error.InvalidValue, Block.view(&buffer));
        try std.testing.expectError(error.InvalidValue, Block.viewMutable(&buffer));
        buffer[index] = original;
    }
}

test "SliceBlock accepts undeclared tags in non-exhaustive enums" {
    const NonExhaustiveStatus = enum(u8) { pending, _ };
    const buffer = [_]u8{ 0, 250 };
    const values = try SliceBlock(NonExhaustiveStatus).view(&buffer);
    try std.testing.expectEqual(2, values.len);
    try std.testing.expectEqual(@as(u8, 250), @intFromEnum(values[1]));
}

test "SliceBlock supports an empty slice" {
    const Block = SliceBlock(u32);
    var buffer: [0]u8 align(@alignOf(u32)) = .{};
    const input: Block.Input = &.{};
    const initial_values: Block.Init = .{ .count = 0, .value = 7 };
    try std.testing.expectEqual(0, try Block.initializedSize(initial_values));
    try std.testing.expectEqual(0, (try Block.initialize(&buffer, initial_values)).len);
    try std.testing.expectEqual(0, try Block.encodedSize(&.{}));
    try std.testing.expectEqual(0, try Block.encode(&buffer, &.{}));
    try std.testing.expectEqual(0, (try Block.encodeMutable(&buffer, input)).len);
    try std.testing.expectEqual(0, (try Block.view(&buffer)).len);
    try std.testing.expectEqual(0, (try Block.viewMutable(&buffer)).len);
}

test "SliceBlock viewAssumeValid() still checks the buffer size and alignment" {
    const Status = enum(u16) { pending, complete };
    const Block = SliceBlock(Status);
    const buffer: [5]u8 align(@alignOf(Status)) = .{ 0, 0, 1, 0, 0 };
    try std.testing.expectEqualSlices(
        Status,
        &.{ .pending, .complete },
        try Block.viewAssumeValid(buffer[0..4]),
    );
    try std.testing.expectError(error.InvalidFormat, Block.viewAssumeValid(&buffer));
    try std.testing.expectError(error.MisalignedBuffer, Block.viewAssumeValid(buffer[1..]));
}

test "SliceBlock initialize() fills each record with the supplied value in the destination buffer" {
    const Status = enum(u8) { pending, complete };
    const Record = extern struct { status: Status, enabled: bool, count: u16 };
    const Block = SliceBlock(Record);
    const initial: Record = .{ .status = .complete, .enabled = true, .count = 7 };
    var buffer: [9]u8 align(Block.alignment) = @splat(99);
    const initial_values: Block.Init = .{ .count = 2, .value = initial };
    try std.testing.expectEqual(8, try Block.initializedSize(initial_values));
    const values = try Block.initialize(&buffer, initial_values);
    try std.testing.expectEqualDeep(&[_]Record{ initial, initial }, values);
    try std.testing.expectEqual(@as(u8, 99), buffer[8]);
    values[1].count = 12;
    try std.testing.expectEqual(@as(u16, 12), (try Block.view(buffer[0..8]))[1].count);
}

test "SliceBlock initialize() leaves the destination unchanged when sizing or alignment checks fail" {
    const Block = SliceBlock(u32);
    var buffer: [9]u8 align(Block.alignment) = @splat(99);
    const initial: Block.Init = .{ .count = 2, .value = 7 };
    try std.testing.expectError(error.NoSpaceLeft, Block.initialize(buffer[0..7], initial));
    try std.testing.expectError(error.MisalignedBuffer, Block.initialize(buffer[1..], initial));
    // Multiplying this count by the element size would overflow usize
    try std.testing.expectError(error.InputTooLarge, Block.initialize(&buffer, .{
        .count = std.math.maxInt(usize) / @sizeOf(u32) + 1,
        .value = 0,
    }));
    try std.testing.expect(std.mem.allEqual(u8, &buffer, 99));
}
