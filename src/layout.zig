//! We define a storage format in stash by giving Layout a struct that describes its fields.
//! Layout uses that schema to determine how to write the data and read it back.
//!
//! For example, this layout holds a struct storing a u32 and a slice:
//! ```zig
//! const Data = Layout(struct {
//!     version: u32,
//!     values: []const u32,
//! });
//! ```
//! Each of these fields becomes a 'block'. In stash, a block defines how one schema field is
//! encoded and accessed. For example, ValueBlock(u32) describes a single integer, while
//! SliceBlock(u32) describes a sequence of integers. Layout chooses the correct block type
//! for each field and combines them into one buffer.
//!
//! Blocks are stored in the order declared in the struct along with any padding needed for alignment.
//! We store each block's byte size as a u64 at the end of the buffer so we can locate its values later.
//! Stored values use the target's type sizes and alignment.
//!
//! Data.encodedSize() tells us how much space we need, and Data.write() writes into a buffer we provide.
//! Data.view() provides "zero copy" access: it performs checks on enums and bools and returns pointers into that buffer.
//! The backing buffer must remain valid and immutable for the lifetime of those views.

const std = @import("std");
const builtin = @import("builtin");

const bytes = @import("bytes.zig");
const blocks = @import("blocks.zig");
const packed_slice = @import("blocks/packed_slice.zig");
const SliceBlock = @import("blocks/slice.zig").SliceBlock;
const ValueBlock = @import("blocks/value.zig").ValueBlock;
const RaggedSliceBlock = @import("blocks/ragged_slice.zig").RaggedSliceBlock;
const Columns = @import("blocks/columnar.zig").Columns;

/// Counts, byte sizes, and aligned positions must fit the layout's representation
pub const BufferSizeError = blocks.BufferSizeError;

pub const WriteError = BufferSizeError || error{
    NoSpaceLeft,
};

pub const ViewError = error{
    BufferTooSmall,
    MisalignedBuffer,
    InvalidFormat,
    InvalidValue,
};

