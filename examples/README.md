# Examples

Run an example from the repository root using its two-digit number:

```sh
zig build example_03
```

Start with [01_stash_values_and_slices.zig](01_stash_values_and_slices.zig) for the basic write/read workflow,
then pick the example closest to your data:

| Example | What to look for |
| --- | --- |
| [01_stash_values_and_slices.zig](01_stash_values_and_slices.zig) | Define a format, write values and slices, and access the stored data |
| [02_save_and_load_a_file.zig](02_save_and_load_a_file.zig) | Save data to a file and load it using the same format |
| [03_stash_a_struct.zig](03_stash_a_struct.zig) | Define a stored struct with an explicit layout and read its fields through a pointer |
| [04_stash_a_slice_of_structs.zig](04_stash_a_slice_of_structs.zig) | Change a stored record while leaving the original input unchanged |
| [05_stash_strings.zig](05_stash_strings.zig) | Read strings of different lengths, including an empty string |
| [06_stash_structs_as_columns.zig](06_stash_structs_as_columns.zig) | Process one field across all rows through a contiguous column |
| [07_pack_small_values.zig](07_pack_small_values.zig) | Use named bitfields and a packed sequence of two-bit states |
| [08_inspect_a_layout.zig](08_inspect_a_layout.zig) | Inspect a schema and see where data, metadata, and padding sit in a buffer |
| [09_build_data_in_place.zig](09_build_data_in_place.zig) | Generate a lookup table directly in the output buffer without a temporary input slice |
| [10_fit_records_into_a_page.zig](10_fit_records_into_a_page.zig) | Measure how many records fit in a page and write the accepted records |

## Representing types that cannot be stored directly

These examples choose an explicit stored representation for an application type.
Stash validates the stored types. Your application checks relationships such as whether an index
refers to an existing record.

| Example | What to look for |
| --- | --- |
| [11_stash_optional_values.zig](11_stash_optional_values.zig) | Distinguish an absent value from zero with an explicit presence flag |
| [12_stash_tagged_unions.zig](12_stash_tagged_unions.zig) | Store a numbered tag and initialized fields for each alternative |
| [13_stash_references.zig](13_stash_references.zig) | Replace pointers with record indices and check them before use |
| [14_stash_error_results.zig](14_stash_error_results.zig) | Map errors to stable status numbers and back to a Zig error union |
| [15_stash_vectors.zig](15_stash_vectors.zig) | Store arrays and load them into vectors for arithmetic |
| [16_stash_structs_with_padding.zig](16_stash_structs_with_padding.zig) | Initialize explicit padding and convert an application limit to a fixed-width integer |
| [17_stash_null_terminated_strings.zig](17_stash_null_terminated_strings.zig) | Store a terminator explicitly and validate it before creating a sentinel slice |

## Inspecting a format

[08_inspect_a_layout.zig](08_inspect_a_layout.zig) prints the schema with `printSchema()` and a buffer’s
layout with `printBufferLayout()`. Both print to stderr, separating data from stash metadata without
printing stored values. Use `describe(writer)` or `inspect(buffer, writer)` to send output elsewhere.

The file example writes to `.zig-cache`. The other examples work entirely in memory.
Examples use checked views when opening stored data. Example 09 creates a mutable view with `initialize()`.
Mutable views change the bytes in memory and preserve the stored shape.
Writing those changes to disk remains the application's responsibility.

Run every example with:

```sh
zig build examples
```

`zig build check` compiles the examples, and `zig build test` also runs them.
