//! The Columns block type will transpose a struct's fields into a columnar format:
//!
//! Input rows:
//! .{ .id = 1, .name = "one" }
//! .{ .id = 2, .name = "two" }
//!
//! Columns:
//! id:   { 1, 2 }
//! name: { "one", "two" }
//!
//! A stash-managed table records each column's byte offset and size so views can access individual columns

const std = @import("std");
const blocks = @import("../blocks.zig");
const bytes = @import("../bytes.zig");
const comptime_validation = @import("../comptime_validation.zig");
const runtime_validation = @import("../runtime_validation.zig");
const packed_slice = @import("packed_slice.zig");
const ragged_slice = @import("ragged_slice.zig");

const ViewMode = enum { read_only, mutable };
const Validation = enum { checked, assume_valid };

pub fn ColumnOptions(comptime Row: type) type {
    comptime comptime_validation.assertStructHasSupportedSchemaFields(Row, "Columns");
    return struct {
        /// Store packed fields using their bit widths rather than whole bytes
        packed_fields: []const std.meta.FieldEnum(Row) = &.{},
    };
}

/// Store each field of Row in a separate column.
/// Slice fields use ragged storage, and fields listed in packed_fields use packed bits
pub fn Columns(comptime Row: type, comptime options: ColumnOptions(Row)) type {
    const row_fields = @typeInfo(Row).@"struct".fields;
    if (row_fields.len == 0) {
        @compileError("stash: Columns row type must have at least one field\n" ++
            "  received '" ++ @typeName(Row) ++ "'");
    }

    const columns: [row_fields.len]Column = blk: {
        var is_packed = [_]bool{false} ** row_fields.len;
        for (options.packed_fields) |packed_column| {
            if (is_packed[@intFromEnum(packed_column)]) {
                @compileError("stash: Columns packed_fields must not contain duplicates\n" ++
                    "  field '" ++ @tagName(packed_column) ++ "' is listed more than once");
            }
            is_packed[@intFromEnum(packed_column)] = true;
        }
        var result: [row_fields.len]Column = undefined;
        for (row_fields, 0..) |field, i| {
            result[i] = .{
                .name = field.name,
                .type = field.type,
                .kind = if (is_packed[i]) .packed_bits else if (isSlice(field.type)) .ragged_slice else .fixed,
            };
        }
        break :blk result;
    };

    comptime validateColumns(&columns);

    return struct {
        // Layout uses this to recognize the block and recover its element type and options
        pub const stash_block_info = .{ .kind = .columnar, .Element = Row, .options = options };
        pub const alignment = blockAlignment(&columns);
        pub const Input = []const Row;
        pub const Field = std.meta.FieldEnum(Row);

        pub const View = ViewType(.read_only);
        pub const MutableView = ViewType(.mutable);
        pub const RowIterator = View.Iterator;

        fn ViewType(comptime view_mode: ViewMode) type {
            return struct {
                row_count: usize,
                columns: columnViewsType(&columns, view_mode),

                pub fn len(self: @This()) usize {
                    return self.row_count;
                }

                /// Return a view of one field across all rows.
                /// Ordinary columns return slices. Packed and ragged columns provide len() and get().
                /// Mutable views allow edits through those slices and packed columns' set() methods
                pub fn column(
                    self: @This(),
                    comptime field: Field,
                ) fieldView(columns[@intFromEnum(field)], view_mode) {
                    return @field(self.columns, @tagName(field));
                }

                /// Read one field from the row at index i, regardless of how its column is stored
                pub fn value(
                    self: @This(),
                    comptime field: Field,
                    index: usize,
                ) blocks.IndexError!columns[@intFromEnum(field)].type {
                    if (index >= self.row_count) return error.IndexOutOfBounds;
                    const column_view = self.column(field);
                    return switch (columns[@intFromEnum(field)].kind) {
                        .fixed => column_view[index],
                        .packed_bits, .ragged_slice => column_view.get(index),
                    };
                }

                /// Return the row at index i by collecting its fields from the respective columns
                /// Think of this as row-level access in columnar data, not super efficient but possible
                pub fn get(self: @This(), index: usize) blocks.IndexError!Row {
                    if (index >= self.row_count) return error.IndexOutOfBounds;
                    var row: Row = undefined;
                    inline for (row_fields) |field| {
                        @field(row, field.name) = try self.value(@field(Field, field.name), index);
                    }
                    return row;
                }

                /// Read the stored rows in order
                pub fn iterator(self: @This()) Iterator {
                    return .{ .view = self };
                }

                const Iterator = struct {
                    view: ViewType(view_mode),
                    index: usize = 0,

                    /// Return the next row, or null when there are no rows left
                    pub fn next(self: *@This()) ?Row {
                        if (self.index >= self.view.len()) return null;
                        defer self.index += 1;
                        return self.view.get(self.index) catch unreachable;
                    }
                };
            };
        }

        /// Include the header, column table, alignment gaps, and column contents
        pub fn encodedSize(rows: Input) blocks.BufferSizeError!usize {
            return (try sizeFromRows(rows)).encodedSize();
        }

        // Count the ragged elements once so sizing and writing can use the same counts
        fn sizeFromRows(rows: Input) blocks.BufferSizeError!Sizer {
            if (rows.len > std.math.maxInt(u32)) return error.InputTooLarge;
            var current_size: Sizer = .{ .row_count = rows.len };
            inline for (columns, 0..) |column, index| {
                if (column.kind == .ragged_slice) {
                    for (rows) |row| {
                        current_size.value_counts[index] = std.math.add(usize, current_size.value_counts[index], @field(row, column.name).len) catch return error.InputTooLarge;
                    }
                }
            }
            return current_size;
        }

        /// Calculate how much space rows will need without keeping the rows themselves.
        /// To check whether another row would fit, copy the Sizer, call append(), and check encodedSize()
        pub const Sizer = struct {
            row_count: usize = 0,
            value_counts: [columns.len]usize = @splat(0),

            /// Add one row to the counts without retaining its values
            pub fn append(self: *@This(), row: Row) blocks.BufferSizeError!void {
                var next = self.*;
                if (next.row_count >= std.math.maxInt(u32)) return error.InputTooLarge;
                next.row_count += 1;
                inline for (columns, 0..) |column, i| {
                    if (column.kind == .ragged_slice) {
                        next.value_counts[i] = std.math.add(usize, next.value_counts[i], @field(row, column.name).len) catch return error.InputTooLarge;
                    }
                }
                self.* = next;
            }

            /// Return the bytes needed for the rows added so far
            pub fn encodedSize(self: @This()) blocks.BufferSizeError!usize {
                if (self.row_count > std.math.maxInt(u32)) return error.InputTooLarge;
                var byte_count = dataStartOffset(columns.len);
                inline for (columns, 0..) |column, i| {
                    const offset = try blocks.alignForward(byte_count, fieldAlignment(column));
                    const size = switch (column.kind) {
                        .fixed => std.math.mul(usize, self.row_count, @sizeOf(column.type)) catch return error.InputTooLarge,
                        .ragged_slice => (try ragged_slice.layoutFromCounts(sliceChild(column.type), self.row_count, self.value_counts[i])).end,
                        .packed_bits => try packed_slice.packedByteCount(column.type, self.row_count),
                    };
                    if (offset > std.math.maxInt(u32) or size > std.math.maxInt(u32)) return error.InputTooLarge;
                    byte_count = std.math.add(usize, offset, size) catch return error.InputTooLarge;
                }
                return byte_count;
            }
        };

        /// Copy each field's values into its column and return the number of bytes written.
        /// The destination buffer must meet this block's alignment requirement
        pub fn encode(dest_buffer: []u8, rows: Input) blocks.WriteError!usize {
            const current_size = try sizeFromRows(rows);
            const byte_count = try current_size.encodedSize();
            if (dest_buffer.len < byte_count) return error.NoSpaceLeft;
            if (@intFromPtr(dest_buffer.ptr) % alignment != 0) return error.MisalignedBuffer;
            const directory_end = dataStartOffset(columns.len);

            bytes.writeValue(ColumnarHeader, dest_buffer[0..@sizeOf(ColumnarHeader)], .{
                .row_count = @intCast(rows.len),
                .field_count = @intCast(columns.len),
            });

            var cursor = directory_end;
            inline for (columns, 0..) |column, field_index| {
                const offset = try blocks.alignForward(cursor, fieldAlignment(column));
                if (offset > dest_buffer.len) return error.NoSpaceLeft;
                @memset(dest_buffer[cursor..offset], 0);

                const size = switch (column.kind) {
                    .fixed => try encodeFixedField(column.type, column.name, dest_buffer[offset..], rows),
                    .packed_bits => try encodePackedField(column.type, column.name, dest_buffer[offset..], rows),
                    .ragged_slice => try encodeRaggedField(column.type, column.name, dest_buffer[offset..], rows, current_size.value_counts[field_index]),
                };
                const entry_offset = @sizeOf(ColumnarHeader) + field_index * @sizeOf(FieldEntry);
                bytes.writeValue(FieldEntry, dest_buffer[entry_offset..][0..@sizeOf(FieldEntry)], .{
                    .offset = std.math.cast(u32, offset) orelse return error.InputTooLarge,
                    .size = std.math.cast(u32, size) orelse return error.InputTooLarge,
                });
                cursor = std.math.add(usize, offset, size) catch return error.InputTooLarge;
            }

            return cursor;
        }

        /// Check the column positions and stored values before returning a view
        pub fn view(buffer: []const u8) blocks.ViewError!View {
            return viewImpl(buffer, .checked);
        }

        /// Return a view without scanning the stored values or ragged offsets. Use this when those
        /// bytes are already known to be valid
        /// Note that the column positions, sizes, and padding are still checked
        pub fn viewAssumeValid(buffer: []const u8) blocks.ViewError!View {
            // My rationale is that they're easy to amortize and valuable, so why not
            return viewImpl(buffer, .assume_valid);
        }

        /// Validate the buffer and return mutable columns in place
        pub fn viewMutable(buffer: []u8) blocks.ViewError!MutableView {
            const checked = try view(buffer);
            var result: MutableView = .{ .row_count = checked.row_count, .columns = undefined };
            // Every column borrows this mutable buffer. Make its elements writable, leaving offsets read-only
            inline for (columns) |column| {
                const source = @field(checked.columns, column.name);
                @field(result.columns, column.name) = switch (column.kind) {
                    .fixed => @constCast(source),
                    .ragged_slice => .{ .offsets = source.offsets, .values = @constCast(source.values) },
                    .packed_bits => .{ .data = @constCast(source.data), .count = source.count },
                };
            }
            return result;
        }

        fn viewImpl(buffer: []const u8, comptime validation: Validation) blocks.ViewError!View {
            if (buffer.len < dataStartOffset(columns.len)) return error.BufferTooSmall;

            const header = bytes.copyValue(ColumnarHeader, buffer) catch unreachable;
            if (header.field_count != columns.len) return error.InvalidFormat;

            const row_count = std.math.cast(usize, header.row_count) orelse return error.InvalidFormat;
            const directory_start = @sizeOf(ColumnarHeader);
            const directory_end = dataStartOffset(columns.len);
            const entries = try bytes.viewSlice(
                FieldEntry,
                buffer[directory_start..directory_end],
                columns.len,
            );

            var result: View = undefined;
            result.row_count = row_count;

            // Each column follows the previous one
            var previous_column_end: usize = directory_end;
            inline for (columns, 0..) |column, field_index| {
                const entry = entries[field_index];
                const offset: usize = entry.offset;
                const column_size: usize = entry.size;
                const end = std.math.add(usize, offset, column_size) catch return error.InvalidFormat;
                const expected_offset = blocks.alignForward(previous_column_end, fieldAlignment(column)) catch return error.InvalidFormat;
                if (offset != expected_offset) return error.InvalidFormat;
                if (end > buffer.len) return error.BufferTooSmall;
                if (!std.mem.allEqual(u8, buffer[previous_column_end..offset], 0)) return error.InvalidFormat;
                previous_column_end = end;

                const column_buffer = buffer[offset..end];
                @field(result.columns, column.name) = switch (column.kind) {
                    .fixed => blk: {
                        const expected = std.math.mul(usize, row_count, @sizeOf(column.type)) catch return error.InvalidFormat;
                        if (column_buffer.len != expected) return error.InvalidFormat;
                        const values = try bytes.viewSlice(column.type, column_buffer, row_count);
                        if (comptime validation == .checked) {
                            try runtime_validation.validateValues(column.type, column_buffer, row_count);
                        }
                        break :blk values;
                    },
                    .ragged_slice => blk: {
                        const Block = ragged_slice.RaggedSliceBlock(sliceChild(column.type));
                        const children = if (validation == .checked)
                            try Block.view(column_buffer)
                        else
                            try Block.viewAssumeValid(column_buffer);
                        if (children.len() != row_count) return error.InvalidFormat;
                        break :blk children;
                    },
                    .packed_bits => blk: {
                        const expected = packed_slice.packedByteCount(column.type, row_count) catch return error.InvalidFormat;
                        if (column_buffer.len != expected) return error.InvalidFormat;
                        try packed_slice.validateRegionPadding(column.type, column_buffer, row_count);
                        if (comptime validation == .checked and runtime_validation.needsPackedValueValidation(column.type)) {
                            for (0..row_count) |index| try packed_slice.validateElement(column.type, column_buffer, index);
                        }
                        break :blk .{ .data = column_buffer, .count = row_count };
                    },
                };
            }

            if (previous_column_end != buffer.len) return error.InvalidFormat;

            return result;
        }
    };
}

