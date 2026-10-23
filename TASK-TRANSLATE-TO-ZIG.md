# TASK: Translate `json-escape-simd` (Rust) → idiomatic Zig

**Blueprint for the implementing agent.** Target language: **Zig 0.16** (every snippet in this
document was compiled and tested with `zig 0.16.0` on linux-x86_64; cross-checked for
aarch64-linux, aarch64-macos, x86_64-windows, x86_64-baseline, riscv64-linux). Copy snippets
verbatim — they are known-good. Where a snippet is not given, follow the stated signature and
loop skeleton exactly.

Source of truth (Rust):

Rust code directory: ~/Sources/mine/json-escape-simd-x

| Rust file | Contents | → Zig |
|---|---|---|
| `src/lib.rs` | `QUOTE_TAB`, `NEED_ESCAPED`, dispatch, public API | `src/json_escape.zig` (Part 1, 5) |
| `src/simd/traits.rs`, `bits.rs` | `Simd`/`Mask`/`BitMask` traits | Part 2 (replaced by comptime generics) |
| `src/simd/{sse2,avx2,avx512,neon,v128}.rs` | 5 parallel backends | **ONE** generic pipeline, Part 2+4 |
| `src/simd/util.rs` | `escape_unchecked`, `check_cross_page` | Part 3 |
| inline `mod tests` in `src/lib.rs` | oracle + boundary tests | Part 6 |

**Deliverable:** a single-file Zig module `src/json_escape.zig` (+ minimal `build.zig`),
translating `escape`, `escape_unquote`, `escape_into`, `escape_into_unquote` into
`escape`, `escapeUnquote`, `escapeInto`, `escapeIntoUnquote`.

---

## 0. Ground rules — read before writing any code

### 0.1 Zig semantics that are NON-NEGOTIABLE

Zig is stricter than Rust. The implementing agent WILL hit these; handle them exactly as follows:

1. **No implicit integer casts, ever.** Any widening/narrowing between different integer types
   requires an explicit cast. Use `@intCast(x)` when the value provably fits (panics in safe
   modes if not), `@truncate(x)` for lossless low-bits narrowing, `@truncate` or `@intCast` for
   usize→u8 lane indices.
2. **Shift counts are not `usize`.** `a >> n` requires `n` to be the *shift type* of `a`
   (`@Log2Int`/`ShiftInt` of the operand). For a runtime `n: usize` write
   `a >> @intCast(n)` (when `n < @bitSizeOf(@TypeOf(a))`, asserted) or
   `a << @intCast(n)`. `std.math.maxInt(T)` returns `comptime_int`; you CANNOT shift a
   `comptime_int` by a runtime amount. Materialize first:
   ```zig
   const all_ones: T = std.math.maxInt(T);   // typed constant
   return m & (all_ones >> @intCast(n));    // OK
   ```
3. **`[*]T` is a many-item pointer, `*T` a single-item pointer.** They do not auto-convert.
   `ptr[i]` works on both; pointer arithmetic `ptr + n` works only on `[*]T`. To load one item
   through a `*T`, dereference: `ptr.*`.
4. **Taking a many-item pointer from an array:** `&arr` coerces to `[*]T`/`[*]const T` when the
   parameter type says so; from a slice use `slice.ptr` (type `[*]T`/`[*]const T`) or
   `@as([*]u8, @ptrCast(...))` when reinterpreting.
5. **Reinterpreting memory through a typed pointer is the Zig way to do unaligned vector
   loads/stores** (there is no `std::arch::x86::_mm256_loadu_si256`):
   ```zig
   // load LANES bytes, any alignment:
   const v = @as(*align(1) const @Vector(LANES, u8), @ptrCast(ptr)).*;
   // store LANES bytes, any alignment:
   @as(*align(1) @Vector(LANES, u8), @ptrCast(ptr)).* = v;
   ```
   The `align(1)` is mandatory — a bare `*` cast would inherit the vector type's natural
   alignment and UB on unaligned input.
6. **Slices with runtime length:** `[]const u8` (input), `[]u8` (output). Array-store through a
   many-item pointer: `dst[0..8].* = arr;` where `arr: [8]u8` (verified pattern, see Part 3).
   To take a many-item pointer from a slice: `slice.ptr`; from an array: `&arr` coerces when
   the parameter type is `[*]T`/`[*]const T`.
7. **Error unions only where allocation happens.** The escape kernels never fail; they return
   `usize` (bytes written) or `[*]u8` (advanced write pointer).
8. **Strings:** the Rust API takes `&str` (UTF-8). Zig has no `str` type; the algorithm is
   byte-oriented and UTF-8 passes through untouched, so the public API takes `[]const u8`.
   Do NOT validate UTF-8 — escaping preserves bytes.
9. **Comptime control flow:** `comptime` conditions use `if (comptime cond)` inside runtime
   functions; comptime table generation uses `blk: { ... break :blk value; }` with
   `@setEvalBranchQuota(N)`.
10. **`std.Target.current` does not exist** in 0.16. Use `@import("builtin")`: `.cpu`,
    `.target`, `.os.tag` (== `.builtin.os.tag`), `.mode`. See Part 1.

### 0.2 Why one generic pipeline replaces five Rust backends

Rust needs five parallel files because `std::arch` intrinsics are per-arch and `#[target_feature]`
is per-function. Zig's `@Vector(N, u8)` lowers to the best available register class for the
*compile target*: SSE2/NEON for 16 lanes, AVX2 for 32, AVX-512 for 64 — and on any target it
compiles whatever the target CPU supports. Therefore: **write `SimdVector(comptime LANES)`
once, instantiate it at 16/32/64.**

