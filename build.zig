const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ++++++++++++++++++++++++++++++++++++++++++++
    // Dependencies
    // ++++++++++++++++++++++++++++++++++++++++++++

    const zbor_dep = b.dependency("zbor", .{
        .target = target,
        .optimize = optimize,
    });
    const zbor_module = zbor_dep.module("zbor");

    const hidapi_dep = b.dependency("hidapi", .{
        .target = target,
        .optimize = optimize,
    });

    // ++++++++++++++++++++++++++++++++++++++++++++
    // Module
    // ++++++++++++++++++++++++++++++++++++++++++++

    // Authenticator Module
    // ------------------------------------------------

    const keylib_module = b.addModule("keylib", .{
        .source_file = .{ .path = "lib/main.zig" },
        .dependencies = &.{
            .{ .name = "zbor", .module = zbor_module },
        },
    });
    try b.modules.put(b.dupe("keylib"), keylib_module);

    const uhid_module = b.addModule("uhid", .{
        .source_file = .{ .path = "bindings/linux/src/uhid.zig" },
        .dependencies = &.{},
    });
    try b.modules.put(b.dupe("uhid"), uhid_module);

    // Re-export zbor module
    try b.modules.put(b.dupe("zbor"), zbor_module);

    // Client Module
    // ------------------------------------------------

    const client_module = b.addModule("clientlib", .{
        .source_file = .{ .path = "lib/client.zig" },
        .dependencies = &.{
            .{ .name = "zbor", .module = zbor_module },
        },
    });
    try b.modules.put(b.dupe("clientlib"), client_module);

    // Examples
    // ------------------------------------------------

    var client_example = b.addExecutable(.{
        .name = "client",
        .root_source_file = .{ .path = "example/client.zig" },
        .target = target,
        .optimize = optimize,
    });
    client_example.addModule("client", client_module);
    client_example.linkLibrary(hidapi_dep.artifact("hidapi"));

    const client_example_step = b.step("client-example", "Build the client application example");
    client_example_step.dependOn(&b.addInstallArtifact(client_example, .{}).step);

    var authenticator_example = b.addExecutable(.{
        .name = "authenticator",
        .root_source_file = .{ .path = "example/authenticator.zig" },
        .target = target,
        .optimize = optimize,
    });
    authenticator_example.addModule("keylib", keylib_module);
    authenticator_example.addModule("uhid", uhid_module);
    authenticator_example.addModule("zbor", zbor_dep.module("zbor"));
    authenticator_example.linkLibC();

    const authenticator_example_step = b.step("auth-example", "Build the authenticator example");
    authenticator_example_step.dependOn(&b.addInstallArtifact(authenticator_example, .{}).step);

    // C bindings
    // ------------------------------------------------

    const c_bindings = b.addStaticLibrary(.{
        .name = "keylib",
        .root_source_file = .{ .path = "bindings/c/src/keylib.zig" },
        .target = target,
        .optimize = optimize,
    });
    c_bindings.addModule("keylib", keylib_module);
    c_bindings.linkLibC();
    c_bindings.installHeadersDirectoryOptions(.{
        .source_dir = std.Build.LazyPath{ .path = "bindings/c/include" },
        .install_dir = .header,
        .install_subdir = "keylib",
        .exclude_extensions = &.{".c"},
    });
    b.installArtifact(c_bindings);

    const uhid = b.addStaticLibrary(.{
        .name = "uhid",
        .root_source_file = .{ .path = "bindings/linux/src/uhid-c.zig" },
        .target = target,
        .optimize = optimize,
    });
    uhid.linkLibC();
    uhid.installHeadersDirectoryOptions(.{
        .source_dir = std.Build.LazyPath{ .path = "bindings/linux/include" },
        .install_dir = .header,
        .install_subdir = "keylib",
        .exclude_extensions = &.{".c"},
    });
    b.installArtifact(uhid);

    // Python bindings
    // ------------------------------------------------

    // TODO: Figure out how to compile the cython code myself

    //const generate_uhid_bindings = b.addSystemCommand(
    //    &[_][]const u8{ "cython3", "bindings/python/uhidmodule.pyx", "-I", "bindings/linux/include", "-o", "bindings/python/uhidmodule.c", "-3" },
    //);

    //const uhid_py = b.addSharedLibrary(.{
    //    .name = "uhid.linux",
    //    .root_source_file = .{ .path = "bindings/python/uhidmodule.c" },
    //    .target = target,
    //    .optimize = optimize,
    //});
    //uhid_py.step.dependOn(&generate_uhid_bindings.step);
    //uhid_py.linkLibrary(uhid);
    //uhid_py.linkSystemLibrary("python3");
    //uhid_py.linkLibC();
    //b.installArtifact(uhid_py);

    //const build_python_bindings_step = b.step("uhid-py", "Build uhid python bindings");
    //build_python_bindings_step.dependOn(&uhid_py.step);

    // ++++++++++++++++++++++++++++++++++++++++++++
    // Tests
    // ++++++++++++++++++++++++++++++++++++++++++++

    // Creates a step for unit testing.
    const lib_tests = b.addTest(.{
        .root_source_file = .{ .path = "lib/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib_tests.addModule("zbor", zbor_module);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}
