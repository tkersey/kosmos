const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const artifact = @import("artifact.zig");
const capsule = @import("capsule.zig");
const projection = @import("projection.zig");
const driver = @import("driver.zig");
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");
const experiment = @import("experiment.zig");

const CacheProduct = struct { first: u64, second: u64, padding: []const u8 };

fn projectionCacheGuest(sequence: bool) ![]u8 {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try @import("author.zig").Author.init(&b);
    const input = if (sequence)
        try b.schema(.{ .seq = e.integer })
    else
        try projection.schema(CacheProduct, &b);
    const entry = try b.declare(&.{input}, e.integer, &.{}, &.{});
    const argument = try e.param(entry, 0);
    const first = try b.variable(e.integer);
    const read = if (sequence) try e.required(argument, e.zero) else try e.field(argument, 0);
    const subsequent = if (sequence) try e.binary(
        .integer_add,
        try e.required(argument, e.one),
        try e.required(argument, e.zero),
    ) else read;
    const result = try b.pure(try e.binary(.integer_add, try b.reference(first), subsequent));
    try b.define(entry, try b.bind(first, try b.pure(read), try b.term(.{ .yield_then = result })));
    return support.encode(b.module(entry, e.unit));
}

fn retainedCacheRange(
    owner: *driver.Driver,
    values: *@import("../interpreter_v2/values.zig").Values,
) !data.graph.Value {
    const outer = &owner.outer;
    const pending = (try outer.store.get(outer.roots.pending.?)).pending;
    const frame = try outer.frames.get(pending.continuation.id);
    const reader = try outer.frames.slots.reader(frame.view);
    for (owner.selected.content.value.recovery.anchors) |anchor| {
        if (anchor.function != frame.function or anchor.role != .published_service) continue;
        const state = try values.split(try reader.at(@intCast(anchor.parameters[0].slot)));
        const machine = try values.split(state.fields[
            @intCast(owner.selected.content.value.recovery.layout.service_machine)
        ]);
        const cache_field = @backingInt(@import("machine.zig").Field.cache);
        const tree = try values.split(machine.fields[cache_field]);
        try std.testing.expectEqual(@as(u64, 1), tree.tag);
        const pair = try values.split(tree.fields[0]);
        const entry = try values.split(pair.fields[1]);
        return entry.fields[4];
    }
    return error.MissingRecoveryAnchor;
}

fn shiftedCacheCapsule(owner: *driver.Driver, original: []const u8) ![]u8 {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const Values = @import("../interpreter_v2/values.zig").Values;
    var values: Values = .{
        .allocator = scratch.allocator(),
        .schemas = owner.outer.program.schemas,
        .store = &owner.outer.store,
        .aggregate_storage = .structured,
    };
    const range = try retainedCacheRange(owner, &values);
    const parts = try values.split(range);
    var fields: [3]data.graph.Value = undefined;
    @memcpy(&fields, parts.fields);
    for (fields[1..]) |*field| field.* = Values.natural(field.schema, try std.math.add(
        u64,
        std.mem.readInt(u64, (try values.bytes(field))[0..8], .little),
        8,
    ));
    switch (range.body) {
        .reference => |reference| try owner.outer.store.replace(reference, .{ .aggregate = .{
            .schema = range.schema,
            .tag = 0,
            .fields = &fields,
        } }),
        .blob => |reference| {
            const bytes = owner.outer.store.blobs.items[@intCast(reference.id)].bytes;
            try std.testing.expectEqual(@as(usize, 24), bytes.len);
            for (&fields, 0..) |*field, i|
                @memcpy(@constCast(bytes[i * 8 ..][0..8]), try values.bytes(field));
        },
        else => return error.InvalidCacheRange,
    }
    const checkpoint = try owner.outer.checkpoint(a);
    defer a.free(checkpoint);
    var envelope = try capsule.read(a, original);
    defer envelope.deinit();
    envelope.value.checkpoint = checkpoint;
    envelope.value.record.checkpoint = capsule.reference(checkpoint);
    return projection.encode(capsule.Envelope, a, envelope.value);
}