// Each columnar block starts with the row count and column count, both stored as u32
const ColumnarHeader = extern struct {
    row_count: u32,
    field_count: u32,
};

// The header is followed by one entry per column.
// Each entry gives the column's size in bytes and its byte offset from the block's start
const FieldEntry = extern struct {
    offset: u32,
    size: u32,
};

const FieldKind = enum {
    fixed,
    ragged_slice,
    packed_bits,
};

// Column metadata connects each row field to its storage representation
const Column = struct {
    name: [:0]const u8,
    type: type,
    kind: FieldKind,
};

fn isSlice(comptime T: type) bool {
    const type_info = @typeInfo(T);
    return type_info == .pointer and type_info.pointer.size == .slice;
}

fn sliceChild(comptime T: type) type {
    return @typeInfo(T).pointer.child;
}

// Check that each field's type is supported by its chosen storage
fn validateColumns(comptime columns: []const Column) void {
    for (columns) |column| {
        switch (column.kind) {
            .fixed => comptime_validation.assertStorable(column.type),
            .ragged_slice => {
                comptime_validation.assertSliceHasSupportedPointerAttributes(column.type);
                const pointer_info = @typeInfo(column.type).pointer;
                if (!pointer_info.is_const) {
                    @compileError("stash: Columns slice fields must be []const T\n" ++
                        "  field '" ++ column.name ++ "' has type '" ++ @typeName(column.type) ++ "'");
                }
                comptime_validation.assertStorable(pointer_info.child);
                if (@sizeOf(pointer_info.child) == 0) {
                    @compileError("stash: Columns ragged fields must have nonzero-sized elements\n" ++
                        "  field '" ++ column.name ++ "' has element type '" ++ @typeName(pointer_info.child) ++ "'");
                }
            },
            .packed_bits => packed_slice.assertPackable(column.type),
        }
    }
}

