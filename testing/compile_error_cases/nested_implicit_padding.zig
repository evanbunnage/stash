// The outer struct has no gaps, but the inner struct does. We must check both structs for padding

const stash = @import("stash");
const Value = extern struct { inner: extern struct { tag: u8, count: u32 } };
comptime {
    stash.assertStorable(Value);
}
