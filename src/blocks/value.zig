//! This is the simplest block type in stash.
//! Stash's Layout uses ValueBlock for fields that store a single value, such as an integer or a struct.
//! The block stores exactly @sizeOf(T) bytes with no extra metadata, and views point directly into those
//! bytes. Writing copies a value into the buffer, while checked views validate any boolean and
//! enum values before returning a pointer

const std = @import("std");
const blocks = @import("../blocks.zig");
const bytes = @import("../bytes.zig");
const comptime_validation = @import("../comptime_validation.zig");
const runtime_validation = @import("../runtime_validation.zig");

/// Store one T in its native representation and access it through a pointer into the buffer
pub fn ValueBlock(comptime T: type) type {
    comptime comptime_validation.assertStorable(T);

    return struct {
        pub const stash_block_info = .{ .kind = .value, .Element = T };
        pub const alignment = @alignOf(T);
        pub const Input = T;
        pub const Init = T;
        // Initializing a single value is the same operation as writing it for this block type
        pub const initializedSize = encodedSize;
        pub const initialize = encodeMutable;
        pub const View = *const T;
        pub const MutableView = *T;

        pub fn encodedSize(_: Input) blocks.BufferSizeError!usize {
            return @sizeOf(T);
        }

        /// Copy the value into the destination buffer and return the number of bytes written.
        /// The buffer must be aligned for T. Any bytes after the value are left unchanged
        pub fn encode(dest_buffer: []u8, value: Input) blocks.WriteError!usize {
            _ = try encodeMutable(dest_buffer, value);
            return @sizeOf(T);
        }

        /// Copy the value into the destination buffer and return a pointer that can be used for modifying it in place.
        /// The buffer must be aligned for T. Any bytes after the value are left unchanged
        pub fn encodeMutable(dest_buffer: []u8, value: Input) blocks.WriteError!MutableView {
            if (dest_buffer.len < @sizeOf(T)) return error.NoSpaceLeft;
            const stored_value = bytes.viewMutableValue(T, dest_buffer) catch |err| switch (err) {
                error.BufferTooSmall => unreachable,
                error.MisalignedBuffer => return error.MisalignedBuffer,
            };
            stored_value.* = value;
            return stored_value;
        }

        // If every bit pattern is valid for T, this block only needs size and alignment checks
        pub const needs_value_validation = runtime_validation.needsValueValidation(T);

        /// Return a pointer to the stored value after checking any boolean and enum values.
        /// The buffer must contain exactly one T and be aligned for T
        pub fn view(buffer: []const u8) blocks.ViewError!View {
            const value = try viewAssumeValid(buffer);
            if (comptime needs_value_validation) {
                runtime_validation.validateValue(T, buffer) catch |err| switch (err) {
                    error.InvalidBufferSize => unreachable,
                    error.InvalidValue => return error.InvalidValue,
                };
            }
            return value;
        }

        /// Return a pointer to the stored value after checking the buffer's size and alignment.
        /// The buffer must contain exactly one T whose boolean and enum values are already valid
        pub fn viewAssumeValid(buffer: []const u8) blocks.ViewError!View {
            if (buffer.len < @sizeOf(T)) return error.BufferTooSmall;
            if (buffer.len != @sizeOf(T)) return error.InvalidFormat;
            return bytes.viewValue(T, buffer);
        }

        /// Check the stored value and return a pointer for modifying it in place
        pub fn viewMutable(buffer: []u8) blocks.ViewError!MutableView {
            _ = try view(buffer);
            return bytes.viewMutableValue(T, buffer);
        }
    };
}

test "ValueBlock encode() writes one value without changing trailing bytes" {
    const Block = ValueBlock(u32);
    var buffer: [5]u8 align(@alignOf(u32)) = .{99} ** 5;
    try std.testing.expectEqual(4, try Block.encodedSize(0x01020304));
    try std.testing.expectEqual(4, try Block.encode(&buffer, 0x01020304));
    // The fifth byte is outside the value and should not be changed
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1, 99 }, &buffer);
    const value = try Block.view(buffer[0..4]);
    try std.testing.expectEqual(@intFromPtr(&buffer), @intFromPtr(value));
    try std.testing.expectEqual(@as(u32, 0x01020304), value.*);
}

