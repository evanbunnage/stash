// Putting a sentinel array inside an extern struct must not skip the sentinel check

const stash = @import("stash");
comptime {
    _ = stash.Layout(struct { value: extern struct { text: [3:0]u8 } });
}
