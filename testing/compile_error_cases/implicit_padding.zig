// Zig inserts bytes between the tag and count fields.
// Those bytes can be uninitialized when we copy the struct

const stash = @import("stash");
const Value = extern struct { tag: u8, count: u32 };
comptime {
    stash.assertStorable(Value);
}
