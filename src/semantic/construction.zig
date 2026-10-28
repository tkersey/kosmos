const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const relation = source.relation;
const compiler = @import("compiler.zig");
const artifact = @import("artifact.zig");
const projection = @import("projection.zig");
const profile = @import("../base/profile.zig");
const Id = data.program.Id;
const Input = @FieldType(artifact.Lineage, "input");
const RecoveryEvidence = @FieldType(compiler.Evidence, "recovery");

pub const Interfaces = struct {
    roles: []const compiler.SourceRole,
    entries: compiler.SourceEntries,
    helpers: [4]Id,
    layout: artifact.Layout,
    input: Input,
};
pub const Proposal = struct {
    selected: source.ast.Module,
    steps: []const relation.Step,
    interfaces: ?Interfaces = null,
};
pub const RecordProposal = struct {
    selected: source.ast.Module,
    steps: []const relation.RecordStep,
    interfaces: ?Interfaces = null,
};
pub const ValidationPolicy = struct { work: u64 = 64_000_000 };
pub const Options = struct { horos_package: []const u8 };
pub const Evidence = struct {
    root: []const u8,
    guest: []const u8,
    prefix: u64,
    steps: []const relation.Step,
    selected: ?source.ast.Module,
    interfaces: Interfaces,
    recovery: RecoveryEvidence,
};
const Delta = struct { prefix: u64, suffix: u64, inserted: []const u8 };
const StoredStep = struct { successor: Delta, rule: relation.RecordRule };
const StoredEvidence = struct {
    root: []const u8,
    guest: []const u8,
    prefix: u64,
    steps: []const StoredStep,
    selected: source.ast.Module,
    interfaces: Interfaces,
    recovery: RecoveryEvidence,
};
const Mapping = struct {
    interfaces: Interfaces,
    private_schemas: [3]Id,
    fixed_schemas: [4]Id,
    specialization: ?artifact.Digest,
};

fn initialMapping(exported: *const compiler.ExportedSource) Mapping {
    const definition = &exported.definition;
    var helpers: [4]Id = undefined;
    for (exported.value.helpers, 0..) |helper, i| helpers[i] = helper.source.module.entry;
    return .{
        .interfaces = .{
            .roles = exported.value.selected_roles,
            .entries = exported.value.selected_entries,
            .helpers = helpers,
            .layout = .{},
            .input = if (artifact.hasProgramArgument(exported.retained.content.value))
                .program_and_initial
            else
                .initial,
        },
        .private_schemas = .{
            definition.service.state, definition.machine.schema, definition.clone.context,
        },
        .fixed_schemas = .{
            definition.machine.program, definition.machine.state,
            definition.service.command, definition.service.event,
        },
        .specialization = exported.retained.content.value.specialization,
    };
}

fn mapId(map: []const ?Id, id: Id) !Id {
    if (id >= map.len) return error.InvalidRelation;
    return map[@intCast(id)] orelse error.InvalidRelation;
}

fn relocateMapping(a: std.mem.Allocator, mapping: *Mapping, maps: relation.Relocation.Maps) !void {
    const roles = try a.dupe(compiler.SourceRole, mapping.interfaces.roles);
    for (roles) |*role| role.function = try mapId(maps.functions, role.function);
    mapping.interfaces.roles = roles;
    mapping.interfaces.entries.service = try mapId(
        maps.functions,
        mapping.interfaces.entries.service,
    );
    mapping.interfaces.entries.branch_returns = try relocateIds(
        a,
        mapping.interfaces.entries.branch_returns,
        maps.functions,
    );
    mapping.interfaces.entries.templates = try relocateIds(
        a,
        mapping.interfaces.entries.templates,
        maps.functions,
    );
    for (&mapping.interfaces.helpers) |*entry| entry.* = try mapId(maps.functions, entry.*);
    for (&mapping.private_schemas) |*schema| schema.* = try mapId(maps.schemas, schema.*);
    for (&mapping.fixed_schemas) |*schema| schema.* = try mapId(maps.schemas, schema.*);
}

