const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "qbe-zig",
        .root_module = b.addModule("libqbe", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);

    // Add the C driver API
    lib.root_module.addCSourceFile(.{
        .language = .c,
        .file = b.path("src/shim.c"),
        .flags = &.{},
    });

    // Add all QBE C sources (excluding main.c)
    try collect_files(b, lib, ".");
    try collect_files(b, lib, "amd64");
    try collect_files(b, lib, "arm64");
    try collect_files(b, lib, "rv64");

    const mod_tests = b.addTest(.{
        .root_module = lib.root_module,
        .use_lld = true,
        .use_llvm = true,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const exe = b.addExecutable(.{
        .name = "qbe-zig-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lib", .module = lib.root_module },
            },
        }),
        .use_lld = true,
        .use_llvm = true,
    });
    b.installArtifact(exe);
}

fn collect_files(b: *std.Build, lib: *std.Build.Step.Compile, sub_path: []const u8) !void {
    const qbe_dep = b.dependency("qbe", .{});
    const qbe_root_dir = try qbe_dep.builder.build_root.handle.openDir(b.graph.io, sub_path, .{ .iterate = true });
    defer qbe_root_dir.close(b.graph.io);
    var iter = qbe_root_dir.iterate();
    while (try iter.next(b.graph.io)) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.name, ".c") or
            std.mem.eql(u8, entry.name, "main.c"))
        {
            continue;
        }
        lib.root_module.addCSourceFile(.{
            .language = .c,
            .file = qbe_dep.path(b.pathJoin(&.{ sub_path, entry.name })),
            .flags = &.{},
        });
    }
    lib.root_module.addIncludePath(qbe_dep.path(sub_path));
}
