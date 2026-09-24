// The outer array has no sentinel, but each inner array does. We must check the element type too

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { value: [2][2:0]u8 });
}