/// Define a storage format from a schema struct
///
/// ```zig
/// const Format = stash.Layout(struct {
///     version: u32,
///     numbers: []const u32,
/// });
/// const buffer = try Format.alloc(allocator, .{ .version = 1, .numbers = &.{ 10, 20 } });
/// defer allocator.free(buffer);
/// const view = try Format.view(buffer);
///
/// // view.version.* is 1
/// // view.numbers is &.{ 10, 20 }
/// ```
pub fn Layout(comptime Schema: type) type {
    comptime @import("comptime_validation.zig").assertStructHasSupportedSchemaFields(Schema, "Layout");
    const layout_info = @typeInfo(Schema);
    const layout_fields = layout_info.@"struct".fields;
    return struct {
        const Self = @This();
        const BlockByteRange = struct { offset: usize, size: usize };
        const BlockByteRanges = [layout_fields.len]BlockByteRange;

        comptime {
            for (layout_fields) |field| {
                const Block = blocks.resolveBlockType(field.type);
                if (field.default_value_ptr != null and Block.Input != field.type and @typeInfo(field.type) != .pointer) {
                    @compileError("stash: explicit storage constructors cannot have schema defaults\n" ++
                        "  field '" ++ field.name ++ "' has a default\n" ++
                        "  fix: supply the value when constructing the layout's Input");
                }
            }
        }

        /// Each schema field accepts the input type chosen by its block
        pub const Input = MappedStruct(layout_fields, true, struct {
            fn map(comptime field: std.builtin.Type.StructField) type {
                return blocks.resolveBlockType(field.type).Input;
            }
        }.map);

        /// Each field borrows its stored values from the buffer.
        /// The buffer must remain valid and immutable while any view, pointer, or slice into it is in use
        pub const View = MappedStruct(layout_fields, false, struct {
            fn map(comptime field: std.builtin.Type.StructField) type {
                return blocks.resolveBlockType(field.type).View;
            }
        }.map);

        /// The required alignment of the buffer's starting address in bytes.
        /// Format.alloc() allocates a buffer with this alignment. If you provide a buffer
        /// to Format.write() or Format.initialize(), declare it with align(Format.alignment)
        /// or allocate it with that alignment.
        /// Buffers passed to the view functions must also meet this requirement,
        /// otherwise they return MisalignedBuffer
        pub const alignment: usize = blk: {
            var result: usize = @alignOf(u64);
            for (layout_fields) |field| {
                result = @max(result, blocks.resolveBlockType(field.type).alignment);
            }
            break :blk result;
        };

        const BlockSizes = [layout_fields.len]usize;

        /// Return the buffer size needed to write the input, including padding and the block size table
        pub fn encodedSize(input: Input) BufferSizeError!usize {
            return totalEncodedSize(try calculateEncodedBlockSizes(input));
        }

        /// Track how much space a layout needs as rows are added to its Columns fields.
        /// This supports value fields and Columns, keeping counts rather than the rows themselves.
        /// Writing measures the supplied input again
        pub const Sizer = struct {
            const Measurements = MappedStruct(layout_fields, false, struct {
                fn map(comptime field: std.builtin.Type.StructField) type {
                    const Block = blocks.resolveBlockType(field.type);
                    if (encodedSizeWithoutInput(Block) != null) return void;
                    if (Block.stash_block_info.kind == .columnar) return Block.Sizer;
                    @compileError("stash: Sizer supports only fixed values and Columns\n" ++
                        "  layout field '" ++ field.name ++ "' does not support incremental sizing\n" ++
                        "  fix: use encodedSize() with the complete input");
                }
            }.map);

            measurements: Measurements = blk: {
                var result: Measurements = undefined;
                for (layout_fields) |field| {
                    const Block = blocks.resolveBlockType(field.type);
                    @field(result, field.name) = if (encodedSizeWithoutInput(Block) != null) {} else .{};
                }
                break :blk result;
            },

            /// The total includes fixed fields, all columnar blocks, alignment, and the block size table.
            /// Empty columnar blocks still occupy space for their metadata
            pub fn encodedSize(self: @This()) BufferSizeError!usize {
                var sizes: BlockSizes = undefined;
                inline for (layout_fields, 0..) |field, index| {
                    const Block = blocks.resolveBlockType(field.type);
                    sizes[index] = if (comptime encodedSizeWithoutInput(Block)) |size|
                        size
                    else
                        try @field(self.measurements, field.name).encodedSize();
                }
                return totalEncodedSize(sizes);
            }

            /// Measure one more row in the selected columnar field.
            /// max_size limits the complete encoded buffer, including alignment and metadata.
            /// Return false if the candidate exceeds that budget. Exceeding a format limit or overflowing returns InputTooLarge.
            /// Both false and errors leave the measurement unchanged. No rows are stored or rescanned
            pub fn tryAppend(
                self: *@This(),
                comptime field: std.meta.FieldEnum(Schema),
                row: RowFor(field),
                limit: struct { max_size: usize },
            ) BufferSizeError!bool {
                var candidate = self.*;
                try @field(candidate.measurements, @tagName(field)).append(row);
                if (try candidate.encodedSize() > limit.max_size) return false;
                self.* = candidate;
                return true;
            }

            fn RowFor(comptime field: std.meta.FieldEnum(Schema)) type {
                const Block = blocks.resolveBlockType(@FieldType(Schema, @tagName(field)));
                if (Block.stash_block_info.kind != .columnar) {
                    @compileError("stash: tryAppend requires a columnar field\n" ++
                        "  field '" ++ @tagName(field) ++ "' is not columnar\n" ++
                        "  fix: select a field declared with Columns");
                }
                return Block.stash_block_info.Element;
            }
        };

        // We need each block's size to calculate the required buffer capacity and place the blocks.
        // Use this when writing existing values and slices from Input.
        // Return the sizes in schema field order so writing can reuse them
        fn calculateEncodedBlockSizes(input: Input) BufferSizeError!BlockSizes {
            var sizes: BlockSizes = undefined;
            inline for (layout_fields, 0..) |field, index| {
                const Block = blocks.resolveBlockType(field.type);
                sizes[index] = try Block.encodedSize(@field(input, field.name));
            }
            return sizes;
        }

        // Initialization also needs block sizes, but the slices will be created in the output buffer.
        // Use this when initializing from Init rather than copying existing slices from Input.
        // Calculate each block's byte size from the supplied values and requested slice counts
        fn calculateInitializedBlockSizes(initial_values: Init) BufferSizeError!BlockSizes {
            var sizes: BlockSizes = undefined;
            inline for (layout_fields, 0..) |field, index| {
                const Block = initializableBlock(field);
                sizes[index] = try Block.initializedSize(@field(initial_values, field.name));
            }
            return sizes;
        }

        /// Callers supply a byte size for every variable-size field, using its schema name.
        /// Fixed-size fields are omitted because their blocks already determine their sizes.
        pub const VariableBlockSizes = blk: {
            var fields: [layout_fields.len]std.builtin.Type.StructField = undefined;
            var count: usize = 0;
            for (layout_fields) |field| {
                const Block = blocks.resolveBlockType(field.type);
                if (encodedSizeWithoutInput(Block) == null) {
                    fields[count] = field;
                    count += 1;
                }
            }
            break :blk MappedStruct(fields[0..count], false, struct {
                fn map(comptime _: std.builtin.Type.StructField) type {
                    return usize;
                }
            }.map);
        };

        /// Calculate the required buffer size from known variable-size block sizes, including all layout overhead
        pub fn encodedSizeFromBlockSizes(sizes: VariableBlockSizes) BufferSizeError!usize {
            var all_sizes: BlockSizes = undefined;
            inline for (layout_fields, 0..) |field, index| {
                const Block = blocks.resolveBlockType(field.type);
                all_sizes[index] = if (comptime encodedSizeWithoutInput(Block)) |size|
                    size
                else
                    @field(sizes, field.name);
            }
            return totalEncodedSize(all_sizes);
        }

        // Include alignment padding and the size table in the total size
        fn totalEncodedSize(sizes: BlockSizes) BufferSizeError!usize {
            var byte_count: usize = 0;
            inline for (layout_fields, sizes) |field, size| {
                const Block = blocks.resolveBlockType(field.type);
                const offset = blocks.alignForward(byte_count, Block.alignment) catch return error.InputTooLarge;
                if (size > std.math.maxInt(u64)) return error.InputTooLarge;
                byte_count = std.math.add(usize, offset, size) catch return error.InputTooLarge;
            }

            const size_table_offset = blocks.alignForward(byte_count, @alignOf(u64)) catch return error.InputTooLarge;
            return std.math.add(usize, size_table_offset, sizeTableByteCount()) catch error.InputTooLarge;
        }

        /// When you want to encode existing values and slices, use write(). It will copy their
        /// contents into the buffer according to this layout's format and return the encoded bytes.
        /// If you want to allocate space for your slice elements in the buffer first and then fill
        /// them in through mutable views, use initialize().
        pub fn write(buffer: []align(alignment) u8, input: Input) WriteError![]align(alignment) u8 {
            return writeInput(buffer, input, try calculateEncodedBlockSizes(input));
        }

        /// Use Init to specify the starting contents of the buffer when calling initialize().
        /// For a value field, supply its value. For a slice field, supply .{ .count = n, .value = x }
        /// to create n elements filled with x, which you can then modify through the returned view
        pub const Init = MappedStruct(layout_fields, false, struct {
            fn map(comptime field: std.builtin.Type.StructField) type {
                const Block = initializableBlock(field);
                return Block.Init;
            }
        }.map);

        /// The return type of initialize(): bytes contains the written portion of your buffer,
        /// and view provides mutable access to the values stored in those bytes
        pub const Initialized = struct {
            bytes: []align(alignment) u8,
            view: MutableView,
        };

        pub fn initializedSize(initial_values: Init) BufferSizeError!usize {
            return totalEncodedSize(try calculateInitializedBlockSizes(initial_values));
        }

        /// When you want to build data directly in its final buffer, use initialize(). This writes your
        /// starting values into the buffer and return mutable views so you can fill in the data in place.
        /// For each slice, provide its length and a value to fill it with. For example,
        /// .{ .count = 3, .value = 0 } creates { 0, 0, 0 }.
        ///
        /// This only supports value fields and slices currently, returning the encoded bytes along with mutable
        /// views into them. initializedSize(initial_values) will help you compute the required buffer size
        pub fn initialize(buffer: []align(alignment) u8, initial_values: Init) WriteError!Initialized {
            const sizes = try calculateInitializedBlockSizes(initial_values);
            const total_size = try totalEncodedSize(sizes);
            if (total_size > buffer.len) return error.NoSpaceLeft;
            const payload = buffer[0..total_size];
            const ranges = writeBlockMetadata(payload, sizes);

            var views: MutableView = undefined;
            inline for (layout_fields, ranges) |field, range| {
                const Block = initializableBlock(field);
                // Sizing and placement established each block's capacity and alignment
                @field(views, field.name) = Block.initialize(
                    payload[range.offset..][0..range.size],
                    @field(initial_values, field.name),
                ) catch unreachable;
            }
            return .{ .bytes = payload, .view = views };
        }

        // Both write() and alloc() reuse the block sizes measured from their input
        fn writeInput(buffer: []align(alignment) u8, input: Input, sizes: BlockSizes) WriteError![]align(alignment) u8 {
            const total_size = try totalEncodedSize(sizes);
            if (total_size > buffer.len) return error.NoSpaceLeft;
            const payload = buffer[0..total_size];
            const ranges = writeBlockMetadata(payload, sizes);

            inline for (layout_fields, ranges) |field, range| {
                const Block = blocks.resolveBlockType(field.type);
                // Sizing and placement established each block's capacity and alignment
                const written = Block.encode(
                    payload[range.offset..][0..range.size],
                    @field(input, field.name),
                ) catch unreachable;
                std.debug.assert(written == range.size);
            }
            return payload;
        }

        // Place the blocks at their appropriate offsets and write the trailing metadata table.
        fn writeBlockMetadata(buffer: []align(alignment) u8, sizes: BlockSizes) BlockByteRanges {
            const size_table_offset = buffer.len - sizeTableByteCount();
            var ranges: BlockByteRanges = undefined;
            var cursor: usize = 0;
            inline for (layout_fields, sizes, 0..) |field, size, field_index| {
                const Block = blocks.resolveBlockType(field.type);
                const offset = std.mem.alignForward(usize, cursor, Block.alignment);
                @memset(buffer[cursor..offset], 0);
                ranges[field_index] = .{ .offset = offset, .size = size };

                const size_entry_offset = size_table_offset + field_index * @sizeOf(u64);
                bytes.writeValue(u64, buffer[size_entry_offset..][0..@sizeOf(u64)], @intCast(size));
                cursor = offset + size;
            }
            @memset(buffer[cursor..size_table_offset], 0);
            return ranges;
        }

        /// Allocate an aligned buffer and write the input into it. The caller must free the returned buffer.
        /// The input and any data it references must remain valid and unchanged until writing finishes
        pub fn alloc(
            allocator: std.mem.Allocator,
            input: Input,
        ) (BufferSizeError || std.mem.Allocator.Error)![]align(alignment) u8 {
            const sizes = try calculateEncodedBlockSizes(input);
            const size = try totalEncodedSize(sizes);
            const buffer = try allocator.alignedAlloc(u8, .fromByteUnits(alignment), size);
            // Reuse the same sizes that established the allocation's size and format limits
            const payload = writeInput(buffer, input, sizes) catch unreachable;
            std.debug.assert(payload.len == size);
            return buffer;
        }

        /// Validate the buffer's structure and stored values, then return read-only views of its fields.
        /// The buffer must remain valid and immutable while any returned view or derived pointer or slice is in use
        pub fn view(payload: []const u8) ViewError!View {
            return viewImpl(payload, true);
        }

        /// Return read-only views without checking stored values or ragged slice offsets.
        /// The bytes must have been written or validated with this layout and remain unchanged since then.
        /// A checksum alone does not establish that the bytes are valid.
        pub fn viewAssumeValid(payload: []const u8) ViewError!View {
            return viewImpl(payload, false);
        }

        /// In-place mutable access to every field in the layout
        pub const MutableView = MappedStruct(layout_fields, false, struct {
            fn map(comptime field: std.builtin.Type.StructField) type {
                const Block = blocks.resolveBlockType(field.type);
                return Block.MutableView;
            }
        }.map);

        /// Validate the buffer's structure and stored values, then return mutable views of its fields.
        /// The buffer must remain valid and be accessed only through the views and their derived pointers
        /// or slices for their lifetime. Blocks cannot be resized or moved.
        pub fn viewMutable(payload: []u8) ViewError!MutableView {
            if (@intFromPtr(payload.ptr) % alignment != 0) return error.MisalignedBuffer;
            const ranges = try Self.readBlockByteRanges(payload);
            var result: MutableView = undefined;
            inline for (layout_fields, 0..) |field, field_index| {
                const Block = blocks.resolveBlockType(field.type);
                const range = ranges[field_index];
                @field(result, field.name) = Block.viewMutable(payload[range.offset..][0..range.size]) catch |err| switch (err) {
                    error.InvalidValue => return error.InvalidValue,
                    error.BufferTooSmall, error.InvalidFormat => return error.InvalidFormat,
                    // The base address and block offset have already been checked for alignment
                    error.MisalignedBuffer => unreachable,
                };
            }
            return result;
        }

        // Resolve the field's block type and check that it supports initialization
        fn initializableBlock(comptime field: std.builtin.Type.StructField) type {
            const Block = blocks.resolveBlockType(field.type);
            if (!@hasDecl(Block, "Init") or !@hasDecl(Block, "initialize") or !@hasDecl(Block, "initializedSize")) {
                @compileError("stash: initialization supports only fixed values and ordinary slices\n" ++
                    "  layout field '" ++ field.name ++ "' does not support initialization");
            }
            return Block;
        }

        // Locate the block size table at the end of the buffer
        fn findBlockSizeTableOffset(payload: []const u8) ViewError!usize {
            if (payload.len < sizeTableByteCount()) return error.BufferTooSmall;
            const offset = payload.len - sizeTableByteCount();
            if (offset % @alignOf(u64) != 0) return error.InvalidFormat;
            return offset;
        }

        fn viewImpl(payload: []const u8, comptime validate_values: bool) ViewError!View {
            if (@intFromPtr(payload.ptr) % alignment != 0) return error.MisalignedBuffer;
            const ranges = try readBlockByteRanges(payload);
            var result: View = undefined;

            inline for (layout_fields, 0..) |field, field_index| {
                const Block = blocks.resolveBlockType(field.type);
                const range = ranges[field_index];
                const buffer = payload[range.offset..][0..range.size];
                const block_view = if (comptime validate_values) Block.view(buffer) else Block.viewAssumeValid(buffer);
                @field(result, field.name) = block_view catch |err| switch (err) {
                    error.InvalidValue => return error.InvalidValue,
                    error.BufferTooSmall, error.InvalidFormat => return error.InvalidFormat,
                    // The base address and block offset have already been checked for alignment
                    error.MisalignedBuffer => unreachable,
                };
            }
            return result;
        }

        // Read the block size table to determine where each block starts and how many bytes it occupies.
        // Check that the blocks fit before the table and that any alignment padding is zero
        fn readBlockByteRanges(payload: []const u8) ViewError!BlockByteRanges {
            const size_table_offset = try Self.findBlockSizeTableOffset(payload);
            var result: BlockByteRanges = undefined;
            var cursor: usize = 0;

            inline for (layout_fields, 0..) |field, field_index| {
                const Block = blocks.resolveBlockType(field.type);
                const offset = blocks.alignForward(cursor, Block.alignment) catch return error.InvalidFormat;
                if (offset > size_table_offset) return error.InvalidFormat;
                if (!std.mem.allEqual(u8, payload[cursor..offset], 0)) return error.InvalidFormat;

                const size_entry_offset = size_table_offset + field_index * @sizeOf(u64);
                const encoded_size = bytes.copyValue(u64, payload[size_entry_offset..]) catch
                    return error.InvalidFormat;
                if (encoded_size > std.math.maxInt(usize)) return error.InvalidFormat;
                const size: usize = @intCast(encoded_size);
                const end = std.math.add(usize, offset, size) catch return error.InvalidFormat;
                if (end > size_table_offset) return error.InvalidFormat;

                result[field_index] = .{ .offset = offset, .size = size };
                cursor = end;
            }

            const expected_size_table_offset = blocks.alignForward(cursor, @alignOf(u64)) catch return error.InvalidFormat;
            if (expected_size_table_offset != size_table_offset) return error.InvalidFormat;
            if (!std.mem.allEqual(u8, payload[cursor..size_table_offset], 0)) return error.InvalidFormat;
            return result;
        }

        fn sizeTableByteCount() usize {
            return layout_fields.len * @sizeOf(u64);
        }
    };
}