fn checkProjectionCacheCapsule(
    selected: *artifact.Admitted,
    sequence: bool,
    input: []const u8,
) !void {
    const image = try projectionCacheGuest(sequence);
    defer a.free(image);
    var prepared = try base.Prepared.init(a, image);
    defer prepared.deinit();
    var owner = try driver.Driver.start(a, &prepared, selected, .{ .arguments = input });
    var live = true;
    defer if (live) owner.deinit();
    var initialized = try owner.pump(null);
    initialized.deinit();
    var yielded = try owner.exchange(.{ .advance = .{ .control = .none, .quantum = 100 } });
    yielded.deinit();
    try std.testing.expectEqual(.yielded, owner.last_cut.?.status);
    const provenance: capsule.Provenance = .{
        .execution = @splat(51),
        .custody = @splat(61),
        .publication = null,
    };
    const original = try capsule.publish(a, &owner, .outer_execution, provenance);
    defer a.free(original);
    const corrupted = try shiftedCacheCapsule(&owner, original);
    defer a.free(corrupted);
    for ([_]capsule.Kind{ .guest_cut, .outer_execution }) |kind| try std.testing.expectError(
        error.InvalidRecovery,
        capsule.publish(a, &owner, kind, provenance),
    );
    var rejected: Custody = .{
        .expected = capsule.reference(corrupted),
        .execution = provenance.execution,
    };
    if (capsule.restore(a, &prepared, selected, corrupted, rejected.verifier())) |candidate| {
        var unexpected = candidate;
        unexpected.deinit();
        return error.CacheRangeAccepted;
    } else |err| try std.testing.expectEqual(error.InvalidRecovery, err);
    try std.testing.expect(!rejected.consumed);
    var accepted: Custody = .{
        .expected = capsule.reference(original),
        .execution = provenance.execution,
    };
    owner.deinit();
    live = false;
    var restored = try capsule.restore(a, &prepared, selected, original, accepted.verifier());
    defer restored.deinit();
    try std.testing.expect(accepted.consumed);
    try finishProjectionCacheCapsule(&restored, &prepared, selected, provenance, image, input);
}

fn finishProjectionCacheCapsule(
    owner: *driver.Driver,
    prepared: *base.Prepared,
    selected: *artifact.Admitted,
    provenance: capsule.Provenance,
    image: []const u8,
    input: []const u8,
) !void {
    try owner.submit(.{ .advance = .{ .control = .resume_yield, .quantum = 100 } });
    var partial = try owner.pump(1);
    defer partial.deinit();
    try std.testing.expect(partial == .suspended);
    const bytes = try capsule.publish(a, owner, .outer_execution, provenance);
    defer a.free(bytes);
    const before = try owner.outer.checkpoint(a);
    defer a.free(before);
    var custody: Custody = .{
        .expected = capsule.reference(bytes),
        .execution = provenance.execution,
    };
    const resumed = try capsule.restore(a, prepared, selected, bytes, custody.verifier());
    owner.deinit();
    owner.* = resumed;
    const after = try owner.outer.checkpoint(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    var completed = try owner.pump(null);
    completed.deinit();
    try std.testing.expectEqual(.completed, owner.last_cut.?.status);
    var oracle = try @import("native_baseline").Session.initImage(a, image, input);
    defer oracle.deinit();
    try std.testing.expect(try oracle.run(null) == .yielded);
    try oracle.resumeYield();
    try std.testing.expect(try oracle.run(null) == .completed);
    const expected = try oracle.checkpoint(a);
    defer a.free(expected);
    const actual = try owner.checkpoint(a);
    defer a.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "outer capsules reject shifted projection ranges before claiming custody" {
    const retained = @import("packaged_runtime").bytes;
    var runtime = try artifact.Admitted.init(a, retained, artifact.digest(retained));
    defer runtime.deinit();
    const record = try projection.encode(CacheProduct, a, .{
        .first = 17,
        .second = 29,
        .padding = &@as([4096]u8, @splat(3)),
    });
    defer a.free(record);
    try checkProjectionCacheCapsule(&runtime, false, record);
    var numbers: [512]u64 = @splat(23);
    numbers[0] = 7;
    numbers[1] = 11;
    const sequence = try projection.encode([]const u64, a, &numbers);
    defer a.free(sequence);
    try checkProjectionCacheCapsule(&runtime, true, sequence);
}

test "quarantined runtime preserves bounded phase progress without guest custody" {
    const retained = @import("packaged_runtime").bytes;
    var runtime = try artifact.Admitted.init(a, retained, artifact.digest(retained));
    defer runtime.deinit();
    const image = try support.guestImage();
    defer a.free(image);
    var oracle = try @import("native_baseline").Session.initImage(
        a,
        image,
        &std.mem.toBytes(@as(u64, 5)),
    );
    defer oracle.deinit();
    const before = try oracle.checkpoint(a);
    defer a.free(before);
    var candidate = try experiment.Experiment.init(a, image, &runtime, before);
    defer candidate.deinit();
    try checkExperimentCommands(&candidate, image, &runtime);
    var initialized = try finishExperiment(&candidate, image, &runtime);
    defer initialized.deinit();
    try std.testing.expectEqual(.initialized, initialized.stage);
    try std.testing.expectEqual(@as(u64, 0), initialized.guest_work);
    try std.testing.expectEqualSlices(u8, before, initialized.checkpoint);
    try candidate.begin(.none, 2);
    var advanced = try finishExperiment(&candidate, image, &runtime);
    defer advanced.deinit();
    try std.testing.expectEqual(.advanced, advanced.stage);
    _ = try oracle.run(2);
    const expected = try oracle.checkpoint(a);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, advanced.checkpoint);
    try std.testing.expectEqual(@as(u64, 2), advanced.guest_work);
    try std.testing.expectError(error.NoOperation, candidate.pump(1));
    try checkExperimentCommands(&candidate, image, &runtime);
    const ready = try candidate.checkpointOuter(a);
    defer a.free(ready);
    var restored = try experiment.Experiment.restore(a, image, &runtime, ready);
    defer restored.deinit();
    try restored.begin(.none, 0);
    var repeated = try finishExperiment(&restored, image, &runtime);
    defer repeated.deinit();
    try std.testing.expectEqualSlices(u8, advanced.checkpoint, repeated.checkpoint);
}

test "experimental replies use retained projections without candidate recovery" {
    const image = try unitRequestImage();
    defer a.free(image);
    var runtime = try failingRecoveryCandidate(image);
    defer runtime.deinit();
    var oracle = try @import("native_baseline").Session.initImage(a, image, &.{});
    defer oracle.deinit();
    try std.testing.expect(try oracle.run(null) == .requested);
    const before = try oracle.checkpoint(a);
    defer a.free(before);
    var pending = try oracle.pendingBinding(a, false);
    defer pending.deinit();
    const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = pending.request.request_identity,
        .value = &.{},
    });
    defer a.free(reply);
    try oracle.answer(reply);
    try std.testing.expect(try oracle.run(null) == .completed);
    const expected = try oracle.checkpoint(a);
    defer a.free(expected);
    for ([_]bool{ false, true }) |restore_ready| {
        var candidate = try experiment.Experiment.init(a, image, &runtime, before);
        defer candidate.deinit();
        var initialized = try finishExperiment(&candidate, image, &runtime);
        defer initialized.deinit();
        const ready = try candidate.checkpointOuter(a);
        defer a.free(ready);
        if (restore_ready) {
            const restored = try experiment.Experiment.restore(a, image, &runtime, ready);
            candidate.deinit();
            candidate = restored;
        }
        try std.testing.expectError(error.InvalidRecovery, candidate.execution.checkpoint(a));
        try rejectNonprojectionReply(image, &runtime, ready);
        try std.testing.expectError(
            error.NonCanonical,
            candidate.begin(.{ .answer = &.{255} }, 10),
        );
        const unchanged = try candidate.checkpointOuter(a);
        defer a.free(unchanged);
        try std.testing.expectEqualSlices(u8, ready, unchanged);
        try std.testing.expectEqual(.ready, candidate.phase);
        try candidate.begin(.{ .answer = &.{} }, 10);
        var completed = try finishExperiment(&candidate, image, &runtime);
        defer completed.deinit();
        try std.testing.expectEqualSlices(u8, expected, completed.checkpoint);
    }
}

