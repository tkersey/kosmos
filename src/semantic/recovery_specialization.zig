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
const producer_passes = 3;
const producer_work = producer_passes * limits.source_work;
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
    var work: u64 = producer_work;
    return try source.specialize.specializeWithWork(a, original, .{
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
const bindings = source.constructor_bindings;

fn coverageCatalog(
    a: Allocator,
    storage: Allocator,
    admitted: source.Module,
    work: *u64,
) !bindings.Catalog {
    for (admitted.constants) |literal| {
        try data.admission.spend(work, 1);
        if (admitted.schemas[@intCast(literal.schema)] != .unit) continue;
        for (admitted.values) |value| {
            try data.admission.spend(work, 1);
            if (bindings.raw(value) != null) break;
        } else return .{ .constructors = &.{}, .constants = admitted.constants };
        break;
    }
    return bindings.admitCatalog(a, storage, admitted, work);
}

fn checkCatalogs(a: Allocator, original: source.Module, d: Derivation, work: *u64) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    const before = try coverageCatalog(a, storage, original, work);
    const after = try coverageCatalog(a, storage, d.residual, work);
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
    for (catalogs) |catalog| try requireReached(catalog.reached, work);
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

    fn walk(self: *Calls, a: Allocator, proof: Derivation, entry: usize, work: *u64) !void {
        try self.function(a, proof, entry, work);
        while (self.pending.pop()) |index| {
            const term_proof = proof.terms[index];
            if (term_proof.callee) |callee| try self.function(a, proof, callee, work);
            for (term_proof.children) |child| try self.term(a, child, work);
        }
    }

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
    try calls.walk(a, proof, 0, work);
    try requireReached(reached, work);
    try requireReached(terms, work);
    try checkValues(a, proof, work);
}

fn requireReached(reached: []const bool, work: *u64) !void {
    try data.admission.spend(work, reached.len);
    if (std.mem.indexOfScalar(bool, reached, false) != null) return error.InvalidSpecialization;
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
    try checkSchemaFacts(a, value.code.schemas, value.schemas, value.uses, work);
    try checkLive(a, checked.facts.pool, checked.facts.live, value.live, work);
}

fn checkSchemaFacts(
    a: Allocator,
    catalog: []const data.program.Schema,
    expected_schemas: data.admission.SchemaFacts,
    expected_uses: data.traits.Facts,
    work: *u64,
) !void {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const mem = scratch.allocator();
    const schemas = try data.admission.schemasWithWork(mem, catalog, work);
    const equal = data.record.equalWithWork;
    if (!try equal(data.admission.SchemaFacts, schemas, expected_schemas, work))
        return error.InvalidRealization;
    const uses = try data.traits.deriveWithWork(mem, catalog, work);
    if (!try equal(data.traits.Facts, uses, expected_uses, work)) return error.InvalidRealization;
}

fn checkLive(
    a: Allocator,
    pool: *data.analysis_sets.Pool,
    live: []const []const data.analysis_sets.Root,
    submitted: []const []const []const u64,
    work: *u64,
) !void {
    if (live.len != submitted.len) return error.InvalidRealization;
    const previous = pool.work;
    pool.work = work;
    defer pool.work = previous;
    try data.admission.spend(work, live.len);
    for (live, submitted) |positions, rows| {
        if (positions.len != rows.len) return error.InvalidRealization;
        try data.admission.spend(work, rows.len);
        for (positions, rows) |root, slots| {
            const expected = try pool.materialize(a, root);
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
    const produce = source.specialize.specializeWithWork;
    var remaining = limits.source_work;
    try std.testing.expectError(
        error.UnsupportedSpecialization,
        produce(a, original, request, &remaining),
    );
    for ([_]usize{ 1, 2 }) |keys| {
        request.policy.keys_per_function = keys;
        remaining = limits.source_work;
        var bounded = try produce(a, original, request, &remaining);
        defer bounded.deinit();
        const spent = limits.source_work - remaining;
        var short = spent - 1;
        try std.testing.expectError(error.RelationLimit, produce(a, original, request, &short));
        var producer = try source.specialize.specialize(a, original, request);
        defer producer.deinit();
        try std.testing.expectEqual(keys + 1, bounded.functions.items.len);
        try std.testing.expectEqualSlices(u8, &producer.key, &bounded.key);
        const derivation = Derivation.from(&bounded);
        try checkLeafCoverage(a, derivation);
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

test "admitted explicit unit supplies the observable specialization catalog" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const entry = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(entry, try b.pure(try b.constant(void, {})));
    const module = b.module(entry, unit);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var remaining = limits.source_work;
    const observed = try bindings.admitCatalog(a, arena.allocator(), module, &remaining);
    var exact: u64 = module.values.len + 1;
    const explicit = try coverageCatalog(a, arena.allocator(), module, &exact);
    try std.testing.expectEqual(0, exact);
    try std.testing.expect(data.record.equal(bindings.Catalog, observed, explicit));
    var short: u64 = module.values.len;
    try std.testing.expectError(
        error.RelationLimit,
        coverageCatalog(a, arena.allocator(), module, &short),
    );
}

fn checkLeafCoverage(a: Allocator, proof: Derivation) !void {
    const reached = try a.alloc(bool, proof.functions.len);
    defer a.free(reached);
    @memset(reached, false);
    const terms = try a.alloc(bool, proof.terms.len);
    defer a.free(terms);
    @memset(terms, false);
    var calls: Calls = .{ .reached = reached, .terms = terms };
    defer calls.pending.deinit(a);
    var work = limits.source_work;
    try calls.walk(a, proof, 1, &work);
    try std.testing.expect(reached[1]);
    try std.testing.expect(!reached[0]);
    try std.testing.expectError(error.InvalidSpecialization, requireReached(reached, &work));
    try calls.walk(a, proof, 0, &work);
    try requireReached(reached, &work);
    try requireReached(terms, &work);
}

test "guest projection facts distinguish admitted catalogs and live rows" {
    const a = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const mem = scratch.allocator();
    const catalog: []const data.program.Schema = &.{.boolean};
    const other: []const data.program.Schema = &.{ .unit, .u64 };
    const schemas = try data.admission.schemas(mem, catalog);
    const other_schemas = try data.admission.schemas(mem, other);
    const uses = try data.traits.derive(mem, catalog);
    const other_uses = try data.traits.derive(mem, other);
    var work = limits.source_work;
    try checkSchemaFacts(a, catalog, schemas, uses, &work);
    try std.testing.expectError(
        error.InvalidRealization,
        checkSchemaFacts(a, catalog, other_schemas, uses, &work),
    );
    try std.testing.expectError(
        error.InvalidRealization,
        checkSchemaFacts(a, catalog, schemas, other_uses, &work),
    );
    var pool: data.analysis_sets.Pool = .{ .allocator = a, .limit = 4 };
    defer pool.deinit();
    const root = try pool.run(1, 3);
    const live: []const []const data.analysis_sets.Root = &.{&.{root}};
    try checkLive(a, &pool, live, &.{&.{&.{ 1, 2 }}}, &work);
    try std.testing.expectError(
        error.InvalidRealization,
        checkLive(a, &pool, live, &.{&.{&.{ 2, 3 }}}, &work),
    );
}
