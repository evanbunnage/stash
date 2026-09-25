//! Define a storage format with Layout, write data into a buffer, and read it through views.
//! Views reference the stored buffer, which must remain valid while they are in use

const comptime_validation = @import("comptime_validation.zig");
const blocks = @import("blocks.zig");
const layout = @import("layout.zig");
const packed_slice = @import("blocks/packed_slice.zig");
const columnar = @import("blocks/columnar.zig");

/// InputTooLarge means a count or byte size exceeds the format's or target's limits.
/// A larger destination buffer cannot resolve this error
pub const BufferSizeError = layout.BufferSizeError;

/// NoSpaceLeft means the destination buffer is too small. InputTooLarge means the input
/// exceeds a size limit. Size and capacity errors leave the destination buffer unchanged
pub const WriteError = layout.WriteError;

/// Opening a view failed because the buffer is too short, misaligned, or malformed,
/// or contains an invalid boolean or enum value. These checks do not detect changes
/// from one valid value to another. Use a separate checksum when you need integrity checks
pub const ViewError = layout.ViewError;

/// IndexOutOfBounds means the requested element or row index is at or beyond len()
pub const IndexError = blocks.IndexError;

/// Check at comptime that a type can be stored directly, including its nested fields.
/// Stored types cannot contain pointers or implicit padding. Stash's Layout logic performs these checks
/// automatically, but assertStorable() can also check types not used with Layout
///
/// ```zig
/// const Header = extern struct { version: u32, count: u32 };
/// comptime { stash.assertStorable(Header); }
/// ```
pub const assertStorable = comptime_validation.assertStorable;

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
///
/// Format.alloc() supplies an aligned buffer. To write into a buffer you provide, use
/// Format.encodedSize() to size it and Format.alignment for its alignment, then call Format.write().
/// To create placeholder slice elements in the buffer before filling them in, use Format.initialize().
/// Format.viewMutable() lets you edit stored values in-place. The exact implementation varies
/// by block type
/// Keep the buffer valid and unchanged while read-only views are in use
pub const Layout = layout.Layout;

/// Store rows in columnar format, grouping values by field
///
/// ```zig
/// const Row = struct { id: u32, name: []const u8 };
/// const Format = stash.Layout(struct { rows: stash.Columns(Row, .{}) });
///
/// // Input rows:
/// // .{ .id = 1, .name = "one" }
/// // .{ .id = 2, .name = "two" }
/// //
/// // Stored columns:
/// // id:   { 1, 2 }
/// // name: { "one", "two" }
/// ```
pub const Columns = columnar.Columns;

/// Choose which row fields use packed storage. Pass these options to Columns()
///
/// ```zig
/// const Row = struct { id: u32, enabled: bool };
/// const RowColumns = stash.Columns(Row, .{ .packed_fields = &.{.enabled} });
/// ```
pub const ColumnOptions = columnar.ColumnOptions;

/// Store each element using its bit width, with no gaps between elements
///
/// ```zig
/// const Format = stash.Layout(struct { codes: stash.PackedSlice(u3) });
/// // Supply .codes = &.{ 1, 2, 7 } when writing, then read an element with view.codes.get(index)
/// ```
///
/// Eight u3 elements occupy three data bytes plus a four-byte element count. Small slices
/// can take more space than slices stored without bit-packing because of that count. Packed elements can
/// share a byte, so get() returns a value rather than a pointer into the buffer.
/// Mutable views provide set(index, value) to replace an element without changing its neighbors
pub const PackedSlice = packed_slice.PackedSlice;

// Include tests from every library module, including helpers not exposed by the public API
test {
    _ = comptime_validation;
    _ = blocks;
    _ = layout;
    _ = @import("bytes.zig");
    _ = @import("runtime_validation.zig");
    _ = @import("blocks/value.zig");
    _ = @import("blocks/slice.zig");
    _ = @import("blocks/ragged_slice.zig");
    _ = packed_slice;
    _ = columnar;
}