fn failingRecoveryCandidate(image: []const u8) !artifact.Admitted {
    const compiler = @import("compiler.zig");
    const retained = @import("packaged_runtime").bytes;
    var root = try artifact.Admitted.init(a, retained, artifact.digest(retained));
    defer root.deinit();
    var exported = try compiler.exportSource(a, &root);
    defer exported.deinit();
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    const b = &exported.definition.builder;
    var helpers = exported.definition.helpers;
    const projector = b.functions.items[@intCast(helpers[0])];
    try std.testing.expectEqual(@as(usize, 1), projector.parameters.len);
    const input = b.variables.items[@intCast(projector.parameters[0])];
    helpers[0] = try b.declare(&.{input}, projector.result, &.{}, &.{});
    try b.define(helpers[0], try b.term(.{ .fail = try b.constant(void, {}) }));
    const bytes = try compiler.deriveRecord(a, &root, guest, .{
        .selected = exported.definition.module(),
        .steps = &.{},
        .interfaces = .{
            .roles = exported.value.selected_roles,
            .entries = exported.value.selected_entries,
            .helpers = helpers,
            .layout = .{},
            .input = .program_and_initial,
        },
    }, .{ .horos_package = root.content.value.manifest.compiler.horos_package });
    defer a.free(bytes);
    return artifact.Admitted.init(a, bytes, artifact.digest(bytes));
}

fn rejectNonprojectionReply(
    image: []const u8,
    runtime: *const artifact.Admitted,
    ready: []const u8,
) !void {
    var observed = try experiment.Experiment.restore(a, image, runtime, ready);
    defer observed.deinit();
    var event = try observed.execution.exchange(.observe);
    defer event.deinit();
    const checkpoint = try observed.execution.outer.checkpoint(a);
    defer a.free(checkpoint);
    var record = try projection.decode(experiment.Record, a, ready);
    defer record.deinit();
    record.value.checkpoint = checkpoint;
    const bytes = try projection.encode(experiment.Record, a, record.value);
    defer a.free(bytes);
    var restored = try experiment.Experiment.restore(a, image, runtime, bytes);
    defer restored.deinit();
    try std.testing.expectError(
        error.InvalidServiceEvent,
        restored.begin(.{ .answer = &.{} }, 10),
    );
    const unchanged = try restored.checkpointOuter(a);
    defer a.free(unchanged);
    try std.testing.expectEqualSlices(u8, bytes, unchanged);
}

