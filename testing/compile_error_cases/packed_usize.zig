// usize still changes width across targets when it is inside a packed struct

const stash = @import("stash");
const Value = packed struct { count: usize };
comptime {
    stash.assertStorable(Value);
}
