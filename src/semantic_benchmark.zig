const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const kosmos = @import("root.zig");
const native = @import("native_baseline");
const service = @import("semantic/service.zig");
const projection = @import("semantic/projection.zig");
const artifact = @import("semantic/artifact.zig");
const Author = @import("semantic/author.zig").Author;
const protocol = data.invocation;

const Workload = enum {
    scalar,
    scalar_chain,
    scalar_chain_large,
    dynamic_loop,
    structured,
    repeated_calls,
    higher_order,
    handlers,
    multi_shot,
    long_cleanup,
    retained_bytes,
};
const Step = struct { control: protocol.Control, checkpoint: []const u8, outcome: []const u8 };
const Costs = struct {
    start_ns: i96 = 0,
    execute_ns: i96 = 0,
    observe_ns: i96 = 0,
    guest_projection_ns: i96 = 0,
    guest_restore_ns: i96 = 0,
    outer_checkpoint_ns: i96 = 0,
    outer_restore_ns: i96 = 0,
    trace_projection_ns: i96 = 0,
    trace_bytes: usize = 0,
    guest_work: u64 = 0,
    base_work: u64 = 0,
    effects: u64 = 0,
    cuts: usize = 0,
    guest_checkpoint_bytes: usize = 0,
    outer_checkpoint_bytes: usize = 0,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    restore_peak_bytes: usize = 0,
    copied_blob_bytes: u64 = 0,
    field_projection_hits: ?u64 = null,
    field_projection_scans: ?u64 = null,
    element_projection_hits: ?u64 = null,
};
fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}
fn elapsed(io: std.Io, start: std.Io.Timestamp) i96 {
    return start.durationTo(now(io)).nanoseconds;
}
fn meter(a: std.mem.Allocator) kosmos.AllocationBudget {
    return .{ .parent = a, .limit = std.math.maxInt(usize) };
}
fn emit(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}
fn image(a: std.mem.Allocator, kind: Workload) ![]u8 {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const module = switch (kind) {
        .higher_order => try horos.source.examples.lexical(&b),
        .handlers => try horos.source.examples.installations(&b, 12),
        .multi_shot => try horos.source.examples.localContinuation(&b, true),
        .retained_bytes => try horos.source.examples.blobCapture(&b),
        .scalar => try scalarModule(e),
        .scalar_chain, .scalar_chain_large => try scalarChainModule(e, kind),
        .structured => try structuredModule(e),
        .dynamic_loop, .repeated_calls => try loopModule(e, kind),
        .long_cleanup => try cleanupModule(e),
    };
    var compiled = try horos.source.lower(a, module);
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    return bytes;
}
fn arguments(a: std.mem.Allocator, kind: Workload, sample: usize) ![]u8 {
    const seed: u64 = 41 + @as(u64, @intCast(sample)) * 19;
    return switch (kind) {
        .scalar, .scalar_chain, .scalar_chain_large, .higher_order => a.dupe(
            u8,
            &std.mem.toBytes(seed),
        ),
        .dynamic_loop, .repeated_calls => a.dupe(u8, &(@as(
            [16]u8,
            std.mem.toBytes(@as(u64, 16 + sample * 16)) ++ std.mem.toBytes(seed),
        ))),
        .structured => a.dupe(u8, &(std.mem.toBytes(seed) ++ std.mem.toBytes(seed + 9))),
        .long_cleanup => a.dupe(u8, &std.mem.toBytes(@as(u64, 8 + sample * 8))),
        .retained_bytes => blk: {
            const length = @as(usize, 1024) << @intCast(sample * 3);
            var size: data.wire.Writer = .{};
            try size.natural(length);
            const bytes = try a.alloc(u8, size.position + length);
            var w: data.wire.Writer = .{ .output = bytes };
            try w.natural(length);
            @memset(bytes[w.position..], @intCast(seed));
            break :blk bytes;
        },
        else => a.dupe(u8, &.{}),
    };
}
fn reply(a: std.mem.Allocator, request_bytes: []const u8, sample: usize) ![]u8 {
    var request = try protocol.decode(protocol.Request, a, request_bytes);
    defer request.deinit();
    const body: []const u8 = if (std.mem.eql(
        u8,
        request.value.binding.semantic_identity,
        "local/producer",
    )) &std.mem.toBytes(@as(u64, 41 + sample * 19)) else &.{};
    return protocol.encodeOwned(protocol.Result, a, .{
        .request_identity = request.value.request_identity,
        .value = body,
    });
}
const RunContext = struct {
    io: std.Io,
    a: std.mem.Allocator,
    sample: usize,
    trace_allocator: std.mem.Allocator,
    trace: *std.ArrayList(Step),
    recording: bool,
};

