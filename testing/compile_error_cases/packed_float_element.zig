// PackedSlice does not support float elements. An ordinary []const f32 can store them

const stash = @import("stash");
comptime {
    _ = stash.PackedSlice(f32);
}
