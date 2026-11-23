const std = @import("std");
const runtime = @import("../runtime_sources.zig");
const current = @import("horos_recovery");
const source = current.source;
const data = current.data;
const old = @import("horos_data");
const legacy = runtime.compiler;
const art = runtime.artifact;
const records = @import("recovery_records.zig");
const roles = @import("recovery_roles.zig");
const spec = @import("recovery_specialization.zig");
const profile = runtime.profile;
const service = runtime.service;
const opt = source.recovery_optimization;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
pub const Derivation = spec.Derivation;
pub const policy = spec.policy;
pub const context = spec.context;
pub const limits = spec.limits;
pub const Evidence = records.Evidence;

pub const Inputs = struct {
    arena: Arena,
    original: source.Module,
    roots: roles.Roots,

    pub fn init(a: Allocator, definition: *const legacy.SourceDefinition) !Inputs {
        var physical = limits.lowering_bytes;
        var cap: data.AllocationBudget =
            .{ .parent = a, .remaining = &physical, .accounting = .live };
        var arena = Arena.init(cap.allocator());
        errdefer arena.deinit();
        const original = records.module(arena.allocator(), definition.module()) catch |err| {
            if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
            return err;
        };
        const roots = roles.roots(definition);
        arena.child_allocator = a;
        return .{ .arena = arena, .original = original, .roots = roots };
    }
};

pub const Compiled = struct { bytes: []u8, outcome: opt.Outcome };

const Selection = struct {
    module: source.Module,
    functions: []const source.specialize.FunctionProof,
    roles: []const legacy.SourceRole,
    options: opt.Options,

    fn init(
        a: Allocator,
        inputs: *const Inputs,
        derivation: ?Derivation,
        work: *u64,
    ) !Selection {
        const functions = if (derivation) |d| d.functions else &.{};
        const selected = try roles.selected(a, inputs.roots, functions, work);
        return .{
            .module = if (derivation) |d| d.residual else inputs.original,
            .functions = functions,
            .roles = selected,
            .options = .{
                .rule = .scalar_field_reuse_v1,
                .limits = limits,
                .formals = try roles.formals(a, selected, work),
            },
        };
    }

    fn interfaces(
        self: Selection,
        a: Allocator,
        definition: *const legacy.SourceDefinition,
        parameters: []const source.RecoveryBinding,
        target_count: usize,
        work: *u64,
    ) !Interfaces {
        return .{
            .anchors = try roles.anchors(a, self.roles, self.module, parameters, work),
            .branches = try roles.functionMap(
                a,
                definition.clone.instantiate,
                self.functions,
                parameters,
                self.module.functions.len,
                target_count,
                work,
            ),
            .templates = try roles.functionMap(
                a,
                definition.template,
                self.functions,
                parameters,
                self.module.functions.len,
                target_count,
                work,
            ),
        };
    }
};

const Interfaces = struct {
    anchors: []const art.Anchor,
    branches: []const u64,
    templates: []const u64,
};

pub fn compile(a: Allocator, options: legacy.Options) !Compiled {
    var definition = try legacy.SourceDefinition.init(a, options.guest != null, options.hooks);
    defer definition.deinit();
    var inputs = try Inputs.init(a, &definition);
    defer inputs.arena.deinit();
    const result = try emit(a, options, &definition, &inputs);
    errdefer a.free(result.bytes);
    var physical = limits.lowering_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    const digest = art.digest(result.bytes);
    var admitted = art.Admitted.init(cap.allocator(), result.bytes, digest) catch |err| {
        if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
        return err;
    };
    defer admitted.deinit();
    try preflight(&admitted);
    try validatePrepared(a, &admitted, &definition, &inputs);
    return result;
}

fn emit(
    a: Allocator,
    options: legacy.Options,
    definition: *const legacy.SourceDefinition,
    inputs: *const Inputs,
) !Compiled {
    var physical = limits.lowering_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    var arena = std.heap.ArenaAllocator.init(cap.allocator());
    defer arena.deinit();
    return emitDefined(a, arena.allocator(), options, definition, inputs) catch |err| {
        if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
        return err;
    };
}

