// Columns check each row field the same way Layout checks its fields

const stash = @import("stash");
const Status = enum(noreturn) {};
comptime {
    _ = stash.Columns(struct { status: Status }, .{});
}
