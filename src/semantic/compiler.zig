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

pub const Options = struct {
    horos_package: []const u8,
    guest: ?*const data.program_image.Admitted = null,
    policy: source.specialize.Policy = .{ .work = 8_000_000, .keys_per_function = 128, .depth = 1024 },
};
pub const Derivation = struct {
    original: source.ast.Module,
    request: source.specialize.Request,
    functions: []const source.specialize.FunctionProof,
    values: []const source.specialize.ValueProof,
    terms: []const source.specialize.TermProof,
};
pub const Evidence = struct {
    module: source.ast.Module,
    recovery: @typeInfo(@FieldType(source.Compiled, "recovery_evidence")).optional.child,
    parameters: []const source.RecoveryBinding,
    derivation: ?Derivation,
    helpers: [4]source.ast.Module,
};

pub fn compile(allocator: std.mem.Allocator, options: Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = source.Builder.init(a);
    defer b.deinit();
    const s = if (options.guest != null) try service.defineStaged(&b) else try service.define(&b);
    const m = try machines.define(&b);
    const clone = try clones.define(&b, m);
    const validators = try @import("clone_validation.zig").define(&b, m, clone);
    const helpers = [4]Id{
        try @import("recovery.zig").define(&b, m),
        try @import("recovery.zig").storage(&b, m),
        validators.context,
        validators.rebase,
    };
    const failure = try b.scalar(void);
    const original = b.module(s.entry, failure);
    var specialized: ?source.specialize.Output = if (options.guest) |guest| try source.specialize.specialize(a, original, .{
        .function = s.entry,
        .arguments = &.{ .{ .known = .{ .schema = m.program, .bytes = try projection.programBytes(a, guest) } }, .dynamic },
        .context = context(guest.identity()),
        .policy = options.policy,
    }) else null;
    defer if (specialized) |*out| out.deinit();
    const module = if (specialized) |*out| out.module() else original;
    var compiled = try source.lowerObserved(a, module, .{ .recovery = true });
    defer compiled.deinit();
    try source.recovery.validate(a, module, &compiled);
    const image = try encode(a, compiled.program);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const effects = admitted.program().effects;
    if (effects.len != 1 or !std.mem.eql(u8, effects[0].identity, service.identity)) return error.InvalidBridge;
    var helper_images: [4]artifact.Helper = undefined;
    var helper_modules: [4]source.ast.Module = undefined;
    for (helpers, 0..) |helper, i| {
        helper_modules[i] = b.module(helper, failure);
        var lowered = try source.lower(a, helper_modules[i]);
        defer lowered.deinit();
        const bytes = try encode(a, lowered.program);
        const checked = try data.program_image.Admitted.decode(a, bytes);
        defer checked.deinit();
        helper_images[i] = .{ .image = bytes, .inventory = try artifact.inventory(a, try profile.check(checked, .{})) };
    }
    const anchors = try anchorMap(a, &b, s, clone, &compiled, if (specialized) |*out| out else null);
    const evidence = try encodeEvidence(a, .{
        .module = module,
        .recovery = compiled.recovery_evidence.?,
        .parameters = compiled.parameters,
        .derivation = if (specialized) |*out| .{ .original = original, .request = out.request, .functions = out.functions.items, .values = out.value_proofs.items, .terms = out.term_proofs.items } else null,
        .helpers = helper_modules,
    });
    const bytes = try projection.encode(artifact.Bundle, allocator, .{
        .manifest = .{
            .image = admitted.identity(),
            .source = @import("source_identity.zig").digest(),
            .compiler = .{ .horos_package = options.horos_package, .zig = @import("builtin").zig_version_string, .policy = artifact.build_policy },
            .requirements = .{ .base = profile.identity, .admission = artifact.admission_profile, .bridge = service.identity },
            .bridge = effects[0],
            .inventory = try artifact.inventory(a, try profile.check(admitted, .{ .effects = effects })),
        },
        .image = image,
        .guest = if (options.guest) |guest| guest.identity() else null,
        .specialization = if (specialized) |*out| out.key else null,
        .recovery = .{ .projector = helper_images[0], .storage = helper_images[1], .clone_context = helper_images[2], .clone_rebase = helper_images[3], .anchors = anchors },
        .branch_returns = try functionMap(a, clone.instantiate, &compiled, if (specialized) |*out| out else null),
        .evidence = evidence,
    });
    errdefer allocator.free(bytes);
    var checked = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer checked.deinit();
    return bytes;
}

