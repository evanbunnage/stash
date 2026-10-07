//! It's helpful for users and LLMs to have some way of visualizing their stash Layout schema.
//!
//! I found LLMs each have their own ways of computing this and it's not always as informative as users expect.
//!
//! These tools compute and print out both the layout schemas and break down the bytes stored in a
//! filled buffer.
//!
//! Format.describe() returns a SchemaReport, and Format.inspect(buffer)
//! returns a BufferReport showing where each region of a validated buffer sits, separating stored
//! values from stash metadata and padding. Print either one with {f}
//!
//! ```zig
//! std.debug.print("{f}\n", .{Format.describe()});
//! std.debug.print("{f}\n", .{try Format.inspect(buffer)});
//! ```

const std = @import("std");
const bytes = @import("bytes.zig");
const blocks = @import("blocks.zig");
const RaggedSliceBlock = @import("blocks/ragged_slice.zig").RaggedSliceBlock;
const packed_slice = @import("blocks/packed_slice.zig");
const Columns = @import("blocks/columnar.zig").Columns;
const Layout = @import("layout.zig").Layout;

/// Lists the format's alignment and each field's storage and input type
pub fn SchemaReport(comptime Schema: type, comptime alignment: usize) type {
    const layout_info = @typeInfo(Schema).@"struct";
    return struct {
        pub fn format(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const type_width = comptime blk: {
                var longest: usize = "Type".len;
                for (layout_info.field_types) |FieldType| {
                    const Block = blocks.resolveBlockType(FieldType);
                    longest = @max(longest, typeName(Block.Input).len);
                }
                break :blk longest;
            };
            const field_width = comptime fieldWidth(Schema);
            const widths = .{ field_width, 22, type_width };
            try writeBorder(writer, &widths);
            try writeLabel(writer, field_width, "Field");
            try writer.print(" {s:<22} | ", .{"Stored as"});
            try writer.writeAll("Type");
            try writer.splatByteAll(' ', type_width - "Type".len);
            try writer.writeAll(" |\n");
            try writeBorder(writer, &widths);
            inline for (layout_info.field_names, layout_info.field_types) |field_name, FieldType| {
                const Block = blocks.resolveBlockType(FieldType);
                const storage: []const u8 = switch (Block.stash_block_info.kind) {
                    .value => "Single value",
                    .slice => "Contiguous slice",
                    .ragged_slice => "Variable-length slices",
                    .packed_slice => "Bit-packed slice",
                    .columnar => "Columns",
                    else => unreachable,
                };
                try writeLabel(writer, field_width, field_name);
                const type_name = comptime typeName(Block.Input);
                try writer.print(" {s:<22} | {s}", .{ storage, type_name });
                try writer.splatByteAll(' ', type_width - type_name.len);
                try writer.writeAll(" |\n");
            }
            try writeBorder(writer, &widths);
            try writer.print("Alignment: {d}\n", .{alignment});
        }
    };
}

