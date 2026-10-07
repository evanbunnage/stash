// assertStorable() reports empty enums directly

const stash = @import("stash");
const Status = enum(noreturn) {};
comptime {
    stash.assertStorable(Status);
}