**Updated after measurement on Apple M1.** The original text here claimed `@bitCast` of a bool
vector emits the shift-and-narrow sequence on NEON, making `bits.rs::NeonBits` obsolete. That
is false for `<16 x i1> -> i16` as LLVM actually lowers it: for an OR of comparisons it emits
`and.16b / ext.16b / zip1.16b / addv.8h` (plus a constant load), 5 instructions and ~10 cycles,
versus Rust's single `shrn.8b`. That cost landed on every escape-path mask extraction and every
tail-loop iteration, and made the port 10-30% slower than the Rust crate on M1. The fix is
`EscapeMask(LANES)` (see 2.2): one-bit-per-lane masks everywhere except aarch64/16 lanes, where
the kernel-internal mask is the NEON nibble layout (4 bits per lane, extracted with `shrn`,
`firstOffset` = `@ctz >> 2`). The lane->bit contract of the public `escapedMask()` /
`bitmask()` API is unchanged; only the kernel's internal representation is arch-specialized.
Do not "simplify" this back to a single `@bitCast` mask.

### 0.3 File layout

```
jsonescape/
├── build.zig          # minimal: addModule + test step (see Part 6.3)
└── src/
    └── json_escape.zig  # everything; tests inline in `test` blocks
```

---

## Part 1: Architecture Detection, Constants & Comptime Tables

### 1.1 Architectural selection (LANES at compile time)

**Comptime tier.** Decide the *candidate* backend from `builtin.cpu` (which mirrors the
`-mcpu`/`-target` the user built for; native builds default to baseline):

```zig
const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum { sse2, neon, avx2, avx512, swar };

pub fn selectBackend() Backend {
    const cpu = builtin.cpu;
    return switch (cpu.arch) {
        .x86_64, .x86 => blk: {
            if (cpu.has(.x86, .avx512f)) break :blk .avx512;
            if (cpu.has(.x86, .avx2)) break :blk .avx2;
            if (cpu.has(.x86, .sse2)) break :blk .sse2;
            break :blk .swar;
        },
        .aarch64, .aarch64_be => blk: {
            if (cpu.has(.aarch64, .neon)) break :blk .neon;
            break :blk .swar;
        },
        else => .swar,
    };
}

pub const selected_backend = selectBackend();
```

Rules:
- The feature check is `cpu.has(.x86, .avx2)` — `Cpu.has(family, feature)`. Do NOT use
  `builtin.cpu.features.isEnabled(.avx2)` (takes a raw bit index; passing the enum tag gives a
  comptime error `type 'u9' has no members`). Do NOT use `std.Target.current` (doesn't exist).
- `.swar` is the only fallback tier. LANES per tier: `sse2`/`neon` → 16, `avx2` → 32,
  `avx512` → 64, `swar` → 64 (eight `u64` SWAR words, see Part 2.3).

**Runtime tier (x86 only).** A binary compiled for baseline x86_64 may run on a CPU with more
features, and one compiled with `-mcpu=native` may be copied to a lesser CPU. Mirror the Rust
runtime detection with raw CPUID (`std` has no public CPUID helper in 0.16):

```zig
fn cpuid(leaf: u32, subleaf: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile (
        \\cpuid
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn xgetbv(leaf: u32) u64 {
    var eax: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile (
        \\xgetbv
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [leaf] "{ecx}" (leaf),
    );
    return (@as(u64, edx) << 32) | @as(u64, eax);
}

fn runtimeSupports(comptime b: Backend) bool {
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => {},   // verification needed only on x86
        else => return true,   // NEON assumed per Rust logic; others → SWAR already comptime
    }
    switch (b) {
        .sse2 => return cpuid(1, 0).edx & (1 << 26) != 0,
        .avx2 => {
            const max_leaf = cpuid(0, 0).eax;
            if (max_leaf < 7) return false;
            const leaf1 = cpuid(1, 0);
            if ((leaf1.ecx & (1 << 27)) == 0) return false;      // OSXSAVE
            if ((xgetbv(0) & 0x06) != 0x06) return false;       // XMM+YMM state enabled
            return cpuid(7, 0).ebx & (1 << 5) != 0;             // AVX2
        },
        .avx512 => {
            if (!runtimeSupports(.avx2)) return false;
            if ((cpuid(7, 0).ebx & (1 << 16)) == 0) return false; // AVX512F
            return (xgetbv(0) & 0xE6) == 0xE6;                   // opmask/ZMM state enabled
        },
        else => return true,
    }
}
```

Dispatch state: a module-level `var` with a bool guard. **`std.once` does not exist in 0.16** —
do not use it:

```zig
var cached_backend: Backend = undefined;
var backend_detected: bool = false;

pub fn activeBackend() Backend {
    if (!backend_detected) {
        const b = comptime selected_backend;
        cached_backend = if (runtimeSupports(b)) b else .swar;
        backend_detected = true;
    }
    return cached_backend;
}
```

Mapping tier → vector type (put right after the wrappers from Part 2 exist):

```zig
pub fn VectorFor(comptime b: Backend) type {
    return switch (b) {
        .sse2, .neon => SimdVector(16),
        .avx2 => SimdVector(32),
        .avx512 => SimdVector(64),
        .swar => FallbackVector,
    };
}
```

Semantics: one binary contains the comptime-selected vector kernel plus the SWAR kernel; if the
CPU lacks the selected tier's instructions at runtime, everything routes to SWAR. (This is the
honest Zig equivalent of Rust's multi-backend runtime dispatch; compiling *multiple* vector
kernels into one binary requires separate `-mcpu` build steps and is out of scope.)