fn relocateIds(a: std.mem.Allocator, ids: []const Id, map: []const ?Id) ![]const Id {
    const result = try a.alloc(Id, ids.len);
    for (ids, result) |id, *next| next.* = try mapId(map, id);
    return result;
}

fn layoutMapping(mapping: *Mapping, layouts: []const relation.Layout) !void {
    inline for (.{ "service_machine", "machine_program", "clone_machine" }, 0..) |field, i| {
        for (layouts) |layout| {
            if (layout.schema != mapping.private_schemas[i]) continue;
            @field(mapping.interfaces.layout, field) = std.mem.indexOfScalar(
                Id,
                layout.coordinates,
                @field(mapping.interfaces.layout, field),
            ) orelse return error.InvalidRelation;
        }
    }
}

fn specializedFunctions(
    a: std.mem.Allocator,
    original: []const Id,
    functions: []const source.specialize.FunctionProof,
) ![]const Id {
    var result: std.ArrayList(Id) = .empty;
    try result.appendSlice(a, original);
    for (functions) |function| {
        if (std.mem.indexOfScalar(Id, original, function.before) != null)
            try result.append(a, function.after);
    }
    return result.toOwnedSlice(a);
}

fn specializedRoles(
    a: std.mem.Allocator,
    roles: []const compiler.SourceRole,
    functions: []const source.specialize.FunctionProof,
) ![]const compiler.SourceRole {
    var result: std.ArrayList(compiler.SourceRole) = .empty;
    try result.appendSlice(a, roles);
    for (functions) |function| for (roles) |role| {
        if (function.before != role.function) continue;
        var ordinals: std.ArrayList(u32) = .empty;
        for (role.ordinals) |original| {
            if (original >= function.arguments.len) return error.InvalidRelation;
            if (function.arguments[original] == .known) break;
            var ordinal: u32 = 0;
            for (function.arguments[0..original]) |argument| {
                if (argument != .known) ordinal += 1;
            }
            try ordinals.append(a, ordinal);
        }
        if (ordinals.items.len == role.ordinals.len) try result.append(a, .{
            .function = function.after,
            .role = role.role,
            .ordinals = try ordinals.toOwnedSlice(a),
        });
    };
    return result.toOwnedSlice(a);
}

fn specializeMapping(
    a: std.mem.Allocator,
    mapping: *Mapping,
    before: source.ast.Module,
    proof: relation.Specialization,
) !void {
    mapping.interfaces.roles = try specializedRoles(a, mapping.interfaces.roles, proof.functions);
    mapping.interfaces.entries.branch_returns = try specializedFunctions(
        a,
        mapping.interfaces.entries.branch_returns,
        proof.functions,
    );
    mapping.interfaces.entries.templates = try specializedFunctions(
        a,
        mapping.interfaces.entries.templates,
        proof.functions,
    );
    mapping.interfaces.entries.service = proof.entry;
    for (proof.request.arguments) |argument| if (argument != .dynamic) {
        mapping.interfaces.input = .initial;
        break;
    };
    mapping.specialization = try source.specialize.identity(a, before, proof.request);
}

fn transport(
    a: std.mem.Allocator,
    initial: Mapping,
    original: source.ast.Module,
    steps: []const relation.Step,
) !Mapping {
    var mapping = initial;
    var before = original;
    for (steps) |step| {
        switch (step.rule) {
            .relocation => |maps| try relocateMapping(a, &mapping, maps),
            .product_layout => |layouts| try layoutMapping(&mapping, layouts),
            .specialization => |proof| try specializeMapping(a, &mapping, before, proof),
            else => {},
        }
        before = step.successor;
    }
    return mapping;
}

fn protectedFunctions(a: std.mem.Allocator, interfaces: Interfaces) ![]const Id {
    var result: std.ArrayList(Id) = .empty;
    try result.append(a, interfaces.entries.service);
    try result.appendSlice(a, &interfaces.helpers);
    try result.appendSlice(a, interfaces.entries.branch_returns);
    try result.appendSlice(a, interfaces.entries.templates);
    for (interfaces.roles) |role| try result.append(a, role.function);
    return result.toOwnedSlice(a);
}