fn run(
    comptime runtime: type,
    io: std.Io,
    a: std.mem.Allocator,
    prepared: *const runtime.Prepared,
    input: []const u8,
    sample: usize,
    trace_allocator: std.mem.Allocator,
    trace: *std.ArrayList(Step),
    recording: bool,
) !Costs {
    var m = meter(a);
    var statistics: std.meta.Child(std.meta.Child(@FieldType(runtime.Session, "statistics"))) = .{};
    var costs: Costs = .{};
    const start = now(io);
    var session = try runtime.Session.start(m.allocator(), prepared, input);
    costs.start_ns = elapsed(io, start);
    defer session.deinit();
    if (comptime @hasDecl(
        runtime.Session,
        "setStatistics",
    )) session.setStatistics(&statistics) else {
        session.statistics = &statistics;
        session.store.statistics = &statistics.storage;
    }
    const context: RunContext = .{
        .io = io,
        .a = a,
        .sample = sample,
        .trace_allocator = trace_allocator,
        .trace = trace,
        .recording = recording,
    };
    var control: protocol.Control = .none;
    var index: usize = 0;
    while (true) { // tiger: event-loop
        if (!try runCut(runtime, prepared, &session, context, &costs, index, &control)) break;
        index += 1;
    }
    if (!recording and costs.cuts != trace.items.len) return error.MissingGuestCut;
    costs.guest_work = statistics.transitions;
    costs.base_work = if (@hasField(
        @TypeOf(statistics),
        "base_transitions",
    )) statistics.base_transitions else 0;
    costs.copied_blob_bytes = statistics.storage.copied_blob_bytes;
    if (@hasField(
        @TypeOf(statistics.storage),
        "field_projection_hits",
    )) costs.field_projection_hits = statistics.storage.field_projection_hits;
    if (@hasField(
        @TypeOf(statistics.storage),
        "field_projection_scans",
    )) costs.field_projection_scans = statistics.storage.field_projection_scans;
    if (@hasField(
        @TypeOf(statistics.storage),
        "element_projection_hits",
    )) costs.element_projection_hits = statistics.storage.element_projection_hits;
    costs.live_bytes = m.live;
    costs.peak_bytes = m.peak;
    return costs;
}
fn send(a: std.mem.Allocator, outer: *native.Session, command: service.Command) !void {
    var pending = try outer.pendingBinding(a, false);
    defer pending.deinit();
    const value = try projection.encode(service.Command, a, command);
    defer a.free(value);
    const response = try protocol.encodeOwned(protocol.Result, a, .{
        .request_identity = pending.request.request_identity,
        .value = value,
    });
    defer a.free(response);
    try outer.answer(response);
}
fn event(a: std.mem.Allocator, outer: *native.Session) !projection.Owned(service.Event) {
    const observation = try outer.run(null);
    if (observation != .requested) return error.InvalidServiceEvent;
    return projection.decode(service.Event, a, try outer.bytes(&observation.requested.payload));
}
fn bootstrap(
    io: std.Io,
    a: std.mem.Allocator,
    prepared: *const native.Prepared,
    guest: *const data.program_image.Admitted,
    input: []const u8,
    trace: []const Step,
) !Costs {
    var m = meter(a);
    const program = try projection.programBytes(a, guest);
    defer a.free(program);
    const initial = try projection.encode(service.Initial, a, .{ .arguments = input });
    defer a.free(initial);
    const args = try std.mem.concat(a, u8, &.{ program, initial });
    defer a.free(args);
    var costs: Costs = .{};
    const start = now(io);
    var outer = try native.Session.start(m.allocator(), prepared, args);
    defer outer.deinit();
    var first = try event(a, &outer);
    first.deinit();
    costs.start_ns = elapsed(io, start);
    var statistics: std.meta.Child(std.meta.Child(@FieldType(native.Session, "statistics"))) = .{};
    outer.statistics = &statistics;
    outer.store.statistics = &statistics.storage;
    for (trace, 0..) |step, index|
        try bootstrapCut(io, a, prepared, &outer, step, index, &costs);
    costs.base_work = statistics.transitions;
    costs.copied_blob_bytes = statistics.storage.copied_blob_bytes;
    costs.live_bytes = m.live;
    costs.peak_bytes = m.peak;
    return costs;
}
fn switching(
    io: std.Io,
    a: std.mem.Allocator,
    prepared: *const kosmos.Prepared,
    target: *const kosmos.RuntimeArtifact,
    checkpoint: []const u8,
) !i96 {
    var resident = try kosmos.Resident.restore(a, prepared, checkpoint);
    defer if (resident.live) {
        const saved = resident.takeCheckpoint(a) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        a.free(saved);
    };
    const Owner = struct {
        fn publish(
            _: *anyopaque,
            _: kosmos.RuntimeCapsule.Binding,
            _: []const u8,
            _: []const u8,
        ) kosmos.RuntimeCapsule.SwitchDecision {
            return .committed;
        }
    };
    var owner: u8 = 0;
    const bound = try resident.runtimeBinding();
    const start = now(io);
    if (try resident.realize(bound, target, .{
        .execution = @splat(3),
        .custody = @splat(4),
        .publication = null,
    }, .{ .context = &owner, .publish = Owner.publish }) != .committed) return error.SwitchRejected;
    const duration = elapsed(io, start);
    const after = try resident.checkpoint(a);
    defer a.free(after);
    if (!std.mem.eql(u8, checkpoint, after)) return error.SwitchChanged;
    return duration;
}
const BuiltArtifact = struct {
    bytes: []u8,
    artifact: kosmos.RuntimeArtifact,
    admission_ns: i96 = 0,
};
const BenchmarkContext = struct {
    a: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    generic: *kosmos.RuntimeArtifact,
    instrumented: *kosmos.RuntimeArtifact,
    bootstrap: *native.Prepared,
    proposal: *const kosmos.RuntimeCompiler.RecordProposal,
};
const WorkloadContext = struct {
    benchmark: BenchmarkContext,
    kind: Workload,
    guest: *const data.program_image.Admitted,
    direct: *native.Prepared,
    general: *kosmos.Prepared,
    selected: *kosmos.Prepared,
    observed: *kosmos.Prepared,
    specialized: *kosmos.RuntimeArtifact,
    candidate: *kosmos.Prepared,
};
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    var arguments_arena = std.heap.ArenaAllocator.init(a);
    defer arguments_arena.deinit();
    const args = try init.minimal.args.toSlice(arguments_arena.allocator());
    const filter = if (args.len > 1) args[1] else null;
    var generic_meter = meter(a);
    const start = now(init.io);
    var generic = try kosmos.RuntimeArtifact.init(
        generic_meter.allocator(),
        @import("packaged_runtime").bytes,
        artifact.digest(@import("packaged_runtime").bytes),
    );
    defer generic.deinit();
    try measureGenericConstruction(a, init.io, &generic, &output.interface, start, &generic_meter);
    var bootstrap_prepared = try native.Prepared.init(a, generic.content.value.image);
    defer bootstrap_prepared.deinit();
    var instrumented_meter = meter(a);
    var instrumented = try buildInstrumented(
        a,
        init.io,
        &generic,
        &instrumented_meter,
        &output.interface,
    );
    defer instrumented_meter.allocator().free(instrumented.bytes);
    defer instrumented.artifact.deinit();
    var producer_meter = meter(a);
    var proposed = try buildProposal(&producer_meter, init.io, &generic, &output.interface);
    defer proposed.deinit();
    const context: BenchmarkContext = .{
        .a = a,
        .io = init.io,
        .output = &output.interface,
        .generic = &generic,
        .instrumented = &instrumented.artifact,
        .bootstrap = &bootstrap_prepared,
        .proposal = &proposed.value,
    };
    for (std.meta.tags(Workload)) |kind| {
        if (filter == null or std.mem.eql(u8, filter.?, @tagName(kind)))
            try measureWorkload(context, kind);
    }
}

