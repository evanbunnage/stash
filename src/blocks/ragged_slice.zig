//! Stash uses RaggedSliceBlock to represent a slice of slices of arbitrary lengths, such as []const []const u8
//! for a slice of strings.
//! We store all the child elements together contiguously and use an offset table to keep track
//! of where each child starts and ends.
//!
//! For example, { "ab", "", "c" } becomes "abc" with offsets { 0, 2, 2, 3 }.
//! u32s are used to store the number of child slices and their offsets

const std = @import("std");
const blocks = @import("../blocks.zig");
const bytes = @import("../bytes.zig");
const comptime_validation = @import("../comptime_validation.zig");
const runtime_validation = @import("../runtime_validation.zig");

const ViewMode = enum { read_only, mutable };

pub fn RaggedSliceBlock(comptime T: type) type {
    comptime comptime_validation.assertStorable(T);
    if (@sizeOf(T) == 0) @compileError("stash: ragged slices do not support zero-sized elements\n" ++
        "  element type '" ++ @typeName(T) ++ "' has zero size");

    return struct {
        pub const stash_block_info = .{ .kind = .ragged_slice, .Element = T };
        pub const alignment = @max(@alignOf(u32), @alignOf(T));
        pub const Input = []const []const T;

        pub const View = ViewType(.read_only);
        pub const MutableView = ViewType(.mutable);

        fn ViewType(comptime view_mode: ViewMode) type {
            return struct {
                offsets: []const u32,
                values: if (view_mode == .mutable) []T else []const T,

                /// Return the number of child slices
                pub fn len(self: @This()) usize {
                    return self.offsets.len - 1;
                }

                /// Return a child slice that points into the buffer without copying its elements.
                /// Return IndexOutOfBounds if index is at or beyond len()
                pub fn get(self: @This(), index: usize) blocks.IndexError!(if (view_mode == .mutable) []T else []const T) {
                    if (index >= self.len()) return error.IndexOutOfBounds;
                    const start: usize = self.offsets[index];
                    const end: usize = self.offsets[index + 1];
                    return self.values[start..end];
                }
            };
        }

        /// Return the number of bytes needed for the child count, offsets, padding, and elements
        pub fn encodedSize(children: Input) blocks.BufferSizeError!usize {
            return (try layoutFor(T, children)).end;
        }

        /// Copy the child slices into the destination buffer with their count and offsets,
        /// and return the number of bytes written. The buffer must meet this block's alignment
        /// requirement
        pub fn encode(dest_buffer: []u8, children: Input) blocks.WriteError!usize {
            var element_count: usize = 0;
            for (children) |child| {
                element_count = std.math.add(usize, element_count, child.len) catch return error.InputTooLarge;
            }

            var writer = try RaggedSliceWriter(T).init(dest_buffer, children.len, element_count);
            for (children) |child| writer.append(child);
            return writer.finish();
        }

        /// Validate the buffer and return mutable child slices without exposing writable offsets
        pub fn viewMutable(buffer: []u8) blocks.ViewError!MutableView {
            const checked = try view(buffer);
            // Only the elements become writable. Both slices point into the caller's mutable buffer
            return .{ .offsets = checked.offsets, .values = @constCast(checked.values) };
        }

        /// Return a view, validating that the offset values are sensible and that boolean and enum values are valid
        pub fn view(buffer: []const u8) blocks.ViewError!View {
            const result = try viewAssumeValid(buffer);
            if (result.offsets[0] != 0) return error.InvalidFormat;
            var previous_offset: u32 = 0;
            for (result.offsets) |offset| {
                if (offset < previous_offset or offset > result.values.len) return error.InvalidFormat;
                previous_offset = offset;
            }
            if (previous_offset != result.values.len) return error.InvalidFormat;
            try runtime_validation.validateValues(T, std.mem.sliceAsBytes(result.values), result.values.len);
            return result;
        }

        /// Check the buffer's size, alignment, and padding without scanning the offsets or elements.
        /// The offsets and any boolean or enum values must already be valid
        pub fn viewAssumeValid(buffer: []const u8) blocks.ViewError!View {
            if (buffer.len < @sizeOf(u32)) return error.BufferTooSmall;
            const child_count = try bytes.copyValue(u32, buffer);
            const prefix = prefixLayout(T, child_count) catch return error.InvalidFormat;
            if (prefix.values_offset > buffer.len) return error.BufferTooSmall;

            const offsets = try bytes.viewSlice(
                u32,
                buffer[@sizeOf(u32)..prefix.offsets_end],
                prefix.offset_count,
            );
            if (!std.mem.allEqual(u8, buffer[prefix.offsets_end..prefix.values_offset], 0)) {
                return error.InvalidFormat;
            }

            const values_bytes = buffer[prefix.values_offset..];
            if (values_bytes.len % @sizeOf(T) != 0) return error.InvalidFormat;
            const element_count = values_bytes.len / @sizeOf(T);
            if (element_count > std.math.maxInt(u32)) return error.InvalidFormat;
            const values = try bytes.viewSlice(T, values_bytes, element_count);

            return .{ .offsets = offsets, .values = values };
        }
    };
}

