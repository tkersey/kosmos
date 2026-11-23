const std = @import("std");
const horos = @import("horos");
const data = horos.data;
const compiler = @import("root.zig").RuntimeCompiler;
const legacy = @import("semantic/compiler.zig");
const artifact = @import("semantic/artifact.zig");
const packaged = @import("semantic_packaged.zig");
const a = std.testing.allocator;

fn checkSource(exported: anytype, candidate: *const artifact.Admitted) !void {
    const v = exported.value;
    const bundle = candidate.content.value;
    try std.testing.expect(exported.retained.core != candidate.core);
    try std.testing.expectEqual(candidate.identity, v.realization);
    try std.testing.expectEqual(bundle.manifest.image, v.image);
    try std.testing.expectEqual(bundle.manifest.source, v.emitter);
    try std.testing.expectEqual(bundle.guest, v.guest);
    try std.testing.expectEqual(v.selected.module.entry, v.selected_entries.service);
    try std.testing.expectEqual(v.generic.module.entry, v.generic_entries.service);
    try std.testing.expectEqual(
        (try compiler.sourceModule(exported.definition.module())).digest,
        v.generic.digest,
    );
    for (v.helpers, candidate.helpers, exported.definition.helpers) |helper, image, entry| {
        try std.testing.expectEqual(image.identity(), helper.image);
        try std.testing.expectEqual(entry, helper.source.module.entry);
        try std.testing.expectEqual(
            (try compiler.sourceModule(exported.definition.builder.module(
                entry,
                exported.definition.failure,
            ))).digest,
            helper.source.digest,
        );
    }
    for (v.generic_pure_entries) |entry| try std.testing.expect(data.record.equal(
        horos.source.ast.Function,
        v.generic.module.functions[entry.function],
        entry.signature,
    ));
    try std.testing.expect(data.record.equal(
        []const artifact.Anchor,
        bundle.recovery.anchors,
        v.anchors,
    ));
    try std.testing.expectEqualSlices(u64, bundle.branch_returns, v.branch_returns);
    try std.testing.expectEqualSlices(u64, bundle.template_entries, v.template_entries);
    try checkBindings(v.selected.module, v.parameters, candidate.program.program());
    if (v.evidence.derivation) |d| {
        try std.testing.expect(v.guest != null);
        const digest = (try compiler.sourceModule(d.residual)).digest;
        try std.testing.expectEqual(digest, v.selected.digest);
        try std.testing.expect(!std.mem.eql(u8, &v.selected.digest, &v.generic.digest));
    } else try std.testing.expectEqual(v.generic.digest, v.selected.digest);
}

fn checkRecoveryExport(candidate: *const artifact.Admitted) !void {
    var exported: compiler.ExportedRecoverySource = try compiler.exportRecoverySource(a, candidate);
    defer exported.deinit();
    try checkSource(&exported, candidate);
    if (exported.value.evidence.derivation) |d| {
        try std.testing.expect(data.record.overlaps(
            []const u8,
            d.request.arguments[0].known.bytes,
            exported.retained.content.value.evidence,
        ));
    }
    const proof = exported.value.evidence.recovery;
    try std.testing.expect(!@import("horos_recovery").data.record.overlaps(
        @TypeOf(proof),
        proof,
        candidate.content.value.evidence,
    ));
    try std.testing.expectEqual(proof.rule == .structural_fallback, proof.witnesses.len == 0);
}

fn checkBindings(
    module: horos.source.Module,
    parameters: []const horos.source.RecoveryBinding,
    program: data.activation.Program,
) !void {
    try std.testing.expect(parameters.len != 0);
    for (parameters) |binding| {
        const formals = module.functions[binding.source_function].parameters;
        try std.testing.expect(std.mem.indexOfScalar(u64, formals, binding.variable) != null);
        try std.testing.expectEqual(module.variables[binding.variable], binding.source_schema);
        const function = program.functions[binding.function];
        try std.testing.expectEqual(function.layout.slots[binding.slot], binding.schema);
    }
}