fn unitRequestImage() ![]u8 {
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const effect = try b.effect(.{ .identity = "unit", .payload = unit, .result = unit });
    const entry = try b.declare(&.{}, unit, &.{effect}, &.{});
    const request = try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.constant(void, {}),
    } });
    try b.define(entry, try b.bind(try b.variable(unit), request, try b.pure(
        try b.constant(void, {}),
    )));
    return support.encode(b.module(entry, unit));
}

fn checkExperimentCommands(
    candidate: *experiment.Experiment,
    image: []const u8,
    runtime: *const artifact.Admitted,
) !void {
    const service = @import("service.zig");
    const bytes = try candidate.checkpointOuter(a);
    defer a.free(bytes);
    var decoded = try projection.decode(experiment.Record, a, bytes);
    defer decoded.deinit();
    const commands = [_]service.Command{
        .{ .advance = .{ .control = .none, .quantum = 1 } }, .observe, .project, .finish,
    };
    const accepted: ?std.meta.Tag(service.Command) = switch (candidate.phase) {
        .initializing => null,
        .advancing => .advance,
        .observing => .observe,
        .projecting, .ready => .project,
    };
    for (commands) |command| {
        if (accepted == std.meta.activeTag(command)) continue;
        const command_bytes = try projection.encode(service.Command, a, command);
        defer a.free(command_bytes);
        var record = decoded.value;
        record.command = command_bytes;
        const invalid = try projection.encode(experiment.Record, a, record);
        defer a.free(invalid);
        try std.testing.expectError(error.InvalidExperiment, experiment.Experiment.restore(
            a,
            image,
            runtime,
            invalid,
        ));
    }
}

fn finishExperiment(
    candidate: *experiment.Experiment,
    image: []const u8,
    runtime: *const artifact.Admitted,
) !experiment.Segment {
    var retained: [5]bool = @splat(false);
    for (0..100_000) |_| {
        const before = candidate.execution.outer.transitions;
        const phase = candidate.phase;
        const result = try candidate.pump(31);
        try std.testing.expect(candidate.execution.outer.transitions - before <= 31);
        if (result == .complete) return result.complete;
        const index = @backingInt(phase);
        if (retained[index]) continue;
        retained[index] = true;
        try checkExperimentCommands(candidate, image, runtime);
        const bytes = try candidate.checkpointOuter(a);
        defer a.free(bytes);
        var restored = try experiment.Experiment.restore(a, image, runtime, bytes);
        errdefer restored.deinit();
        const again = try restored.checkpointOuter(a);
        defer a.free(again);
        try std.testing.expectEqualSlices(u8, bytes, again);
        candidate.deinit();
        candidate.* = restored;
    }
    return error.ExperimentDidNotComplete;
}

const Custody = struct {
    expected: capsule.Reference,
    execution: [32]u8,
    consumed: bool = false,
    fn claim(
        context: *anyopaque,
        actual: capsule.Reference,
        record: capsule.Record,
        target: capsule.Reference,
    ) !void {
        const self: *Custody = @ptrCast(@alignCast(context));
        if (self.consumed or !std.meta.eql(self.expected, actual) or !std.mem.eql(
            u8,
            &self.execution,
            &record.provenance.execution,
        ) or !std.meta.eql(record.artifact, target)) return error.UnauthorizedCapsule;
        self.consumed = true;
    }
    fn verifier(self: *Custody) capsule.Verifier {
        return .{ .context = self, .claim = claim };
    }
};

fn finishCapsules(
    selected: *artifact.Admitted,
    prepared: *base.Prepared,
    input: u64,
    cancelled: bool,
    terminal: data.process_state.Status,
) !void {
    var owner = try driver.Driver.start(a, prepared, selected, .{
        .arguments = &std.mem.toBytes(input),
    });
    var live = true;
    defer if (live) owner.deinit();
    var initialized = try owner.pump(null);
    initialized.deinit();
    var advanced = try owner.exchange(.{ .advance = .{
        .control = if (cancelled) .{ .cancel = .{ .text = "finish capsule" } } else .none,
        .quantum = 1024,
    } });
    advanced.deinit();
    try std.testing.expectEqual(terminal, owner.last_cut.?.status);
    const guest_revision = owner.guest_revision;
    const cut = owner.last_cut.?;
    try owner.submit(.finish);
    var cuts: usize = 0;
    for (0..std.math.maxInt(usize)) |_| {
        var result = try owner.pump(1);
        defer result.deinit();
        if (result == .closed) break;
        try std.testing.expect(result == .suspended);
        try std.testing.expectError(error.GuestCutUnavailable, owner.checkpoint(a));
        const provenance: capsule.Provenance = .{
            .execution = @splat(31),
            .custody = @splat(41),
            .publication = null,
        };
        const bytes = try capsule.publish(a, &owner, .outer_execution, provenance);
        defer a.free(bytes);
        const before = try owner.outer.checkpoint(a);
        defer a.free(before);
        var custody: Custody = .{
            .expected = capsule.reference(bytes),
            .execution = provenance.execution,
        };
        owner.deinit();
        live = false;
        owner = try capsule.restore(a, prepared, selected, bytes, custody.verifier());
        live = true;
        try std.testing.expect(custody.consumed);
        const after = try owner.outer.checkpoint(a);
        defer a.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
        try std.testing.expectEqual(driver.Operation.finish, owner.operation.?);
        try std.testing.expectEqual(guest_revision, owner.guest_revision);
        try std.testing.expectEqualDeep(cut, owner.last_cut.?);
        cuts += 1;
    } else return error.PumpBoundExhausted;
    try std.testing.expect(cuts > 0);
    try std.testing.expectEqual(guest_revision, owner.guest_revision);
    try std.testing.expectError(error.InvalidState, capsule.publish(a, &owner, .outer_execution, .{
        .execution = @splat(31),
        .custody = @splat(41),
        .publication = null,
    }));
}

