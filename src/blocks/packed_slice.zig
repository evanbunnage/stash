//! Use PackedSlice in a layout to store elements using their compact bit widths rather than whole bytes.
//! For example: eight u3 elements need three bytes of data instead of eight.
//! However, note that we need to store the number of elements in order to correctly parse
//! the values later. We use a u32 for this.
//!
//! So eight u3 elements really uses (8*3) + 32 = 56 bits. That's still 1 bit savings per element, but just
//! note that this is approach best used with larger element counts where the u32 and additional compute overhead
//! is amoritized.
//!
//! So far we haven't run into a use case where supporting smaller count integers warrants the
//! extra complexity.
//!
//! Unlike SliceBlock, packed elements can share a byte, so get() extracts their bits
//! and returns a value rather than a pointer into the buffer

const std = @import("std");
const blocks = @import("../blocks.zig");
const bytes = @import("../bytes.zig");
const comptime_validation = @import("../comptime_validation.zig");
const runtime_validation = @import("../runtime_validation.zig");

pub fn PackedSlice(comptime T: type) type {
    comptime assertPackable(T);

    const header_byte_count = @sizeOf(u32);

    return struct {
        pub const stash_block_info = .{ .kind = .packed_slice, .Element = T };
        pub const alignment = @alignOf(u32);
        pub const Input = []const T;

        pub const View = struct {
            data: []const u8,
            count: usize,

            pub fn len(self: View) usize {
                return self.count;
            }

            /// Return the element by value, not by reference
            pub fn get(self: View, index: usize) blocks.IndexError!T {
                if (index >= self.count) return error.IndexOutOfBounds;
                return readElement(T, self.data, index);
            }
        };

        pub const needs_value_validation = runtime_validation.needsPackedValueValidation(T);

        /// Return the number of bytes needed for the element count and packed elements
        pub fn encodedSize(input: Input) blocks.BufferSizeError!usize {
            return std.math.add(usize, header_byte_count, try packedByteCount(T, input.len)) catch return error.InputTooLarge;
        }

        /// Copy the elements into the destination buffer as packed bits after a u32 element count,
        /// and return the number of bytes written
        pub fn encode(dest_buffer: []u8, input: Input) blocks.WriteError!usize {
            const packed_byte_count = try packedByteCount(T, input.len);
            const byte_count = std.math.add(usize, header_byte_count, packed_byte_count) catch return error.InputTooLarge;
            if (dest_buffer.len < byte_count) return error.NoSpaceLeft;

            bytes.writeValue(u32, dest_buffer[0..@sizeOf(u32)], @intCast(input.len));
            const packed_bytes = dest_buffer[header_byte_count..byte_count];
            // Unused bits in the last byte must stay zero
            @memset(packed_bytes, 0);
            for (input, 0..) |item, index| writeElement(T, packed_bytes, index, item);
            return byte_count;
        }

        /// Return a view after checking the buffer format and stored enum tags
        pub fn view(buffer: []const u8) blocks.ViewError!View {
            const result = try viewAssumeValid(buffer);
            if (comptime needs_value_validation) {
                for (0..result.count) |index| try validateElement(T, result.data, index);
            }
            return result;
        }

        /// Check the buffer's size and unused bits without validating enum tags
        pub fn viewAssumeValid(buffer: []const u8) blocks.ViewError!View {
            if (buffer.len < header_byte_count) return error.BufferTooSmall;
            const count = bytes.copyValue(u32, buffer) catch unreachable;
            const packed_byte_count = packedByteCount(T, count) catch return error.InvalidFormat;
            const end = std.math.add(usize, header_byte_count, packed_byte_count) catch return error.InvalidFormat;
            if (buffer.len < end) return error.BufferTooSmall;
            if (buffer.len != end) return error.InvalidFormat;
            const packed_bytes = buffer[header_byte_count..end];
            try validateRegionPadding(T, packed_bytes, count);
            return .{ .data = packed_bytes, .count = count };
        }
    };
}

fn unsignedIntegerType(comptime T: type) type {
    return @Int(.unsigned, @bitSizeOf(T));
}

/// Return how many bytes the packed values occupy.
/// For example, three u3 values need 9 bits, which takes two bytes.
/// The four-byte element count is not included
pub fn packedByteCount(comptime T: type, count: usize) blocks.BufferSizeError!usize {
    if (count > std.math.maxInt(u32)) return error.InputTooLarge;
    const total_bits = std.math.mul(usize, count, @bitSizeOf(T)) catch return error.InputTooLarge;
    return total_bits / 8 + @intFromBool(total_bits % 8 != 0);
}

