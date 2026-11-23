const std = @import("std");
const runtime = @import("../runtime_sources.zig");
const current = @import("horos_recovery");
const source = current.source;
const data = current.data;
const legacy = runtime.compiler;
const projection = runtime.projection;
const artifact = runtime.artifact;
const Allocator = std.mem.Allocator;
const Hooks = runtime.instrumentation.Hooks;
pub const limits: source.recovery_optimization.Limits = .{};
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
    return identityFromCore(runtime.source_identity.digest());
}

fn identityFromCore(core: artifact.Digest) artifact.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(policy);
    hash.update(&core);
    hash.update(runtime.packaged.horos_package);
    hash.update(@import("recovery_options").horos_package);
    inline for (.{
        @embedFile("../runtime_sources.zig"),
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
    const bytes = try projectGuest(a, guest, limits.lowering_bytes);
    defer a.free(bytes);
    var work = limits.source_work;
    return try specialize(a, original, .{
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
    }, &work);
}

pub fn projectGuest(
    a: Allocator,
    guest: *const @import("horos_data").program_image.Admitted,
    storage_bytes: usize,
) ![]u8 {
    var physical = storage_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    return projectedBytes(cap.allocator(), guest) catch |err| {
        if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
        return err;
    };
}

fn projectedBytes(
    a: Allocator,
    guest: *const @import("horos_data").program_image.Admitted,
) ![]u8 {
    var program: projection.Program = .{
        .identity = guest.identity(),
        .code = guest.program(),
        .schemas = guest.schemaFacts(),
        .uses = guest.traits(),
        .live = &.{},
    };
    var work = limits.source_work;
    var traversal: @import("horos_data").wire.Writer = .{ .remaining = &work };
    try @import("horos_data").record.write(projection.Program, program, &traversal);
    var analysis = try guest.analysis(a);
    defer analysis.deinit();
    analysis.facts.pool.work = &work;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    try data.admission.spend(&work, analysis.facts.live.len);
    const live = try scratch.alloc([]const []const u64, analysis.facts.live.len);
    for (analysis.facts.live, live) |positions, *block| {
        try data.admission.spend(&work, positions.len);
        const rows = try scratch.alloc([]const u64, positions.len);
        for (positions, rows) |root, *row| row.* = try analysis.facts.pool.materialize(
            scratch,
            root,
        );
        block.* = rows;
    }
    program.live = live;
    return projection.encode(projection.Program, a, program);
}

pub fn validate(
    a: Allocator,
    definition: *const legacy.SourceDefinition,
    original: source.Module,
    derivation: ?Derivation,
    bundle: artifact.Bundle,
    storage_bytes: usize,
    work: *u64,
) !void {
    const d = derivation orelse {
        if (bundle.guest != null or bundle.specialization != null) return error.InvalidRealization;
        return;
    };
    const guest = bundle.guest orelse return error.InvalidRealization;
    const key = bundle.specialization orelse return error.InvalidRealization;
    if (!std.meta.eql(d.request.context, context(guest, bundle.hooks)) or
        d.residual.failure != original.failure or d.request.function != original.entry or
        d.request.function != definition.service.entry or d.request.arguments.len != 2 or
        d.request.arguments[0] != .known or d.request.arguments[1] != .dynamic or
        d.request.arguments[0].known.schema != definition.machine.program)
        return error.InvalidRealization;
    try validateGuest(a, guest, d.request.arguments[0].known.bytes, storage_bytes, work);
    try validateRelation(a, original, d, key, storage_bytes, work);
}

fn specialize(
    a: Allocator,
    original: source.Module,
    request: source.specialize.Request,
    work: *u64,
) !source.specialize.Output {
    var bounded = request;
    bounded.policy.work = @min(request.policy.work, work.*, limits.source_work);
    var out = try source.specialize.specialize(a, original, bounded);
    errdefer out.deinit();
    if (bounded.policy.work != request.policy.work) {
        out.request.policy.work = request.policy.work;
        out.key = try source.specialize.identityWithWork(a, original, out.request, work);
    }
    return out;
}

pub fn validateRelation(
    a: Allocator,
    original: source.Module,
    d: Derivation,
    key: artifact.Digest,
    storage_bytes: usize,
    work: *u64,
) !void {
    var physical = storage_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    checkRelation(cap.allocator(), original, d, key, work) catch |err| {
        if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
        return err;
    };
}

fn checkRelation(
    a: Allocator,
    original: source.Module,
    d: Derivation,
    key: artifact.Digest,
    work: *u64,
) !void {
    if (d.residual.failure != original.failure or d.request.function != original.entry)
        return error.InvalidSpecialization;
    try checkFunctions(a, original.functions.len, d, work);
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
    }) |name| @field(out.builder, name) = .fromOwnedSlice(@constCast(@field(d.residual, name)));
    out.builder.region_count = d.residual.region_count;
    try source.specialize.validateWithWork(a, original, d.request, &out, work);
    try checkCatalogs(a, original, d, work);
}

