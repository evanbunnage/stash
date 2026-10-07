// An array of empty enums has no possible values either

const stash = @import("stash");
const Status = enum(noreturn) {};
comptime {
    _ = stash.Layout(struct { statuses: [2]Status });
}