// The block must satisfy the alignment of both its metadata and its columns
fn blockAlignment(comptime columns: []const Column) usize {
    var max_alignment: usize = @max(@alignOf(ColumnarHeader), @alignOf(FieldEntry));
    for (columns) |column| {
        max_alignment = @max(max_alignment, fieldAlignment(column));
    }
    return max_alignment;
}

// Each column starts at an address aligned for its representation.
// Packed columns read individual bytes and need no additional alignment
fn fieldAlignment(comptime column: Column) usize {
    return switch (column.kind) {
        .fixed => @alignOf(column.type),
        .ragged_slice => ragged_slice.RaggedSliceBlock(sliceChild(column.type)).alignment,
        .packed_bits => 1,
    };
}

// Column data follows the header and column metadata table, with padding before columns that need alignment
fn dataStartOffset(column_count: usize) usize {
    return @sizeOf(ColumnarHeader) + column_count * @sizeOf(FieldEntry);
}

// Preserve the row field names so callers can access columns by name
fn columnViewsType(comptime columns: []const Column, comptime view_mode: ViewMode) type {
    var field_names: [columns.len][]const u8 = undefined;
    var field_types: [columns.len]type = undefined;
    var field_attrs: [columns.len]std.builtin.Type.StructField.Attributes = undefined;

    for (columns, 0..) |column, index| {
        const FieldView = fieldView(column, view_mode);
        field_names[index] = column.name;
        field_types[index] = FieldView;
        field_attrs[index] = .{ .@"align" = @alignOf(FieldView) };
    }

    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

// Pack this field's values together without a separate element count.
// The column uses the row count already stored in the block header
fn encodePackedField(
    comptime T: type,
    comptime field_name: []const u8,
    dest_buffer: []u8,
    rows: anytype,
) blocks.WriteError!usize {
    const byte_size = try packed_slice.packedByteCount(T, rows.len);
    if (dest_buffer.len < byte_size) return error.NoSpaceLeft;

    const region = dest_buffer[0..byte_size];
    @memset(region, 0); // Leave unused bits in the final byte at zero
    for (rows, 0..) |row, row_index| {
        packed_slice.writeElement(T, region, row_index, @field(row, field_name));
    }
    return byte_size;
}

// Copy this field from each row into a slice of stored values
fn encodeFixedField(
    comptime T: type,
    comptime field_name: []const u8,
    dest_buffer: []u8,
    rows: anytype,
) blocks.WriteError!usize {
    const byte_size = std.math.mul(usize, rows.len, @sizeOf(T)) catch return error.InputTooLarge;
    if (dest_buffer.len < byte_size) return error.NoSpaceLeft;

    const values = bytes.viewMutableSlice(T, dest_buffer, rows.len) catch |err| switch (err) {
        error.BufferTooSmall => unreachable,
        error.MisalignedBuffer => return error.MisalignedBuffer,
    };
    for (rows, 0..) |row, row_index| {
        values[row_index] = @field(row, field_name);
    }
    return byte_size;
}

// Write the slices from this field into one ragged block
fn encodeRaggedField(
    comptime Slice: type,
    comptime field_name: []const u8,
    dest_buffer: []u8,
    rows: anytype,
    value_count: usize,
) blocks.WriteError!usize {
    const T = sliceChild(Slice);
    var writer = try ragged_slice.RaggedSliceWriter(T).init(dest_buffer, rows.len, value_count);
    for (rows) |row| writer.append(@field(row, field_name));
    return writer.finish();
}

fn fieldView(comptime column: Column, comptime view_mode: ViewMode) type {
    return switch (column.kind) {
        .fixed => if (view_mode == .mutable) []column.type else []const column.type,
        .ragged_slice => if (view_mode == .mutable) ragged_slice.RaggedSliceBlock(sliceChild(column.type)).MutableView else ragged_slice.RaggedSliceBlock(sliceChild(column.type)).View,
        .packed_bits => if (view_mode == .mutable) packed_slice.PackedSlice(column.type).MutableView else packed_slice.PackedSlice(column.type).View,
    };
}

test "Columns writes fixed-size, ragged, and packed columns in the expected byte format" {
    const Row = struct { id: u16, name: []const u8, code: u2 };
    const Block = Columns(Row, .{ .packed_fields = &.{.code} });
    const rows = [_]Row{
        .{ .id = 1, .name = "a", .code = 1 },
        .{ .id = 2, .name = "bc", .code = 2 },
    };
    const expected = [_]u8{
        2,  0, 0, 0, 3,   0,   0,   0,
        32, 0, 0, 0, 4,   0,   0,   0,
        36, 0, 0, 0, 19,  0,   0,   0,
        55, 0, 0, 0, 1,   0,   0,   0,
        1,  0, 2, 0, 2,   0,   0,   0,
        0,  0, 0, 0, 1,   0,   0,   0,
        3,  0, 0, 0, 'a', 'b', 'c', 0x09,
    };
    var buffer: [expected.len]u8 align(Block.alignment) = undefined;
    const written = try Block.encode(&buffer, &rows);
    try std.testing.expectEqual(expected.len, written);
    try std.testing.expectEqualSlices(u8, &expected, &buffer);
    const view = try Block.view(&buffer);
    try std.testing.expectEqual(@as(u16, 2), try view.value(.id, 1));
    try std.testing.expectEqualSlices(u8, "bc", try view.value(.name, 1));
    try std.testing.expectEqual(@as(u2, 2), try view.value(.code, 1));
}

test "Columns view() and viewAssumeValid() return columns pointing into the buffer" {
    const Row = struct { name: []const u8, id: u32 };
    const Block = Columns(Row, .{});
    const rows = [_]Row{
        .{ .name = "one", .id = 1 },
        .{ .name = "two", .id = 2 },
    };
    var buffer: [128]u8 align(Block.alignment) = undefined;
    const written = try Block.encode(&buffer, &rows);
    try std.testing.expectEqual(try Block.encodedSize(&rows), written);

    const name_entry = try bytes.copyValue(FieldEntry, buffer[8..]);
    const id_entry = try bytes.copyValue(FieldEntry, buffer[16..]);
    // Two names need a four-byte count and three four-byte offsets before their bytes
    const name_address = @intFromPtr(&buffer) + name_entry.offset + 16;
    const id_address = @intFromPtr(&buffer) + id_entry.offset;
    for ([_]Block.View{
        try Block.view(buffer[0..written]),
        try Block.viewAssumeValid(buffer[0..written]),
    }) |view| {
        try std.testing.expectEqual(rows.len, view.len());
        try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, view.column(.id));
        try std.testing.expectEqual(id_address, @intFromPtr(view.column(.id).ptr));
        try std.testing.expectEqual(name_address, @intFromPtr((try view.value(.name, 0)).ptr));
        try std.testing.expectEqualStrings("two", try view.value(.name, 1));
    }
}

