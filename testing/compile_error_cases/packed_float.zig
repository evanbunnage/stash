// f32 is supported on its own, but the packed-field code does not support floats

const stash = @import("stash");
const Value = packed struct { value: f32 };
comptime {
    stash.assertStorable(Value);
}
