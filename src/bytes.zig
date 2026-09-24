//! This file is a catchall for internal functions that help us work with byte buffers, like viewing
//! bytes as typed data using @ptrCast and memcpy-ing values

const std = @import("std");
const comptime_validation = @import("comptime_validation.zig");

pub const ByteViewError = error{
    BufferTooSmall,
    MisalignedBuffer,
};

/// Return a typed pointer into the buffer
pub fn viewValue(comptime T: type, source_buffer: []const u8) ByteViewError!*const T {
    comptime comptime_validation.assertStorable(T);
    if (source_buffer.len < @sizeOf(T)) return error.BufferTooSmall;
    if (!isPointerAligned(T, source_buffer.ptr)) return error.MisalignedBuffer;
    return @ptrCast(@alignCast(source_buffer.ptr));
}

/// Return a typed mutable pointer into the buffer. Note that we're limited to mutating values in
/// place
pub fn viewMutableValue(comptime T: type, buffer: []u8) ByteViewError!*T {
    comptime comptime_validation.assertStorable(T);
    if (buffer.len < @sizeOf(T)) return error.BufferTooSmall;
    if (!isPointerAligned(T, buffer.ptr)) return error.MisalignedBuffer;
    return @ptrCast(@alignCast(buffer.ptr));
}

/// Return a typed slice into the buffer
pub fn viewSlice(comptime T: type, source_buffer: []const u8, element_count: usize) ByteViewError![]const T {
    comptime comptime_validation.assertStorable(T);
    const bytes_needed = std.math.mul(usize, element_count, @sizeOf(T)) catch return error.BufferTooSmall;
    if (source_buffer.len < bytes_needed) return error.BufferTooSmall;
    if (!isPointerAligned(T, source_buffer.ptr)) return error.MisalignedBuffer;
    const pointer: [*]const T = @ptrCast(@alignCast(source_buffer.ptr));
    return pointer[0..element_count];
}

/// Return a typed mutable slice into the buffer. Same limitation as above: only for mutating values in place
pub fn viewMutableSlice(comptime T: type, buffer: []u8, element_count: usize) ByteViewError![]T {
    comptime comptime_validation.assertStorable(T);
    const bytes_needed = std.math.mul(usize, element_count, @sizeOf(T)) catch return error.BufferTooSmall;
    if (buffer.len < bytes_needed) return error.BufferTooSmall;
    if (!isPointerAligned(T, buffer.ptr)) return error.MisalignedBuffer;
    const pointer: [*]T = @ptrCast(@alignCast(buffer.ptr));
    return pointer[0..element_count];
}

/// Get a typed value from bytes that could be unaligned
pub fn copyValue(comptime T: type, source_buffer: []const u8) error{BufferTooSmall}!T {
    comptime comptime_validation.assertStorable(T);
    if (source_buffer.len < @sizeOf(T)) return error.BufferTooSmall;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), source_buffer[0..@sizeOf(T)]);
    return value;
}

/// Copy a value into a destination buffer that may be unaligned
pub fn writeValue(comptime T: type, dest_buffer: *[@sizeOf(T)]u8, value: T) void {
    comptime comptime_validation.assertStorable(T);
    @memcpy(dest_buffer, std.mem.asBytes(&value));
}

fn isPointerAligned(comptime T: type, pointer: [*]const u8) bool {
    return @intFromPtr(pointer) % @alignOf(T) == 0;
}

test "viewValue() points into a provided buffer" {
    const buffer: [8]u8 align(@alignOf(u32)) = .{ 0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0 };
    for ([_]usize{ 4, 8 }) |length| {
        const value = try viewValue(u32, buffer[0..length]);
        try std.testing.expectEqual(@intFromPtr(&buffer), @intFromPtr(value));
        try std.testing.expectEqual(@as(u32, 0x12345678), value.*);
    }
}

test "value views reject a buffer that is too short" {
    var buffer: [4]u8 align(@alignOf(u32)) = @splat(0);
    for (0..buffer.len) |length| {
        try std.testing.expectError(error.BufferTooSmall, viewValue(u32, buffer[0..length]));
        try std.testing.expectError(error.BufferTooSmall, viewMutableValue(u32, buffer[0..length]));
    }
}

test "value views reject a buffer whose starting address is misaligned" {
    var buffer: [5]u8 align(@alignOf(u32)) = @splat(0);
    try std.testing.expectError(error.MisalignedBuffer, viewValue(u32, buffer[1..]));
    try std.testing.expectError(error.MisalignedBuffer, viewMutableValue(u32, buffer[1..]));
}

test "viewMutableValue() lets the caller change a value directly in a provided buffer" {
    for ([_]usize{ 4, 8 }) |length| {
        var buffer: [8]u8 align(@alignOf(u32)) = .{99} ** 8;
        const value = try viewMutableValue(u32, buffer[0..length]);
        value.* = 0x12345678;
        try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12, 99, 99, 99, 99 }, &buffer);
    }
}

test "viewSlice() returns the requested number of elements from a provided buffer without copying" {
    const Point = extern struct { x: u16, y: u16, z: u16 };
    const buffer: [18]u8 align(@alignOf(Point)) = .{ 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8, 0, 9, 0 };
    // Accept an exact fit, an extra byte, and enough space for another element
    for ([_]usize{ 12, 13, 18 }) |length| {
        const values = try viewSlice(Point, buffer[0..length], 2);
        try std.testing.expectEqual(@intFromPtr(&buffer), @intFromPtr(values.ptr));
        try std.testing.expectEqual(@as(usize, 2), values.len);
        try std.testing.expectEqualDeep(Point{ .x = 1, .y = 2, .z = 3 }, values[0]);
        try std.testing.expectEqualDeep(Point{ .x = 4, .y = 5, .z = 6 }, values[1]);
    }
}

