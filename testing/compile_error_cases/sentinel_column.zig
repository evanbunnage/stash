// Slice columns use ragged storage.
// It does not keep the trailing sentinel promised by [:0]const u8

const stash = @import("stash");
comptime {
    _ = stash.Columns(struct { text: [:0]const u8 }, .{});
}