test "Columns stores packed enum values alongside ordinary integer values" {
    const Status = enum(u3) { pending, complete, failed };
    const Row = struct {
        status: Status, // Three bits per row
        len: u32, // One u32 per row
    };
    const Block = Columns(Row, .{ .packed_fields = &.{.status} });

    const rows = [_]Row{
        .{ .status = .complete, .len = 100 },
        .{ .status = .failed, .len = 200 },
        .{ .status = .pending, .len = 300 },
    };

    var buffer: [256]u8 align(Block.alignment) = undefined;
    const written = try Block.encode(&buffer, &rows);

    // Three enum values need nine bits, so the status column takes two bytes
    const status_entry = try bytes.copyValue(FieldEntry, buffer[@sizeOf(ColumnarHeader)..]);
    try std.testing.expectEqual(@as(u32, 2), status_entry.size);

    const view = try Block.view(buffer[0..written]);
    try std.testing.expectEqual(@as(usize, 3), view.len());
    try std.testing.expectEqual(Status.failed, try view.value(.status, 1));
    try std.testing.expectEqual(@as(u32, 300), try view.value(.len, 2));

    // The packed column returns values through get(). The u32 column is a regular slice
    try std.testing.expectEqual(Status.failed, try view.column(.status).get(1));
    try std.testing.expectEqual(@as(u32, 300), view.column(.len)[2]);
}

