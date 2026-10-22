//! SIMD-accelerated JSON string escaping, translated from the Rust
//! `json-escape-simd` crate.
//!
//! The escape set is exactly: bytes `< 0x20` (as `\u00XX`, or the short forms
//! `\b \t \n \f \r`), `"` as `\"`, and `\` as `\\`. Every other byte, including
//! `0x20` and all bytes `>= 0x7F`, is copied verbatim. Input is byte-oriented:
//! UTF-8 passes through untouched and is never validated (escaping preserves
//! bytes).

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// Part 1: backend selection, constants, comptime tables
// ---------------------------------------------------------------------------

pub const Backend = enum { sse2, neon, avx2, avx512, swar };

/// Candidate backend chosen at compile time from the target CPU. The runtime
/// check in `activeBackend` can still downgrade this to `.swar`.
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

const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
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
        .x86_64, .x86 => {},
        else => return true,
    }
    switch (b) {
        .sse2 => return cpuid(1, 0).edx & (1 << 26) != 0,
        .avx2 => {
            const max_leaf = cpuid(0, 0).eax;
            if (max_leaf < 7) return false;
            const leaf1 = cpuid(1, 0);
            if ((leaf1.ecx & (1 << 27)) == 0) return false; // OSXSAVE
            if ((xgetbv(0) & 0x06) != 0x06) return false; // XMM+YMM state enabled
            return cpuid(7, 0).ebx & (1 << 5) != 0; // AVX2
        },
        .avx512 => {
            if (!runtimeSupports(.avx2)) return false;
            if ((cpuid(7, 0).ebx & (1 << 16)) == 0) return false; // AVX512F
            return (xgetbv(0) & 0xE6) == 0xE6; // opmask/ZMM state enabled
        },
        else => return true,
    }
}

var cached_backend: Backend = undefined;
var backend_detected: bool = false;

/// Runs the CPUID/XGETBV probe. Kept out of line so `activeBackend` stays a
/// single predictable load and branch; inlining the probe into `escapeInto`
/// would make the dispatch too large for the optimizer to inline.
fn detectBackend() Backend {
    const b = comptime selected_backend;
    cached_backend = if (runtimeSupports(b)) b else .swar;
    backend_detected = true;
    return cached_backend;
}

pub inline fn activeBackend() Backend {
    if (!backend_detected) return @call(.never_inline, detectBackend, .{});
    return cached_backend;
}

pub const EscapeEntry = struct { len: u8, bytes: [8]u8 };

fn pad8(comptime s: []const u8) [8]u8 {
    var out: [8]u8 = @splat(0);
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

// ---------------------------------------------------------------------------
// Part 2: generic vector + SWAR fallback
// ---------------------------------------------------------------------------

pub fn Mask(comptime LANES: usize) type {
    return struct {
        const Self = @This();
        pub const lanes = LANES;
        data: @Vector(LANES, bool),

        pub inline fn orWith(self: Self, rhs: Self) Self {
            return .{ .data = self.data | rhs.data };
        }

        pub inline fn bitmask(self: Self) @Int(.unsigned, LANES) {
            return @bitCast(self.data);
        }
    };
}

pub fn SimdVector(comptime LANES: usize) type {
    return struct {
        const Self = @This();
        pub const lanes = LANES;
        pub const BitMask = @Int(.unsigned, LANES);

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

/// Pure u64 SWAR fallback covering 64 bytes as eight little-endian-normalized
/// words. It exposes the same surface `formatRaw` uses: `lanes`, `BitMask`,
/// `loadu`, `storeu`, `escapedMask`.
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
            // escaped <=> (b <= 0x1F) or (b == '\\') or (b == '"')
            const f = zeroFlags(w & ME0) // (b & 0xE0) == 0 <=> b <= 0x1F
                | zeroFlags(w ^ broadcast('\\')) | zeroFlags(w ^ broadcast('"'));
            inline for (0..8) |bi| {
                const bit = (f >> @intCast(8 * bi + 7)) & 1;
                bm |= bit << @intCast(8 * wi + bi);
            }
        }
        return bm;
    }
};

