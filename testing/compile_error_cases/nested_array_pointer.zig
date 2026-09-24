// The pointer check must reach fields inside structs that are themselves array elements

const stash = @import("stash");
const Value = [2]extern struct { address: *const u32 };
comptime {
    stash.assertStorable(Value);
}
