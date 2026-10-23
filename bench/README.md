# Benchmark: Zig port vs Rust `json-escape-simd`

This directory holds a matched pair of benchmark programs, one per language,
that run the same benchmark:

- `zig/main.zig` -- the Zig port (`src/json_escape.zig`)
- `rust/src/main.rs` -- the Rust reference implementation: the original
  upstream `json-escape-simd` crate from crates.io (currently 3.1.2)
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
the ratio columns are the meaningful ones, and the checksums never change. The
Rust side is the upstream `json-escape-simd` 3.1.2 crate from crates.io with its
default features (the crate's optional `avx512` feature is not enabled).

### Zig vs Rust

```
name             strings      bytes  zig ns/pass  rust ns/pass  zig MiB/s  rust MiB/s  zig/rust
short/every         4096      70510        55030         93225    1221.94      721.30     1.694
short/realistic     4096      70510        13451         24557    4999.15     2738.27     1.826
mid/every           2048     164490        89516        138368    1752.42     1133.72     1.546
mid/realistic       2048     164490        16323         21486    9610.36     7301.03     1.316
large/every          512     290628       185140        205126    1497.05     1351.19     1.108
large/realistic      512     290628        39275         37849    7057.02     7322.90     0.964

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
the only kernel. It won where the tail is a meaningful share of the work: about
4% on `mid/every`, 7.7% on `mid/realistic`, and 5-10% on the short buckets. The
only measured regression was `large/every` at about 3.6%, where Tier 1 dominates
and the tail change could not pay for the code-layout shift. That single-workload
difference is negligible compared with carrying a second kernel, so the
masked-tail variant was removed. Re-measure on the target machine instead of
comparing absolute numbers across machines.

This historical table was measured while the Rust side was still a local fork of
the crate, so do not diff it directly against the current table above: the
difference mixes the tail change with upstream improvements.

The short-input buckets, where a call frame dominates the work, remain the
port's strongest result: `short/realistic` is about 1.8x and `mid/realistic`
about 1.3x faster than upstream Rust. This comes from keeping the runtime backend
check small enough that the compiler inlines the dispatch into the caller's
loop; the Rust crate cannot do the same because `#[target_feature]` forces an
out-of-line call per string.

The one workload where the port is slower against upstream is `large/realistic`
(0.96x on this machine, 0.88x on the M1 below): long strings that almost never
need escaping are the case where upstream's kernel is already at peak bandwidth.

> User input:
>
> I actually followed this profile with an optimized short-mid execution as the
> the main target, since my application area are logs, where the huge majority
> of workload is short (keys) and the rest (text) is likely short (within 32 bytes)
> or mid.



### Apple M1 (NEON), macOS

Best of 10 alternated runs of each binary, upstream `json-escape-simd` 3.1.2 as
the Rust side. Absolute numbers move with frequency and background load; the
ratio column is the meaningful one, and the checksums never change.

```
name             strings      bytes  zig ns/pass  rust ns/pass  zig MiB/s  rust MiB/s  zig/rust
short/every         4096      70510        42569         86545    1579.64      776.98     2.033
short/realistic     4096      70510        11103         22987    6056.34     2925.29     2.070
mid/every           2048     164490       131284        181011    1194.89      866.63     1.379
mid/realistic       2048     164490        19395         26374    8088.16     5947.90     1.360
large/every          512     290628       283683        312130     977.02      887.98     1.100
large/realistic      512     290628        63539         55936    4362.12     4955.03     0.880

zig/rust > 1.0 means the Zig port is faster (fewer ns per pass).
checksums: all 6 scenarios match
```