fn advanceRecovery(selected: *artifact.Admitted, prepared: *base.Prepared) !void {
    var owner = try driver.Driver.start(a, prepared, selected, .{
        .arguments = &std.mem.toBytes(@as(u64, 1)),
    });
    defer owner.deinit();
    var initialized = try owner.pump(null);
    initialized.deinit();
    try owner.submit(.{ .advance = .{ .control = .none, .quantum = 1 } });
    var cuts: usize = 0;
    for (0..std.math.maxInt(usize)) |_| {
        var result = try owner.pump(1);
        defer result.deinit();
        if (result == .event) {
            try std.testing.expect(result.event.value == .cut);
            try std.testing.expectEqual(@as(u64, 1), result.event.value.cut.guest_work);
            break;
        }
        try std.testing.expect(result == .suspended);
        try std.testing.expectError(error.GuestCutUnavailable, owner.checkpoint(a));
        const inspected = try @import("realization.zig").inspect(
            a,
            &owner.outer,
            owner.selected,
            owner.guest.admitted(),
        );
        try std.testing.expect(inspected.committed != 0);
        cuts += 1;
    } else return error.PumpBoundExhausted;
    try std.testing.expect(cuts != 0);
    try std.testing.expectEqual(@as(u64, 1), owner.guest_revision);
    const checkpoint = try owner.checkpoint(a);
    defer a.free(checkpoint);
    var reference = try driver.Driver.start(a, prepared, selected, .{
        .arguments = &std.mem.toBytes(@as(u64, 1)),
    });
    defer reference.deinit();
    var first = try reference.pump(null);
    first.deinit();
    var advanced = try reference.exchange(.{ .advance = .{ .control = .none, .quantum = 1 } });
    advanced.deinit();
    const expected = try reference.checkpoint(a);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, checkpoint);
}

test "advance and finish retain recovery at every bounded cut" {
    var generic = try artifact.Admitted.init(
        a,
        @import("packaged_runtime").bytes,
        artifact.digest(@import("packaged_runtime").bytes),
    );
    defer generic.deinit();
    const image = try support.guestImage();
    defer a.free(image);
    var prepared = try base.Prepared.init(a, image);
    defer prepared.deinit();
    const guest = try prepared.acquire();
    defer guest.release();
    const bytes = try @import("compiler.zig").compile(a, .{
        .horos_package = generic.content.value.manifest.compiler.horos_package,
        .guest = guest.admitted(),
    });
    defer a.free(bytes);
    var specialized = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer specialized.deinit();
    for ([_]*artifact.Admitted{ &generic, &specialized }) |selected| {
        try advanceRecovery(selected, &prepared);
        try finishCapsules(selected, &prepared, 1, false, .completed);
        try finishCapsules(selected, &prepared, std.math.maxInt(u64), false, .failed);
        try finishCapsules(selected, &prepared, 1, true, .cancelled);
    }
}

