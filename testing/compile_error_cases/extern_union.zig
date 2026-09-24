// An extern union has no tag telling us which field to read or validate

const stash = @import("stash");
const Value = extern union { number: u32, signed: i32 };
comptime {
    stash.assertStorable(Value);
}