fn emitDefined(
    a: Allocator,
    mem: Allocator,
    options: legacy.Options,
    definition: *const legacy.SourceDefinition,
    inputs: *const Inputs,
) !Compiled {
    var physical = limits.lowering_bytes;
    var specialization: data.AllocationBudget =
        .{ .parent = a, .remaining = &physical, .accounting = .live };
    var out = spec.select(
        specialization.allocator(),
        definition,
        inputs.original,
        options,
    ) catch |err| {
        if (err == error.OutOfMemory and specialization.exhausted) return error.Capacity;
        return err;
    };
    defer if (out) |*o| o.deinit();
    const derivation = if (out) |*o| Derivation.from(o) else null;
    var work = limits.source_work;
    const selected = try Selection.init(mem, inputs, derivation, &work);
    var result = try source.lowerRecoveryOptimized(a, selected.module, selected.options);
    defer result.deinit();
    const image = try records.limitedImage(a, result.program, limits.lowering_bytes, &work);
    defer a.free(image);
    var target_bytes = limits.lowering_bytes;
    var target_storage: data.AllocationBudget =
        .{ .parent = a, .remaining = &target_bytes, .accounting = .live };
    const target = old.program_image.Admitted.decode(
        target_storage.allocator(),
        image,
    ) catch |err| {
        if (err == error.OutOfMemory and target_storage.exhausted) return error.Capacity;
        return err;
    };
    defer target.deinit();
    const entries = try selected.interfaces(
        mem,
        definition,
        result.parameters,
        result.program.functions.len,
        &work,
    );
    const helpers = try buildHelpers(a, mem, inputs.original, definition.helpers);
    const bytes = try art.encode(a, .{
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
            .recovery = try records.transportBytes(mem, result.evidence, limits, &work),
            .derivation = derivation,
        }, limits),
    });
    return .{ .bytes = bytes, .outcome = result.outcome };
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
    try preflight(admitted);
    const bytes = try canonicalBytes(a, admitted);
    a.free(bytes);
    const bundle = admitted.content.value;
    var definition = try legacy.SourceDefinition.init(a, bundle.guest != null, bundle.hooks);
    defer definition.deinit();
    var inputs = try Inputs.init(a, &definition);
    defer inputs.arena.deinit();
    try validatePrepared(a, admitted, &definition, &inputs);
}

fn validatePrepared(
    a: Allocator,
    admitted: *const art.Admitted,
    definition: *const legacy.SourceDefinition,
    inputs: *const Inputs,
) !void {
    var remaining = limits.source_work;
    var validated = try validateDefined(a, &remaining, admitted, definition, inputs);
    defer validated.proof.deinit();
    defer a.free(validated.parameters);
}

const SnapshotAllocator = struct {
    backing: Allocator,
    references: std.atomic.Value(usize) = .init(1),

    fn release(self: *SnapshotAllocator) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) self.backing.destroy(self);
    }

    fn allocator(self: *SnapshotAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, align_to: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *SnapshotAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, align_to, ra) orelse return null;
        _ = self.references.fetchAdd(1, .monotonic);
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, align_to: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *SnapshotAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(buf, align_to, len, ra);
    }

    fn remap(
        ctx: *anyopaque,
        buf: []u8,
        align_to: std.mem.Alignment,
        len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *SnapshotAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(buf, align_to, len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, align_to: std.mem.Alignment, ra: usize) void {
        const self: *SnapshotAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, align_to, ra);
        self.release();
    }
};

pub fn independentCopy(a: Allocator, owned: *const art.Admitted) !art.Admitted {
    try preflight(owned);
    var physical = limits.lowering_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    const bytes = canonicalBytes(cap.allocator(), owned) catch |err| {
        if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
        return err;
    };
    defer cap.allocator().free(bytes);
    return admitSnapshot(&cap, bytes, owned.identity);
}

