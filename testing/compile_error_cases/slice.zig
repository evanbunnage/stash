// assertStorable() checks the slice itself, which contains a pointer.
// A slice field in Layout is different because Layout stores its elements

const stash = @import("stash");
const Value = []const u8;
comptime {
    stash.assertStorable(Value);
}