// Sizer and encodedSizeFromBlockSizes() must include value fields without receiving their values.
// Value blocks always occupy @sizeOf(T) bytes
fn encodedSizeWithoutInput(comptime Block: type) ?usize {
    const block_info = Block.stash_block_info;
    return switch (block_info.kind) {
        .value => @sizeOf(block_info.Element),
        else => null,
    };
}

// Preserve schema field names while replacing their types
fn MappedStruct(
    comptime fields: []const std.builtin.Type.StructField,
    comptime preserve_defaults: bool,
    comptime mapField: fn (comptime std.builtin.Type.StructField) type,
) type {
    var field_names: [fields.len][]const u8 = undefined;
    var field_types: [fields.len]type = undefined;
    var field_attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (fields, 0..) |field, i| {
        const FieldType = mapField(field);
        field_names[i] = field.name;
        field_types[i] = FieldType;
        field_attrs[i] = .{ .@"align" = @alignOf(FieldType) };
        if (preserve_defaults and field.default_value_ptr != null) {
            const value: FieldType = field.defaultValue().?;
            field_attrs[i].default_value_ptr = @ptrCast(&value);
        }
    }
    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

test "Layout viewMutable() updates stored fields in place" {
    const Header = extern struct { generation: u32 };
    const MutableLayout = Layout(struct {
        header: Header,
        label: [3]u8,
        values: []const u64,
    });
    const values = [_]u64{ 3, 5, 8 };

    var buffer: [256]u8 align(MutableLayout.alignment) = undefined;
    const payload = try MutableLayout.write(&buffer, .{
        .header = .{ .generation = 1 },
        .label = .{ 'a', 0, 'z' },
        .values = &values,
    });

    const mutable = try MutableLayout.viewMutable(buffer[0..payload.len]);
    mutable.header.generation = 2;
    mutable.label[2] = 'b';
    mutable.values[1] = 13;

    const viewed = try MutableLayout.view(payload);
    try std.testing.expectEqual(@as(u32, 2), viewed.header.generation);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 0, 'b' }, viewed.label);
    try std.testing.expectEqualSlices(u64, &.{ 3, 13, 8 }, viewed.values);
}

