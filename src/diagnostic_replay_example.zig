const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const kosmos = @import("root.zig");
const projection = @import("semantic/projection.zig");
const artifact = @import("semantic/artifact.zig");
const base = @import("base/session.zig");
const fixture = @import("diagnostic_fixture");
const publication = @import("diagnostic_replay_publication.zig");
const comparison = @import("diagnostic_replay_comparison.zig");
const analysis = kosmos.RuntimeAnalysis;
const views = kosmos.RuntimeViews;
const queries = views.queries;

pub const hidden = fixture.hidden;
pub const answer = fixture.answer;
pub const guest = fixture.guest;
pub const integer = fixture.integer;
pub const arguments = fixture.arguments;
pub const expected_terminal = integer(answer);
pub const allocation_limit = 4 * 1024 * 1024 * 1024;
pub const execution_limit = 64 * 1024 * 1024;
pub const input_limit = 1024 * 1024;
pub const output_limit = 1024 * 1024;
pub const base_quantum = 4096;
pub const pump_limit = 4096;
pub const Limits = struct {
    input_bytes: usize = input_limit,
    working_bytes: usize = execution_limit,
    output_bytes: usize = output_limit,
    pumps: u64 = pump_limit,
    quantum: u64 = base_quantum,
};
pub const matching = [_]analysis.ReplayExchange{
    .{ .expected_request = .{ .effect = 0, .payload = &integer(11) }, .response = &integer(5) },
    .{ .expected_request = .{ .effect = 0, .payload = &integer(22) }, .response = &integer(7) },
};

pub fn require(condition: bool) !void {
    if (!condition) {
        std.debug.dumpCurrentStackTrace(.{});
        return error.DiagnosticWitnessFailed;
    }
}

pub fn encode(a: std.mem.Allocator, module: source.ast.Module, pure: bool) ![]u8 {
    var compiled = try source.lower(a, module);
    defer compiled.deinit();
    if (pure and compiled.program.effects.len != 0) return error.ImpureDiagnostic;
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    const admitted = try data.program_image.Admitted.decode(a, bytes);
    defer admitted.deinit();
    if (pure and admitted.program().effects.len != 0) return error.ImpureDiagnostic;
    return bytes;
}

pub const Execution = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    base_steps: u64,
    working_peak: u64,

    pub fn deinit(self: *Execution) void {
        self.allocator.free(self.bytes);
    }
};

pub fn execute(a: std.mem.Allocator, image: []const u8, input: []const u8) !Execution {
    return executeWithLimits(a, image, input, .{});
}

pub fn executeWithLimits(
    a: std.mem.Allocator,
    image: []const u8,
    input: []const u8,
    limits: Limits,
) !Execution {
    if (input.len > limits.input_bytes) return error.DiagnosticInputLimit;
    var working: kosmos.AllocationBudget = .{ .parent = a, .limit = limits.working_bytes };
    var prepared = try base.Prepared.init(working.allocator(), image);
    defer prepared.deinit();
    if (prepared.core.?.admitted().program().effects.len != 0) return error.ImpureDiagnostic;
    var session = try base.Session.start(working.allocator(), &prepared, input, .{});
    defer session.deinit();
    for (0..limits.pumps) |_| {
        const outcome = try session.run(limits.quantum);
        switch (outcome) {
            .progressed => {},
            .completed => |value| {
                const output = try session.bytes(&value);
                if (output.len > limits.output_bytes) return error.DiagnosticOutputLimit;
                return .{
                    .allocator = a,
                    .bytes = try a.dupe(u8, output),
                    .base_steps = session.transitions,
                    .working_peak = working.peak,
                };
            },
            .requested => return error.ImpureDiagnostic,
            else => return error.DiagnosticAnalysisFailed,
        }
    }
    return error.DiagnosticPumpLimit;
}

