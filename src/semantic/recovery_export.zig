const std = @import("std");
const old = @import("horos");
const current = @import("horos_recovery");
const artifact = @import("artifact.zig");
const backend = @import("recovery_backend.zig");
const legacy = @import("compiler.zig");
const roles = @import("recovery_roles.zig");
const opt = current.source.recovery_optimization;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;

pub const RecoverySourceBundle = struct {
    realization: artifact.Digest,
    image: artifact.Digest,
    emitter: artifact.Digest,
    guest: ?artifact.Digest,
    requirements: artifact.Requirements,
    bridge: old.data.program.Effect,
    generic: legacy.SourceModule,
    selected: legacy.SourceModule,
    helpers: [4]legacy.SourceHelper,
    generic_entries: legacy.SourceEntries,
    selected_entries: legacy.SourceEntries,
    generic_roles: [9]legacy.SourceRole,
    selected_roles: []const legacy.SourceRole,
    generic_pure_entries: [6]legacy.PureEntry,
    parameters: []const old.source.RecoveryBinding,
    anchors: []const artifact.Anchor,
    branch_returns: []const u64,
    template_entries: []const u64,
    evidence: struct {
        recovery: opt.Evidence,
        derivation: ?legacy.Derivation,
    },
};

pub const ExportedRecoverySource = struct {
    arena: Arena,
    value: RecoverySourceBundle,
    retained: artifact.Admitted,
    definition: legacy.SourceDefinition,
    transport: opt.Decoded,

    pub fn deinit(self: *ExportedRecoverySource) void {
        self.transport.deinit();
        self.definition.deinit();
        self.retained.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn exportRecoverySource(
    a: Allocator,
    candidate: *const artifact.Admitted,
) !ExportedRecoverySource {
    var owned = try candidate.clone();
    defer owned.deinit();
    try backend.checkManifest(&owned);
    var temporary = Arena.init(a);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    var arena = Arena.init(a);
    errdefer arena.deinit();
    const storage = arena.allocator();
    var retained = try artifact.Admitted.init(a, try owned.encode(scratch), owned.identity);
    errdefer retained.deinit();
    const bundle = retained.content.value;
    var definition = try legacy.SourceDefinition.init(a, bundle.guest != null, bundle.hooks);
    errdefer definition.deinit();
    var remaining = backend.limits.source_work;
    var validated = try backend.validateDefined(a, scratch, &remaining, &retained, &definition);
    defer validated.envelope.deinit();
    defer a.free(validated.parameters);
    errdefer validated.proof.deinit();
    const value = try sourceBundle(storage, &retained, &definition, validated);
    return .{
        .arena = arena,
        .value = value,
        .retained = retained,
        .definition = definition,
        .transport = validated.proof,
    };
}

fn sourceBundle(
    storage: Allocator,
    retained: *const artifact.Admitted,
    definition: *legacy.SourceDefinition,
    validated: backend.Validated,
) !RecoverySourceBundle {
    const derivation: ?legacy.Derivation = if (validated.envelope.derivation_bytes) |bytes|
        try readDerivation(storage, bytes)
    else
        null;
    const functions = if (validated.derivation) |d| d.functions else &.{};
    const bundle = retained.content.value;
    const pure = try pureEntries(definition);
    const original = definition.module();
    const selected = if (derivation) |d| d.residual else original;
    const parameters = try storage.alloc(old.source.RecoveryBinding, validated.parameters.len);
    for (parameters, validated.parameters) |*binding, checked| binding.* = .{
        .source_function = checked.source_function,
        .variable = checked.variable,
        .source_schema = checked.source_schema,
        .function = checked.function,
        .slot = checked.slot,
        .schema = checked.schema,
    };
    const generic_roles = try roles.selected(storage, definition, &.{});
    std.debug.assert(generic_roles.len == 9);
    return .{
        .realization = retained.identity,
        .image = bundle.manifest.image,
        .emitter = bundle.manifest.source,
        .guest = bundle.guest,
        .requirements = bundle.manifest.requirements,
        .bridge = bundle.manifest.bridge,
        .generic = try legacy.sourceModule(original),
        .selected = try legacy.sourceModule(selected),
        .helpers = try helperSources(definition, retained),
        .generic_entries = try entries(storage, definition, original.entry, &.{}),
        .selected_entries = try entries(storage, definition, selected.entry, functions),
        .generic_roles = generic_roles[0..9].*,
        .selected_roles = try roles.selected(storage, definition, functions),
        .generic_pure_entries = pure,
        .parameters = parameters,
        .anchors = bundle.recovery.anchors,
        .branch_returns = bundle.branch_returns,
        .template_entries = bundle.template_entries,
        .evidence = .{
            .derivation = derivation,
            .recovery = validated.proof.evidence,
        },
    };
}

fn readDerivation(storage: Allocator, bytes: []const u8) !legacy.Derivation {
    var reader: old.data.wire.Reader = .{ .input = bytes };
    var capacity = backend.limits.lowering_bytes;
    const result = try old.data.record.readBounded(legacy.Derivation, &reader, storage, &capacity);
    try reader.finish();
    return result;
}

fn helperSources(
    definition: *const legacy.SourceDefinition,
    retained: *const artifact.Admitted,
) ![4]legacy.SourceHelper {
    var helpers: [4]legacy.SourceHelper = undefined;
    for (definition.helpers, retained.helpers, &helpers, 0..) |entry, image, *helper, i| {
        helper.* = .{
            .role = @fromBackingInt(@intCast(i)),
            .source = try legacy.sourceModule(definition.builder.module(entry, definition.failure)),
            .image = image.identity(),
        };
    }
    return helpers;
}

const Function = current.source.specialize.FunctionProof;

fn entries(
    a: Allocator,
    definition: *const legacy.SourceDefinition,
    service: u64,
    functions: []const Function,
) !legacy.SourceEntries {
    return .{
        .service = service,
        .branch_returns = try sourceFunctions(a, definition.clone.instantiate, functions),
        .templates = try sourceFunctions(a, definition.template, functions),
    };
}

fn sourceFunctions(a: Allocator, original: u64, functions: []const Function) ![]const u64 {
    var selected: std.ArrayList(u64) = .empty;
    try selected.append(a, original);
    for (functions) |f| if (f.before == original) try selected.append(a, f.after);
    return selected.items;
}

fn pureEntries(definition: *legacy.SourceDefinition) ![6]legacy.PureEntry {
    const b = &definition.builder;
    const m = definition.machine;
    const life = try @import("lifecycle.zig").define(b, m);
    const step = try @import("step.zig").define(b, m);
    const observe = try @import("observe.zig").define(b, m);
    const functions = [_]u64{
        life.initialize, step.active, life.respond, observe, m.hydrate, m.project,
    };
    var pure: [6]legacy.PureEntry = undefined;
    for (functions, &pure, 0..) |function, *entry, i| entry.* = .{
        .role = @fromBackingInt(@intCast(i)),
        .function = function,
        .signature = b.functions.items[function],
    };
    return pure;
}