fn staticScopes(
    a: std.mem.Allocator,
    original: source.ast.Module,
    initial: Mapping,
    guest: *const data.program_image.Admitted,
    hooks: @import("service.zig").instrumentation.Hooks,
    steps: []const relation.Step,
) ![]const relation.StaticScope {
    var result: std.ArrayList(relation.StaticScope) = .empty;
    var before = original;
    var program = initial.fixed_schemas[0];
    var input = initial.interfaces.input;
    const bytes = try projection.programBytes(a, guest);
    for (steps) |step| {
        if (step.rule == .relocation) program = try mapId(step.rule.relocation.schemas, program);
        if (step.rule == .specialization) {
            const request = step.rule.specialization.request;
            var known = false;
            for (request.arguments) |argument| known = known or argument != .dynamic;
            if (known) {
                if (input != .program_and_initial or request.arguments.len != 2 or
                    request.arguments[0] != .known or request.arguments[1] != .dynamic)
                    return error.InvalidRealization;
                const value = request.arguments[0].known;
                const context = compiler.contextWithHooks(guest.identity(), hooks);
                if (value.schema != program or !std.mem.eql(u8, value.bytes, bytes) or
                    !data.record.equal(source.specialize.Context, request.context, context))
                    return error.InvalidRealization;
                try result.append(a, .{
                    .predecessor = try relation.identity(before),
                    .request = request,
                });
                input = .initial;
            }
        }
        before = step.successor;
    }
    return result.toOwnedSlice(a);
}

fn selectedModule(evidence: Evidence, original: source.ast.Module) source.ast.Module {
    if (evidence.selected) |selected| return selected;
    if (evidence.steps.len == 0) return original;
    return evidence.steps[evidence.steps.len - 1].successor;
}

pub fn decodeEvidence(a: std.mem.Allocator, bytes: []const u8) !Evidence {
    return decodeEvidenceWithPolicy(a, bytes, .{});
}

fn decodeEvidenceWithPolicy(
    a: std.mem.Allocator,
    bytes: []const u8,
    policy: ValidationPolicy,
) !Evidence {
    var remaining = std.math.cast(usize, policy.work) orelse std.math.maxInt(usize);
    if (bytes.len > remaining) return error.RelationLimit;
    var reader: data.wire.Reader = .{ .input = bytes };
    const stored = try data.record.readBounded(StoredEvidence, &reader, a, &remaining);
    try reader.finish();
    const steps = try a.alloc(relation.Step, stored.steps.len);
    const initial = try moduleBytes(a, stored.selected);
    defer a.free(initial);
    var successor: []const u8 = initial;
    var index = steps.len;
    while (index != 0) {
        index -= 1;
        const record = stored.steps[index];
        const restored = try restoreDelta(a, successor, record.successor, &remaining);
        errdefer a.free(restored);
        var module_reader: data.wire.Reader = .{ .input = restored };
        const module = try data.record.readBounded(
            source.ast.Module,
            &module_reader,
            a,
            &remaining,
        );
        try module_reader.finish();
        steps[index] = try retainDecodedStep(a, module, record.rule, &remaining);
        successor = restored;
    }
    return .{
        .root = stored.root,
        .guest = stored.guest,
        .prefix = stored.prefix,
        .steps = steps,
        .selected = stored.selected,
        .interfaces = stored.interfaces,
        .recovery = stored.recovery,
    };
}

fn retainDecodedStep(
    a: std.mem.Allocator,
    module: source.ast.Module,
    rule: relation.RecordRule,
    remaining: *usize,
) !relation.Step {
    return switch (rule) {
        .specialization => try relation.decodeRecordStep(a, .{
            .successor = module,
            .rule = rule,
        }, remaining),
        inline else => |payload, tag| .{
            .successor = module,
            .rule = @unionInit(relation.Rule, @tagName(tag), payload),
        },
    };
}

