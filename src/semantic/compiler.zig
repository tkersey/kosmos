//! Host-only construction and independent verification of portable artifacts.
//! Execution loads their admitted first-order images; no compiler is needed to
//! pump a carried realization or its recovery helpers.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const artifact = @import("artifact.zig");
const service = @import("service.zig");
const machines = @import("machine.zig");
const clones = @import("clone.zig");
const projection = @import("projection.zig");
const profile = @import("../base/profile.zig");
const Id = data.program.Id;

const construction = @import("construction.zig");
pub const checker_identity = artifact.derived_policy;
pub const Proposal = construction.Proposal;
pub const RecordProposal = construction.RecordProposal;
pub const ProposedInterfaces = construction.Interfaces;
pub const DeriveOptions = construction.Options;
pub const ValidationPolicy = construction.ValidationPolicy;
pub const derive = construction.derive;
pub const deriveRecord = construction.deriveRecord;
pub const validateAgainst = construction.validateAgainst;
pub const approvedRootIdentity = construction.approvedRootIdentity;

pub const Options = struct {
    horos_package: []const u8,
    guest: ?*const data.program_image.Admitted = null,
    hooks: service.instrumentation.Hooks = .{},
    policy: source.specialize.Policy = .{
        .work = 8_000_000,
        .keys_per_function = 128,
        .depth = 1024,
    },
};
pub const Derivation = struct {
    residual: source.ast.Module,
    request: source.specialize.Request,
    functions: []const source.specialize.FunctionProof,
    values: []const source.specialize.ValueProof,
    terms: []const source.specialize.TermProof,
};
pub const Evidence = struct {
    // The bound compiler reconstructs generic source, helper source and
    // formal-parameter origins. Only residual source and finite derivations
    // have information that cannot be recovered from that binding.
    recovery: @typeInfo(@FieldType(source.Compiled, "recovery_evidence")).optional.child,
    derivation: ?Derivation,
};

pub const SourceDefinition = struct {
    builder: source.Builder,
    service: service.Definition,
    machine: machines.Definition,
    clone: clones.Definition,
    template: Id,
    helpers: [4]Id,
    failure: Id,

    pub fn init(
        a: std.mem.Allocator,
        staged: bool,
        hooks: service.instrumentation.Hooks,
    ) !SourceDefinition {
        var b = source.Builder.init(a);
        errdefer b.deinit();
        const s = try service.defineWithHooks(&b, staged, hooks);
        const m = try machines.define(&b);
        const clone = try clones.define(&b, m);
        const graph = try @import("graph.zig").define(&b, m);
        const validators = try @import("clone_validation.zig").define(&b, m, clone);
        const helpers = [4]Id{
            try @import("recovery.zig").define(&b, m),
            try @import("recovery.zig").storage(&b, m),
            validators.context,
            validators.rebase,
        };
        const failure = try b.scalar(void);
        return .{
            .builder = b,
            .service = s,
            .machine = m,
            .clone = clone,
            .template = graph.template,
            .helpers = helpers,
            .failure = failure,
        };
    }

    pub fn deinit(self: *SourceDefinition) void {
        self.builder.deinit();
        self.* = undefined;
    }

    pub fn module(self: *const SourceDefinition) source.ast.Module {
        return self.builder.module(self.service.entry, self.failure);
    }
};

