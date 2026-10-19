//! Host compiler entry point; absent from the installed execution dependency.
const std = @import("std");
const artifact = @import("semantic/artifact.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const compiler = @import("semantic/compiler.zig");
    const bundle = try compiler.compile(a, .{ .horos_package = @import("artifact_options").horos_package });
    var checked = try artifact.Admitted.init(a, bundle, artifact.digest(bundle));
    defer checked.deinit();
    try compiler.validate(a, &checked);
    var buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(bundle);
    try output.interface.flush();
}
