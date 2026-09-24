//! Selects storage blocks for layout fields and provides shared errors and alignment helpers

const std = @import("std");
const validation = @import("comptime_validation.zig");
const ValueBlock = @import("blocks/value.zig").ValueBlock;
const SliceBlock = @import("blocks/slice.zig").SliceBlock;
const RaggedSliceBlock = @import("blocks/ragged_slice.zig").RaggedSliceBlock;
const PackedSlice = @import("blocks/packed_slice.zig").PackedSlice;
const Columns = @import("blocks/columnar.zig").Columns;

// The input exceeds the block's size limits, regardless of the destination buffer's size
pub const BufferSizeError = error{
    InputTooLarge,
};

pub const WriteError = BufferSizeError || error{
    // The destination buffer is too small
    NoSpaceLeft,
    // The destination buffer is not aligned for the stored type
    MisalignedBuffer,
};

pub const ViewError = error{
    // The buffer ends before the required bytes.
    // For example, ValueBlock(u32) needs four bytes, but the caller supplied three
    BufferTooSmall,
    // The bytes may be valid, but the buffer's address is not aligned for the stored type
    MisalignedBuffer,
    // The bytes do not match the block's expected structure or length.
    // ValueBlock(u32) rejects five bytes because there is an extra byte.
    // SliceBlock(u32) rejects six bytes because the final element is incomplete
    InvalidFormat,
    // A boolean is not 0 or 1, or an exhaustive enum has an undeclared tag
    InvalidValue,
};

pub const IndexError = error{
    IndexOutOfBounds,
};

/// Choose the correct block type for a given field in a user's layout schema
pub fn resolveBlockType(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info == .pointer and type_info.pointer.size == .slice) {
        validation.assertSliceHasSupportedPointerAttributes(T);
        if (comptime isSlice(type_info.pointer.child)) {
            validation.assertSliceHasSupportedPointerAttributes(type_info.pointer.child);
            return RaggedSliceBlock(@typeInfo(type_info.pointer.child).pointer.child);
        }
        return SliceBlock(type_info.pointer.child);
    }
    if (comptime isContainerType(T) and @hasDecl(T, "stash_block_info")) {
        const block_info = T.stash_block_info;
        const Expected = switch (block_info.kind) {
            .value => ValueBlock(block_info.Element),
            .slice => SliceBlock(block_info.Element),
            .ragged_slice => RaggedSliceBlock(block_info.Element),
            .packed_slice => PackedSlice(block_info.Element),
            .columnar => Columns(block_info.Element, block_info.options),
            else => @compileError("stash: unsupported block kind"),
        };
        if (T != Expected) @compileError("stash: custom block implementations are not supported");
        return T;
    }
    return ValueBlock(T);
}

fn isSlice(comptime T: type) bool {
    const type_info = @typeInfo(T);
    return type_info == .pointer and type_info.pointer.size == .slice;
}

fn isContainerType(comptime T: type) bool {
    // @hasDecl() accepts only container types
    return switch (@typeInfo(T)) {
        .@"struct",
        .@"enum",
        .@"union",
        .@"opaque",
        => true,
        else => false,
    };
}

/// Round byte_count up to the next multiple of alignment, leaving it unchanged
/// if already aligned. Return InputTooLarge if the result would overflow usize
pub fn alignForward(byte_count: usize, alignment: usize) BufferSizeError!usize {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const mask = alignment - 1;
    const with_mask = std.math.add(usize, byte_count, mask) catch return error.InputTooLarge;
    return with_mask & ~mask;
}

test "resolveBlockType() chooses the correct storage block for each supported field type" {
    const Row = extern struct { key: u64, value: i64 };
    const cases = .{
        .{ .input = u32, .expected = ValueBlock(u32) },
        .{ .input = SliceBlock(u8), .expected = SliceBlock(u8) },
        .{ .input = []const Row, .expected = SliceBlock(Row) },
        .{ .input = []Row, .expected = SliceBlock(Row) },
        .{ .input = []const []const u8, .expected = RaggedSliceBlock(u8) },
        .{ .input = []const []u32, .expected = RaggedSliceBlock(u32) },
        .{ .input = [][]const u64, .expected = RaggedSliceBlock(u64) },
        .{ .input = PackedSlice(u3), .expected = PackedSlice(u3) },
        .{ .input = Columns(Row, .{}), .expected = Columns(Row, .{}) },
    };

    inline for (cases) |case| {
        try std.testing.expectEqual(case.expected, resolveBlockType(case.input));
    }
}

test "alignForward() rounds byte counts up and rejects overflow" {
    try std.testing.expectEqual(@as(usize, 8), try alignForward(8, 8));
    try std.testing.expectEqual(@as(usize, 8), try alignForward(5, 8));
    try std.testing.expectEqual(std.math.maxInt(usize), try alignForward(std.math.maxInt(usize), 1));
    try std.testing.expectError(error.InputTooLarge, alignForward(std.math.maxInt(usize), 8));
}