pub const SourceModule = struct { module: source.ast.Module, digest: artifact.Digest };
pub const SourceHelper = struct {
    role: enum { projector, storage, clone_context, clone_rebase },
    source: SourceModule,
    image: artifact.Digest,
};
pub const PureEntry = struct {
    role: enum { initialize, step, respond, observe, hydrate, project },
    function: Id,
    signature: source.ast.Function,
};
pub const SourceEntries = struct {
    service: Id,
    branch_returns: []const Id,
    templates: []const Id,
};
pub const SourceBundle = struct {
    realization: artifact.Digest,
    image: artifact.Digest,
    emitter: artifact.Digest,
    guest: ?artifact.Digest,
    requirements: artifact.Requirements,
    bridge: data.program.Effect,
    generic: SourceModule,
    selected: SourceModule,
    helpers: [4]SourceHelper,
    generic_entries: SourceEntries,
    selected_entries: SourceEntries,
    generic_roles: [9]SourceRole,
    selected_roles: []const SourceRole,
    generic_pure_entries: [6]PureEntry,
    parameters: []const source.RecoveryBinding,
    anchors: []const artifact.Anchor,
    branch_returns: []const Id,
    template_entries: []const Id,
    evidence: Evidence,
    construction: ?construction.Evidence = null,
    lineage: ?artifact.Lineage = null,
};
pub const ExportedSource = struct {
    arena: *std.heap.ArenaAllocator,
    value: SourceBundle,
    retained: artifact.Admitted,
    derived: ?artifact.Admitted = null,
    definition: SourceDefinition,

    pub fn deinit(self: *ExportedSource) void {
        if (self.derived) |*derived| derived.deinit();
        self.definition.deinit();
        self.retained.deinit();
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn exportSource(a: std.mem.Allocator, admitted: *const artifact.Admitted) !ExportedSource {
    if (admitted.content.value.lineage != null) return construction.exportSource(a, admitted);
    return exportBuiltinSource(a, admitted);
}

pub fn exportBuiltinSource(
    a: std.mem.Allocator,
    admitted: *const artifact.Admitted,
) !ExportedSource {
    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(a);
    errdefer {
        arena.deinit();
        a.destroy(arena);
    }
    const scratch = arena.allocator();
    const bytes = try admitted.encode(scratch);
    var retained = try artifact.Admitted.init(scratch, bytes, admitted.identity);
    errdefer retained.deinit();
    var definition = try sourceDefinition(scratch, &retained);
    errdefer definition.deinit();
    const pure_entries = try pureEntries(&definition);
    const evidence = try readEvidence(scratch, &retained);
    var validation = std.heap.ArenaAllocator.init(a);
    defer validation.deinit();
    const parameters = try scratch.dupe(source.RecoveryBinding, try validateDefined(
        validation.allocator(),
        &retained,
        &definition,
        evidence,
    ));
    const original = definition.module();
    const selected = if (evidence.derivation) |d| d.residual else original;
    const bundle = retained.content.value;
    var helpers: [4]SourceHelper = undefined;
    for (definition.helpers, 0..) |entry, i| {
        helpers[i] = .{
            .role = @fromBackingInt(@intCast(i)),
            .source = try sourceModule(definition.builder.module(entry, definition.failure)),
            .image = retained.helpers[i].identity(),
        };
    }
    const roles = sourceRoles(definition.service, definition.clone);
    return .{ .arena = arena, .retained = retained, .definition = definition, .value = .{
        .realization = retained.identity,
        .image = bundle.manifest.image,
        .emitter = bundle.manifest.source,
        .guest = bundle.guest,
        .requirements = bundle.manifest.requirements,
        .bridge = bundle.manifest.bridge,
        .generic = try sourceModule(original),
        .selected = try sourceModule(selected),
        .helpers = helpers,
        .generic_entries = try sourceEntries(scratch, &definition, null),
        .selected_entries = try sourceEntries(scratch, &definition, evidence.derivation),
        .generic_roles = roles,
        .selected_roles = try selectedRoles(scratch, roles, evidence.derivation),
        .generic_pure_entries = pure_entries,
        .parameters = parameters,
        .anchors = bundle.recovery.anchors,
        .branch_returns = bundle.branch_returns,
        .template_entries = bundle.template_entries,
        .evidence = evidence,
    } };
}

pub fn sourceModule(module: source.ast.Module) !SourceModule {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var writer: data.wire.Writer = .{ .hasher = &hash };
    try data.record.write(source.ast.Module, module, &writer);
    return .{ .module = module, .digest = hash.finalResult() };
}

fn pureEntries(definition: *SourceDefinition) ![6]PureEntry {
    const b = &definition.builder;
    const m = definition.machine;
    const life = try @import("lifecycle.zig").define(b, m);
    const step = try @import("step.zig").define(b, m);
    const observe = try @import("observe.zig").define(b, m);
    const functions = [6]Id{
        life.initialize, step.active, life.respond, observe, m.hydrate, m.project,
    };
    var result: [6]PureEntry = undefined;
    for (functions, 0..) |function, i| result[i] = .{
        .role = @fromBackingInt(@intCast(i)),
        .function = function,
        .signature = b.functions.items[function],
    };
    return result;
}

fn sourceEntries(
    a: std.mem.Allocator,
    definition: *const SourceDefinition,
    derivation: ?Derivation,
) !SourceEntries {
    return .{
        .service = if (derivation) |d| d.residual.entry else definition.service.entry,
        .branch_returns = try sourceFunctions(a, definition.clone.instantiate, derivation),
        .templates = try sourceFunctions(a, definition.template, derivation),
    };
}

fn sourceFunctions(a: std.mem.Allocator, original: Id, derivation: ?Derivation) ![]const Id {
    var result: std.ArrayList(Id) = .empty;
    try result.append(a, original);
    if (derivation) |d| for (d.functions) |f| {
        if (f.before == original) try result.append(a, f.after);
    };
    return result.toOwnedSlice(a);
}

fn selectedRoles(
    a: std.mem.Allocator,
    roles: [9]SourceRole,
    derivation: ?Derivation,
) ![]const SourceRole {
    var result: std.ArrayList(SourceRole) = .empty;
    try result.appendSlice(a, &roles);
    if (derivation) |d| for (d.functions) |f| {
        for (roles) |role| {
            if (f.before != role.function) continue;
            var ordinals: std.ArrayList(u32) = .empty;
            for (role.ordinals) |original| {
                if (f.arguments[original] == .known) break;
                var ordinal: u32 = 0;
                for (f.arguments[0..original]) |argument| {
                    if (argument != .known) ordinal += 1;
                }
                try ordinals.append(a, ordinal);
            }
            if (ordinals.items.len != role.ordinals.len) continue;
            try result.append(a, .{
                .function = f.after,
                .role = role.role,
                .ordinals = try ordinals.toOwnedSlice(a),
            });
        }
    };
    return result.toOwnedSlice(a);
}

pub fn compile(allocator: std.mem.Allocator, options: Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var definition = try SourceDefinition.init(a, options.guest != null, options.hooks);
    defer definition.deinit();
    const b = &definition.builder;
    const s = definition.service;
    const m = definition.machine;
    const clone = definition.clone;
    const original = definition.module();
    var specialized = try specialize(a, options, original, s.entry, m.program);
    defer if (specialized) |*out| out.deinit();
    const module = if (specialized) |*out| out.module() else original;
    var compiled = try source.lowerObserved(a, module, .{ .recovery = true });
    defer compiled.deinit();
    // Recovery lowering constructs formal origins and checks their actual
    // correspondence. Reconstruct source when validating carried artifacts.
    const image = try encode(a, compiled.program);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const effects = admitted.program().effects;
    if (effects.len != 1 or !std.mem.eql(
        u8,
        effects[0].identity,
        service.identity,
    )) return error.InvalidBridge;
    const helper_images = try helperImages(a, b, definition.helpers, definition.failure);
    const bytes = try encodeBundle(
        a,
        allocator,
        options,
        b,
        s,
        clone,
        definition.template,
        compiled,
        if (specialized) |*out| out else null,
        admitted,
        image,
        helper_images,
    );
    errdefer allocator.free(bytes);
    var checked = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer checked.deinit();
    return bytes;
}

fn specialize(
    a: std.mem.Allocator,
    options: Options,
    original: source.ast.Module,
    entry: Id,
    program: Id,
) !?source.specialize.Output {
    return if (options.guest) |guest| try source.specialize.specialize(
        a,
        original,
        .{
            .function = entry,
            .arguments = &.{ .{ .known = .{
                .schema = program,
                .bytes = try projection.programBytes(a, guest),
            } }, .dynamic },
            .context = contextWithHooks(guest.identity(), options.hooks),
            .policy = options.policy,
        },
    ) else null;
}

fn helperImages(
    a: std.mem.Allocator,
    b: *const source.Builder,
    helpers: [4]Id,
    failure: Id,
) ![4]artifact.Helper {
    var helper_images: [4]artifact.Helper = undefined;
    for (helpers, 0..) |helper, i| {
        var lowered = try source.lower(a, b.module(helper, failure));
        defer lowered.deinit();
        const bytes = try encode(a, lowered.program);
        const checked = try data.program_image.Admitted.decode(a, bytes);
        defer checked.deinit();
        helper_images[i] = .{
            .image = bytes,
            .inventory = try artifact.inventory(a, try profile.check(checked, .{})),
        };
    }
    return helper_images;
}

fn encodeBundle(
    a: std.mem.Allocator,
    allocator: std.mem.Allocator,
    options: Options,
    b: *const source.Builder,
    s: service.Definition,
    clone: clones.Definition,
    template: Id,
    compiled: source.Compiled,
    specialized: ?*const source.specialize.Output,
    admitted: *const data.program_image.Admitted,
    image: []const u8,
    helper_images: [4]artifact.Helper,
) ![]u8 {
    const anchors = try anchorMap(
        a,
        b,
        s,
        clone,
        compiled.parameters,
        specialized,
    );
    const evidence = try encodeEvidence(a, .{
        .recovery = compiled.recovery_evidence.?,
        .derivation = if (specialized) |out| .{
            .residual = out.module(),
            .request = out.request,
            .functions = out.functions.items,
            .values = out.value_proofs.items,
            .terms = out.term_proofs.items,
        } else null,
    });
    return artifact.encode(allocator, .{
        .manifest = try manifestFor(a, options, admitted),
        .image = image,
        .guest = if (options.guest) |guest| guest.identity() else null,
        .specialization = if (specialized) |out| out.key else null,
        .hooks = options.hooks,
        .recovery = .{
            .projector = helper_images[0],
            .storage = helper_images[1],
            .clone_context = helper_images[2],
            .clone_rebase = helper_images[3],
            .anchors = anchors,
        },
        .branch_returns = try functionMap(
            a,
            clone.instantiate,
            compiled.parameters,
            specialized,
        ),
        .template_entries = try functionMap(
            a,
            template,
            compiled.parameters,
            specialized,
        ),
        .evidence = evidence,
    });
}

fn manifestFor(
    a: std.mem.Allocator,
    options: Options,
    admitted: *const data.program_image.Admitted,
) !@FieldType(artifact.Bundle, "manifest") {
    const effects = admitted.program().effects;
    return .{
        .image = admitted.identity(),
        .source = @import("source_identity.zig").digest(),
        .compiler = .{
            .horos_package = options.horos_package,
            .zig = @import("builtin").zig_version_string,
            .policy = artifact.build_policy,
        },
        .requirements = .{
            .base = profile.identity,
            .admission = artifact.admission_profile,
            .bridge = service.identity,
        },
        .bridge = effects[0],
        .inventory = try artifact.inventory(
            a,
            try profile.check(admitted, .{ .effects = effects }),
        ),
    };
}

pub fn context(guest: artifact.Digest) source.specialize.Context {
    return contextWithHooks(guest, .{});
}

pub fn contextWithHooks(
    guest: artifact.Digest,
    hooks: service.instrumentation.Hooks,
) source.specialize.Context {
    var observation = std.crypto.hash.sha2.Sha256.init(.{});
    observation.update("kosmos.canonical-pst3/3;cut-observation/1");
    observation.update(&.{ @intFromBool(hooks.control), @intFromBool(hooks.storage) });
    return .{
        .core = @import("source_identity.zig").digest(),
        .guest = guest,
        .observation = observation.finalResult(),
        .base_profile = artifact.digest(profile.identity),
        .admission_profile = artifact.digest(artifact.admission_profile),
        .compiler_policy = artifact.digest(artifact.build_policy),
    };
}

pub const SourceRole = struct { function: Id, role: artifact.Role, ordinals: []const u32 };
const Selector = SourceRole;

fn sourceRoles(s: service.Definition, clone: clones.Definition) [9]SourceRole {
    return .{
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
}

fn anchorMap(
    a: std.mem.Allocator,
    b: *const source.Builder,
    s: service.Definition,
    clone: clones.Definition,
    parameters: []const source.RecoveryBinding,
    specialized: ?*const source.specialize.Output,
) ![]const artifact.Anchor {
    var anchors: std.ArrayList(artifact.Anchor) = .empty;
    const selectors = sourceRoles(s, clone);
    for (selectors) |selector| {
        try addAnchor(
            a,
            &anchors,
            parameters,
            selector,
            b.module(s.entry, 0),
            selector.function,
            null,
        );
        if (specialized) |out| for (out.functions.items) |f| {
            if (f.before == selector.function) try addAnchor(
                a,
                &anchors,
                parameters,
                selector,
                out.module(),
                f.after,
                f.arguments,
            );
        };
    }
    return anchors.toOwnedSlice(a);
}

pub fn anchorsForRoles(
    a: std.mem.Allocator,
    roles: []const SourceRole,
    module: source.ast.Module,
    parameters: []const source.RecoveryBinding,
) ![]const artifact.Anchor {
    var anchors: std.ArrayList(artifact.Anchor) = .empty;
    for (roles) |role| {
        if (role.function >= module.functions.len) return error.InvalidRecovery;
        const function = module.functions[@intCast(role.function)];
        for (role.ordinals) |ordinal| {
            if (ordinal >= function.parameters.len) return error.InvalidRecovery;
        }
        try addAnchor(a, &anchors, parameters, role, module, role.function, null);
    }
    return anchors.toOwnedSlice(a);
}

fn addAnchor(
    a: std.mem.Allocator,
    anchors: *std.ArrayList(artifact.Anchor),
    bindings: []const source.RecoveryBinding,
    selector: Selector,
    module: source.ast.Module,
    function: Id,
    knowledge: ?[]const source.specialize.Knowledge,
) !void {
    var parameters: std.ArrayList(artifact.Parameter) = .empty;
    var final_function: ?Id = null;
    for (selector.ordinals, 0..) |original_ordinal, ordinal| {
        var actual = original_ordinal;
        if (knowledge) |arguments| {
            if (arguments[original_ordinal] == .known) return;
            actual = 0;
            for (arguments[0..original_ordinal]) |k| if (k != .known) {
                actual += 1;
            };
        }
        const variable = module.functions[@intCast(function)].parameters[actual];
        var found = false;
        for (bindings) |binding| if (binding.source_function == function and
            binding.variable == variable)
        {
            if (final_function) |prior| if (prior != binding.function) return error.InvalidRecovery;
            final_function = binding.function;
            try parameters.append(a, .{
                .ordinal = ordinal,
                .slot = binding.slot,
                .schema = binding.schema,
            });
            found = true;
            break;
        };
        if (!found) return; // unreachable original functions have no final slots
    }
    try anchors.append(a, .{
        .function = final_function.?,
        .role = selector.role,
        .parameters = try parameters.toOwnedSlice(a),
    });
}

fn encode(a: std.mem.Allocator, program: data.activation.Program) ![]u8 {
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(program));
    _ = try data.program_image.encode(a, program, bytes);
    return bytes;
}

fn functionMap(
    a: std.mem.Allocator,
    original: Id,
    parameters: []const source.RecoveryBinding,
    specialized: ?*const source.specialize.Output,
) ![]const Id {
    var result: std.ArrayList(Id) = .empty;
    for (parameters) |binding| {
        var selected = binding.source_function == original;
        if (specialized) |out| for (out.functions.items) |f| {
            if (f.before == original and f.after == binding.source_function) selected = true;
        };
        if (selected and std.mem.indexOfScalar(
            Id,
            result.items,
            binding.function,
        ) == null) try result.append(a, binding.function);
    }
    return result.toOwnedSlice(a);
}

fn encodeEvidence(a: std.mem.Allocator, evidence: Evidence) ![]u8 {
    var length: data.wire.Writer = .{};
    try data.record.writeAlloc(Evidence, a, evidence, &length);
    const bytes = try a.alloc(u8, length.position);
    var writer: data.wire.Writer = .{ .output = bytes };
    try data.record.writeAlloc(Evidence, a, evidence, &writer);
    return bytes;
}

/// Independent derivation/relocation checks over carried evidence. A caller
/// still approves the exact source/compiler policy before activating it.
pub fn validate(a: std.mem.Allocator, admitted: *const artifact.Admitted) !void {
    if (admitted.content.value.lineage != null) return construction.validate(a, admitted, .{});
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var definition = try sourceDefinition(scratch, admitted);
    defer definition.deinit();
    const evidence = try readEvidence(scratch, admitted);
    _ = try validateDefined(scratch, admitted, &definition, evidence);
}

pub fn validateWithPolicy(
    a: std.mem.Allocator,
    admitted: *const artifact.Admitted,
    policy: ValidationPolicy,
) !void {
    if (admitted.content.value.lineage != null) return construction.validate(a, admitted, policy);
    return validate(a, admitted);
}

fn sourceDefinition(a: std.mem.Allocator, admitted: *const artifact.Admitted) !SourceDefinition {
    const bundle = admitted.content.value;
    if (!std.mem.eql(u8, &bundle.manifest.source, &@import("source_identity.zig").digest()) or
        !std.mem.eql(u8, bundle.manifest.compiler.policy, artifact.build_policy))
        return error.UnsupportedSource;
    return SourceDefinition.init(a, bundle.guest != null, bundle.hooks);
}

fn readEvidence(a: std.mem.Allocator, admitted: *const artifact.Admitted) !Evidence {
    var reader: data.wire.Reader = .{ .input = admitted.content.value.evidence };
    const evidence = try data.record.read(Evidence, &reader, a);
    try reader.finish();
    return evidence;
}

fn validateDefined(
    scratch: std.mem.Allocator,
    admitted: *const artifact.Admitted,
    definition: *const SourceDefinition,
    evidence: Evidence,
) ![]const source.RecoveryBinding {
    const bundle = admitted.content.value;
    const original = definition.module();
    const module = if (evidence.derivation) |d| d.residual else original;
    const parameters = try source.recovery.parameters(
        scratch,
        module,
        admitted.program.program(),
        evidence.recovery,
    );
    var specialized: ?source.specialize.Output = null;
    defer if (specialized) |*out| out.deinit();
    if (evidence.derivation) |d| {
        specialized = try validatedDerivation(
            scratch,
            admitted,
            original,
            definition.service.entry,
            definition.machine.program,
            d,
        );
    } else if (bundle.specialization != null or bundle.guest != null) {
        return error.InvalidRealization;
    }
    const out = if (specialized) |*value| value else null;
    const anchors = try anchorMap(
        scratch,
        &definition.builder,
        definition.service,
        definition.clone,
        parameters,
        out,
    );
    try validateRecovery(
        scratch,
        admitted,
        &definition.builder,
        definition.failure,
        definition.helpers,
        anchors,
        try functionMap(scratch, definition.clone.instantiate, parameters, out),
        try functionMap(scratch, definition.template, parameters, out),
    );
    return parameters;
}

fn validatedDerivation(
    scratch: std.mem.Allocator,
    admitted: *const artifact.Admitted,
    original: source.ast.Module,
    entry: Id,
    program: Id,
    d: Derivation,
) !source.specialize.Output {
    const bundle = admitted.content.value;
    const module = d.residual;
    try validateGuest(scratch, bundle, entry, program, d);
    var out: source.specialize.Output = .{
        .builder = source.Builder.init(scratch),
        .original = original,
        .request = d.request,
        .entry = module.entry,
        .key = admitted.content.value.specialization orelse return error.InvalidRealization,
        .functions = .fromOwnedSlice(@constCast(d.functions)),
        .value_proofs = .fromOwnedSlice(@constCast(d.values)),
        .term_proofs = .fromOwnedSlice(@constCast(d.terms)),
    };
    errdefer out.deinit();
    inline for (.{
        "schemas",
        "constants",
        "effects",
        "handlers",
        "resources",
        "variables",
        "values",
        "terms",
        "functions",
    }) |name| {
        try @field(out.builder, name).appendSlice(
            out.builder.allocator(),
            @field(module, name),
        );
    }
    out.builder.region_count = module.region_count;
    if (!data.record.equal(source.specialize.Context, d.request.context, contextWithHooks(
        admitted.content.value.guest orelse return error.InvalidRealization,
        bundle.hooks,
    ))) return error.InvalidRealization;
    try source.specialize.validate(scratch, original, d.request, &out);
    return out;
}

fn validateGuest(
    scratch: std.mem.Allocator,
    bundle: artifact.Bundle,
    entry: Id,
    program: Id,
    d: Derivation,
) !void {
    if (d.request.function != entry or d.request.arguments.len != 2 or
        d.request.arguments[0] != .known or
        d.request.arguments[1] != .dynamic or
        d.request.arguments[0].known.schema != program) return error.InvalidRealization;
    var known = try projection.decode(
        projection.Program,
        scratch,
        d.request.arguments[0].known.bytes,
    );
    defer known.deinit();
    const guest = try data.program_image.Admitted.decode(
        scratch,
        try encode(scratch, known.value.code),
    );
    defer guest.deinit();
    if (!std.mem.eql(
        u8,
        &guest.identity(),
        &(bundle.guest orelse return error.InvalidRealization),
    ) or
        !std.mem.eql(
            u8,
            try projection.programBytes(scratch, guest),
            d.request.arguments[0].known.bytes,
        )) return error.InvalidRealization;
}

fn validateRecovery(
    scratch: std.mem.Allocator,
    admitted: *const artifact.Admitted,
    expected_builder: *const source.Builder,
    failure: Id,
    helper_entries: [4]Id,
    anchors: []const artifact.Anchor,
    branch_returns: []const Id,
    template_entries: []const Id,
) !void {
    const bundle = admitted.content.value;
    if (!data.record.equal(
        []const artifact.Anchor,
        anchors,
        bundle.recovery.anchors,
    )) return error.InvalidRecovery;
    if (!std.mem.eql(
        Id,
        branch_returns,
        bundle.branch_returns,
    ) or !std.mem.eql(Id, template_entries, bundle.template_entries)) return error.InvalidRecovery;
    for (admitted.helpers, helper_entries) |helper, entry| {
        var lowered = try source.lower(scratch, expected_builder.module(entry, failure));
        defer lowered.deinit();
        if (!data.record.equal(
            data.activation.Program,
            lowered.program,
            helper.program(),
        )) return error.InvalidRecovery;
    }
}
