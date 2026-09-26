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

    const check_step = b.step("check", "Compile tests and examples and check expected compilation errors");
    const test_step = b.step("test", "Run tests and examples and check expected compilation errors");
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

    // Compile examples with check, and run them with test or their individual build steps
    const examples_step = b.step("examples", "Run all examples");
    test_step.dependOn(examples_step);
    const examples = .{
        "01_stash_values_and_slices",
        "02_save_and_load_a_file",
        "03_stash_a_struct",
        "04_stash_a_slice_of_structs",
        "05_stash_strings",
        "06_stash_structs_as_columns",
        "07_pack_small_values",
        "08_inspect_a_layout",
        "09_build_data_in_place",
        "10_fit_records_into_a_page",
        "11_stash_optional_values",
        "12_stash_tagged_unions",
        "13_stash_references",
        "14_stash_error_results",
        "15_stash_vectors",
        "16_stash_structs_with_padding",
        "17_stash_null_terminated_strings",
    };
    inline for (examples) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "stash", .module = stash }},
            }),
        });
        check_step.dependOn(&example.step);
        const run = b.addRunArtifact(example);
        run.stdio = .inherit;
        if (comptime std.mem.eql(u8, name, "02_save_and_load_a_file")) {
            // Keep the example's output file in the build cache
            run.setCwd(.{ .cwd_relative = b.cache_root.path orelse "." });
        }
        b.step("example_" ++ name[0..2], "Run " ++ name ++ ".zig").dependOn(&run.step);
        examples_step.dependOn(&run.step);
    }

    fmt_check_step.dependOn(&b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src", "testing", "examples" },
        .check = true,
    }).step);
}