const EncodedLayout = struct {
    offsets_end: usize,
    values_offset: usize,
    end: usize,
};

const PrefixLayout = struct {
    offset_count: usize,
    offsets_end: usize,
    values_offset: usize,
};

// Find where the offset table ends and the aligned values begin
fn prefixLayout(comptime T: type, child_count: usize) blocks.BufferSizeError!PrefixLayout {
    if (child_count > std.math.maxInt(u32)) return error.InputTooLarge;
    const offset_count = std.math.add(usize, child_count, 1) catch return error.InputTooLarge;
    const offsets_bytes = std.math.mul(usize, offset_count, @sizeOf(u32)) catch return error.InputTooLarge;
    const offsets_end = std.math.add(usize, @sizeOf(u32), offsets_bytes) catch return error.InputTooLarge;
    const values_offset = blocks.alignForward(offsets_end, @alignOf(T)) catch return error.InputTooLarge;
    return .{
        .offset_count = offset_count,
        .offsets_end = offsets_end,
        .values_offset = values_offset,
    };
}

/// Use the child count to size the offset table and the total element count to size the values
pub fn layoutFromCounts(
    comptime T: type,
    child_count: usize,
    element_count: usize,
) blocks.BufferSizeError!EncodedLayout {
    if (element_count > std.math.maxInt(u32)) return error.InputTooLarge;
    const prefix = try prefixLayout(T, child_count);
    const values_bytes = std.math.mul(usize, element_count, @sizeOf(T)) catch return error.InputTooLarge;
    const end = std.math.add(usize, prefix.values_offset, values_bytes) catch return error.InputTooLarge;
    return .{
        .offsets_end = prefix.offsets_end,
        .values_offset = prefix.values_offset,
        .end = end,
    };
}

// Sum the child lengths to calculate the space needed for their offsets and elements
fn layoutFor(comptime T: type, children: []const []const T) blocks.BufferSizeError!EncodedLayout {
    var element_count: usize = 0;
    for (children) |child| {
        element_count = std.math.add(usize, element_count, child.len) catch return error.InputTooLarge;
    }
    return layoutFromCounts(T, children.len, element_count);
}

// Return the byte position of an entry in the offset table
fn offsetPosition(index: usize) usize {
    return @sizeOf(u32) + index * @sizeOf(u32);
}

