//! Find how many records fit in a page, then write them into it
//!
//! cd examples && zig build example_10

const std = @import("std");
const stash = @import("stash");

const Row = struct {
    id: u32,
    name: []const u8,
    active: bool,
};
const Format = stash.Layout(struct {
    page_id: u64,
    rows: stash.Columns(Row, .{ .packed_fields = &.{.active} }),
});

pub fn main() !void {
    std.debug.print("Example 10: Fit records into a page\n", .{});

    const rows = [_]Row{
        .{ .id = 1, .name = "README.md", .active = true },
        .{ .id = 2, .name = "build.zig", .active = false },
        .{ .id = 3, .name = "src/layout.zig", .active = true },
        .{ .id = 4, .name = "src/blocks/columnar.zig", .active = true },
        .{ .id = 5, .name = "testing/compile_error_cases.zig", .active = false },
    };
    var page: [128]u8 align(Format.alignment) = undefined;
    var sizer: Format.Sizer = .{};
    var accepted: usize = 0;
    for (rows) |row| {
        if (!try sizer.tryAppend(.rows, row, .{ .max_size = page.len })) break;
        accepted += 1;
    }

    // Sizer measures rows but does not retain them. Supply the accepted rows to write()
    const byte_buffer = try Format.write(&page, .{ .page_id = 7, .rows = rows[0..accepted] });
    std.debug.print("Records that fit: {d} of {d}\n", .{ accepted, rows.len });
    std.debug.print("Page space used: {d} of {d} bytes\n", .{ byte_buffer.len, page.len });

    // Pass only the used bytes to view(). If saving the whole page, also save this length
    const view = try Format.view(byte_buffer);
    for (0..view.rows.len()) |index| {
        const row = view.rows.get(index);
        std.debug.print("Record {d}: {s}, active={}\n", .{ row.id, row.name, row.active });
    }
    std.debug.print("Records left for the next page: {d}\n", .{rows.len - accepted});
}
