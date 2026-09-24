// Sentinel arrays are not supported.
// Store the terminator as an ordinary array element if you need to keep it

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { value: [2:0]u8 });
}