### 1.2 Exact types

| Concept | Zig type |
|---|---|
| input string | `[]const u8` |
| output buffer | `[]u8` (public API) / `[*]u8` (kernel write cursor) |
| read cursor | `[*]const u8` |
| remaining-bytes counter | `usize` |
| per-byte escape length | `u8` |
| escape payload | `[8]u8` (NUL-padded fixed-width, same as Rust) |
| table | `[256]EscapeEntry`, `[256]u8` |
| vector | `@Vector(LANES, u8)` |
| mask | `@Vector(LANES, bool)` |
| bitmask | `std.meta.Int(.unsigned, LANES)` → `u16`/`u32`/`u64` |

### 1.3 Comptime tables (`QUOTE_TAB`, `NEED_ESCAPED`)

Generate both at comptime — never hand-write 256 entries. This is the verified generator:

```zig
pub const EscapeEntry = struct { len: u8, bytes: [8]u8 };

fn pad8(comptime s: []const u8) [8]u8 {
    var out: [8]u8 = [_]u8{0} ** 8;
    for (s, 0..) |c, i| out[i] = c;
    return out;
}

pub const quoteTab: [256]EscapeEntry = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]EscapeEntry = undefined;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        t[i] = switch (c) {
            '"' => .{ .len = 2, .bytes = pad8("\\\"") },
            '\\' => .{ .len = 2, .bytes = pad8("\\\\") },
            0x08 => .{ .len = 2, .bytes = pad8("\\b") },
            0x09 => .{ .len = 2, .bytes = pad8("\\t") },
            0x0A => .{ .len = 2, .bytes = pad8("\\n") },
            0x0C => .{ .len = 2, .bytes = pad8("\\f") },
            0x0D => .{ .len = 2, .bytes = pad8("\\r") },
            else => blk2: {
                if (c < 0x20) {
                    var bytes = pad8("\\u00");
                    const digits = "0123456789abcdef";
                    bytes[4] = digits[c >> 4];
                    bytes[5] = digits[c & 0x0F];
                    break :blk2 .{ .len = 6, .bytes = bytes };
                }
                break :blk2 .{ .len = 0, .bytes = pad8("") };
            },
        };
    }
    break :blk t;
};

pub const needEscaped: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (0..256) |i| t[i] = @intFromBool(quoteTab[i].len != 0);
    break :blk t;
};
```

Rules:
- Escape set is EXACTLY: bytes `< 0x20` (`\u00XX`, or the 2-byte forms `\b \t \n \f \r`),
  `"` → `\"`, `\` → `\\`. Every other byte, including 0x20 and ≥ 0x7F, is copied verbatim.
- `bytes` is always 8 bytes, NUL-padded; `len` is the true output length (2 or 6, 0 = copy
  byte verbatim). Part 3 depends on the full-8-byte copy, do not "optimize" it to `len`.
- `needEscaped[i]` MUST equal `quoteTab[i].len != 0` — derive it, don't duplicate it.

### 1.4 Memory-safety notes for Part 1

- The tables are module-level `pub const` — comptime-evaluated, no runtime init cost.
- `pad8` uses `for (s, 0..)` over a comptime string; no bounds check needed because all
  payloads are ≤ 6 bytes.

---

## Part 2: `SimdVector(comptime LANES)` / `Mask(comptime LANES)` + SWAR fallback

Rust's `Simd`/`Mask`/`BitMask` trait stack becomes two comptime-generic structs. The mask
type is `@Vector(LANES, bool)` and the bitmask integer is
`std.meta.Int(.unsigned, LANES)` — which IS `u16` at 16 lanes, `u32` at 32, `u64` at 64, on
every architecture. That remains the public/test-facing contract (`Mask.bitmask`,
`SimdVector.escapedMask`); the kernels additionally use `EscapeMask`, the arch-specialized
packed form described in 0.2 and 2.2.

### 2.1 The generic vector (verified, copy verbatim)

```zig
pub fn Mask(comptime LANES: usize) type {
    return struct {
        const Self = @This();
        pub const lanes = LANES;
        data: @Vector(LANES, bool),

        pub inline fn orWith(self: Self, rhs: Self) Self {
            return .{ .data = self.data | rhs.data };
        }

        pub inline fn bitmask(self: Self) std.meta.Int(.unsigned, LANES) {
            return @bitCast(self.data);
        }
    };
}

