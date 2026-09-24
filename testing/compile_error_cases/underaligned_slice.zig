// align(1) allows unaligned u32 elements.
// Stash views require u32's natural alignment

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { values: []align(1) const u32 });
}
