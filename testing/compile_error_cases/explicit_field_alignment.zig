// align(8) puts the count field at byte 8. The three padding bytes only fill the space up to byte 4,
// so there is still a gap that Zig inserts

const stash = @import("stash");
const Value = extern struct { tag: u8, reserved: [3]u8, count: u32 align(8), end: u32 };
comptime {
    stash.assertStorable(Value);
}
