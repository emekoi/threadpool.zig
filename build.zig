const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("threadpool", "src/index.zig");
    lib.addPackagePath("deque", "deque.zig/src/deque.zig");
    lib.setBuildMode(mode);

    var main_tests = b.addTest("src/threadpool.zig");
    main_tests.addPackagePath("deque", "deque.zig/src/deque.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "run library tests");
    test_step.dependOn(&main_tests.step);

    b.default_step.dependOn(&lib.step);
    b.installArtifact(lib);
}
