// Zig vectors can have different padding and bit packing from arrays. Store an array instead

const stash = @import("stash");
const Value = @Vector(4, u32);
comptime {
    stash.assertStorable(Value);
}
