const std = @import("std");
const current = @import("horos_recovery");
const source = current.source;
const data = current.data;
const old = @import("horos_data");
const legacy = @import("compiler.zig");
const art = @import("artifact.zig");
const records = @import("recovery_records.zig");
const roles = @import("recovery_roles.zig");
const spec = @import("recovery_specialization.zig");
const profile = @import("../base/profile.zig");
const service = @import("service.zig");
const opt = source.recovery_optimization;
const Allocator = std.mem.Allocator;
pub const Derivation = spec.Derivation;
pub const policy = spec.policy;
pub const context = spec.context;
pub const limits: opt.Limits = .{};
pub const Evidence = records.Evidence;

const Selection = struct {
    module: source.Module,
    functions: []const source.specialize.FunctionProof,
    roles: []const legacy.SourceRole,
    options: opt.Options,

    fn init(
        a: Allocator,
        definition: *const legacy.SourceDefinition,
        original: source.Module,
        derivation: ?Derivation,
    ) !Selection {
        const functions = if (derivation) |d| d.functions else &.{};
        const selected = try roles.selected(a, definition, functions);
        return .{
            .module = if (derivation) |d| d.residual else original,
            .functions = functions,
            .roles = selected,
            .options = .{
                .rule = .scalar_field_reuse_v1,
                .limits = limits,
                .formals = try roles.formals(a, selected),
            },
        };
    }

    fn interfaces(
        self: Selection,
        a: Allocator,
        definition: *const legacy.SourceDefinition,
        parameters: []const source.RecoveryBinding,
    ) !Interfaces {
        return .{
            .anchors = try roles.anchors(a, self.roles, self.module, parameters),
            .branches = try roles.functionMap(
                a,
                definition.clone.instantiate,
                self.functions,
                parameters,
            ),
            .templates = try roles.functionMap(a, definition.template, self.functions, parameters),
        };
    }
};

const Interfaces = struct {
    anchors: []const art.Anchor,
    branches: []const u64,
    templates: []const u64,
};

pub fn compile(a: Allocator, options: legacy.Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    var definition = try legacy.SourceDefinition.init(a, options.guest != null, options.hooks);
    defer definition.deinit();
    const original = try records.module(mem, definition.module());
    var out = try spec.select(a, mem, &definition, original, options);
    defer if (out) |*o| o.deinit();
    const derivation = if (out) |*o| Derivation.from(o) else null;
    const selected = try Selection.init(mem, &definition, original, derivation);
    var result = try source.lowerRecoveryOptimized(a, selected.module, selected.options);
    defer result.deinit();
    const image = try records.image(a, a, result.program);
    defer a.free(image);
    const target = try old.program_image.Admitted.decode(a, image);
    defer target.deinit();
    const entries = try selected.interfaces(mem, &definition, result.parameters);
    const helpers = try buildHelpers(a, mem, original, definition.helpers);
    const bundle = try art.encode(a, .{
        .manifest = try manifest(mem, target),
        .image = image,
        .guest = if (options.guest) |g| g.identity() else null,
        .specialization = if (out) |o| o.key else null,
        .hooks = options.hooks,
        .recovery = .{
            .projector = helpers[0],
            .storage = helpers[1],
            .clone_context = helpers[2],
            .clone_rebase = helpers[3],
            .anchors = entries.anchors,
        },
        .branch_returns = entries.branches,
        .template_entries = entries.templates,
        .evidence = try records.encodeEvidence(a, mem, .{
            .recovery = try records.encode(mem, result.evidence),
            .derivation = derivation,
        }, limits),
    });
    errdefer a.free(bundle);
    var admitted = try art.Admitted.init(a, bundle, art.digest(bundle));
    defer admitted.deinit();
    var work = limits.source_work;
    const content = admitted.content.value;
    var envelope = try openEvidence(a, content, &work);
    defer envelope.deinit();
    try spec.validate(a, &definition, original, envelope.value.derivation, content, &work);
    return bundle;
}

fn manifest(a: Allocator, admitted: *const old.program_image.Admitted) !art.Manifest {
    const effects = admitted.program().effects;
    if (effects.len != 1 or !std.mem.eql(u8, effects[0].identity, service.identity))
        return error.InvalidBridge;
    return .{
        .image = admitted.identity(),
        .source = spec.identity(),
        .compiler = .{
            .horos_package = @import("recovery_options").horos_package,
            .zig = @import("builtin").zig_version_string,
            .policy = policy,
        },
        .requirements = .{
            .base = profile.identity,
            .admission = art.admission_profile,
            .bridge = service.identity,
        },
        .bridge = effects[0],
        .inventory = try art.inventory(a, try profile.check(admitted, .{ .effects = effects })),
    };
}