fn moduleBytes(a: std.mem.Allocator, module: source.ast.Module) ![]u8 {
    var size: data.wire.Writer = .{};
    try data.record.write(source.ast.Module, module, &size);
    const bytes = try a.alloc(u8, size.position);
    errdefer a.free(bytes);
    var writer: data.wire.Writer = .{ .output = bytes };
    try data.record.write(source.ast.Module, module, &writer);
    return bytes;
}

fn sourceDelta(before: []const u8, after: []const u8) Delta {
    const common = @min(before.len, after.len);
    var prefix: usize = 0;
    while (prefix < common and before[prefix] == after[prefix]) prefix += 1;
    var suffix: usize = 0;
    while (suffix < common - prefix and
        before[before.len - suffix - 1] == after[after.len - suffix - 1]) suffix += 1;
    return .{
        .prefix = prefix,
        .suffix = suffix,
        .inserted = after[prefix .. after.len - suffix],
    };
}

fn restoreDelta(
    a: std.mem.Allocator,
    before: []const u8,
    delta: Delta,
    remaining: *usize,
) ![]u8 {
    if (delta.prefix > before.len or delta.suffix > before.len - delta.prefix)
        return error.InvalidSourceDelta;
    const retained: usize = @intCast(delta.prefix + delta.suffix);
    const length = std.math.add(usize, retained, delta.inserted.len) catch
        return error.RelationLimit;
    if (length > remaining.*) return error.RelationLimit;
    remaining.* -= length;
    const bytes = try a.alloc(u8, length);
    errdefer a.free(bytes);
    const prefix: usize = @intCast(delta.prefix);
    const suffix: usize = @intCast(delta.suffix);
    @memcpy(bytes[0..prefix], before[0..prefix]);
    @memcpy(bytes[prefix..][0..delta.inserted.len], delta.inserted);
    @memcpy(bytes[length - suffix ..], before[before.len - suffix ..]);
    if (!data.record.equal(Delta, delta, sourceDelta(before, bytes)))
        return error.NonCanonicalSourceDelta;
    return bytes;
}

fn encodeEvidence(
    a: std.mem.Allocator,
    evidence: Evidence,
    original: source.ast.Module,
) ![]u8 {
    const selected = selectedModule(evidence, original);
    const steps = try a.alloc(StoredStep, evidence.steps.len);
    var successor = try moduleBytes(a, selected);
    var index = steps.len;
    while (index != 0) {
        index -= 1;
        const step = evidence.steps[index];
        const previous = try moduleBytes(a, step.successor);
        const record = try relation.encodeRecordStep(a, step);
        steps[index] = .{ .successor = sourceDelta(successor, previous), .rule = record.rule };
        successor = previous;
    }
    const stored: StoredEvidence = .{
        .root = evidence.root,
        .guest = evidence.guest,
        .prefix = evidence.prefix,
        .steps = steps,
        .selected = selected,
        .interfaces = evidence.interfaces,
        .recovery = evidence.recovery,
    };
    var size: data.wire.Writer = .{};
    try data.record.write(StoredEvidence, stored, &size);
    const bytes = try a.alloc(u8, size.position);
    errdefer a.free(bytes);
    var writer: data.wire.Writer = .{ .output = bytes };
    try data.record.write(StoredEvidence, stored, &writer);
    return bytes;
}

fn encodeImage(a: std.mem.Allocator, program: data.activation.Program) ![]u8 {
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(program));
    _ = try data.program_image.encode(a, program, bytes);
    return bytes;
}

fn helperImages(
    a: std.mem.Allocator,
    selected: source.ast.Module,
    entries: [4]Id,
) ![4]artifact.Helper {
    var helpers: [4]artifact.Helper = undefined;
    for (entries, 0..) |entry, i| {
        var module = selected;
        module.entry = entry;
        var lowered = try source.lower(a, module);
        defer lowered.deinit();
        const bytes = try encodeImage(a, lowered.program);
        const image = try data.program_image.Admitted.decode(a, bytes);
        defer image.deinit();
        helpers[i] = .{
            .image = bytes,
            .inventory = try artifact.inventory(a, try profile.check(image, .{})),
        };
    }
    return helpers;
}

