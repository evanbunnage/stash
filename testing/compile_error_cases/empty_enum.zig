// Zig backs an enum with no tags by noreturn, so no value of it can exist

const stash = @import("stash");
const Status = enum(noreturn) {};
comptime {
    _ = stash.Layout(struct { status: Status });
}
