const std = @import("std");
const data = @import("horos_data");
const checked = @import("horos_recovery").data;
const compiler = @import("root.zig").RuntimeCompiler;
const artifact = @import("semantic/artifact.zig");
const records = @import("semantic/recovery_records.zig");
const packaged = @import("semantic_packaged.zig");
const a = std.testing.allocator;

fn admitted(bundle: artifact.Bundle) !artifact.Admitted {
    const bytes = try artifact.encode(a, bundle);
    defer a.free(bytes);
    return artifact.Admitted.init(a, bytes, artifact.digest(bytes));
}

fn rejects(bundle: artifact.Bundle, expected: anyerror) !void {
    var actual = try admitted(bundle);
    defer actual.deinit();
    try std.testing.expectError(expected, compiler.validate(a, &actual));
}

fn checkIdentity(bundle: artifact.Bundle) !void {
    var changed = bundle;
    changed.manifest.compiler.horos_package = packaged.horos_package;
    try rejects(changed, error.UnsupportedSource);
    changed = bundle;
    changed.manifest.compiler.zig = "0.17.0";
    try rejects(changed, error.UnsupportedSource);
    changed = bundle;
    changed.manifest.source = @import("semantic/source_identity.zig").digest();
    try rejects(changed, error.UnsupportedSource);
    changed = bundle;
    changed.guest = artifact.digest("different admitted guest");
    try rejects(changed, error.InvalidRealization);
}

fn checkContext(bundle: artifact.Bundle) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var reader: checked.wire.Reader = .{ .input = bundle.evidence };
    var capacity = compiler.recovery_limits.lowering_bytes;
    var evidence = try checked.record.readBounded(
        compiler.RecoveryEvidence,
        &reader,
        arena.allocator(),
        &capacity,
    );
    try reader.finish();
    var changed = bundle;
    var submitted = evidence.derivation orelse return error.MissingDerivation;
    submitted.request.context.compiler_policy = artifact.digest(artifact.build_policy);
    evidence.derivation = submitted;
    changed.evidence = try records.encode(arena.allocator(), evidence);
    try rejects(changed, error.InvalidRealization);
}

fn checkVerifierWork(bundle: artifact.Bundle, proof: compiler.RecoveryDerivation) !void {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var definition = try compiler.SourceDefinition.init(a, true, bundle.hooks);
    defer definition.deinit();
    const original = try records.module(scratch.allocator(), definition.module());
    var work: u64 = original.functions.len + proof.functions.len +
        proof.request.arguments[0].known.bytes.len;
    inline for (.{ "schemas", "constants", "effects", "handlers", "resources" }) |name|
        work += @field(proof.residual, name).len;
    inline for (.{ "variables", "values", "terms", "functions" }) |name|
        work += @field(proof.residual, name).len;
    try std.testing.expectError(
        error.RelationLimit,
        @import("semantic/recovery_specialization.zig").validate(
            a,
            &definition,
            original,
            proof,
            bundle,
            &work,
        ),
    );
    try std.testing.expectEqual(0, work);
}

fn checkEvidenceLimits(bundle: artifact.Bundle) !void {
    const limits = compiler.recovery_limits;
    var exact: u64 = bundle.evidence.len;
    var decoded = try records.decodeEvidence(a, bundle.evidence, true, limits, &exact);
    defer decoded.deinit();
    try std.testing.expectEqual(0, exact);
    try checkVerifierWork(bundle, decoded.value.derivation.?);
    const encoded = try records.encodeEvidence(a, a, decoded.value, limits);
    defer a.free(encoded);
    try std.testing.expectEqualSlices(u8, bundle.evidence, encoded);
    var smaller = limits;
    smaller.lowering_bytes = encoded.len - 1;
    var remaining = limits.source_work;
    try std.testing.expectError(error.Capacity, records.decodeEvidence(
        a,
        bundle.evidence,
        true,
        smaller,
        &remaining,
    ));
    try std.testing.expectError(
        error.Capacity,
        records.encodeEvidence(a, a, decoded.value, smaller),
    );
}

test "specialized scalar recovery binds the guest compiler package and residual context" {
    const image = try @import("semantic/test_support.zig").guestImage();
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    const bytes = try compiler.compile(a, .{
        .horos_package = packaged.horos_package,
        .guest = guest,
        .scalar_field_reuse = true,
    });
    defer a.free(bytes);
    var candidate = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer candidate.deinit();
    try compiler.validateAgainst(a, &candidate, &candidate);
    const bundle = candidate.content.value;
    try std.testing.expectEqualStrings(compiler.recovery_policy, bundle.manifest.compiler.policy);
    try std.testing.expectEqualStrings(
        @import("recovery_options").horos_package,
        bundle.manifest.compiler.horos_package,
    );
    try checkEvidenceLimits(bundle);
    try checkIdentity(bundle);
    try checkContext(bundle);
}

test {
    _ = @import("semantic/recovery_specialization.zig");
}
