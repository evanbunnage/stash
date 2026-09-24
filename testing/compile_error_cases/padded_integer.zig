// u24 occupies four bytes, so copying it would include eight unused bits

const stash = @import("stash");
const Value = u24;
comptime {
    stash.assertStorable(Value);
}
