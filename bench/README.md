# Benchmark: Zig port vs Rust `json-escape-simd`

This directory holds a matched pair of benchmark programs, one per language,
that run the same benchmark:

- `zig/main.zig` -- the Zig port (`src/json_escape.zig`)
- `rust/src/main.rs` -- the Rust reference implementation (`json-escape-simd`
  crate, expected at `../../../json-escape-simd-x`)
- `compare.py` -- builds both, runs them alternately and prints a comparison

Both binaries share one deterministic specification: identical PRNG, identical
dataset generation, identical escape loop, identical calibration/timing loop and
identical report format. No benchmark framework is used on either side, so the
two runs are directly comparable. Each row prints an FNV-1a checksum of the
escaped output; **the checksums must match between the two languages** (only the
timing columns may differ). If they do not, the two datasets or the escaping
semantics have diverged.

## Running

The easiest way is the comparison runner, which builds both sides, runs them
alternately for several rounds and prints one side-by-side table:

```sh
python3 bench/compare.py --runs 5
```

To run each side on its own:

```sh
zig build bench        # builds zig-out/bin/bench and runs it (ReleaseFast)
zig build bench-build  # builds zig-out/bin/bench only
cargo run --release --manifest-path bench/rust/Cargo.toml   # Rust side
```

`zig build bench -Dbench-optimize=safe` builds the Zig side with safety checks
if you want to measure that cost. The programs take no arguments.

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
the ratio column is the meaningful one, and the checksums never change.

```
name             strings      bytes  zig ns/pass  rust ns/pass  zig MiB/s  rust MiB/s  zig/rust
short/every         4096      70510        51648         88742    1301.96      757.72     1.718
short/realistic     4096      70510        12685         20126    5301.03     3340.53     1.587
mid/every           2048     164490        98418         96517    1593.91     1625.31     0.981
mid/realistic       2048     164490        17432         29504    8998.96     5317.65     1.693
large/every          512     290628       215818        195336    1284.25     1418.95     0.905
large/realistic      512     290628        40356         39376    6867.99     7039.07     0.976

zig/rust > 1.0 means the Zig port is faster (fewer ns per pass).
checksums: all 6 scenarios match
```

The short-input buckets, where a call frame dominates the work, are the port's
strongest result: `short/realistic` is about 1.6x and `mid/realistic` about 1.7x
faster than Rust. This comes from keeping the runtime backend check small enough
that the compiler inlines the dispatch into the caller's loop; the Rust crate
cannot do the same because `#[target_feature]` forces an out-of-line call per
string. `mid/every` is at parity and `large/every` is about 10% slower, both
dominated by the scalar escape slow path on dense input. Per-scenario raw output
from either binary is the table format described above.

> User input:
>
> I actually followed this profile with an optimized short-mid execution as the
> the main target, since my application area are logs, where the huge majority
> of workload is short (keys) and the rest (text) is likely short (within 32 bytes)
> or mid.



### Apple M1 (NEON), macOS

Same protocol, best of 14 alternated runs. Before the packed-mask work the port
was 0.72-0.95x on most scenarios; these changes target this machine.

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
