// Stash only guarantees the alignment required by the element type.
// A []align(16) u32 would promise alignment we cannot guarantee

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { values: []align(16) const u32 });
}
