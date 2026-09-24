// usize changes width across targets. Stored integers must have an explicit width

const stash = @import("stash");
const Value = usize;
comptime {
    stash.assertStorable(Value);
}
