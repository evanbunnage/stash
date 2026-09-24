// Columns chooses alignment from each field's type. An align(8) on the row field would be ignored

const stash = @import("stash");
comptime {
    _ = stash.Columns(struct { id: u32 align(8) }, .{});
}
