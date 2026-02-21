const std = @import("std");

const Renderer = enum { opengl, metal };

const FontBackend = enum { freetype, fontconfig_freetype, coretext };

const Platform = struct {
    root_source_file: ?std.Build.LazyPath,
    renderer: Renderer,
    font_backend: FontBackend,
    system_libs: []const []const u8,
    lib_only: bool,

    fn fromOS(os: std.Target.Os.Tag, b: *std.Build) Platform {
        return switch (os) {
            .linux => .{
                .root_source_file = b.path("src/platform/linux.zig"),
                .renderer = .opengl,
                .font_backend = .fontconfig_freetype,
                .system_libs = &.{"glfw3"},
                .lib_only = false,
            },
            .windows => .{
                .root_source_file = b.path("src/platform/windows.zig"),
                .renderer = .opengl,
                .font_backend = .fontconfig_freetype,
                .system_libs = &.{ "opengl32", "gdi32", "user32" },
                .lib_only = false,
            },
            .macos => .{
                .root_source_file = null,
                .renderer = .metal,
                .font_backend = .coretext,
                .system_libs = &.{},
                .lib_only = true,
            },
            else => @panic("unsupported target OS"),
        };
    }
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const platform = Platform.fromOS(os, b);

    // Build libghostty with platform-appropriate renderer.
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"app-runtime" = .none,
        .renderer = platform.renderer,
        .@"font-backend" = platform.font_backend,
        .sentry = false,
        .i18n = false,
    });
    const ghostty_lib = ghostty_dep.artifact("ghostty");

    // Pre-built Rust staticlib for manifest/config parsing.
    // Built by `cargo build` in ../config before zig build runs (see justfile).
    const config_lib_path = b.option(
        []const u8,
        "config-lib",
        "Path to the pre-built libtrolley_config.a",
    );

    if (platform.lib_only) {
        // macOS: only install libghostty.a and headers for the Swift build.
        b.installArtifact(ghostty_lib);
        return;
    }

    // Zig-based platforms: build the trolley executable.
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run unit tests");

    const exe_mod = b.createModule(.{
        .root_source_file = platform.root_source_file.?,
        .target = target,
        .optimize = optimize,
    });
    exe_mod.link_libc = true;
    exe_mod.link_libcpp = true;

    for (platform.system_libs) |lib| {
        exe_mod.linkSystemLibrary(lib, .{});
    }

    if (os == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |dep| {
            exe_mod.addImport("win32", dep.module("win32"));
        }
    }

    exe_mod.addImport("common", b.createModule(.{
        .root_source_file = b.path("src/common.zig"),
        .target = target,
        .optimize = optimize,
    }));

    exe_mod.addIncludePath(ghostty_dep.path("include"));
    exe_mod.linkLibrary(ghostty_lib);

    // Link the config staticlib (manifest parsing).
    exe_mod.addIncludePath(b.path("../config/include"));
    if (config_lib_path) |lib_path| {
        exe_mod.addObjectFile(.{ .cwd_relative = lib_path });
    }

    const exe = b.addExecutable(.{
        .name = "trolley",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // Test
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);
}
