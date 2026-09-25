//! Save data to a file, then load it and read it using the same format
//!
//! zig build example_02

const std = @import("std");
const stash = @import("stash");

const Format = stash.Layout(struct {
    version: u32,
    values: []const f64,
});

fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const byte_buffer = try Format.alloc(allocator, .{
        .version = 1,
        .values = &.{ 1.5, 2.5, 3.5 },
    });
    defer allocator.free(byte_buffer);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = byte_buffer,
    });
    std.debug.print("Saved {d} bytes to {s}\n", .{ byte_buffer.len, path });
}

fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const loaded = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(1024 * 1024), // Limit this example to files up to 1 MiB
        .fromByteUnits(Format.alignment),
        null,
    );
    defer allocator.free(loaded);
    std.debug.print("Loaded {d} bytes from {s}\n", .{ loaded.len, path });

    const view = try Format.view(loaded);
    std.debug.print("Version: {d}\n", .{view.version.*});
    std.debug.print("Values ({d}): {any}\n", .{ view.values.len, view.values });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const path = "example_02.stash";

    try save(io, allocator, path);
    try load(io, allocator, path);
}
