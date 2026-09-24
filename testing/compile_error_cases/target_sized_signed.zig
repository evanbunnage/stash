// isize changes width across targets. Stored integers must have an explicit width

const stash = @import("stash");
const Value = isize;
comptime {
    stash.assertStorable(Value);
}
