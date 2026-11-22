const std = @import("std");
const data = @import("horos_data");
const native = @import("native_baseline");
const kosmos = @import("root.zig");
const bench = @import("semantic_benchmark.zig");
const artifact = @import("semantic/artifact.zig");
const packaged = @import("semantic_packaged.zig");
const protocol = data.invocation;
const Allocator = std.mem.Allocator;
const Digest = [32]u8;
const Context = struct {
    a: Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    image: []const u8,
    guest: *const data.program_image.Admitted,
    input: []const u8,
    trace: []const bench.Step,
    guest_work: u64,
};
const Realization = enum { generic, specialized };
const repetitions = 6;

pub fn measure(
    a: Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    image: []const u8,
    input: []const u8,
) !void {
    try @import("semantic_benchmark_recovery_diamond.zig").measure(a, output);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var trace: std.ArrayList(bench.Step) = .empty;
    var direct = try native.Prepared.init(a, image);
    defer direct.deinit();
    const reference = try bench.run(
        native,
        io,
        a,
        &direct,
        input,
        0,
        scratch.allocator(),
        &trace,
        true,
    );
    try bench.emit(output, .{
        .phase = "recovery-environment",
        .workload = "scalar_chain_large",
        .replicates = repetitions,
        .quantum = 256,
        .input = std.fmt.bytesToHex(input[0..8].*, .lower),
        .guest = std.fmt.bytesToHex(guest.identity(), .lower),
        .guest_image_sha256 = std.fmt.bytesToHex(artifact.digest(image), .lower),
        .reference_guest_work = reference.guest_work,
        .reference_cuts = trace.items.len,
        .zig = @import("builtin").zig_version_string,
        .mode = @tagName(@import("builtin").mode),
        .cpu_model = @import("builtin").cpu.model.name,
        .arch = @tagName(@import("builtin").cpu.arch),
        .os = @tagName(@import("builtin").os.tag),
    });
    const context: Context = .{
        .a = a,
        .io = io,
        .output = output,
        .image = image,
        .guest = guest,
        .input = input,
        .trace = trace.items,
        .guest_work = reference.guest_work,
    };
    for (std.meta.tags(Realization)) |kind| try measurePair(context, kind);
}

fn build(context: Context, kind: Realization, optimized: bool) !kosmos.Prepared {
    var construction = bench.meter(context.a);
    var start = bench.now(context.io);
    const bytes = try kosmos.RuntimeCompiler.compile(construction.allocator(), .{
        .guest = if (kind == .specialized) context.guest else null,
        .horos_package = packaged.horos_package,
        .scalar_field_reuse = optimized,
    });
    const compile_ns = bench.elapsed(context.io, start);
    defer construction.allocator().free(bytes);
    start = bench.now(context.io);
    var admitted = try kosmos.RuntimeArtifact.init(context.a, bytes, artifact.digest(bytes));
    defer admitted.deinit();
    const admission_ns = bench.elapsed(context.io, start);
    var validation = bench.meter(context.a);
    start = bench.now(context.io);
    try kosmos.RuntimeCompiler.validate(validation.allocator(), &admitted);
    const validation_ns = bench.elapsed(context.io, start);
    if (validation.live != 0) return error.LeakedValidation;
    const bundle = admitted.content.value;
    const proof = if (optimized) try recoveryShape(context.a, bundle.evidence) else null;
    try bench.emit(context.output, .{
        .phase = "recovery-construction",
        .realization = @tagName(kind),
        .optimized = optimized,
        .compiler_policy = bundle.manifest.compiler.policy,
        .horos_package = bundle.manifest.compiler.horos_package,
        .artifact = std.fmt.bytesToHex(admitted.identity, .lower),
        .image = std.fmt.bytesToHex(admitted.program.identity(), .lower),
        .artifact_bytes = bytes.len,
        .image_bytes = bundle.image.len,
        .evidence_bytes = bundle.evidence.len,
        .recovery_proof = proof,
        .compile_ns = compile_ns,
        .admission_ns = admission_ns,
        .independent_validation_ns = validation_ns,
        .compile_peak_bytes = construction.peak,
        .validation_peak_bytes = validation.peak,
    });
    return kosmos.Prepared.initWithRuntime(context.a, context.image, &admitted);
}

const ProofShape = struct { rule: []const u8, evidence_bytes: usize, field_witnesses: usize };

