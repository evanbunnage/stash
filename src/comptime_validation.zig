const std = @import("std");
const builtin = @import("builtin");

// We only support little-endian targets for now
comptime {
    const endianness = builtin.cpu.arch.endian();
    if (endianness != .little) {
        @compileError(std.fmt.comptimePrint(
            "stash: a little-endian target is required\n" ++
                "  target '{s}-{s}-{s}' is {s}-endian",
            .{
                @tagName(builtin.cpu.arch),
                @tagName(builtin.os.tag),
                @tagName(builtin.abi),
                @tagName(endianness),
            },
        ));
    }
}

/// Recursively check that this type can be stored with stash's guarantees
pub fn assertStorable(comptime T: type) void {
    // Zig defaults to 1,000 branches during compile-time evaluation. This limit can be hit with
    // our recursive validation.
    // maxInt(u32) is huge but anything else would be too arbitrary IMO. I trust you :)
    @setEvalBranchQuota(std.math.maxInt(u32));
    comptime assertStorableType(T, @typeName(T));
}

// Not all types are storable in stash - this function recursively checks a given type to see
// if it's compatible at comptime
fn assertStorableType(comptime T: type, comptime type_path: []const u8) void {
    switch (@typeInfo(T)) {
        .int => assertFixedWidthInteger(T, type_path),
        .float => {},
        .bool => return,
        .@"enum" => |enum_info| {
            assertStorableType(enum_info.tag_type, type_path);
            return;
        },
        .array => |array_info| {
            if (array_info.sentinel_ptr != null) {
                @compileError("stash: sentinel arrays are not supported\n" ++
                    "  '" ++ type_path ++ "' has type '" ++ @typeName(T) ++ "'\n" ++
                    "  fix: use an ordinary array and store any terminator explicitly");
            }
            assertStorableType(array_info.child, type_path);
            return;
        },
        .@"struct" => |struct_info| {
            switch (struct_info.layout) {
                .auto => @compileError("stash: stored structs must be extern or packed\n" ++
                    "  '" ++ type_path ++ "' has an auto layout\n" ++
                    "  fix: use an extern or packed struct so its on-disk layout is defined"),
                .@"extern" => {
                    assertStructHasNoImplicitPadding(T);
                    for (struct_info.fields) |field| {
                        assertStorableType(field.type, type_path ++ "." ++ field.name);
                    }
                    return;
                },
                .@"packed" => {
                    for (struct_info.fields) |field| {
                        assertStorablePackedField(field.type, type_path ++ "." ++ field.name);
                    }
                },
            }
        },
        .vector => @compileError("stash: vectors are not supported\n" ++
            "  '" ++ type_path ++ "' is a vector; vectors can have padding and bit packing that differ from arrays\n" ++
            "  fix: store an array of storable elements; create a vector from the array when you need vector operations"),
        .@"union" => @compileError("stash: unions are not supported\n" ++
            "  '" ++ type_path ++ "' is a union\n" ++
            "  fix: store a byte array with an explicit enum tag and validate both"),
        .pointer => @compileError("stash: stored values must not contain pointers\n" ++
            "  '" ++ type_path ++ "' contains a pointer; saving its memory address will not let you find the data after loading\n" ++
            "  fix: store an ID or a byte offset within the stored data instead"),
        .optional => @compileError("stash: optional values are not supported\n" ++
            "  '" ++ type_path ++ "' is optional\n" ++
            "  fix: use a storable type with a way to indicate 'no value'"),
        .error_set => @compileError("stash: error sets are not supported\n" ++
            "  '" ++ type_path ++ "' is an error set; the integers used to represent errors can change between builds\n" ++
            "  fix: map errors to an explicitly numbered enum with a fixed-width integer tag"),
        .error_union => @compileError("stash: error unions are not supported\n" ++
            "  '" ++ type_path ++ "' is an error union; the integers used to represent errors and the memory layout are not stable storage formats\n" ++
            "  fix: store an explicitly numbered status enum and a storable payload in an extern struct\n" ++
            "  fix: initialize the payload even when the status indicates an error"),
        else => @compileError("stash: type is not storable\n" ++
            "  '" ++ type_path ++ "' has type '" ++ @typeName(T) ++ "'\n" ++
            "  fix: use a scalar value, an array, or an extern or packed struct with storable fields"),
    }

    // We want to prevent unspecified, compiler-inserted padding bits in types like packed structs
    assertNoUnusedStorageBits(T, type_path);
}

