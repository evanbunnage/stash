//! Store strings of different lengths and read each one from the buffer
//!
//! cd examples && zig build example_05

const std = @import("std");
const stash = @import("stash");

// Strings are byte slices here, without an implied encoding or terminator
const Format = stash.Layout(struct {
    names: []const []const u8,
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 05: Stash strings\n", .{});

    const allocator = init.gpa;
    const byte_buffer = try Format.alloc(allocator, .{
        .names = &.{ "alpha", "", "beta" },
    });
    defer allocator.free(byte_buffer);

    const view = try Format.view(byte_buffer);
    for (0..view.names.len()) |index| {
        // get() returns a slice into the buffer for this string
        const name = view.names.get(index);
        std.debug.print("Name {d}: \"{s}\" ({d} bytes)\n", .{ index, name, name.len });
    }
}
