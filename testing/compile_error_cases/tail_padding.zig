// Zig adds three bytes after the tag field to keep the struct aligned. Those bytes could be uninitialized

const stash = @import("stash");
const Value = extern struct { count: u32, tag: u8 };
comptime {
    stash.assertStorable(Value);
}
