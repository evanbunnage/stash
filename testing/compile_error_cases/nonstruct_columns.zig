// Columns needs a struct whose fields become columns. A plain u32 has no fields

const stash = @import("stash");
comptime {
    _ = stash.Columns(u32, .{});
}