test "ValueBlock encodeMutable() and viewMutable() modify the stored value in place" {
    const Block = ValueBlock(u32);
    var buffer: [5]u8 align(@alignOf(u32)) = .{99} ** 5;
    const value = try Block.encodeMutable(&buffer, 12);
    try std.testing.expectEqual(@as(u32, 12), value.*);
    value.* = 34;
    const mutable = try Block.viewMutable(buffer[0..4]);
    try std.testing.expectEqual(@as(u32, 34), mutable.*);
    mutable.* = 56;
    try std.testing.expectEqualSlices(u8, &.{ 56, 0, 0, 0, 99 }, &buffer);
}

test "ValueBlock rejects a buffer that is too short without changing it" {
    const Block = ValueBlock(u32);
    var buffer: [4]u8 align(@alignOf(u32)) = .{99} ** 4;
    for (0..4) |length| {
        try std.testing.expectError(error.NoSpaceLeft, Block.encode(buffer[0..length], 12));
        try std.testing.expectError(error.NoSpaceLeft, Block.encodeMutable(buffer[0..length], 12));
        try std.testing.expectError(error.BufferTooSmall, Block.view(buffer[0..length]));
        try std.testing.expectError(error.BufferTooSmall, Block.viewMutable(buffer[0..length]));
    }
    try std.testing.expectEqualSlices(u8, &.{ 99, 99, 99, 99 }, &buffer);
}

test "ValueBlock views reject trailing bytes" {
    var buffer: [5]u8 align(@alignOf(u32)) = .{0} ** 5;
    try std.testing.expectError(error.InvalidFormat, ValueBlock(u32).view(&buffer));
    try std.testing.expectError(error.InvalidFormat, ValueBlock(u32).viewMutable(&buffer));
}

test "ValueBlock rejects misaligned buffers without writing" {
    const Block = ValueBlock(u32);
    var buffer: [5]u8 align(@alignOf(u32)) = .{99} ** 5;
    // Starting one byte after an aligned address leaves enough space but breaks alignment
    try std.testing.expectError(error.MisalignedBuffer, Block.encode(buffer[1..], 12));
    try std.testing.expectError(error.MisalignedBuffer, Block.encodeMutable(buffer[1..], 12));
    try std.testing.expectError(error.MisalignedBuffer, Block.view(buffer[1..]));
    try std.testing.expectError(error.MisalignedBuffer, Block.viewMutable(buffer[1..]));
    try std.testing.expectEqualSlices(u8, &.{ 99, 99, 99, 99, 99 }, &buffer);
}

test "ValueBlock view() and viewMutable() reject invalid boolean and enum fields" {
    const Status = enum(u8) { pending, complete };
    const Record = extern struct { status: Status, enabled: bool };
    const Block = ValueBlock(Record);
    var buffer = [_]u8{ 1, 1 };
    try std.testing.expect((try Block.view(&buffer)).enabled);
    for (0..buffer.len) |index| {
        buffer[index] = 2;
        try std.testing.expectError(error.InvalidValue, Block.view(&buffer));
        try std.testing.expectError(error.InvalidValue, Block.viewMutable(&buffer));
        buffer[index] = 1;
    }
}

test "ValueBlock accepts undeclared tags in non-exhaustive enums" {
    const NonExhaustiveStatus = enum(u8) { pending, _ };
    const buffer = [_]u8{250};
    try std.testing.expectEqual(
        @as(u8, 250),
        @intFromEnum((try ValueBlock(NonExhaustiveStatus).view(&buffer)).*),
    );
}

test "ValueBlock viewAssumeValid() still checks the buffer size and alignment" {
    const Status = enum(u32) { pending, complete };
    const Block = ValueBlock(Status);
    const buffer: [5]u8 align(@alignOf(Status)) = .{ 1, 0, 0, 0, 0 };
    try std.testing.expectEqual(Status.complete, (try Block.viewAssumeValid(buffer[0..4])).*);
    try std.testing.expectError(error.BufferTooSmall, Block.viewAssumeValid(buffer[0..3]));
    try std.testing.expectError(error.InvalidFormat, Block.viewAssumeValid(&buffer));
    try std.testing.expectError(error.MisalignedBuffer, Block.viewAssumeValid(buffer[1..]));
}

test "ValueBlock can store a zero-sized value" {
    const Empty = extern struct {};
    const Block = ValueBlock(Empty);
    var buffer: [0]u8 align(@alignOf(Empty)) = .{};
    try std.testing.expectEqual(0, try Block.encodedSize(.{}));
    try std.testing.expectEqual(0, try Block.encode(&buffer, .{}));
    _ = try Block.encodeMutable(&buffer, .{});
    _ = try Block.view(&buffer);
    _ = try Block.viewMutable(&buffer);
}
