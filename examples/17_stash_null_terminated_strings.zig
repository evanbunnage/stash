//! Store a null-terminated string and check its terminator when reading it
//!
//! zig build example_17

const std = @import("std");
const stash = @import("stash");

const Format = stash.Layout(struct {
    name: []const u8,
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 17: Stash null-terminated strings\n", .{});

    const allocator = init.gpa;
    const name: [:0]const u8 = "stash";
    // Include the byte at name.len, where Zig guarantees a zero terminator
    const bytes_with_terminator: []const u8 = name[0 .. name.len + 1];
    const byte_buffer = try Format.alloc(allocator, .{ .name = bytes_with_terminator });
    defer allocator.free(byte_buffer);

    const view = try Format.view(byte_buffer);

    // A byte slice alone does not guarantee a terminator
    if (view.name.len == 0 or view.name[view.name.len - 1] != 0) return error.MissingTerminator;
    const length = view.name.len - 1;
    // C string consumers would stop early if there were another zero inside the name
    if (std.mem.indexOfScalar(u8, view.name[0..length], 0) != null) return error.InteriorZero;
    const restored: [:0]const u8 = view.name[0..length :0];
    std.debug.print("Name: {s}\n", .{restored});
    std.debug.print("Stored bytes including terminator: {any}\n", .{view.name});
    // For a sentinel array [N:0]u8, the stored array would include all N + 1 bytes
}
