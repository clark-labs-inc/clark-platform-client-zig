const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public library module, importable as `clark_platform`.
    const mod = b.addModule("clark_platform", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests for the library module (mock HTTP server, no real network).
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests against a local mock server");
    test_step.dependOn(&run_mod_tests.step);

    // Opt-in live smoke test against a real Clark deployment. Reads
    // CLARK_API_BASE_URL / CLARK_API_KEY / CLARK_TEST_MODEL from the
    // environment; does not run as part of `zig build` or `zig build test`.
    const live_smoke = b.addExecutable(.{
        .name = "live-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/live_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clark_platform", .module = mod },
            },
        }),
    });
    b.installArtifact(live_smoke);

    const run_live_smoke = b.addRunArtifact(live_smoke);
    run_live_smoke.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_live_smoke.addArgs(args);

    const live_smoke_step = b.step("live-smoke", "Run the opt-in live smoke test against a real Clark deployment");
    live_smoke_step.dependOn(&run_live_smoke.step);
}
