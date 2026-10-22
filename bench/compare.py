#!/usr/bin/env python3
"""Compare the Zig port against the Rust `json-escape-simd` reference.

Both benchmark binaries share the same dataset, escape loop, timing loop and
report format (see bench/README.md). This script builds them, runs them
alternately, keeps the fastest per-pass time per scenario for each language and
prints a side-by-side comparison. It also verifies that the FNV-1a checksums of
the escaped output match, which proves both languages processed identical data.

Usage:
    python3 bench/compare.py [--runs N] [--zig PATH] [--rust PATH]
"""

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ZIG = ROOT / "zig-out" / "bin" / "bench"
DEFAULT_RUST = ROOT / "bench" / "rust" / "target" / "release" / "json-escape-bench"

COLUMNS = ("name", "strings", "bytes", "ns/pass", "ps/byte", "MiB/s", "checksum")


def build() -> None:
    subprocess.run(["zig", "build", "bench-build"], cwd=ROOT, check=True)
    subprocess.run(
        [
            "cargo",
            "build",
            "--release",
            "--manifest-path",
            "bench/rust/Cargo.toml",
        ],
        cwd=ROOT,
        check=True,
    )


def run_binary(path: Path) -> dict:
    out = subprocess.run(
        [str(path)], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout
    rows = {}
    for line in out.splitlines():
        fields = line.split()
        if len(fields) != len(COLUMNS) or fields[0] == "name":
            continue
        name, strings, total_bytes, ns_per_pass, ps_per_byte, mib, checksum = fields
        rows[name] = {
            "strings": int(strings),
            "bytes": int(total_bytes),
            "ns": int(ns_per_pass),
            "ps": int(ps_per_byte),
            "mib": float(mib),
            "checksum": checksum,
        }
    return rows


def best(runs: list[dict]) -> dict:
    merged = dict(runs[0])
    for run in runs[1:]:
        for name, row in run.items():
            current = merged.get(name)
            if current is None or row["ns"] < current["ns"]:
                merged[name] = row
    return merged


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=3, help="runs per language (default 3)")
    parser.add_argument("--zig", default=str(DEFAULT_ZIG), help="Zig benchmark binary")
    parser.add_argument("--rust", default=str(DEFAULT_RUST), help="Rust benchmark binary")
    parser.add_argument("--no-build", action="store_true", help="skip building")
    args = parser.parse_args()

    if not args.no_build:
        build()

    zig_bin = Path(args.zig)
    rust_bin = Path(args.rust)
    for binary in (zig_bin, rust_bin):
        if not binary.exists():
            print(f"missing benchmark binary: {binary}", file=sys.stderr)
            return 1

    zig_runs = []
    rust_runs = []
    for _ in range(args.runs):
        zig_runs.append(run_binary(zig_bin))
        rust_runs.append(run_binary(rust_bin))

    zig = best(zig_runs)
    rust = best(rust_runs)

    print(f"json_escape benchmark: best of {args.runs} runs per language, alternated")
    print()
    print(
        f"{'name':<16} {'strings':>7} {'bytes':>10} "
        f"{'zig ns/pass':>12} {'rust ns/pass':>13} "
        f"{'zig MiB/s':>10} {'rust MiB/s':>11} {'zig/rust':>9}"
    )
    mismatch = False
    for name in zig:
        if name not in rust:
            print(f"{name}: missing from the Rust output", file=sys.stderr)
            return 1
        z = zig[name]
        r = rust[name]
        if z["checksum"] != r["checksum"]:
            mismatch = True
        ratio = r["ns"] / z["ns"] if z["ns"] else 0.0
        print(
            f"{name:<16} {z['strings']:>7} {z['bytes']:>10} "
            f"{z['ns']:>12} {r['ns']:>13} "
            f"{z['mib']:>10.2f} {r['mib']:>11.2f} {ratio:>9.3f}"
        )

    print()
    print("zig/rust > 1.0 means the Zig port is faster (fewer ns per pass).")
    if mismatch:
        print("checksum mismatch: the two languages produced different output")
        return 1
    print(f"checksums: all {len(zig)} scenarios match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