/// Lists each region of a validated buffer with its byte offset and size, then totals the bytes
/// used by stored values, stash metadata, and padding. Stored values are not printed.
/// The report borrows the buffer, which must remain valid and unchanged while the report is in use
pub fn BufferReport(comptime Schema: type, comptime alignment: usize, comptime View: type, comptime Ranges: type) type {
    const layout_info = @typeInfo(Schema).@"struct";
    return struct {
        payload: []const u8,
        views: View,
        // Each block's offset and size in schema field order
        ranges: Ranges,
        table_offset: usize,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const table_size = self.payload.len - self.table_offset;

            // Counts normally fit within the buffer size, but zero-sized arrays and columns can exceed it
            var largest_count = self.payload.len;
            inline for (layout_info.field_names, layout_info.field_types) |field_name, FieldType| {
                const Block = blocks.resolveBlockType(FieldType);
                largest_count = @max(largest_count, storedEntryCount(Block, @field(self.views, field_name)) orelse 0);
            }
            const field_width = comptime fieldWidth(Schema);
            const region_width = field_width + 5 + std.fmt.count("{d}", .{largest_count});
            const widths = .{ region_width, 12, 12 };
            try writeBorder(writer, &widths);
            try writer.writeAll("| Region");
            try writer.splatByteAll(' ', region_width - "Region".len);
            try writer.print(" | {s:>12} | {s:>12} |\n", .{ "Offset", "Size" });
            try writeBorder(writer, &widths);
            var cursor: usize = 0;
            var value_bytes: usize = 0;
            var metadata_bytes: usize = table_size;
            inline for (layout_info.field_names, layout_info.field_types, self.ranges) |field_name, FieldType, range| {
                if (range.offset > cursor) {
                    try writeRange(writer, region_width, "  [padding]", cursor, range.offset - cursor, null);
                }
                const Block = blocks.resolveBlockType(FieldType);
                const block_view = @field(self.views, field_name);
                value_bytes += storedValueByteCount(Block, block_view);
                metadata_bytes += blockMetadataByteCount(Block, block_view);
                try writeBlockRegions(Block, writer, region_width, self.payload[range.offset..][0..range.size], range.offset, field_name, block_view);
                cursor = range.offset + range.size;
            }
            if (self.table_offset > cursor) {
                try writeRange(writer, region_width, "  [padding]", cursor, self.table_offset - cursor, null);
            }
            try writeRange(writer, region_width, "  [footer]", self.table_offset, table_size, null);
            try writeBorder(writer, &widths);
            try writer.print("\nYour data:        {d:>6} bytes\nStash metadata:   {d:>6} bytes\nStash padding:    {d:>6} bytes\n------------------------------\nTotal:            {d:>6} bytes\n\nAlignment: {d}\n", .{
                value_bytes, metadata_bytes, self.payload.len - value_bytes - metadata_bytes, self.payload.len, alignment,
            });
        }
    };
}

// Leave room for both schema field names and the metadata rows
fn fieldWidth(comptime Schema: type) usize {
    const layout_info = @typeInfo(Schema).@"struct";
    var longest: usize = 18;
    for (layout_info.field_names, layout_info.field_types) |field_name, FieldType| {
        longest = @max(longest, field_name.len);
        const Block = blocks.resolveBlockType(FieldType);
        if (Block.stash_block_info.kind == .packed_slice or Block.stash_block_info.kind == .ragged_slice or Block.stash_block_info.kind == .columnar) {
            longest = @max(longest, 4 + field_name.len + " offsets".len);
        }
        if (Block.stash_block_info.kind == .columnar) {
            longest = @max(longest, 4 + field_name.len + " column directory".len);
            const row_info = @typeInfo(Block.stash_block_info.Element).@"struct";
            for (row_info.field_names, row_info.field_types) |column_name, ColumnType| {
                longest = @max(longest, field_name.len + 1 + column_name.len);
                if (@typeInfo(ColumnType) == .pointer) {
                    longest = @max(longest, 4 + field_name.len + 1 + column_name.len + " offsets".len);
                }
            }
        }
    }
    return longest + 2;
}

fn writeBorder(writer: *std.Io.Writer, widths: []const usize) std.Io.Writer.Error!void {
    try writer.writeByte('+');
    for (widths) |width| {
        try writer.splatByteAll('-', width + 2);
        try writer.writeByte('+');
    }
    try writer.writeByte('\n');
}

fn writeLabel(writer: *std.Io.Writer, width: usize, label: []const u8) std.Io.Writer.Error!void {
    try writer.print("| {s}", .{label});
    try writer.splatByteAll(' ', width - label.len);
    try writer.writeAll(" |");
}

fn writeRange(writer: *std.Io.Writer, width: usize, label: []const u8, offset: usize, size: usize, count: ?usize) std.Io.Writer.Error!void {
    try writer.print("| {s}", .{label});
    var label_size = label.len;
    if (count) |entries| {
        try writer.print(" (n={d})", .{entries});
        label_size += std.fmt.count(" (n={d})", .{entries});
    }
    try writer.splatByteAll(' ', width - label_size);
    try writer.print(" | {d:>12} | {d:>12} |\n", .{ offset, size });
}

