const std = @import("std");
const current = @import("horos_recovery");
const source = current.source;
const old = @import("horos_data");
const legacy = @import("compiler.zig");
const projection = @import("projection.zig");
const artifact = @import("artifact.zig");
const Allocator = std.mem.Allocator;
const Hooks = @import("instrumentation.zig").Hooks;
pub const policy = "kosmos.source-lower/3";
pub const Derivation = struct {
    residual: source.Module,
    request: source.specialize.Request,
    functions: []const source.specialize.FunctionProof,
    values: []const source.specialize.ValueProof,
    terms: []const source.specialize.TermProof,

    pub fn from(out: *const source.specialize.Output) Derivation {
        return .{
            .residual = out.module(),
            .request = out.request,
            .functions = out.functions.items,
            .values = out.value_proofs.items,
            .terms = out.term_proofs.items,
        };
    }
};

pub fn identity() artifact.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(policy);
    hash.update(&@import("source_identity.zig").digest());
    hash.update(@import("../semantic_packaged.zig").horos_package);
    hash.update(@import("recovery_options").horos_package);
    inline for (.{
        @embedFile("recovery_compiler.zig"),
        @embedFile("recovery_backend.zig"),
        @embedFile("recovery_export.zig"),
        @embedFile("recovery_records.zig"),
        @embedFile("recovery_specialization.zig"),
        @embedFile("recovery_roles.zig"),
    }) |bytes| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, bytes.len, .little);
        hash.update(&length);
        hash.update(bytes);
    }
    return hash.finalResult();
}

pub fn context(guest: artifact.Digest, hooks: Hooks) source.specialize.Context {
    const prior = legacy.contextWithHooks(guest, hooks);
    return .{
        .core = identity(),
        .guest = guest,
        .observation = prior.observation,
        .base_profile = prior.base_profile,
        .admission_profile = prior.admission_profile,
        .compiler_policy = artifact.digest(policy),
    };
}

pub fn select(
    a: Allocator,
    scratch: Allocator,
    definition: *const legacy.SourceDefinition,
    original: source.Module,
    opts: legacy.Options,
) !?source.specialize.Output {
    const guest = opts.guest orelse return null;
    return try source.specialize.specialize(a, original, .{
        .function = definition.service.entry,
        .arguments = try scratch.dupe(source.specialize.Knowledge, &.{
            .{ .known = .{
                .schema = definition.machine.program,
                .bytes = try projection.programBytes(scratch, guest),
            } },
            .dynamic,
        }),
        .context = context(guest.identity(), opts.hooks),
        .policy = .{
            .work = opts.policy.work,
            .keys_per_function = opts.policy.keys_per_function,
            .depth = opts.policy.depth,
        },
    });
}

pub fn validate(
    a: Allocator,
    definition: *const legacy.SourceDefinition,
    original: source.Module,
    derivation: ?Derivation,
    bundle: artifact.Bundle,
    work: *u64,
) !void {
    const d = derivation orelse {
        if (bundle.guest != null or bundle.specialization != null) return error.InvalidRealization;
        return;
    };
    const guest = bundle.guest orelse return error.InvalidRealization;
    const key = bundle.specialization orelse return error.InvalidRealization;
    if (!std.meta.eql(d.request.context, context(guest, bundle.hooks)) or
        d.residual.failure != original.failure or
        d.request.function != definition.service.entry or d.request.arguments.len != 2 or
        d.request.arguments[0] != .known or d.request.arguments[1] != .dynamic or
        d.request.arguments[0].known.schema != definition.machine.program)
        return error.InvalidRealization;
    try checkKeys(a, original.functions.len, d.functions, d.request.policy.keys_per_function, work);
    const known = d.request.arguments[0].known.bytes;
    try current.data.admission.spend(work, known.len);
    try validateGuest(a, guest, known);
    var out: source.specialize.Output = .{
        .builder = source.Builder.init(a),
        .original = original,
        .request = d.request,
        .entry = d.residual.entry,
        .key = key,
        .functions = .fromOwnedSlice(@constCast(d.functions)),
        .value_proofs = .fromOwnedSlice(@constCast(d.values)),
        .term_proofs = .fromOwnedSlice(@constCast(d.terms)),
    };
    defer out.deinit();
    inline for (.{
        "schemas",   "constants", "effects", "handlers",  "resources",
        "variables", "values",    "terms",   "functions",
    }) |name| {
        const rows = @field(d.residual, name);
        try current.data.admission.spend(work, rows.len);
        try @field(out.builder, name).appendSlice(out.builder.allocator(), rows);
    }
    out.builder.region_count = d.residual.region_count;
    try source.specialize.validateWithWork(a, original, d.request, &out, work);
}

fn checkKeys(
    a: Allocator,
    function_count: usize,
    functions: []const source.specialize.FunctionProof,
    limit: usize,
    work: *u64,
) !void {
    try current.data.admission.spend(work, function_count);
    try current.data.admission.spend(work, functions.len);
    const counts = try a.alloc(usize, function_count);
    defer a.free(counts);
    @memset(counts, 0);
    for (functions) |proof| {
        if (proof.before >= counts.len) return error.InvalidSpecialization;
        const count = &counts[@intCast(proof.before)];
        if (count.* >= limit) return error.InvalidSpecialization;
        count.* += 1;
    }
}

fn validateGuest(
    a: Allocator,
    guest: artifact.Digest,
    bytes: []const u8,
) !void {
    var known = try projection.decode(projection.Program, a, bytes);
    defer known.deinit();
    if (!std.mem.eql(u8, &known.value.identity, &guest)) return error.InvalidRealization;
    const encoded = try a.alloc(u8, try old.program_image.encodedLength(known.value.code));
    defer a.free(encoded);
    _ = try old.program_image.encode(a, known.value.code, encoded);
    const admitted = try old.program_image.Admitted.decode(a, encoded);
    defer admitted.deinit();
    if (!std.mem.eql(u8, &admitted.identity(), &guest)) return error.InvalidRealization;
    const projected = try projection.programBytes(a, admitted);
    defer a.free(projected);
    if (!std.mem.eql(u8, projected, bytes)) return error.InvalidRealization;
}

test "specialization key allowance counts distinct emitted records for each original function" {
    const Function = source.specialize.FunctionProof;
    const functions = [_]Function{
        .{ .before = 1, .after = 2, .arguments = &.{} },
        .{ .before = 0, .after = 3, .arguments = &.{} },
    };
    var exact: u64 = 4;
    try checkKeys(std.testing.allocator, 2, &functions, 1, &exact);
    try std.testing.expectEqual(0, exact);
    var short: u64 = 3;
    try std.testing.expectError(error.RelationLimit, checkKeys(
        std.testing.allocator,
        2,
        &functions,
        1,
        &short,
    ));
    exact = 4;
    try std.testing.expectError(error.InvalidSpecialization, checkKeys(
        std.testing.allocator,
        2,
        &functions,
        0,
        &exact,
    ));
}
