//! Define a binary format with a Zig struct, then write and read data using that format
//!
//! cd examples && zig build example_01

const std = @import("std");
const stash = @import("stash");

const Format = stash.Layout(struct {
    version: u32,
    values: []const f64,
});

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Stash's alloc() helper sizes and aligns the buffer. view() checks its contents and borrows it
    const byte_buffer = try Format.alloc(allocator, .{
        .version = 1,
        .values = &.{ 1.5, 2.5, 3.5 },
    });
    defer allocator.free(byte_buffer);

    const view = try Format.view(byte_buffer);
    std.debug.print("version: {d}\n", .{view.version.*});
    std.debug.print("values: {any}\n", .{view.values});

    var sum: f64 = 0;
    for (view.values) |value| sum += value;
    std.debug.print("sum: {d}\n", .{sum});
}