// Print each byte range once, using absolute offsets within the validated buffer.
// Metadata is indented, while stored fields retain their schema names
fn writeBlockRegions(
    comptime Block: type,
    writer: *std.Io.Writer,
    width: usize,
    buffer: []const u8,
    offset: usize,
    comptime name: []const u8,
    block_view: Block.View,
) std.Io.Writer.Error!void {
    const info = Block.stash_block_info;
    switch (info.kind) {
        .packed_slice => {
            const data_offset = @intFromPtr(block_view.data.ptr) - @intFromPtr(buffer.ptr);
            try writeRange(writer, width, "  [`" ++ name ++ "` counts]", offset, data_offset, null);
            try writeRange(writer, width, name, offset + data_offset, block_view.data.len, block_view.len());
        },
        .ragged_slice => {
            const offsets_size = std.mem.sliceAsBytes(block_view.offsets).len;
            const values_offset = @intFromPtr(block_view.values.ptr) - @intFromPtr(buffer.ptr);
            const metadata_end = @sizeOf(u32) + offsets_size;
            try writeRange(writer, width, "  [`" ++ name ++ "` counts]", offset, @sizeOf(u32), null);
            try writeRange(writer, width, "  [`" ++ name ++ "` offsets]", offset + @sizeOf(u32), offsets_size, null);
            if (values_offset > metadata_end) {
                try writeRange(writer, width, "  [padding]", offset + metadata_end, values_offset - metadata_end, null);
            }
            try writeRange(writer, width, name, offset + values_offset, std.mem.sliceAsBytes(block_view.values).len, block_view.len());
        },
        .columnar => {
            // Columnar storage begins with two u32 counts and an offset/size pair per column
            const row_info = @typeInfo(info.Element).@"struct";
            const counts_size = 2 * @sizeOf(u32);
            const Entry = extern struct { offset: u32, size: u32 };
            const table_size = row_info.field_names.len * @sizeOf(Entry);
            try writeRange(writer, width, "  [`" ++ name ++ "` counts]", offset, counts_size, null);
            try writeRange(writer, width, "  [`" ++ name ++ "` column directory]", offset + counts_size, table_size, null);
            var cursor = counts_size + table_size;
            inline for (row_info.field_names, row_info.field_types, 0..) |column_name, ColumnType, index| {
                const entry = bytes.copyValue(Entry, buffer[counts_size + index * @sizeOf(Entry) ..]) catch unreachable;
                if (entry.offset > cursor) {
                    try writeRange(writer, width, "  [padding]", offset + cursor, entry.offset - cursor, null);
                }
                const field_id = @field(Block.Field, column_name);
                if (comptime std.mem.indexOfScalar(Block.Field, info.options.packed_fields, field_id) == null and @typeInfo(ColumnType) == .pointer) {
                    const ChildBlock = RaggedSliceBlock(@typeInfo(ColumnType).pointer.child);
                    try writeBlockRegions(ChildBlock, writer, width, buffer[entry.offset..][0..entry.size], offset + entry.offset, name ++ "." ++ column_name, block_view.column(field_id));
                } else {
                    try writeRange(writer, width, name ++ "." ++ column_name, offset + entry.offset, entry.size, block_view.len());
                }
                cursor = @as(usize, entry.offset) + entry.size;
            }
        },
        else => try writeRange(writer, width, name, offset, buffer.len, storedEntryCount(Block, block_view)),
    }
}

// Preserve slice and array syntax while omitting module names from named element types
fn typeName(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| "[]" ++ (if (pointer.attrs.@"const") "const " else "") ++ typeName(pointer.child),
        .array => |array| std.fmt.comptimePrint("[{d}]{s}", .{ array.len, typeName(array.child) }),
        .@"struct", .@"enum" => blk: {
            const name = @typeName(T);
            const start = if (std.mem.lastIndexOfScalar(u8, name, '.')) |index| index + 1 else 0;
            break :blk name[start..];
        },
        else => @typeName(T),
    };
}