fn measureGenericConstruction(
    a: std.mem.Allocator,
    io: std.Io,
    generic: *kosmos.RuntimeArtifact,
    output: *std.Io.Writer,
    admission_start: std.Io.Timestamp,
    generic_meter: *const kosmos.AllocationBudget,
) !void {
    var start = admission_start;
    try emit(
        output,
        .{
            .phase = "generic-admission",
            .nanoseconds = elapsed(io, start),
            .artifact_bytes = @import("packaged_runtime").bytes.len,
            .live_bytes = generic_meter.live,
            .peak_bytes = generic_meter.peak,
            .source = std.fmt.bytesToHex(generic.content.value.manifest.source, .lower),
            .artifact = std.fmt.bytesToHex(generic.identity, .lower),
            .zig = @import("builtin").zig_version_string,
            .mode = @tagName(@import(
                "builtin",
            ).mode),
            .arch = @tagName(@import(
                "builtin",
            ).cpu.arch),
            .os = @tagName(@import(
                "builtin",
            ).os.tag),
        },
    );
    {
        var construction = meter(a);
        start = now(io);
        const rebuilt = try kosmos.RuntimeCompiler.compile(construction.allocator(), .{
            .horos_package = generic.content.value.manifest.compiler.horos_package,
        });
        const build_ns = elapsed(io, start);
        defer construction.allocator().free(rebuilt);
        if (!std.mem.eql(
            u8,
            rebuilt,
            @import("packaged_runtime").bytes,
        )) return error.GenericBuildChanged;
        start = now(io);
        try kosmos.RuntimeCompiler.validate(a, generic);
        try emit(output, .{
            .phase = "generic-construction",
            .construction_ns = build_ns,
            .independent_validation_ns = elapsed(io, start),
            .construction_peak_bytes = construction.peak,
        });
    }
}

fn buildInstrumented(
    a: std.mem.Allocator,
    io: std.Io,
    generic: *const kosmos.RuntimeArtifact,
    construction: *kosmos.AllocationBudget,
    output: *std.Io.Writer,
) !BuiltArtifact {
    var start: std.Io.Timestamp = undefined;
    start = now(io);
    const instrumented_bytes = try kosmos.RuntimeCompiler.compile(construction.allocator(), .{
        .horos_package = generic.content.value.manifest.compiler.horos_package,
        .hooks = .{ .control = true, .storage = true },
    });
    const instrumented_compile_ns = elapsed(io, start);
    errdefer construction.allocator().free(instrumented_bytes);
    start = now(io);
    var instrumented = try kosmos.RuntimeArtifact.init(
        a,
        instrumented_bytes,
        artifact.digest(instrumented_bytes),
    );
    const instrumented_admission_ns = elapsed(io, start);
    errdefer instrumented.deinit();
    start = now(io);
    try kosmos.RuntimeCompiler.validate(a, &instrumented);
    try emit(output, .{
        .phase = "instrumented-construction",
        .construction_ns = instrumented_compile_ns,
        .admission_ns = instrumented_admission_ns,
        .independent_validation_ns = elapsed(io, start),
        .construction_peak_bytes = construction.peak,
        .artifact_bytes = instrumented_bytes.len,
        .artifact = std.fmt.bytesToHex(instrumented.identity, .lower),
    });
    return .{ .bytes = instrumented_bytes, .artifact = instrumented };
}

