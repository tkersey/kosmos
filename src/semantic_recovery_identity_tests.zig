const std = @import("std");
const data = @import("horos_data");
const checked = @import("horos_recovery").data;
const spec = @import("semantic/recovery_specialization.zig");
const compiler = @import("recovery_root.zig").RuntimeCompiler;
const artifact = @import("semantic/artifact.zig");
const records = @import("semantic/recovery_records.zig");
const packaged = @import("semantic_packaged.zig");
const a = std.testing.allocator;
const superseded_horos_package = "horos-8.0.1-flclaJaVVgC6MoQyrPCu39bQWT4ffTRnDxam33dMB2hI";

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
    changed.manifest.compiler.horos_package = superseded_horos_package;
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
    const limits = compiler.recovery_limits;
    const guest = bundle.guest.?;
    const known = proof.request.arguments[0].known.bytes;
    var budget = limits.source_work;
    try spec.validateGuest(a, guest, known, limits.lowering_bytes, &budget);
    const guest_cost = limits.source_work - budget;
    budget = guest_cost - 1;
    try std.testing.expectError(error.RelationLimit, spec.validateGuest(
        a,
        guest,
        known,
        limits.lowering_bytes,
        &budget,
    ));
    budget = guest_cost;
    try std.testing.expectError(error.Capacity, spec.validateGuest(a, guest, known, 1, &budget));
    const scratch_bytes = 1024 * 1024;
    budget = limits.source_work;
    try spec.validateGuest(a, guest, known, scratch_bytes, &budget);
    budget = limits.source_work;
    try std.testing.expectError(
        error.Capacity,
        spec.validate(a, &definition, original, proof, bundle, scratch_bytes, &budget),
    );
    var work = guest_cost;
    try std.testing.expectError(
        error.RelationLimit,
        spec.validate(a, &definition, original, proof, bundle, limits.lowering_bytes, &work),
    );
    try std.testing.expectEqual(0, work);
}

fn checkEvidenceLimits(bundle: artifact.Bundle) !void {
    const limits = compiler.recovery_limits;
    var exact: u64 = bundle.evidence.len;
    var decoded = try records.decodeEvidence(a, bundle.evidence, true, limits, &exact);
    defer decoded.deinit();
    try std.testing.expectEqual(0, exact);
    const proof = decoded.value.derivation.?;
    try std.testing.expectEqual(1, proof.request.policy.keys_per_function);
    try std.testing.expectEqual(limits.source_work + 1, proof.request.policy.work);
    try checkVerifierWork(bundle, proof);
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
    try std.testing.expectError(error.Capacity, spec.projectGuest(a, guest, 1));
    const projected = try spec.projectGuest(a, guest, compiler.recovery_limits.lowering_bytes);
    defer a.free(projected);
    const expected = try @import("semantic/projection.zig").programBytes(a, guest);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, projected);
    const same = try checked.program_image.Admitted.decode(a, image);
    defer same.deinit();
    try records.checkProgram(guest, same.program());
    var different = same.program();
    const constants = try a.dupe(@TypeOf(different.constants[0]), different.constants);
    defer a.free(constants);
    constants[0].bytes = &std.mem.toBytes(@as(u64, 8));
    different.constants = constants;
    _ = try checked.program_image.identity(a, different);
    try std.testing.expectError(error.InvalidRecovery, records.checkProgram(guest, different));
    const policy = @import("horos").source.specialize.Policy{
        .work = compiler.recovery_limits.source_work + 1,
        .keys_per_function = 1,
        .depth = 1024,
    };
    const bytes = try compiler.compile(a, .{
        .horos_package = packaged.horos_package,
        .guest = guest,
        .scalar_field_reuse = true,
        .policy = policy,
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