/// Stash allows fields to be packed together.
/// This fn checks that a packed field's type is storable, allowing bit widths that do not fill a whole byte
pub fn assertStorablePackedField(comptime T: type, comptime type_path: []const u8) void {
    switch (@typeInfo(T)) {
        .int => assertFixedWidthInteger(T, type_path),
        .bool => {},
        .@"enum" => |enum_info| assertStorablePackedField(enum_info.tag_type, type_path),
        .@"struct" => |struct_info| {
            if (struct_info.layout != .@"packed") {
                @compileError("stash: structs inside packed structs must also be packed\n" ++
                    "  '" ++ type_path ++ "' is not a packed struct");
            }
            for (struct_info.fields) |field| {
                assertStorablePackedField(field.type, type_path ++ "." ++ field.name);
            }
        },
        .@"union" => @compileError("stash: unions are not supported\n" ++
            "  '" ++ type_path ++ "' is a union\n" ++
            "  fix: store a byte array with an explicit enum tag and validate both"),
        else => @compileError("stash: packed fields must be integers, bools, enums, or packed structs\n" ++
            "  '" ++ type_path ++ "' has type '" ++ @typeName(T) ++ "'"),
    }
}

// usize and isize change width across targets, so stored integers must use explicit widths
fn assertFixedWidthInteger(comptime T: type, comptime type_path: []const u8) void {
    if (T == usize or T == isize) {
        @compileError("stash: target-sized integers are not supported\n" ++
            "  '" ++ type_path ++ "' is backed by '" ++ @typeName(T) ++ "'\n" ++
            "  fix: use an explicitly sized integer such as u32, u64, or i32");
    }
}

// Unused storage bits would be copied with the value and make its bytes nondeterministic
fn assertNoUnusedStorageBits(comptime T: type, comptime type_path: []const u8) void {
    if (@bitSizeOf(T) != 8 * @sizeOf(T)) {
        @compileError(std.fmt.comptimePrint(
            "stash: stored types must fill their storage bits\n" ++
                "  '{s}' has type '{s}', which defines {d} bits but occupies {d} bits of storage\n" ++
                "  unused storage bits would make copied bytes nondeterministic\n" ++
                "  fix: use a type that fills its storage. For a packed struct, add explicit reserved fields",
            .{ type_path, @typeName(T), @bitSizeOf(T), 8 * @sizeOf(T) },
        ));
    }
}

// Implicit compiler-inserted bytes are rejected. If you need a certain size struct, add explicit
// fields (like _reserved) with the minimum number of bytes to avoid added padding.
fn assertStructHasNoImplicitPadding(comptime T: type) void {
    var end: usize = 0;
    for (@typeInfo(T).@"struct".fields) |field| {
        const offset = @offsetOf(T, field.name);
        if (offset != end) {
            @compileError(std.fmt.comptimePrint(
                "stash: implicit field padding is not supported\n" ++
                    "  '{s}' has {d} bytes of implicit padding before field '{s}'\n" ++
                    "  fix: insert an explicit [{d}]u8 reserved field before '{s}'",
                .{ @typeName(T), offset - end, field.name, offset - end, field.name },
            ));
        }
        end = offset + @sizeOf(field.type);
    }
    if (end != @sizeOf(T)) {
        @compileError(std.fmt.comptimePrint(
            "stash: implicit tail padding is not supported\n" ++
                "  '{s}' has {d} bytes of implicit tail padding\n" ++
                "  fix: append an explicit [{d}]u8 reserved field",
            .{ @typeName(T), @sizeOf(T) - end, @sizeOf(T) - end },
        ));
    }
}

