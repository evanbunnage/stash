// Columns returns read-only slices.
// A []u8 row field would promise mutation that the view cannot provide

const stash = @import("stash");
comptime {
    _ = stash.Columns(struct { text: []u8 }, .{});
}
