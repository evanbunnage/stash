//! Store a struct and read its fields zero-copy as a typed view
//!
//! zig build example_03

const std = @import("std");
const stash = @import("stash");

// Stored structs need an explicit layout (extern or packed)
const ImageInfo = extern struct {
    id: u64,
    width: u32,
    height: u32,
};

const Format = stash.Layout(struct {
    image: ImageInfo,
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 03: Stash a struct\n", .{});

    const allocator = init.gpa;
    const byte_buffer = try Format.alloc(allocator, .{
        .image = .{ .id = 7, .width = 1920, .height = 1080 },
    });
    defer allocator.free(byte_buffer);

    const view = try Format.view(byte_buffer);
    const image: *const ImageInfo = view.image;
    std.debug.print("Image ID: {d}\n", .{image.id});
    std.debug.print("Dimensions: {d} x {d}\n", .{ image.width, image.height });
}

// ---------------

// In this struct, the compiler inserts one byte before alpha to align the u16 field.
// Add a 1-byte field before alpha to make that byte explicit
const Pixel = extern struct {
    red: u8,
    green: u8,
    blue: u8,
    // _reserved: [1]u8, // This field becomes necessary in stash to make the padding explicit
    alpha: u16,
};

// Uncomment to see stash reject the implicit padding at compile time
// comptime {
//     stash.assertStorable(Pixel);
// }