test "viewMutableSlice() lets the caller change elements without changing bytes after the slice" {
    const Point = extern struct { x: u16, y: u16, z: u16 };
    var buffer: [18]u8 align(@alignOf(Point)) = @splat(99);
    const values = try viewMutableSlice(Point, &buffer, 2);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    values[0] = .{ .x = 1, .y = 2, .z = 3 };
    values[1] = .{ .x = 4, .y = 5, .z = 6 };
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 99, 99, 99, 99, 99, 99 }, &buffer);
}

test "slice views reject a buffer that cannot hold the requested number of elements" {
    inline for (.{ u32, extern struct { x: u16, y: u16, z: u16 } }) |T| {
        var buffer: [2 * @sizeOf(T)]u8 align(@alignOf(T)) = @splat(0);
        for (0..buffer.len) |length| {
            try std.testing.expectError(error.BufferTooSmall, viewSlice(T, buffer[0..length], 2));
            try std.testing.expectError(error.BufferTooSmall, viewMutableSlice(T, buffer[0..length], 2));
        }
    }
}

test "slice views reject an element count whose total byte size overflows" {
    var buffer: [8]u8 align(@alignOf(u32)) = .{0} ** 8;
    // Multiplying this count by four bytes is too large for usize
    // Both functions should return BufferTooSmall instead of overflowing
    const overflowing_count = std.math.maxInt(usize) / @sizeOf(u32) + 1;
    try std.testing.expectError(error.BufferTooSmall, viewSlice(u32, &buffer, overflowing_count));
    try std.testing.expectError(error.BufferTooSmall, viewMutableSlice(u32, &buffer, overflowing_count));
}

test "slice views require an aligned buffer even when no elements are requested" {
    // buffer[1..] is not aligned for u32
    // We reject that address even when the caller asks for zero elements
    var buffer: [9]u8 align(@alignOf(u32)) = .{0} ** 9;
    for ([_]usize{ 0, 2 }) |count| {
        try std.testing.expectError(error.MisalignedBuffer, viewSlice(u32, buffer[1..], count));
        try std.testing.expectError(error.MisalignedBuffer, viewMutableSlice(u32, buffer[1..], count));
    }
}

test "slice views support empty slices and elements that occupy no bytes" {
    var buffer: [0]u8 align(@alignOf(u32)) = .{};
    try std.testing.expectEqual(@as(usize, 0), (try viewSlice(u32, &buffer, 0)).len);
    try std.testing.expectEqual(@as(usize, 0), (try viewMutableSlice(u32, &buffer, 0)).len);
    const Empty = extern struct {};
    // Empty has no fields and takes zero bytes, so three of them will fit in an empty buffer
    // The slice length counts elements, not bytes, and should be three
    try std.testing.expectEqual(@as(usize, 3), (try viewSlice(Empty, &buffer, 3)).len);
    try std.testing.expectEqual(@as(usize, 3), (try viewMutableSlice(Empty, &buffer, 3)).len);
}

test "copyValue() copies an independent value from an unaligned buffer" {
    // Exercise a six-byte value as well as the four-byte integers used elsewhere
    const Point = extern struct { x: u16, y: u16, z: u16 };
    const expected: Point = .{ .x = 1, .y = 2, .z = 3 };
    for ([_]usize{ 7, 8 }) |end| {
        var buffer: [8]u8 align(@alignOf(Point)) = .{ 99, 1, 0, 2, 0, 3, 0, 99 };
        const copied = try copyValue(Point, buffer[1..end]);
        @memset(&buffer, 0);
        try std.testing.expectEqualDeep(expected, copied);
    }
}

test "copyValue() rejects a buffer that is too short" {
    const buffer = [_]u8{0} ** 4;
    for (0..4) |length| {
        try std.testing.expectError(error.BufferTooSmall, copyValue(u32, buffer[0..length]));
    }
}

test "writeValue() copies into an unaligned buffer without changing surrounding bytes" {
    const Point = extern struct { x: u16, y: u16, z: u16 };
    var buffer: [8]u8 align(@alignOf(Point)) = @splat(99);
    writeValue(Point, buffer[1..7], .{ .x = 4, .y = 5, .z = 6 });
    try std.testing.expectEqualSlices(u8, &.{ 99, 4, 0, 5, 0, 6, 0, 99 }, &buffer);
}

test "u8 views do not require alignment beyond a byte" {
    // buffer[1..3] starts at an address that would be rejected for u32
    // These calls use u8, so they should work at that address
    var buffer: [4]u8 align(4) = .{ 99, 1, 2, 99 };
    const bytes = buffer[1..3];
    try std.testing.expectEqual(@as(u8, 1), (try viewValue(u8, bytes)).*);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, try viewSlice(u8, bytes, 2));

    (try viewMutableValue(u8, bytes)).* = 3;
    const values = try viewMutableSlice(u8, bytes, 2);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    values[1] = 4;
    try std.testing.expectEqualSlices(u8, &.{ 99, 3, 4, 99 }, &buffer);
}