// A ragged field counts child slices, and a columnar field counts rows
fn storedEntryCount(comptime Block: type, block_view: Block.View) ?usize {
    return switch (Block.stash_block_info.kind) {
        .value => switch (@typeInfo(Block.stash_block_info.Element)) {
            .array => |array| array.len,
            else => null,
        },
        .slice => block_view.len,
        .ragged_slice, .packed_slice, .columnar => block_view.len(),
        else => unreachable,
    };
}

// Count only the bytes occupied by values in an already validated view.
// The remaining bytes belong to stash metadata and alignment, including inside columnar blocks
// Count headers and offset tables separately from padding and stored values
fn blockMetadataByteCount(comptime Block: type, block_view: Block.View) usize {
    const info = Block.stash_block_info;
    return switch (info.kind) {
        .value, .slice => 0,
        .packed_slice => @sizeOf(u32),
        .ragged_slice => @sizeOf(u32) + std.mem.sliceAsBytes(block_view.offsets).len,
        .columnar => count: {
            const row_info = @typeInfo(info.Element).@"struct";
            var total: usize = 2 * @sizeOf(u32) + row_info.field_names.len * 2 * @sizeOf(u32);
            inline for (row_info.field_names, row_info.field_types) |column_name, ColumnType| {
                const field_id = @field(Block.Field, column_name);
                if (comptime @typeInfo(ColumnType) == .pointer and std.mem.indexOfScalar(Block.Field, info.options.packed_fields, field_id) == null) {
                    const column = block_view.column(field_id);
                    total += @sizeOf(u32) + std.mem.sliceAsBytes(column.offsets).len;
                }
            }
            break :count total;
        },
        else => unreachable,
    };
}

fn storedValueByteCount(comptime Block: type, block_view: Block.View) usize {
    const info = Block.stash_block_info;
    return switch (info.kind) {
        .value => @sizeOf(info.Element),
        .slice => std.mem.sliceAsBytes(block_view).len,
        .ragged_slice => std.mem.sliceAsBytes(block_view.values).len,
        .packed_slice => block_view.data.len,
        .columnar => count: {
            var total: usize = 0;
            const row_info = @typeInfo(info.Element).@"struct";
            inline for (row_info.field_names, row_info.field_types) |column_name, ColumnType| {
                const field_id = @field(Block.Field, column_name);
                const column = block_view.column(field_id);
                if (comptime std.mem.indexOfScalar(Block.Field, info.options.packed_fields, field_id) != null) {
                    total += column.data.len;
                } else if (comptime @typeInfo(ColumnType) == .pointer) {
                    total += std.mem.sliceAsBytes(column.values).len;
                } else {
                    total += std.mem.sliceAsBytes(column).len;
                }
            }
            break :count total;
        },
        else => unreachable,
    };
}

test "Layout describe() lists each field's storage and input type" {
    const RoverMode = enum(u2) { parked, driving, charging };
    const Status = enum(u8) { pending, complete };
    const Row = struct { id: u32 };
    const Format = Layout(struct {
        version: u8,
        samples: []const u32,
        names: []const []const u8,
        states: packed_slice.PackedSlice(RoverMode),
        history: [2]Status,
        rows: Columns(Row, .{}),
    });
    try std.testing.expectFmt(
        \\+-----------------------------+------------------------+--------------------+
        \\| Field                       | Stored as              | Type               |
        \\+-----------------------------+------------------------+--------------------+
        \\| version                     | Single value           | u8                 |
        \\| samples                     | Contiguous slice       | []const u32        |
        \\| names                       | Variable-length slices | []const []const u8 |
        \\| states                      | Bit-packed slice       | []const RoverMode  |
        \\| history                     | Single value           | [2]Status          |
        \\| rows                        | Columns                | []const Row        |
        \\+-----------------------------+------------------------+--------------------+
        \\Alignment: 8
        \\
    , "{f}", .{Format.describe()});
}

