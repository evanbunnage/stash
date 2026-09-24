// A sentinel array still stores its terminator even when its length is zero

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { value: [0:0]u8 });
}
