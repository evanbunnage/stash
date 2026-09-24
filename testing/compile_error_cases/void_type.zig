// void is not a supported stored type.
// Empty extern structs are allowed, so this is not a general ban on zero-sized values

const stash = @import("stash");
const Value = void;
comptime {
    stash.assertStorable(Value);
}
