//! Store optional values with a flag that distinguishes a missing value from zero
//!
//! zig build example_11

const std = @import("std");
const stash = @import("stash");

const OptionalCount = extern struct {
    count: u32,
    present: bool,
    reserved: [3]u8 = @splat(0),

    fn fromOptional(count: ?u32) OptionalCount {
        // Even an absent value needs initialized bytes in the stored representation
        return .{ .count = count orelse 0, .present = count != null };
    }

    fn toOptional(self: OptionalCount) ?u32 {
        return if (self.present) self.count else null;
    }
};
const Format = stash.Layout(struct {
    counts: []const OptionalCount,
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 11: Stash optional values\n", .{});

    const allocator = init.gpa;
    const counts = [_]OptionalCount{
        OptionalCount.fromOptional(42),
        OptionalCount.fromOptional(0),
        OptionalCount.fromOptional(null),
    };
    const byte_buffer = try Format.alloc(allocator, .{ .counts = &counts });
    defer allocator.free(byte_buffer);

    const view = try Format.view(byte_buffer);

    // Zero is a valid count, distinct from an absent count
    for (view.counts) |count| {
        std.debug.print("Count: {any}\n", .{count.toOptional()});
    }
}
