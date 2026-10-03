//! Give a stored struct explicit padding and fixed-width fields
//!
//! cd examples && zig build example_16

const std = @import("std");
const stash = @import("stash");

const Header = extern struct {
    version: u8,
    // Without this field, the compiler would insert three unspecified bytes before record_limit
    reserved: [3]u8 = @splat(0),
    record_limit: u32,
};
const Format = stash.Layout(struct {
    header: Header,
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 16: Stash structs with padding\n", .{});

    const allocator = init.gpa;
    const requested_limit: usize = 1000;
    // Convert the application's usize to a fixed-width field, checking that it fits
    const record_limit = std.math.cast(u32, requested_limit) orelse return error.LimitTooLarge;
    const byte_buffer = try Format.alloc(allocator, .{
        .header = .{ .version = 1, .record_limit = record_limit },
    });
    defer allocator.free(byte_buffer);

    const view = try Format.view(byte_buffer);
    std.debug.print("Version: {d}\n", .{view.header.version});
    std.debug.print("Record limit: {d}\n", .{view.header.record_limit});
    std.debug.print("Reserved bytes: {any}\n", .{view.header.reserved});
}
