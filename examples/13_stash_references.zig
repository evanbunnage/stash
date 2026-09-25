//! Refer to stored records by index instead of saving memory addresses
//!
//! zig build example_13

const std = @import("std");
const stash = @import("stash");

// Reserve one index to represent a null parent pointer
const no_parent = std.math.maxInt(u32);
const Node = extern struct {
    value: u32,
    // Indices survive saving and loading, but must be updated if records are reordered
    parent_index: u32 = no_parent,
};
const Format = stash.Layout(struct {
    nodes: []const Node,
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 13: Stash references\n", .{});

    const allocator = init.gpa;
    const nodes = [_]Node{
        .{ .value = 10 },
        .{ .value = 20, .parent_index = 0 },
        .{ .value = 30, .parent_index = 1 },
    };
    const byte_buffer = try Format.alloc(allocator, .{ .nodes = &nodes });
    defer allocator.free(byte_buffer);

    const view = try Format.view(byte_buffer);

    // view() checks the stored types, but the application must check what an index refers to
    for (view.nodes) |node| {
        if (node.parent_index == no_parent) {
            std.debug.print("Node {d}: no parent\n", .{node.value});
            continue;
        }
        if (node.parent_index >= view.nodes.len) return error.InvalidParentIndex;
        const parent = &view.nodes[node.parent_index];
        std.debug.print("Node {d}: parent {d}\n", .{ node.value, parent.value });
    }
}
