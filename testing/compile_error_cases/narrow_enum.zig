// The u3 enum tag leaves five unused bits in its storage byte, just like a plain u3

const stash = @import("stash");
const Value = enum(u3) { first, second };
comptime {
    stash.assertStorable(Value);
}
