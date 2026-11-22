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
    scratch: Allocator,
    definition: *const legacy.SourceDefinition,
    original: source.Module,
    derivation: ?Derivation,
    bundle: artifact.Bundle,
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
    try validateGuest(a, scratch, guest, d.request.arguments[0].known.bytes);
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
    }) |name| try @field(out.builder, name).appendSlice(
        out.builder.allocator(),
        @field(d.residual, name),
    );
    out.builder.region_count = d.residual.region_count;
    try source.specialize.validate(a, original, d.request, &out);
}

fn validateGuest(
    a: Allocator,
    scratch: Allocator,
    guest: artifact.Digest,
    bytes: []const u8,
) !void {
    var known = try projection.decode(projection.Program, a, bytes);
    defer known.deinit();
    const encoded = try scratch.alloc(u8, try old.program_image.encodedLength(known.value.code));
    _ = try old.program_image.encode(a, known.value.code, encoded);
    const admitted = try old.program_image.Admitted.decode(a, encoded);
    defer admitted.deinit();
    if (!std.mem.eql(u8, &admitted.identity(), &guest) or
        !std.mem.eql(u8, try projection.programBytes(scratch, admitted), bytes))
        return error.InvalidRealization;
}