test "outer capsule retains clone microprogress and requires exact consumed custody" {
    var selected = try artifact.Admitted.init(
        a,
        @import("packaged_runtime").bytes,
        artifact.digest(@import("packaged_runtime").bytes),
    );
    defer selected.deinit();
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try support.encode(try source.examples.cloned(&b));
    defer a.free(image);
    var prepared = try base.Prepared.init(a, image);
    defer prepared.deinit();
    var original = try driver.Driver.start(a, &prepared, &selected, .{ .arguments = &.{} });
    var original_live = true;
    defer if (original_live) original.deinit();
    var initialized = try original.pump(null);
    initialized.event.deinit();
    try seekCloneRebase(&original, &selected);
    try std.testing.expectError(error.GuestCutUnavailable, original.checkpoint(a));
    const provenance: capsule.Provenance = .{
        .execution = @splat(3),
        .custody = @splat(7),
        .publication = null,
    };
    const bytes = try capsule.publish(a, &original, .outer_execution, provenance);
    defer a.free(bytes);
    try inspectOuterView(&original, &selected, bytes);
    const before = try original.outer.checkpoint(a);
    defer a.free(before);
    var custody = try checkRejectedCustody(&prepared, &selected, bytes, provenance);
    // The publisher retires at its publication fence before destination use.
    original.deinit();
    original_live = false;
    var restored = try capsule.restore(a, &prepared, &selected, bytes, custody.verifier());
    defer restored.deinit();
    const after = try restored.outer.checkpoint(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectError(error.UnauthorizedCapsule, capsule.restore(
        a,
        &prepared,
        &selected,
        bytes,
        custody.verifier(),
    ));
    var completed = try restored.pump(null);
    try std.testing.expect(completed == .event and completed.event.value == .cut);
    completed.event.deinit();
    const checkpoint = try restored.checkpoint(a);
    defer a.free(checkpoint);
    var state = try data.state_image.decodeGraph(a, checkpoint);
    defer state.deinit();
    try data.state_admission.validateAdmitted(a, restored.guest.admitted(), state.state);
}

fn inspectOuterView(
    owner: *driver.Driver,
    selected: *artifact.Admitted,
    bytes: []const u8,
) !void {
    const before = try owner.outer.checkpoint(a);
    defer a.free(before);
    var view = try capsule.inspectOuter(
        a,
        owner.guest.admitted(),
        selected,
        bytes,
        .{},
        @splat(23),
    );
    defer view.deinit();
    try std.testing.expectEqual(.outer_execution, view.value.capsule.kind);
    try std.testing.expectEqual(.not_requested, view.value.state.value_coverage);
    try std.testing.expectEqual(null, view.value.state.snapshot);
    try std.testing.expectError(error.InvalidDisclosure, capsule.inspectOuter(
        a,
        owner.guest.admitted(),
        selected,
        bytes,
        .{ .snapshot = true },
        @splat(23),
    ));
    try std.testing.expectEqualDeep(
        owner.guest.admitted().identity(),
        view.value.capsule.guest.identity,
    );
    try std.testing.expectEqualDeep(
        selected.program.identity(),
        view.value.state.metadata.binding.guest,
    );
    const encoded = try capsule.encodeOuterView(a, view.value);
    defer a.free(encoded);
    const schema = try capsule.outerViewSchemaBytes(a);
    defer a.free(schema);
    var descriptor = try data.schema.decode(a, schema);
    defer descriptor.deinit();
    try data.schema.validateValue(a, descriptor.descriptor, encoded);
    const after = try owner.outer.checkpoint(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "resident capsule receipts bind level generation and exact outer progress" {
    const facade = @import("session.zig");
    var image: [52]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &image,
        "41424c5f4250493303000000200000000000000001000001020a000000010000" ++
            "0100010000020000070100000000000000000000",
    );
    var prepared = try facade.Prepared.init(a, &image);
    defer prepared.deinit();
    var owner = try facade.Resident.start(a, &prepared, &.{ 1, 42 });
    defer if (owner.live) {
        const bytes = owner.takeCheckpoint(a) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        a.free(bytes);
    };
    const provenance: capsule.Provenance = .{
        .execution = @splat(5),
        .custody = @splat(8),
        .publication = null,
    };
    var guest = try owner.publish(.{ .record = a }, .none, .{
        .quantum = 0,
        .checkpoint = .receipt,
    });
    defer guest.deinit();
    const guest_capsule = try owner.publishCapsule(a, .guest_cut, provenance);
    defer guest_capsule.deinit();
    try owner.beginAdvance(.none, 100);
    try std.testing.expectError(error.InvalidState, owner.transferCheckpoint(guest.checkpoint.?));
    try std.testing.expectError(
        error.InvalidState,
        owner.transferCapsule(guest_capsule, .guest_cut),
    );
    try std.testing.expect(try owner.pump(1) == .suspended);
    try std.testing.expectError(
        error.GuestCutUnavailable,
        owner.publishCapsule(a, .guest_cut, provenance),
    );
    const before = try owner.publishCapsule(a, .outer_execution, provenance);
    defer before.deinit();
    var failure = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, owner.publishCapsule(
        failure.allocator(),
        .outer_execution,
        provenance,
    ));
    const unchanged = try owner.publishCapsule(a, .outer_execution, provenance);
    defer unchanged.deinit();
    try std.testing.expectEqualSlices(u8, before.bytes(), unchanged.bytes());
    try std.testing.expectError(error.InvalidState, owner.transferCapsule(unchanged, .guest_cut));
    try std.testing.expect(try owner.pump(1) == .suspended);
    try std.testing.expectError(
        error.InvalidState,
        owner.transferCapsule(unchanged, .outer_execution),
    );
    const current = try owner.publishCapsule(a, .outer_execution, provenance);
    defer current.deinit();
    try owner.transferCapsule(current, .outer_execution);
    try std.testing.expectError(
        error.InvalidState,
        owner.transferCapsule(current, .outer_execution),
    );
    try checkTransferredReceipt(&prepared, current.bytes(), provenance);
}

test "public resident resumes every admitted outer operation and owns its output" {
    const facade = @import("session.zig");
    var b = source.Builder.init(a);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const entry = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(entry, try b.pure(try b.constant(u64, 42)));
    const image = try support.encode(b.module(entry, try b.scalar(void)));
    defer a.free(image);
    var prepared = try facade.Prepared.init(a, image);
    defer prepared.deinit();
    const provenance: capsule.Provenance = .{
        .execution = @splat(11),
        .custody = @splat(12),
        .publication = null,
    };
    // This switch is exhaustive over the actual restorable operation domain.
    inline for (std.meta.tags(driver.Operation)) |operation| {
        try checkOperationCapsule(&prepared, provenance, operation);
    }
}

fn seekCloneRebase(original: *driver.Driver, selected: *artifact.Admitted) !void {
    var found = false;
    for (0..400) |_| {
        const control: @import("service.zig").Control =
            if (original.last_cut.?.status == .yielded) .resume_yield else .none;
        try original.submit(.{ .advance = .{ .control = control, .quantum = 1 } });
        for (0..std.math.maxInt(usize)) |_| {
            var step = try original.pump(16);
            if (step == .event) {
                step.event.deinit();
                break;
            }
            try std.testing.expect(step == .suspended);
            const current = original.outer.roots.current orelse continue;
            const frame = try original.outer.frames.get(current.id);
            var rebase = false;
            for (selected.content.value.recovery.anchors) |anchor| {
                if (anchor.role == .clone_rebase and anchor.function == frame.function)
                    rebase = true;
            }
            if (!rebase) continue;
            const inspection = try @import("realization.zig").inspect(
                a,
                &original.outer,
                original.selected,
                original.guest.admitted(),
            );
            if (inspection.clone_rebases == 0) continue;
            found = true;
            break;
        } else return error.PumpBoundExhausted;
        if (found) break;
        if (original.last_cut.?.status == .completed) return error.MissingClonePhase;
    }
    try std.testing.expect(found);
}

fn checkRejectedCustody(
    prepared: *base.Prepared,
    selected: *artifact.Admitted,
    bytes: []const u8,
    provenance: capsule.Provenance,
) !Custody {
    var rejected: Custody = .{ .expected = capsule.reference(bytes), .execution = @splat(4) };
    try std.testing.expectError(error.UnauthorizedCapsule, capsule.restore(
        a,
        prepared,
        selected,
        bytes,
        rejected.verifier(),
    ));
    try std.testing.expect(!rejected.consumed);
    var edited = try projection.decode(capsule.Envelope, a, bytes);
    defer edited.deinit();
    edited.value.record.outer_revision += 1;
    const changed = try projection.encode(capsule.Envelope, a, edited.value);
    defer a.free(changed);
    var custody: Custody = .{
        .expected = capsule.reference(bytes),
        .execution = provenance.execution,
    };
    try std.testing.expectError(error.UnauthorizedCapsule, capsule.restore(
        a,
        prepared,
        selected,
        changed,
        custody.verifier(),
    ));
    try std.testing.expect(!custody.consumed);
    return custody;
}

fn checkTransferredReceipt(
    prepared: *@import("session.zig").Prepared,
    bytes: []const u8,
    provenance: capsule.Provenance,
) !void {
    const facade = @import("session.zig");
    var custody: Custody = .{
        .expected = capsule.reference(bytes),
        .execution = provenance.execution,
    };
    var restored = try facade.Resident.restoreCapsule(
        a,
        prepared,
        bytes,
        custody.verifier(),
    );
    defer if (restored.live) {
        const saved = restored.takeCheckpoint(a) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        a.free(saved);
    };
    try std.testing.expectError(error.UnauthorizedCapsule, facade.Resident.restoreCapsule(
        a,
        prepared,
        bytes,
        custody.verifier(),
    ));
    for (0..std.math.maxInt(usize)) |_| {
        var progress = try restored.pump(64);
        defer progress.deinit();
        if (progress != .suspended) break;
    } else return error.PumpBoundExhausted;
    var result = try restored.drive(a, .resume_yield, .{});
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 42 }, result.record.completed);
    try restored.close();
}

