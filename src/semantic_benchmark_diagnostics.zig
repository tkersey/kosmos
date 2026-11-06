const std = @import("std");
const source = @import("horos").source;
const data = @import("horos_data");
const kosmos = @import("root.zig");
const native = @import("native_baseline");
const base = @import("base/session.zig");
const projection = @import("semantic/projection.zig");
const analysis = @import("semantic/analysis.zig");
const bench = @import("semantic_benchmark.zig");
const fixtures = @import("semantic_benchmark_diagnostics_fixtures.zig");
const views = @import("semantic_benchmark_diagnostics_views.zig");

pub const Context = struct {
    a: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    generic: *const kosmos.RuntimeArtifact,
    instrumented: *const kosmos.RuntimeArtifact,
};
const Case = enum { matching, first_mismatch, later_mismatch };
const Run = struct {
    context: Context,
    fixture: fixtures.Fixture,
    reference: fixtures.Reference,
    guest: *const data.program_image.Admitted,
    guest_work: u64,
};

pub fn measure(context: Context) !void {
    try bench.emit(context.output, .{
        .phase = "diagnostics-environment",
        .replicates = 3,
        .samples_per_family = 3,
        .clock = "awake nanoseconds",
        .allocator = "requested bytes through AllocationBudget over process GPA",
        .preparation = "one immutable preparation per fixture and capture mode; reused for cases",
        .construction = "start admission, source construction and lowering combined",
        .execution = "guest steps, request and terminal comparison, optional projection combined",
        .publication = "in-memory RuntimeCapsule encoding only; no external publication",
        .cache = "no application cache; process and OS caches uncontrolled",
        .cpu_model = @import("builtin").cpu.model.name,
        .query_count = 3,
        .concurrency = 1,
    });
    for (std.meta.tags(fixtures.Family)) |family| {
        for (0..3) |sample| try measureFixture(context, family, sample);
    }
}

fn measureFixture(context: Context, family: fixtures.Family, sample: usize) !void {
    var arena = std.heap.ArenaAllocator.init(context.a);
    defer arena.deinit();
    const a = arena.allocator();
    var construction = bench.meter(context.a);
    var start = bench.now(context.io);
    const fixture = try fixtures.make(construction.allocator(), family, sample);
    defer construction.allocator().free(fixture.image);
    defer construction.allocator().free(fixture.input);
    const construction_ns = bench.elapsed(context.io, start);
    start = bench.now(context.io);
    const guest = try data.program_image.Admitted.decode(a, fixture.image);
    defer guest.deinit();
    const admission_ns = bench.elapsed(context.io, start);
    var direct = try native.Prepared.init(a, fixture.image);
    defer direct.deinit();
    var trace: std.ArrayList(bench.Step) = .empty;
    const baseline = try bench.run(
        native,
        context.io,
        a,
        &direct,
        fixture.input,
        sample,
        a,
        &trace,
        true,
    );
    const reference = try fixtures.reference(a, trace.items);
    if (reference.exchanges.len != fixture.requests) return error.RequestCountChanged;
    if (family == .aliased_graph) try fixtures.assertAliased(a, reference.pending);
    try bench.emit(context.output, .{
        .phase = "diagnostics-fixture",
        .family = @tagName(family),
        .sample = sample,
        .elements = fixture.elements,
        .requests = fixture.requests,
        .input_bytes = fixture.input.len,
        .guest_image_bytes = fixture.image.len,
        .construction_lowering_ns = construction_ns,
        .guest_admission_ns = admission_ns,
        .construction_live_bytes = construction.live,
        .construction_peak_bytes = construction.peak,
        .native_baseline = baseline,
    });
    try measurePair(context, fixture, a, &trace);
    const run: Run = .{
        .context = context,
        .fixture = fixture,
        .reference = reference,
        .guest = guest,
        .guest_work = baseline.guest_work,
    };
    try views.measure(
        context.a,
        context.io,
        context.output,
        guest,
        reference.pending,
        family,
        sample,
        context.generic,
    );
    for ([_]bool{ false, true }) |snapshot| try measureReplay(run, snapshot);
}

fn measurePair(
    context: Context,
    fixture: fixtures.Fixture,
    a: std.mem.Allocator,
    trace: *std.ArrayList(bench.Step),
) !void {
    var preparation = bench.meter(context.a);
    var start = bench.now(context.io);
    var plain = try kosmos.Prepared.initWithRuntime(
        preparation.allocator(),
        fixture.image,
        context.generic,
    );
    defer plain.deinit();
    const plain_prepare_ns = bench.elapsed(context.io, start);
    start = bench.now(context.io);
    var observed = try kosmos.Prepared.initWithRuntime(
        preparation.allocator(),
        fixture.image,
        context.instrumented,
    );
    defer observed.deinit();
    try bench.emit(context.output, .{
        .phase = "diagnostics-paired-preparation",
        .family = @tagName(fixture.family),
        .sample = fixture.sample,
        .plain_prepare_ns = plain_prepare_ns,
        .instrumented_prepare_ns = bench.elapsed(context.io, start),
        .live_bytes = preparation.live,
        .peak_bytes = preparation.peak,
    });
    for (0..3) |replicate| {
        for (0..2) |offset| {
            const instrumented = (replicate + offset) % 2 == 1;
            const costs = try bench.run(
                kosmos,
                context.io,
                context.a,
                if (instrumented) &observed else &plain,
                fixture.input,
                fixture.sample,
                a,
                trace,
                false,
            );
            try bench.emit(context.output, .{
                .phase = "diagnostics-paired-execution",
                .family = @tagName(fixture.family),
                .sample = fixture.sample,
                .replicate = replicate,
                .instrumented = instrumented,
                .preparation_reused = true,
                .costs = costs,
                .equality = "canonical checkpoints and outcomes equal the independent native trace",
            });
        }
    }
}