fn finalFunctions(
    a: std.mem.Allocator,
    roots: []const Id,
    parameters: []const source.RecoveryBinding,
) ![]const Id {
    var result: std.ArrayList(Id) = .empty;
    for (parameters) |parameter| {
        if (std.mem.indexOfScalar(Id, roots, parameter.source_function) == null or
            std.mem.indexOfScalar(Id, result.items, parameter.function) != null) continue;
        try result.append(a, parameter.function);
    }
    return result.toOwnedSlice(a);
}

fn derivedManifest(
    a: std.mem.Allocator,
    root: *const compiler.ExportedSource,
    image: *const data.program_image.Admitted,
    options: Options,
) !artifact.Manifest {
    const effects = image.program().effects;
    const bridge = @import("service.zig").identity;
    if (effects.len != 1 or !std.mem.eql(u8, effects[0].identity, bridge)) {
        return error.InvalidBridge;
    }
    return .{
        .contract = artifact.derived_identity,
        .image = image.identity(),
        .source = root.value.emitter,
        .compiler = .{
            .horos_package = options.horos_package,
            .zig = @import("builtin").zig_version_string,
            .policy = artifact.derived_policy,
        },
        .requirements = root.retained.content.value.manifest.requirements,
        .bridge = try source.own(data.program.Effect, a, effects[0]),
        .inventory = try artifact.inventory(a, try profile.check(image, .{ .effects = effects })),
    };
}

fn buildBundle(
    a: std.mem.Allocator,
    root: *const compiler.ExportedSource,
    parent: artifact.Digest,
    selected: source.ast.Module,
    evidence: Evidence,
    specialization: ?artifact.Digest,
    options: Options,
) !artifact.Bundle {
    var compiled = try source.lowerObserved(a, selected, .{ .recovery = true });
    defer compiled.deinit();
    const bytes = try encodeImage(a, compiled.program);
    const image = try data.program_image.Admitted.decode(a, bytes);
    defer image.deinit();
    const helpers = try helperImages(a, selected, evidence.interfaces.helpers);
    const guest = try data.program_image.Admitted.decode(a, evidence.guest);
    defer guest.deinit();
    var carried = evidence;
    carried.recovery = compiled.recovery_evidence.?;
    var bundle = root.retained.content.value;
    bundle.manifest = try derivedManifest(a, root, image, options);
    bundle.image = bytes;
    bundle.guest = guest.identity();
    bundle.specialization = specialization;
    bundle.recovery = .{
        .projector = helpers[0],
        .storage = helpers[1],
        .clone_context = helpers[2],
        .clone_rebase = helpers[3],
        .anchors = try compiler.anchorsForRoles(
            a,
            evidence.interfaces.roles,
            selected,
            compiled.parameters,
        ),
        .layout = evidence.interfaces.layout,
    };
    bundle.branch_returns = try finalFunctions(
        a,
        evidence.interfaces.entries.branch_returns,
        compiled.parameters,
    );
    bundle.template_entries = try finalFunctions(
        a,
        evidence.interfaces.entries.templates,
        compiled.parameters,
    );
    bundle.evidence = try encodeEvidence(a, carried, root.value.selected.module);
    bundle.lineage = .{
        .root = root.retained.identity,
        .parent = parent,
        .generic_source = root.value.generic.digest,
        .selected_source = (try compiler.sourceModule(selected)).digest,
        .checker = artifact.derived_policy,
        .input = evidence.interfaces.input,
    };
    return bundle;
}

fn rootArtifact(
    a: std.mem.Allocator,
    candidate: *const artifact.Admitted,
    evidence: Evidence,
) !artifact.Admitted {
    const lineage = candidate.content.value.lineage orelse return error.InvalidRealization;
    var root = try artifact.Admitted.init(a, evidence.root, lineage.root);
    errdefer root.deinit();
    if (!std.mem.eql(u8, root.content.value.manifest.contract, artifact.identity))
        return error.InvalidAncestor;
    return root;
}

