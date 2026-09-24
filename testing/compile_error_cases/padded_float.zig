// f80 has 80 value bits, but its storage takes more space. Copying it would include the padding

const stash = @import("stash");
const Value = f80;
comptime {
    stash.assertStorable(Value);
}
