// Stash doesn't support optional values.
// Use a separate bool to record whether a value is present

const stash = @import("stash");
const Value = ?u32;
comptime {
    stash.assertStorable(Value);
}