pub fn SimdVector(comptime LANES: usize) type {
    return struct {
        const Self = @This();
        pub const lanes = LANES;
        pub const BitMask = std.meta.Int(.unsigned, LANES);

        data: @Vector(LANES, u8),

        pub inline fn loadu(ptr: [*]const u8) Self {
            return .{ .data = @as(*align(1) const @Vector(LANES, u8), @ptrCast(ptr)).* };
        }

        pub inline fn storeu(self: Self, ptr: [*]u8) void {
            @as(*align(1) @Vector(LANES, u8), @ptrCast(ptr)).* = self.data;
        }

        pub inline fn splat(x: u8) Self {
            return .{ .data = @splat(x) };
        }

        pub inline fn le(self: Self, rhs: Self) Mask(LANES) {
            return .{ .data = self.data <= rhs.data };
        }

        pub inline fn eq(self: Self, rhs: Self) Mask(LANES) {
            return .{ .data = self.data == rhs.data };
        }

        pub inline fn escapedMask(self: Self) BitMask {
            const ctl = Self.splat(0x1F);
            const bslash = Self.splat('\\');
            const quote = Self.splat('"');
            return self.le(ctl).orWith(self.eq(bslash)).orWith(self.eq(quote)).bitmask();
        }
    };
}
```

Rules:
- `escapedMask` = `(v <= 0x1F) | (v == '\\') | (v == '"')` — identical semantics to the Rust
  `escaped_mask` in every backend. Bit *i* of the result ⇔ byte *i* needs escaping.
- Comparisons on `@Vector` yield `@Vector(LANES, bool)` directly; `|` on bool vectors is
  lane-wise OR. No `BitAnd` impls needed — `and`-ing masks is never required by the algorithm.
- Keep every method `inline fn` (cheap single-use wrappers; lets LLVM fuse into the loops).
- Instantiations used by the library: `SimdVector(16)`, `SimdVector(32)`, `SimdVector(64)`.
  Nothing else needs to compile.

### 2.2 Bitmask helpers (verified)

```zig
inline fn firstOffset(m: anytype) usize {
    return @ctz(m);
}

inline fn clearHighBits(m: anytype, n: usize) @TypeOf(m) {
    const T = @TypeOf(m);
    const all_ones: T = std.math.maxInt(T);
    std.debug.assert(n < @bitSizeOf(T));
    return m & (all_ones >> @intCast(n));
}
```

- `@ctz` on the bitmask: bit 0 = lane 0 = first byte — matches Rust `first_offset()`
  (which is `trailing_zeros` on the little-endian view). `@bitCast` of a bool vector is
  defined in lane order on ALL targets and endiannesses, so no endian handling is needed here.
- `clearHighBits(m, k)` clears the top `k` bits — used ONLY in the tail loop as
  `clearHighBits(mask, LANES - nb)`. Precondition `LANES - nb >= 1` holds because the tail
  loop runs only while `nb < LANES` (see Part 4).
- `n` must be runtime-`usize`; the `all_ones` materialization + `@intCast` is the ONLY
  correct shift form (ground rule 0.1.2).

**Update: the helpers now live in `EscapeMask(LANES)`** (`firstOffset`, `isZero`, `orWith`,
`fromPredicate`). The free functions were removed so the kernel has exactly one mask
abstraction. The old `keepLanes(n)` helper (which replaced
`clearHighBits(mask, LANES - n)`) was removed with the masked-tail kernel: the tail loop now
reads the raw first offset on every backend (see 4.3).

### 2.3 Scalar fallback: `FallbackVector` (SWAR over `[8]u64`, LANES = 64) — verified

Pure u64 SWAR, no SIMD registers. Layout: one `FallbackVector` covers 64 bytes as **eight
little-endian-normalized `u64` words** (`words[0]` = bytes 0–7, `words[7]` = bytes 56–63).
Bitmask is `u64`, bit *i* ⇔ byte *i*, exactly like the 64-lane SIMD tier — so `formatRaw`
(Part 4) is byte-for-byte the same algorithm.

```zig
pub const FallbackVector = struct {
    pub const lanes = 64;
    pub const BitMask = u64;

    const native_endian = builtin.cpu.arch.endian();

    const M7F: u64 = 0x7F7F7F7F7F7F7F7F;
    const M80: u64 = 0x8080808080808080;
    const ME0: u64 = 0xE0E0E0E0E0E0E0E0;

    words: [8]u64,

    pub inline fn loadu(ptr: [*]const u8) FallbackVector {
        const p: [*]align(1) const u64 = @ptrCast(ptr);
        var w: [8]u64 = undefined;
        inline for (0..8) |i| {
            var x = p[i];
            if (comptime native_endian == .big) x = @byteSwap(x);
            w[i] = x;
        }
        return .{ .words = w };
    }

    pub inline fn storeu(self: FallbackVector, ptr: [*]u8) void {
        const p: [*]align(1) u64 = @ptrCast(ptr);
        inline for (0..8) |i| {
            var w = self.words[i];
            if (comptime native_endian == .big) w = @byteSwap(w);
            p[i] = w;
        }
    }

    inline fn zeroFlags(x: u64) u64 {
        // per-byte: high bit set iff that byte == 0x00 (no cross-byte carries)
        return ~(((x & M7F) +% M7F) | x) & M80;
    }

    inline fn broadcast(c: u8) u64 {
        return @as(u64, c) *% 0x0101010101010101;
    }

    pub inline fn escapedMask(self: FallbackVector) u64 {
        var bm: u64 = 0;
        inline for (0..8) |wi| {
            const w = self.words[wi];
            // escaped ⇔ (b <= 0x1F) or (b == '\\') or (b == '"')
            const f = zeroFlags(w & ME0)              // (b & 0xE0) == 0  ⇔ b <= 0x1F
                | zeroFlags(w ^ broadcast('\\'))
                | zeroFlags(w ^ broadcast('"'));
            inline for (0..8) |bi| {
                const bit = (f >> @intCast(8 * bi + 7)) & 1;
                bm |= bit << @intCast(8 * wi + bi);
            }
        }
        return bm;
    }
};
```

Rules / derivations (so the implementing agent doesn't "simplify" them wrongly):
- `zeroFlags` detects zero bytes: `(x & 0x7F) +% 0x7F` sets the high bit iff the low 7 bits
  are non-zero; `| x` also propagates a set high bit; invert and mask → high bit set ⇔ byte
  == 0. `+%`/`*%` are wrapping ops (Zig errors on potential overflow with `+`/`*`).
- `w & ME0` zeroes every byte whose value is ≥ 0x20, so `zeroFlags(w & ME0)` flags bytes
  ≤ 0x1F — this is `le(splat(0x1F))`. It works because 0x1F, '\\', '"' all have their high
  bit clear, which is why `ME0 = 0xE0` (three top bits) is sufficient masking.
- XOR + zero-detect is `eq`. `broadcast` uses wrapping multiply.
- The `inline for` bit-extraction copies each byte's high bit into lane position — keep the
  `@intCast`s; all shift counts are comptime-derived but must still be cast to the shift type.
- The comptime `@byteSwap` normalizes big-endian hosts to little-endian word layout so the
  bit-extraction mapping stays lane-ordered. On LE hosts the swap compiles out.
- `FallbackVector` must expose the same surface used by `formatRaw`: `lanes`, `BitMask`,
  `loadu`, `storeu`, `escapedMask`. It has no `splat`/`le`/`eq` — `formatRaw` must not use
  them (it never does; it only uses the five members listed).

### 2.4 What NOT to port

- `bits.rs::NeonBits` — folded into `EscapeMask` as the aarch64/16-lane case (see 0.2). Do
  not reintroduce it as a separate type or as the public bitmask type.
- `BitOrAssign`/`BitAnd` trait impls — the algorithm needs only `|` on masks, which Zig
  gives natively on bool vectors.
- `#[repr(transparent)]` newtypes — unnecessary; Zig struct-of-one-vector is already
  transparent to LLVM after inlining.

