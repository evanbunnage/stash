//! This example shows how to store SIMD vectors (@Vector). Stash rejects vectors because their memory
//! layout isn't guaranteed to match an array's (bool vectors are bit-packed, and some lengths get extra
//! padding, like @Vector(3, f32) taking 16 bytes). So instead, store an array and "convert" it with @Vector
//!
//! key takeaways:
//! - store [N]T instead of @Vector(N, T)
//! - assign the vector to an array when writing, and the array back to a vector when reading
//! - converting the stored array to a vector costs nothing extra at read time: it compiles to the same single
//!   load as reading a vector directly
//!
//! cd examples && zig build example_15

const std = @import("std");
const stash = @import("stash");

const Format = stash.Layout(struct {
    samples: [4]f32,
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 15: Stash vectors\n", .{});

    const allocator = init.gpa;
    const input: @Vector(4, f32) = .{ 1, 2, 3, 4 };
    // Zig converts vectors to arrays without manual byte encoding
    const samples: [4]f32 = input;
    const byte_buffer = try Format.alloc(allocator, .{ .samples = samples });
    defer allocator.free(byte_buffer);

    const view = try Format.view(byte_buffer);

    // Load the stored array into a vector for arithmetic
    const lanes: @Vector(4, f32) = view.samples.*;
    const doubled = lanes * @as(@Vector(4, f32), @splat(2));
    std.debug.print("Stored samples: {any}\n", .{view.samples.*});
    std.debug.print("Doubled sum: {d}\n", .{@reduce(.Add, doubled)});
}
