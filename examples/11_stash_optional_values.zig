//! This example shows how to store optional values (?T). Zig doesn't define a stable byte layout for
//! optionals, so stash rejects them, and you store a presence flag next to the value instead.
//! rkyv's archived Option uses the same layout (a tag plus the value) but checks the tag for you.
//! User's of stash need to have their application read the flag itself.
//!
//! takeaways:
//! - store a presence flag next to the value, so zero can be a real value instead of meaning "missing"
//! - store zero in the value when it's absent, so equal optionals always produce identical bytes
//! - stash checks that the flag is a valid bool, but your application decides what the pair means
//!
//! cd examples && zig build example_11

const std = @import("std");
const stash = @import("stash");

const OptionalCount = extern struct {
    count: u32,
    present: bool,
    reserved: [3]u8 = @splat(0),

    fn fromOptional(count: ?u32) OptionalCount {
        // Store zero when absent, so equal optional values always produce identical bytes
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
