# Benchmark: Zig port vs Rust `json-escape-simd`

This directory holds a matched pair of benchmark programs, one per language,
that run the same benchmark:

- `zig/main.zig` -- the Zig port (`src/json_escape.zig`)
- `rust/src/main.rs` -- the Rust reference implementation (`json-escape-simd`
  crate, expected at `../../../json-escape-simd-x`)
- `compare.py` -- builds both, runs them alternately and prints a comparison

Both binaries share one deterministic specification: identical PRNG, identical
dataset generation, identical escape loop, identical calibration/timing loop and
identical per-scenario report rows. The printed header and rows are identical by
design. No benchmark framework is used on either side, so the two runs are
directly comparable. Each row prints an FNV-1a checksum of the escaped output;
**the checksums must match between the two languages** (only the timing columns
may differ). If they do not, the two datasets or the escaping semantics have
diverged.

## Running

The easiest way is the comparison runner, which builds both sides, runs them
alternately for several rounds and prints one side-by-side table:

```sh
python3 bench/compare.py --runs 5
```

To run each side on its own:

```sh
zig build bench                     # builds and runs the Zig side (ReleaseFast)
zig build bench-build               # builds zig-out/bin/bench only
cargo run --release --manifest-path bench/rust/Cargo.toml   # Rust side
```

`zig build bench -Dbench-optimize=safe` builds the Zig side with safety checks
if you want to measure that cost. Neither benchmark binary takes arguments.

Timings move with CPU frequency and background load, so `compare.py` alternates
the two binaries over several rounds and keeps the fastest per-pass time per
scenario. Pinning to an idle core (`taskset -c 4 ...`) and a performance governor
reduce the noise further. Each process already reports the best of 7 samples,
each measuring at least 250 ms of work.

## Methodology

Both implementations perform the same steps:

1. **Dataset generation** (once, outside timing): for each bucket a vector of
   lengths is drawn from a seeded xorshift64\* PRNG, then each string is filled
   byte by byte from the same PRNG stream. Content is printable ASCII
   (`0x20..=0x7E`). For strings that must need escaping, every PRNG draw with
   `r % 8 == 0` is replaced by a byte from the escape set
   (`\"`, `\\`, `\n`, `\t`, `\r`, `0x08`, `0x0C`, `0x01`), and one extra
   escape byte is forced at a derived position so the guarantee is exact.
2. **Escaping** into one preallocated buffer of `6 * 1024 + 64` bytes
   (`escapeIntoSlice` in Zig, `escape_into` on a cleared `Vec` in Rust), summing
   the written lengths. Both use the quoted form.
3. **Calibration**: double the number of full-dataset passes until a sample
   takes at least 250 ms. Then take 7 timed samples of that pass count and keep
   the fastest per-pass time. Each language prevents the loop from being
   optimized away (`doNotOptimizeAway` / `black_box`).

Reported columns:

| column     | meaning                                      |
| ---------- | -------------------------------------------- |
| `name`     | workload (bucket/workload)                   |
| `strings`  | number of strings in the dataset             |
| `bytes`    | total input bytes per pass                   |
| `ns/pass`  | best measured time for one full dataset pass |
| `ps/byte`  | integer picoseconds per input byte           |
| `MiB/s`    | throughput, `bytes / ns`                     |
| `checksum` | FNV-1a 64 of all escaped output bytes        |

## Scenarios

All workloads use the same three buckets; the realistic workload reuses the
exact same length vector as the dense workload for the bucket, so only content
differs.

| bucket  | strings | length range | dense bytes | realistic bytes |
| ------- | ------- | ------------ | ----------- | --------------- |
| `short` | 4096    | 2..=32       | 70510       | 70510           |
| `mid`   | 2048    | 33..=128     | 164490      | 164490          |
| `large` | 512     | 129..=1024   | 290628      | 290628          |

1. **`every` -- everything needs escapes**: 100% of strings contain at least one
   byte that must be escaped, with roughly 1 in 8 bytes escaped. This exercises
   the SIMD fast path and the scalar escape path on every string.
2. **`realistic` -- realistic workload**: 95% of strings are pure printable
   ASCII and need no escaping at all (the fully vectorized copy path); 5% of
   strings need escaping and are generated exactly as in the `every` workload.

