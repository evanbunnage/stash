// These fields use three bits, but the struct occupies a whole byte.
// The five unused bits would be copied too

const stash = @import("stash");
const Value = packed struct { enabled: bool, mode: u2 };
comptime {
    stash.assertStorable(Value);
}
