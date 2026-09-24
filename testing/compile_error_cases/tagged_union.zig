// Stash does not support reading and validating union variants, even when the union has a tag

const stash = @import("stash");
const Value = union(enum) { number: u32, flag: bool };
comptime {
    stash.assertStorable(Value);
}
