// The same field cannot appear twice in packed_fields

const stash = @import("stash");
comptime {
    _ = stash.Columns(struct { flag: bool }, .{ .packed_fields = &.{ .flag, .flag } });
}
