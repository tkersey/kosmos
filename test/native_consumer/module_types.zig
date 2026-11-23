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