fn helperImage(
    a: Allocator,
    mem: Allocator,
    original: source.Module,
    entry: u64,
) ![]const u8 {
    var helper = original;
    helper.entry = entry;
    var compiled = try source.lower(a, helper);
    defer compiled.deinit();
    return records.image(a, mem, compiled.program);
}

fn buildHelpers(
    a: Allocator,
    mem: Allocator,
    original: source.Module,
    entries: [4]u64,
) ![4]art.Helper {
    var helpers: [4]art.Helper = undefined;
    for (entries, &helpers) |entry, *helper| {
        const image = try helperImage(a, mem, original, entry);
        const admitted = try old.program_image.Admitted.decode(a, image);
        defer admitted.deinit();
        helper.* = .{ .image = image, .inventory = try art.inventory(
            mem,
            try profile.check(admitted, .{}),
        ) };
    }
    return helpers;
}

pub fn validate(a: Allocator, admitted: *const art.Admitted) !void {
    try checkManifest(admitted);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    const bundle = admitted.content.value;
    var definition = try legacy.SourceDefinition.init(a, bundle.guest != null, bundle.hooks);
    defer definition.deinit();
    var remaining = limits.source_work;
    var validated = try validateDefined(a, mem, &remaining, admitted, &definition);
    defer validated.deinit(a);
}

pub fn checkManifest(admitted: *const art.Admitted) !void {
    const bundle = admitted.content.value;
    const m = bundle.manifest;
    if (bundle.lineage != null or !std.mem.eql(u8, m.contract, art.identity) or
        !std.mem.eql(u8, m.compiler.policy, policy) or
        !std.mem.eql(u8, &m.source, &spec.identity()) or
        !std.mem.eql(u8, m.compiler.horos_package, @import("recovery_options").horos_package) or
        !std.mem.eql(u8, m.compiler.zig, @import("builtin").zig_version_string))
        return error.UnsupportedSource;
}

pub const Validated = struct {
    envelope: records.DecodedEvidence,
    derivation: ?Derivation,
    proof: opt.Decoded,
    parameters: []const source.RecoveryBinding,

    pub fn deinit(self: *Validated, a: Allocator) void {
        a.free(self.parameters);
        self.proof.deinit();
        self.envelope.deinit();
    }
};

pub fn validateDefined(
    a: Allocator,
    scratch: Allocator,
    remaining: *u64,
    admitted: *const art.Admitted,
    definition: *const legacy.SourceDefinition,
) !Validated {
    const bundle = admitted.content.value;
    var envelope = try openEvidence(a, bundle, remaining);
    errdefer envelope.deinit();
    const evidence = envelope.value;
    var proof = try opt.decode(a, evidence.recovery, limits);
    errdefer proof.deinit();
    const original = try records.module(scratch, definition.module());
    try spec.validate(a, definition, original, evidence.derivation, bundle, remaining);
    const selected = try Selection.init(scratch, definition, original, evidence.derivation);
    const parameters = try validateSelected(
        a,
        scratch,
        admitted,
        definition,
        original,
        selected,
        proof.evidence,
    );
    return .{
        .envelope = envelope,
        .derivation = evidence.derivation,
        .proof = proof,
        .parameters = parameters,
    };
}

fn openEvidence(
    a: Allocator,
    bundle: art.Bundle,
    remaining: *u64,
) !records.DecodedEvidence {
    if ((bundle.guest != null) != (bundle.specialization != null)) return error.InvalidRealization;
    return records.decodeEvidence(a, bundle.evidence, bundle.guest != null, limits, remaining);
}

fn validateSelected(
    a: Allocator,
    mem: Allocator,
    admitted: *const art.Admitted,
    definition: *const legacy.SourceDefinition,
    original: source.Module,
    selected: Selection,
    proof: opt.Evidence,
) ![]const source.RecoveryBinding {
    const bundle = admitted.content.value;
    try records.checkImage(a, bundle.image, admitted.program);
    const target = try data.program_image.Admitted.decode(a, bundle.image);
    defer target.deinit();
    const parameters = try opt.parameters(
        a,
        selected.module,
        target.program(),
        proof,
        selected.options,
    );
    errdefer a.free(parameters);
    const mapped = try selected.interfaces(mem, definition, parameters);
    if (!old.record.equal([]const art.Anchor, mapped.anchors, bundle.recovery.anchors) or
        !std.mem.eql(u64, mapped.branches, bundle.branch_returns) or
        !std.mem.eql(u64, mapped.templates, bundle.template_entries)) return error.InvalidRecovery;
    const helpers = [_]art.Helper{
        bundle.recovery.projector,     bundle.recovery.storage,
        bundle.recovery.clone_context, bundle.recovery.clone_rebase,
    };
    for (definition.helpers, helpers, admitted.helpers) |entry, helper, owner| {
        try records.checkImage(a, helper.image, owner);
        if (!std.mem.eql(u8, try helperImage(a, mem, original, entry), helper.image))
            return error.InvalidRecovery;
    }
    return parameters;
}
