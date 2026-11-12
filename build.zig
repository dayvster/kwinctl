const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // the library other projects import: b.dependency("kwinctl", .{}).module("kwinctl")
    const lib = b.addModule("kwinctl", .{
        .root_source_file = b.path("src/kwinctl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "kwinctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "kwinctl", .module = lib }},
        }),
    });
    b.installArtifact(exe);

    const unit_tests_cli = b.addTest(.{ .root_module = exe.root_module });

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run kwinctl").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = lib });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(unit_tests_cli).step);
}