fn measureReplay(run: Run, snapshot: bool) !void {
    const c = run.context;
    var construction = bench.meter(c.a);
    var builder = source.Builder.init(construction.allocator());
    defer builder.deinit();
    var start = bench.now(c.io);
    const program = try analysis.replay(
        &builder,
        run.guest,
        .{ .arguments = run.fixture.input },
        .{ .snapshot = snapshot },
    );
    const image = try fixtures.encode(construction.allocator(), program.module);
    defer construction.allocator().free(image);
    const construction_ns = bench.elapsed(c.io, start);
    var preparation = bench.meter(c.a);
    start = bench.now(c.io);
    var prepared = try base.Prepared.init(preparation.allocator(), image);
    defer prepared.deinit();
    try bench.emit(c.output, .{
        .phase = "diagnostics-replay-construction",
        .family = @tagName(run.fixture.family),
        .sample = run.fixture.sample,
        .snapshot = snapshot,
        .start_admission_construction_lowering_ns = construction_ns,
        .preparation_ns = bench.elapsed(c.io, start),
        .image_bytes = image.len,
        .construction_live_bytes = construction.live,
        .construction_peak_bytes = construction.peak,
        .preparation_live_bytes = preparation.live,
        .preparation_peak_bytes = preparation.peak,
    });
    for (0..3) |replicate| {
        for (std.meta.tags(Case)) |case| {
            try measureReplayRun(run, &prepared, program.binding, snapshot, case, replicate);
        }
    }
}

const ReplayRun = struct {
    run: Run,
    snapshot: bool,
    case: Case,
    replicate: usize,
    input: []const u8,
    input_encoding_ns: i96,
};

fn measureReplayRun(
    run: Run,
    prepared: *const base.Prepared,
    binding: analysis.ReplayBinding,
    snapshot: bool,
    case: Case,
    replicate: usize,
) !void {
    const c = run.context;
    var inputs = bench.meter(c.a);
    const a = inputs.allocator();
    const exchanges = try a.dupe(analysis.ReplayExchange, run.reference.exchanges);
    defer a.free(exchanges);
    var wrong: ?[]u8 = null;
    defer if (wrong) |bytes| a.free(bytes);
    if (case != .matching) {
        const index = if (case == .first_mismatch) 0 else exchanges.len - 1;
        wrong = try a.dupe(u8, exchanges[index].expected_request.payload);
        wrong.?[wrong.?.len - 1] ^= 1;
        exchanges[index].expected_request.payload = wrong.?;
    }
    const start = bench.now(c.io);
    const input = try projection.encode(analysis.ReplayInput, a, .{
        .transcript = .{
            .binding = binding,
            .exchanges = exchanges,
            .ending = .{ .terminal = .{ .completed = run.reference.terminal } },
        },

        .guest_quantum = 10000,
    });
    defer a.free(input);
    const r: ReplayRun = .{
        .run = run,
        .snapshot = snapshot,
        .case = case,
        .replicate = replicate,
        .input = input,
        .input_encoding_ns = bench.elapsed(c.io, start),
    };
    try executeReplay(r, prepared, &inputs);
}