fn buildSpecialized(
    a: std.mem.Allocator,
    io: std.Io,
    generic: *const kosmos.RuntimeArtifact,
    construction: *kosmos.AllocationBudget,
    output: *std.Io.Writer,
    guest: *const data.program_image.Admitted,
    kind: Workload,
    image_bytes: usize,
) !BuiltArtifact {
    var start: std.Io.Timestamp = undefined;
    start = now(io);
    const specialized_bytes = try kosmos.RuntimeCompiler.compile(
        construction.allocator(),
        .{
            .horos_package = generic.content.value.manifest.compiler.horos_package,
            .guest = guest,
        },
    );
    const compile_ns = elapsed(io, start);
    errdefer construction.allocator().free(specialized_bytes);
    start = now(io);
    var specialized = try kosmos.RuntimeArtifact.init(
        a,
        specialized_bytes,
        artifact.digest(specialized_bytes),
    );
    const admission_ns = elapsed(io, start);
    errdefer specialized.deinit();
    start = now(io);
    try kosmos.RuntimeCompiler.validate(a, &specialized);
    const validate_ns = elapsed(io, start);
    try emit(output, .{
        .phase = "construction",
        .workload = @tagName(kind),
        .guest = std.fmt.bytesToHex(guest.identity(), .lower),
        .guest_image_bytes = image_bytes,
        .construction_ns = compile_ns,
        .independent_validation_ns = validate_ns,
        .construction_peak_bytes = construction.peak,
        .artifact_bytes = specialized_bytes.len,
        .executable_bytes = specialized.content.value.image.len,
        .proof_bytes = specialized.content.value.evidence.len,
        .recovery_anchors = specialized.content.value.recovery.anchors.len,
    });
    return .{ .bytes = specialized_bytes, .artifact = specialized, .admission_ns = admission_ns };
}

fn measureWorkload(context: BenchmarkContext, kind: Workload) !void {
    const a = context.a;
    const io = context.io;
    const output = context.output;
    var start: std.Io.Timestamp = undefined;
    const bytes = try image(a, kind);
    defer a.free(bytes);
    var direct_prepared = try native.Prepared.init(a, bytes);
    defer direct_prepared.deinit();
    const guest = try data.program_image.Admitted.decode(a, bytes);
    defer guest.deinit();
    var construction = meter(a);
    var specialized = try buildSpecialized(
        a,
        io,
        context.generic,
        &construction,
        output,
        guest,
        kind,
        bytes.len,
    );
    defer construction.allocator().free(specialized.bytes);
    defer specialized.artifact.deinit();
    var candidate_meter = meter(a);
    var candidate = try buildCandidate(context, guest, kind, &candidate_meter);
    defer candidate_meter.allocator().free(candidate.bytes);
    defer candidate.artifact.deinit();
    start = now(io);
    var derived = try kosmos.Prepared.initWithRuntime(a, bytes, &candidate.artifact);
    const candidate_prepare_ns = elapsed(io, start);
    defer derived.deinit();
    start = now(io);
    var general = try kosmos.Prepared.initWithRuntime(a, bytes, context.generic);
    const generic_prepare_ns = elapsed(io, start);
    defer general.deinit();
    start = now(io);
    var selected = try kosmos.Prepared.initWithRuntime(a, bytes, &specialized.artifact);
    const specialized_prepare_ns = elapsed(io, start);
    defer selected.deinit();
    start = now(io);
    var observed_prepared = try kosmos.Prepared.initWithRuntime(a, bytes, context.instrumented);
    const instrumented_prepare_ns = elapsed(io, start);
    defer observed_prepared.deinit();
    try emit(output, .{
        .phase = "setup",
        .workload = @tagName(kind),
        .specialized_admission_ns = specialized.admission_ns,
        .generic_prepare_ns = generic_prepare_ns,
        .specialized_prepare_ns = specialized_prepare_ns,
        .instrumented_prepare_ns = instrumented_prepare_ns,
        .candidate_prepare_ns = candidate_prepare_ns,
    });
    const workload: WorkloadContext = .{
        .benchmark = context,
        .kind = kind,
        .guest = guest,
        .direct = &direct_prepared,
        .general = &general,
        .selected = &selected,
        .observed = &observed_prepared,
        .specialized = &specialized.artifact,
        .candidate = &derived,
    };
    for (0..3) |sample| try measureSample(workload, sample);
}