const relocation = source.relation.Relocation;
const Catalog = struct { prefix: usize, limit: usize, reached: []bool };
const Catalogs = [std.meta.tags(relocation.Kind).len]Catalog;

fn checkCatalogs(a: Allocator, original: source.Module, d: Derivation, work: *u64) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    const bindings = source.constructor_bindings;
    const before = try bindings.admitCatalog(a, storage, original, work);
    const after = try bindings.admitCatalog(a, storage, d.residual, work);
    try bindings.validate(original, before.constructors, after.constructors, .{}, work);
    var emitted = d.residual;
    emitted.constants = after.constants;
    var catalogs: Catalogs = undefined;
    inline for (comptime std.meta.tags(relocation.Kind)) |kind| {
        const field = comptime @tagName(kind) ++ "s";
        const prefix = if (kind == .region) original.region_count else @field(original, field).len;
        const submitted = if (kind == .region)
            d.residual.region_count
        else
            @field(d.residual, field).len;
        const limit = if (kind == .region) emitted.region_count else @field(emitted, field).len;
        if (prefix > submitted or submitted > limit) return error.InvalidSpecialization;
        const added = std.math.cast(usize, submitted - prefix) orelse return error.Capacity;
        try data.admission.spend(work, added);
        const reached = try storage.alloc(bool, added);
        @memset(reached, false);
        catalogs[@backingInt(kind)] = .{
            .prefix = @intCast(prefix),
            .limit = @intCast(limit),
            .reached = reached,
        };
    }
    const constants = catalogs[@backingInt(relocation.Kind.constant)];
    for (before.constants[original.constants.len..], original.constants.len..) |literal, i| {
        if (i >= d.residual.constants.len) break;
        try data.admission.spend(work, 1);
        const carried = d.residual.constants[i];
        if (try source.specialize.values.literalEqualWithWork(literal, carried, work))
            constants.reached[i - constants.prefix] = true;
    }
    try visitAdded(a, &catalogs, emitted, after.constructors, d, work);
    for (catalogs) |catalog| {
        try data.admission.spend(work, catalog.reached.len);
        if (std.mem.indexOfScalar(bool, catalog.reached, false) != null)
            return error.InvalidSpecialization;
    }
}

fn visitAdded(
    a: Allocator,
    catalogs: *Catalogs,
    emitted: source.Module,
    constructors: []const source.constructor_bindings.Binding,
    d: Derivation,
    work: *u64,
) !void {
    var pending: std.ArrayList(relocation.Reference) = .empty;
    defer pending.deinit(a);
    inline for (.{ .function, .term, .value }) |kind| {
        const proofs = @field(d, @tagName(kind) ++ "s");
        try data.admission.spend(work, proofs.len);
        for (proofs) |proof| try pending.append(a, .{ .kind = kind, .id = proof.after });
    }
    while (pending.pop()) |ref| {
        try data.admission.spend(work, 1);
        const catalog = catalogs[@backingInt(ref.kind)];
        if (ref.id >= catalog.limit) return error.InvalidSpecialization;
        if (ref.id < catalog.prefix) continue;
        const index: usize = @intCast(ref.id - catalog.prefix);
        if (index >= catalog.reached.len or catalog.reached[index]) continue;
        catalog.reached[index] = true;
        try relocation.visitReferencesWithWork(
            a,
            emitted,
            constructors,
            ref.kind,
            ref.id,
            &pending,
            work,
        );
    }
}

const Calls = struct {
    reached: []bool,
    terms: []bool,
    pending: std.ArrayList(usize) = .empty,

    fn function(
        self: *Calls,
        a: Allocator,
        proof: Derivation,
        index: usize,
        work: *u64,
    ) !void {
        try data.admission.spend(work, 1);
        if (index >= self.reached.len) return error.InvalidSpecialization;
        if (self.reached[index]) return;
        self.reached[index] = true;
        const body = proof.functions[index].body orelse return error.InvalidSpecialization;
        try self.term(a, body, work);
    }

    fn term(self: *Calls, a: Allocator, index: usize, work: *u64) !void {
        try data.admission.spend(work, 1);
        if (index >= self.terms.len) return error.InvalidSpecialization;
        if (self.terms[index]) return;
        self.terms[index] = true;
        try self.pending.append(a, index);
    }
};

