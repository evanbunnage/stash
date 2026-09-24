// Saving a pointer saves an address in this process.
// That address may be meaningless when the data is loaded again

const stash = @import("stash");
const Value = *const u32;
comptime {
    stash.assertStorable(Value);
}