fn checkOperationCapsule(
    prepared: *@import("session.zig").Prepared,
    provenance: capsule.Provenance,
    operation: driver.Operation,
) !void {
    var original = try driver.Driver.start(
        a,
        &prepared.guest,
        &prepared.runtime,
        .{ .arguments = &.{} },
    );
    var original_live = true;
    defer if (original_live) original.deinit();
    if (operation != .initialize) {
        var initialized = try original.pump(null);
        defer initialized.deinit();
        if (operation == .finish) {
            var terminal = try original.exchange(.{
                .advance = .{ .control = .none, .quantum = 100 },
            });
            defer terminal.deinit();
            try std.testing.expectEqual(.completed, terminal.value.cut.status);
        }
        try original.submit(switch (operation) {
            .initialize => unreachable,
            .advance => .{ .advance = .{ .control = .none, .quantum = 1 } },
            .observe => .observe,
            .project => .project,
            .finish => .finish,
        });
    }
    var partial = try original.pump(1);
    defer partial.deinit();
    try std.testing.expect(partial == .suspended);
    const bytes = try capsule.publish(a, &original, .outer_execution, provenance);
    defer a.free(bytes);
    var envelope = try capsule.read(a, bytes);
    defer envelope.deinit();
    try std.testing.expectEqual(operation == .initialize, envelope.value.initial.len != 0);
    const guest_revision = original.guest_revision;
    var expected = try original.pump(null);
    defer expected.deinit();
    try std.testing.expectEqual(@as(usize, 0), original.initial.len);
    const final_revision = original.guest_revision;
    original.deinit();
    original_live = false;
    if (operation == .initialize)
        try checkInitialSession(prepared, bytes, provenance, expected);
    try checkRestoredOperation(
        prepared,
        bytes,
        provenance,
        operation,
        expected,
        guest_revision,
        final_revision,
    );
}