test "Columns writes consistent padding and rejects nonzero bytes between columns" {
    const Row = struct {
        small: u8,
        wide: u64,
    };
    const Block = Columns(Row, .{});
    const rows = [_]Row{.{ .small = 7, .wide = 0x0123_4567_89ab_cdef }};

    var first: [128]u8 align(Block.alignment) = @splat(0xa5);
    var second: [128]u8 align(Block.alignment) = @splat(0x5a);
    const first_len = try Block.encode(&first, &rows);
    const second_len = try Block.encode(&second, &rows);
    try std.testing.expectEqual(first_len, second_len);
    try std.testing.expectEqualSlices(u8, first[0..first_len], second[0..second_len]);

    const first_entry = try bytes.copyValue(FieldEntry, first[@sizeOf(ColumnarHeader)..]);
    const second_entry = try bytes.copyValue(FieldEntry, first[@sizeOf(ColumnarHeader) + @sizeOf(FieldEntry) ..]);
    const padding_start = first_entry.offset + first_entry.size;
    try std.testing.expect(second_entry.offset > padding_start);
    try std.testing.expect(std.mem.allEqual(u8, first[padding_start..second_entry.offset], 0));
    first[padding_start] = 1;
    try std.testing.expectError(error.InvalidFormat, Block.view(first[0..first_len]));
    try std.testing.expectError(error.InvalidFormat, Block.viewMutable(first[0..first_len]));
    try std.testing.expectError(error.InvalidFormat, Block.viewAssumeValid(first[0..first_len]));
}

