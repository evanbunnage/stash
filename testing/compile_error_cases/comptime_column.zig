// A comptime row field has no runtime storage to turn into a column

const stash = @import("stash");
comptime {
    _ = stash.Columns(struct { comptime id: u32 = 0 }, .{});
}