test "Layout view() and viewMutable() reject invalid enum tags in values and slices" {
    const Status = enum(u8) { active, stale };
    const Format = Layout(struct { status: Status, statuses: []const Status });
    var buffer: [32]u8 align(Format.alignment) = undefined;
    const payload = try Format.write(&buffer, .{ .status = .active, .statuses = &.{ .active, .stale } });
    for (0..3) |offset| {
        const original = buffer[offset];
        buffer[offset] = 2;
        try std.testing.expectError(error.InvalidValue, Format.view(payload));
        try std.testing.expectError(error.InvalidValue, Format.viewMutable(buffer[0..payload.len]));
        buffer[offset] = original;
    }
}

test "Layout rejects nonzero padding between blocks" {
    const TestLayout = Layout(struct {
        byte: u8,
        value: u64,
    });

    var buffer: [64]u8 align(TestLayout.alignment) = undefined;
    const payload = try TestLayout.write(&buffer, .{ .byte = 1, .value = 2 });
    buffer[1] = 1;
    try std.testing.expectError(error.InvalidFormat, TestLayout.view(payload));
    try std.testing.expectError(error.InvalidFormat, TestLayout.viewAssumeValid(payload));
    try std.testing.expectError(error.InvalidFormat, TestLayout.viewMutable(payload));
}

test "Layout rejects truncated values and size tables" {
    const Format = Layout(struct { first: u32, second: u32 });
    var buffer: [24]u8 align(Format.alignment) = undefined;
    const payload = try Format.write(&buffer, .{ .first = 1, .second = 2 });

    // Fewer than sixteen bytes cannot hold the size table for two fields
    for (0..16) |size| {
        try std.testing.expectError(error.BufferTooSmall, Format.view(payload[0..size]));
        try std.testing.expectError(error.BufferTooSmall, Format.viewAssumeValid(payload[0..size]));
    }
    for (16..payload.len) |size| {
        try std.testing.expectError(error.InvalidFormat, Format.view(payload[0..size]));
        try std.testing.expectError(error.InvalidFormat, Format.viewAssumeValid(payload[0..size]));
    }
}

