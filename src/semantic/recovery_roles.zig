const std = @import("std");
const source = @import("horos_recovery").source;
const compiler = @import("compiler.zig");
const artifact = @import("artifact.zig");
const role = compiler.SourceRole;
const Allocator = std.mem.Allocator;
const Id = u64;
const Function = source.specialize.FunctionProof;
const Binding = source.RecoveryBinding;

pub fn selected(
    a: Allocator,
    definition: *const compiler.SourceDefinition,
    functions: []const Function,
) ![]const role {
    const s = definition.service;
    const clone = definition.clone;
    const roots = [_]role{
        .{ .function = s.loop, .role = .published_service, .ordinals = &.{1} },
        .{ .function = s.dispatch, .role = .committed_service, .ordinals = &.{1} },
        .{ .function = s.publish, .role = .committed_service, .ordinals = &.{1} },
        .{ .function = s.publish, .role = .committed_service, .ordinals = &.{2} },
        .{ .function = s.commit, .role = .committed_machine, .ordinals = &.{0} },
        .{ .function = s.control_commit, .role = .committed_machine, .ordinals = &.{0} },
        .{ .function = s.cut, .role = .committed_machine, .ordinals = &.{0} },
        .{ .function = clone.run, .role = .clone_context, .ordinals = &.{ 0, 1 } },
        .{ .function = clone.rebase, .role = .clone_rebase, .ordinals = &.{ 0, 1, 2, 3 } },
    };
    var result: std.ArrayList(role) = .empty;
    for (roots) |root| {
        try result.append(a, root);
        for (functions) |f| if (f.before == root.function) {
            const ordinals = try a.alloc(u32, root.ordinals.len);
            for (root.ordinals, ordinals) |original, *ordinal| {
                if (f.arguments[original] == .known) break;
                ordinal.* = 0;
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

pub fn formals(a: Allocator, roles: []const role) ![]const source.recovery_optimization.Formal {
    var result: std.ArrayList(source.recovery_optimization.Formal) = .empty;
    for (roles) |r| for (r.ordinals) |ordinal| {
        try result.append(a, .{ .function = r.function, .ordinal = ordinal });
    };
    return result.items;
}

pub fn anchors(
    a: Allocator,
    roles: []const role,
    module: source.Module,
    parameters: []const Binding,
) ![]const artifact.Anchor {
    var result: std.ArrayList(artifact.Anchor) = .empty;
    for (roles) |r| {
        const vars = module.functions[@intCast(r.function)].parameters;
        const fields = try a.alloc(artifact.Parameter, r.ordinals.len);
        var final: ?Id = null;
        for (r.ordinals, fields, 0..) |ordinal, *field, index| {
            if (ordinal >= vars.len) return error.InvalidRecovery;
            for (parameters) |binding| {
                if (binding.source_function != r.function or
                    binding.variable != vars[ordinal]) continue;
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
) ![]const Id {
    var result: std.ArrayList(Id) = .empty;
    for (parameters) |binding| {
        var matches = binding.source_function == original;
        for (functions) |f| {
            if (f.before == original and f.after == binding.source_function) matches = true;
        }
        if (matches and std.mem.indexOfScalar(Id, result.items, binding.function) == null)
            try result.append(a, binding.function);
    }
    return result.items;
}
