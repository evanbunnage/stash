const std = @import("std");
const compile_error_cases = @import("testing/compile_error_cases.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run Zig tests whose names contain this text",
    ) orelse &.{};

    const check_step = b.step("check", "Compile unit tests and check expected compilation errors");
    const test_step = b.step("test", "Run unit tests and check expected compilation errors");
    const fmt_check_step = b.step("fmt-check", "Check Zig formatting without changing files");

    b.default_step = check_step;

    const stash = b.addModule("stash", .{
        .root_source_file = b.path("src/stash.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{ .root_module = stash, .filters = test_filters });
    check_step.dependOn(&unit_tests.step);
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    compile_error_cases.addCases(b, check_step, stash);
    test_step.dependOn(check_step);

    fmt_check_step.dependOn(&b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src", "testing" },
        .check = true,
    }).step);
}