inline fn firstOffset(m: anytype) usize {
    return @ctz(m);
}

inline fn clearHighBits(m: anytype, n: usize) @TypeOf(m) {
    const T = @TypeOf(m);
    const all_ones: T = std.math.maxInt(T);
    std.debug.assert(n < @bitSizeOf(T));
    return m & (all_ones >> @intCast(n));
}

pub fn VectorFor(comptime b: Backend) type {
    return switch (b) {
        .sse2, .neon => SimdVector(16),
        .avx2 => SimdVector(32),
        .avx512 => SimdVector(64),
        .swar => FallbackVector,
    };
}

// ---------------------------------------------------------------------------
// Part 3: slow-path helper
// ---------------------------------------------------------------------------

inline fn escapeUnchecked(src: *[*]const u8, nb: *usize, dst: *[*]u8) void {
    std.debug.assert(nb.* >= 1);
    while (true) {
        const ch = src.*[0];
        const entry = quoteTab[ch];
        std.debug.assert(entry.len != 0);
        dst.*[0..8].* = entry.bytes;
        dst.* += entry.len;
        src.* += 1;
        nb.* -= 1;
        if (nb.* == 0 or needEscaped[src.*[0]] == 0) return;
    }
}

inline fn checkCrossPage(ptr: [*]const u8, step: usize) bool {
    const page: usize = 4096;
    return (@intFromPtr(ptr) & (page - 1)) + step > page;
}

// ---------------------------------------------------------------------------
// Part 4: main kernel
// ---------------------------------------------------------------------------

