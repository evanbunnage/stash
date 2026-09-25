// Sizer can count rows for Columns, but it has no incremental sizing support for one-dimensional slices

const stash = @import("stash");
const Format = stash.Layout(struct { values: []const u32 });
comptime {
    const sizer: Format.Sizer = .{};
    _ = sizer.encodedSize() catch unreachable;
}