test "Layout rejects block sizes that do not match the stored fields" {
    const Format = Layout(struct { first: u32, second: u32 });
    const invalid_sizes = [_][2]u64{
        .{ 4, 0 }, // The second u32 needs four bytes even when its value is zero
        .{ 8, 0 }, // Fits in the buffer, but a u32 cannot occupy eight bytes
        .{ 4, 8 }, // Extends the second block into the size table
        .{ std.math.maxInt(u64), 4 }, // Extends the first block beyond the buffer
        .{ 4, std.math.maxInt(u64) }, // Adding the second block size overflows on a 64-bit target
    };
    for (invalid_sizes) |sizes| {
        var buffer: [24]u8 align(Format.alignment) = undefined;
        _ = try Format.write(&buffer, .{ .first = 1, .second = 0 });
        bytes.writeValue(u64, buffer[8..16], sizes[0]);
        bytes.writeValue(u64, buffer[16..24], sizes[1]);
        try std.testing.expectError(error.InvalidFormat, Format.view(&buffer));
        try std.testing.expectError(error.InvalidFormat, Format.viewAssumeValid(&buffer));
        try std.testing.expectError(error.InvalidFormat, Format.viewMutable(&buffer));
    }
}

test "Layout rejects unnecessary space before the size table" {
    const Format = Layout(struct { value: u32 });
    // The value and its alignment padding need eight bytes, but the table starts at byte 16
    var buffer: [24]u8 align(Format.alignment) = @splat(0);
    bytes.writeValue(u32, buffer[0..4], 1);
    bytes.writeValue(u64, buffer[16..24], 4);
    try std.testing.expectError(error.InvalidFormat, Format.view(&buffer));
    try std.testing.expectError(error.InvalidFormat, Format.viewAssumeValid(&buffer));
}

test "Layout rejects nonzero padding before the size table" {
    const Format = Layout(struct { value: u8 });
    var buffer: [16]u8 align(Format.alignment) = undefined;
    _ = try Format.write(&buffer, .{ .value = 1 });
    buffer[1] = 99;
    try std.testing.expectError(error.InvalidFormat, Format.view(&buffer));
    try std.testing.expectError(error.InvalidFormat, Format.viewAssumeValid(&buffer));
    try std.testing.expectError(error.InvalidFormat, Format.viewMutable(&buffer));
}

test "Layout write() and initialize() reject buffers that are too small without changing them" {
    const Format = Layout(struct { generation: u64, values: []const u32 });
    const input: Format.Input = .{ .generation = 1, .values = &.{ 7, 7, 7 } };
    const initial: Format.Init = .{ .generation = 1, .values = .{ .count = 3, .value = 7 } };
    const required = try Format.encodedSize(input);
    var buffer: [64]u8 align(Format.alignment) = @splat(0xa5);
    for (0..required) |length| {
        try std.testing.expectError(error.NoSpaceLeft, Format.write(buffer[0..length], input));
        try std.testing.expect(std.mem.allEqual(u8, &buffer, 0xa5));
        try std.testing.expectError(
            error.NoSpaceLeft,
            Format.initialize(buffer[0..length], initial),
        );
        try std.testing.expect(std.mem.allEqual(u8, &buffer, 0xa5));
    }
}

test "Layout sizing rejects overflow when adding blocks, alignment padding, or the size table" {
    comptime {
        const Format = Layout(struct {
            first: []const u8,
            second: []const u64,
        });
        const max = std.math.maxInt(usize);

        // These sizes overflow when aligning the second block, adding its bytes,
        // or adding the size table. We can check each case without allocating the data
        try std.testing.expectError(
            error.InputTooLarge,
            Format.encodedSizeFromBlockSizes(.{ .first = max, .second = 0 }),
        );
        try std.testing.expectError(
            error.InputTooLarge,
            Format.encodedSizeFromBlockSizes(.{ .first = max - 7, .second = 8 }),
        );
        try std.testing.expectError(
            error.InputTooLarge,
            Format.encodedSizeFromBlockSizes(.{ .first = 0, .second = max - 7 }),
        );
    }
}

test "Layout alloc() returns an aligned buffer of exactly the required size" {
    const Row = struct { id: u32, name: []const u8 };
    const TestLayout = Layout(struct {
        values: []const u64,
        names: []const []const u8,
        rows: Columns(Row, .{}),
    });
    const values = [_]u64{ 1, 2, 3, 5, 8 };
    const contents: TestLayout.Input = .{
        .values = &values,
        .names = &.{ "alpha", "", "beta" },
        .rows = &.{ .{ .id = 1, .name = "first" }, .{ .id = 2, .name = "" } },
    };

    const expected_size = try TestLayout.encodedSize(contents);
    const payload = try TestLayout.alloc(std.testing.allocator, contents);
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqual(expected_size, payload.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(payload.ptr) % TestLayout.alignment);
    try std.testing.expectEqualSlices(u64, &values, (try TestLayout.view(payload)).values);
    try std.testing.expectEqualSlices(
        u64,
        &values,
        (try TestLayout.viewAssumeValid(payload)).values,
    );
    var storage: [256]u8 align(TestLayout.alignment) = undefined;
    try std.testing.expectEqualSlices(u8, try TestLayout.write(&storage, contents), payload);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, TestLayout.alloc(failing.allocator(), contents));
}

test "Layout reads a buffer ending at a protected page boundary" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const Guarded = Layout(struct {
        first: u64,
        second: u64,
    });
    var source: [64]u8 align(Guarded.alignment) = undefined;
    const payload = try Guarded.write(&source, .{ .first = 1, .second = 2 });

    const page_size = std.heap.pageSize();
    try std.testing.expect(payload.len < page_size);
    const payload_offset = page_size - payload.len;
    try std.testing.expectEqual(@as(usize, 0), payload_offset % Guarded.alignment);

    const mapping = try std.posix.mmap(
        null,
        2 * page_size,
        .{},
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(mapping);
    try std.process.protectMemory(mapping[0..page_size], .{ .read = true, .write = true });
    try std.process.protectMemory(@alignCast(mapping[page_size..]), .{});

    const placed = mapping[payload_offset..page_size];
    @memcpy(placed, payload);
    const view_value = try Guarded.view(placed);
    try std.testing.expectEqual(@as(u64, 1), view_value.first.*);
    try std.testing.expectEqual(@as(u64, 2), view_value.second.*);
    _ = try Guarded.viewAssumeValid(placed);
    try std.testing.expectError(error.InvalidFormat, Guarded.view(placed[0 .. placed.len - 1]));
    try std.testing.expectError(
        error.InvalidFormat,
        Guarded.viewAssumeValid(placed[0 .. placed.len - 1]),
    );
}

