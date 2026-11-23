const std = @import("std");
const data = @import("horos_data");
const native = @import("native_baseline");
const kosmos = @import("recovery_root.zig");
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
    opt_in_first: bool,

    fn orders(self: Context) [2][2]bool {
        if (self.opt_in_first) return .{ construction_order[1], construction_order[0] };
        return construction_order;
    }
};
const Realization = enum { generic, specialized };
const repetitions = 6;
const construction_order = [2][2]bool{ .{ false, true }, .{ true, false } };
const allocation_meter = .{
    .allocator = "AllocationBudget",
    .resize = "noResize",
    .remap = "noRemap",
    .quantity = "live requested bytes",
};

pub fn measure(
    a: Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    image: []const u8,
    input: []const u8,
    opt_in_first: bool,
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
    const cuts = try scratch.allocator().alloc(u64, trace.items.len);
    for (trace.items, cuts) |step, *work| work.* = step.guest_work;
    try bench.emit(output, .{
        .phase = "recovery-environment",
        .reference_cut_guest_work = cuts,
        .workload = "scalar_chain_large",
        .replicates = repetitions,
        .opt_in_first = opt_in_first,
        .quantum = 256,
        .input = std.fmt.bytesToHex(input[0..8].*, .lower),
        .guest = std.fmt.bytesToHex(guest.identity(), .lower),
        .guest_image_sha256 = std.fmt.bytesToHex(artifact.digest(image), .lower),
        .structural_horos_package = packaged.horos_package,
        .opt_in_horos_package = @import("recovery_options").horos_package,
        .execute_interval = "invocation.advance sum, ordinary allocator, statistics off",
        .construction_interval = "ordinary allocator, compile, admit with digest, validate",
        .construction_replicates = construction_order.len,
        .construction_process = "same process, each timed artifact released before the next build",
        .construction_peak_interval = "separately metered compile and independent validation calls",
        .wall_interval = "session start through final outcome and checkpoint checks",
        .counter_interval = "sum of invocation.advance calls on a separate instrumented session",
        .reference_guest_work = reference.guest_work,
        .reference_cuts = trace.items.len,
        .zig = @import("builtin").zig_version_string,
        .mode = @tagName(@import("builtin").mode),
        .target_cpu_model = @import("builtin").cpu.model.name,
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
        .opt_in_first = opt_in_first,
    };
    for (std.meta.tags(Realization)) |kind| try measurePair(context, kind);
}

const Built = struct { prepared: kosmos.Prepared, effective_rule: []const u8 };

fn compileOptions(
    context: Context,
    kind: Realization,
    optimized: bool,
) kosmos.RuntimeCompiler.Options {
    return .{
        .guest = if (kind == .specialized) context.guest else null,
        .horos_package = packaged.horos_package,
        .scalar_field_reuse = optimized,
    };
}

const ConstructionTiming = struct {
    artifact: Digest,
    compile_ns: i96,
    admission_ns: i96,
    independent_validation_ns: i96,
};

fn timeConstruction(context: Context, options: kosmos.RuntimeCompiler.Options) !ConstructionTiming {
    const a = context.a;
    var start = bench.now(context.io);
    const bytes = try kosmos.RuntimeCompiler.compile(a, options);
    const compile_ns = bench.elapsed(context.io, start);
    defer a.free(bytes);
    const expected = artifact.digest(bytes);
    start = bench.now(context.io);
    var admitted = try kosmos.RuntimeArtifact.init(a, bytes, expected);
    const admission_ns = bench.elapsed(context.io, start);
    defer admitted.deinit();
    start = bench.now(context.io);
    try kosmos.RuntimeCompiler.validate(a, &admitted);
    return .{
        .artifact = admitted.identity,
        .compile_ns = compile_ns,
        .admission_ns = admission_ns,
        .independent_validation_ns = bench.elapsed(context.io, start),
    };
}

fn buildMetered(context: Context, kind: Realization, optimized: bool) !Built {
    var construction = bench.meter(context.a);
    const options = compileOptions(context, kind, optimized);
    const built = if (optimized) try @import("semantic/recovery_backend.zig").compile(
        construction.allocator(),
        .{
            .horos_package = options.horos_package,
            .guest = options.guest,
            .hooks = options.hooks,
            .policy = options.policy,
        },
    ) else null;
    const bytes = if (built) |checked| checked.bytes else try kosmos.RuntimeCompiler.compile(
        construction.allocator(),
        options,
    );
    defer construction.allocator().free(bytes);
    var admitted = try kosmos.RuntimeArtifact.init(context.a, bytes, artifact.digest(bytes));
    defer admitted.deinit();
    var validation = bench.meter(context.a);
    try kosmos.RuntimeCompiler.validate(validation.allocator(), &admitted);
    if (validation.live != 0) return error.LeakedValidation;
    const bundle = admitted.content.value;
    const proof = if (optimized) try recoveryShape(context.a, bundle.evidence) else null;
    const rule = if (proof) |p| p.rule else "legacy_structural";
    try bench.emit(context.output, .{
        .phase = "recovery-construction",
        .effective_rule = rule,
        .producer_outcome = if (built) |checked| @tagName(checked.outcome) else null,
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
        .allocation_meter = allocation_meter,
        .compile_peak_bytes = construction.peak,
        .validation_peak_bytes = validation.peak,
    });
    return .{
        .prepared = try kosmos.Prepared.initWithRuntime(context.a, context.image, &admitted),
        .effective_rule = rule,
    };
}

fn measureConstruction(context: Context, kind: Realization) ![2]Built {
    var samples: [construction_order.len][2]ConstructionTiming = undefined;
    const orders = context.orders();
    for (orders, &samples) |pair, *timings| {
        for (pair, timings) |optimized, *sample| {
            sample.* = try timeConstruction(context, compileOptions(context, kind, optimized));
        }
    }
    var built: [2]Built = undefined;
    const first = orders[0][0];
    built[@intFromBool(first)] = try buildMetered(context, kind, first);
    errdefer built[@intFromBool(first)].prepared.deinit();
    built[@intFromBool(!first)] = try buildMetered(context, kind, !first);
    errdefer built[@intFromBool(!first)].prepared.deinit();
    for (orders, samples, 0..) |pair, timings, replicate| {
        for (pair, timings, 0..) |selected, sample, order| {
            const runtime = &built[@intFromBool(selected)].prepared.runtime;
            if (!std.mem.eql(u8, &runtime.identity, &sample.artifact))
                return error.ConstructionArtifactChanged;
            try bench.emit(context.output, .{
                .phase = "recovery-construction-timing",
                .realization = @tagName(kind),
                .optimized = selected,
                .replicate = replicate,
                .order = order,
                .artifact = std.fmt.bytesToHex(sample.artifact, .lower),
                .horos_package = runtime.content.value.manifest.compiler.horos_package,
                .compile_ns = sample.compile_ns,
                .admission_ns = sample.admission_ns,
                .independent_validation_ns = sample.independent_validation_ns,
            });
        }
    }
    return built;
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

const Observations = struct {
    guest_work: u64 = 0,
    checked_cuts: usize = 0,
    answer: ?u64 = null,
    terminal_checkpoint: Digest = undefined,
};
const Timings = struct { start_ns: i96, execute_ns: i96 = 0, wall_ns: i96 = 0 };
const Counters = struct {
    field_evaluations: u64 = 0,
    move_slot_reads: u64 = 0,
    base_work: u64 = 0,
    resident_peak_bytes: usize = 0,
    resident_retained_bytes: usize = 0,
};

fn measurePair(context: Context, kind: Realization) !void {
    var builds = try measureConstruction(context, kind);
    defer for (&builds) |*built| built.prepared.deinit();
    const orders = context.orders();
    for (0..repetitions) |replicate| {
        for (orders[replicate % orders.len], 0..) |selected, order| {
            const built = &builds[@intFromBool(selected)];
            const sample = try timed(context, &built.prepared);
            const observed = sample.observed;
            const manifest = built.prepared.runtime.content.value.manifest;
            try bench.emit(context.output, .{
                .phase = "recovery-execution",
                .realization = @tagName(kind),
                .optimized = selected,
                .effective_rule = built.effective_rule,
                .horos_package = manifest.compiler.horos_package,
                .replicate = replicate,
                .order = order,
                .artifact = std.fmt.bytesToHex(built.prepared.runtime.identity, .lower),
                .checked_cuts = observed.checked_cuts,
                .guest_work = observed.guest_work,
                .answer = observed.answer,
                .terminal_checkpoint = std.fmt.bytesToHex(observed.terminal_checkpoint, .lower),
                .start_ns = sample.time.start_ns,
                .execute_ns = sample.time.execute_ns,
                .wall_ns = sample.time.wall_ns,
            });
        }
    }
    for (orders[0]) |selected| {
        const built = &builds[@intFromBool(selected)];
        const measured = try counted(context, &built.prepared);
        const observed = measured.observed;
        const manifest = built.prepared.runtime.content.value.manifest;
        try bench.emit(context.output, .{
            .phase = "recovery-counters",
            .realization = @tagName(kind),
            .optimized = selected,
            .effective_rule = built.effective_rule,
            .horos_package = manifest.compiler.horos_package,
            .artifact = std.fmt.bytesToHex(built.prepared.runtime.identity, .lower),
            .checked_cuts = observed.checked_cuts,
            .guest_work = observed.guest_work,
            .answer = observed.answer,
            .terminal_checkpoint = std.fmt.bytesToHex(observed.terminal_checkpoint, .lower),
            .base_work = measured.cost.base_work,
            .field_evaluations = measured.cost.field_evaluations,
            .move_slot_reads = measured.cost.move_slot_reads,
            .allocation_meter = allocation_meter,
            .resident_memory_allocator = "session allocations only",
            .resident_memory_excludes = "prepared runtime and caller-owned buffers",
            .resident_peak_interval = "Session.start through the final checkpoint check",
            .resident_retained_at = "after the final checkpoint check, before Session.deinit",
            .resident_peak_bytes = measured.cost.resident_peak_bytes,
            .resident_retained_bytes = measured.cost.resident_retained_bytes,
        });
    }
}

fn timed(context: Context, prepared: *const kosmos.Prepared) !struct {
    time: Timings,
    observed: Observations,
} {
    const start = bench.now(context.io);
    var session = try kosmos.Session.start(context.a, prepared, context.input);
    var time: Timings = .{ .start_ns = bench.elapsed(context.io, start) };
    defer session.deinit();
    var observed: Observations = .{};
    for (context.trace) |step| {
        const before = session.transitions;
        const begin = bench.now(context.io);
        _ = try kosmos.invocation.advance(&session, step.control, 256);
        time.execute_ns += bench.elapsed(context.io, begin);
        try checkCut(context, &session, step, session.transitions -% before, &observed);
    }
    time.wall_ns = bench.elapsed(context.io, start);
    try checkComplete(context, observed);
    return .{ .time = time, .observed = observed };
}

fn counted(context: Context, prepared: *const kosmos.Prepared) !struct {
    cost: Counters,
    observed: Observations,
} {
    var m = bench.meter(context.a);
    var stats: kosmos.Statistics = .{};
    var cost: Counters = .{};
    var observed: Observations = .{};
    {
        var session = try kosmos.Session.start(m.allocator(), prepared, context.input);
        defer session.deinit();
        session.setStatistics(&stats);
        for (context.trace) |step| {
            const fields = stats.storage.base_field_evaluations;
            const moves = stats.storage.base_move_slot_reads;
            const guest_before = session.transitions;
            const base_before = session.driver.outer.transitions;
            _ = try kosmos.invocation.advance(&session, step.control, 256);
            cost.field_evaluations += stats.storage.base_field_evaluations - fields;
            cost.move_slot_reads += stats.storage.base_move_slot_reads - moves;
            cost.base_work += session.driver.outer.transitions -% base_before;
            try checkCut(context, &session, step, session.transitions -% guest_before, &observed);
        }
        cost.resident_peak_bytes = m.peak;
        cost.resident_retained_bytes = m.live;
    }
    if (m.live != 0) return error.LeakedExecution;
    try checkComplete(context, observed);
    return .{ .cost = cost, .observed = observed };
}

fn checkComplete(context: Context, observed: Observations) !void {
    if (observed.answer == null or observed.guest_work != context.guest_work)
        return error.GuestObservationChanged;
}

fn checkCut(
    context: Context,
    session: *kosmos.Session,
    step: bench.Step,
    guest_work: usize,
    observed: *Observations,
) !void {
    if (guest_work != step.guest_work) return error.GuestWorkChanged;
    observed.guest_work += guest_work;
    var outcome = try kosmos.invocation.finish(context.a, session, false);
    defer outcome.deinit();
    const encoded = try protocol.encodeOwned(protocol.Outcome, context.a, outcome.record);
    defer context.a.free(encoded);
    const checkpoint = try session.checkpoint(context.a);
    defer context.a.free(checkpoint);
    if (!std.mem.eql(u8, checkpoint, step.checkpoint) or !std.mem.eql(u8, encoded, step.outcome))
        return error.GuestObservationChanged;
    observed.checked_cuts += 1;
    if (outcome.record == .completed) {
        const result = outcome.record.completed;
        if (result.len != 8) return error.GuestObservationChanged;
        observed.answer = std.mem.readInt(u64, result[0..8], .little);
        observed.terminal_checkpoint = artifact.digest(checkpoint);
    }
}
