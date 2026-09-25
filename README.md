# stash

A Zig library for creating binary data formats with zero-copy reads.

## Highlights

- Zero-copy reads
- Optional runtime checks to validate bounds, alignment, and boolean/enum representations
- Compile-time rejection of pointers, structs with implicit padding, and other types that can’t be
  stored directly
- Compact internal metadata for low storage overhead
- Formats defined with simple Zig structs, without a separate schema language or complex codegen
- Support for scalar values, structs, slices, nested slices (e.g. slices of strings), and dense
  bit-packed data
- Columnar storage defined from a struct, like Zig’s `MultiArrayList`
- Mutable views for in-place edits

Note that users of this library are responsible for buffer lifetimes!

## Usage

Define formats using Zig structs:

```zig
const stash = @import("stash");

const MyFormat = stash.Layout(
    struct {
        version: u32,
        my_data: []const f64,
    },
);
```

Read stored data through typed views without allocating or copying:

```zig
var buffer: [128]u8 align(MyFormat.alignment) = undefined;
const encoded = try MyFormat.write(
    &buffer,
    .{
        .version = 1,
        .my_data = &.{ 1.5, 2.5, 3.5 },
    },
);

const view = try MyFormat.view(encoded); // fast
// view.version.*
// 1
// view.my_data[1]
// 2.5
```

Stash's typed views exclusively borrow from caller-owned buffers. This means **your application must
always manage the buffer and its lifetime!**

Free allocated buffers after you're done with those views:

```zig
const byte_buffer = try MyFormat.alloc(
    allocator,
    .{
        .version = 1,
        .my_data = &.{ 1.5, 2.5, 3.5 },
    },
);
defer allocator.free(byte_buffer);

const view = try MyFormat.view(byte_buffer);
// Use view before freeing byte_buffer
```

## Getting started

Requires Zig 0.16.0.

```sh
zig fetch --save=stash git+https://github.com/evanbunnage/stash
```

Add to `build.zig`:

```zig
const stash = b.dependency("stash", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("stash", stash.module("stash"));
```

Then simply `@import("stash")`

## When should I use stash?

Stash can be useful when your application needs a custom binary format and fast access to the stored
data. Typically, your application will wrap stash to handle things like data integrity checks,
format versions, migrations, and runtime schema handling (file formats are complex!).

I've personally found it useful for database use cases like defining custom page formats and
indexes.

## When should I not use stash?

Assuming you're building with Zig, there are some limitations:

- Stash isn't great out of the box for streaming applications since it expects a complete buffer
  before you can read its contents. However, since stash's formats are customizable and compact,
  your application could frame the stream as separate stash buffers and process each one as it
  arrives. Let me know if better support for this is valuable!
- If you frequently read data that subsequently needs to be resized, zero-copy access is less useful
  since stash's mutable views are limited to in-place edits. However, you can still copy individual
  fields into your own managed growable containers and read the rest through stash's views. To
  persist those changes, your application would need to write to a new buffer.
- Currently little-endian only

Outside of a Zig context, stash is stricter than [rkyv](https://rkyv.org/), meaning you can't just pass any data
structure to it and have stash serialize it. You also shouldn't use stash if you want broad
interoperability across languages and runtimes. With great power...

Here are some other Zig ser/de projects to consider. Please submit a PR if you know more that should
be up here:

- [s2s](https://github.com/ziglibs/s2s): Serialize Zig values to a binary stream and deserialize them back
- [zbor](https://codeberg.org/r4gus/zbor): Encode and decode CBOR, a standardized binary interchange format
- [zig-protobuf](https://github.com/Arwalk/zig-protobuf): Use protobufs to exchange data with applications written in other languages
- [Ziggy](https://ziggy-lang.io/): Write human-readable configuration and data files with schema tooling

## Is stash just a glorified `@ptrCast()`?

Kinda. [`@ptrCast()`](https://ziglang.org/documentation/0.16.0/#ptrCast), if you aren't familiar, tells the compiler to "interpret the bytes at address
0xX as my type `T`". This is of course very fast, and "hella zero copy"[^1]. But `@ptrCast()` does
not guarantee that the bytes in the buffer actually form a valid `T`.

Are there enough bytes to hold `T`? `@ptrCast()` is not aware of the buffer length. Is the address
aligned for the type? Good luck with the zero-copy reads, pal. Did your exhaustive enum get
corrupted on disk? Enjoy the UB! Compilers can add padding to structs (yes, `extern struct` too),
which makes it tedious to persist data reliably.

Stash aims to find the sweet spot of explicitness and performance to make these low-level headaches
more foolproof, letting you focus on data layouts and access patterns.

(But honestly, you should probably just use [rkyv](https://rkyv.org/))

---

[^1]: 'zero copy' seems to get more [qualifiers](https://rkyv.org/zero-copy-deserialization.html#total-zero-copy) over time
