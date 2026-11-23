const std = @import("std");
const ordinary = @import("kosmos");
const checked = @import("kosmos_recovery");

comptime {
    for (std.meta.declarations(ordinary)) |name| {
        if (std.mem.eql(u8, name, "RuntimeCompiler")) continue;
        if (@field(ordinary, name) != @field(checked, name)) @compileError(name);
    }
    const validate = @typeInfo(@TypeOf(checked.RuntimeCompiler.validate)).@"fn";
    if (ordinary.RuntimeCompiler.SourceModule != checked.RuntimeCompiler.SourceModule or
        validate.param_types[1] != *const ordinary.RuntimeArtifact or
        !@hasDecl(checked.RuntimeCompiler, "exportRecoverySource"))
        @compileError("incompatible recovery compiler");
}

test "checked generic source compiles, validates and exports through ordinary admission" {
    const a = std.testing.allocator;
    const compiler = checked.RuntimeCompiler;
    const bytes = try compiler.compile(a, .{ .scalar_field_reuse = true });
    defer a.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var admitted = try ordinary.RuntimeArtifact.init(a, bytes, digest);
    defer admitted.deinit();
    try compiler.validate(a, &admitted);
    var source = try compiler.exportRecoverySource(a, &admitted);
    defer source.deinit();
    try std.testing.expectEqual(digest, source.value.realization);
    try std.testing.expect(source.value.guest == null);
    try std.testing.expect(source.value.selected.module.functions.len > 0);
}
