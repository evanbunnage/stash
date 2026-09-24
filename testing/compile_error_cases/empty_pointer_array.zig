// The array has no elements, but we must still check its element type.
// Length zero must not skip the pointer check

const stash = @import("stash");
const Value = [0]*const u32;
comptime {
    stash.assertStorable(Value);
}