fn admitSnapshot(
    cap: *data.AllocationBudget,
    bytes: []const u8,
    identity: art.Digest,
) !art.Admitted {
    const storage = cap.allocator().create(SnapshotAllocator) catch |err| {
        if (cap.exhausted) return error.Capacity;
        return err;
    };
    storage.* = .{ .backing = cap.allocator() };
    const result = art.Admitted.init(storage.allocator(), bytes, identity) catch |err| {
        storage.release();
        if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
        return err;
    };
    storage.backing = cap.parent;
    storage.release();
    return result;
}

fn canonicalBytes(a: Allocator, owned: *const art.Admitted) ![]u8 {
    const core = owned.core orelse return error.InvalidState;
    var physical = core.encoded_length;
    if (physical > limits.lowering_bytes) return error.Capacity;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    const bytes = owned.encode(cap.allocator()) catch |err| {
        if (err == error.OutOfMemory and cap.exhausted) return error.ArtifactIdentityMismatch;
        return err;
    };
    errdefer a.free(bytes);
    if (bytes.len != core.encoded_length or !std.mem.eql(u8, &art.digest(bytes), &owned.identity))
        return error.ArtifactIdentityMismatch;
    return bytes;
}

fn bindImage(
    handle: @FieldType(art.Core, "executable"),
    mirror: *const old.program_image.Admitted,
    bytes: []const u8,
    work: *u64,
) !void {
    const core = handle.core orelse return error.InvalidState;
    const admitted = core.admitted();
    if (admitted != mirror) return error.ArtifactIdentityMismatch;
    try data.admission.spend(work, bytes.len);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(old.program_image.identity_domain);
    hash.update(bytes);
    if (!std.mem.eql(u8, &hash.finalResult(), &admitted.identity()))
        return error.ArtifactIdentityMismatch;
}

pub fn bindOwners(owned: *const art.Admitted, work: *u64) !void {
    const core = owned.core orelse return error.InvalidState;
    const bundle = core.content.value;
    try bindImage(core.executable, core.program, bundle.image, work);
    if (!std.mem.eql(u8, &core.program.identity(), &bundle.manifest.image))
        return error.ArtifactIdentityMismatch;
    const recovery = bundle.recovery;
    for (core.helper_executables, core.helpers, [_]art.Helper{
        recovery.projector, recovery.storage, recovery.clone_context, recovery.clone_rebase,
    }) |handle, mirror, helper| try bindImage(handle, mirror, helper.image, work);
}

pub fn preflight(admitted: *const art.Admitted) !void {
    const core = admitted.core orelse return error.InvalidState;
    if (core.encoded_length > limits.lowering_bytes) return error.Capacity;
    const bundle = admitted.content.value;
    const m = bundle.manifest;
    if (bundle.lineage != null or !std.mem.eql(u8, m.contract, art.identity) or
        !std.mem.eql(u8, m.compiler.policy, policy) or
        !std.mem.eql(u8, &m.source, &spec.identity()) or
        !std.mem.eql(u8, m.compiler.horos_package, @import("recovery_options").horos_package) or
        !std.mem.eql(u8, m.compiler.zig, @import("builtin").zig_version_string))
        return error.UnsupportedSource;
    if (bundle.image.len > limits.lowering_bytes) return error.Capacity;
    if ((bundle.guest != null) != (bundle.specialization != null)) return error.InvalidRealization;
    _ = try records.evidenceParts(bundle.evidence, bundle.guest != null, limits);
    var work = limits.source_work;
    var sizing: data.wire.Writer = .{ .remaining = &work };
    try data.record.write(art.Bundle, bundle, &sizing);
    try bindOwners(admitted, &work);
}

pub const Validated = struct {
    parameters: []const source.RecoveryBinding,
    proof: opt.Decoded,
};

pub fn validateDefined(
    a: Allocator,
    remaining: *u64,
    admitted: *const art.Admitted,
    definition: *const legacy.SourceDefinition,
    inputs: *const Inputs,
) !Validated {
    var physical = limits.lowering_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    var arena = std.heap.ArenaAllocator.init(cap.allocator());
    defer arena.deinit();
    return checkDefined(a, arena.allocator(), remaining, admitted, definition, inputs) catch |err| {
        if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
        return err;
    };
}