fn executeReplay(
    r: ReplayRun,
    prepared: *const base.Prepared,
    inputs: *const kosmos.AllocationBudget,
) !void {
    const c = r.run.context;
    var execution = bench.meter(c.a);
    var output = bench.meter(c.a);
    var start = bench.now(c.io);
    var session = try base.Session.start(execution.allocator(), prepared, r.input, .{});
    defer session.deinit();
    const start_ns = bench.elapsed(c.io, start);
    start = bench.now(c.io);
    const outcome = try session.run(null);
    const execution_ns = bench.elapsed(c.io, start);
    if (outcome != .completed) return error.ReplayFailed;
    start = bench.now(c.io);
    const bytes = try session.bytes(&outcome.completed);
    const result_encoding_ns = bench.elapsed(c.io, start);
    var decoded = try projection.decode(analysis.ReplayOutput, output.allocator(), bytes);
    defer decoded.deinit();
    try validateReplay(r, decoded.value, bytes.len);
    try bench.emit(c.output, .{
        .phase = "diagnostics-replay-execution",
        .family = @tagName(r.run.fixture.family),
        .sample = r.run.fixture.sample,
        .replicate = r.replicate,
        .case = @tagName(r.case),
        .snapshot = r.snapshot,
        .preparation_reused = true,
        .input_encoding_ns = r.input_encoding_ns,
        .session_start_admission_ns = start_ns,
        .execution_comparison_projection_ns = execution_ns,
        .result_encoding_ns = result_encoding_ns,
        .input_bytes = r.input.len,
        .output_bytes = bytes.len,
        .guest_steps = decoded.value.guest_steps,
        .base_transitions = session.transitions,
        .matched = decoded.value.matched_exchanges,
        .canonical_guest_checkpoint_bytes = referenceCheckpoint(r).len,
        .input_live_bytes = inputs.live,
        .input_peak_bytes = inputs.peak,
        .execution_live_bytes = execution.live,
        .execution_peak_bytes = execution.peak,
        .output_live_bytes = output.live,
        .output_peak_bytes = output.peak,
    });
    if (r.replicate == 0 and r.case == .matching) try restoreReplay(r, prepared, bytes);
}

fn validateReplay(r: ReplayRun, value: analysis.ReplayOutput, length: usize) !void {
    if (value.observation != null) return error.UnrequestedObservation;
    const matched = switch (r.case) {
        .matching => r.run.fixture.requests,
        .first_mismatch => 0,
        .later_mismatch => r.run.fixture.requests - 1,
    };
    if (value.matched_exchanges != matched) return error.WrongMatchedCount;
    if (r.case == .matching) {
        if (value.stopping != .terminal_matched) return error.TerminalNotCompared;
        if (value.guest_steps != r.run.guest_work) return error.GuestWorkChanged;
    } else {
        if (value.stopping != .payload_mismatch or
            value.stopping.payload_mismatch.index != matched) return error.MismatchNotCompared;
        const length_expected = r.run.reference.exchanges[matched].expected_request.payload.len;
        if (value.stopping.payload_mismatch.expected_length != length_expected or
            value.stopping.payload_mismatch.actual_length != length_expected or
            value.stopping.payload_mismatch.first_difference != length_expected - 1)
            return error.MismatchWitnessChanged;
    }
    if (!r.snapshot) {
        if (value.snapshot != null or length > 128) return error.UnboundedSummary;
    } else {
        const state = value.snapshot orelse return error.MissingSnapshot;
        const bytes = try data.state_image.emit(r.run.context.a, state);
        defer r.run.context.a.free(bytes);
        const expected = referenceCheckpoint(r);
        if (!std.mem.eql(u8, bytes, expected)) return error.SnapshotChanged;
    }
}

fn restoreReplay(
    r: ReplayRun,
    prepared: *const base.Prepared,
    expected: []const u8,
) !void {
    const c = r.run.context;
    var suspended = bench.meter(c.a);
    var original = try base.Session.start(suspended.allocator(), prepared, r.input, .{});
    defer original.deinit();
    if (try original.run(128) != .progressed) return error.MissingAnalysisSuspension;
    var checkpoint_meter = bench.meter(c.a);
    var restore = bench.meter(c.a);
    var start = bench.now(c.io);
    const bytes = try original.checkpoint(checkpoint_meter.allocator());
    defer checkpoint_meter.allocator().free(bytes);
    const checkpoint_ns = bench.elapsed(c.io, start);
    start = bench.now(c.io);
    var restored = try base.Session.restore(restore.allocator(), prepared, bytes, .{});
    defer restored.deinit();
    const restore_ns = bench.elapsed(c.io, start);
    start = bench.now(c.io);
    const outcome = try restored.run(null);
    const continuation_ns = bench.elapsed(c.io, start);
    if (outcome != .completed or !std.mem.eql(
        u8,
        expected,
        try restored.bytes(&outcome.completed),
    )) return error.RestoreChanged;
    try bench.emit(c.output, .{
        .phase = "diagnostics-replay-restore",
        .family = @tagName(r.run.fixture.family),
        .sample = r.run.fixture.sample,
        .snapshot = r.snapshot,
        .checkpoint_ns = checkpoint_ns,
        .restore_ns = restore_ns,
        .analysis_checkpoint_bytes = bytes.len,
        .checkpoint_live_bytes = checkpoint_meter.live,
        .checkpoint_peak_bytes = checkpoint_meter.peak,
        .restore_live_bytes = restore.live,
        .restore_peak_bytes = restore.peak,
        .continuation_ns = continuation_ns,
        .suspended_live_bytes = suspended.live,
        .suspended_peak_bytes = suspended.peak,
        .boundary = "analysis suspended after 128 base transitions",
    });
}

fn referenceCheckpoint(r: ReplayRun) []const u8 {
    return switch (r.case) {
        .matching => r.run.reference.terminal_checkpoint,
        .first_mismatch => r.run.reference.pending_checkpoints[0],
        .later_mismatch => r.run.reference.pending_checkpoints[r.run.fixture.requests - 1],
    };
}