pub fn formatRaw(comptime Vec: type, value: []const u8, dst: [*]u8) [*]u8 {
    const LANES = Vec.lanes;
    const CHUNK = LANES * 4;

    var sptr: [*]const u8 = value.ptr;
    var dptr: [*]u8 = dst;
    var nb: usize = value.len;

    // Tier 1: CHUNK loop.
    chunk: while (nb >= CHUNK) {
        const v1 = Vec.loadu(sptr);
        const v2 = Vec.loadu(sptr + LANES);
        const v3 = Vec.loadu(sptr + LANES * 2);
        const v4 = Vec.loadu(sptr + LANES * 3);

        const m1 = v1.escapedMask();
        const m2 = v2.escapedMask();
        const m3 = v3.escapedMask();
        const m4 = v4.escapedMask();

        if ((m1 | m2 | m3 | m4) == 0) {
            v1.storeu(dptr);
            v2.storeu(dptr + LANES);
            v3.storeu(dptr + LANES * 2);
            v4.storeu(dptr + LANES * 3);
            nb -= CHUNK;
            dptr += CHUNK;
            sptr += CHUNK;
        } else {
            inline for (.{ v1, v2, v3, v4 }, .{ m1, m2, m3, m4 }) |v, m| {
                v.storeu(dptr);
                if (m != 0) {
                    const cn = firstOffset(m);
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
    }

    // Tier 2: LANES loop.
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

    // Tier 3: tail loop. A full-LANES load may over-read up to LANES - 1 bytes;
    // that is only allowed on linux/macos in release modes and only when the
    // read stays within the current page.
    var placeholder: [LANES]u8 = @splat(0);
    const direct_tail_load = comptime (builtin.os.tag == .linux or builtin.os.tag == .macos) and
        (builtin.mode == .fast or builtin.mode == .small);

    tail: while (nb > 0) {
        const v = if (direct_tail_load and !checkCrossPage(sptr, LANES))
            Vec.loadu(sptr)
        else blk: {
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
}

pub fn formatString(comptime Vec: type, value: []const u8, dst: [*]u8) [*]u8 {
    var d = dst;
    d[0] = '"';
    d += 1;
    const end = formatRaw(Vec, value, d);
    end[0] = '"';
    return end + 1;
}

pub fn formatUnquoted(comptime Vec: type, value: []const u8, dst: [*]u8) [*]u8 {
    return formatRaw(Vec, value, dst);
}

// ---------------------------------------------------------------------------
// Part 5: public API
// ---------------------------------------------------------------------------

/// Escape `value` into `dst` as a quoted JSON string.
/// Returns a pointer to the first byte after the last written element; the
/// number of bytes written is `@intFromPtr(result) - @intFromPtr(dst)`.
///
/// CALLER RESPONSIBILITY: `dst` must point to at least `value.len * 6 + 64`
/// writable bytes. `6 * value.len + 2` is the worst-case logical output (the
/// `+ 2` being the surrounding quotes); the extra slack absorbs full-width
/// vector stores (up to 64 bytes) and the fixed 8-byte escape-table copies
/// that write past the final length. There are no runtime bounds checks.
///
/// The hot path is deliberately split from the multi-backend fallback: a single
/// `switch` over every backend here turns this into an ~9 KiB function that the
/// optimizer will not inline, costing a full call frame, an indirect jump and a
/// re-materialization of the kernel constants for every escaped string.
pub fn escapeInto(dst: [*]u8, value: []const u8) [*]u8 {
    if (activeBackend() == selected_backend) {
        return formatString(VectorFor(selected_backend), value, dst);
    }
    return @call(.never_inline, escapeIntoAnyBackend, .{ dst, value });
}

fn escapeIntoAnyBackend(dst: [*]u8, value: []const u8) [*]u8 {
    return switch (activeBackend()) {
        inline else => |b| formatString(VectorFor(b), value, dst),
    };
}

/// Like `escapeInto` but without the surrounding quotes. Worst case
/// `6 * value.len` bytes; the same `value.len * 6 + 64` capacity rule applies.
pub fn escapeIntoUnquote(dst: [*]u8, value: []const u8) [*]u8 {
    if (activeBackend() == selected_backend) {
        return formatUnquoted(VectorFor(selected_backend), value, dst);
    }
    return @call(.never_inline, escapeIntoAnyBackendUnquote, .{ dst, value });
}

fn escapeIntoAnyBackendUnquote(dst: [*]u8, value: []const u8) [*]u8 {
    return switch (activeBackend()) {
        inline else => |b| formatUnquoted(VectorFor(b), value, dst),
    };
}

/// Slice-typed convenience wrapper around `escapeInto` that checks capacity in
/// Debug/ReleaseSafe and returns exactly the written bytes.
pub fn escapeIntoSlice(dst: []u8, value: []const u8) []u8 {
    if (comptime (builtin.mode == .debug or builtin.mode == .safe)) {
        if (dst.len < value.len * 6 + 64) @panic("destination buffer too small");
    }
    const end = escapeInto(dst.ptr, value);
    return dst[0 .. @intFromPtr(end) - @intFromPtr(dst.ptr)];
}

/// Slice-typed convenience wrapper around `escapeIntoUnquote`.
pub fn escapeIntoUnquoteSlice(dst: []u8, value: []const u8) []u8 {
    if (comptime (builtin.mode == .debug or builtin.mode == .safe)) {
        if (dst.len < value.len * 6 + 64) @panic("destination buffer too small");
    }
    const end = escapeIntoUnquote(dst.ptr, value);
    return dst[0 .. @intFromPtr(end) - @intFromPtr(dst.ptr)];
}

fn shrink(allocator: std.mem.Allocator, buf: []u8, cnt: usize) std.mem.Allocator.Error![]u8 {
    if (cnt == buf.len) return buf;
    const shrunk = allocator.realloc(buf, cnt) catch |err| {
        allocator.free(buf);
        return err;
    };
    return shrunk;
}

pub fn escape(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    const cap = value.len * 6 + 64;
    const buf = try allocator.alloc(u8, cap);
    const end = escapeInto(buf.ptr, value);
    return shrink(allocator, buf, @intFromPtr(end) - @intFromPtr(buf.ptr));
}

pub fn escapeUnquote(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    const cap = value.len * 6 + 64;
    const buf = try allocator.alloc(u8, cap);
    const end = escapeIntoUnquote(buf.ptr, value);
    return shrink(allocator, buf, @intFromPtr(end) - @intFromPtr(buf.ptr));
}

// ---------------------------------------------------------------------------
// Part 6: tests
// ---------------------------------------------------------------------------

const all_backends = .{ SimdVector(16), SimdVector(32), SimdVector(64), FallbackVector };

fn referenceEscape(value: []const u8, quoted: bool, out: []u8) usize {
    var i: usize = 0;
    if (quoted) {
        out[i] = '"';
        i += 1;
    }
    for (value) |c| {
        const e = quoteTab[c];
        if (e.len == 0) {
            out[i] = c;
            i += 1;
        } else {
            @memcpy(out[i..][0..8], &e.bytes);
            i += e.len;
        }
    }
    if (quoted) {
        out[i] = '"';
        i += 1;
    }
    return i;
}

fn runKernel(comptime Vec: type, value: []const u8, out: []u8, quoted: bool) []const u8 {
    const start = out.ptr;
    const end = if (quoted)
        formatString(Vec, value, start)
    else
        formatUnquoted(Vec, value, start);
    return out[0 .. @intFromPtr(end) - @intFromPtr(start)];
}

fn expectMatchesOracle(value: []const u8, quoted: bool) !void {
    var expected_buf: [4200]u8 = undefined;
    const expected = expected_buf[0..referenceEscape(value, quoted, &expected_buf)];
    inline for (all_backends) |Vec| {
        var out: [4200]u8 = undefined;
        const got = runKernel(Vec, value, &out, quoted);
        try std.testing.expectEqualSlices(u8, expected, got);
    }
}

test "quote table hand-checked" {
    try std.testing.expectEqual(@as(u8, 2), quoteTab['"'].len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ '\\', '"', 0, 0, 0, 0 }, quoteTab['"'].bytes[0..6]);

    try std.testing.expectEqual(@as(u8, 2), quoteTab['\\'].len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ '\\', '\\', 0, 0, 0, 0 }, quoteTab['\\'].bytes[0..6]);

    try std.testing.expectEqual(@as(u8, 2), quoteTab[0x08].len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ '\\', 'b', 0, 0, 0, 0 }, quoteTab[0x08].bytes[0..6]);

    try std.testing.expectEqual(@as(u8, 2), quoteTab[0x09].len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ '\\', 't', 0, 0, 0, 0 }, quoteTab[0x09].bytes[0..6]);

    try std.testing.expectEqual(@as(u8, 2), quoteTab[0x0A].len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ '\\', 'n', 0, 0, 0, 0 }, quoteTab[0x0A].bytes[0..6]);

    try std.testing.expectEqual(@as(u8, 2), quoteTab[0x0C].len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ '\\', 'f', 0, 0, 0, 0 }, quoteTab[0x0C].bytes[0..6]);

    try std.testing.expectEqual(@as(u8, 2), quoteTab[0x0D].len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ '\\', 'r', 0, 0, 0, 0 }, quoteTab[0x0D].bytes[0..6]);

    try std.testing.expectEqual(@as(u8, 6), quoteTab[0x00].len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ '\\', 'u', '0', '0', '0', '0' }, quoteTab[0x00].bytes[0..6]);

    try std.testing.expectEqual(@as(u8, 6), quoteTab[0x1F].len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ '\\', 'u', '0', '0', '1', 'f' }, quoteTab[0x1F].bytes[0..6]);

    try std.testing.expectEqual(@as(u8, 0), quoteTab[0x20].len);
    try std.testing.expectEqual(@as(u8, 0), quoteTab[0x7F].len);
    try std.testing.expectEqual(@as(u8, 0), quoteTab[0xFF].len);

    const all_zero: [8]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &all_zero, &quoteTab[0x7F].bytes);

    for (0..256) |i| {
        const expected: u8 = @intFromBool(i < 0x20 or i == '"' or i == '\\');
        try std.testing.expectEqual(expected, needEscaped[i]);
    }
}