test "Columns reads zero-sized rows without validating each empty array" {
    const Row = struct { empty: [0]bool };
    const Block = Columns(Row, .{});
    // Fail promptly if the scan returns: this column declares u32's maximum row count
    try std.testing.expect(!comptime runtime_validation.needsValueValidation([0]bool));
    const buffer: [16]u8 align(Block.alignment) = .{
        255, 255, 255, 255, // row count
        1, 0, 0, 0, // field count
        16, 0, 0, 0, // column offset
        0, 0, 0, 0, // column byte size
    };
    const view = try Block.view(&buffer);
    try std.testing.expectEqual(@as(usize, std.math.maxInt(u32)), view.len());
    try std.testing.expectEqualDeep(Row{ .empty = .{} }, try view.get(view.len() - 1));
}

test "Columns view() rejects an undeclared enum tag in a packed column" {
    const Status = enum(u3) { pending, complete, failed };
    const Row = struct { status: Status };
    const Block = Columns(Row, .{ .packed_fields = &.{.status} });

    const rows = [_]Row{ .{ .status = .pending }, .{ .status = .complete } };
    var buffer: [64]u8 align(Block.alignment) = undefined;
    const written = try Block.encode(&buffer, &rows);

    // Give the second element, in bits 3–5, the undeclared tag 6
    const status_entry = try bytes.copyValue(FieldEntry, buffer[@sizeOf(ColumnarHeader)..]);
    std.mem.writePackedInt(u3, buffer[status_entry.offset..][0..status_entry.size], 3, 6, .little);

    try std.testing.expectError(error.InvalidValue, Block.view(buffer[0..written]));
    try std.testing.expectError(error.InvalidValue, Block.viewMutable(buffer[0..written]));
}

