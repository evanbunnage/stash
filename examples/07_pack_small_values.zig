//! Store flags and small values using only the bits they need
//!
//! cd examples && zig build example_07

const std = @import("std");
const stash = @import("stash");

const Flags = packed struct(u8) {
    enabled: bool,
    priority: u3,
    reserved: u4 = 0, // Fill the remaining bits so all eight are defined
};
const State = enum(u2) { pending = 0, active = 1, complete = 2 };
const Format = stash.Layout(struct {
    flags: Flags,
    states: stash.PackedSlice(State),
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 07: Pack small values\n", .{});

    const allocator = init.gpa;
    const states = [_]State{ .pending, .active, .complete, .pending } ** 16;
    const byte_buffer = try Format.alloc(allocator, .{
        .flags = .{ .enabled = true, .priority = 5 },
        .states = &states,
    });
    defer allocator.free(byte_buffer);

    const view = try Format.viewMutable(byte_buffer);
    std.debug.print("Flags: enabled={}, priority={d}\n", .{ view.flags.enabled, view.flags.priority });
    std.debug.print("First state before edit: {s}\n", .{@tagName(view.states.get(0))});

    // Packed elements share bytes, so set() updates one element without changing its neighbors
    view.states.set(0, .complete);
    for (0..4) |index| {
        std.debug.print("State {d}: {s}\n", .{ index, @tagName(view.states.get(index)) });
    }
    std.debug.print("{d} {d}-bit values use {d} bytes packed, instead of {d} bytes unpacked\n", .{
        view.states.len(),
        @bitSizeOf(State),
        view.states.data.len,
        view.states.len() * @sizeOf(State),
    });
    std.debug.print("Complete buffer with flags and metadata: {d} bytes\n", .{byte_buffer.len});
}
