const std = @import("std");
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const dependency = b.dependency("kosmos", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "kosmos", .module = dependency.module("kosmos") }} });
    module.addAnonymousImport("image", .{ .root_source_file = b.option(std.Build.LazyPath, "image", "Existing independently emitted program") orelse @panic("provide -Dimage") });
    const executable = b.addExecutable(.{ .name = "kosmos-native-consumer", .root_module = module });
    const run = b.addRunArtifact(executable);
    run.has_side_effects = true;
    b.getInstallStep().dependOn(&run.step);
}
