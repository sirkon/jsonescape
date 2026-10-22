const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("jsonescape", .{
        .root_source_file = b.path("src/json_escape.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // Benchmark against the Rust reference. The benchmark module is always
    // optimized, regardless of the top-level `-Doptimize`.
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimization mode for the benchmark (default: fast)",
    ) orelse .fast;

    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/json_escape.zig"),
        .target = target,
        .optimize = bench_optimize,
    });

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/zig/main.zig"),
            .target = target,
            .optimize = bench_optimize,
        }),
    });
    bench.root_module.addImport("jsonescape", bench_module);

    const install_bench = b.addInstallArtifact(bench, .{});
    const run_bench = b.addRunArtifact(bench);

    const bench_build_step = b.step("bench-build", "Build the Zig benchmark into zig-out/bin");
    bench_build_step.dependOn(&install_bench.step);

    const bench_step = b.step("bench", "Build and run the Zig side of the benchmark");
    bench_step.dependOn(&install_bench.step);
    bench_step.dependOn(&run_bench.step);
}
