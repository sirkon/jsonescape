# AGENTS.md

SIMD-accelerated JSON string escaping, translated from the Rust `json-escape-simd` crate
into a single Zig module.

## Toolchain

- **Zig 0.17.0** is required (`build.zig.zon` sets `minimum_zig_version = "0.17.0"`; the
  installed `zig` is 0.17.0). Many APIs used here differ from older Zig the model may have
  seen: `std.once` does not exist, `std.Target.current` does not exist, and
  `Cpu.features.isEnabled(.enum_tag)` is wrong (use `cpu.has(.x86, .avx2)`).

## Commands

```sh
zig build test                      # primary gate: build + run tests (Debug)
zig fmt src/json_escape.zig         # formatting

# Full verification matrix from TASK-TRANSLATE-TO-ZIG.md section 6.3.
# --test-no-exec cross-compiles the test binary without running it.
zig test src/json_escape.zig
zig test src/json_escape.zig -O ReleaseSafe
zig test src/json_escape.zig -O ReleaseFast
zig test src/json_escape.zig -target aarch64-linux --test-no-exec
zig test src/json_escape.zig -target aarch64-macos -mcpu=apple_m1 --test-no-exec
zig test src/json_escape.zig -target x86_64-linux -mcpu=baseline --test-no-exec
zig test src/json_escape.zig -target x86_64-windows --test-no-exec
zig test src/json_escape.zig -target riscv64-linux --test-no-exec   # SWAR-only tier
```

The tail-loop safety logic branches on `builtin.os.tag` and `builtin.mode`, so the same
source must compile and pass under **all three optimization modes and every target above**.
A change that only passes Debug or only the host is not done.

Hardware access for verification (from the blueprint): Neon on Apple Silicon via
`ssh homembp`; AVX-512 via the Intel SDE (`sde -icl -- ./test/binary`).

## Layout

```
build.zig            addModule("json_escape") + test step
build.zig.zon        package manifest (name, minimum Zig version, fingerprint)
src/json_escape.zig  everything: backend detection, tables, kernels, public API, tests
TASK-TRANSLATE-TO-ZIG.md  the original translation blueprint (spec of record)
```

The Rust source of truth lives outside this repo at `~/Sources/mine/json-escape-simd-x`.
`TASK-TRANSLATE-TO-ZIG.md` contains verified, known-good snippets; prefer them verbatim
when extending the translation. Deviations require justification.

## Architecture

Control flow: public API -> `activeBackend()` runtime dispatch -> `VectorFor(backend)` ->
`formatRaw` generic kernel -> per-backend vector type.

- `selectBackend()` picks a **comptime candidate** from `builtin.cpu`.
- `activeBackend()` caches a **runtime** CPUID/XGETBV check (x86 only) that may downgrade the
  candidate to `.swar`. State is a module-level `var` + bool guard, not `std.once`.
- The four tiers map to LANES: `sse2`/`neon` -> 16, `avx2` -> 32, `avx512` -> 64,
  `swar` -> `FallbackVector` (64 bytes as eight `u64` SWAR words).
- `formatRaw` has three tiers: a 4x-wide `CHUNK` loop, a single-vector loop, and a scalar
  tail. Only the tail may over-read, and only under a strict gate (linux/macos +
  ReleaseFast/ReleaseSmall + same 4 KiB page). See section 4.3 of the blueprint.
- Rust needed five per-arch backends because of `#[target_feature]`; Zig's
  `@Vector(N, u8)` lowers per compile target instead, so there is exactly one generic
  pipeline. Do not recreate the per-arch files or the `NeonBits` movemask hack.

## Public API contract (important gotchas)

- `escapeInto(dst, value)` / `escapeIntoUnquote` write through raw `[*]u8` cursors and
  return a pointer to the **first byte after the last written byte**. They perform no bounds
  checks. Callers must provide `value.len * 6 + 64` bytes: `6 * value.len + 2` is the logical
  worst case, and the `+64` absorbs full-width vector stores and the fixed 8-byte escape-table
  copies that write past the logical end. Do not "tighten" this bound to `6*len+2`.
- `escape` / `escapeUnquote` (allocator wrappers) are the only fallible functions; they
  allocate `6*len+64`, then `realloc` down to the written length (freeing on failure).
- `escapeIntoSlice` / `escapeIntoUnquoteSlice` panic in Debug/ReleaseSafe if capacity is
  insufficient; that check is comptime-eliminated in release modes.
- Input is `[]const u8` and is never UTF-8 validated: escaping preserves bytes, so invalid
  UTF-8 passes through unchanged.
- Escape set is exactly bytes `< 0x20` (short forms `\b \t \n \f \r`, else `\u00xx`),
  `"`, and `\`. `0x20` and all bytes `>= 0x7F` are copied verbatim.

## Conventions and Zig-specific patterns

- **Tables are comptime-generated**, never hand-written: `quoteTab` and `needEscaped` are
  `blk: { ... }` blocks. `needEscaped[i]` must stay derived from `quoteTab[i].len != 0`.
- Escape payloads are always NUL-padded `[8]u8` and the slow path copies all 8 bytes; `len`
  is the true length (2 or 6; 0 means copy verbatim). Do not shrink this to `len`.
- **Unaligned vector access** is `@as(*align(1) const @Vector(LANES, u8), @ptrCast(ptr)).*`
  and the symmetric store. The `align(1)` is mandatory; omitting it inherits the vector's
  natural alignment and is UB on unaligned input.
- No implicit integer casts. Shift counts must be the operand's shift type, so runtime
  shifts use `x >> @intCast(n)` after materializing a typed `all_ones` (a `comptime_int`
  cannot be shifted by a runtime amount). See `clearHighBits`.
- `escapedMask` semantics: bit `i` of the result is 1 iff byte `i` needs escaping. Lane 0 is
  bit 0, matching `@ctz` used by `firstOffset`.
- Keep the small vector/mask methods `inline fn`; that is intentional for loop fusion.
- Public API names are camelCase (`escapeIntoUnquote`), the Rust originals being snake_case.

## Testing

- Tests are inline `test "..."` blocks at the bottom of `src/json_escape.zig`.
- The oracle is `referenceEscape`, a scalar port of the table walk (Zig std has no JSON
  escaper). New cases should be compared against it.
- **Every backend must be exercised explicitly** via
  `const all_backends = .{ SimdVector(16), SimdVector(32), SimdVector(64), FallbackVector };`
  and `inline for (all_backends)`. Testing only the dispatched path silently skips AVX-512 on
  most hosts. `expectMatchesOracle` already does this for both quoted and unquoted output.
- The SWAR mask must always agree bit-for-bit with the 64-lane vector mask.
- Random coverage is a 3-shift xorshift64 with a per-length seed over sizes `0..=300`
  (covers 15/16, 31/32, 63/64, 127/128, 255/256 boundaries); unaligned starts are covered by
  300-byte windows at offsets `0..=32`. Stack buffers of `[4200]u8` are the established size.
- `std.testing.allocator` is used for the allocating API, so leaks are caught automatically.

## Repo notes

- `.gitignore` covers `.zig-cache/`, `zig-out/`, `*.o`, and editor dirs. A stray
  `json_escape.o` may appear in the repo root from manual `zig build-obj` runs; it is ignored.
- The default branch is `master`. Do not commit unless asked.