test "bitmask type identity" {
    try std.testing.expect(SimdVector(16).BitMask == u16);
    try std.testing.expect(SimdVector(32).BitMask == u32);
    try std.testing.expect(SimdVector(64).BitMask == u64);
    try std.testing.expect(FallbackVector.BitMask == u64);
}

test "escapedMask lane order" {
    var buf: [64]u8 = @splat('a');
    buf[0] = '"';
    buf[15] = '\\';
    buf[31] = 0x01;
    buf[63] = '\n';

    const v16 = SimdVector(16).loadu(&buf);
    try std.testing.expectEqual(@as(u16, 0x8001), v16.escapedMask());

    const v32 = SimdVector(32).loadu(&buf);
    try std.testing.expectEqual(@as(u32, 0x8000_8001), v32.escapedMask());

    const v64 = SimdVector(64).loadu(&buf);
    try std.testing.expectEqual(@as(u64, 0x8000_0000_8000_8001), v64.escapedMask());

    const vswar = FallbackVector.loadu(&buf);
    try std.testing.expectEqual(v64.escapedMask(), vswar.escapedMask());
}

fn nextRand(s: *u64) u8 {
    s.* ^= s.* << 13;
    s.* ^= s.* >> 7;
    s.* ^= s.* << 17;
    return @truncate(s.*);
}

