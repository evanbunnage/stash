// PackedSlice has no mutable view. Layout must report that when MutableView is requested

const stash = @import("stash");
const Format = stash.Layout(struct { values: stash.PackedSlice(u3) });
comptime {
    _ = Format.MutableView;
}