test "Layout view(), viewAssumeValid(), and viewMutable() reject a misaligned buffer" {
    const OffsetLayout = Layout(struct {
        generation: u32,
        values: []const u64,
    });
    const values = [_]u64{ 3, 5, 8 };
    var source: [512]u8 align(OffsetLayout.alignment) = undefined;
    const payload = try OffsetLayout.write(&source, .{
        .generation = 9,
        .values = &values,
    });

    var storage: [512]u8 align(OffsetLayout.alignment) = undefined;
    for (0..OffsetLayout.alignment) |offset| {
        const candidate = storage[offset..][0..payload.len];
        @memcpy(candidate, payload);
        if (offset == 0) {
            const view_value = try OffsetLayout.view(candidate);
            try std.testing.expectEqualSlices(u64, &values, view_value.values);
            _ = try OffsetLayout.viewAssumeValid(candidate);
            _ = try OffsetLayout.viewMutable(candidate);
        } else {
            try std.testing.expectError(error.MisalignedBuffer, OffsetLayout.view(candidate));
            try std.testing.expectError(
                error.MisalignedBuffer,
                OffsetLayout.viewAssumeValid(candidate),
            );
            try std.testing.expectError(
                error.MisalignedBuffer,
                OffsetLayout.viewMutable(candidate),
            );
        }
    }
}

test "Layout write() and initialize() produce identical bytes for the same values" {
    const Status = enum(u8) { pending, complete };
    const Format = Layout(struct {
        enabled: bool,
        counts: []const u32,
        statuses: []const Status,
    });
    const counts = [_]u32{ 10, 10 };
    const input: Format.Input = .{
        .enabled = true,
        .counts = &counts,
        .statuses = &.{ .pending, .pending, .pending },
    };
    var plain_buffer: [64]u8 align(Format.alignment) = @splat(99);
    var mutable_buffer: [64]u8 align(Format.alignment) = @splat(99);
    const plain = try Format.write(&plain_buffer, input);
    const initial: Format.Init = .{
        .enabled = true,
        .counts = .{ .count = counts.len, .value = 10 },
        .statuses = .{ .count = 3, .value = .pending },
    };
    const size = try Format.initializedSize(initial);
    try std.testing.expectEqual(plain.len, size);
    const result = try Format.initialize(mutable_buffer[0..size], initial);
    try std.testing.expectEqualSlices(u8, plain, result.bytes);
    try std.testing.expect(std.mem.allEqual(u8, plain_buffer[plain.len..], 99));
    try std.testing.expect(std.mem.allEqual(u8, mutable_buffer[result.bytes.len..], 99));

    try std.testing.expectEqualSlices(u32, &counts, result.view.counts);
    try std.testing.expectEqualSlices(
        Status,
        &.{ .pending, .pending, .pending },
        result.view.statuses,
    );
    result.view.enabled.* = false;
    result.view.counts[0] = 30;
    result.view.statuses[1] = .complete;
    const checked = try Format.view(result.bytes);
    try std.testing.expect(!checked.enabled.*);
    try std.testing.expectEqualSlices(u32, &.{ 30, 10 }, checked.counts);
    try std.testing.expectEqual(Status.complete, checked.statuses[1]);
}

test "Layout write() and initialize() support empty schemas and zero-sized values" {
    const Empty = Layout(struct {});
    var buffer: [32]u8 align(8) = @splat(99);
    try std.testing.expectEqual(0, try Empty.encodedSize(.{}));
    const written = try Empty.write(&buffer, .{});
    try std.testing.expectEqual(0, written.len);
    _ = try Empty.view(written);
    try std.testing.expectEqual(0, try Empty.initializedSize(.{}));
    try std.testing.expectEqual(0, (try Empty.initialize(&buffer, .{})).bytes.len);
    try std.testing.expect(std.mem.allEqual(u8, &buffer, 99));

    const Format = Layout(struct { marker: extern struct {}, values: []const u64 });
    const result = try Format.initialize(&buffer, .{
        .marker = .{},
        .values = .{ .count = 0, .value = 0 },
    });
    try std.testing.expectEqual(0, result.view.values.len);
    _ = try Format.view(result.bytes);
}

test "Layout sizing accepts a 4 GiB block when it fits the target address space" {
    comptime {
        const Format = Layout(struct { values: []const u64 });
        if (@bitSizeOf(usize) > 32) {
            const block_size = @as(usize, std.math.maxInt(u32)) + 1;
            try std.testing.expectEqual(
                block_size + 8,
                try Format.encodedSizeFromBlockSizes(.{ .values = block_size }),
            );
            try std.testing.expectEqual(block_size + 8, try Format.initializedSize(.{
                .values = .{ .count = block_size / @sizeOf(u64), .value = 0 },
            }));
        } else {
            try std.testing.expectError(
                error.InputTooLarge,
                Format.encodedSizeFromBlockSizes(.{ .values = std.math.maxInt(usize) }),
            );
        }
    }
}

test "Layout write() stores blocks, zero padding, and the u64 size table in the expected order" {
    const Format = Layout(struct { tag: u8, values: []const u16 });
    const values = [_]u16{ 0x0102, 0x0304 };
    const expected = [_]u8{
        0xab, 0, 0x02, 0x01, 0x04, 0x03, 0, 0,
        1,    0, 0,    0,    0,    0,    0, 0,
        4,    0, 0,    0,    0,    0,    0, 0,
    };
    var storage: [expected.len]u8 align(Format.alignment) = undefined;
    const payload = try Format.write(&storage, .{ .tag = 0xab, .values = &values });
    try std.testing.expectEqualSlices(u8, &expected, payload);
    const view = try Format.view(payload);
    try std.testing.expectEqual(@as(u8, 0xab), view.tag.*);
    try std.testing.expectEqualSlices(u16, &values, view.values);
}