pub fn derive(
    a: std.mem.Allocator,
    ancestor: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
    proposal: Proposal,
    options: Options,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    const prior = if (ancestor.content.value.lineage != null)
        try decodeEvidence(storage, ancestor.content.value.evidence)
    else
        null;
    var root = if (prior) |evidence|
        try rootArtifact(storage, ancestor, evidence)
    else
        try ancestor.clone();
    defer root.deinit();
    var exported = try compiler.exportBuiltinSource(storage, &root);
    defer exported.deinit();
    if (prior) |evidence| _ = try validateExported(storage, ancestor, &exported, evidence, .{});
    try validateGuestScope(ancestor.content.value.guest, guest.identity());
    const prefix = if (prior) |evidence| evidence.steps else &.{};
    const steps = try std.mem.concat(storage, relation.Step, &.{ prefix, proposal.steps });
    const mapping = try transport(
        storage,
        initialMapping(&exported),
        exported.value.selected.module,
        steps,
    );
    const terminal = if (steps.len == 0)
        exported.value.selected.module
    else
        steps[steps.len - 1].successor;
    const evidence: Evidence = .{
        .root = try root.encode(storage),
        .guest = try encodeImage(storage, guest.program()),
        .prefix = prefix.len,
        .steps = steps,
        .selected = if (data.record.equal(source.ast.Module, terminal, proposal.selected))
            null
        else
            proposal.selected,
        .interfaces = proposal.interfaces orelse mapping.interfaces,
        .recovery = undefined,
    };
    const bundle = try buildBundle(
        storage,
        &exported,
        ancestor.identity,
        proposal.selected,
        evidence,
        mapping.specialization,
        options,
    );
    const bytes = try artifact.encode(a, bundle);
    errdefer a.free(bytes);
    var admitted = try artifact.Admitted.init(storage, bytes, artifact.digest(bytes));
    admitted.deinit();
    return bytes;
}

pub fn deriveRecord(
    a: std.mem.Allocator,
    ancestor: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
    proposal: RecordProposal,
    options: Options,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    var remaining: usize = (ValidationPolicy{}).work;
    const steps = try storage.alloc(relation.Step, proposal.steps.len);
    for (proposal.steps, steps) |record, *step| {
        step.* = try relation.decodeRecordStep(storage, record, &remaining);
    }
    return derive(a, ancestor, guest, .{
        .selected = proposal.selected,
        .steps = steps,
        .interfaces = proposal.interfaces,
    }, options);
}

const Validated = struct { mapping: Mapping, parameters: []const source.RecoveryBinding };

fn validateGuestScope(ancestor: ?artifact.Digest, successor: ?artifact.Digest) !void {
    if (ancestor) |expected| {
        const actual = successor orelse return error.GuestIdentityMismatch;
        if (!std.mem.eql(u8, &expected, &actual)) return error.GuestIdentityMismatch;
    }
}

fn validateIdentity(
    candidate: *const artifact.Admitted,
    root: *const compiler.ExportedSource,
    evidence: Evidence,
    selected: source.ast.Module,
    guest: *const data.program_image.Admitted,
) !void {
    const bundle = candidate.content.value;
    const lineage = bundle.lineage orelse return error.InvalidRealization;
    if (!std.mem.eql(u8, bundle.manifest.contract, artifact.derived_identity) or
        !std.mem.eql(u8, &lineage.root, &root.retained.identity) or
        !std.mem.eql(u8, &lineage.generic_source, &root.value.generic.digest) or
        !std.mem.eql(u8, &lineage.selected_source, &(try compiler.sourceModule(selected)).digest) or
        !std.mem.eql(u8, &bundle.manifest.source, &root.value.emitter) or
        !std.meta.eql(bundle.hooks, root.retained.content.value.hooks) or
        evidence.prefix > evidence.steps.len or
        std.mem.eql(u8, &lineage.parent, &candidate.identity))
        return error.InvalidAncestor;
    if (bundle.guest == null or !std.mem.eql(u8, &bundle.guest.?, &guest.identity()))
        return error.GuestIdentityMismatch;
    try validateGuestScope(root.retained.content.value.guest, guest.identity());
}

