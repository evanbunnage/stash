// An error union includes a Zig error code, which can change between builds.
// Its memory layout is not a stable storage format either

const stash = @import("stash");
const Value = error{NotFound}!u32;
comptime {
    stash.assertStorable(Value);
}
