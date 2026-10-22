//! Benchmark for the Zig port of `json-escape-simd`.
//!
//! The dataset generation, the escape loop, the calibration/timing loop and the
//! report format are byte-for-byte identical to `bench/rust/src/main.rs`. Do not
//! change one side without changing the other: the printed checksums must match
//! between the two implementations.

const std = @import("std");
const json_escape = @import("jsonescape");

const seed_base: u64 = 0x243F_6A88_85A3_08D3;
const min_sample_ns: u64 = 250 * std.time.ns_per_ms;
const samples: u64 = 7;
const max_len: usize = 1024;
const dst_capacity: usize = max_len * 6 + 64;
const printable: u64 = 95;

const escapable = [8]u8{ '"', '\\', '\n', '\t', '\r', 0x08, 0x0C, 0x01 };

const Bucket = struct {
    name: []const u8,
    count: u64,
    min_len: u64,
    max_len: u64,
};

const buckets = [3]Bucket{
    .{ .name = "short", .count = 4096, .min_len = 2, .max_len = 32 },
    .{ .name = "mid", .count = 2048, .min_len = 33, .max_len = 128 },
    .{ .name = "large", .count = 512, .min_len = 129, .max_len = 1024 },
};

/// xorshift64*, identical to the Rust `Rng`.
const Rng = struct {
    state: u64,

    fn init(seed: u64) Rng {
        return .{ .state = if (seed == 0) 0x9E37_79B9_7F4A_7C15 else seed };
    }

    fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545_F491_4F6C_DD1D;
    }

    fn below(self: *Rng, n: u64) u64 {
        return self.next() % n;
    }
};

fn seedFor(bucket: u64, workload: u64) u64 {
    return seed_base ^ (bucket *% 0x9E37_79B9_7F4A_7C15) ^ (workload *% 0xC2B2_AE3D_27D4_EB4F);
}

fn genContent(allocator: std.mem.Allocator, rng: *Rng, len: usize, needs_escape: bool) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    for (buf) |*b| {
        const r = rng.next();
        const escaped = needs_escape and r % 8 == 0;
        const payload = @as(usize, @intCast((r >> 8) % escapable.len));
        const plain = @as(u8, @intCast(r % printable));
        b.* = if (escaped) escapable[payload] else 0x20 + plain;
    }
    if (needs_escape) {
        const idx: usize = @intCast(rng.below(len));
        const payload = rng.below(escapable.len);
        buf[idx] = escapable[@intCast(payload)];
    }
    return buf;
}

fn genLengths(allocator: std.mem.Allocator, rng: *Rng, bucket: Bucket) ![]usize {
    const lengths = try allocator.alloc(usize, @intCast(bucket.count));
    for (lengths) |*len| {
        const span = bucket.max_len - bucket.min_len + 1;
        len.* = @intCast(bucket.min_len + rng.below(span));
    }
    return lengths;
}

const Dataset = struct {
    strings: [][]u8,
    total_bytes: usize,
};

fn buildDataset(
    allocator: std.mem.Allocator,
    lengths: []const usize,
    rng: *Rng,
    escape_every: bool,
) !Dataset {
    const strings = try allocator.alloc([]u8, lengths.len);
    var total_bytes: usize = 0;
    for (lengths, strings) |len, *slot| {
        const needs_escape = if (escape_every) true else rng.below(100) < 5;
        slot.* = try genContent(allocator, rng, len, needs_escape);
        total_bytes += len;
    }
    return .{ .strings = strings, .total_bytes = total_bytes };
}

fn onePass(strings: []const []u8, dst: []u8) usize {
    var acc: usize = 0;
    for (strings) |s| {
        const out = json_escape.escapeIntoSlice(dst, s);
        acc +%= out.len;
    }
    return acc;
}

fn checksum(strings: []const []u8, dst: []u8) u64 {
    var h: u64 = 0xCBF2_9CE4_8422_2325;
    for (strings) |s| {
        const out = json_escape.escapeIntoSlice(dst, s);
        for (out) |b| {
            h ^= b;
            h *%= 0x0000_0100_0000_01B3;
        }
    }
    return h;
}

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn measure(io: std.Io, strings: []const []u8, dst: []u8) u64 {
    std.mem.doNotOptimizeAway(onePass(strings, dst));

    var reps: u64 = 1;
    var elapsed: u64 = 0;
    while (true) {
        const start = nowNs(io);
        var i: u64 = 0;
        while (i < reps) : (i += 1) {
            std.mem.doNotOptimizeAway(onePass(strings, dst));
        }
        elapsed = nowNs(io) - start;
        if (elapsed >= min_sample_ns) break;
        reps *= 2;
    }

    var best: u64 = elapsed / reps;
    var sample: u64 = 1;
    while (sample < samples) : (sample += 1) {
        const start = nowNs(io);
        var i: u64 = 0;
        while (i < reps) : (i += 1) {
            std.mem.doNotOptimizeAway(onePass(strings, dst));
        }
        const ns = (nowNs(io) - start) / reps;
        if (ns < best) best = ns;
    }
    return best;
}

fn report(
    io: std.Io,
    stdout: *std.Io.Writer,
    name: []const u8,
    dataset: Dataset,
    dst: []u8,
) !void {
    const chk = checksum(dataset.strings, dst);
    const best_ns = measure(io, dataset.strings, dst);
    const ps_per_byte = best_ns * 1000 / dataset.total_bytes;
    const mib_per_s = @as(f64, @floatFromInt(dataset.total_bytes)) *
        1_000_000_000.0 /
        (@as(f64, @floatFromInt(best_ns)) * 1048576.0);
    try stdout.print(
        "{s:<16} {d:>7} {d:>10} {d:>12} {d:>8} {d:>10.2} {x:>18}\n",
        .{ name, dataset.strings.len, dataset.total_bytes, best_ns, ps_per_byte, mib_per_s, chk },
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var dst_buffer: [dst_capacity]u8 = undefined;
    const dst = dst_buffer[0..];

    try stdout.print("{s}\n", .{"json_escape benchmark"});
    try stdout.print(
        "{s:<16} {s:>7} {s:>10} {s:>12} {s:>8} {s:>10} {s:>18}\n",
        .{ "name", "strings", "bytes", "ns/pass", "ps/byte", "MiB/s", "checksum" },
    );

    var name_buffer: [32]u8 = undefined;
    for (buckets, 0..) |bucket, bucket_index| {
        var lengths_rng = Rng.init(seedFor(bucket_index, 0));
        const lengths = try genLengths(allocator, &lengths_rng, bucket);

        inline for (.{ "every", "realistic" }, 0..) |label, workload| {
            var rng = Rng.init(seedFor(bucket_index, workload + 1));
            const dataset = try buildDataset(allocator, lengths, &rng, workload == 0);
            const name = try std.fmt.bufPrint(&name_buffer, "{s}/{s}", .{ bucket.name, label });
            try report(init.io, stdout, name, dataset, dst);
        }
    }

    try stdout.flush();
}
