//! This file provides helpers for runtime checks to ensure exhaustive enums and bools are valid.
//!
//! A u8 can hold 256 different values, but an exhaustive enum(u8) can declare only a subset of them. When we read
//! that byte from disk, issues can occur if the value fits in a u8 without matching any of the declared values (either by
//! corruption or if a developer changed the enum). Similarly, a bool stored in a whole byte must
//! contain 0 or 1, even though a u8 can of course hold 254 other values.
//!
//! An exhaustive enum only allows its declared tags. In Zig, adding _ makes it non-exhaustive, meaning that
//! every value of its backing integer is valid.
//! This improves performance since we don't need to check the enum values at runtime, but it also means we
//! can't catch undeclared values (either caused by corruption or a developer changing the enum).
//!
//! ```zig
//! // Exhaustive: only 0, 1 and 2 are valid u8 integers
//! const Status = enum(u8) {
//!     pending = 0,
//!     complete = 1,
//!     cancelled = 2,
//! };
//!
//! // Non-exhaustive: any u8 value is valid
//! const NonExhaustiveStatus = enum(u8) {
//!     pending = 0,
//!     complete = 1,
//!     cancelled = 2,
//!     _,
//! };
//! ```
//!
//! For example: a stored byte of 42 is invalid for Status, but valid for NonExhaustiveStatus

const std = @import("std");
const bytes = @import("bytes.zig");
const comptime_validation = @import("comptime_validation.zig");

pub const ValueValidationError = error{
    InvalidBufferSize,
    InvalidValue,
};