---

## Part 3: `escapeUnchecked` — slow-path helper

Rust signature: `unsafe fn escape_unchecked(src: &mut *const u8, nb: &mut usize, dst: &mut *mut u8)`.
Zig has no `&mut *T`; the mutable-pointer parameters become pointers to many-item pointers:
`dst: *[*]u8`, `src: *[*]const u8`, `nb: *[*]u8`. Mutation through them: `src.* += 1;`.

**Verified translation — copy verbatim:**

```zig
inline fn escapeUnchecked(src: *[*]const u8, nb: *usize, dst: *[*]u8) void {
    std.debug.assert(nb.* >= 1);
    while (true) {
        const ch = src.*[0];
        const entry = quoteTab[ch];
        std.debug.assert(entry.len != 0);
        dst[0..8].* = entry.bytes;
        dst.* += entry.len;
        src.* += 1;
        nb.* -= 1;
        if (nb.* == 0 or needEscaped[src.*[0]] == 0) return;
    }
}
```

Semantics (must match Rust exactly):
- The caller has just located a byte that needs escaping; consume the run of consecutive
  escapable bytes one at a time.
- For each byte: copy the **full 8-byte** `entry.bytes` through `dst` (this is the capacity
  contract in Part 5 — never trim to `len`), advance `dst` by the *true* `entry.len` (2 or 6),
  advance `src` by 1, decrement `nb`.
- Loop guard mirrors Rust exactly: stop when `nb == 0` OR the *next* byte needs no escape.
  Order matters — `nb.* == 0` must be checked first: reading `src.*[0]` is only in-bounds
  while `nb.* > 0` (and even then the final read may be at the last byte — `src.*[0]` after
  `nb.* -= 1` reads one-past-end when the run reaches the buffer end; see safety note).
- `dst[0..8].* = entry.bytes;` is the array-store-through-many-item-pointer form.
- `std.debug.assert(entry.len != 0)` documents the precondition (caller only invokes on an
  escapable byte); it compiles out in ReleaseFast/ReleaseSmall.

Safety note for the implementing agent: after processing the final byte of the input,
`src.*` points one past the buffer and the guard reads `src.*[0]` when `nb.* != 0` is false —
re-check the guard: Rust reads `NEED_ESCAPED[*(*src)]` only when `*nb != 0`; the Zig
`or` short-circuits identically, so the one-past-end byte is never dereferenced. Keep the
`nb.* == 0 or` term FIRST. Do not "clean this up" to index into the slice — this function
must stay pointer-based (Part 4 passes interior cursors).

---

## Part 4: `formatRaw` — the main loop structure

One generic function parameterized by the vector type. Rust has three loop tiers
(CHUNK fast path → LANES loop → tail) — and all five Rust backends including SSE2/NEON use
all three — but in Zig the GENERIC function keeps all three tiers for every LANES (at LANES=16,
CHUNK=64 ≥ 16 so the tier is still profitable and the tests verify correctness). Signature:

```zig
pub fn formatRaw(comptime Vec: type, value: []const u8, dst: [*]u8) [*]u8
```

with `const LANES = Vec.lanes;` and `const CHUNK = LANES * 4;`. `Vec` is any of
`SimdVector(16)`, `SimdVector(32)`, `SimdVector(64)`, `FallbackVector` — same five members
(see 2.3). State: `sptr: [*]const u8 = value.ptr;`, `dptr: [*]u8 = dst;`,
`nb: usize = value.len;`. Return `dptr` (advanced).

### 4.1 Tier 1 — CHUNK loop (`while (nb >= CHUNK)`)

Load 4 vectors at `sptr`, `sptr + LANES`, `sptr + 2*LANES`, `sptr + 3*LANES`; compute the four
escaped predicates. Fast path: if they are all empty, store the 4 vectors to `dptr + i*LANES`
and advance both cursors by CHUNK, decrement `nb` by CHUNK.

