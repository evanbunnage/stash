// An array of u3 still uses a full byte per element.
// Putting values in an array does not pack their bits

const stash = @import("stash");
const Value = [4]u3;
comptime {
    stash.assertStorable(Value);
}
