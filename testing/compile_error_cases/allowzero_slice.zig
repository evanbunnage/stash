// allowzero permits a slice to point at address zero. Stash views do not support that

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { values: []allowzero u8 });
}
