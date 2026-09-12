# json_escape public API

`json_escape` is a single-module Zig 0.16 library (`build.zig` declares an
`addModule("json_escape", ...)` rooted at `src/json_escape.zig`). Import it as:

```zig
const json_escape = @import("json_escape");
```

It produces JSON escaped bytes: bytes `< 0x20` become `\u00xx` (or the short forms
`\b \t \n \f \r`), `"` becomes `\"`, and `\` becomes `\\`. Every other byte, including
`0x20` and all bytes `>= 0x7F`, is copied verbatim. Input is `[]const u8` and is never
UTF-8 validated; invalid UTF-8 passes through unchanged.

Internal development guidance (toolchain, architecture, testing) lives in
`AGENTS-DEV.md`.

## Intended consumer API

Only the `escape*` family is meant for callers. Everything else marked `pub` is exposed
for tests and custom kernels (see "Exposed internals" below).

| Function | Output | Fallible | Buffer |
|---|---|---|---|
| `escape(allocator, value) ![]u8` | quoted | yes | allocates |
| `escapeUnquote(allocator, value) ![]u8` | unquoted | yes | allocates |
| `escapeInto(dst: [*]u8, value) [*]u8` | quoted | no | caller |
| `escapeIntoUnquote(dst: [*]u8, value) [*]u8` | unquoted | no | caller |
| `escapeIntoSlice(dst: []u8, value) []u8` | quoted | no | caller |
| `escapeIntoUnquoteSlice(dst: []u8, value) []u8` | unquoted | no | caller |

Quoted output includes the surrounding `"` characters; unquoted output is the escaped
payload only. Both forms are returned as exactly the written bytes (the `*Slice` and
allocator variants) or as a cursor (the raw `[*]u8` variants).

## Usage examples

Allocating, the simplest entry point:

```zig
const std = @import("std");
const json_escape = @import("json_escape");

const allocator = std.heap.page_allocator;
const escaped = try json_escape.escape(allocator, "tab\there\n");
defer allocator.free(escaped);
// escaped == "\"tab\\there\\n\"" (including the surrounding quotes)
```

Caller-provided buffer, slice API:

```zig
var buf: [128]u8 = undefined;
const out = json_escape.escapeIntoSlice(&buf, "tab\there\n");
// out is buf[0..n], exactly the written bytes; out == "\"tab\\there\\n\""

const raw = json_escape.escapeIntoUnquoteSlice(&buf, "a\nb");
// raw == "a\\nb" (no surrounding quotes)
```

Raw cursor API, when the written length is tracked manually:

```zig
var buf: [128]u8 = undefined;
const end = json_escape.escapeInto(&buf, "a\nb");
const written = buf[0 .. @intFromPtr(end) - @intFromPtr(&buf)];
// written == "\"a\\nb\""
```

## Gotchas

- **Destination capacity is `value.len * 6 + 64`, always.** `6 * value.len + 2` is the
  logical worst case; the extra 64 bytes absorb full-width vector stores and the fixed
  8-byte escape-table copies that write past the logical end. Do not pass a tighter
  buffer, and do not "optimize" this bound. There are no bounds checks in the raw
  `[*]u8` functions.
- `escapeInto*Slice` panics with "destination buffer too small" only in **Debug and
  ReleaseSafe**. The check is comptime-eliminated in ReleaseFast/ReleaseSmall, where an
  undersized buffer is undefined behavior.
- `escapeInto` / `escapeIntoUnquote` return a pointer to the **first byte after** the
  last written byte, not a length. Convert with
  `buf[0..@intFromPtr(end) - @intFromPtr(buf.ptr)]`. They never fail.
- `escape` / `escapeUnquote` are the only fallible functions
  (`std.mem.Allocator.Error![]u8`). They allocate `6*len+64` and `realloc` down to the
  written length; on shrink failure they free the buffer and return the error. Free the
  result with the same allocator.
- Empty input yields a 2-byte quoted result (`""`) or a 0-byte unquoted result.
- The allocator variants take `(allocator, value)` in that order.

## Exposed internals

These are `pub` so tests and custom kernels can use them; treat them as unstable.

- `Backend` (`sse2`, `neon`, `avx2`, `avx512`, `swar`), `selectBackend()` (comptime
  candidate from `builtin.cpu`), `selected_backend`, and `activeBackend()` (cached
  runtime CPUID check that may downgrade to `.swar`).
- `VectorFor(backend)` maps a backend to its vector type; `Mask(LANES)`,
  `SimdVector(LANES)`, and `FallbackVector` are the backend implementations, each
  offering `loadu`, `storeu`, and `escapedMask`.
- `EscapeEntry`, `quoteTab: [256]EscapeEntry`, and `needEscaped: [256]u8`.
- `formatRaw(Vec, value, dst)`, `formatString(Vec, value, dst)`, and
  `formatUnquoted(Vec, value, dst)` are the per-backend kernels behind the dispatched
  API; they share the same `6*len+64` capacity contract.