fn checkInitialSession(
    prepared: *@import("session.zig").Prepared,
    bytes: []const u8,
    provenance: capsule.Provenance,
    expected: driver.Pump,
) !void {
    const facade = @import("session.zig");
    var session_custody: Custody = .{
        .expected = capsule.reference(bytes),
        .execution = provenance.execution,
    };
    var session = facade.Session.fromDriver(try capsule.restore(
        a,
        &prepared.guest,
        &prepared.runtime,
        bytes,
        session_custody.verifier(),
    ));
    defer session.deinit();
    try std.testing.expect(session.driver.last_cut == null);
    try std.testing.expectError(
        error.OperationInProgress,
        session.submitAdvance(.resume_yield, 1, null),
    );
    try std.testing.expectError(
        error.OperationInProgress,
        session.submitAdvance(.none, 1, null),
    );
    try std.testing.expectError(error.OperationInProgress, session.submitAdvance(
        .{ .cancel = .{ .text = "stop" } },
        1,
        null,
    ));
    try std.testing.expectError(
        error.OperationInProgress,
        session.submitAdvance(.{ .reply = &.{} }, 1, null),
    );
    for (0..std.math.maxInt(usize)) |_| {
        var progress = try session.pump(64);
        defer progress.deinit();
        if (progress == .suspended) continue;
        try std.testing.expectEqualDeep(expected.event.value, progress.event.value);
        break;
    } else return error.PumpBoundExhausted;
    try std.testing.expectError(
        error.InvalidState,
        session.submitAdvance(.resume_yield, 1, null),
    );
    try std.testing.expect(try session.run(null) == .completed);
}

fn checkRestoredOperation(
    prepared: *@import("session.zig").Prepared,
    bytes: []const u8,
    provenance: capsule.Provenance,
    operation: driver.Operation,
    expected: driver.Pump,
    guest_revision: u64,
    final_revision: u64,
) !void {
    const facade = @import("session.zig");
    var custody: Custody = .{
        .expected = capsule.reference(bytes),
        .execution = provenance.execution,
    };
    var failing = std.testing.FailingAllocator.init(a, .{});
    var restored = try facade.Resident.restoreCapsule(
        failing.allocator(),
        prepared,
        bytes,
        custody.verifier(),
    );
    defer if (restored.live) {
        if (operation == .finish) {
            restored.close() catch |err| std.debug.panic("{s}", .{@errorName(err)});
        } else {
            const saved = restored.takeCheckpoint(a) catch |err|
                std.debug.panic("{s}", .{@errorName(err)});
            a.free(saved);
        }
    };
    try std.testing.expectError(error.UnauthorizedCapsule, facade.Resident.restoreCapsule(
        a,
        prepared,
        bytes,
        custody.verifier(),
    ));
    const before = try restored.runtimeBinding();
    try std.testing.expectEqual(guest_revision, before.guest_revision);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, restored.pump(1));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqualDeep(before, try restored.runtimeBinding());
    try checkRestoredOutput(&restored, expected);
    try std.testing.expectEqual(final_revision, (try restored.runtimeBinding()).guest_revision);
    if (operation != .advance) try std.testing.expectEqual(guest_revision, final_revision);
    if (operation == .finish) {
        var closed = try restored.pump(1);
        defer closed.deinit();
        try std.testing.expect(closed == .closed);
        try restored.close();
    } else {
        try std.testing.expectError(error.NoOperation, restored.pump(1));
    }
}

fn checkRestoredOutput(restored: *@import("session.zig").Resident, expected: driver.Pump) !void {
    const service = @import("service.zig");
    for (0..std.math.maxInt(usize)) |_| {
        var actual = try restored.pump(64);
        defer actual.deinit();
        if (actual == .suspended) continue;
        try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
        if (actual == .event) {
            const expected_bytes = try projection.encode(
                service.Event,
                a,
                expected.event.value,
            );
            defer a.free(expected_bytes);
            const actual_bytes = try projection.encode(service.Event, a, actual.event.value);
            defer a.free(actual_bytes);
            try std.testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
        }
        break;
    } else return error.PumpBoundExhausted;
}