/// Use this writer to store child slices + their offsets
/// init() needs the number of child slices to size the offset table, and the total
/// number of elements in those slices to reserve space for their data.
/// Call append() for each child slice, then finish() to write the final end offset
pub fn RaggedSliceWriter(comptime T: type) type {
    return struct {
        dest_buffer: []u8,
        values: []T,
        child_count: usize,
        element_count: usize,
        element_index: usize = 0,
        child_index: usize = 0,

        /// Prepare space for child_count slices containing element_count elements in total
        pub fn init(
            dest_buffer: []u8,
            child_count: usize,
            element_count: usize,
        ) blocks.WriteError!@This() {
            const encoded = try layoutFromCounts(T, child_count, element_count);
            if (encoded.end > dest_buffer.len) return error.NoSpaceLeft;
            if (@intFromPtr(dest_buffer.ptr) % RaggedSliceBlock(T).alignment != 0) return error.MisalignedBuffer;
            const values = bytes.viewMutableSlice(
                T,
                dest_buffer[encoded.values_offset..encoded.end],
                element_count,
            ) catch |err| switch (err) {
                error.BufferTooSmall => unreachable,
                error.MisalignedBuffer => return error.MisalignedBuffer,
            };
            bytes.writeValue(u32, dest_buffer[0..@sizeOf(u32)], @intCast(child_count));
            @memset(dest_buffer[encoded.offsets_end..encoded.values_offset], 0);
            return .{
                .dest_buffer = dest_buffer,
                .values = values,
                .child_count = child_count,
                .element_count = element_count,
            };
        }

        /// Copy the next child slice into the buffer and record its starting offset.
        /// The number of slices and total elements must stay within the counts supplied to init()
        pub fn append(self: *@This(), child: []const T) void {
            std.debug.assert(self.child_index < self.child_count);
            std.debug.assert(child.len <= self.element_count - self.element_index);
            bytes.writeValue(
                u32,
                self.dest_buffer[offsetPosition(self.child_index)..][0..@sizeOf(u32)],
                @intCast(self.element_index),
            );
            @memcpy(self.values[self.element_index..][0..child.len], child);
            self.element_index += child.len;
            self.child_index += 1;
        }

        /// Record where the last slice ends and return the number of bytes written.
        /// All slices and elements counted in init() must have been appended first
        pub fn finish(self: *@This()) usize {
            std.debug.assert(self.child_index == self.child_count);
            std.debug.assert(self.element_index == self.element_count);
            bytes.writeValue(
                u32,
                self.dest_buffer[offsetPosition(self.child_index)..][0..@sizeOf(u32)],
                @intCast(self.element_index),
            );
            return @intFromPtr(self.values.ptr) - @intFromPtr(self.dest_buffer.ptr) + self.values.len * @sizeOf(T);
        }
    };
}

test "RaggedSliceBlock encode() writes the child count, offsets, and elements without changing trailing bytes" {
    const children = [_][]const u8{ "ab", "c" };
    const expected = [_]u8{
        2,   0,   0,   0,
        0,   0,   0,   0,
        2,   0,   0,   0,
        3,   0,   0,   0,
        'a', 'b', 'c',
    };
    var buffer: [expected.len + 1]u8 align(RaggedSliceBlock(u8).alignment) = @splat(99);
    const written = try RaggedSliceBlock(u8).encode(&buffer, &children);
    try std.testing.expectEqual(expected.len, written);
    try std.testing.expectEqualSlices(u8, &expected, buffer[0..written]);
    try std.testing.expectEqual(@as(u8, 99), buffer[written]);
    const view = try RaggedSliceBlock(u8).view(buffer[0..written]);
    try std.testing.expectEqual(@intFromPtr(&buffer) + 16, @intFromPtr((try view.get(0)).ptr));
    try std.testing.expectEqual(@intFromPtr(&buffer) + 18, @intFromPtr((try view.get(1)).ptr));
    try std.testing.expectEqualSlices(u8, "ab", (try view.get(0)));
    try std.testing.expectEqualSlices(u8, "c", (try view.get(1)));
}

test "RaggedSliceBlock preserves byte slices of different lengths, including empty slices" {
    const Block = RaggedSliceBlock(u8);
    const values = [_][]const u8{ "alpha", "", &.{ 0, 1, 2, 3 }, "omega" };
    var buffer: [128]u8 align(Block.alignment) = undefined;
    const len = try Block.encode(&buffer, &values);
    try std.testing.expectEqual(try Block.encodedSize(&values), len);

    const view = try Block.view(buffer[0..len]);
    const assumed_valid = try Block.viewAssumeValid(buffer[0..len]);
    try std.testing.expectEqual(@as(usize, values.len), view.len());
    for (&values, 0..) |expected, index| {
        try std.testing.expectEqualSlices(u8, expected, (try view.get(index)));
        try std.testing.expectEqualSlices(u8, expected, (try assumed_valid.get(index)));
    }
}

