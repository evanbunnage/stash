const std = @import("std");

// Run examples from this directory with `zig build example_03`
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const stash = b.dependency("stash", .{
        .target = target,
        .optimize = optimize,
    }).module("stash");

    const all_step = b.step("all", "Run all examples");
    b.default_step = all_step;
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
        "13_stash_pointer_references",
        "14_stash_error_results",
        "15_stash_vectors",
        "16_stash_null_terminated_strings",
    };
    inline for (examples) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "stash", .module = stash }},
            }),
        });
        const run = b.addRunArtifact(example);
        run.stdio = .inherit;
        if (comptime std.mem.eql(u8, name, "02_save_and_load_a_file")) {
            // Keep the example's output file in the build cache
            run.setCwd(.cache_root);
        }
        b.step("example_" ++ name[0..2], "Run " ++ name ++ ".zig").dependOn(&run.step);
        all_step.dependOn(&run.step);
    }
}