pub fn context(guest: artifact.Digest) source.specialize.Context {
    return .{
        .core = @import("source_identity.zig").digest(),
        .guest = guest,
        .observation = artifact.digest("kosmos.canonical-pst3/3"),
        .base_profile = artifact.digest(profile.identity),
        .admission_profile = artifact.digest(artifact.admission_profile),
        .compiler_policy = artifact.digest(artifact.build_policy),
    };
}

const Selector = struct { function: Id, role: artifact.Role, ordinals: []const usize };

fn anchorMap(a: std.mem.Allocator, b: *const source.Builder, s: service.Definition, clone: clones.Definition, compiled: *const source.Compiled, specialized: ?*const source.specialize.Output) ![]const artifact.Anchor {
    var anchors: std.ArrayList(artifact.Anchor) = .empty;
    const selectors = [_]Selector{
        .{ .function = s.loop, .role = .published_service, .ordinals = &.{1} },
        .{ .function = s.loop, .role = .committed_service, .ordinals = &.{3} },
        .{ .function = s.dispatch, .role = .committed_service, .ordinals = &.{1} },
        .{ .function = s.receive, .role = .committed_service, .ordinals = &.{1} },
        .{ .function = s.receive, .role = .committed_service, .ordinals = &.{2} },
        .{ .function = s.publish, .role = .committed_service, .ordinals = &.{1} },
        .{ .function = s.publish, .role = .committed_service, .ordinals = &.{2} },
        .{ .function = s.commit, .role = .committed_machine, .ordinals = &.{0} },
        .{ .function = s.control_commit, .role = .committed_machine, .ordinals = &.{0} },
        .{ .function = clone.run, .role = .clone_context, .ordinals = &.{ 0, 1 } },
        .{ .function = clone.rebase, .role = .clone_rebase, .ordinals = &.{ 0, 1, 2, 3 } },
    };
    for (selectors) |selector| {
        try addAnchor(a, &anchors, compiled, selector, b.module(s.entry, 0), selector.function, null);
        if (specialized) |out| for (out.functions.items) |f| {
            if (f.before == selector.function) try addAnchor(a, &anchors, compiled, selector, out.module(), f.after, f.arguments);
        };
    }
    return anchors.toOwnedSlice(a);
}

fn addAnchor(a: std.mem.Allocator, anchors: *std.ArrayList(artifact.Anchor), compiled: *const source.Compiled, selector: Selector, module: source.ast.Module, function: Id, knowledge: ?[]const source.specialize.Knowledge) !void {
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
        for (compiled.parameters) |binding| if (binding.source_function == function and binding.variable == variable) {
            if (final_function) |prior| if (prior != binding.function) return error.InvalidRecovery;
            final_function = binding.function;
            try parameters.append(a, .{ .ordinal = ordinal, .slot = binding.slot, .schema = binding.schema });
            found = true;
            break;
        };
        if (!found) return; // unreachable original functions have no final slots
    }
    try anchors.append(a, .{ .function = final_function.?, .role = selector.role, .parameters = try parameters.toOwnedSlice(a) });
}

fn encode(a: std.mem.Allocator, program: data.activation.Program) ![]u8 {
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(program));
    _ = try data.program_image.encode(a, program, bytes);
    return bytes;
}

fn functionMap(a: std.mem.Allocator, original: Id, compiled: *const source.Compiled, specialized: ?*const source.specialize.Output) ![]const Id {
    var result: std.ArrayList(Id) = .empty;
    for (compiled.parameters) |binding| {
        var selected = binding.source_function == original;
        if (specialized) |out| for (out.functions.items) |f| {
            if (f.before == original and f.after == binding.source_function) selected = true;
        };
        if (selected and std.mem.indexOfScalar(Id, result.items, binding.function) == null) try result.append(a, binding.function);
    }
    return result.toOwnedSlice(a);
}

fn encodeEvidence(a: std.mem.Allocator, evidence: Evidence) ![]u8 {
    var length: data.wire.Writer = .{};
    try data.record.write(Evidence, evidence, &length);
    const bytes = try a.alloc(u8, length.position);
    var writer: data.wire.Writer = .{ .output = bytes };
    try data.record.write(Evidence, evidence, &writer);
    return bytes;
}

