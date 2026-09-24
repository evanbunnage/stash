// Layout chooses alignment from each block's type.
// An align(8) on the schema field would be ignored

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { version: u32 align(8) });
}
