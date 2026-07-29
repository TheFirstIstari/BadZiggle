const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .native },
    });

    // Release mode options: --release-fast or --release-small
    const release_fast = b.option(bool, "release-fast", "Compile with ReleaseFast optimization") orelse false;
    const release_small = b.option(bool, "release-small", "Compile with ReleaseSmall optimization") orelse false;

    const optimize = blk: {
        if (release_fast) break :blk std.builtin.OptimizeMode.ReleaseFast;
        if (release_small) break :blk std.builtin.OptimizeMode.ReleaseSmall;
        break :blk b.standardOptimizeOption(.{});
    };

    const strip = b.option(bool, "strip", "Strip debug symbols from release builds") orelse false;

    // Main executable module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "badziggle",
        .root_module = root_module,
    });

    if (strip and optimize != std.builtin.OptimizeMode.Debug) {
        root_module.strip = true;
    }

    // Add FFmpeg bindings
    root_module.linkSystemLibrary("libavformat", .{});
    root_module.linkSystemLibrary("libavcodec", .{});
    root_module.linkSystemLibrary("libavutil", .{});
    root_module.linkSystemLibrary("libswscale", .{});

    // Add optional mupdf
    if (b.option(bool, "use_mupdf", "Enable mupdf PDF support") orelse false) {
        root_module.linkSystemLibrary("mupdf", .{});
        root_module.addCMacro("HAVE_MUPDF", "1");
    }

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run badziggle");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_root_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
