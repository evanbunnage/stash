// Comptime fields have no runtime storage. They cannot be used as layout fields

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { comptime version: u32 = 1 });
}
