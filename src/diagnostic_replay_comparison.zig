const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const kosmos = @import("root.zig");
const projection = @import("semantic/projection.zig");
const artifact = @import("semantic/artifact.zig");
const service = @import("semantic/service.zig");
const Observation = @import("semantic/observe.zig").Observation;
const Author = @import("semantic/author.zig").Author;
const example = @import("diagnostic_replay_example.zig");
const queries = kosmos.RuntimeViews.queries;
const Experiment = kosmos.RuntimeExperiment.Experiment;
const Segment = kosmos.RuntimeExperiment.Segment;

pub const Report = struct {
    reference: [32]u8,
    candidate: [32]u8,
    conclusion: @FieldType(queries.DivergenceResult, "conclusion"),
    compared: u64,
    left_length: u64,
    right_length: u64,
    left_complete: bool,
    right_complete: bool,
    left_boundary: data.process_state.Status,
    right_boundary: data.process_state.Status,
    states_equal: bool,
    states_compared: u64,
    left_base_steps: u64,
    right_base_steps: u64,
    discrepancy_revision: ?u64,
};

fn complete(experiment: *Experiment) !Segment {
    for (0..example.pump_limit) |_| {
        const result = try experiment.pump(example.base_quantum);
        if (result == .complete) return result.complete;
    }
    return error.DiagnosticPumpLimit;
}

pub fn run(
    a: std.mem.Allocator,
    image: []const u8,
    reference: *const kosmos.RuntimeArtifact,
    candidate: *const kosmos.RuntimeArtifact,
    checkpoint: []const u8,
    bound: kosmos.RuntimeViews.Binding,
) !Report {
    var left = try Experiment.init(a, image, reference, checkpoint);
    defer left.deinit();
    var right = try Experiment.init(a, image, candidate, checkpoint);
    defer right.deinit();
    var left_origin = try complete(&left);
    defer left_origin.deinit();
    var right_origin = try complete(&right);
    defer right_origin.deinit();
    try example.require(std.mem.eql(u8, checkpoint, left_origin.checkpoint));
    try example.require(std.mem.eql(u8, checkpoint, right_origin.checkpoint));
    try example.require(std.mem.eql(u8, left_origin.observation, right_origin.observation));
    return compareCuts(a, &left, &right, bound, reference, candidate);
}

fn compareCuts(
    a: std.mem.Allocator,
    left: *Experiment,
    right: *Experiment,
    bound: kosmos.RuntimeViews.Binding,
    reference: *const kosmos.RuntimeArtifact,
    candidate: *const kosmos.RuntimeArtifact,
) !Report {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const owned = arena.allocator();
    var lhs: [2]queries.Observation = undefined;
    var rhs: [2]queries.Observation = undefined;
    var states_equal = true;
    var count: usize = 0;
    var states_compared: u64 = 0;
    for (example.matching, 0..) |exchange, i| {
        const command: service.Command = .{ .advance = .{
            .control = .{ .answer = exchange.response },
            .quantum = 100,
        } };
        const encoded_control = try projection.encode(service.Command, owned, command);
        const control = artifact.digest(encoded_control);
        try left.begin(command.advance.control, command.advance.quantum);
        try right.begin(command.advance.control, command.advance.quantum);
        var l = try complete(left);
        defer l.deinit();
        var r = try complete(right);
        defer r.deinit();
        lhs[i] = .{
            .revision = left.execution.guest_revision,
            .control = control,
            .bytes = try owned.dupe(u8, l.observation),
        };
        rhs[i] = .{
            .revision = right.execution.guest_revision,
            .control = control,
            .bytes = try owned.dupe(u8, r.observation),
        };
        count += 1;
        if (lhs[i].revision != rhs[i].revision) break;
        states_equal = states_equal and std.mem.eql(u8, l.checkpoint, r.checkpoint);
        states_compared += 1;
        if (terminal(left.execution.last_cut.?.status) or
            terminal(right.execution.last_cut.?.status)) break;
    }
    return query(a, .{
        .reference = reference,
        .candidate = candidate,
        .left = left,
        .right = right,
        .bound = bound,
        .lhs = lhs[0..count],
        .rhs = rhs[0..count],
        .states_equal = states_equal,
        .states_compared = states_compared,
    });
}

const Comparison = struct {
    reference: *const kosmos.RuntimeArtifact,
    candidate: *const kosmos.RuntimeArtifact,
    left: *const Experiment,
    right: *const Experiment,
    bound: kosmos.RuntimeViews.Binding,
    lhs: []const queries.Observation,
    rhs: []const queries.Observation,
    states_equal: bool,
    states_compared: u64,
};

