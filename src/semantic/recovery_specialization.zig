const std = @import("std");
const current = @import("horos_recovery");
const source = current.source;
const data = current.data;
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
    return identityFromCore(@import("source_identity.zig").digest());
}

fn identityFromCore(core: artifact.Digest) artifact.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(policy);
    hash.update(&core);
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
        .core = identityFromCore(prior.core),
        .guest = guest,
        .observation = prior.observation,
        .base_profile = prior.base_profile,
        .admission_profile = prior.admission_profile,
        .compiler_policy = artifact.digest(policy),
    };
}

pub fn select(
    a: Allocator,
    definition: *const legacy.SourceDefinition,
    original: source.Module,
    opts: legacy.Options,
) !?source.specialize.Output {
    const guest = opts.guest orelse return null;
    const bytes = try projection.programBytes(a, guest);
    defer a.free(bytes);
    return try source.specialize.specialize(a, original, .{
        .function = definition.service.entry,
        .arguments = &.{
            .{ .known = .{ .schema = definition.machine.program, .bytes = bytes } },
            .dynamic,
        },
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
    guest_storage_bytes: usize,
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
    try validateGuest(a, guest, known, guest_storage_bytes, work);
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

const GuestProjection = struct {
    identity: artifact.Digest,
    code: data.activation.Program,
    schemas: data.admission.SchemaFacts,
    uses: data.traits.Facts,
    live: []const []const []const u64,
};

pub fn validateGuest(
    a: Allocator,
    guest: artifact.Digest,
    bytes: []const u8,
    storage_bytes: usize,
    work: *u64,
) !void {
    try data.admission.spend(work, bytes.len);
    var physical = storage_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    checkGuest(cap.allocator(), guest, bytes, work) catch |err| {
        if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
        return err;
    };
}

fn checkGuest(a: Allocator, guest: artifact.Digest, bytes: []const u8, work: *u64) !void {
    var known = try projection.decode(GuestProjection, a, bytes);
    defer known.deinit();
    const value = known.value;
    if (!std.mem.eql(u8, &value.identity, &guest)) return error.InvalidRealization;
    var checked = try data.program_image.identityWithFlow(a, value.code, work);
    defer checked.deinit();
    if (!std.mem.eql(u8, &checked.identity, &guest)) return error.InvalidRealization;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const mem = scratch.allocator();
    const schemas = try data.admission.schemasWithWork(mem, value.code.schemas, work);
    if (!try data.record.equalWithWork(data.admission.SchemaFacts, schemas, value.schemas, work))
        return error.InvalidRealization;
    const uses = try data.traits.deriveWithWork(mem, value.code.schemas, work);
    if (!try data.record.equalWithWork(data.traits.Facts, uses, value.uses, work))
        return error.InvalidRealization;
    try checkLive(&checked.facts, value.live, work);
}

fn checkLive(
    facts: *const data.activation_flow.Facts,
    submitted: []const []const []const u64,
    work: *u64,
) !void {
    if (facts.live.len != submitted.len) return error.InvalidRealization;
    try data.admission.spend(work, facts.live.len);
    for (facts.live, submitted) |positions, rows| {
        if (positions.len != rows.len) return error.InvalidRealization;
        try data.admission.spend(work, rows.len);
        for (positions, rows) |root, slots| {
            try data.admission.spend(work, slots.len);
            var iter = facts.pool.iterator(root);
            for (slots) |slot| {
                const expected = iter.next() orelse return error.InvalidRealization;
                if (expected != slot) return error.InvalidRealization;
            }
            if (iter.next() != null) return error.InvalidRealization;
        }
    }
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
