const std = @import("std");
const source = @import("horos").source;
const data = @import("horos_data");
const kosmos = @import("root.zig");
const base = @import("base/session.zig");
const views = kosmos.RuntimeViews;
const projection = @import("semantic/projection.zig");
const artifact = @import("semantic/artifact.zig");
const bench = @import("semantic_benchmark.zig");
const fixtures = @import("semantic_benchmark_diagnostics_fixtures.zig");

const Context = struct {
    a: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    guest: *const data.program_image.Admitted,
    checkpoint: []const u8,
    binding: views.Binding,
    family: fixtures.Family,
    sample: usize,
};
const Costs = struct {
    capture_admission_traversal_ns: i96 = 0,
    query_encode_execute_result_ns: i96 = 0,
    captures: usize = 0,
    input_bytes: usize = 0,
    output_bytes: usize = 0,
    base_transitions: usize = 0,
};

pub fn measure(
    a: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    guest: *const data.program_image.Admitted,
    checkpoint: []const u8,
    family: fixtures.Family,
    sample: usize,
    runtime: *const kosmos.RuntimeArtifact,
) !void {
    const context: Context = .{
        .a = a,
        .io = io,
        .output = output,
        .guest = guest,
        .checkpoint = checkpoint,
        .family = family,
        .sample = sample,
        .binding = .{
            .guest = guest.identity(),
            .core = runtime.content.value.manifest.source,
            .realization = runtime.identity,
            .checkpoint = artifact.digest(checkpoint),
            .execution = @splat(0),
            .guest_revision = 1,
            .realization_revision = 0,
            .disclosure = artifact.digest("benchmark/full-metadata-no-values"),
        },
    };
    var construction = bench.meter(a);
    var builder = source.Builder.init(construction.allocator());
    defer builder.deinit();
    var start = bench.now(io);
    const image = try fixtures.encode(
        construction.allocator(),
        try views.queries.retention(&builder),
    );
    defer construction.allocator().free(image);
    const construction_ns = bench.elapsed(io, start);
    var preparation = bench.meter(a);
    start = bench.now(io);
    var prepared = try base.Prepared.init(preparation.allocator(), image);
    defer prepared.deinit();
    try bench.emit(output, .{
        .phase = "diagnostics-retention-preparation",
        .family = @tagName(family),
        .sample = sample,
        .construction_lowering_ns = construction_ns,
        .preparation_ns = bench.elapsed(io, start),
        .construction_live_bytes = construction.live,
        .construction_peak_bytes = construction.peak,
        .preparation_live_bytes = preparation.live,
        .preparation_peak_bytes = preparation.peak,
    });
    for (0..3) |replicate| try compare(context, &prepared, replicate);
}

fn admission(c: Context) !void {
    var resources = bench.meter(c.a);
    const start = bench.now(c.io);
    var state = try data.state_image.decodeGraphBorrowed(resources.allocator(), c.checkpoint, .{});
    defer state.deinit();
    try data.state_admission.validateAdmitted(resources.allocator(), c.guest, state.state);
    try bench.emit(c.output, .{
        .phase = "diagnostics-view-admission",
        .family = @tagName(c.family),
        .sample = c.sample,
        .admission_ns = bench.elapsed(c.io, start),
        .checkpoint_bytes = c.checkpoint.len,
        .live_bytes = resources.live,
        .peak_bytes = resources.peak,
        .scope = "standalone decode and admission; capture repeats its required admission",
    });
}

fn compare(c: Context, prepared: *const base.Prepared, replicate: usize) !void {
    if (replicate == 0) try admission(c);
    var retained = bench.meter(c.a);
    var queries = bench.meter(c.a);
    var start = bench.now(c.io);
    var captured = try views.captureDetailed(
        retained.allocator(),
        c.guest,
        c.checkpoint,
        c.binding,
        .{},
    );
    defer captured.deinit();
    var costs: Costs = .{
        .capture_admission_traversal_ns = bench.elapsed(c.io, start),
        .captures = 1,
    };
    const metadata = captured.value.metadata;
    if (metadata.nodes.len == 0) return error.EmptyView;
    const targets = [_]u64{
        metadata.nodes[0].id, metadata.nodes[metadata.nodes.len - 1].id, std.math.maxInt(u64),
    };
    var expected: [3][]const u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(c.a);
    defer arena.deinit();
    for (targets, 0..) |target, i| {
        start = bench.now(c.io);
        expected[i] = try query(
            queries.allocator(),
            arena.allocator(),
            prepared,
            metadata,
            target,
            &costs,
        );
        costs.query_encode_execute_result_ns += bench.elapsed(c.io, start);
    }
    try report(c, replicate, true, costs, &retained, &queries);
    try repeated(c, prepared, replicate, targets, expected);
}

fn repeated(
    c: Context,
    prepared: *const base.Prepared,
    replicate: usize,
    targets: [3]u64,
    expected: [3][]const u8,
) !void {
    var captures = bench.meter(c.a);
    var queries = bench.meter(c.a);
    var costs: Costs = .{};
    for (targets, expected) |target, wanted| {
        var start = bench.now(c.io);
        var captured = try views.captureDetailed(
            captures.allocator(),
            c.guest,
            c.checkpoint,
            c.binding,
            .{},
        );
        defer captured.deinit();
        costs.capture_admission_traversal_ns += bench.elapsed(c.io, start);
        costs.captures += 1;
        start = bench.now(c.io);
        const result = try query(
            queries.allocator(),
            c.a,
            prepared,
            captured.value.metadata,
            target,
            &costs,
        );
        defer c.a.free(result);
        costs.query_encode_execute_result_ns += bench.elapsed(c.io, start);
        if (!std.mem.eql(u8, wanted, result)) return error.RetentionResultChanged;
    }
    try report(c, replicate, false, costs, &captures, &queries);
}

fn query(
    a: std.mem.Allocator,
    output: std.mem.Allocator,
    prepared: *const base.Prepared,
    view: views.GuestView,
    target: u64,
    costs: *Costs,
) ![]const u8 {
    const input = try projection.encode(views.queries.RetentionInput, a, .{
        .view = view,
        .target = target,
    });
    defer a.free(input);
    var session = try base.Session.start(a, prepared, input, .{});
    defer session.deinit();
    const outcome = try session.run(null);
    if (outcome != .completed) return error.RetentionFailed;
    const bytes = try session.bytes(&outcome.completed);
    costs.input_bytes += input.len;
    costs.output_bytes += bytes.len;
    costs.base_transitions += session.transitions;
    return output.dupe(u8, bytes);
}

fn report(
    c: Context,
    replicate: usize,
    reused: bool,
    costs: Costs,
    captures: *const kosmos.AllocationBudget,
    queries: *const kosmos.AllocationBudget,
) !void {
    try bench.emit(c.output, .{
        .phase = "diagnostics-retention",
        .family = @tagName(c.family),
        .sample = c.sample,
        .replicate = replicate,
        .view_reused = reused,
        .queries = 3,
        .preparation_reused = true,
        .costs = costs,
        .canonical_guest_checkpoint_bytes = c.checkpoint.len,
        .capture_live_bytes = captures.live,
        .capture_peak_bytes = captures.peak,
        .query_live_bytes = queries.live,
        .query_peak_bytes = queries.peak,
        .disclosure = "complete metadata graph; no values, blob payloads or snapshot",
        .equality = "exact ordered result bytes for identical targets and disclosure",
    });
}