pub const ReplayReport = struct {
    program: [32]u8,
    input: [32]u8,
    stop: analysis.ReplayStop,
    mismatch: analysis.ReplayStop,
    matched: u64,
    guest_steps: u64,
    base_steps: u64,
    program_bytes: u64,
    input_bytes: u64,
    summary_bytes: u64,
    working_peak: u64,
    budget_rejections: u64,
};
pub const RetentionReport = struct {
    binding: views.Binding,
    reachable: @FieldType(queries.RetentionResult, "conclusion"),
    restricted: @FieldType(queries.RetentionResult, "conclusion"),
    absent: @FieldType(queries.RetentionResult, "conclusion"),
    complete_graph: bool,
    value_coverage: views.Coverage,
    disclosed_blobs: u64,
    view_bytes: u64,
};
pub const Report = struct {
    guest: [32]u8,
    start: [32]u8,
    checkpoint_bytes: u64,
    acquired: u64,
    committed: u64,
    publication_failures: u64,
    live_owner_unchanged: bool,
    retention: RetentionReport,
    replay: ReplayReport,
    agreement: comparison.Report,
    discrepancy: comparison.Report,
    allocation_peak: u64,
    construction_limit: u64,
    optional_analysis_failure: enum { ImpureDiagnostic },
    limits: Limits,
    replay_as_reply_rejected: bool,
    tool_requests_remained_data: bool,
};

pub fn run(allocator: std.mem.Allocator) !Report {
    var budget: kosmos.AllocationBudget = .{ .parent = allocator, .limit = allocation_limit };
    var report = try runBounded(budget.allocator());
    report.allocation_peak = budget.peak;
    return report;
}

fn runBounded(a: std.mem.Allocator) !Report {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const image = try encode(a, try guest(&builder), false);
    defer a.free(image);
    const input = try arguments(a);
    defer a.free(input);
    const packaged = @import("packaged_runtime").bytes;
    var root = try kosmos.RuntimeArtifact.init(a, packaged, artifact.digest(packaged));
    defer root.deinit();
    const instrumented_bytes = try kosmos.RuntimeCompiler.compile(a, .{
        .horos_package = root.content.value.manifest.compiler.horos_package,
        .hooks = .{ .control = true, .storage = true },
    });
    defer a.free(instrumented_bytes);
    var instrumented = try kosmos.RuntimeArtifact.init(a, instrumented_bytes, artifact.digest(
        instrumented_bytes,
    ));
    defer instrumented.deinit();
    try kosmos.RuntimeCompiler.validate(a, &instrumented);
    var prepared = try kosmos.Prepared.initWithRuntime(a, image, &instrumented);
    defer prepared.deinit();
    var origin = try publication.Origin.init(a, &prepared, input);
    defer origin.deinit();
    var live = try publication.Origin.init(a, &prepared, input);
    defer live.deinit();
    var recorded = try publication.record(a, &origin);
    defer recorded.deinit();
    try optionalFailure(a, &origin, image, input);
    try origin.owner.close();
    return investigations(a, image, &root, &instrumented, &prepared, &origin, &live, &recorded);
}

fn investigations(
    a: std.mem.Allocator,
    image: []const u8,
    root: *const kosmos.RuntimeArtifact,
    instrumented: *const kosmos.RuntimeArtifact,
    prepared: *const kosmos.Prepared,
    origin: *publication.Origin,
    live: *publication.Origin,
    recorded: *const publication.Recording,
) !Report {
    const admitted = prepared.guest.core.?.admitted();
    const bound = origin.viewBinding(admitted.identity(), instrumented.program.identity());
    const retention_report = try retention(a, admitted, origin.checkpoint(), bound);
    const replay_report = try replay(a, admitted, origin.checkpoint(), recorded, live);
    try inertToolRequests(a, live);
    const agreement = try comparison.run(a, image, root, instrumented, origin.checkpoint(), bound);
    var candidate = try comparison.wrongObservation(a, root, admitted);
    defer candidate.deinit();
    const discrepancy = try comparison.run(a, image, root, &candidate, origin.checkpoint(), bound);
    try require(agreement.conclusion == .observed_agreement and agreement.states_equal);
    try require(agreement.compared == 2 and agreement.states_compared == 2);
    try require(agreement.left_complete and agreement.right_complete);
    try require(discrepancy.conclusion == .divergence and discrepancy.states_equal);
    try require(discrepancy.states_compared == 2);
    try live.unchanged();
    try live.release();
    return .{
        .guest = admitted.identity(),
        .start = artifact.digest(origin.checkpoint()),
        .checkpoint_bytes = origin.checkpoint().len,
        .acquired = recorded.acquired,
        .committed = recorded.committed,
        .publication_failures = recorded.failed_attempts,
        .live_owner_unchanged = true,
        .retention = retention_report,
        .replay = replay_report,
        .agreement = agreement,
        .discrepancy = discrepancy,
        .allocation_peak = 0,
        .construction_limit = allocation_limit,
        .optional_analysis_failure = .ImpureDiagnostic,
        .limits = .{},
        .replay_as_reply_rejected = true,
        .tool_requests_remained_data = true,
    };
}