fn measureSample(context: WorkloadContext, sample: usize) !void {
    const a = context.benchmark.a;
    const io = context.benchmark.io;
    const output = context.benchmark.output;
    const kind = context.kind;
    const input = try arguments(a, kind, sample);
    defer a.free(input);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var trace: std.ArrayList(Step) = .empty;
    const direct = try run(
        native,
        io,
        a,
        context.direct,
        input,
        sample,
        arena.allocator(),
        &trace,
        true,
    );
    try emit(output, .{
        .phase = "execution",
        .workload = @tagName(kind),
        .sample = sample,
        .input_bytes = input.len,
        .realization = "direct-native",
        .costs = direct,
    });
    const original_base = try bootstrap(
        io,
        a,
        context.benchmark.bootstrap,
        context.guest,
        input,
        trace.items,
    );
    try emit(output, .{
        .phase = "execution",
        .workload = @tagName(kind),
        .sample = sample,
        .input_bytes = input.len,
        .realization = "generic-bootstrap",
        .costs = original_base,
    });
    try measureReplicates(context, sample, input, arena.allocator(), &trace);
    try emit(
        output,
        .{
            .phase = "switch",
            .workload = @tagName(kind),
            .sample = sample,
            .publication = "in-memory",
            .generic_to_specialized_ns = try switching(
                io,
                a,
                context.general,
                context.specialized,
                trace.items[0].checkpoint,
            ),
            .specialized_to_generic_ns = try switching(
                io,
                a,
                context.selected,
                context.benchmark.generic,
                trace.items[0].checkpoint,
            ),
        },
    );
}

fn measureReplicates(
    context: WorkloadContext,
    sample: usize,
    input: []const u8,
    trace_allocator: std.mem.Allocator,
    trace: *std.ArrayList(Step),
) !void {
    const a = context.benchmark.a;
    const io = context.benchmark.io;
    const output = context.benchmark.output;
    const kind = context.kind;
    for (0..3) |replicate| {
        inline for (.{
            "generic-base", "specialized-base", "instrumented-base", "generated-candidate",
        }, 0..) |name, index| {
            const measured = try run(kosmos, io, a, switch (index) {
                0 => context.general,
                1 => context.selected,
                2 => context.observed,
                else => context.candidate,
            }, input, sample, trace_allocator, trace, false);
            try emit(output, .{
                .phase = "execution",
                .workload = @tagName(kind),
                .sample = sample,
                .replicate = replicate,
                .input_bytes = input.len,
                .realization = name,
                .costs = measured,
            });
        }
        try measureGuarded(context, sample, replicate, input, trace_allocator, trace);
    }
}

fn scalarModule(e: Author) !horos.source.Module {
    const b = e.b;
    const entry = try b.declare(&.{e.integer}, e.integer, &.{}, &.{});
    try b.define(entry, try b.pure(try e.binary(
        .integer_bit_xor,
        try e.param(entry, 0),
        try b.constant(u64, 0x12345678),
    )));
    return b.module(entry, e.unit);
}

fn scalarChainModule(e: Author, kind: Workload) !horos.source.Module {
    const b = e.b;
    const entry = try b.declare(&.{e.integer}, e.integer, &.{}, &.{});
    var value = try e.param(entry, 0);
    for (0..@as(usize, if (kind == .scalar_chain_large) 96 else 24)) |i| {
        value = try e.binary(.integer_add, value, try b.constant(u64, 17 + i));
        value = try e.binary(.integer_bit_xor, value, try b.constant(u64, 0x12345678 + i));
    }
    try b.define(entry, try b.pure(value));
    return b.module(entry, e.unit);
}

fn structuredModule(e: Author) !horos.source.Module {
    const b = e.b;
    const pair = try b.schema(.{ .product = &.{ e.integer, e.integer } });
    const entry = try b.declare(&.{pair}, pair, &.{}, &.{});
    const value = try e.param(entry, 0);
    try b.define(entry, try b.pure(try e.tuple(pair, &.{ try e.binary(
        .integer_bit_xor,
        try e.field(value, 0),
        try e.field(value, 1),
    ), try e.field(value, 0) })));
    return b.module(entry, e.unit);
}

fn loopModule(e: Author, kind: Workload) !horos.source.Module {
    const b = e.b;
    const entry = try b.declare(&.{ e.integer, e.integer }, e.integer, &.{}, &.{});
    const loop = try b.declare(&.{ e.integer, e.integer }, e.integer, &.{}, &.{});
    const count = try e.param(loop, 0);
    const acc = try e.param(loop, 1);
    const step = try e.binary(.integer_bit_xor, acc, count);
    const next = try e.call(loop, &.{
        try e.binary(.integer_sub, count, e.one), if (kind == .dynamic_loop) step else acc,
    });
    const tail = if (kind == .dynamic_loop) next else blk2: {
        const value = try b.variable(e.integer);
        break :blk2 try b.bind(value, next, try b.pure(try e.binary(
            .integer_bit_xor,
            try b.reference(value),
            count,
        )));
    };
    try b.define(loop, try e.when(
        try e.binary(.equal, count, e.zero),
        try b.pure(acc),
        tail,
    ));
    try b.define(entry, try e.call(loop, &.{
        try e.param(entry, 0), try e.param(entry, 1),
    }));
    return b.module(entry, e.unit);
}