test "RaggedSliceBlock encode() aligns u64 elements and views reject nonzero padding" {
    const Block = RaggedSliceBlock(u64);
    const children = [_][]const u64{ &.{ 3, 8 }, &.{}, &.{13} };
    // The count and four offsets occupy 20 bytes, followed by four padding bytes
    var buffer: [48]u8 align(Block.alignment) = @splat(99);
    try std.testing.expectEqual(buffer.len, try Block.encode(&buffer, &children));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, buffer[20..24]);

    const view = try Block.view(&buffer);
    try std.testing.expectEqual(children.len, view.len());
    try std.testing.expectEqual(@intFromPtr(&buffer) + 24, @intFromPtr(view.values.ptr));
    for (children, 0..) |expected, index| {
        try std.testing.expectEqualSlices(u64, expected, try view.get(index));
    }
    for (20..24) |index| {
        buffer[index] = 1;
        try std.testing.expectError(error.InvalidFormat, Block.view(&buffer));
        try std.testing.expectError(error.InvalidFormat, Block.viewMutable(&buffer));
        try std.testing.expectError(error.InvalidFormat, Block.viewAssumeValid(&buffer));
        buffer[index] = 0;
    }
}

test "RaggedSliceBlock supports an empty list of slices" {
    const Block = RaggedSliceBlock(u32);
    const values = [_][]const u32{};
    var buffer: [32]u8 align(Block.alignment) = undefined;
    const len = try Block.encode(&buffer, &values);
    const view = try Block.view(buffer[0..len]);
    try std.testing.expectEqual(@as(usize, 0), view.len());
    try std.testing.expectEqual(@as(usize, 0), view.values.len);
}

test "RaggedSliceBlock preserves the number of empty slices" {
    const Block = RaggedSliceBlock(u8);
    var buffer: [20]u8 align(Block.alignment) = undefined;
    _ = try Block.encode(&buffer, &.{ "", "", "" });
    const view = try Block.view(&buffer);
    try std.testing.expectEqual(3, view.len());
    for (0..view.len()) |index| try std.testing.expectEqual(0, (try view.get(index)).len);
}

test "RaggedSliceBlock view() rejects offsets that do not describe all stored elements in order" {
    const Block = RaggedSliceBlock(u8);
    // Three child slices share three stored bytes. Each table breaks one rule
    for ([_][4]u32{
        .{ 1, 1, 2, 3 }, // The first slice must start at element zero
        .{ 0, 2, 1, 3 }, // Offsets must not decrease, even when the final offset is correct
        .{ 0, 1, 2, 4 }, // An offset cannot exceed the number of stored elements
        .{ 0, 1, 2, 2 }, // The last offset must include every stored element
    }) |offsets| {
        var buffer: [23]u8 align(Block.alignment) = @splat(0);
        bytes.writeValue(u32, buffer[0..4], 3);
        for (offsets, 0..) |offset, index| {
            bytes.writeValue(u32, buffer[4 + index * 4 ..][0..4], offset);
        }
        try std.testing.expectError(error.InvalidFormat, Block.view(&buffer));
        try std.testing.expectError(error.InvalidFormat, Block.viewMutable(&buffer));
    }
}