fn checkLegacyExport(exported: *const compiler.ExportedSource) !void {
    const bundle: compiler.SourceBundle = exported.value;
    const evidence: compiler.Evidence = bundle.evidence;
    const roles = @import("semantic/recovery_roles.zig");
    const Function = @import("horos_recovery").source.specialize.FunctionProof;
    var work = compiler.recovery_limits.source_work;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const protected = try roles.selected(
        arena.allocator(),
        &exported.definition,
        @as([]const Function, &.{}),
        &work,
    );
    try std.testing.expect(data.record.equal(
        []const legacy.SourceRole,
        &bundle.generic_roles,
        protected,
    ));
    const bindings = try horos.source.recovery.parameters(
        a,
        bundle.selected.module,
        exported.retained.program.program(),
        evidence.recovery,
    );
    defer a.free(bindings);
    try std.testing.expect(data.record.equal(
        []const horos.source.RecoveryBinding,
        bindings,
        bundle.parameters,
    ));
}

test "public checked source export preserves ordinary compiler types and lowering evidence" {
    try std.testing.expect(legacy.SourceBundle == compiler.SourceBundle);
    try std.testing.expect(legacy.ExportedSource == compiler.ExportedSource);
    try std.testing.expect(legacy.Evidence == compiler.Evidence);
    try std.testing.expect(@TypeOf(legacy.exportSource) == @TypeOf(compiler.exportSource));
    const BuiltinExporter = @TypeOf(legacy.exportBuiltinSource);
    try std.testing.expect(BuiltinExporter == @TypeOf(compiler.exportBuiltinSource));
    var ordinary = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer ordinary.deinit();
    inline for (.{ compiler.exportSource, compiler.exportBuiltinSource }) |exporter| {
        var result: compiler.ExportedSource = try exporter(a, &ordinary);
        defer result.deinit();
        try checkSource(&result, &ordinary);
        try checkLegacyExport(&result);
    }
}

test "public checked source export retains builtin and specialized recovery source" {
    var ordinary = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer ordinary.deinit();
    const image = try @import("semantic/test_support.zig").guestImage();
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    for ([_]?*const data.program_image.Admitted{ null, guest }) |selection| {
        const bytes = try compiler.compile(a, .{
            .horos_package = packaged.horos_package,
            .scalar_field_reuse = true,
            .guest = selection,
        });
        defer a.free(bytes);
        var candidate = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
        defer candidate.deinit();
        var independent = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
        defer independent.deinit();
        try compiler.validateAgainst(a, &candidate, &independent);
        try std.testing.expectError(error.InvalidAncestor, compiler.validateAgainst(
            a,
            &candidate,
            &ordinary,
        ));
        try checkRecoveryExport(&candidate);
    }
}

test "admitted guest program records transfer within explicit work and storage allowances" {
    const records = @import("semantic/recovery_records.zig");
    const image = try @import("semantic/test_support.zig").guestImage();
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    const limits = compiler.recovery_limits;
    var work = limits.source_work;
    const program = try records.targetProgram(storage, guest, limits.lowering_bytes, &work);
    try records.checkProgram(guest, program);
    var exact = limits.source_work - work;
    _ = try records.targetProgram(storage, guest, limits.lowering_bytes, &exact);
    try std.testing.expectEqual(0, exact);
    work = limits.source_work;
    try std.testing.expectError(error.Capacity, records.targetProgram(storage, guest, 0, &work));
    try std.testing.expectError(error.RelationLimit, records.targetProgram(
        storage,
        guest,
        limits.lowering_bytes,
        &exact,
    ));
}

test "recovery function map preserves the first binding order of specialized functions" {
    const source = @import("horos_recovery").source;
    const roles = @import("semantic/recovery_roles.zig");
    const functions = [_]source.specialize.FunctionProof{
        .{ .before = 1, .after = 3, .arguments = &.{} },
        .{ .before = 0, .after = 4, .arguments = &.{} },
    };
    var bindings: [4]source.RecoveryBinding = undefined;
    for (&bindings, [_]u64{ 3, 4, 1, 3 }, [_]u64{ 2, 0, 1, 2 }) |*binding, before, after| {
        binding.* = .{
            .source_function = before,
            .function = after,
            .variable = 0,
            .source_schema = 0,
            .slot = 0,
            .schema = 0,
        };
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var work: u64 = 5 + 3 + functions.len + bindings.len;
    const map = try roles.functionMap(arena.allocator(), 1, &functions, &bindings, 5, 3, &work);
    try std.testing.expectEqualSlices(u64, &.{ 2, 1 }, map);
    try std.testing.expectEqual(0, work);
}