test "Layout initialize() leaves the buffer unchanged when a slice size overflows usize" {
    const Format = Layout(struct { header: u64, values: []const u32 });
    var buffer: [32]u8 align(Format.alignment) = @splat(99);
    const count = std.math.maxInt(usize) / @sizeOf(u32) + 1;
    const initial_values: Format.Init = .{
        .header = 7,
        .values = .{ .count = count, .value = 0 },
    };
    comptime try std.testing.expectError(error.InputTooLarge, Format.initializedSize(initial_values));
    try std.testing.expectError(error.InputTooLarge, Format.initialize(&buffer, initial_values));
    try std.testing.expect(std.mem.allEqual(u8, &buffer, 99));
}

test "Layout encodedSizeFromBlockSizes() needs sizes only for fields whose size depends on the input" {
    const RowColumns = Columns(struct { id: u32, name: []const u8 }, .{});
    const Format = Layout(struct {
        header: ValueBlock(u64),
        empty: extern struct {},
        values: []const u16,
        names: []const []const u8,
        flags: packed_slice.PackedSlice(u3),
        rows: RowColumns,
    });
    const input: Format.Input = .{
        .header = 7,
        .empty = .{},
        .values = &.{ 1, 2 },
        .names = &.{ "cat", "", "hello" },
        .flags = &.{ 1, 2, 3 },
        .rows = &.{.{ .id = 1, .name = "one" }},
    };
    const size_fields = @typeInfo(Format.VariableBlockSizes).@"struct".fields;
    try std.testing.expectEqual(4, size_fields.len);
    inline for (size_fields, .{ "values", "names", "flags", "rows" }) |field, name| {
        try std.testing.expectEqualStrings(name, field.name);
        try std.testing.expect(field.type == usize);
        try std.testing.expect(field.default_value_ptr == null);
    }

    // Only variable-size fields belong in the supplied sizes, regardless of their declaration order
    const measured = try Format.encodedSizeFromBlockSizes(.{
        .rows = try RowColumns.encodedSize(input.rows),
        .flags = try packed_slice.PackedSlice(u3).encodedSize(input.flags),
        .names = try RaggedSliceBlock(u8).encodedSize(input.names),
        .values = input.values.len * @sizeOf(u16),
    });
    var buffer: [256]u8 align(Format.alignment) = undefined;
    try std.testing.expectEqual(try Format.encodedSize(input), measured);
    try std.testing.expectEqual((try Format.write(&buffer, input)).len, measured);
}

test "Layout sizing needs no input for empty schemas or schemas containing only fixed-size values" {
    const Fixed = Layout(struct { marker: u8, value: u64, empty: extern struct {} });
    const input: Fixed.Input = .{ .marker = 1, .value = 2, .empty = .{} };
    const expected = try Fixed.encodedSize(input);
    const sizer: Fixed.Sizer = .{};
    try std.testing.expectEqual(expected, try Fixed.encodedSizeFromBlockSizes(.{}));
    try std.testing.expectEqual(expected, try sizer.encodedSize());
    const initial: Fixed.Init = .{ .marker = 1, .value = 2, .empty = .{} };
    try std.testing.expectEqual(expected, try Fixed.initializedSize(initial));
    var buffer: [64]u8 align(Fixed.alignment) = undefined;
    const result = try Fixed.initialize(buffer[0..expected], initial);
    try std.testing.expectEqual(expected, result.bytes.len);
    try std.testing.expectEqual(2, result.view.value.*);

    const Empty = Layout(struct {});
    const empty: Empty.Sizer = .{};
    try std.testing.expectEqual(0, try Empty.encodedSizeFromBlockSizes(.{}));
    try std.testing.expectEqual(0, try empty.encodedSize());
}

test "Layout Sizer accepts rows that exactly fit the byte budget and stays unchanged when they do not" {
    const Row = struct { id: u64, name: []const u8, samples: []const u16, code: u3 };
    const RowColumns = Columns(Row, .{ .packed_fields = &.{.code} });
    const Format = Layout(struct { header: u32, rows: RowColumns });
    var current_size: Format.Sizer = .{};
    // Two complete packed-bit alignment cycles, plus the next row
    var rows: [17]Row = undefined;
    var buffer: [4096]u8 align(Format.alignment) = undefined;
    const samples = [_]u16{ 10, 20, 30 };
    const name = "variable";

    try std.testing.expectEqual(
        try Format.encodedSize(.{ .header = 0, .rows = &.{} }),
        try current_size.encodedSize(),
    );
    for (&rows, 0..) |*row, index| {
        row.* = .{ .id = index, .name = name[0 .. index % name.len], .samples = samples[0 .. index % 4], .code = @intCast(index % 8) };
        const input: Format.Input = .{ .header = 7, .rows = rows[0 .. index + 1] };
        const required_size = try Format.encodedSize(input);
        const before = current_size;
        try std.testing.expect(
            !try current_size.tryAppend(.rows, row.*, .{ .max_size = required_size - 1 }),
        );
        try std.testing.expectEqualDeep(before, current_size);
        try std.testing.expect(
            try current_size.tryAppend(.rows, row.*, .{ .max_size = required_size }),
        );
        try std.testing.expectEqual(
            (try Format.write(&buffer, input)).len,
            try current_size.encodedSize(),
        );
    }

    // Resetting starts a new measurement, including the empty columnar block's metadata
    current_size = .{};
    const before = current_size;
    try std.testing.expect(!try current_size.tryAppend(.rows, rows[0], .{ .max_size = 0 }));
    try std.testing.expectEqualDeep(before, current_size);
    try std.testing.expect(try current_size.tryAppend(.rows, rows[0], .{ .max_size = buffer.len }));
    try std.testing.expectEqual(
        try Format.encodedSize(.{ .header = 7, .rows = rows[0..1] }),
        try current_size.encodedSize(),
    );
}