fn queryRetention(
    a: std.mem.Allocator,
    image: []const u8,
    view: views.GuestView,
    target: u64,
) !@FieldType(queries.RetentionResult, "conclusion") {
    const input = try projection.encode(queries.RetentionInput, a, .{
        .view = view,
        .target = target,
    });
    defer a.free(input);
    var output = try execute(a, image, input);
    defer output.deinit();
    var result = try projection.decode(queries.RetentionResult, a, output.bytes);
    defer result.deinit();
    try require(std.meta.eql(result.value.binding, view.binding));
    return result.value.conclusion;
}

fn retention(
    a: std.mem.Allocator,
    admitted: *const data.program_image.Admitted,
    checkpoint: []const u8,
    bound: views.Binding,
) !RetentionReport {
    var view = try views.captureDetailed(a, admitted, checkpoint, bound, .{});
    defer view.deinit();
    try require(view.value.value_coverage == .not_requested and view.value.snapshot == null);
    try require(view.value.values.len == 0 and view.value.blobs.len == 0);
    const graph = view.value.metadata;
    try require(graph.roots.len > 0 and graph.complete_graph);
    const mask = try a.alloc(bool, graph.nodes.len);
    defer a.free(mask);
    @memset(mask, false);
    var restricted = try views.capture(a, admitted, checkpoint, bound, mask);
    defer restricted.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const image = try encode(a, try queries.retention(&builder), true);
    defer a.free(image);
    const reachable = try queryRetention(a, image, graph, graph.roots[0].node);
    const unknown = try queryRetention(a, image, restricted.value, graph.roots[0].node);
    const absent = try queryRetention(a, image, graph, std.math.maxInt(u64));
    try require(reachable == .reachable and unknown == .unknown_partial);
    try require(absent == .absent_complete);
    const bytes = try views.encodeDetailed(a, view.value);
    defer a.free(bytes);
    try require(std.mem.indexOf(u8, bytes, hidden) == null);
    return .{
        .binding = bound,
        .reachable = reachable,
        .restricted = unknown,
        .absent = absent,
        .complete_graph = graph.complete_graph,
        .value_coverage = view.value.value_coverage,
        .disclosed_blobs = view.value.blobs.len,
        .view_bytes = bytes.len,
    };
}

fn replayInput(
    binding: analysis.ReplayBinding,
    exchanges: []const analysis.ReplayExchange,
) analysis.ReplayInput {
    return .{ .transcript = .{
        .binding = binding,
        .exchanges = exchanges,
        .ending = .{ .terminal = .{ .completed = &expected_terminal } },
    }, .guest_quantum = 100 };
}

fn replay(
    a: std.mem.Allocator,
    admitted: *const data.program_image.Admitted,
    checkpoint: []const u8,
    recorded: *const publication.Recording,
    live: *publication.Origin,
) !ReplayReport {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const program = try analysis.replay(&builder, admitted, .{ .checkpoint = checkpoint }, .{
        .observation = true,
        .snapshot = true,
    });
    const image = try encode(a, program.module, true);
    defer a.free(image);
    const input = try projection.encode(analysis.ReplayInput, a, replayInput(
        program.binding,
        &recorded.exchanges,
    ));
    defer a.free(input);
    var output = try execute(a, image, input);
    defer output.deinit();
    var decoded = try projection.decode(analysis.ReplayOutput, a, output.bytes);
    defer decoded.deinit();
    try require(decoded.value.stopping == .terminal_matched);
    try require(decoded.value.matched_exchanges == 2);
    try publication.rejectReplayReply(a, live, output.bytes);
    try require(std.mem.eql(u8, decoded.value.observation.?.completed, &integer(answer)));
    const final_state = try data.state_image.emit(a, decoded.value.snapshot.?);
    defer a.free(final_state);
    try require(std.mem.eql(u8, final_state, recorded.checkpoint));
    const mismatch = try wrongReplay(a, image, program.binding);
    var again = try execute(a, image, input);
    defer again.deinit();
    try require(std.mem.eql(u8, output.bytes, again.bytes));
    return .{
        .program = artifact.digest(image),
        .input = artifact.digest(input),
        .stop = decoded.value.stopping,
        .mismatch = mismatch,
        .matched = decoded.value.matched_exchanges,
        .guest_steps = decoded.value.guest_steps,
        .base_steps = output.base_steps,
        .program_bytes = image.len,
        .input_bytes = input.len,
        .summary_bytes = try summary(a, admitted, checkpoint, recorded),
        .working_peak = output.working_peak,
        .budget_rejections = try budgetFailures(a, image, input),
    };
}