/// Independent derivation/relocation checks over carried evidence. A caller
/// still approves the exact source/compiler policy before activating it.
pub fn validate(a: std.mem.Allocator, admitted: *const artifact.Admitted) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var reader: data.wire.Reader = .{ .input = admitted.content.value.evidence };
    const evidence = try data.record.read(Evidence, &reader, scratch);
    try reader.finish();
    const bundle = admitted.content.value;
    if (!std.mem.eql(u8, &bundle.manifest.source, &@import("source_identity.zig").digest()) or
        !std.mem.eql(u8, bundle.manifest.compiler.policy, artifact.build_policy)) return error.UnsupportedSource;
    var expected_builder = source.Builder.init(scratch);
    defer expected_builder.deinit();
    const s = if (bundle.guest != null) try service.defineStaged(&expected_builder) else try service.define(&expected_builder);
    const m = try machines.define(&expected_builder);
    const clone = try clones.define(&expected_builder, m);
    const validators = try @import("clone_validation.zig").define(&expected_builder, m, clone);
    const helper_entries = [4]Id{
        try @import("recovery.zig").define(&expected_builder, m),
        try @import("recovery.zig").storage(&expected_builder, m),
        validators.context,
        validators.rebase,
    };
    const failure = try expected_builder.scalar(void);
    const original = expected_builder.module(s.entry, failure);
    var compiled: source.Compiled = .{ .arena = undefined, .program = admitted.program.program(), .flow = undefined, .parameters = evidence.parameters, .recovery_evidence = evidence.recovery };
    try source.recovery.validate(scratch, evidence.module, &compiled);
    var anchors: []const artifact.Anchor = undefined;
    var branch_returns: []const Id = undefined;
    if (evidence.derivation) |d| {
        if (!data.record.equal(source.ast.Module, original, d.original) or d.request.function != s.entry or d.request.arguments.len != 2 or
            d.request.arguments[0] != .known or d.request.arguments[1] != .dynamic or d.request.arguments[0].known.schema != m.program) return error.InvalidRealization;
        var known = try projection.decode(projection.Program, scratch, d.request.arguments[0].known.bytes);
        defer known.deinit();
        const guest = try data.program_image.Admitted.decode(scratch, try encode(scratch, known.value.code));
        defer guest.deinit();
        if (!std.mem.eql(u8, &guest.identity(), &(bundle.guest orelse return error.InvalidRealization)) or
            !std.mem.eql(u8, try projection.programBytes(scratch, guest), d.request.arguments[0].known.bytes)) return error.InvalidRealization;
        var out: source.specialize.Output = .{
            .builder = source.Builder.init(scratch),
            .original = d.original,
            .request = d.request,
            .entry = evidence.module.entry,
            .key = admitted.content.value.specialization orelse return error.InvalidRealization,
            .functions = .fromOwnedSlice(@constCast(d.functions)),
            .value_proofs = .fromOwnedSlice(@constCast(d.values)),
            .term_proofs = .fromOwnedSlice(@constCast(d.terms)),
        };
        defer out.deinit();
        inline for (.{ "schemas", "constants", "effects", "handlers", "resources", "variables", "values", "terms", "functions" }) |name| {
            try @field(out.builder, name).appendSlice(out.builder.allocator(), @field(evidence.module, name));
        }
        out.builder.region_count = evidence.module.region_count;
        if (!data.record.equal(source.specialize.Context, d.request.context, context(admitted.content.value.guest orelse return error.InvalidRealization))) return error.InvalidRealization;
        try source.specialize.validate(scratch, d.original, d.request, &out);
        anchors = try anchorMap(scratch, &expected_builder, s, clone, &compiled, &out);
        branch_returns = try functionMap(scratch, clone.instantiate, &compiled, &out);
    } else {
        if (bundle.specialization != null or !data.record.equal(source.ast.Module, original, evidence.module)) return error.InvalidRealization;
        anchors = try anchorMap(scratch, &expected_builder, s, clone, &compiled, null);
        branch_returns = try functionMap(scratch, clone.instantiate, &compiled, null);
    }
    if (!data.record.equal([]const artifact.Anchor, anchors, bundle.recovery.anchors)) return error.InvalidRecovery;
    if (!std.mem.eql(Id, branch_returns, bundle.branch_returns)) return error.InvalidRecovery;
    for (evidence.helpers, admitted.helpers, helper_entries) |module, helper, entry| {
        if (!data.record.equal(source.ast.Module, expected_builder.module(entry, failure), module)) return error.InvalidRecovery;
        var lowered = try source.lower(scratch, module);
        defer lowered.deinit();
        if (!data.record.equal(data.activation.Program, lowered.program, helper.program())) return error.InvalidRecovery;
    }
}
