// A volatile slice requires volatile memory accesses. Stash views use ordinary accesses

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { values: []volatile u8 });
}