// Users pass structs to Layout to define their storage layout, we think of these structs as "schemas"
// The schema structs describe fields, not their in-memory layout
pub fn assertStructHasSupportedSchemaFields(comptime Schema: type, comptime owner: []const u8) void {
    const info = @typeInfo(Schema);
    if (info != .@"struct") @compileError("stash: " ++ owner ++ " expects a struct type\n" ++
        "  received '" ++ @typeName(Schema) ++ "'");
    if (info.@"struct".is_tuple) @compileError("stash: " ++ owner ++ " expects named fields, not a tuple\n" ++
        "  received '" ++ @typeName(Schema) ++ "'");
    for (info.@"struct".fields) |field| {
        if (field.is_comptime) @compileError("stash: " ++ owner ++ " fields must not be comptime\n" ++
            "  field '" ++ field.name ++ "' is comptime");
        if ((field.alignment orelse @alignOf(field.type)) != @alignOf(field.type)) {
            @compileError("stash: " ++ owner ++ " fields must use natural alignment\n" ++
                "  field '" ++ field.name ++ "' has custom alignment\n" ++
                "  fix: put alignment on an explicitly stored extern struct instead");
        }
    }
}

// Slice views preserve element types, but do not store pointer qualifiers or sentinels
pub fn assertSliceHasSupportedPointerAttributes(comptime T: type) void {
    const pointer = @typeInfo(T).pointer;
    if (pointer.sentinel_ptr != null) @compileError("stash: sentinel slices are not supported\n" ++
        "  received '" ++ @typeName(T) ++ "'\n" ++
        "  fix: use []const T and store any terminator explicitly");
    if (pointer.is_volatile) @compileError("stash: volatile slices are not supported\n" ++
        "  received '" ++ @typeName(T) ++ "'\n" ++
        "  fix: use []const T");
    if (pointer.is_allowzero) @compileError("stash: allowzero slices are not supported\n" ++
        "  received '" ++ @typeName(T) ++ "'\n" ++
        "  fix: use []const T");
    if (pointer.address_space != .generic) @compileError("stash: slices must use the generic address space\n" ++
        "  received '" ++ @typeName(T) ++ "'\n" ++
        "  fix: use []const T");
    if ((pointer.alignment orelse @alignOf(pointer.child)) != @alignOf(pointer.child)) {
        @compileError("stash: slices must use natural alignment\n" ++
            "  received '" ++ @typeName(T) ++ "'\n" ++
            "  fix: use []const T");
    }
}

test "assertStorable() accepts supported scalars, arrays, and structs without implicit padding" {
    inline for (.{ u8, u16, u32, u64, u128, i8, i16, i32, i64, f32, f64, bool }) |T| {
        comptime assertStorable(T);
    }
    const Status = enum(u8) { pending, complete };
    const Point = extern struct { x: i32, y: i32 };
    const Mode = enum(u2) { idle, running };
    const Settings = packed struct { enabled: bool, mode: Mode };
    const Flags = packed struct(u8) { settings: Settings, reserved: u5 = 0 };
    inline for (.{
        Status, // An exhaustive enum with a storable tag type
        enum(u16) { pending = 1, _ }, // Non-exhaustive enums are storable too
        [4]Status, // Arrays can contain enums
        [2][3]u32, // Arrays can contain other arrays
        [0]u32, // An empty array is valid when its element type is storable
        extern struct {}, // A stored value can occupy zero bytes
        Point, // An extern struct whose fields leave no padding
        extern struct { points: [4]Point, id: u32 }, // Struct fields can contain arrays of structs
        Flags, // Nested packed fields together fill a whole storage byte
        [8]Flags, // Arrays can contain packed structs
        packed struct(u128) { a: u64, b: u64 }, // Packed structs can span more than 64 bits
    }) |T| comptime assertStorable(T);
}

test "assertStorable() can validate deeply nested structs within the comptime evaluation budget" {
    const One = extern struct { value: u32 };
    const Two = extern struct { a: One, b: One };
    const Four = extern struct { a: Two, b: Two };
    const Eight = extern struct { a: Four, b: Four };
    const Sixteen = extern struct { a: Eight, b: Eight };
    const ThirtyTwo = extern struct { a: Sixteen, b: Sixteen };
    const SixtyFour = extern struct { a: ThirtyTwo, b: ThirtyTwo };
    // This fails if eval branch depth is <= the default of 1000
    comptime assertStorable(extern struct { a: SixtyFour, b: SixtyFour });
}