/// Recursively check whether any stored values in T need validation. Currently, this means checking bools and
/// enums for valid integers
pub fn needsValueValidation(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .bool => return true,
        .@"enum" => |enum_info| return enum_info.is_exhaustive,
        .array => |array_info| return array_info.len != 0 and needsValueValidation(array_info.child),
        .@"struct" => |struct_info| {
            if (struct_info.layout == .@"packed") return needsPackedValueValidation(T);
            inline for (struct_info.fields) |field| {
                if (needsValueValidation(field.type)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Require exactly @sizeOf(T) bytes and validate any boolean or enum values in the buffer
pub fn validateValue(comptime T: type, buffer: []const u8) ValueValidationError!void {
    comptime comptime_validation.assertStorable(T);
    if (buffer.len != @sizeOf(T)) return error.InvalidBufferSize;
    if (comptime !needsValueValidation(T)) return;
    switch (@typeInfo(T)) {
        .bool => if (buffer[0] > 1) return error.InvalidValue,
        .@"enum" => |enum_info| {
            // Read the integer tag first, then check whether the enum declares it
            const tag = bytes.copyValue(enum_info.tag_type, buffer) catch unreachable;
            _ = std.enums.fromInt(T, tag) orelse return error.InvalidValue;
        },
        .array => |array_info| try validateValues(array_info.child, buffer, array_info.len),
        .@"struct" => |struct_info| {
            if (struct_info.layout == .@"packed") {
                const value_bits = bytes.copyValue(struct_info.backing_integer.?, buffer) catch unreachable;
                try validatePackedValue(T, value_bits, 0);
            } else {
                inline for (struct_info.fields) |field| {
                    if (comptime needsValueValidation(field.type)) {
                        const offset = @offsetOf(T, field.name);
                        try validateValue(field.type, buffer[offset..][0..@sizeOf(field.type)]);
                    }
                }
            }
        },
        else => {},
    }
}

/// Validate multiple elements in a provided buffer. The buffer must be count * @sizeOf(T) bytes
pub fn validateValues(comptime T: type, buffer: []const u8, count: usize) error{InvalidValue}!void {
    comptime comptime_validation.assertStorable(T);
    const size = @sizeOf(T);
    std.debug.assert(buffer.len == count * size);
    if (comptime !needsValueValidation(T)) return;
    // enum(u0), for example, has the same empty representation at every index
    const checks = if (size == 0) @min(count, 1) else count;
    for (0..checks) |index| {
        validateValue(T, buffer[index * size ..][0..size]) catch |err| switch (err) {
            error.InvalidBufferSize => unreachable,
            error.InvalidValue => return error.InvalidValue,
        };
    }
}

/// Packed values use their bit widths during validation to reduce work: a one-bit bool has no invalid bit patterns,
/// and an enum(u2) declaring all four tags needs no check either. Exhaustive enums with
/// undeclared bit patterns still need validation, including those nested in packed structs.
pub fn needsPackedValueValidation(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"enum" => |enum_info| {
            if (!enum_info.is_exhaustive) return false;
            const tag_bit_count = @bitSizeOf(enum_info.tag_type);
            // If counting all possible tags would overflow usize, there cannot be that many enum fields
            if (tag_bit_count >= @bitSizeOf(usize)) return true;
            const possible_tag_count = @as(usize, 1) << tag_bit_count;
            return enum_info.fields.len != possible_tag_count;
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                if (needsPackedValueValidation(field.type)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Check that the enum tags stored in T are valid, including those in nested packed structs.
/// Pass value_bits without shifting it and use bit_offset to indicate where T begins,
/// counting from the least significant bit. Any bits outside T are ignored
///
/// Here, Status occupies bits 4 and 5, and the stored tag is 2
/// ```zig
/// const Status = enum(u2) { pending = 0, complete = 2 };
/// const Flags = packed struct(u8) {
///     permissions: u4,
///     status: Status,
///     reserved: u2,
/// };
/// const raw: u8 = 0b11101111;
/// try validatePackedValue(Status, raw, @bitOffsetOf(Flags, "status"));
/// ```
pub fn validatePackedValue(
    comptime T: type,
    value_bits: anytype,
    bit_offset: usize,
) ValueValidationError!void {
    const integer_bit_count = @bitSizeOf(@TypeOf(value_bits));
    if (bit_offset > integer_bit_count or @bitSizeOf(T) > integer_bit_count - bit_offset) {
        return error.InvalidBufferSize;
    }
    if (comptime !needsPackedValueValidation(T)) return;
    const bits: @Int(.unsigned, @bitSizeOf(T)) = @truncate(value_bits >> @intCast(bit_offset));
    switch (@typeInfo(T)) {
        .@"enum" => |enum_info| {
            const tag: enum_info.tag_type = @bitCast(bits);
            _ = std.enums.fromInt(T, tag) orelse return error.InvalidValue;
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                if (comptime needsPackedValueValidation(field.type)) {
                    try validatePackedValue(field.type, bits, @bitOffsetOf(T, field.name));
                }
            }
        },
        else => @compileError("stash: type is not supported by packed validation\n" ++
            "  received '" ++ @typeName(T) ++ "'\n" ++
            "  packed validation only checks enum tags, either on their own or as fields in a packed struct\n" ++
            "  fix: use validateValue(T, buffer) to check a value stored in a byte buffer"),
    }
}

test "value validation is needed for stored booleans and exhaustive enums, including nested fields" {
    const Status = enum(u8) { pending, complete };
    const NonExhaustiveStatus = enum(u8) { pending, _ };
    const Record = extern struct { status: Status, enabled: bool };
    inline for (.{
        bool, // A whole byte can contain values other than 0 and 1
        Status, // Only declared tags are valid
        Record, // Check fields inside structs
        [4]bool, // Check array elements
        [2]Record, // Check fields in each array element
    }) |T| {
        try std.testing.expect(comptime needsValueValidation(T));
    }
    inline for (.{
        u32,
        f64,
        NonExhaustiveStatus, // Every tag is allowed
        [4]u16,
        extern struct { count: u32 },
        [0]bool, // Empty arrays have no elements to validate
        [0]Status,
        [2][0]bool, // Nested empty arrays also need no checks
        extern struct { empty: [0]bool },
    }) |T| {
        try std.testing.expect(!comptime needsValueValidation(T));
    }
}

test "validateValues() accepts signed enum tags and checks every element in an unaligned buffer" {
    const Status = enum(i16) { failed = -1, complete = 2 };
    // The two 255 bytes represent -1. Starting at buffer[1] also checks unaligned reads
    var buffer: [5]u8 align(2) = .{ 99, 255, 255, 2, 0 };
    try validateValues(Status, buffer[1..], 2);
    try validateValues(Status, &.{}, 0);
    for ([_]usize{ 1, 3 }) |offset| {
        const original = buffer[offset..][0..2].*;
        @memcpy(buffer[offset..][0..2], &[_]u8{ 3, 0 });
        try std.testing.expectError(error.InvalidValue, validateValues(Status, buffer[1..], 2));
        @memcpy(buffer[offset..][0..2], &original);
    }
}

test "validateValues() handles zero-sized enums without iterating over the element count" {
    const One = enum(u0) { only };
    const Empty = enum(u0) {};
    try validateValues(One, &.{}, std.math.maxInt(usize));
    try validateValues(Empty, &.{}, 0);
    try std.testing.expectError(error.InvalidValue, validateValues(Empty, &.{}, 1));
}

test "packed structs use their field's bit widths to decide whether validation is needed" {
    const AllTagsDeclared = enum(u2) { a, b, c, d };
    const SomeTagsDeclared = enum(u2) { a = 0, b = 2 };
    const PackedBoolean = packed struct(u8) { enabled: bool, reserved: u7 };
    const PackedFullEnum = packed struct(u8) { tag: AllTagsDeclared, reserved: u6 };
    const PackedPartialEnum = packed struct(u8) { tag: SomeTagsDeclared, reserved: u6 };

    inline for (.{
        PackedBoolean, // One bit can only contain 0 or 1
        PackedFullEnum, // Every two-bit tag is declared
        [2]PackedFullEnum,
        extern struct { flags: PackedBoolean },
    }) |T| {
        try std.testing.expect(!comptime needsValueValidation(T));
    }
    inline for (.{
        PackedPartialEnum, // Some two-bit tags are undeclared
        [2]PackedPartialEnum,
        extern struct { flags: PackedPartialEnum },
    }) |T| {
        try std.testing.expect(comptime needsValueValidation(T));
    }
}

test "validateValue() requires exactly enough bytes for one value" {
    // Check sizes even for integers and empty structs, which need no value validation
    inline for (.{ bool, u32, extern struct {} }) |T| {
        const buffer = [_]u8{0} ** (@sizeOf(T) + 1);
        for (0..buffer.len + 1) |length| {
            if (length == @sizeOf(T)) {
                try validateValue(T, buffer[0..length]);
            } else {
                try std.testing.expectError(
                    error.InvalidBufferSize,
                    validateValue(T, buffer[0..length]),
                );
            }
        }
    }
}

test "boolean validation accepts only bytes containing zero or one" {
    for (0..256) |value| {
        const buffer = [_]u8{@intCast(value)};
        if (value <= 1) {
            try validateValue(bool, &buffer);
        } else {
            try std.testing.expectError(error.InvalidValue, validateValue(bool, &buffer));
        }
    }
}

test "enum validation rejects undeclared tags unless the enum is non-exhaustive" {
    const Status = enum(u8) { pending = 1, complete = 3 };
    const NonExhaustiveStatus = enum(u8) { pending = 1, _ };
    for (0..256) |value| {
        const buffer = [_]u8{@intCast(value)};
        if (value == 1 or value == 3) {
            try validateValue(Status, &buffer);
        } else {
            try std.testing.expectError(error.InvalidValue, validateValue(Status, &buffer));
        }
        try validateValue(NonExhaustiveStatus, &buffer);
    }
}

test "value validation checks boolean and enum fields inside arrays of structs" {
    const Status = enum(u8) { pending, complete };
    const Item = extern struct { status: Status, enabled: bool };
    const Record = extern struct { items: [2]Item, count: u32 };
    var buffer = [_]u8{ 0, 0, 1, 1, 99, 99, 99, 99 };
    try validateValue(Record, &buffer);
    // Change each enum or boolean byte in turn, including those in the second item
    for (0..4) |index| {
        const original = buffer[index];
        buffer[index] = 2;
        try std.testing.expectError(error.InvalidValue, validateValue(Record, &buffer));
        buffer[index] = original;
    }
    try validateValue([0]bool, &.{});
}

test "packed value validation is needed only for enums with undeclared bit patterns" {
    const AllTagsDeclared = enum(u2) { a, b, c, d };
    const SomeTagsDeclared = enum(u2) { a = 0, b = 2 };
    const NonExhaustiveEnum = enum(u2) { a, _ };
    inline for (.{
        bool, // A packed bool has no invalid bit pattern
        u3,
        AllTagsDeclared,
        NonExhaustiveEnum,
        packed struct { enabled: bool, tag: AllTagsDeclared },
    }) |T| {
        try std.testing.expect(!comptime needsPackedValueValidation(T));
    }
    inline for (.{
        SomeTagsDeclared,
        enum(u32) { a, b }, // Counting possible tags must not overflow a 32-bit usize
        enum(u64) { a, b }, // Nor a 64-bit usize
        packed struct { tag: SomeTagsDeclared },
    }) |T| {
        try std.testing.expect(comptime needsPackedValueValidation(T));
    }
}

test "packed enum tags are checked at every offset within a byte" {
    const Status = enum(u2) { pending = 0, complete = 2 };
    for (0..7) |offset| {
        for (0..256) |value| {
            const raw: u8 = @intCast(value);
            // The valid tags are 00 and 10, so the tag's lowest bit must be zero.
            // Trying every byte also varies all the bits outside the tag
            const lowest_tag_bit = @as(u8, 1) << @intCast(offset);
            if (raw & lowest_tag_bit == 0) {
                try validatePackedValue(Status, raw, offset);
            } else {
                try std.testing.expectError(
                    error.InvalidValue,
                    validatePackedValue(Status, raw, offset),
                );
            }
        }
    }
}

test "packed enum validation accepts declared negative tags and rejects undeclared tags" {
    const Status = enum(i2) { failed = -1, complete = 1 };
    // In a signed two-bit integer, 11 means -1 and 10 means -2
    try validatePackedValue(Status, @as(u2, 0b11), 0);
    try validatePackedValue(Status, @as(u2, 0b01), 0);
    try std.testing.expectError(error.InvalidValue, validatePackedValue(Status, @as(u2, 0b10), 0));
    try std.testing.expectError(error.InvalidValue, validatePackedValue(Status, @as(u2, 0b00), 0));
}

test "packed types with no invalid values accept every bit pattern" {
    const NonExhaustiveStatus = enum(u2) { pending = 0, _ };
    const AllTagsDeclared = enum(u2) { a, b, c, d };
    const Flags = packed struct(u8) { status: NonExhaustiveStatus, reserved: u6 };
    const PackedBoolean = packed struct(u8) { enabled: bool, reserved: u7 };
    const PackedFullEnum = packed struct(u8) { tag: AllTagsDeclared, reserved: u6 };
    for (0..256) |value| {
        const raw: u8 = @intCast(value);
        try validatePackedValue(bool, raw, 0);
        try validatePackedValue(AllTagsDeclared, raw, 0);
        try validatePackedValue(NonExhaustiveStatus, raw, 0);
        try validateValue(Flags, &.{raw});
        try validateValue(PackedBoolean, &.{raw});
        try validateValue(PackedFullEnum, &.{raw});
    }
}

test "validatePackedValue() checks enum fields at their offsets inside nested packed structs" {
    const Status = enum(u2) { pending = 0, complete = 2 };
    const Settings = packed struct { enabled: bool, status: Status };
    const Flags = packed struct(u8) { permissions: u3, settings: Settings, reserved: u2 };
    const settings_offset = @bitOffsetOf(Flags, "settings");
    // settings starts at bit 3, so its status field starts at bit 4
    try validatePackedValue(Settings, @as(u8, 0b11101111), settings_offset);
    try std.testing.expectError(
        error.InvalidValue,
        validatePackedValue(Settings, @as(u8, 0b11011111), settings_offset),
    );
}

test "value validation checks enum fields in every packed struct in an array" {
    const Status = enum(u2) { pending = 0, complete = 2 };
    const Item = packed struct(u8) { enabled: bool, status: Status, reserved: u5 };
    var buffer = [_]u8{ 0b11111001, 0b11111101 };
    try validateValue([2]Item, &buffer);
    // Give each item an undeclared tag in turn to catch skipped array elements
    for (0..buffer.len) |index| {
        const original = buffer[index];
        buffer[index] = 0b11111011;
        try std.testing.expectError(error.InvalidValue, validateValue([2]Item, &buffer));
        buffer[index] = original;
    }
}

test "packed value validation rejects offsets that leave too few bits for the value" {
    const Status = enum(u2) { pending = 0, complete = 2 };
    try validatePackedValue(Status, @as(u8, 0b10000000), 6);
    for ([_]usize{ 7, 8, std.math.maxInt(usize) }) |offset| {
        try std.testing.expectError(
            error.InvalidBufferSize,
            validatePackedValue(Status, @as(u8, 0), offset),
        );
    }
    // Check the bounds even when the type needs no value validation
    try std.testing.expectError(error.InvalidBufferSize, validatePackedValue(bool, @as(u8, 0), 8));
}

test "nested packed fields are validated beyond the first 64 bits" {
    const Status = enum(u2) { pending = 0, complete = 2 };
    const PackedSettings = packed struct { enabled: bool, status: Status };
    const Record = packed struct(u128) { reserved: u64, settings: PackedSettings, remaining: u61 };
    // Byte 8 holds the boolean in bit 0 and the enum in bits 1 and 2.
    // This checks that we find the enum even when it sits beyond the first 64 bits
    var buffer: [16]u8 = .{0} ** 16;
    buffer[8] = 0b101; // enabled = 1, status = 2, which is declared
    try validateValue(Record, &buffer);
    buffer[8] = 0b011; // enabled = 1, status = 1, which is not declared
    try std.testing.expectError(error.InvalidValue, validateValue(Record, &buffer));
}
