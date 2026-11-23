const std = @import("std");
const horos = @import("horos");
const data = horos.data;
const compiler = @import("root.zig").RuntimeCompiler;
const artifact = @import("semantic/artifact.zig");
const packaged = @import("semantic_packaged.zig");
const a = std.testing.allocator;

fn checkExport(candidate: *const artifact.Admitted) !void {
    var exported = try compiler.exportSource(a, candidate);
    defer exported.deinit();
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
    try checkBindings(v, candidate.program.program());
    if (v.evidence.derivation) |d| {
        try std.testing.expect(v.guest != null);
        const digest = (try compiler.sourceModule(d.residual)).digest;
        try std.testing.expectEqual(digest, v.selected.digest);
        try std.testing.expect(!std.mem.eql(u8, &v.selected.digest, &v.generic.digest));
    } else try std.testing.expectEqual(v.generic.digest, v.selected.digest);
    try checkProof(&exported, candidate);
}

fn checkProof(exported: *const compiler.ExportedSource, candidate: *const artifact.Admitted) !void {
    const v = exported.value;
    const policy = candidate.content.value.manifest.compiler.policy;
    const transported = std.mem.eql(u8, policy, compiler.recovery_policy);
    switch (v.evidence.recovery) {
        .correspondence => {
            try std.testing.expect(!transported);
            const bindings = try horos.source.recovery.parameters(
                a,
                v.selected.module,
                candidate.program.program(),
                .{ .correspondence = exported.value.evidence.recovery.correspondence },
            );
            defer a.free(bindings);
            try std.testing.expect(data.record.equal(
                []const horos.source.RecoveryBinding,
                bindings,
                v.parameters,
            ));
        },
        .source_lower_3 => |proof| {
            try std.testing.expect(transported);
            const fallback = proof.rule == .structural_fallback;
            try std.testing.expectEqual(fallback, proof.witnesses.len == 0);
        },
    }
}

fn checkBindings(value: compiler.SourceBundle, program: data.activation.Program) !void {
    try std.testing.expect(value.parameters.len != 0);
    const module = value.selected.module;
    for (value.parameters) |binding| {
        const formals = module.functions[binding.source_function].parameters;
        try std.testing.expect(std.mem.indexOfScalar(u64, formals, binding.variable) != null);
        try std.testing.expectEqual(module.variables[binding.variable], binding.source_schema);
        const function = program.functions[binding.function];
        try std.testing.expectEqual(function.layout.slots[binding.slot], binding.schema);
    }
}

test "public checked source export retains builtin and specialized recovery source" {
    var ordinary = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer ordinary.deinit();
    try checkExport(&ordinary);
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
        try checkExport(&candidate);
    }
}
