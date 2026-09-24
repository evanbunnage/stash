// Layout needs a struct whose fields become blocks. A plain u32 has no fields

const stash = @import("stash");
comptime {
    _ = stash.Layout(u32);
}
