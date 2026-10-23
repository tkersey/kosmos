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

pub fn compile(allocator: std.mem.Allocator, options: Options) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = source.Builder.init(a);
    defer b.deinit();
    const s = try service.defineWithHooks(&b, options.guest != null, options.hooks);
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
    const original = b.module(s.entry, failure);
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
    const helper_images = try helperImages(a, &b, helpers, failure);
    const bytes = try encodeBundle(
        a,
        allocator,
        options,
        &b,
        s,
        clone,
        graph.template,
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
    return projection.encode(artifact.Bundle, allocator, .{
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

const Selector = struct { function: Id, role: artifact.Role, ordinals: []const usize };

fn anchorMap(
    a: std.mem.Allocator,
    b: *const source.Builder,
    s: service.Definition,
    clone: clones.Definition,
    parameters: []const source.RecoveryBinding,
    specialized: ?*const source.specialize.Output,
) ![]const artifact.Anchor {
    var anchors: std.ArrayList(artifact.Anchor) = .empty;
    const selectors = [_]Selector{
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
    errdefer a.free(bytes);
    var writer: data.wire.Writer = .{ .output = bytes };
    try data.record.writeAlloc(Evidence, a, evidence, &writer);
    return bytes;
}

/// Independent derivation/relocation checks over carried evidence. A caller
/// still approves the exact source/compiler policy before activating it.
pub fn validate(a: std.mem.Allocator, admitted: *const artifact.Admitted) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const bundle = admitted.content.value;
    if (!std.mem.eql(u8, &bundle.manifest.source, &@import("source_identity.zig").digest()) or
        !std.mem.eql(
            u8,
            bundle.manifest.compiler.policy,
            artifact.build_policy,
        )) return error.UnsupportedSource;
    var reader: data.wire.Reader = .{ .input = bundle.evidence };
    const evidence = try data.record.read(Evidence, &reader, scratch);
    try reader.finish();
    var expected_builder = source.Builder.init(scratch);
    defer expected_builder.deinit();
    const s = try service.defineWithHooks(&expected_builder, bundle.guest != null, bundle.hooks);
    const m = try machines.define(&expected_builder);
    const clone = try clones.define(&expected_builder, m);
    const graph = try @import("graph.zig").define(&expected_builder, m);
    const validators = try @import("clone_validation.zig").define(&expected_builder, m, clone);
    const helper_entries = [4]Id{
        try @import("recovery.zig").define(&expected_builder, m),
        try @import("recovery.zig").storage(&expected_builder, m),
        validators.context,
        validators.rebase,
    };
    const failure = try expected_builder.scalar(void);
    const original = expected_builder.module(s.entry, failure);
    const module = if (evidence.derivation) |d| d.residual else original;
    const parameters = try source.recovery.parameters(
        scratch,
        module,
        admitted.program.program(),
        evidence.recovery,
    );
    var anchors: []const artifact.Anchor = undefined;
    var branch_returns: []const Id = undefined;
    var template_entries: []const Id = undefined;
    if (evidence.derivation) |d| {
        var out = try validatedDerivation(scratch, admitted, original, s.entry, m.program, d);
        defer out.deinit();
        anchors = try anchorMap(scratch, &expected_builder, s, clone, parameters, &out);
        branch_returns = try functionMap(scratch, clone.instantiate, parameters, &out);
        template_entries = try functionMap(scratch, graph.template, parameters, &out);
    } else {
        if (bundle.specialization != null or bundle.guest != null) return error.InvalidRealization;
        anchors = try anchorMap(scratch, &expected_builder, s, clone, parameters, null);
        branch_returns = try functionMap(scratch, clone.instantiate, parameters, null);
        template_entries = try functionMap(scratch, graph.template, parameters, null);
    }
    try validateRecovery(
        scratch,
        admitted,
        &expected_builder,
        failure,
        helper_entries,
        anchors,
        branch_returns,
        template_entries,
    );
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
