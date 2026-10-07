// PackedSlice elements must be storable values too

const stash = @import("stash");
const Status = enum(noreturn) {};
comptime {
    _ = stash.PackedSlice(Status);
}
