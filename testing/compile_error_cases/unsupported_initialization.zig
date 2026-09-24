// PackedSlice cannot be initialized in place. initializedSize() must reject it too

const stash = @import("stash");
const Format = stash.Layout(struct { values: stash.PackedSlice(u3) });
comptime {
    _ = Format.initializedSize(.{ .values = .{ .count = 3, .value = 0 } }) catch unreachable;
}
