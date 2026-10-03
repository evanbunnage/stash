//! Store successful results and errors using a numbered status enum
//!
//! cd examples && zig build example_14

const std = @import("std");
const stash = @import("stash");

const LookupError = error{ NotFound, PermissionDenied };
// These numbers belong to the file format, unlike Zig's error numbers
const Status = enum(u32) { ok = 0, not_found = 1, permission_denied = 2 };
const StoredResult = extern struct {
    status: Status,
    value: u32 = 0,

    fn fromResult(result: LookupError!u32) StoredResult {
        const value = result catch |err| return .{ .status = switch (err) {
            error.NotFound => .not_found,
            error.PermissionDenied => .permission_denied,
        } };
        return .{ .status = .ok, .value = value };
    }

    fn toResult(self: StoredResult) LookupError!u32 {
        return switch (self.status) {
            .ok => self.value,
            .not_found => error.NotFound,
            .permission_denied => error.PermissionDenied,
        };
    }
};
const Format = stash.Layout(struct {
    results: []const StoredResult,
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 14: Stash error results\n", .{});

    const allocator = init.gpa;
    const results = [_]StoredResult{
        StoredResult.fromResult(42),
        StoredResult.fromResult(error.NotFound),
        StoredResult.fromResult(error.PermissionDenied),
    };
    const byte_buffer = try Format.alloc(allocator, .{ .results = &results });
    defer allocator.free(byte_buffer);

    const view = try Format.view(byte_buffer);

    // To store only an error code, use the enum without the value field
    for (view.results) |stored| {
        if (stored.toResult()) |value| {
            std.debug.print("Result: {d}\n", .{value});
        } else |err| {
            std.debug.print("Result: {s}\n", .{@errorName(err)});
        }
    }
}
