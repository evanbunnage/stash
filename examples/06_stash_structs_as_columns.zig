//! Store records in columns so you can process one field across all rows
//!
//! cd examples && zig build example_06

const std = @import("std");
const stash = @import("stash");

// Columns() stores the fields separately, so Row does not need an extern layout
const Row = struct {
    id: u32,
    score: f64,
};
const Format = stash.Layout(struct {
    rows: stash.Columns(Row, .{}),
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 06: Stash structs as columns\n", .{});

    const allocator = init.gpa;
    const rows = [_]Row{
        .{ .id = 10, .score = 1.5 },
        .{ .id = 11, .score = 2.5 },
        .{ .id = 12, .score = 3.5 },
    };
    const byte_buffer = try Format.alloc(allocator, .{ .rows = &rows });
    defer allocator.free(byte_buffer);

    const view = try Format.view(byte_buffer);
    const scores: []const f64 = view.rows.column(.score);
    var sum: f64 = 0;
    for (scores) |score| sum += score;
    std.debug.print("Scores: {any}\n", .{scores});

    std.debug.print("Total score: {d}\n", .{sum});

    // get() gathers a row from its columns and returns it by value
    const row = view.rows.get(1);
    std.debug.print("Row 1: id={d}, score={d}\n", .{ row.id, row.score });
}