fn recoveryShape(a: Allocator, bytes: []const u8) !ProofShape {
    const current = @import("horos_recovery");
    var reader: current.data.wire.Reader = .{ .input = bytes };
    const recovery = try reader.bytes();
    var decoded = try current.source.recovery_optimization.decode(
        a,
        recovery,
        kosmos.RuntimeCompiler.recovery_limits,
    );
    defer decoded.deinit();
    return .{
        .rule = @tagName(decoded.evidence.rule),
        .evidence_bytes = recovery.len,
        .field_witnesses = decoded.evidence.witnesses.len,
    };
}

const Costs = struct {
    start_ns: i96,
    wall_ns: i96 = 0,
    execute_ns: i96 = 0,
    field_evaluations: u64 = 0,
    move_slot_reads: u64 = 0,
    base_work: u64 = 0,
    guest_work: u64 = 0,
    resident_peak_bytes: usize = 0,
    resident_retained_bytes: usize = 0,
    checked_cuts: usize = 0,
    answer: ?u64 = null,
    terminal_checkpoint: Digest = undefined,
};

fn measurePair(context: Context, kind: Realization) !void {
    var structural = try build(context, kind, false);
    defer structural.deinit();
    var optimized = try build(context, kind, true);
    defer optimized.deinit();
    for (0..repetitions) |replicate| {
        for (0..2) |order| {
            const selected = (replicate + order) % 2 == 1;
            const runtime = if (selected) &optimized else &structural;
            const costs = try sample(context, runtime);
            try bench.emit(context.output, .{
                .phase = "recovery-execution",
                .realization = @tagName(kind),
                .optimized = selected,
                .replicate = replicate,
                .order = order,
                .artifact = std.fmt.bytesToHex(runtime.runtime.identity, .lower),
                .checked_cuts = costs.checked_cuts,
                .guest_work = costs.guest_work,
                .answer = costs.answer,
                .terminal_checkpoint = std.fmt.bytesToHex(costs.terminal_checkpoint, .lower),
                .base_work = costs.base_work,
                .field_evaluations = costs.field_evaluations,
                .move_slot_reads = costs.move_slot_reads,
                .start_ns = costs.start_ns,
                .execute_ns = costs.execute_ns,
                .wall_ns = costs.wall_ns,
                .resident_peak_bytes = costs.resident_peak_bytes,
                .resident_retained_bytes = costs.resident_retained_bytes,
            });
        }
    }
}

fn sample(context: Context, prepared: *const kosmos.Prepared) !Costs {
    var m = bench.meter(context.a);
    var statistics: kosmos.Statistics = .{};
    const start = bench.now(context.io);
    var session = try kosmos.Session.start(m.allocator(), prepared, context.input);
    var costs: Costs = .{ .start_ns = bench.elapsed(context.io, start) };
    {
        defer session.deinit();
        session.setStatistics(&statistics);
        for (context.trace) |step| {
            const fields = statistics.storage.base_field_evaluations;
            const moves = statistics.storage.base_move_slot_reads;
            const begin = bench.now(context.io);
            _ = try kosmos.invocation.advance(&session, step.control, 256);
            costs.execute_ns += bench.elapsed(context.io, begin);
            costs.field_evaluations += statistics.storage.base_field_evaluations - fields;
            costs.move_slot_reads += statistics.storage.base_move_slot_reads - moves;
            try checkCut(context, &session, step, &costs);
        }
        costs.wall_ns = bench.elapsed(context.io, start);
        costs.guest_work = statistics.transitions;
        costs.base_work = statistics.base_transitions;
        costs.resident_peak_bytes = m.peak;
        costs.resident_retained_bytes = m.live;
    }
    if (m.live != 0) return error.LeakedExecution;
    if (costs.answer == null or costs.guest_work != context.guest_work)
        return error.GuestObservationChanged;
    return costs;
}

fn checkCut(context: Context, session: *kosmos.Session, step: bench.Step, costs: *Costs) !void {
    var outcome = try kosmos.invocation.finish(context.a, session, false);
    defer outcome.deinit();
    const encoded = try protocol.encodeOwned(protocol.Outcome, context.a, outcome.record);
    defer context.a.free(encoded);
    const checkpoint = try session.checkpoint(context.a);
    defer context.a.free(checkpoint);
    if (!std.mem.eql(u8, checkpoint, step.checkpoint) or !std.mem.eql(u8, encoded, step.outcome))
        return error.GuestObservationChanged;
    costs.checked_cuts += 1;
    if (outcome.record == .completed) {
        const result = outcome.record.completed;
        if (result.len != 8) return error.GuestObservationChanged;
        costs.answer = std.mem.readInt(u64, result[0..8], .little);
        costs.terminal_checkpoint = artifact.digest(checkpoint);
    }
}