/// Check that unused bits in the final byte of the packed values are zero.
/// For example, one u3 value uses the lowest three bits of its byte and the remaining five bits must be zero
pub fn validateRegionPadding(comptime T: type, packed_bytes: []const u8, count: usize) error{InvalidFormat}!void {
    const total_bits = std.math.mul(usize, count, @bitSizeOf(T)) catch return error.InvalidFormat;
    const used_bits = total_bits % 8;
    if (used_bits == 0) return;

    const allowed: u8 = @intCast((@as(u16, 1) << @intCast(used_bits)) - 1);
    if (packed_bytes[packed_bytes.len - 1] & ~allowed != 0) return error.InvalidFormat;
}

pub fn writeElement(comptime T: type, packed_bytes: []u8, index: usize, value: T) void {
    std.mem.writePackedInt(unsignedIntegerType(T), packed_bytes, index * @bitSizeOf(T), toBits(T, value), .little);
}

fn readElement(comptime T: type, packed_bytes: []const u8, index: usize) T {
    return fromBits(T, std.mem.readPackedInt(unsignedIntegerType(T), packed_bytes, index * @bitSizeOf(T), .little));
}

/// Check that any exhaustive enums in the element contain declared tags.
pub fn validateElement(comptime T: type, packed_bytes: []const u8, index: usize) error{InvalidValue}!void {
    const raw = std.mem.readPackedInt(unsignedIntegerType(T), packed_bytes, index * @bitSizeOf(T), .little);
    runtime_validation.validatePackedValue(T, raw, 0) catch |err| switch (err) {
        error.InvalidBufferSize => unreachable,
        error.InvalidValue => return error.InvalidValue,
    };
}

// Reinterpret the value as an unsigned integer so packed writes preserve its bits
fn toBits(comptime T: type, value: T) unsignedIntegerType(T) {
    return switch (@typeInfo(T)) {
        .int => @bitCast(value),
        .bool => @intFromBool(value),
        .@"enum" => @bitCast(@intFromEnum(value)),
        .@"struct" => @bitCast(value),
        else => unreachable,
    };
}

// Interpret previously validated bits as T
fn fromBits(comptime T: type, raw: unsignedIntegerType(T)) T {
    return switch (@typeInfo(T)) {
        .int => @bitCast(raw),
        .bool => raw != 0,
        .@"enum" => |enum_info| @enumFromInt(@as(enum_info.tag_type, @bitCast(raw))),
        .@"struct" => @bitCast(raw),
        else => unreachable,
    };
}

/// Check that T is a supported type and packing saves space compared with storing whole values
pub fn assertPackable(comptime T: type) void {
    @setEvalBranchQuota(std.math.maxInt(u32));
    const supported = switch (@typeInfo(T)) {
        .int, .bool, .@"enum" => true,
        .@"struct" => |struct_info| struct_info.layout == .@"packed",
        else => false,
    };
    if (!supported) {
        @compileError("stash: PackedSlice supports only integers, bools, enums, and packed structs\n" ++
            "  received '" ++ @typeName(T) ++ "'");
    }
    comptime comptime_validation.assertStorablePackedField(T, @typeName(T));
    if (@bitSizeOf(T) == 0) {
        @compileError("stash: PackedSlice elements must have nonzero bit width\n" ++
            "  element type '" ++ @typeName(T) ++ "' has zero bits");
    }
    if (@bitSizeOf(T) >= 8 * @sizeOf(T)) {
        @compileError("stash: PackedSlice requires packing to save space\n" ++
            "  the bits of '" ++ @typeName(T) ++ "' already fill its storage\n" ++
            "  fix: use []const T instead");
    }
}

test "PackedSlice encode() writes the element count and packed bits in little-endian order" {
    const values = [_]u3{ 1, 2, 7 };
    const expected = [_]u8{ 3, 0, 0, 0, 0xd1, 0x01 };
    var buffer: [expected.len]u8 align(PackedSlice(u3).alignment) = undefined;
    const written = try PackedSlice(u3).encode(&buffer, &values);
    try std.testing.expectEqual(expected.len, written);
    try std.testing.expectEqualSlices(u8, &expected, &buffer);
    const view = try PackedSlice(u3).view(&buffer);
    for (values, 0..) |value, index| try std.testing.expectEqual(value, (try view.get(index)));
}

