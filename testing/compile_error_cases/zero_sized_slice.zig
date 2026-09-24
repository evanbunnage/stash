// The slice length comes from the stored byte count.
// If each element takes zero bytes, we cannot tell how many elements were written

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { values: []const extern struct {} });
}
