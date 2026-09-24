// Layout uses field names to identify blocks. Tuple fields do not have the names it expects

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { u32 });
}