## Reference results

Intel Core i7-12700K (AVX2, no AVX-512), Linux, `powersave` governor, best of 10
alternated runs of each binary. Absolute numbers vary with frequency and load;
the ratio columns are the meaningful ones, and the checksums never change.

### Zig vs Rust

```
name             strings      bytes  zig ns/pass  rust ns/pass  zig MiB/s  rust MiB/s  zig/rust
short/every         4096      70510        52196         88366    1288.29      760.97     1.693
short/realistic     4096      70510        12895         20121    5214.70     3341.96     1.560
mid/every           2048     164490        93311         96223    1681.15     1630.27     1.031
mid/realistic       2048     164490        16150         29523    9713.31     5313.48     1.828
large/every          512     290628       193135        195684    1435.08     1416.39     1.013
large/realistic      512     290628        36049         39905    7688.55     6945.61     1.107

zig/rust > 1.0 means the Zig port is faster (fewer ns per pass).
checksums: all 6 scenarios match
```

### Previous tail-masking kernel vs Rust (historical)

This kernel was removed; it differed only by masking over-read lanes before
reading the first escape offset in the tail loop. Kept for reference only.

```
name             strings      bytes  zig ns/pass  rust ns/pass  zig MiB/s  rust MiB/s  zig/rust
short/every         4096      70510        57801         88547    1163.36      759.41     1.532
short/realistic     4096      70510        13643         20050    4928.80     3353.79     1.470
mid/every           2048     164490        97250         96277    1613.06     1629.36     0.990
mid/realistic       2048     164490        17496         29612    8966.04     5297.51     1.693
large/every          512     290628       186355        195695    1487.29     1416.31     1.050
large/realistic      512     290628        36560         39795    7581.08     6964.81     1.088

zig/rust > 1.0 means the Zig port is faster (fewer ns per pass).
checksums: all 6 scenarios match
```

The unmasked tail (read the raw first offset and finish when it is `>= nb`) is
the only kernel. It wins where the tail is a meaningful share of the work: about
4% on `mid/every`, 7.7% on `mid/realistic`, and 5-10% on the short buckets. The
only measured regression is `large/every` at about 3.6%, where Tier 1 dominates
and the tail change cannot pay for the code-layout shift. That single-workload
difference is negligible compared with carrying a second kernel, so the
masked-tail variant was removed. Re-measure on the target machine instead of
comparing absolute numbers across machines.

The short-input buckets, where a call frame dominates the work, remain the
port's strongest result: `short/realistic` is about 1.5-1.6x and `mid/realistic`
about 1.7-1.8x faster than Rust. This comes from keeping the runtime backend
check small enough that the compiler inlines the dispatch into the caller's
loop; the Rust crate cannot do the same because `#[target_feature]` forces an
out-of-line call per string.

> User input:
>
> I actually followed this profile with an optimized short-mid execution as the
> the main target, since my application area are logs, where the huge majority
> of workload is short (keys) and the rest (text) is likely short (within 32 bytes)
> or mid.



### Apple M1 (NEON), macOS

Historical results for the previous tail-masking kernel, best of 14 alternated
runs; not re-run after the tail change. Before the packed-mask work the port was
0.72-0.95x on most scenarios; these changes target this machine.

```
name             strings      bytes  zig ns/pass  rust ns/pass  zig MiB/s  rust MiB/s  zig/rust
short/every         4096      70510        73389         74838      916.47      898.73     1.020
short/realistic     4096      70510        19522         19013     3444.75     3536.97     0.974
mid/every           2048     164490       144212        144820     1087.72     1083.15     1.004
mid/realistic       2048     164490        25164         24928     6233.03     6292.06     0.991
large/every          512     290628       312300        306684     887.49      903.74     0.982
large/realistic      512     290628        69904         72271     3965.90     3836.01     1.034

checksums: all 6 scenarios match
```

On NEON the port has no call-inlining advantage over Rust: both end up with one
out-of-line kernel call per string, so the results are symmetric. The remaining
work is codegen quality (see `EscapeMask` in `AGENTS-DEV.md`), not structure.