fn checkDefined(
    a: Allocator,
    scratch: Allocator,
    remaining: *u64,
    admitted: *const art.Admitted,
    definition: *const legacy.SourceDefinition,
    inputs: *const Inputs,
) !Validated {
    const bundle = admitted.content.value;
    var envelope = try records.decodeEvidence(
        a,
        bundle.evidence,
        bundle.guest != null,
        limits,
        remaining,
    );
    defer envelope.deinit();
    const evidence = envelope.value;
    var proof = try opt.decode(a, evidence.recovery, limits);
    errdefer proof.deinit();
    try spec.validate(
        a,
        definition,
        inputs.original,
        evidence.derivation,
        bundle,
        limits.lowering_bytes,
        remaining,
    );
    const selected = try Selection.init(scratch, inputs, evidence.derivation, remaining);
    const parameters = try validateSelected(
        a,
        scratch,
        admitted,
        definition,
        inputs.original,
        selected,
        proof.evidence,
        remaining,
    );
    return .{ .parameters = parameters, .proof = proof };
}

fn validateSelected(
    a: Allocator,
    mem: Allocator,
    admitted: *const art.Admitted,
    definition: *const legacy.SourceDefinition,
    original: source.Module,
    selected: Selection,
    proof: opt.Evidence,
    work: *u64,
) ![]const source.RecoveryBinding {
    const bundle = admitted.content.value;
    const target = try records.targetProgram(mem, admitted.program, limits.lowering_bytes, work);
    const expected = try manifest(mem, admitted.program);
    if (!try data.record.equalWithWork(art.Manifest, expected, bundle.manifest, work))
        return error.ArtifactIdentityMismatch;
    const parameters = try opt.parameters(
        a,
        selected.module,
        target,
        proof,
        selected.options,
    );
    errdefer a.free(parameters);
    const mapped = try selected.interfaces(mem, definition, parameters, target.functions.len, work);
    const equal = data.record.equalWithWork;
    if (!try equal([]const art.Anchor, mapped.anchors, bundle.recovery.anchors, work) or
        !try equal([]const u64, mapped.branches, bundle.branch_returns, work) or
        !try equal([]const u64, mapped.templates, bundle.template_entries, work))
        return error.InvalidRecovery;
    const helpers = [_]art.Helper{
        bundle.recovery.projector,     bundle.recovery.storage,
        bundle.recovery.clone_context, bundle.recovery.clone_rebase,
    };
    for (definition.helpers, helpers, admitted.helpers) |entry, helper, owner| {
        var selected_helper = original;
        selected_helper.entry = entry;
        var compiled = try source.lower(a, selected_helper);
        defer compiled.deinit();
        try records.checkProgramWithWork(owner, compiled.program, work);
        const inventory = try art.inventory(mem, try profile.check(owner, .{}));
        if (!try equal(art.Inventory, inventory, helper.inventory, work))
            return error.InvalidInventory;
        const bytes = try records.image(a, a, compiled.program);
        defer a.free(bytes);
        if (bytes.len != helper.image.len) return error.InvalidRecovery;
        try data.admission.spend(work, bytes.len);
        if (!std.mem.eql(u8, bytes, helper.image)) return error.InvalidRecovery;
    }
    return parameters;
}

test "private admission reports its own storage refusal and preserves backing allocator errors" {
    const a = std.testing.allocator;
    const bytes = runtime.packaged.bytes;
    const identity = art.digest(bytes);
    var physical: usize = @sizeOf(SnapshotAllocator);
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    try std.testing.expectError(error.Capacity, admitSnapshot(&cap, bytes, identity));
    try std.testing.expectEqual(@sizeOf(SnapshotAllocator), physical);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    cap.parent = failing.allocator();
    physical = limits.lowering_bytes;
    try std.testing.expectError(error.OutOfMemory, admitSnapshot(&cap, bytes, identity));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try std.testing.expectEqual(limits.lowering_bytes, physical);
}
