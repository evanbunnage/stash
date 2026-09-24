// The slice itself has no sentinel, but its array elements do. We must check the element type too

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { values: []const [3:0]u8 });
}
