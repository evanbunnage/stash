// Zig can reorder fields in an ordinary struct, so we cannot use its memory layout for storage

const stash = @import("stash");
const Value = struct { count: u32 };
comptime {
    stash.assertStorable(Value);
}