fn cleanupModule(e: Author) !horos.source.Module {
    const b = e.b;
    const releasing = try b.effect(.{
        .identity = "benchmark/cleanup",
        .payload = e.unit,
        .result = e.unit,
    });
    const exit_info = try horos.source.library.cleanup.exitInfo(b, e.unit);
    const recursive = try b.declare(&.{e.integer}, e.integer, &.{releasing}, &.{});
    const count = try e.param(recursive, 0);
    const body = try b.declare(&.{}, e.integer, &.{releasing}, &.{});
    try b.define(body, try e.call(recursive, &.{try e.binary(.integer_sub, count, e.one)}));
    const cleanup = try b.declare(&.{exit_info}, e.unit, &.{releasing}, &.{});
    try b.define(cleanup, try b.term(.{ .perform = .{
        .effect = releasing,
        .payload = try b.constant(void, {}),
    } }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = e.integer,
        .effects = &.{releasing},
        .capture_bound = &.{e.integer},
    } } });
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{exit_info},
        .result = e.unit,
        .effects = &.{releasing},
    } } });
    const protected = try b.term(.{ .protect = .{
        .body = try b.lambda(body, body_type),
        .cleanup = try b.lambda(cleanup, cleanup_type),
    } });
    try b.define(recursive, try e.when(
        try e.binary(.equal, count, e.zero),
        try b.pure(e.zero),
        protected,
    ));
    return b.module(recursive, e.unit);
}

fn runCut(
    comptime runtime: type,
    prepared: *const runtime.Prepared,
    session: *runtime.Session,
    context: RunContext,
    costs: *Costs,
    index: usize,
    control: *protocol.Control,
) !bool {
    const a = context.a;
    const io = context.io;
    const trace = context.trace;
    const trace_allocator = context.trace_allocator;
    const recording = context.recording;
    const sample = context.sample;
    var start: std.Io.Timestamp = undefined;
    if (!recording) {
        if (index == trace.items.len) return error.ExtraGuestCut;
        control.* = trace.items[index].control;
    }
    start = now(io);
    _ = try runtime.invocation.advance(session, control.*, 256);
    costs.execute_ns += elapsed(io, start);
    start = now(io);
    var outcome = try runtime.invocation.finish(a, session, false);
    defer outcome.deinit();
    const encoded = try protocol.encodeOwned(protocol.Outcome, a, outcome.record);
    defer a.free(encoded);
    costs.observe_ns += elapsed(io, start);
    if (comptime runtime == kosmos) {
        if (session.trace()) |trace_output| {
            start = now(io);
            const trace_bytes = try projection.encode(@TypeOf(trace_output), a, trace_output);
            costs.trace_projection_ns += elapsed(io, start);
            costs.trace_bytes += trace_bytes.len;
            a.free(trace_bytes);
        } else if (prepared.runtime.content.value.hooks.control or
            prepared.runtime.content.value.hooks.storage) return error.MissingInstrumentation;
    }
    try measureCheckpoint(runtime, prepared, session, context, costs, index, control, encoded);
    costs.cuts += 1;
    switch (outcome.record) {
        .progressed => control.* = .none,
        .yielded => control.* = .resume_yield,
        .requested => |pending| {
            costs.effects += 1;
            if (recording) control.* = .{ .reply = try reply(
                trace_allocator,
                pending.request,
                sample,
            ) };
        },
        .completed, .failed, .cancelled => return false,
        .needs_capacity => return error.Capacity,
    }
    return true;
}

fn measureCheckpoint(
    comptime runtime: type,
    prepared: *const runtime.Prepared,
    session: *runtime.Session,
    context: RunContext,
    costs: *Costs,
    index: usize,
    control: *protocol.Control,
    encoded: []const u8,
) !void {
    const a = context.a;
    const io = context.io;
    const trace = context.trace;
    const trace_allocator = context.trace_allocator;
    const recording = context.recording;
    const start = now(io);
    const checkpoint = try session.checkpoint(a);
    defer a.free(checkpoint);
    costs.guest_projection_ns += elapsed(io, start);
    costs.guest_checkpoint_bytes = @max(costs.guest_checkpoint_bytes, checkpoint.len);
    if (recording) {
        const owned_control = try @import("interpreter_v2/store.zig").duplicate(
            protocol.Control,
            trace_allocator,
            control.*,
        );
        try trace.append(trace_allocator, .{
            .control = owned_control,
            .checkpoint = try trace_allocator.dupe(u8, checkpoint),
            .outcome = try trace_allocator.dupe(u8, encoded),
        });
    } else if (!std.mem.eql(u8, checkpoint, trace.items[index].checkpoint) or !std.mem.eql(
        u8,
        encoded,
        trace.items[index].outcome,
    )) return error.RealizationChanged;
    if (index == 0)
        try measureRestore(runtime, io, a, prepared, session, checkpoint, costs);
}

fn measureRestore(
    comptime runtime: type,
    io: std.Io,
    a: std.mem.Allocator,
    prepared: *const runtime.Prepared,
    session: *runtime.Session,
    checkpoint: []const u8,
    costs: *Costs,
) !void {
    var restored_meter = meter(a);
    const start = now(io);
    var restored = try runtime.Session.restore(
        restored_meter.allocator(),
        prepared,
        checkpoint,
    );
    costs.guest_restore_ns = elapsed(io, start);
    costs.restore_peak_bytes = restored_meter.peak;
    restored.deinit();
    if (restored_meter.live != 0) return error.LeakedRestore;
    if (comptime runtime == kosmos)
        try measureOuterRestore(io, a, prepared, session, checkpoint, costs);
}