test "Columns views reject a packed column that is too short for the declared row count" {
    const Status = enum(u3) { pending, complete, failed };
    const Row = struct {
        status: Status,
        len: u32,
    };
    const Block = Columns(Row, .{ .packed_fields = &.{.status} });

    var buffer: [@sizeOf(ColumnarHeader) + 2 * @sizeOf(FieldEntry) + @sizeOf(u32)]u8 align(Block.alignment) = undefined;
    @memset(&buffer, 0);

    const directory_end = dataStartOffset(@typeInfo(Row).@"struct".fields.len);
    bytes.writeValue(ColumnarHeader, buffer[0..@sizeOf(ColumnarHeader)], .{
        .row_count = 1,
        .field_count = 2,
    });
    bytes.writeValue(FieldEntry, buffer[@sizeOf(ColumnarHeader)..][0..@sizeOf(FieldEntry)], .{
        .offset = @intCast(directory_end),
        .size = 0,
    });
    bytes.writeValue(FieldEntry, buffer[@sizeOf(ColumnarHeader) + @sizeOf(FieldEntry) ..][0..@sizeOf(FieldEntry)], .{
        .offset = @intCast(directory_end),
        .size = @sizeOf(u32),
    });

    try std.testing.expectError(error.InvalidFormat, Block.view(buffer[0..]));
    try std.testing.expectError(error.InvalidFormat, Block.viewMutable(buffer[0..]));
    try std.testing.expectError(error.InvalidFormat, Block.viewAssumeValid(buffer[0..]));
}

test "Columns view() rejects an undeclared enum tag in an ordinary column" {
    const Status = enum(u8) { pending, complete };
    const Row = struct {
        status: Status,
        len: u32,
    };
    const Block = Columns(Row, .{});

    const rows = [_]Row{
        .{ .status = .pending, .len = 1 },
        .{ .status = .complete, .len = 2 },
    };

    var buffer: [256]u8 align(Block.alignment) = undefined;
    const written = try Block.encode(&buffer, &rows);

    // Give the second value in the status column an undeclared tag
    const status_entry = try bytes.copyValue(FieldEntry, buffer[@sizeOf(ColumnarHeader)..]);
    buffer[status_entry.offset + 1] = 9;

    try std.testing.expectError(error.InvalidValue, Block.view(buffer[0..written]));
    try std.testing.expectError(error.InvalidValue, Block.viewMutable(buffer[0..written]));
}

test "Columns view() rejects overlapping columns" {
    const Row = struct {
        a: u32,
        b: u32,
    };
    const Block = Columns(Row, .{});

    const rows = [_]Row{
        .{ .a = 1, .b = 10 },
        .{ .a = 2, .b = 20 },
    };

    var buffer: [256]u8 align(Block.alignment) = undefined;
    _ = try Block.encode(&buffer, &rows);

    // Make column b point at column a's values. Both ranges still fit in the buffer,
    // but the columns should have separate storage
    const entry_a = try bytes.copyValue(FieldEntry, buffer[@sizeOf(ColumnarHeader)..]);
    const entry_b_offset = @sizeOf(ColumnarHeader) + @sizeOf(FieldEntry);
    var entry_b = try bytes.copyValue(FieldEntry, buffer[entry_b_offset..]);
    entry_b.offset = entry_a.offset;
    bytes.writeValue(FieldEntry, buffer[entry_b_offset..][0..@sizeOf(FieldEntry)], entry_b);

    // End the buffer at the overlapping columns so trailing bytes cannot explain the failure
    const end = entry_b.offset + entry_b.size;
    try std.testing.expectError(error.InvalidFormat, Block.view(buffer[0..end]));
    try std.testing.expectError(error.InvalidFormat, Block.viewMutable(buffer[0..end]));
    try std.testing.expectError(error.InvalidFormat, Block.viewAssumeValid(buffer[0..end]));
}

test "Columns view() rejects trailing bytes past the last column" {
    const Row = struct { key: u64 };
    const Block = Columns(Row, .{});

    const rows = [_]Row{ .{ .key = 1 }, .{ .key = 2 } };
    var buffer: [256]u8 align(Block.alignment) = undefined;
    const written = try Block.encode(&buffer, &rows);

    _ = try Block.view(buffer[0..written]);

    // The extra byte does not belong to any column
    buffer[written] = 0;
    try std.testing.expectError(error.InvalidFormat, Block.view(buffer[0 .. written + 1]));
    try std.testing.expectError(error.InvalidFormat, Block.viewMutable(buffer[0 .. written + 1]));
    try std.testing.expectError(
        error.InvalidFormat,
        Block.viewAssumeValid(buffer[0 .. written + 1]),
    );
}

