what do clients do if they get the misaligned error? is this recoverable?

Yes, it's recoverable. Misalignment is about where the bytes are in memory, not what they contain, so the same bytes are fine at a different address.

What a client should do depends on why it happened:

Cause	Example	What to do
The memory just isn't aligned	readFileAlloc, or a buffer from a network read	Copy into an aligned buffer and view the copy. Better, allocate aligned in the first place with readFileAllocOptions or alignedAlloc, so the error never happens.
Your own container places records at unaligned offsets	Records packed back to back inside a page or log segment	That's a bug in the container format. Pad each record's offset up to Format.alignment when writing.
The offset came from stored data	A directory entry says "record at offset 13"	Treat it like InvalidFormat: the data is corrupt.
The copy fallback is a few lines. It gives up zero-copy for that one buffer but keeps the code working:

const view = Format.view(bytes) catch |err| switch (err) {
    error.MisalignedBuffer => blk: {
        const copy = try allocator.alignedAlloc(u8, .fromByteUnits(Format.alignment), bytes.len);
        @memcpy(copy, bytes);
        break :blk try Format.view(copy); // caller frees copy after using the view
    },
    else => return err,
};
The advice I'd give users: design your containers so stash buffers always start at aligned offsets. Then MisalignedBuffer only appears for corrupt data, and you can handle it the same way as InvalidFormat.

I wouldn't add a helper to stash for the copy. It needs an allocator and changes who owns the memory, which is the caller's decision. A short "If you get MisalignedBuffer" note in the docs, built around the table above, would cover it. Want me to add one?



Buffers must be aligned to `MyFormat.alignment`. `write()` requires that alignment in its buffer type,
but `view()` takes plain bytes and returns `error.MisalignedBuffer` instead. Stored buffers often sit at
offsets only known at runtime, like a page inside a mapped file, and checking there avoids an
`@alignCast` that would panic or cause undefined behavior on bad input. `alloc()` returns aligned
buffers, but `readFileAlloc()` does not guarantee alignment, so read files with:

```zig
const loaded = try std.Io.Dir.cwd().readFileAllocOptions(
    io,
    path,
    allocator,
    .limited(1024 * 1024),
    .fromByteUnits(MyFormat.alignment),
    null,
);
defer allocator.free(loaded);

const view = try MyFormat.view(loaded);
