//! A significant focus of this library is checking the compatibility of your data structures at comptime.
//! This means we have fairly specific compilation errors. Currently there's not a great way to assert
//! that a given test returns a specific compilation error in Zig's testing framework.
//!
//! So instead we have this runner. It compiles each fixture separately (see all the files in compile_error_cases/)
//! and checks that the compile error contains the expected error message. Kinda janky but it works fine.

const std = @import("std");

const cases = [_]struct { name: []const u8, expected_message: []const u8 }{
    .{ .name = "target_sized_unsigned", .expected_message = "stash: target-sized integers are not supported" },
    .{ .name = "target_sized_signed", .expected_message = "stash: target-sized integers are not supported" },
    .{ .name = "packed_usize", .expected_message = "stash: target-sized integers are not supported" },
    .{ .name = "target_sized_enum", .expected_message = "stash: target-sized integers are not supported" },

    .{ .name = "narrow_integer", .expected_message = "stash: stored types must fill their storage bits" },
    .{ .name = "narrow_array", .expected_message = "stash: stored types must fill their storage bits" },
    .{ .name = "narrow_enum", .expected_message = "stash: stored types must fill their storage bits" },
    .{ .name = "incomplete_packed_struct", .expected_message = "stash: stored types must fill their storage bits" },
    .{ .name = "padded_integer", .expected_message = "stash: stored types must fill their storage bits" },
    .{ .name = "padded_float", .expected_message = "stash: stored types must fill their storage bits" },

    .{ .name = "pointer", .expected_message = "stash: stored values must not contain pointers" },
    .{ .name = "slice", .expected_message = "stash: stored values must not contain pointers" },
    .{ .name = "optional", .expected_message = "stash: optional values are not supported" },
    .{ .name = "error_set", .expected_message = "stash: error sets are not supported" },
    .{ .name = "error_union", .expected_message = "stash: error unions are not supported" },
    .{ .name = "vector", .expected_message = "stash: vectors are not supported" },
    .{ .name = "tagged_union", .expected_message = "stash: unions are not supported" },
    .{ .name = "extern_union", .expected_message = "stash: unions are not supported" },
    .{ .name = "packed_union", .expected_message = "stash: unions are not supported" },
    .{ .name = "auto_struct", .expected_message = "stash: stored structs must be extern or packed" },
    .{ .name = "void_type", .expected_message = "stash: type is not storable" },
    .{ .name = "packed_float", .expected_message = "stash: packed fields must be integers, bools, enums, or packed structs" },

    .{ .name = "nested_pointer", .expected_message = "stash: stored values must not contain pointers" },
    .{ .name = "nested_array_pointer", .expected_message = "stash: stored values must not contain pointers" },
    .{ .name = "empty_pointer_array", .expected_message = "stash: stored values must not contain pointers" },
    .{ .name = "nested_implicit_padding", .expected_message = "stash: implicit field padding is not supported" },
    .{ .name = "implicit_padding", .expected_message = "stash: implicit field padding is not supported" },
    .{ .name = "tail_padding", .expected_message = "stash: implicit tail padding is not supported" },
    .{ .name = "explicit_field_alignment", .expected_message = "stash: implicit field padding is not supported" },

    .{ .name = "sentinel_array", .expected_message = "stash: sentinel arrays are not supported" },
    .{ .name = "empty_sentinel_array", .expected_message = "stash: sentinel arrays are not supported" },
    .{ .name = "nested_sentinel_array", .expected_message = "stash: sentinel arrays are not supported" },
    .{ .name = "sentinel_struct", .expected_message = "stash: sentinel arrays are not supported" },
    .{ .name = "sentinel_slice_element", .expected_message = "stash: sentinel arrays are not supported" },
    .{ .name = "sentinel_slice", .expected_message = "stash: sentinel slices are not supported" },
    .{ .name = "volatile_slice", .expected_message = "stash: volatile slices are not supported" },
    .{ .name = "allowzero_slice", .expected_message = "stash: allowzero slices are not supported" },
    .{ .name = "overaligned_slice", .expected_message = "stash: slices must use natural alignment" },
    .{ .name = "underaligned_slice", .expected_message = "stash: slices must use natural alignment" },
    .{ .name = "sentinel_ragged_child", .expected_message = "stash: sentinel slices are not supported" },

    .{ .name = "nonstruct_schema", .expected_message = "stash: Layout expects a struct type" },
    .{ .name = "tuple_schema", .expected_message = "stash: Layout expects named fields, not a tuple" },
    .{ .name = "comptime_schema", .expected_message = "stash: Layout fields must not be comptime" },
    .{ .name = "aligned_schema", .expected_message = "stash: Layout fields must use natural alignment" },
    .{ .name = "constructor_default", .expected_message = "stash: explicit storage constructors cannot have schema defaults" },

    .{ .name = "nonstruct_columns", .expected_message = "stash: Columns expects a struct type" },
    .{ .name = "empty_columns", .expected_message = "stash: Columns row type must have at least one field" },
    .{ .name = "comptime_column", .expected_message = "stash: Columns fields must not be comptime" },
    .{ .name = "aligned_column", .expected_message = "stash: Columns fields must use natural alignment" },
    .{ .name = "sentinel_column", .expected_message = "stash: sentinel slices are not supported" },
    .{ .name = "mutable_column", .expected_message = "stash: Columns slice fields must be []const T" },
    .{ .name = "zero_sized_column", .expected_message = "stash: Columns ragged fields must have nonzero-sized elements" },
    .{ .name = "duplicate_packed_field", .expected_message = "stash: Columns packed_fields must not contain duplicates" },

    .{ .name = "packed_full_width", .expected_message = "stash: PackedSlice requires packing to save space" },
    .{ .name = "packed_zero_width", .expected_message = "stash: PackedSlice elements must have nonzero bit width" },
    .{ .name = "packed_float_element", .expected_message = "stash: PackedSlice supports only integers, bools, enums, and packed structs" },

    .{ .name = "zero_sized_slice", .expected_message = "stash: slices cannot store zero-sized elements" },
    .{ .name = "zero_sized_ragged", .expected_message = "stash: ragged slices do not support zero-sized elements" },

    .{ .name = "unsupported_initialization", .expected_message = "stash: initialization supports only fixed values and ordinary slices" },
    .{ .name = "unsupported_sizer", .expected_message = "stash: Sizer supports only fixed values and Columns" },
    .{ .name = "append_fixed_field", .expected_message = "stash: tryAppend requires a columnar field" },
};

pub fn addCases(b: *std.Build, step: *std.Build.Step, module: *std.Build.Module) void {
    for (cases) |case| addCase(b, step, module, case.name, case.expected_message);
}

fn addCase(
    b: *std.Build,
    step: *std.Build.Step,
    module: *std.Build.Module,
    name: []const u8,
    expected_message: []const u8,
) void {
    const fixture = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("testing/compile_error_cases/{s}.zig", .{name})),
            .target = module.resolved_target,
            .optimize = module.optimize,
            .imports = &.{.{ .name = "stash", .module = module }},
        }),
    });
    fixture.expect_errors = .{ .contains = expected_message };
    step.dependOn(&fixture.step);
}
