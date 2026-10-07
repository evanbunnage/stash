// A slice of empty enums could only ever be empty, so stash rejects it

const stash = @import("stash");
const Status = enum(noreturn) {};
comptime {
    _ = stash.Layout(struct { statuses: []const Status });
}