fn measureOuterRestore(
    io: std.Io,
    a: std.mem.Allocator,
    prepared: *const kosmos.Prepared,
    session: *kosmos.Session,
    checkpoint: []const u8,
    costs: *Costs,
) !void {
    var start: std.Io.Timestamp = undefined;
    const provenance: kosmos.RuntimeCapsule.Provenance = .{
        .execution = @splat(1),
        .custody = @splat(2),
        .publication = .{
            .digest = artifact.digest(checkpoint),
            .bytes = checkpoint.len,
        },
    };
    start = now(io);
    const outer = try kosmos.RuntimeCapsule.publish(
        a,
        &session.driver,
        .outer_execution,
        provenance,
    );
    costs.outer_checkpoint_ns = elapsed(io, start);
    defer a.free(outer);
    costs.outer_checkpoint_bytes = outer.len;
    const Owner = struct {
        fn claim(
            _: *anyopaque,
            _: kosmos.RuntimeCapsule.Reference,
            _: kosmos.RuntimeCapsule.Record,
            _: kosmos.RuntimeCapsule.Reference,
        ) !void {}
    };
    var owner: u8 = 0;
    start = now(io);
    var carried = try kosmos.RuntimeCapsule.restore(
        a,
        &prepared.guest,
        &prepared.runtime,
        outer,
        .{ .context = &owner, .claim = Owner.claim },
    );
    costs.outer_restore_ns = elapsed(io, start);
    carried.deinit();
}

fn bootstrapCut(
    io: std.Io,
    a: std.mem.Allocator,
    prepared: *const native.Prepared,
    outer: *native.Session,
    step: Step,
    index: usize,
    costs: *Costs,
) !void {
    var start: std.Io.Timestamp = undefined;
    var decoded: ?data.invocation.Owned(protocol.Result) = null;
    defer if (decoded) |*value| value.deinit();
    const control: service.Control = switch (step.control) {
        .none => .none,
        .resume_yield => .resume_yield,
        .cancel => |reason| .{ .cancel = reason },
        .reply => |bytes| blk: {
            decoded = try protocol.decode(protocol.Result, a, bytes);
            break :blk .{ .answer = decoded.?.value.value };
        },
    };
    start = now(io);
    try send(a, outer, .{ .advance = .{ .control = control, .quantum = 256 } });
    var cut = try event(a, outer);
    defer cut.deinit();
    costs.execute_ns += elapsed(io, start);
    if (cut.value != .cut) return error.InvalidServiceEvent;
    costs.guest_work += cut.value.cut.guest_work;
    start = now(io);
    try send(a, outer, .project);
    var projected = try event(a, outer);
    defer projected.deinit();
    if (projected.value != .projection) return error.InvalidServiceEvent;
    var canonical = try data.state_image.canonicalize(a, projected.value.projection);
    defer canonical.deinit();
    const checkpoint = try data.state_image.emit(a, canonical.state);
    defer a.free(checkpoint);
    costs.guest_projection_ns += elapsed(io, start);
    if (!std.mem.eql(u8, checkpoint, step.checkpoint)) return error.BootstrapChanged;
    costs.guest_checkpoint_bytes = @max(costs.guest_checkpoint_bytes, checkpoint.len);
    if (index == 0) {
        start = now(io);
        const saved = try outer.checkpoint(a);
        defer a.free(saved);
        costs.outer_checkpoint_ns = elapsed(io, start);
        costs.outer_checkpoint_bytes = saved.len;
        start = now(io);
        var restored = try native.Session.restore(a, prepared, saved);
        costs.outer_restore_ns = elapsed(io, start);
        restored.deinit();
    }
    if (step.control == .reply) costs.effects += 1;
    costs.cuts += 1;
}

fn buildProposal(
    resources: *kosmos.AllocationBudget,
    io: std.Io,
    generic: *const kosmos.RuntimeArtifact,
    output: *std.Io.Writer,
) !projection.Owned(kosmos.RuntimeCompiler.RecordProposal) {
    const storage = resources.allocator();
    var start = now(io);
    var exported = try kosmos.RuntimeCompiler.exportSource(storage, generic);
    defer exported.deinit();
    const export_ns = elapsed(io, start);
    start = now(io);
    var builder = horos.source.Builder.init(storage);
    defer builder.deinit();
    const module = try kosmos.RuntimeTransformation.scalar(&builder);
    var compiled = try horos.source.lower(storage, module);
    defer compiled.deinit();
    const image_length = try data.program_image.encodedLength(compiled.program);
    const image_bytes = try storage.alloc(u8, image_length);
    defer storage.free(image_bytes);
    _ = try compiled.encode(storage, image_bytes);
    var prepared = try @import("base/session.zig").Prepared.init(storage, image_bytes);
    defer prepared.deinit();
    const construction_ns = elapsed(io, start);
    const input = try projection.encode(kosmos.RuntimeTransformation.Input, storage, .{
        .module = exported.value.selected.module,
        .first_value = 0,
        .edits_max = 16,
    });
    defer storage.free(input);
    start = now(io);
    var producer = try @import("base/session.zig").Session.start(storage, &prepared, input, .{});
    defer producer.deinit();
    const outcome = try producer.run(null);
    if (outcome != .completed) return error.ProducerFailed;
    const result = try producer.bytes(&outcome.completed);
    var proposed = try projection.decode(kosmos.RuntimeCompiler.RecordProposal, storage, result);
    errdefer proposed.deinit();
    if (proposed.value.steps.len != 16) return error.MissingGeneratedEdit;
    try emit(output, .{
        .phase = "generated-producer",
        .source_export_ns = export_ns,
        .construction_prepare_ns = construction_ns,
        .execute_decode_ns = elapsed(io, start),
        .image_bytes = image_bytes.len,
        .input_bytes = input.len,
        .output_bytes = result.len,
        .base_work = producer.transitions,
        .peak_bytes = resources.peak,
        .source = std.fmt.bytesToHex(exported.value.selected.digest, .lower),
        .first_value = 0,
        .edits_max = 16,
    });
    return proposed;
}