test "PackedSlice preserves values whose bits cross byte boundaries" {
    inline for (.{ u1, u3, u7, u9, u15, u33, u65 }) |T| {
        const Block = PackedSlice(T);
        // Odd widths visit every bit offset. Seventeen elements cross two eight-element cycles
        var values: [17]T = undefined;
        for (&values, 0..) |*value, index| {
            value.* = switch (index % 3) {
                0 => 0,
                1 => std.math.maxInt(T),
                else => if (@bitSizeOf(T) < @bitSizeOf(usize)) @truncate(index) else @intCast(index),
            };
        }
        var buffer: [160]u8 = @splat(0xa5);
        for (0..values.len + 1) |count| {
            @memset(&buffer, 0xa5);
            const written = try Block.encode(&buffer, values[0..count]);
            try std.testing.expectEqual(4 + (count * @bitSizeOf(T) + 7) / 8, written);
            try std.testing.expectEqual(try Block.encodedSize(values[0..count]), written);
            try std.testing.expect(std.mem.allEqual(u8, buffer[written..], 0xa5));
            const view = try Block.view(buffer[0..written]);
            try std.testing.expectEqual(count, view.len());
            for (values[0..count], 0..) |expected, index| {
                try std.testing.expectEqual(expected, try view.get(index));
            }
        }
    }
}

test "PackedSlice view() rejects an undeclared enum tag" {
    const Status = enum(u3) { pending, complete, failed };
    const Block = PackedSlice(Status);

    const input = [_]Status{ .pending, .complete, .failed };
    var buffer: [32]u8 align(Block.alignment) = undefined;
    const written = try Block.encode(&buffer, &input);

    // Overwrite the second element (bits 3–5) with the invalid tag 5
    std.mem.writePackedInt(u3, buffer[@sizeOf(u32)..written], 3, 5, .little);
    try std.testing.expectError(error.InvalidValue, Block.view(buffer[0..written]));
}

test "PackedSlice views reject trailing bytes and nonzero unused bits" {
    const Block = PackedSlice(u3);
    var buffer = [_]u8{ 1, 0, 0, 0, 5, 0 };
    try std.testing.expectEqual(@as(u3, 5), try (try Block.view(buffer[0..5])).get(0));
    try std.testing.expectError(error.InvalidFormat, Block.view(&buffer));
    try std.testing.expectError(error.InvalidFormat, Block.viewAssumeValid(&buffer));
    for (3..8) |bit| {
        buffer[4] = 5 | (@as(u8, 1) << @intCast(bit));
        try std.testing.expectError(error.InvalidFormat, Block.view(buffer[0..5]));
        try std.testing.expectError(error.InvalidFormat, Block.viewAssumeValid(buffer[0..5]));
    }
}

test "PackedSlice rejects a buffer too small for the maximum element count without overflowing" {
    const Block = PackedSlice(u1);
    var buffer: [@sizeOf(u32)]u8 align(Block.alignment) = undefined;
    bytes.writeValue(u32, &buffer, std.math.maxInt(u32));

    try std.testing.expectError(error.BufferTooSmall, Block.view(&buffer));
}

test "PackedSlice stores booleans and fully declared enums without needing value validation" {
    const AllTagsDeclared = enum(u2) { a, b, c, d };
    inline for (.{ bool, AllTagsDeclared }) |T| {
        const Block = PackedSlice(T);
        try std.testing.expect(!Block.needs_value_validation);
        const input = if (T == bool)
            [_]bool{ true, false, true, true, false }
        else
            [_]AllTagsDeclared{ .a, .b, .c, .d, .a };
        var buffer: [6]u8 = undefined;
        const written = try Block.encode(&buffer, &input);
        const view = try Block.view(buffer[0..written]);
        for (input, 0..) |expected, index| {
            try std.testing.expectEqual(expected, try view.get(index));
        }
    }
}

test "PackedSlice supports an empty slice" {
    var buffer: [4]u8 = .{99} ** 4;
    const Block = PackedSlice(u3);
    try std.testing.expectEqual(4, try Block.encodedSize(&.{}));
    try std.testing.expectEqual(4, try Block.encode(&buffer, &.{}));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &buffer);
    try std.testing.expectEqual(0, (try Block.view(&buffer)).len());
}

test "PackedSlice views reject an incomplete element count or packed data" {
    const Block = PackedSlice(u3);
    var buffer: [6]u8 = undefined;
    _ = try Block.encode(&buffer, &.{ 1, 2, 7 });
    for (0..buffer.len) |length| {
        try std.testing.expectError(error.BufferTooSmall, Block.view(buffer[0..length]));
        try std.testing.expectError(error.BufferTooSmall, Block.viewAssumeValid(buffer[0..length]));
    }
}

