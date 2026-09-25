//! Generate a lookup table directly in the output buffer
//!
//! zig build example_09

const std = @import("std");
const stash = @import("stash");

const Format = stash.Layout(struct {
    squares: []const u32,
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 09: Build data in place\n", .{});

    const allocator = init.gpa;
    const initial_values: Format.Init = .{
        .squares = .{ .count = 16, .value = 0 },
    };
    // Size and align the buffer for the requested number of elements
    const byte_count = try Format.initializedSize(initial_values);
    const byte_buffer = try allocator.alignedAlloc(u8, .fromByteUnits(Format.alignment), byte_count);
    defer allocator.free(byte_buffer);

    // initialize() creates 16 stored elements, each starting at zero
    const initialized = try Format.initialize(byte_buffer, initial_values);
    std.debug.print("Before filling: {any}\n", .{initialized.view.squares});
    for (initialized.view.squares, 0..) |*square, index| {
        const n: u32 = @intCast(index);
        square.* = n * n;
    }

    // These edits are already in initialized.bytes, ready to save without calling write()
    std.debug.print("Squares: {any}\n", .{initialized.view.squares});
    std.debug.print("Bytes ready to save: {d}\n", .{initialized.bytes.len});
}