test "Layout inspect() accounts for blocks, alignment gaps, and the size table" {
    const Format = Layout(struct {
        version: u8,
        samples: []const u32,
        states: packed_slice.PackedSlice(u2),
    });
    var buffer: [48]u8 align(Format.alignment) = undefined;
    const payload = try Format.write(&buffer, .{
        .version = 1,
        .samples = &.{ 10, 20 },
        .states = &.{ 0, 1, 2 },
    });
    try std.testing.expectFmt(
        \\+-----------------------------+--------------+--------------+
        \\| Region                      |       Offset |         Size |
        \\+-----------------------------+--------------+--------------+
        \\| version                     |            0 |            1 |
        \\|   [padding]                 |            1 |            3 |
        \\| samples (n=2)               |            4 |            8 |
        \\|   [`states` counts]         |           12 |            4 |
        \\| states (n=3)                |           16 |            1 |
        \\|   [padding]                 |           17 |            7 |
        \\|   [footer]                  |           24 |           24 |
        \\+-----------------------------+--------------+--------------+
        \\
        \\Your data:            10 bytes
        \\Stash metadata:       28 bytes
        \\Stash padding:        10 bytes
        \\------------------------------
        \\Total:                48 bytes
        \\
        \\Alignment: 8
        \\
    , "{f}", .{try Format.inspect(payload)});
}

test "Layout inspect() rejects buffers that view() rejects" {
    const State = enum(u8) { ready = 1 };
    const Format = Layout(struct { state: State });
    var buffer: [16]u8 align(Format.alignment) = undefined;
    const payload = try Format.write(&buffer, .{ .state = .ready });
    payload[0] = 2;
    try std.testing.expectError(error.InvalidValue, Format.inspect(payload));
    payload[0] = 1;
    payload[1] = 1;
    try std.testing.expectError(error.InvalidFormat, Format.inspect(payload));
}

test "Layout inspect() separates ragged and columnar metadata from stored values" {
    const Row = struct { id: u32, name: []const u8, active: bool };
    const Header = extern struct { version: u8, reserved: [3]u8 = @splat(0), limit: u32 };
    const Format = Layout(struct {
        header: Header,
        groups: []const []const u64,
        rows: Columns(Row, .{ .packed_fields = &.{.active} }),
    });
    var buffer: [136]u8 align(Format.alignment) = undefined;
    const payload = try Format.write(&buffer, .{
        .header = .{ .version = 1, .limit = 10 },
        .groups = &.{ &.{ 1, 2 }, &.{}, &.{} },
        .rows = &.{
            .{ .id = 1, .name = "ab", .active = true },
            .{ .id = 2, .name = "", .active = false },
        },
    });
    // Header: 8, grouped integers: 16, IDs: 8, string bytes: 2, packed booleans: 1
    // Three ragged children also require four bytes of alignment after their offset table
    try std.testing.expectFmt(
        \\+-------------------------------------+--------------+--------------+
        \\| Region                              |       Offset |         Size |
        \\+-------------------------------------+--------------+--------------+
        \\| header                              |            0 |            8 |
        \\|   [`groups` counts]                 |            8 |            4 |
        \\|   [`groups` offsets]                |           12 |           16 |
        \\|   [padding]                         |           28 |            4 |
        \\| groups (n=3)                        |           32 |           16 |
        \\|   [`rows` counts]                   |           48 |            8 |
        \\|   [`rows` column directory]         |           56 |           24 |
        \\| rows.id (n=2)                       |           80 |            8 |
        \\|   [`rows.name` counts]              |           88 |            4 |
        \\|   [`rows.name` offsets]             |           92 |           12 |
        \\| rows.name (n=2)                     |          104 |            2 |
        \\| rows.active (n=2)                   |          106 |            1 |
        \\|   [padding]                         |          107 |            5 |
        \\|   [footer]                          |          112 |           24 |
        \\+-------------------------------------+--------------+--------------+
        \\
        \\Your data:            35 bytes
        \\Stash metadata:       92 bytes
        \\Stash padding:         9 bytes
        \\------------------------------
        \\Total:               136 bytes
        \\
        \\Alignment: 8
        \\
    , "{f}", .{try Format.inspect(payload)});
}