fn validateHelpers(
    a: std.mem.Allocator,
    candidate: *const artifact.Admitted,
    module: source.ast.Module,
    entries: [4]Id,
) !void {
    for (entries, candidate.helpers) |entry, helper| {
        var selected = module;
        selected.entry = entry;
        var lowered = try source.lower(a, selected);
        defer lowered.deinit();
        if (!data.record.equal(data.activation.Program, lowered.program, helper.program()))
            return error.InvalidRecovery;
    }
}

fn validateMaps(
    a: std.mem.Allocator,
    candidate: *const artifact.Admitted,
    selected: source.ast.Module,
    evidence: Evidence,
    mapping: Mapping,
) ![]const source.RecoveryBinding {
    const bundle = candidate.content.value;
    const lineage = bundle.lineage orelse return error.InvalidRealization;
    if (!data.record.equal(Interfaces, mapping.interfaces, evidence.interfaces) or
        !std.meta.eql(bundle.recovery.layout, mapping.interfaces.layout) or
        lineage.input != mapping.interfaces.input or
        !data.record.equal(?artifact.Digest, bundle.specialization, mapping.specialization))
        return error.InvalidRecovery;
    const parameters = try source.recovery.parameters(
        a,
        selected,
        candidate.program.program(),
        evidence.recovery,
    );
    const anchors = try compiler.anchorsForRoles(a, mapping.interfaces.roles, selected, parameters);
    const branch_returns = try finalFunctions(
        a,
        mapping.interfaces.entries.branch_returns,
        parameters,
    );
    const templates = try finalFunctions(a, mapping.interfaces.entries.templates, parameters);
    if (!data.record.equal([]const artifact.Anchor, anchors, bundle.recovery.anchors) or
        !std.mem.eql(Id, branch_returns, bundle.branch_returns) or
        !std.mem.eql(Id, templates, bundle.template_entries)) return error.InvalidRecovery;
    try validateHelpers(a, candidate, selected, mapping.interfaces.helpers);
    return parameters;
}

fn validateExported(
    a: std.mem.Allocator,
    candidate: *const artifact.Admitted,
    root: *const compiler.ExportedSource,
    evidence: Evidence,
    policy: ValidationPolicy,
) !Validated {
    const original = root.value.selected.module;
    const selected = selectedModule(evidence, original);
    const guest = try data.program_image.Admitted.decode(a, evidence.guest);
    defer guest.deinit();
    try validateIdentity(candidate, root, evidence, selected, guest);
    const initial = initialMapping(root);
    try relation.validate(a, original, selected, evidence.steps, .{
        .work = policy.work,
        .static_scopes = try staticScopes(
            a,
            original,
            initial,
            guest,
            root.retained.content.value.hooks,
            evidence.steps,
        ),
        .private_schemas = &initial.private_schemas,
        .fixed_schemas = &initial.fixed_schemas,
        .protected_functions = try protectedFunctions(a, initial.interfaces),
    });
    const mapping = try transport(a, initial, original, evidence.steps);
    return .{
        .mapping = mapping,
        .parameters = try validateMaps(a, candidate, selected, evidence, mapping),
    };
}

pub fn validate(
    a: std.mem.Allocator,
    candidate: *const artifact.Admitted,
    policy: ValidationPolicy,
) !void {
    if (candidate.content.value.evidence.len > policy.work) return error.RelationLimit;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const evidence = try decodeEvidenceWithPolicy(
        scratch,
        candidate.content.value.evidence,
        policy,
    );
    var root = try rootArtifact(scratch, candidate, evidence);
    defer root.deinit();
    var exported = try compiler.exportBuiltinSource(scratch, &root);
    defer exported.deinit();
    _ = try validateExported(scratch, candidate, &exported, evidence, policy);
}

