// This default constructs the Columns block itself, but the input needs a slice of rows.
// Put the default on the input rather than the schema

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { rows: stash.Columns(struct { id: u32 }, .{}) = .{} });
}
