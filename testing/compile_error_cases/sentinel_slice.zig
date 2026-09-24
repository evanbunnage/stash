// Slice storage copies len elements. The sentinel sits after them and would not be copied

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { values: [:0]const u8 });
}