test "PackedSlice encode() leaves a destination buffer unchanged when it is too small" {
    var buffer: [6]u8 = .{99} ** 6;
    for (0..buffer.len) |length| {
        try std.testing.expectError(
            error.NoSpaceLeft,
            PackedSlice(u3).encode(buffer[0..length], &.{ 1, 2, 7 }),
        );
    }
    try std.testing.expectEqualSlices(u8, &.{ 99, 99, 99, 99, 99, 99 }, &buffer);
}

test "PackedSlice accepts unaligned buffers and leaves surrounding bytes unchanged" {
    const Block = PackedSlice(u3);
    var buffer: [8]u8 align(4) = .{99} ** 8;
    // Packed access copies bits, so starting one byte after an aligned address is allowed
    const written = try Block.encode(buffer[1..], &.{ 1, 2, 7 });
    for ([_]Block.View{
        try Block.view(buffer[1..][0..written]),
        try Block.viewAssumeValid(buffer[1..][0..written]),
    }) |view| {
        try std.testing.expectEqual(@as(u3, 7), try view.get(2));
    }
    try std.testing.expectEqualSlices(u8, &.{ 99, 3, 0, 0, 0, 0xd1, 1, 99 }, &buffer);
}

test "PackedSlice preserves signed integers and signed enum tags" {
    const Status = enum(i3) { failed = -4, pending = -1, complete = 3 };
    inline for (.{ i3, Status }) |T| {
        const input = if (T == i3) [_]i3{ -4, -1, 3 } else [_]Status{ .failed, .pending, .complete };
        var buffer: [6]u8 = undefined;
        _ = try PackedSlice(T).encode(&buffer, &input);
        const view = try PackedSlice(T).view(&buffer);
        for (input, 0..) |expected, index| try std.testing.expectEqual(
            expected,
            (try view.get(index)),
        );
    }
}

test "PackedSlice accepts undeclared tags in non-exhaustive enums" {
    const NonExhaustiveStatus = enum(u3) { pending = 0, _ };
    var buffer: [5]u8 = undefined;
    _ = try PackedSlice(NonExhaustiveStatus).encode(&buffer, &.{@enumFromInt(7)});
    try std.testing.expectEqual(
        @as(u3, 7),
        @intFromEnum(try (try PackedSlice(NonExhaustiveStatus).view(&buffer)).get(0)),
    );
}

test "PackedSlice view() checks nested enum fields beyond bit 64 in later elements" {
    const Status = enum(u2) { pending = 0, complete = 2 };
    const Settings = packed struct { enabled: bool, status: Status };
    const Record = packed struct { number: u64, settings: Settings };
    const input = [_]Record{
        .{ .number = 123, .settings = .{ .enabled = true, .status = .complete } },
        .{ .number = 456, .settings = .{ .enabled = false, .status = .pending } },
    };
    var buffer: [21]u8 = undefined;
    _ = try PackedSlice(Record).encode(&buffer, &input);
    const view = try PackedSlice(Record).view(&buffer);
    for (input, 0..) |expected, index| try std.testing.expectEqual(expected, (try view.get(index)));
    // The second record starts at bit 67, and its enum starts another 65 bits later
    std.mem.writePackedInt(u2, buffer[4..], 67 + 65, 1, .little);
    try std.testing.expectError(error.InvalidValue, PackedSlice(Record).view(&buffer));
}

test "packedByteCount() rejects counts above u32 and bit counts that overflow usize" {
    // Execute these expectations during cross-compilation too
    comptime {
        try std.testing.expectEqual(
            @as(usize, std.math.maxInt(u32) / 8 + 1),
            try packedByteCount(u1, std.math.maxInt(u32)),
        );
        if (@bitSizeOf(usize) > 32) {
            try std.testing.expectError(
                error.InputTooLarge,
                packedByteCount(u1, @as(usize, std.math.maxInt(u32)) + 1),
            );
        } else {
            try std.testing.expectError(
                error.InputTooLarge,
                packedByteCount(u3, std.math.maxInt(u32)),
            );
        }
    }
}

test "PackedSlice get() rejects an index at or beyond the element count" {
    const Block = PackedSlice(u3);
    var buffer: [32]u8 align(Block.alignment) = undefined;
    const written = try Block.encode(&buffer, &.{ 1, 2 });
    const view = try Block.view(buffer[0..written]);
    for ([_]usize{ view.len(), view.len() + 1, std.math.maxInt(usize) }) |index| {
        try std.testing.expectError(error.IndexOutOfBounds, view.get(index));
    }

    const empty_written = try Block.encode(&buffer, &.{});
    const empty_view = try Block.view(buffer[0..empty_written]);
    try std.testing.expectError(error.IndexOutOfBounds, empty_view.get(0));
}
