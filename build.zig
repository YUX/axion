const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Module: axion ---
    const mod = b.addModule("axion", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addCSourceFile(.{ .file = b.path("src/c/lz4.c"), .flags = &.{"-O3"} });
    mod.addIncludePath(b.path("src/c"));

    // --- Executable: axion (CLI) ---
    const exe = b.addExecutable(.{
        .name = "axion",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "axion", .module = mod },
            },
        }),
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---
    const test_step = b.step("test", "Run all tests");

    // 1. Unit tests for main module
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.linkLibC();
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // 2. Unit tests for CLI executable
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.linkLibC();
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // 3. Integration Tests (src/tests/*.zig)
    const integration_tests = [_][]const u8{
        "src/tests/test_vtab_schema.zig",
        "src/tests/test_index_maintenance.zig",
        "src/tests/test_index_query.zig",
        "src/tests/test_savepoints.zig",
        "src/tests/test_operational_tooling.zig",
    };

    for (integration_tests) |test_path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "axion", .module = mod },
                },
            }),
        });
        t.linkLibC();
        t.linkSystemLibrary("sqlite3");
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // --- Benchmarks ---
    // Helper to create benchmark executables
    const benchmarks = [_]struct { name: []const u8, path: []const u8, link_sqlite: bool }{
        .{ .name = "bench_native_axion", .path = "src/bench/bench_native_axion.zig", .link_sqlite = false },
        .{ .name = "bench_native_sqlite", .path = "src/bench/bench_native_sqlite.zig", .link_sqlite = true },
        .{ .name = "bench_vtab_axion", .path = "src/bench/bench_vtab_axion.zig", .link_sqlite = true },
    };

    for (benchmarks) |bench| {
        const bench_exe = b.addExecutable(.{
            .name = bench.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(bench.path),
                .target = target,
                .optimize = optimize,
                .imports = if (std.mem.eql(u8, bench.name, "bench_native_sqlite")) &.{} else &.{
                    .{ .name = "axion", .module = mod },
                },
            }),
        });
        bench_exe.linkLibC();
        if (bench.link_sqlite) {
            bench_exe.linkSystemLibrary("sqlite3");
        }
        b.installArtifact(bench_exe);

        const run_bench = b.addRunArtifact(bench_exe);
        if (b.args) |args| {
            run_bench.addArgs(args);
        }
        const bench_step = b.step(bench.name, b.fmt("Run {s}", .{bench.name}));
        bench_step.dependOn(&run_bench.step);
    }

    // --- Tools ---
    // Verify Scan Tool
    const verify_scan = b.addExecutable(.{
        .name = "verify_scan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/verify_scan.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "axion", .module = mod },
            },
        }),
    });
    verify_scan.linkLibC();
    verify_scan.linkSystemLibrary("sqlite3");
    b.installArtifact(verify_scan);

    const verify_scan_step = b.step("verify_scan", "Run Verification Tool");
    verify_scan_step.dependOn(&b.addRunArtifact(verify_scan).step);

    // Axion Shell (CLI Tool)
    const axion_shell = b.addExecutable(.{
        .name = "axion_shell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/shell.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "axion", .module = mod },
            },
        }),
    });
    axion_shell.linkLibC();
    axion_shell.linkSystemLibrary("sqlite3");
    b.installArtifact(axion_shell);

    const run_shell = b.addRunArtifact(axion_shell);
    if (b.args) |args| {
        run_shell.addArgs(args);
    }
    const shell_step = b.step("shell", "Run Axion-SQLite Shell");
    shell_step.dependOn(&run_shell.step);

    // --- Shared Library ---
    const lib_axion = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "axion",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib_axion.linkLibC();
    lib_axion.linkSystemLibrary("sqlite3");
    lib_axion.addCSourceFile(.{ .file = b.path("src/c/lz4.c"), .flags = &.{"-O3"} });
    lib_axion.addIncludePath(b.path("src/c"));
    b.installArtifact(lib_axion);
}
