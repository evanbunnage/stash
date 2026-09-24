// u3 uses only three bits of its storage byte.
// Copying the byte would include the five unused bits

const stash = @import("stash");
const Value = u3;
comptime {
    stash.assertStorable(Value);
}