**Update:** the masks are no longer combined as integers in the source. `Vec.hotMask4(v1, v2,
v3, v4)` ORs the four predicates in the vector domain and extracts once (`shrn` on NEON,
`vpmovmskb` on x86) — combining the already-extracted integers forces four extractions on
NEON. The slow path then re-extracts each vector's mask lazily with `v.hotMask()`.

Slow path — process each vector in order; this is the verified structure using a labeled
`continue` with `inline for` over tuples (replaces the four copy-pasted Rust blocks):

```zig
        } else {
            inline for (.{ v1, v2, v3, v4 }) |v| {
                v.storeu(dptr);
                const m = v.hotMask();
                if (!m.isZero()) {
                    const cn = m.firstOffset();
                    nb -= cn;
                    dptr += cn;
                    sptr += cn;
                    escapeUnchecked(&sptr, &nb, &dptr);
                    continue :chunk;
                }
                nb -= LANES;
                dptr += LANES;
                sptr += LANES;
            }
        }
```

with the loop written as `chunk: while (nb >= CHUNK) { ... }`. Per-vector semantics: store
the raw vector first (bytes before the first escape are already written), then if the mask is
non-zero advance both cursors by the first-escape offset `cn`, run `escapeUnchecked`, and jump
back to the CHUNK test (`continue :chunk`); else advance by a full LANES and fall through to
the next vector. The `inline for` over two parallel tuples is the idiomatic single source of
truth — keep exactly 4 elements.

### 4.2 Tier 2 — LANES loop (`while (nb >= LANES)`)

Single vector per iteration:

```zig
    while (nb >= LANES) {
        const v = Vec.loadu(sptr);
        v.storeu(dptr);
        const m = v.escapedMask();
        if (m == 0) {
            nb -= LANES;
            dptr += LANES;
            sptr += LANES;
        } else {
            const cn = firstOffset(m);
            nb -= cn;
            dptr += cn;
            sptr += cn;
            escapeUnchecked(&sptr, &nb, &dptr);
        }
    }
```

### 4.3 Tier 3 — tail loop (`while (nb > 0)`), page-cross & build-mode matrix

Remaining `nb` is in `1..LANES`. A full-LANES load would over-read up to `LANES-1` bytes past
the input; Rust guards this per-OS/build-mode. Translate with a comptime constant and a
runtime page check:

```zig
    var placeholder: [LANES]u8 = [_]u8{0} ** LANES;
    const direct_tail_load = comptime (builtin.os.tag == .linux or builtin.os.tag == .macos)
        and (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall);

    tail: while (nb > 0) {
        const v = if (direct_tail_load and !checkCrossPage(sptr, LANES))
            Vec.loadu(sptr)
        else
            blk: {
                @memcpy(placeholder[0..nb], sptr[0..nb]);
                break :blk Vec.loadu(&placeholder);
            };

        v.storeu(dptr);
        const m = clearHighBits(v.escapedMask(), LANES - nb);
        if (m == 0) {
            dptr += nb;
            break :tail;
        } else {
            const cn = firstOffset(m);
            nb -= cn;
            dptr += cn;
            sptr += cn;
            escapeUnchecked(&sptr, &nb, &dptr);
        }
    }
    return dptr;
```

**Update (Apple Silicon, measured).** The loop above is the historical shape. The current
kernel declares `placeholder` as `undefined` (Debug/ReleaseSafe fill exactly `nb` bytes before
the load; lanes above `nb` are never trusted) and reads the raw mask:

```zig
        v.storeu(dptr);
        const cn = v.hotMask().firstOffset();
        if (cn >= nb) {
            dptr += nb;
            break :tail;
        }
        nb -= cn;
        dptr += cn;
        sptr += cn;
        escapeUnchecked(&sptr, &nb, &dptr);
```

Why: `@ctz` already returns `LANES` for an empty mask, and over-read lanes can only move the
first escape at or beyond `nb`, so comparing the first offset against `nb` is enough on every
backend. Clearing the over-read lanes first only measured faster on one large-string
workload, not enough to keep a second kernel.

The exact cfg matrix (translating `#[cfg(...)]` in `avx2.rs:245-268`):

| Condition (comptime or runtime) | Load source |
|---|---|
| OS not linux/macos (e.g. windows) | always placeholder copy (`@memcpy` `nb` bytes, load placeholder) |
| linux/macos, would cross 4096-byte page | placeholder copy |
| linux/macos, same page, Debug/ReleaseSafe | placeholder copy |
| linux/macos, same page, ReleaseFast/ReleaseSmall | direct over-read `Vec.loadu(sptr)` |

`direct_tail_load` is the comptime fold of the last two rows plus the OS gate; `checkCrossPage`
is the runtime row. Page check (port of `util.rs::check_cross_page`):

```zig
inline fn checkCrossPage(ptr: [*]const u8, step: usize) bool {
    const page: usize = 4096;
    return (@intFromPtr(ptr) & (page - 1)) + step > page;
}
```

`@intFromPtr` (not `@ptrToInt` — removed in 0.16) converts to `usize` for the arithmetic.

Tail-loop invariants to preserve verbatim:
- Store the full vector even though only `nb` bytes are meaningful — the capacity contract
  (Part 5) guarantees `LANES` writable bytes at `dptr`. Lanes at index >= `nb` must never
  trigger an escape: reject a first offset >= `nb`.
- No escape in the valid range → advance `dptr += nb` (not LANES!) and `break :tail`.
- Otherwise `cn` from the mask, advance by `cn`, `escapeUnchecked`, loop. The loop
  re-runs only while `nb > 0`; `escapeUnchecked` can bring `nb` to 0, ending the loop.
