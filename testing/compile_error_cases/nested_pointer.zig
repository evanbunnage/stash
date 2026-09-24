// The pointer is two struct levels down. Validation must still find it

const stash = @import("stash");
const Value = extern struct { inner: extern struct { address: *const u32 } };
comptime {
    stash.assertStorable(Value);
}