test "sizes 0..=300 random bytes" {
    var value: [300]u8 = undefined;
    var i: usize = 0;
    while (i <= 300) : (i += 1) {
        var s: u64 = 0x9E3779B97F4A7C15 +% @as(u64, i);
        for (value[0..i]) |*b| b.* = nextRand(&s);
        try expectMatchesOracle(value[0..i], true);
        try expectMatchesOracle(value[0..i], false);
    }
}

test "special fixtures" {
    try expectMatchesOracle("", true);
    try expectMatchesOracle("", false);
    try expectMatchesOracle("\"", true);
    try expectMatchesOracle("\\", true);
    try expectMatchesOracle("\"\\", true);
    try expectMatchesOracle("abcdefghijklmnopqrstuvwxyz .*? hello world escape json string", true);

    const mixed = "Hello \"World\"!\n\tHere\nEmoji: \xF0\x9F\x98\x80 Chinese: \xE4\xB8\xAD\xE6\x96\x87\nMath: \xE2\x88\x91\xE2\x88\xAB\xE2\x88\x82 Music: \xF0\x9D\x84\x9E\nEscape: \\\" \\\\ \\n \\r \\t";
    try expectMatchesOracle(mixed, true);
    try expectMatchesOracle(mixed, false);

    var ctrl: [32]u8 = undefined;
    for (0..32) |j| ctrl[j] = @intCast(j);
    try expectMatchesOracle(&ctrl, true);
    try expectMatchesOracle(&ctrl, false);

    var all_bytes: [256]u8 = undefined;
    for (0..256) |j| all_bytes[j] = @intCast(j);
    try expectMatchesOracle(&all_bytes, true);
    try expectMatchesOracle(&all_bytes, false);

    var nuls: [200]u8 = @splat(0);
    try expectMatchesOracle(&nuls, true);

    var quotes: [129]u8 = @splat('"');
    try expectMatchesOracle(&quotes, true);

    var slashes: [130]u8 = @splat('\\');
    try expectMatchesOracle(&slashes, true);
}

