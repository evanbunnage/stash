// u0 has no bits to pack, so PackedSlice does not accept it

const stash = @import("stash");
comptime {
    _ = stash.PackedSlice(u0);
}
