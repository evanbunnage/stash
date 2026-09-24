// Putting a union inside a packed struct must not skip the check that rejects unions

const stash = @import("stash");
const Value = packed struct { value: packed union { number: u32, signed: i32 } };
comptime {
    stash.assertStorable(Value);
}
