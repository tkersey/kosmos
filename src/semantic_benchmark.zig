//! Matched dynamic inputs and controls across the frozen native evaluator,
//! portable bootstrap, restricted base and checked specialization. JSONL costs
//! include construction and explicit publication; no elapsed-time pass threshold.
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

const Workload = enum { scalar, scalar_chain, scalar_chain_large, dynamic_loop, structured, repeated_calls, higher_order, handlers, multi_shot, long_cleanup, retained_bytes };
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
        .scalar => blk: {
            const entry = try b.declare(&.{e.integer}, e.integer, &.{}, &.{});
            try b.define(entry, try b.pure(try e.binary(.integer_bit_xor, try e.param(entry, 0), try b.constant(u64, 0x12345678))));
            break :blk b.module(entry, e.unit);
        },
        .scalar_chain, .scalar_chain_large => blk: {
            const entry = try b.declare(&.{e.integer}, e.integer, &.{}, &.{});
            var value = try e.param(entry, 0);
            for (0..@as(usize, if (kind == .scalar_chain_large) 96 else 24)) |i| {
                value = try e.binary(.integer_add, value, try b.constant(u64, 17 + i));
                value = try e.binary(.integer_bit_xor, value, try b.constant(u64, 0x12345678 + i));
            }
            try b.define(entry, try b.pure(value));
            break :blk b.module(entry, e.unit);
        },
        .structured => blk: {
            const pair = try b.schema(.{ .product = &.{ e.integer, e.integer } });
            const entry = try b.declare(&.{pair}, pair, &.{}, &.{});
            const value = try e.param(entry, 0);
            try b.define(entry, try b.pure(try e.tuple(pair, &.{ try e.binary(.integer_bit_xor, try e.field(value, 0), try e.field(value, 1)), try e.field(value, 0) })));
            break :blk b.module(entry, e.unit);
        },
        .dynamic_loop, .repeated_calls => blk: {
            const entry = try b.declare(&.{ e.integer, e.integer }, e.integer, &.{}, &.{});
            const loop = try b.declare(&.{ e.integer, e.integer }, e.integer, &.{}, &.{});
            const count = try e.param(loop, 0);
            const acc = try e.param(loop, 1);
            const step = try e.binary(.integer_bit_xor, acc, count);
            const next = try e.call(loop, &.{ try e.binary(.integer_sub, count, e.one), if (kind == .dynamic_loop) step else acc });
            const tail = if (kind == .dynamic_loop) next else blk2: {
                const value = try b.variable(e.integer);
                break :blk2 try b.bind(value, next, try b.pure(try e.binary(.integer_bit_xor, try b.reference(value), count)));
            };
            try b.define(loop, try e.when(try e.binary(.equal, count, e.zero), try b.pure(acc), tail));
            try b.define(entry, try e.call(loop, &.{ try e.param(entry, 0), try e.param(entry, 1) }));
            break :blk b.module(entry, e.unit);
        },
        .long_cleanup => blk: {
            const releasing = try b.effect(.{ .identity = "benchmark/cleanup", .payload = e.unit, .result = e.unit });
            const exit_info = try horos.library.cleanup.exitInfo(&b, e.unit);
            const recursive = try b.declare(&.{e.integer}, e.integer, &.{releasing}, &.{});
            const count = try e.param(recursive, 0);
            const body = try b.declare(&.{}, e.integer, &.{releasing}, &.{});
            try b.define(body, try e.call(recursive, &.{try e.binary(.integer_sub, count, e.one)}));
            const cleanup = try b.declare(&.{exit_info}, e.unit, &.{releasing}, &.{});
            try b.define(cleanup, try b.term(.{ .perform = .{ .effect = releasing, .payload = try b.constant(void, {}) } }));
            const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = e.integer, .effects = &.{releasing}, .capture_bound = &.{e.integer} } } });
            const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{exit_info}, .result = e.unit, .effects = &.{releasing} } } });
            const protected = try b.term(.{ .protect = .{ .body = try b.lambda(body, body_type), .cleanup = try b.lambda(cleanup, cleanup_type) } });
            try b.define(recursive, try e.when(try e.binary(.equal, count, e.zero), try b.pure(e.zero), protected));
            break :blk b.module(recursive, e.unit);
        },
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
        .scalar, .scalar_chain, .scalar_chain_large, .higher_order => a.dupe(u8, &std.mem.toBytes(seed)),
        .dynamic_loop, .repeated_calls => a.dupe(u8, &(@as([16]u8, std.mem.toBytes(@as(u64, 16 + sample * 16)) ++ std.mem.toBytes(seed)))),
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
    const body: []const u8 = if (std.mem.eql(u8, request.value.binding.semantic_identity, "local/producer")) &std.mem.toBytes(@as(u64, 41 + sample * 19)) else &.{};
    return protocol.encodeOwned(protocol.Result, a, .{ .request_identity = request.value.request_identity, .value = body });
}
fn run(comptime runtime: type, io: std.Io, a: std.mem.Allocator, prepared: *const runtime.Prepared, input: []const u8, sample: usize, trace_allocator: std.mem.Allocator, trace: *std.ArrayList(Step), recording: bool) !Costs {
    var m = meter(a);
    var statistics: std.meta.Child(std.meta.Child(@FieldType(runtime.Session, "statistics"))) = .{};
    var costs: Costs = .{};
    var start = now(io);
    var session = try runtime.Session.start(m.allocator(), prepared, input);
    costs.start_ns = elapsed(io, start);
    defer session.deinit();
    if (comptime @hasDecl(runtime.Session, "setStatistics")) session.setStatistics(&statistics) else {
        session.statistics = &statistics;
        session.store.statistics = &statistics.storage;
    }
    var control: protocol.Control = .none;
    var index: usize = 0;
    while (true) : (index += 1) {
        if (!recording) {
            if (index == trace.items.len) return error.ExtraGuestCut;
            control = trace.items[index].control;
        }
        start = now(io);
        _ = try runtime.invocation.advance(&session, control, 256);
        costs.execute_ns += elapsed(io, start);
        start = now(io);
        var outcome = try runtime.invocation.finish(a, &session, false);
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
            } else if (prepared.runtime.content.value.hooks.control or prepared.runtime.content.value.hooks.storage) return error.MissingInstrumentation;
        }
        start = now(io);
        const checkpoint = try session.checkpoint(a);
        defer a.free(checkpoint);
        costs.guest_projection_ns += elapsed(io, start);
        costs.guest_checkpoint_bytes = @max(costs.guest_checkpoint_bytes, checkpoint.len);
        if (recording) {
            const owned_control = try @import("interpreter_v2/store.zig").duplicate(protocol.Control, trace_allocator, control);
            try trace.append(trace_allocator, .{ .control = owned_control, .checkpoint = try trace_allocator.dupe(u8, checkpoint), .outcome = try trace_allocator.dupe(u8, encoded) });
        } else if (!std.mem.eql(u8, checkpoint, trace.items[index].checkpoint) or !std.mem.eql(u8, encoded, trace.items[index].outcome)) return error.RealizationChanged;
        if (index == 0) {
            var restored_meter = meter(a);
            start = now(io);
            var restored = try runtime.Session.restore(restored_meter.allocator(), prepared, checkpoint);
            costs.guest_restore_ns = elapsed(io, start);
            costs.restore_peak_bytes = restored_meter.peak;
            restored.deinit();
            if (restored_meter.live != 0) return error.LeakedRestore;
            if (comptime runtime == kosmos) {
                const provenance: kosmos.RuntimeCapsule.Provenance = .{ .execution = @splat(1), .custody = @splat(2), .publication = .{ .digest = artifact.digest(checkpoint), .bytes = checkpoint.len } };
                start = now(io);
                const outer = try kosmos.RuntimeCapsule.publish(a, &session.driver, .outer_execution, provenance);
                costs.outer_checkpoint_ns = elapsed(io, start);
                defer a.free(outer);
                costs.outer_checkpoint_bytes = outer.len;
                const Owner = struct {
                    fn claim(_: *anyopaque, _: kosmos.RuntimeCapsule.Reference, _: kosmos.RuntimeCapsule.Record, _: kosmos.RuntimeCapsule.Reference) !void {}
                };
                var owner: u8 = 0;
                start = now(io);
                var carried = try kosmos.RuntimeCapsule.restore(a, &prepared.guest, &prepared.runtime, outer, .{ .context = &owner, .claim = Owner.claim });
                costs.outer_restore_ns = elapsed(io, start);
                carried.deinit();
            }
        }
        costs.cuts += 1;
        switch (outcome.record) {
            .progressed => control = .none,
            .yielded => control = .resume_yield,
            .requested => |pending| {
                costs.effects += 1;
                if (recording) control = .{ .reply = try reply(trace_allocator, pending.request, sample) };
            },
            .completed, .failed, .cancelled => break,
            .needs_capacity => return error.Capacity,
        }
    }
    if (!recording and costs.cuts != trace.items.len) return error.MissingGuestCut;
    costs.guest_work = statistics.transitions;
    // The historical direct evaluator has no outer/base execution level.
    costs.base_work = if (@hasField(@TypeOf(statistics), "base_transitions")) statistics.base_transitions else 0;
    costs.copied_blob_bytes = statistics.storage.copied_blob_bytes;
    if (@hasField(@TypeOf(statistics.storage), "field_projection_hits")) costs.field_projection_hits = statistics.storage.field_projection_hits;
    if (@hasField(@TypeOf(statistics.storage), "field_projection_scans")) costs.field_projection_scans = statistics.storage.field_projection_scans;
    if (@hasField(@TypeOf(statistics.storage), "element_projection_hits")) costs.element_projection_hits = statistics.storage.element_projection_hits;
    costs.live_bytes = m.live;
    costs.peak_bytes = m.peak;
    return costs;
}
fn send(a: std.mem.Allocator, outer: *native.Session, command: service.Command) !void {
    var pending = try outer.pendingBinding(a, false);
    defer pending.deinit();
    const value = try projection.encode(service.Command, a, command);
    defer a.free(value);
    const response = try protocol.encodeOwned(protocol.Result, a, .{ .request_identity = pending.request.request_identity, .value = value });
    defer a.free(response);
    try outer.answer(response);
}
fn event(a: std.mem.Allocator, outer: *native.Session) !projection.Owned(service.Event) {
    const observation = try outer.run(null);
    if (observation != .requested) return error.InvalidServiceEvent;
    return projection.decode(service.Event, a, try outer.bytes(&observation.requested.payload));
}
fn bootstrap(io: std.Io, a: std.mem.Allocator, prepared: *const native.Prepared, guest: *const data.program_image.Admitted, input: []const u8, trace: []const Step) !Costs {
    var m = meter(a);
    const program = try projection.programBytes(a, guest);
    defer a.free(program);
    const initial = try projection.encode(service.Initial, a, .{ .arguments = input });
    defer a.free(initial);
    const args = try std.mem.concat(a, u8, &.{ program, initial });
    defer a.free(args);
    var costs: Costs = .{};
    var start = now(io);
    var outer = try native.Session.start(m.allocator(), prepared, args);
    defer outer.deinit();
    var first = try event(a, &outer);
    first.deinit();
    costs.start_ns = elapsed(io, start);
    var statistics: std.meta.Child(std.meta.Child(@FieldType(native.Session, "statistics"))) = .{};
    outer.statistics = &statistics;
    outer.store.statistics = &statistics.storage;
    for (trace, 0..) |step, index| {
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
        try send(a, &outer, .{ .advance = .{ .control = control, .quantum = 256 } });
        var cut = try event(a, &outer);
        defer cut.deinit();
        costs.execute_ns += elapsed(io, start);
        if (cut.value != .cut) return error.InvalidServiceEvent;
        costs.guest_work += cut.value.cut.guest_work;
        start = now(io);
        try send(a, &outer, .project);
        var projected = try event(a, &outer);
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
    costs.base_work = statistics.transitions;
    costs.copied_blob_bytes = statistics.storage.copied_blob_bytes;
    costs.live_bytes = m.live;
    costs.peak_bytes = m.peak;
    return costs;
}
fn switching(io: std.Io, a: std.mem.Allocator, prepared: *const kosmos.Prepared, target: *const kosmos.RuntimeArtifact, checkpoint: []const u8) !i96 {
    var resident = try kosmos.Resident.restore(a, prepared, checkpoint);
    defer if (resident.live) {
        const saved = resident.takeCheckpoint(a) catch unreachable;
        a.free(saved);
    };
    const Owner = struct {
        fn publish(_: *anyopaque, _: kosmos.RuntimeCapsule.Binding, _: []const u8, _: []const u8) kosmos.RuntimeCapsule.SwitchDecision {
            return .committed;
        }
    };
    var owner: u8 = 0;
    const bound = try resident.runtimeBinding();
    const start = now(io);
    if (try resident.realize(bound, target, .{ .execution = @splat(3), .custody = @splat(4), .publication = null }, .{ .context = &owner, .publish = Owner.publish }) != .committed) return error.SwitchRejected;
    const duration = elapsed(io, start);
    const after = try resident.checkpoint(a);
    defer a.free(after);
    if (!std.mem.eql(u8, checkpoint, after)) return error.SwitchChanged;
    return duration;
}
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    var arguments_arena = std.heap.ArenaAllocator.init(a);
    defer arguments_arena.deinit();
    const args = try init.minimal.args.toSlice(arguments_arena.allocator());
    const filter = if (args.len > 1) args[1] else null;
    var generic_meter = meter(a);
    var start = now(init.io);
    var generic = try kosmos.RuntimeArtifact.init(generic_meter.allocator(), @import("packaged_runtime").bytes, artifact.digest(@import("packaged_runtime").bytes));
    defer generic.deinit();
    try emit(&output.interface, .{ .phase = "generic-admission", .nanoseconds = elapsed(init.io, start), .artifact_bytes = @import("packaged_runtime").bytes.len, .live_bytes = generic_meter.live, .peak_bytes = generic_meter.peak, .source = std.fmt.bytesToHex(generic.content.value.manifest.source, .lower), .artifact = std.fmt.bytesToHex(generic.identity, .lower), .zig = @import("builtin").zig_version_string, .mode = @tagName(@import("builtin").mode), .arch = @tagName(@import("builtin").cpu.arch), .os = @tagName(@import("builtin").os.tag) });
    {
        var construction = meter(a);
        start = now(init.io);
        const rebuilt = try kosmos.RuntimeCompiler.compile(construction.allocator(), .{ .horos_package = generic.content.value.manifest.compiler.horos_package });
        const build_ns = elapsed(init.io, start);
        defer construction.allocator().free(rebuilt);
        if (!std.mem.eql(u8, rebuilt, @import("packaged_runtime").bytes)) return error.GenericBuildChanged;
        start = now(init.io);
        try kosmos.RuntimeCompiler.validate(a, &generic);
        try emit(&output.interface, .{ .phase = "generic-construction", .construction_ns = build_ns, .independent_validation_ns = elapsed(init.io, start), .construction_peak_bytes = construction.peak });
    }
    var bootstrap_prepared = try native.Prepared.init(a, generic.content.value.image);
    defer bootstrap_prepared.deinit();
    var instrumented_meter = meter(a);
    start = now(init.io);
    const instrumented_bytes = try kosmos.RuntimeCompiler.compile(instrumented_meter.allocator(), .{ .horos_package = generic.content.value.manifest.compiler.horos_package, .hooks = .{ .control = true, .storage = true } });
    const instrumented_compile_ns = elapsed(init.io, start);
    defer instrumented_meter.allocator().free(instrumented_bytes);
    start = now(init.io);
    var instrumented = try kosmos.RuntimeArtifact.init(a, instrumented_bytes, artifact.digest(instrumented_bytes));
    const instrumented_admission_ns = elapsed(init.io, start);
    defer instrumented.deinit();
    start = now(init.io);
    try kosmos.RuntimeCompiler.validate(a, &instrumented);
    try emit(&output.interface, .{ .phase = "instrumented-construction", .construction_ns = instrumented_compile_ns, .admission_ns = instrumented_admission_ns, .independent_validation_ns = elapsed(init.io, start), .construction_peak_bytes = instrumented_meter.peak, .artifact_bytes = instrumented_bytes.len, .artifact = std.fmt.bytesToHex(instrumented.identity, .lower) });
    for (std.meta.tags(Workload)) |kind| {
        if (filter == null or std.mem.eql(u8, filter.?, @tagName(kind))) {
            const bytes = try image(a, kind);
            defer a.free(bytes);
            var direct_prepared = try native.Prepared.init(a, bytes);
            defer direct_prepared.deinit();
            const guest = try data.program_image.Admitted.decode(a, bytes);
            defer guest.deinit();
            var construction = meter(a);
            start = now(init.io);
            const specialized_bytes = try kosmos.RuntimeCompiler.compile(construction.allocator(), .{ .horos_package = generic.content.value.manifest.compiler.horos_package, .guest = guest });
            const compile_ns = elapsed(init.io, start);
            defer construction.allocator().free(specialized_bytes);
            start = now(init.io);
            var specialized = try kosmos.RuntimeArtifact.init(a, specialized_bytes, artifact.digest(specialized_bytes));
            const admission_ns = elapsed(init.io, start);
            defer specialized.deinit();
            start = now(init.io);
            try kosmos.RuntimeCompiler.validate(a, &specialized);
            const validate_ns = elapsed(init.io, start);
            try emit(&output.interface, .{ .phase = "construction", .workload = @tagName(kind), .guest = std.fmt.bytesToHex(guest.identity(), .lower), .guest_image_bytes = bytes.len, .construction_ns = compile_ns, .independent_validation_ns = validate_ns, .construction_peak_bytes = construction.peak, .artifact_bytes = specialized_bytes.len, .executable_bytes = specialized.content.value.image.len, .proof_bytes = specialized.content.value.evidence.len, .recovery_anchors = specialized.content.value.recovery.anchors.len });
            start = now(init.io);
            var general = try kosmos.Prepared.initWithRuntime(a, bytes, &generic);
            const generic_prepare_ns = elapsed(init.io, start);
            defer general.deinit();
            start = now(init.io);
            var selected = try kosmos.Prepared.initWithRuntime(a, bytes, &specialized);
            const specialized_prepare_ns = elapsed(init.io, start);
            defer selected.deinit();
            start = now(init.io);
            var observed_prepared = try kosmos.Prepared.initWithRuntime(a, bytes, &instrumented);
            const instrumented_prepare_ns = elapsed(init.io, start);
            defer observed_prepared.deinit();
            try emit(&output.interface, .{ .phase = "setup", .workload = @tagName(kind), .specialized_admission_ns = admission_ns, .generic_prepare_ns = generic_prepare_ns, .specialized_prepare_ns = specialized_prepare_ns, .instrumented_prepare_ns = instrumented_prepare_ns });
            for (0..3) |sample| {
                const input = try arguments(a, kind, sample);
                defer a.free(input);
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                var trace: std.ArrayList(Step) = .empty;
                const direct = try run(native, init.io, a, &direct_prepared, input, sample, arena.allocator(), &trace, true);
                try emit(&output.interface, .{ .phase = "execution", .workload = @tagName(kind), .sample = sample, .input_bytes = input.len, .realization = "direct-native", .costs = direct });
                const original_base = try bootstrap(init.io, a, &bootstrap_prepared, guest, input, trace.items);
                try emit(&output.interface, .{ .phase = "execution", .workload = @tagName(kind), .sample = sample, .input_bytes = input.len, .realization = "generic-bootstrap", .costs = original_base });
                for (0..3) |replicate| {
                    inline for (.{ "generic-base", "specialized-base", "instrumented-base" }, 0..) |name, index| {
                        const measured = try run(kosmos, init.io, a, switch (index) {
                            0 => &general,
                            1 => &selected,
                            else => &observed_prepared,
                        }, input, sample, arena.allocator(), &trace, false);
                        try emit(&output.interface, .{ .phase = "execution", .workload = @tagName(kind), .sample = sample, .replicate = replicate, .input_bytes = input.len, .realization = name, .costs = measured });
                    }
                }
                try emit(&output.interface, .{ .phase = "switch", .workload = @tagName(kind), .sample = sample, .publication = "in-memory", .generic_to_specialized_ns = try switching(init.io, a, &general, &specialized, trace.items[0].checkpoint), .specialized_to_generic_ns = try switching(init.io, a, &selected, &generic, trace.items[0].checkpoint) });
            }
        }
    }
}
