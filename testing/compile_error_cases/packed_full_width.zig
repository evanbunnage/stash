// u32 already uses every bit of its storage.
// PackedSlice would add overhead without saving any space

const stash = @import("stash");
comptime {
    _ = stash.PackedSlice(u32);
}
