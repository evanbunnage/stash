//! Inspect the schema and stored bytes of Mars rover telemetry
//!
//! cd examples && zig build example_08

const std = @import("std");
const stash = @import("stash");

const RoverMode = enum(u2) {
    parked = 0,
    driving = 1,
    charging = 2,
};

const RoverTelemetry = stash.Layout(struct {
    format_version: u8,
    elapsed_seconds: []const u32,
    battery_percent: []const u8,
    modes: stash.PackedSlice(RoverMode),
});

pub fn main(init: std.process.Init) !void {
    // describe() needs only the schema, so it works before any data is written
    std.debug.print("RoverTelemetry.describe()\n{f}", .{RoverTelemetry.describe()});
    // Generate a day of sample telemetry at one reading per minute
    const reading_count = 24 * 60;
    var elapsed_seconds: [reading_count]u32 = undefined;
    var battery_percent: [reading_count]u8 = undefined;
    var modes: [reading_count]RoverMode = undefined;
    for (0..reading_count) |minute| {
        elapsed_seconds[minute] = @intCast(minute * 60);
        modes[minute] = switch ((minute / 120) % 3) {
            0 => .parked,
            1 => .driving,
            else => .charging,
        };
        battery_percent[minute] = switch (modes[minute]) {
            .parked => 80,
            .driving => 65,
            .charging => 90,
        };
    }

    const byte_buffer = try RoverTelemetry.alloc(init.gpa, .{
        .format_version = 1,
        // Entries at the same index describe one reading
        .elapsed_seconds = &elapsed_seconds,
        .battery_percent = &battery_percent,
        .modes = &modes,
    });
    defer init.gpa.free(byte_buffer);

    // inspect() validates the buffer and returns a report of its layout
    const report = try RoverTelemetry.inspect(byte_buffer);
    std.debug.print("\nRoverTelemetry.inspect()\n{f}", .{report});
}