fn buildCandidate(
    context: BenchmarkContext,
    guest: *const data.program_image.Admitted,
    kind: Workload,
    construction: *kosmos.AllocationBudget,
) !BuiltArtifact {
    var start = now(context.io);
    const bytes = try kosmos.RuntimeCompiler.deriveRecord(
        construction.allocator(),
        context.generic,
        guest,
        context.proposal.*,
        .{ .horos_package = context.generic.content.value.manifest.compiler.horos_package },
    );
    errdefer construction.allocator().free(bytes);
    const derive_ns = elapsed(context.io, start);
    start = now(context.io);
    var candidate = try kosmos.RuntimeArtifact.init(context.a, bytes, artifact.digest(bytes));
    errdefer candidate.deinit();
    const admission_ns = elapsed(context.io, start);
    var validation = meter(context.a);
    start = now(context.io);
    try kosmos.RuntimeCompiler.validateAgainst(validation.allocator(), &candidate, context.generic);
    try emit(context.output, .{
        .phase = "generated-candidate-construction",
        .workload = @tagName(kind),
        .derive_ns = derive_ns,
        .admission_ns = admission_ns,
        .independent_validation_ns = elapsed(context.io, start),
        .construction_peak_bytes = construction.peak,
        .validation_peak_bytes = validation.peak,
        .artifact_bytes = bytes.len,
        .executable_bytes = candidate.content.value.image.len,
        .proof_bytes = candidate.content.value.evidence.len,
        .artifact = std.fmt.bytesToHex(candidate.identity, .lower),
    });
    return .{ .bytes = bytes, .artifact = candidate, .admission_ns = admission_ns };
}

fn measureGuarded(
    context: WorkloadContext,
    sample: usize,
    replicate: usize,
    input: []const u8,
    trace_allocator: std.mem.Allocator,
    trace: *std.ArrayList(Step),
) !void {
    const io = context.benchmark.io;
    var resources = meter(context.benchmark.a);
    const a = resources.allocator();
    const total_start = now(io);
    var costs = [_]Costs{ .{}, .{} };
    const prepared = [_]*const kosmos.Prepared{ context.general, context.candidate };
    var statistics = [_]kosmos.Statistics{ .{}, .{} };
    var side_resources = [_]kosmos.AllocationBudget{ meter(a), meter(a) };
    var start = now(io);
    var reference = try kosmos.Session.start(side_resources[0].allocator(), prepared[0], input);
    defer reference.deinit();
    costs[0].start_ns = elapsed(io, start);
    start = now(io);
    var candidate = try kosmos.Session.start(side_resources[1].allocator(), prepared[1], input);
    defer candidate.deinit();
    costs[1].start_ns = elapsed(io, start);
    const sessions = [_]*kosmos.Session{ &reference, &candidate };
    const run_context: RunContext = .{
        .io = io,
        .a = a,
        .sample = sample,
        .trace_allocator = trace_allocator,
        .trace = trace,
        .recording = false,
    };
    for (sessions, &statistics) |session, *stats| session.setStatistics(stats);
    for (trace.items, 0..) |_, index| {
        for (sessions, prepared, &costs) |session, selected, *cost| {
            var control: protocol.Control = .none;
            const more = try runCut(kosmos, selected, session, run_context, cost, index, &control);
            if (more != (index + 1 < trace.items.len)) return error.GuardTraceChanged;
        }
        if (statistics[0].transitions != statistics[1].transitions) return error.GuardWorkChanged;
    }
    for (&costs, statistics, side_resources) |*cost, stats, side| {
        cost.guest_work = stats.transitions;
        cost.base_work = stats.base_transitions;
        cost.copied_blob_bytes = stats.storage.copied_blob_bytes;
        cost.live_bytes = side.live;
        cost.peak_bytes = side.peak;
    }
    try emit(context.benchmark.output, .{
        .phase = "execution",
        .workload = @tagName(context.kind),
        .sample = sample,
        .replicate = replicate,
        .input_bytes = input.len,
        .realization = "generated-candidate-reference-guarded",
        .guard_scope = "paired generic and candidate cuts checked against independent native trace",
        .native_trace_preparation = "separate direct-native row",
        .reference = costs[0],
        .candidate = costs[1],
        .total_ns = elapsed(io, total_start),
        .total_base_work = costs[0].base_work + costs[1].base_work,
        .combined_live_bytes = resources.live,
        .combined_peak_bytes = resources.peak,
    });
}
