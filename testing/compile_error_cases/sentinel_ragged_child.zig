// The outer slice is ordinary, but each child promises a trailing zero.
// We must check the inner slice type too

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { values: []const [:0]const u8 });
}