test "unaligned starts" {
    var big: [400]u8 = undefined;
    for (&big, 0..) |*b, idx| {
        b.* = switch (idx % 7) {
            0 => '"',
            1 => '\\',
            2 => '\n',
            3 => 0x00,
            4 => 'a',
            5 => 'b',
            else => 'c',
        };
    }
    for (0..33) |off| {
        const window = big[off .. off + 300];
        try expectMatchesOracle(window, true);
        try expectMatchesOracle(window, false);
    }
}

test "dispatched public API" {
    const fixtures = [_][]const u8{
        "",
        "hello",
        "hello\n",
        "\"",
        "\\",
        "\r\n",
        "0123456789abcdef",
        "0123456789abcdef0123456789abcdef",
        "Hello \"World\"!\n\tEmoji: \xF0\x9F\x98\x80 Chinese: \xE4\xB8\xAD\xE6\x96\x87",
    };

    var expected_q: [4200]u8 = undefined;
    var expected_u: [4200]u8 = undefined;
    var out: [4200]u8 = undefined;

    for (fixtures) |fixture| {
        const expected = expected_q[0..referenceEscape(fixture, true, &expected_q)];
        const got = escapeIntoSlice(&out, fixture);
        try std.testing.expectEqualSlices(u8, expected, got);

        const expected_unquoted = expected_u[0..referenceEscape(fixture, false, &expected_u)];
        const got_u = escapeIntoUnquoteSlice(&out, fixture);
        try std.testing.expectEqualSlices(u8, expected_unquoted, got_u);

        const own = try escape(std.testing.allocator, fixture);
        defer std.testing.allocator.free(own);
        try std.testing.expectEqualSlices(u8, expected, own);

        const own_u = try escapeUnquote(std.testing.allocator, fixture);
        defer std.testing.allocator.free(own_u);
        try std.testing.expectEqualSlices(u8, expected_unquoted, own_u);
    }
}

test "runtime fallback dispatch" {
    // `escapeInto` only takes `escapeIntoAnyBackend` when the runtime CPU probe
    // downgrades the compile-time backend, which never happens on a host that
    // matches its build target. Exercise that path directly so it cannot rot.
    const fixtures = [_][]const u8{
        "",
        "hello",
        "hello\n",
        "\"",
        "\\",
        "\r\n",
        "0123456789abcdef",
        "0123456789abcdef0123456789abcdef",
        "Hello \"World\"!\n\tEmoji: \xF0\x9F\x98\x80 Chinese: \xE4\xB8\xAD\xE6\x96\x87",
    };

    var expected_q: [4200]u8 = undefined;
    var expected_u: [4200]u8 = undefined;
    var out: [4200]u8 = undefined;

    for (fixtures) |fixture| {
        const expected = expected_q[0..referenceEscape(fixture, true, &expected_q)];
        const end_q = escapeIntoAnyBackend(&out, fixture);
        try std.testing.expectEqualSlices(u8, expected, out[0 .. @intFromPtr(end_q) - @intFromPtr(&out)]);

        const expected_unquoted = expected_u[0..referenceEscape(fixture, false, &expected_u)];
        const end_u = escapeIntoAnyBackendUnquote(&out, fixture);
        try std.testing.expectEqualSlices(u8, expected_unquoted, out[0 .. @intFromPtr(end_u) - @intFromPtr(&out)]);
    }
}

test "activeBackend sanity" {
    switch (activeBackend()) {
        .sse2, .neon, .avx2, .avx512, .swar => {},
    }
    if (comptime builtin.cpu.arch == .x86_64) {
        try std.testing.expect(activeBackend() != .neon);
    }
    // When the compile target is a native x86 machine whose tier we detected,
    // the runtime check must agree (baseline builds may downgrade to SWAR).
    if (comptime selected_backend == .avx2 and builtin.cpu.arch == .x86_64) {
        try std.testing.expectEqual(Backend.avx2, activeBackend());
    }
    if (comptime selected_backend == .neon) {
        try std.testing.expectEqual(Backend.neon, activeBackend());
    }
}