test "RaggedSliceBlock views reject an incomplete count, offset table, or element" {
    const Block = RaggedSliceBlock(u16);
    var buffer: [15]u8 align(Block.alignment) = .{0} ** 15;
    const written = try Block.encode(&buffer, &.{&.{42}});
    // One child needs a four-byte count and two four-byte offsets
    for (0..12) |length| {
        try std.testing.expectError(error.BufferTooSmall, Block.view(buffer[0..length]));
        try std.testing.expectError(error.BufferTooSmall, Block.viewMutable(buffer[0..length]));
        try std.testing.expectError(error.BufferTooSmall, Block.viewAssumeValid(buffer[0..length]));
    }
    for ([_]usize{ written - 1, written + 1 }) |length| {
        try std.testing.expectError(error.InvalidFormat, Block.view(buffer[0..length]));
        try std.testing.expectError(error.InvalidFormat, Block.viewMutable(buffer[0..length]));
        try std.testing.expectError(error.InvalidFormat, Block.viewAssumeValid(buffer[0..length]));
    }
}

test "RaggedSliceBlock encode() leaves an undersized or misaligned destination unchanged" {
    inline for (.{ u8, u64 }) |T| {
        const Block = RaggedSliceBlock(T);
        const children = [_][]const T{&.{1}};
        var buffer: [32]u8 align(Block.alignment) = .{99} ** 32;
        const byte_count = try Block.encodedSize(&children);
        try std.testing.expectError(
            error.NoSpaceLeft,
            Block.encode(buffer[0 .. byte_count - 1], &children),
        );
        // Even u8 elements need an aligned buffer because the offsets are u32 values
        try std.testing.expectError(error.MisalignedBuffer, Block.encode(buffer[1..], &children));
        try std.testing.expect(std.mem.allEqual(u8, &buffer, 99));
        _ = try Block.encode(buffer[0..], &children);
        std.mem.copyBackwards(u8, buffer[1..][0..byte_count], buffer[0..byte_count]);
        try std.testing.expectError(error.MisalignedBuffer, Block.view(buffer[1..][0..byte_count]));
        try std.testing.expectError(error.MisalignedBuffer, Block.viewMutable(buffer[1..][0..byte_count]));
        try std.testing.expectError(
            error.MisalignedBuffer,
            Block.viewAssumeValid(buffer[1..][0..byte_count]),
        );
    }
}

test "RaggedSliceBlock view() checks boolean and enum values on both sides of an empty child slice" {
    const Status = enum(u8) { active, stale };
    const Item = extern struct { enabled: bool, status: Status };
    const Block = RaggedSliceBlock(Item);
    const children = [_][]const Item{
        &.{.{ .enabled = false, .status = .active }},
        &.{},
        &.{.{ .enabled = true, .status = .stale }},
    };
    var buffer: [24]u8 align(Block.alignment) = undefined;
    try std.testing.expectEqual(buffer.len, try Block.encode(&buffer, &children));
    _ = try Block.view(&buffer);
    // Three children need four offsets. The two two-byte values start at byte 20
    for (20..24) |index| {
        const original = buffer[index];
        buffer[index] = 2;
        try std.testing.expectError(error.InvalidValue, Block.view(&buffer));
        try std.testing.expectError(error.InvalidValue, Block.viewMutable(&buffer));
        buffer[index] = original;
    }
}

test "layoutFromCounts() rejects child or element counts that exceed format or target limits" {
    comptime {
        try std.testing.expectError(
            error.InputTooLarge,
            layoutFromCounts(u8, std.math.maxInt(usize), 0),
        );
        try std.testing.expectError(
            error.InputTooLarge,
            layoutFromCounts(u64, 0, std.math.maxInt(usize)),
        );
    }
}

test "RaggedSliceBlock get() rejects an index at or beyond the number of slices" {
    const Block = RaggedSliceBlock(u8);
    var buffer: [32]u8 align(Block.alignment) = undefined;
    const written = try Block.encode(&buffer, &.{ "a", "" });
    const view = try Block.view(buffer[0..written]);
    for ([_]usize{ view.len(), view.len() + 1, std.math.maxInt(usize) }) |index| {
        try std.testing.expectError(error.IndexOutOfBounds, view.get(index));
    }

    const empty_written = try Block.encode(&buffer, &.{});
    const empty_view = try Block.view(buffer[0..empty_written]);
    try std.testing.expectError(error.IndexOutOfBounds, empty_view.get(0));
}