- The placeholder is declared OUTSIDE the loop (reused). The `direct_tail_load` branch never
  reads it; the copy branch fills exactly `nb` bytes, so `undefined` init is safe as long as
  lanes above `nb` stay untrusted.

### 4.4 `formatString` / `formatUnquoted` wrappers

```zig
pub fn formatString(comptime Vec: type, value: []const u8, dst: [*]u8) [*]u8 {
    dst[0] = '"';
    dst += 1;
    var end = formatRaw(Vec, value, dptr);
    end[0] = '"';
    end += 1;
    return end;
}

pub fn formatUnquoted(comptime Vec: type, value: []const u8, dst: [*]u8) [*]u8 {
    return formatRaw(Vec, value, dst);
}
```

(`formatString` = quotes; `formatUnquoted` = no quotes; both return bytes written.)

---

## Part 5: Public API — and the `escape_into` contract (IMPORTANT)

### 5.1 The Rust `escape_into` is a bluff — translate the *real* semantics

Rust's `escape_into(value, dst: &mut Vec<u8>)` claims Vec semantics but actually:

```rust
let spare = std::slice::from_raw_parts_mut(dst.as_mut_ptr().add(old_len), dst.capacity() - old_len);
let cnt = format_string(value, spare);
dst.set_len(old_len + cnt);
```

It writes straight into the Vec's spare capacity with **no runtime checks** — an undersized
buffer is silent memory unsafety, and the doc's "Panics" claim is false.

**Zig translation decision (required):** take a plain output slice and put the burden on the
caller, stated loudly in the doc comment. Do NOT replicate Vec-style auto-reservation, do NOT
replicate a `*std.ArrayList(u8)`, and do NOT add release-mode runtime checks. Return the
number of bytes written so the caller can re-slice.

```zig
/// Escape `value` into `dst` as a quoted JSON string.
/// Returns a pointer to the first byte after the last written element.
///
/// CALLER RESPONSIBILITY: `dst.len >= value.len * 6 + 64`.
pub fn escapeInto(dst: [*]u8, value: []const u8) [*]u8 {
    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (dst.len < value.len * 6 + 64) @panic("destination buffer too small");
    }
    
    return switch (activeBackend()) {   
        inline else => |b| formatString(VectorFor(b), value, dst.ptr),
    };
}

/// Like `escapeInto` but without the surrounding quotes. Worst case `6 * value.len` bytes;
/// the same `value.len * 6 + 64` capacity rule applies.
pub fn escapeIntoUnquote(dst: [*]u8, value: []const u8) [*]u8 {
    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (dst.len < value.len * 6 + 64) @panic("destination buffer too small");
    }

    return switch (activeBackend()) {
        inline else => |b| formatString(VectorFor(b), value, dst.ptr),
    };
}
```

Rules:
- The `switch (activeBackend()) { inline else => |b| ... }` is the comptime dispatch — every
  arm instantiates its kernel; exactly one runs at runtime.
- Doc comment MUST carry the warning above (adapt the wording, keep the `len * 6 + 64` number
  and the reason). This is the whole point of not replicating the Vec bluff.
