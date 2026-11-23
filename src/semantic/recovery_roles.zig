const std = @import("std");
const runtime = @import("../runtime_sources.zig");
const source = @import("horos_recovery").source;
const compiler = runtime.compiler;
const artifact = runtime.artifact;
const role = compiler.SourceRole;
const Allocator = std.mem.Allocator;
const Id = u64;
const Function = source.specialize.FunctionProof;
const Binding = source.RecoveryBinding;
const spend = @import("horos_recovery").data.admission.spend;

pub const Roots = @FieldType(compiler.SourceBundle, "generic_roles");

pub fn roots(
    a: Allocator,
    storage: Allocator,
    definition: *const compiler.SourceDefinition,
) !Roots {
    const packaged = runtime.packaged;
    var identity: artifact.Digest = undefined;
    _ = try std.fmt.hexToBytes(&identity, packaged.artifact_sha256);
    var retained = try artifact.Admitted.init(a, packaged.bytes, identity);
    defer retained.deinit();
    var ordinary = try compiler.exportBuiltinSource(a, &retained);
    defer ordinary.deinit();
    var result = try copyRoots(storage, ordinary.value.generic_roles);
    for (&result) |*entry| entry.function = try reboundFunction(
        &ordinary.definition,
        definition,
        entry.function,
    );
    return result;
}

pub fn copyRoots(storage: Allocator, original: Roots) !Roots {
    var result = original;
    for (&result) |*entry| entry.ordinals = try storage.dupe(u32, entry.ordinals);
    return result;
}

fn reboundFunction(
    ordinary: *const compiler.SourceDefinition,
    selected_definition: *const compiler.SourceDefinition,
    original: Id,
) !Id {
    var rebound: ?Id = null;
    inline for (.{
        .{ "service", .{
            "entry", "loop", "dispatch", "advance", "commit", "control_commit", "publish", "cut",
        } },
        .{ "clone", .{ "instantiate", "run", "rebase" } },
    }) |group| {
        inline for (group[1]) |name| {
            if (@field(@field(ordinary, group[0]), name) == original) {
                const mapped = @field(@field(selected_definition, group[0]), name);
                if (rebound != null and rebound.? != mapped) return error.InvalidRecovery;
                rebound = mapped;
            }
        }
    }
    return rebound orelse error.InvalidRecovery;
}

pub fn selected(
    a: Allocator,
    root_roles: Roots,
    functions: anytype,
    work: *u64,
) ![]const role {
    var result: std.ArrayList(role) = .empty;
    try spend(work, root_roles.len);
    for (root_roles) |root| {
        try spend(work, functions.len);
        try result.append(a, root);
        for (functions) |f| if (f.before == root.function) {
            try spend(work, root.ordinals.len);
            const ordinals = try a.alloc(u32, root.ordinals.len);
            for (root.ordinals, ordinals) |original, *ordinal| {
                if (original >= f.arguments.len) return error.InvalidRecovery;
                if (f.arguments[original] == .known) break;
                ordinal.* = 0;
                try spend(work, original);
                for (f.arguments[0..original]) |arg| ordinal.* += @intFromBool(arg != .known);
            } else try result.append(a, .{
                .function = f.after,
                .role = root.role,
                .ordinals = ordinals,
            });
        };
    }
    return result.items;
}

pub fn formals(
    a: Allocator,
    roles: []const role,
    work: *u64,
) ![]const source.recovery_optimization.Formal {
    var result: std.ArrayList(source.recovery_optimization.Formal) = .empty;
    try spend(work, roles.len);
    for (roles) |r| {
        try spend(work, r.ordinals.len);
        for (r.ordinals) |ordinal|
            try result.append(a, .{ .function = r.function, .ordinal = ordinal });
    }
    return result.items;
}

pub fn anchors(
    a: Allocator,
    roles: []const role,
    module: source.Module,
    parameters: []const Binding,
    work: *u64,
) ![]const artifact.Anchor {
    try spend(work, module.functions.len);
    try spend(work, parameters.len);
    const heads = try a.alloc(?usize, module.functions.len);
    @memset(heads, null);
    const next = try a.alloc(?usize, parameters.len);
    for (0..parameters.len) |reverse| {
        const i = parameters.len - 1 - reverse;
        const f = parameters[i].source_function;
        if (f >= heads.len) return error.InvalidRecovery;
        next[i] = heads[@intCast(f)];
        heads[@intCast(f)] = i;
    }
    var result: std.ArrayList(artifact.Anchor) = .empty;
    try spend(work, roles.len);
    for (roles) |r| {
        if (r.function >= heads.len) return error.InvalidRecovery;
        try spend(work, r.ordinals.len);
        const vars = module.functions[@intCast(r.function)].parameters;
        const fields = try a.alloc(artifact.Parameter, r.ordinals.len);
        var final: ?Id = null;
        for (r.ordinals, fields, 0..) |ordinal, *field, index| {
            if (ordinal >= vars.len) return error.InvalidRecovery;
            var cursor = heads[@intCast(r.function)];
            while (cursor) |i| : (cursor = next[i]) {
                try spend(work, 1);
                const binding = parameters[i];
                if (binding.variable != vars[ordinal]) continue;
                if (final != null and final != binding.function) return error.InvalidRecovery;
                final = binding.function;
                field.* = .{ .ordinal = index, .slot = binding.slot, .schema = binding.schema };
                break;
            } else break;
        } else try result.append(a, .{
            .function = final orelse return error.InvalidRecovery,
            .role = r.role,
            .parameters = fields,
        });
    }
    return result.items;
}

pub fn functionMap(
    a: Allocator,
    original: Id,
    functions: []const Function,
    parameters: []const Binding,
    source_count: usize,
    target_count: usize,
    work: *u64,
) ![]const Id {
    try spend(work, source_count);
    try spend(work, target_count);
    try spend(work, functions.len);
    try spend(work, parameters.len);
    const matches = try a.alloc(bool, source_count);
    @memset(matches, false);
    if (original >= matches.len) return error.InvalidRecovery;
    matches[@intCast(original)] = true;
    for (functions) |f| if (f.before == original) {
        if (f.after >= matches.len) return error.InvalidRecovery;
        matches[@intCast(f.after)] = true;
    };
    const seen = try a.alloc(bool, target_count);
    @memset(seen, false);
    var result: std.ArrayList(Id) = .empty;
    for (parameters) |binding| {
        if (binding.source_function >= matches.len or binding.function >= seen.len)
            return error.InvalidRecovery;
        if (!matches[@intCast(binding.source_function)] or seen[@intCast(binding.function)])
            continue;
        seen[@intCast(binding.function)] = true;
        try result.append(a, binding.function);
    }
    return result.items;
}