pub fn approvedRootIdentity(candidate: *const artifact.Admitted) artifact.Digest {
    return if (candidate.content.value.lineage) |lineage| lineage.root else candidate.identity;
}

pub fn validateAgainst(
    a: std.mem.Allocator,
    candidate: *const artifact.Admitted,
    ancestor: *const artifact.Admitted,
) !void {
    const lineage = candidate.content.value.lineage orelse {
        if (!std.mem.eql(u8, &candidate.identity, &ancestor.identity)) return error.InvalidAncestor;
        return compiler.validate(a, candidate);
    };
    if (!std.mem.eql(u8, &lineage.parent, &ancestor.identity) or
        !std.mem.eql(u8, &lineage.root, &approvedRootIdentity(ancestor)))
        return error.InvalidAncestor;
    try validateGuestScope(ancestor.content.value.guest, candidate.content.value.guest);
    try compiler.validate(a, ancestor);
    try validate(a, candidate, .{});
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const evidence = try decodeEvidence(arena.allocator(), candidate.content.value.evidence);
    if (ancestor.content.value.lineage != null) {
        const prior = try decodeEvidence(arena.allocator(), ancestor.content.value.evidence);
        if (evidence.prefix != prior.steps.len or !try data.record.equalAlloc(
            []const relation.Step,
            arena.allocator(),
            evidence.steps[0..@intCast(evidence.prefix)],
            prior.steps,
        )) return error.InvalidAncestor;
    } else if (evidence.prefix != 0) return error.InvalidAncestor;
}

fn exportHelpers(
    module: source.ast.Module,
    entries: [4]Id,
    candidate: *const artifact.Admitted,
) ![4]compiler.SourceHelper {
    var helpers: [4]compiler.SourceHelper = undefined;
    for (entries, 0..) |entry, i| {
        var helper = module;
        helper.entry = entry;
        helpers[i] = .{
            .role = @fromBackingInt(@intCast(i)),
            .source = try compiler.sourceModule(helper),
            .image = candidate.helpers[i].identity(),
        };
    }
    return helpers;
}

pub fn exportSource(
    a: std.mem.Allocator,
    candidate: *const artifact.Admitted,
) !compiler.ExportedSource {
    var temporary = std.heap.ArenaAllocator.init(a);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const decoded = try decodeEvidence(scratch, candidate.content.value.evidence);
    var root = try rootArtifact(scratch, candidate, decoded);
    defer root.deinit();
    var exported = try compiler.exportBuiltinSource(a, &root);
    errdefer exported.deinit();
    const storage = exported.arena.allocator();
    exported.derived = try artifact.Admitted.init(
        storage,
        try candidate.encode(storage),
        candidate.identity,
    );
    const retained = &exported.derived.?;
    const evidence = try decodeEvidence(storage, retained.content.value.evidence);
    const validated = try validateExported(scratch, retained, &exported, evidence, .{});
    const selected = selectedModule(evidence, exported.value.selected.module);
    const mapping = try transport(
        storage,
        initialMapping(&exported),
        exported.value.selected.module,
        evidence.steps,
    );
    const bundle = retained.content.value;
    exported.value.realization = retained.identity;
    exported.value.image = bundle.manifest.image;
    exported.value.guest = bundle.guest;
    exported.value.bridge = bundle.manifest.bridge;
    exported.value.selected = try compiler.sourceModule(selected);
    exported.value.helpers = try exportHelpers(selected, mapping.interfaces.helpers, retained);
    exported.value.selected_entries = mapping.interfaces.entries;
    exported.value.selected_roles = mapping.interfaces.roles;
    exported.value.parameters = try storage.dupe(source.RecoveryBinding, validated.parameters);
    exported.value.anchors = bundle.recovery.anchors;
    exported.value.branch_returns = bundle.branch_returns;
    exported.value.template_entries = bundle.template_entries;
    exported.value.construction = evidence;
    exported.value.lineage = bundle.lineage;
    return exported;
}
