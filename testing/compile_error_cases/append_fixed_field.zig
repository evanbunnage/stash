// tryAppend() adds rows to a Columns field. It cannot append to a single u32 header

const stash = @import("stash");
const Format = stash.Layout(struct { header: u32 });
comptime {
    var sizer: Format.Sizer = .{};
    _ = sizer.tryAppend(.header, 0, .{ .max_size = 100 }) catch unreachable;
}