test "Layout Sizer includes multiple columnar blocks and fixed-size fields" {
    const Row = struct { value: u64, text: []const u8 };
    const Format = Layout(struct {
        first: Columns(Row, .{}),
        marker: u8,
        second: Columns(Row, .{}),
    });
    const first: Row = .{ .value = 10, .text = "ten" };
    const second: Row = .{ .value = 20, .text = "twenty" };
    var current_size: Format.Sizer = .{};
    const first_only: Format.Input = .{ .first = &.{first}, .marker = 1, .second = &.{} };
    try std.testing.expect(
        try current_size.tryAppend(.first, first, .{ .max_size = try Format.encodedSize(first_only) }),
    );
    const both: Format.Input = .{ .first = &.{first}, .marker = 1, .second = &.{second} };
    try std.testing.expect(
        try current_size.tryAppend(.second, second, .{ .max_size = try Format.encodedSize(both) }),
    );
    var buffer: [512]u8 align(Format.alignment) = undefined;
    try std.testing.expectEqual(
        (try Format.write(&buffer, both)).len,
        try current_size.encodedSize(),
    );
}

test "Layout Sizer stays unchanged when a row exceeds format limits or causes overflow" {
    const Format = Layout(struct { rows: Columns(struct { values: []const u64 }, .{}) });
    var current_size: Format.Sizer = .{};
    current_size.measurements.rows.row_count = std.math.maxInt(u32);
    const row_limit = current_size;
    try std.testing.expectError(
        error.InputTooLarge,
        current_size.tryAppend(.rows, .{ .values = &.{} }, .{ .max_size = 0 }),
    );
    try std.testing.expectEqualDeep(row_limit, current_size);

    current_size = .{};
    current_size.measurements.rows.value_counts[0] = std.math.maxInt(usize);
    const overflow = current_size;
    try std.testing.expectError(
        error.InputTooLarge,
        current_size.tryAppend(.rows, .{ .values = &.{1} }, .{ .max_size = std.math.maxInt(usize) }),
    );
    try std.testing.expectEqualDeep(overflow, current_size);

    // The row count can increase, but the resulting column exceeds its stored byte-size limit
    current_size = .{};
    current_size.measurements.rows.value_counts[0] = std.math.maxInt(u32) / @sizeOf(u64);
    const column_limit = current_size;
    try std.testing.expectError(
        error.InputTooLarge,
        current_size.tryAppend(.rows, .{ .values = &.{1} }, .{ .max_size = std.math.maxInt(usize) }),
    );
    try std.testing.expectEqualDeep(column_limit, current_size);
}

test "Layout Input preserves field defaults and makes slice elements const" {
    const Header = extern struct { count: u32 = 7 };
    const Format = Layout(struct {
        version: u32 = 1,
        header: Header = .{},
        values: []u16 = &.{},
        names: []const []const u8 = &.{ "one", "two" },
        rows: Columns(struct { text: []const u8, id: u32 = 7 }, .{}),
    });
    var values = [_]u16{ 10, 20 };
    const input: Format.Input = .{ .values = &values, .rows = &.{.{ .text = "abc" }} };
    const defaults: Format.Input = .{ .rows = &.{} };
    try std.testing.expectEqual(0, defaults.values.len);
    try std.testing.expect(@TypeOf(input.values) == []const u16);
    const encoded = try Format.alloc(std.testing.allocator, input);
    defer std.testing.allocator.free(encoded);
    const view = try Format.view(encoded);
    try std.testing.expectEqual(1, view.version.*);
    try std.testing.expectEqual(7, view.header.count);
    try std.testing.expectEqualSlices(u16, &values, view.values);
    try std.testing.expectEqualStrings("one", try view.names.get(0));
    try std.testing.expectEqualStrings("two", try view.names.get(1));
    const row = try view.rows.get(0);
    try std.testing.expectEqualStrings("abc", row.text);
    try std.testing.expectEqual(7, row.id);
    // Input defaults must not become defaults for pointers and slices in View
    inline for (@typeInfo(Format.View).@"struct".fields) |field| {
        try std.testing.expect(field.default_value_ptr == null);
    }
}

test "Layout viewMutable() edits every block type without changing the stored structure" {
    const Status = enum(u8) { pending, complete };
    const Row = struct { score: u32, name: []const u8, code: u3 };
    const Format = Layout(struct {
        status: Status,
        numbers: []const u32,
        names: []const []const u8,
        flags: packed_slice.PackedSlice(bool),
        rows: Columns(Row, .{ .packed_fields = &.{.code} }),
    });
    var buffer: [512]u8 align(Format.alignment) = undefined;
    const payload = try Format.write(&buffer, .{
        .status = .pending,
        .numbers = &.{ 1, 2 },
        .names = &.{ "one", "", "two" },
        .flags = &.{ true, true, true },
        .rows = &.{
            .{ .score = 10, .name = "first", .code = 7 },
            .{ .score = 20, .name = "", .code = 6 },
            .{ .score = 30, .name = "third", .code = 7 },
        },
    });
    {
        const view = try Format.viewMutable(payload);
        view.status.* = .complete;
        view.numbers[1] = 42;
        @memcpy(try view.names.get(0), "ONE");
        try std.testing.expectEqual(0, (try view.names.get(1)).len);
        try std.testing.expectError(error.IndexOutOfBounds, view.names.get(view.names.len()));
        try view.flags.set(1, false);
        view.rows.column(.score)[0] = 99;
        @memcpy(try view.rows.column(.name).get(2), "THIRD");
        try view.rows.column(.code).set(2, 0);

        try std.testing.expectEqual(@as(u32, 99), try view.rows.value(.score, 0));
        try std.testing.expectEqualDeep(Row{ .score = 30, .name = "THIRD", .code = 0 }, try view.rows.get(2));
        var iterator = view.rows.iterator();
        try std.testing.expectEqual(@as(u32, 99), iterator.next().?.score);
        _ = iterator.next().?;
        try std.testing.expectEqualStrings("THIRD", iterator.next().?.name);
        try std.testing.expectEqual(null, iterator.next());
    }

    var reference: [512]u8 align(Format.alignment) = undefined;
    const expected = try Format.write(&reference, .{
        .status = .complete,
        .numbers = &.{ 1, 42 },
        .names = &.{ "ONE", "", "two" },
        .flags = &.{ true, false, true },
        .rows = &.{
            .{ .score = 99, .name = "first", .code = 7 },
            .{ .score = 20, .name = "", .code = 6 },
            .{ .score = 30, .name = "THIRD", .code = 0 },
        },
    });
    // Comparing the complete encoding also checks every header, offset, and padding byte
    try std.testing.expectEqualSlices(u8, expected, payload);
    _ = try Format.view(payload);
}