test "Columns get() and iterator() reconstruct rows from their stored columns" {
    const Status = enum(u3) { pending, complete, failed };
    const Row = struct {
        name: []const u8,
        length: u32,
        status: Status,
    };
    const Block = Columns(Row, .{ .packed_fields = &.{.status} });

    const rows = [_]Row{
        .{ .name = "one", .length = 1, .status = .pending },
        .{ .name = "three", .length = 3, .status = .failed },
    };

    var buffer: [512]u8 align(Block.alignment) = undefined;
    const written = try Block.encode(&buffer, &rows);
    const view = try Block.view(buffer[0..written]);

    const second = try view.get(1);
    try std.testing.expectEqualSlices(u8, "three", second.name);
    try std.testing.expectEqual(@as(u32, 3), second.length);
    try std.testing.expectEqual(Status.failed, second.status);

    var it = view.iterator();
    var count: usize = 0;
    while (it.next()) |row| : (count += 1) {
        try std.testing.expectEqualSlices(u8, rows[count].name, row.name);
        try std.testing.expectEqual(rows[count].length, row.length);
        try std.testing.expectEqual(rows[count].status, row.status);
    }
    try std.testing.expectEqual(rows.len, count);
    try std.testing.expectEqual(null, it.next());
}

test "Columns get() and value() reject an index at or beyond the row count" {
    const Row = struct { id: u16, name: []const u8, code: u2 };
    const Block = Columns(Row, .{ .packed_fields = &.{.code} });
    const rows = [_]Row{.{ .id = 1, .name = "a", .code = 2 }};
    var buffer: [128]u8 align(Block.alignment) = undefined;
    const written = try Block.encode(&buffer, &rows);
    const view = try Block.view(buffer[0..written]);
    for ([_]usize{ view.len(), view.len() + 1, std.math.maxInt(usize) }) |index| {
        try std.testing.expectError(error.IndexOutOfBounds, view.get(index));
        inline for (.{ .id, .name, .code }) |field| {
            try std.testing.expectError(error.IndexOutOfBounds, view.value(field, index));
        }
    }
    const empty_written = try Block.encode(&buffer, &.{});
    const empty_view = try Block.view(buffer[0..empty_written]);
    try std.testing.expectError(error.IndexOutOfBounds, empty_view.get(0));
    inline for (.{ .id, .name, .code }) |field| {
        try std.testing.expectError(error.IndexOutOfBounds, empty_view.value(field, 0));
    }
    var empty_iterator = empty_view.iterator();
    try std.testing.expectEqual(null, empty_iterator.next());
}

test "Columns encode() leaves an undersized or misaligned destination buffer unchanged" {
    const Row = struct { id: u32, name: []const u8 };
    const Block = Columns(Row, .{});
    const rows = [_]Row{.{ .id = 1, .name = "a" }};
    var buffer: [128]u8 align(Block.alignment) = .{99} ** 128;
    const byte_count = try Block.encodedSize(&rows);
    try std.testing.expectError(
        error.NoSpaceLeft,
        Block.encode(buffer[0 .. byte_count - 1], &rows),
    );
    try std.testing.expectError(error.MisalignedBuffer, Block.encode(buffer[1..], &rows));
    try std.testing.expect(std.mem.allEqual(u8, &buffer, 99));
}

test "Columns Sizer rejects row counts and column sizes that exceed storage limits" {
    const Row = struct { values: []const u16 };
    const Block = Columns(Row, .{});
    var current_size: Block.Sizer = .{ .row_count = std.math.maxInt(u32) };
    const before = current_size;
    try std.testing.expectError(error.InputTooLarge, current_size.append(.{ .values = &.{} }));
    try std.testing.expectEqualDeep(before, current_size);

    // The element count fits in u32, but the bytes for those elements do not
    current_size = .{ .row_count = 1, .value_counts = .{std.math.maxInt(u32)} };
    try std.testing.expectError(error.InputTooLarge, current_size.encodedSize());
    current_size.value_counts[0] = std.math.maxInt(usize);
    const before_overflow = current_size;
    try std.testing.expectError(error.InputTooLarge, current_size.append(.{ .values = &.{1} }));
    try std.testing.expectEqualDeep(before_overflow, current_size);
}
