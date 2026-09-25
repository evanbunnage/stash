//! Store a slice of records and update a record in place
//!
//! zig build example_04

const std = @import("std");
const stash = @import("stash");

const Status = enum(u32) {
    pending = 0,
    complete = 1,
};

const Job = extern struct {
    id: u32,
    status: Status,
};

const Format = stash.Layout(struct {
    jobs: []const Job,
});

pub fn main(init: std.process.Init) !void {
    std.debug.print("Example 04: Stash a slice of structs\n", .{});

    const allocator = init.gpa;
    const jobs = [_]Job{
        .{ .id = 10, .status = .pending },
        .{ .id = 11, .status = .complete },
    };
    const byte_buffer = try Format.alloc(allocator, .{ .jobs = &jobs });
    defer allocator.free(byte_buffer);

    const view = try Format.viewMutable(byte_buffer);
    std.debug.print("Job {d} before edit: {s}\n", .{ view.jobs[0].id, @tagName(view.jobs[0].status) });

    // The view refers to the stored records, so assignment changes the buffer directly
    view.jobs[0].status = .complete;
    std.debug.print("Job {d} after edit: {s}\n", .{ view.jobs[0].id, @tagName(view.jobs[0].status) });
    std.debug.print("Original input: {s}\n", .{@tagName(jobs[0].status)});

    // The slice has a fixed length, just like a regular Zig slice
    for (view.jobs) |job| {
        std.debug.print("Job {d}: {s}\n", .{ job.id, @tagName(job.status) });
    }
}
