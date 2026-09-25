//! Store a union using an explicit tag and fields for its alternatives
//!
//! zig build example_12

const std = @import("std");
const stash = @import("stash");

const Setting = union(enum) {
    retry_limit: u32,
    enabled: bool,
};
const Tag = enum(u32) { retry_limit = 0, enabled = 1 };
const StoredSetting = extern struct {
    tag: Tag,
    retry_limit: u32 = 0,
    enabled: bool = false,
    reserved: [3]u8 = @splat(0),

    fn fromSetting(setting: Setting) StoredSetting {
        return switch (setting) {
            .retry_limit => |limit| .{ .tag = .retry_limit, .retry_limit = limit },
            .enabled => |enabled| .{ .tag = .enabled, .enabled = enabled },
        };
    }

    fn toSetting(self: StoredSetting) Setting {
        return switch (self.tag) {
            .retry_limit => .{ .retry_limit = self.retry_limit },
            .enabled => .{ .enabled = self.enabled },
        };
    }
};
const Format = stash.Layout(struct {
    settings: []const StoredSetting,
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 12: Stash tagged unions\n", .{});

    const allocator = init.gpa;
    const settings = [_]StoredSetting{
        StoredSetting.fromSetting(.{ .retry_limit = 3 }),
        StoredSetting.fromSetting(.{ .enabled = true }),
    };
    const byte_buffer = try Format.alloc(allocator, .{ .settings = &settings });
    defer allocator.free(byte_buffer);

    const view = try Format.view(byte_buffer);

    // Both alternatives occupy space and have valid values, even when inactive.
    // This lets view() check the tag and bool without application-specific decoding
    for (view.settings) |stored| {
        switch (stored.toSetting()) {
            .retry_limit => |limit| std.debug.print("Retry limit: {d}\n", .{limit}),
            .enabled => |enabled| std.debug.print("Enabled: {}\n", .{enabled}),
        }
    }
}
