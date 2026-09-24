// Zig's numeric error codes can change between builds, so we cannot store them directly

const stash = @import("stash");
const Value = error{NotFound};
comptime {
    stash.assertStorable(Value);
}