- Optional (implementer's choice, NOT required): in Debug/ReleaseSafe only, a
  `if (dst.len < value.len * 6 + 64) @panic(...)` guard before dispatch. If added, it must
  be comptime-gated on `builtin.mode == .Debug or builtin.mode == .ReleaseSafe` so
  ReleaseFast keeps zero overhead.

### 5.2 Allocating convenience functions

```zig
pub fn escape(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    const cap = value.len * 6 + 64;
    const buf = try allocator.alloc(u8, cap);
    const cnt = escapeInto(value, buf);
    if (cnt == cap) return buf;
    const shrunk = allocator.realloc(buf, cnt) catch |err| {
        allocator.free(buf);
        return err;
    };
    return shrunk;
}
```

`escapeUnquote` is identical with `escapeIntoUnquote`. Rules:
- Allocate `len * 6 + 64` (mirrors Rust's `len * 6 + 64` reserve), write, then shrink with
  `allocator.realloc` — Zig cannot "set_len" a longer allocation into a shorter slice.
- If `realloc` fails, free the original and propagate the error (never return an
  over-allocated buffer silently — the shrink failure path is the only allocation error).
- Return type `Allocator.Error![]u8` — these are the ONLY fallible public functions.
- Output is ASCII-safe JSON but the input is not validated as UTF-8 (see 0.1.8); document
  "bytes in, escaped bytes out".

---

## Part 6: Tests & verification gates

### 6.1 Oracle

Port the scalar reference (replaces `serde_json::to_string` as oracle — Zig std has no JSON
string escaper):

```zig
fn referenceEscape(value: []const u8, quoted: bool, out: []u8) usize {
    var i: usize = 0;
    if (quoted) { out[i] = '"'; i += 1; }
    for (value) |c| {
        const e = quoteTab[c];
        if (e.len == 0) { out[i] = c; i += 1; }
        else { @memcpy(out[i..][0..8], &e.bytes); i += e.len; }
    }
    if (quoted) { out[i] = '"'; i += 1; }
    return i;
}
```

### 6.2 Required test set (each must exercise ALL backends explicitly)

Instantiate `const all_backends = .{ SimdVector(16), SimdVector(32), SimdVector(64), FallbackVector };`
and `inline for (all_backends) |Vec|` — do NOT only test the dispatched path (the host CPU
won't exercise AVX-512 otherwise). Required cases (ports of `src/lib.rs` tests):

1. **Tables hand-checked:** `quoteTab['"'].len == 2` with bytes `[0..6]` equal to
   `{ '\', '"', 0, 0, 0, 0 }`; same shape checks for `\`, `\b`, `\t`, `\n`, `\f`, `\r`,
   `\u0000`, `\u001f`, plus `needEscaped[i] == (i < 0x20 or i == '"' or i == '\\')` for all 256.
   (NUL padding counts: the `"` entry stores `5C 22 00 00 00 00 00 00`.)
2. **Bitmask type identity:** `SimdVector(16).BitMask == u16`, `SimdVector(32).BitMask == u32`,
   `SimdVector(64).BitMask == u64`, `FallbackVector.BitMask == u64`.
3. **escapedMask lane order:** buffer of `'a'`s with escapes planted at bytes 0, 15, 31, 63;
   assert the exact integer bitmasks for 16/32/64 and assert SWAR's mask equals the 64-lane
   vector mask (they must agree bit-for-bit).
4. **Sizes 0..=300**, random bytes (xorshift PRNG, e.g. the 3-shift xorshift64 with a
   per-length seed), compared against `referenceEscape` for both quoted and unquoted, all
   backends. This covers every boundary (15/16, 31/32, 63/64, 127/128, 255/256, 299/300).
5. **Special fixtures:** empty string, `"`, `\`, `"\"`, the ASCII sentence, a multi-byte UTF-8
   + CJK + emoji string, all 32 control bytes, all 256 byte values, 200×NUL, 129×`"`, 130×`\`.
6. **Unaligned starts:** one 400-byte buffer with mixed escapes, escape 300-byte windows at
   start offsets 0..=32 (all backends).
7. **Dispatched API:** `escapeInto`/`escapeUnquote`/`escape`/`escapeUnquote` against the
   oracle; use `std.testing.allocator` for the allocating ones (leak-check comes free).
8. **`activeBackend()` sanity:** returns some `Backend` (and on x86_64/avx2 hosts, expect
   `.avx2` when `-mcpu=native`).

Stack buffers of `[4200]u8` suffice for cases 4–7 (300×6+2 max).

### 6.3 Verification commands (run ALL; these are the acceptance gates)

```sh
zig test src/json_escape.zig                       # Debug
zig test src/json_escape.zig -O ReleaseSafe
zig test src/json_escape.zig -O ReleaseFast
zig test src/json_escape.zig -target aarch64-linux --test-no-exec
zig test src/json_escape.zig -target aarch64-macos -mcpu=apple_m1 --test-no-exec
zig test src/json_escape.zig -target x86_64-linux -mcpu=baseline --test-no-exec
zig test src/json_escape.zig -target x86_64-windows --test-no-exec
zig test src/json_escape.zig -target riscv64-linux --test-no-exec   # SWAR-only tier
```

#### User input.

- You can test Neon with my machine on Apple Silicon which you can access via `ssh homembp`.
- You can test AVX512 via the Intel SDE (software development emulator):
  ```shell
  sde -icl -- ./path/to/test/binary # Will run Ice Lake emulator.
  ```

`build.zig` (minimal, 0.16 style):

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("json_escape", .{
        .root_source_file = b.path("src/json_escape.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = mod;

    const tests = b.addTest(.{
        .root_source_file = b.path("src/json_escape.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
```

### 6.4 Memory-model notes (summary of all safety constraints)

- Over-read (input side): only in the tail tier under the exact matrix in 4.3; bounded by
  `LANES - 1` bytes; gated on same-page + release mode. Windows/Debug always placeholder.
- Over-write (output side): never past `value.len * 6 + 64` from the write cursor; bounded by
  the capacity contract in 5.1. This mirrors the Rust design (tight `6*len+2` bound is NOT
  safe due to the 8-byte table copies — Rust ASAN-verified, keep the +64).
- `escapeUnchecked` reads `src.*[0]` only while `nb.* > 0` (guard-order in Part 3).
- No alignment requirements anywhere: every load/store is `align(1)` or `@memcpy`.

---

## Execution order (implement Part by Part; gate each step)

1. Create `src/json_escape.zig` with Part 1 (tables + backend detection). Gate: write test
   6.2.1 and run `zig test` — tables must pass before anything else exists.
2. Add Part 2 wrappers (`Mask`, `SimdVector`, `FallbackVector`, helpers). Gate: tests 6.2.2
   and 6.2.3 pass.
3. Add Part 3 `escapeUnchecked` (needs `quoteTab`/`needEscaped` only). Gate: compiles
   (`zig build test` or `zig test`).
4. Add Part 4 `formatRaw` + wrappers. Gate: tests 6.2.4–6.2.6 pass in Debug.
5. Add Part 5 public API + dispatch. Gate: tests 6.2.7–6.2.8 pass; full command matrix 6.3
   green.
6. Final review checklist: every `inline fn` kept inline; no `std.once`; no
   `features.isEnabled` with enum tags; every runtime shift uses the `all_ones` +
   `@intCast` pattern; `escapeInto` doc warning present; no runtime bounds checks in
   release modes.
   The `escapeInto` better be something like
   ```zig
   fn espaceInto(dst: [*]u8, value: []const u8) [*]u8 {}
   ```
   And the return pointer must point to the first element after the last written escape.

Deviations from this blueprint require justification in the PR description; when in doubt,
prefer the verbatim snippets — they are tested, the prose is commentary.


  