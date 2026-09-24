// The ragged reader finds the element count by dividing the stored byte count by the element size.
// An empty struct would make that a division by zero

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { values: []const []const extern struct {} });
}