fn terminal(status: data.process_state.Status) bool {
    return status == .completed or status == .failed or status == .cancelled;
}

fn query(a: std.mem.Allocator, c: Comparison) !Report {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const image = try example.encode(a, try queries.divergence(&builder), true);
    defer a.free(image);
    const left_status = c.left.execution.last_cut.?.status;
    const right_status = c.right.execution.last_cut.?.status;
    var left_binding = c.bound;
    left_binding.execution = artifact.digest("diagnostic-example/reference-experiment");
    left_binding.disclosure = artifact.digest("diagnostic-example/finite-observations");
    left_binding.realization = c.reference.identity;
    left_binding.core = c.reference.program.identity();
    left_binding.guest_revision = c.left.execution.guest_revision;
    left_binding.realization_revision = c.left.execution.revision;
    var right_binding = c.bound;
    right_binding.execution = artifact.digest("diagnostic-example/candidate-experiment");
    right_binding.disclosure = left_binding.disclosure;
    right_binding.realization = c.candidate.identity;
    right_binding.core = c.candidate.program.identity();
    right_binding.guest_revision = c.right.execution.guest_revision;
    right_binding.realization_revision = c.right.execution.revision;
    const input = try projection.encode(queries.DivergenceInput, a, .{
        .left = .{
            .binding = left_binding,
            .complete = terminal(left_status) and c.lhs.len == example.matching.len,
            .observations = c.lhs,
        },
        .right = .{
            .binding = right_binding,
            .complete = terminal(right_status) and c.rhs.len == example.matching.len,
            .observations = c.rhs,
        },
    });
    defer a.free(input);
    var output = try example.execute(a, image, input);
    defer output.deinit();
    var result = try projection.decode(queries.DivergenceResult, a, output.bytes);
    defer result.deinit();
    try example.require(std.meta.eql(result.value.left, left_binding));
    try example.require(std.meta.eql(result.value.right, right_binding));
    return .{
        .reference = c.reference.identity,
        .candidate = c.candidate.identity,
        .conclusion = result.value.conclusion,
        .compared = result.value.compared,
        .left_length = c.lhs.len,
        .right_length = c.rhs.len,
        .left_complete = result.value.left_complete,
        .right_complete = result.value.right_complete,
        .left_boundary = left_status,
        .right_boundary = right_status,
        .states_equal = c.states_equal,
        .states_compared = c.states_compared,
        .left_base_steps = c.left.execution.outer.transitions,
        .right_base_steps = c.right.execution.outer.transitions,
        .discrepancy_revision = result.value.revision,
    };
}

pub fn wrongObservation(
    a: std.mem.Allocator,
    root: *const kosmos.RuntimeArtifact,
    guest: *const data.program_image.Admitted,
) !kosmos.RuntimeArtifact {
    var definition = try kosmos.RuntimeCompiler.SourceDefinition.init(
        a,
        root.content.value.guest != null,
        root.content.value.hooks,
    );
    defer definition.deinit();
    const observe = try @import("semantic/observe.zig").define(
        &definition.builder,
        definition.machine,
    );
    try corruptCompletion(&definition.builder, observe);
    const bytes = try kosmos.RuntimeCompiler.derive(a, root, guest, .{
        .selected = definition.module(),
        .steps = &.{},
    }, .{ .horos_package = root.content.value.manifest.compiler.horos_package });
    defer a.free(bytes);
    var candidate = try kosmos.RuntimeArtifact.init(a, bytes, artifact.digest(bytes));
    errdefer candidate.deinit();
    if (kosmos.RuntimeCompiler.validateAgainst(a, &candidate, root)) |_| {
        return error.ExpectedCandidateRejection;
    } else |err| {
        if (err != error.InvalidRelation) return err;
    }
    return candidate;
}

fn corruptCompletion(b: *source.Builder, observe: data.program.Id) !void {
    const e = try Author.init(b);
    const original = b.functions.items[observe].body orelse return error.MissingObserveBody;
    const schema = try projection.schema(Observation, b);
    const observed = try b.variable(schema);
    const value = try b.reference(observed);
    const tag = try b.primitive(e.integer, .variant_tag, &.{value}, 0);
    const completed_tag = @import("semantic/machine.zig").index(Observation, "completed");
    const replacement = try e.literal(Observation, .{ .completed = &example.integer(999) });
    const body = try b.bind(observed, original, try e.when(
        try e.binary(.equal, tag, try b.constant(u64, completed_tag)),
        try b.pure(replacement),
        try b.pure(value),
    ));
    b.functions.items[observe].body = body;
}
