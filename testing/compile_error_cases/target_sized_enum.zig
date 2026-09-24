// An enum with a usize tag changes size across targets.
// The tag type needs the same check as integers

const stash = @import("stash");
const Value = enum(usize) { first, second };
comptime {
    stash.assertStorable(Value);
}