fn wrongReplay(
    a: std.mem.Allocator,
    image: []const u8,
    binding: analysis.ReplayBinding,
) !analysis.ReplayStop {
    var wrong = matching;
    wrong[0].expected_request.payload = &integer(22);
    const input = try projection.encode(analysis.ReplayInput, a, replayInput(binding, &wrong));
    defer a.free(input);
    var output = try execute(a, image, input);
    defer output.deinit();
    var decoded = try projection.decode(analysis.ReplayOutput, a, output.bytes);
    defer decoded.deinit();
    try require(decoded.value.stopping == .payload_mismatch);
    try require(decoded.value.matched_exchanges == 0 and decoded.value.boundary == .parked);
    return decoded.value.stopping;
}

fn summary(
    a: std.mem.Allocator,
    admitted: *const data.program_image.Admitted,
    checkpoint: []const u8,
    recorded: *const publication.Recording,
) !u64 {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const program = try analysis.replay(&builder, admitted, .{ .checkpoint = checkpoint }, .{});
    const image = try encode(a, program.module, true);
    defer a.free(image);
    const input = try projection.encode(analysis.ReplayInput, a, replayInput(
        program.binding,
        &recorded.exchanges,
    ));
    defer a.free(input);
    var output = try execute(a, image, input);
    defer output.deinit();
    var decoded = try projection.decode(analysis.ReplayOutput, a, output.bytes);
    defer decoded.deinit();
    try require(decoded.value.stopping == .terminal_matched);
    try require(decoded.value.observation == null and decoded.value.snapshot == null);
    return output.bytes.len;
}

fn expectFailure(
    a: std.mem.Allocator,
    image: []const u8,
    input: []const u8,
    limits: Limits,
    expected: anyerror,
) !void {
    if (executeWithLimits(a, image, input, limits)) |successful| {
        var output = successful;
        output.deinit();
        return error.ExpectedDiagnosticFailure;
    } else |err| {
        if (err != expected) return err;
    }
}

fn budgetFailures(a: std.mem.Allocator, image: []const u8, input: []const u8) !u64 {
    try expectFailure(a, image, input, .{ .input_bytes = 0 }, error.DiagnosticInputLimit);
    try expectFailure(a, image, input, .{ .working_bytes = 0 }, error.OutOfMemory);
    try expectFailure(a, image, input, .{ .output_bytes = 0 }, error.DiagnosticOutputLimit);
    try expectFailure(a, image, input, .{ .pumps = 0 }, error.DiagnosticPumpLimit);
    return 4;
}

fn optionalFailure(
    a: std.mem.Allocator,
    origin: *publication.Origin,
    image: []const u8,
    input: []const u8,
) !void {
    const binding = try origin.owner.runtimeBinding();
    const before = try origin.owner.checkpoint(a);
    defer a.free(before);
    try expectFailure(a, image, input, .{}, error.ImpureDiagnostic);
    const after = try origin.owner.checkpoint(a);
    defer a.free(after);
    try require(std.mem.eql(u8, before, after));
    try require(std.meta.eql(binding, try origin.owner.runtimeBinding()));
}

fn inertToolRequests(a: std.mem.Allocator, live: *publication.Origin) !void {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const e = try @import("semantic/author.zig").Author.init(&builder);
    const RequestedActions = struct { operation: []const u8, disclosure: []const u8 };
    const schema = try projection.schema(RequestedActions, &builder);
    const entry = try builder.declare(&.{}, schema, &.{}, &.{});
    try builder.define(entry, try builder.pure(try e.literal(RequestedActions, .{
        .operation = "dispatch",
        .disclosure = "more disclosure",
    })));
    const image = try encode(a, builder.module(entry, e.unit), true);
    defer a.free(image);
    var output = try execute(a, image, &.{});
    defer output.deinit();
    var decoded = try projection.decode(RequestedActions, a, output.bytes);
    defer decoded.deinit();
    try require(std.mem.eql(u8, decoded.value.operation, "dispatch"));
    try require(std.mem.eql(u8, decoded.value.disclosure, "more disclosure"));
    try live.unchanged();
}
