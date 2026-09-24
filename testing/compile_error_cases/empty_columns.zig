// An empty row struct gives Columns no fields to store

const stash = @import("stash");
comptime {
    _ = stash.Columns(struct {}, .{});
}
