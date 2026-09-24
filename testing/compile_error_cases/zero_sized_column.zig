// A slice field becomes a ragged column, which needs nonzero-sized elements to recover its lengths

const stash = @import("stash");
comptime {
    _ = stash.Columns(struct { values: []const extern struct {} }, .{});
}