fn checkFunctions(a: Allocator, function_count: usize, proof: Derivation, work: *u64) !void {
    try data.admission.spend(work, function_count);
    const counts = try a.alloc(usize, function_count);
    defer a.free(counts);
    @memset(counts, 0);
    try data.admission.spend(work, proof.functions.len);
    for (proof.functions) |f| {
        if (f.before >= counts.len) return error.InvalidSpecialization;
        const count = &counts[@intCast(f.before)];
        if (count.* >= proof.request.policy.keys_per_function) return error.InvalidSpecialization;
        count.* += 1;
    }
    try data.admission.spend(work, proof.functions.len);
    const reached = try a.alloc(bool, proof.functions.len);
    defer a.free(reached);
    @memset(reached, false);
    try data.admission.spend(work, proof.terms.len);
    const terms = try a.alloc(bool, proof.terms.len);
    defer a.free(terms);
    @memset(terms, false);
    var calls: Calls = .{ .reached = reached, .terms = terms };
    defer calls.pending.deinit(a);
    try calls.function(a, proof, 0, work);
    while (calls.pending.pop()) |index| {
        const term = proof.terms[index];
        if (term.callee) |callee| try calls.function(a, proof, callee, work);
        for (term.children) |child| try calls.term(a, child, work);
    }
    try data.admission.spend(work, reached.len);
    if (std.mem.indexOfScalar(bool, reached, false) != null) return error.InvalidSpecialization;
    try data.admission.spend(work, terms.len);
    if (std.mem.indexOfScalar(bool, terms, false) != null) return error.InvalidSpecialization;
    try checkValues(a, proof, work);
}

fn checkValues(a: Allocator, proof: Derivation, work: *u64) !void {
    try data.admission.spend(work, proof.values.len);
    const seen = try a.alloc(bool, proof.values.len);
    defer a.free(seen);
    @memset(seen, false);
    try data.admission.spend(work, proof.terms.len);
    for (proof.terms) |term| try markValues(seen, term.values, work);
    var i = seen.len;
    while (i > 0) {
        i -= 1;
        if (!seen[i]) return error.InvalidSpecialization;
        try markValues(seen[0..i], proof.values[i].children, work);
    }
}

fn markValues(seen: []bool, values: []const usize, work: *u64) !void {
    try data.admission.spend(work, values.len);
    for (values) |value| {
        if (value >= seen.len) return error.InvalidSpecialization;
        seen[value] = true;
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
    var physical = storage_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    checkGuest(cap.allocator(), guest, bytes, work) catch |err| {
        if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
        return err;
    };
}

fn checkGuest(a: Allocator, guest: artifact.Digest, bytes: []const u8, work: *u64) !void {
    try data.admission.spend(work, bytes.len);
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
    try checkLive(a, &checked.facts, value.live, work);
}

fn checkLive(
    a: Allocator,
    facts: *const data.activation_flow.Facts,
    submitted: []const []const []const u64,
    work: *u64,
) !void {
    if (facts.live.len != submitted.len) return error.InvalidRealization;
    const previous = facts.pool.work;
    facts.pool.work = work;
    defer facts.pool.work = previous;
    try data.admission.spend(work, facts.live.len);
    for (facts.live, submitted) |positions, rows| {
        if (positions.len != rows.len) return error.InvalidRealization;
        try data.admission.spend(work, rows.len);
        for (positions, rows) |root, slots| {
            const expected = try facts.pool.materialize(a, root);
            defer a.free(expected);
            try data.admission.spend(work, slots.len);
            if (!std.mem.eql(u64, expected, slots)) return error.InvalidRealization;
        }
    }
}

test "entry rooted specialization admits each requested key allowance" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const scalar = try b.scalar(u64);
    const failure = try b.scalar(void);
    const id = try b.declare(&.{scalar}, scalar, &.{}, &.{});
    try b.define(id, try b.pure(try b.reference(b.parameter(id, 0))));
    const entry = try b.declare(&.{}, scalar, &.{}, &.{});
    const one = try b.constant(u64, 1);
    const two = try b.constant(u64, 2);
    const first = try b.term(.{ .call = .{ .function = id, .arguments = &.{one} } });
    const next = try b.term(.{ .call = .{ .function = id, .arguments = &.{two} } });
    try b.define(entry, try b.bind(try b.variable(scalar), first, next));
    const original = b.module(entry, failure);
    var request: source.specialize.Request = .{
        .function = entry,
        .arguments = &.{},
        .context = context(@splat(0), .{}),
        .policy = .{ .work = 1_000_000, .keys_per_function = 0 },
    };
    var remaining: u64 = 1024;
    try std.testing.expectError(
        error.UnsupportedSpecialization,
        specialize(a, original, request, &remaining),
    );
    for ([_]usize{ 1, 2 }) |keys| {
        request.policy.keys_per_function = keys;
        remaining = 1024;
        var bounded = try specialize(a, original, request, &remaining);
        defer bounded.deinit();
        var producer = try source.specialize.specialize(a, original, request);
        defer producer.deinit();
        try std.testing.expectEqual(keys + 1, bounded.functions.items.len);
        try std.testing.expectEqualSlices(u8, &producer.key, &bounded.key);
        const derivation = Derivation.from(&bounded);
        var work: u64 = 100_000;
        try checkRelation(a, original, derivation, bounded.key, &work);
        try std.testing.expect(work < 100_000);
        var reduced = derivation;
        reduced.request.policy.keys_per_function = keys - 1;
        work = 100_000;
        try std.testing.expectError(
            error.InvalidSpecialization,
            checkFunctions(a, original.functions.len, reduced, &work),
        );
    }
}
