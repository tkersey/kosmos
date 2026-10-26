//! Public production runtime retains exact reply contracts under exclusive ownership.
const runtime = @import("kosmos");
// Independent response rejection and lifecycle checks for Resident-owned facts.
const std = @import("std");
const horos = @import("horos");
const data = horos.data;
const protocol = data.invocation;
const a = std.testing.allocator;
const expect = std.testing.expect;
const eq = std.testing.expectEqual;
const bytesEq = std.testing.expectEqualSlices;
const Statistics = std.meta.Child(std.meta.Child(@FieldType(runtime.Session, "statistics")));
const ExpectedReply = @typeInfo(@TypeOf(runtime.Session.answerExpected)).@"fn".param_types[2].?;

fn makeImage(cleanup: bool) ![]u8 {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const module = if (cleanup) try horos.source.examples.unwind(&b) else blk: {
        const integer = try b.scalar(u64);
        const unit = try b.scalar(void);
        const effect = try b.effect(.{
            .identity = "binding/retained",
            .payload = unit,
            .result = unit,
        });
        const entry = try b.declare(&.{integer}, integer, &.{effect}, &.{});
        const operation = try b.term(.{ .perform = .{
            .effect = effect,
            .payload = try b.constant(void, {}),
        } });
        try b.define(entry, try b.bind(try b.variable(unit), operation, try b.pure(
            try b.reference(b.parameter(entry, 0)),
        )));
        break :blk b.module(entry, unit);
    };
    var compiled = try horos.program.compile(a, module);
    defer compiled.deinit();
    const result = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(result);
    _ = try compiled.encode(a, result);
    return result;
}
fn finish(resident: *runtime.Resident) void {
    resident.close() catch |err| switch (err) {
        error.InvalidState => {},
        error.UnfinishedSession => {
            const state = resident.takeCheckpoint(a) catch |checkpoint_error|
                std.debug.panic("{s}", .{@errorName(checkpoint_error)});
            a.free(state);
        },
        else => unreachable,
    };
}
fn encodeReply(request: []const u8, value: []const u8) ![]u8 {
    var decoded = try protocol.decode(protocol.Request, a, request);
    defer decoded.deinit();
    return protocol.encodeOwned(protocol.Result, a, .{
        .request_identity = decoded.value.request_identity,
        .value = value,
    });
}

test "runtime observation failures preserve restored terminal state and retry binding" {
    const image = try makeImage(false);
    defer a.free(image);
    var prepared = try runtime.Prepared.init(a, image);
    defer prepared.deinit();
    var owner = try runtime.Resident.start(a, &prepared, &std.mem.toBytes(@as(u64, 42)));
    defer finish(&owner);
    const active = try owner.checkpoint(a);
    defer a.free(active);
    try checkActiveObservation(&prepared, active);
    var requested = try owner.drive(a, .none, .{});
    defer requested.deinit();
    const reply = try encodeReply(requested.record.requested.request, &.{});
    defer a.free(reply);
    var completed = try owner.drive(a, .{ .reply = reply }, .{});
    defer completed.deinit();
    const checkpoint = try owner.checkpoint(a);
    defer a.free(checkpoint);
    var measuring = std.testing.FailingAllocator.init(a, .{});
    var reference = try runtime.Resident.restore(measuring.allocator(), &prepared, checkpoint);
    defer finish(&reference);
    const start = measuring.alloc_index;
    var expected = try reference.runtimeObservation(a);
    defer expected.deinit();
    const allocations = measuring.alloc_index - start;
    try expect(allocations > 2);
    var cached = try reference.runtimeObservation(a);
    defer cached.deinit();
    try std.testing.expectEqualDeep(expected.binding, cached.binding);
    try bytesEq(u8, expected.observation, cached.observation);
    for ([_]usize{ 0, allocations / 2, allocations - 1 }) |offset| {
        try checkObservationRetry(&prepared, checkpoint, expected.observation, offset);
    }
}

fn checkActiveObservation(prepared: *runtime.Prepared, checkpoint: []const u8) !void {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var owner = try runtime.Resident.restore(failing.allocator(), prepared, checkpoint);
    defer finish(&owner);
    const before = try owner.runtimeBinding();
    failing.fail_index = failing.alloc_index;
    defer failing.fail_index = std.math.maxInt(usize);
    var observed = try owner.runtimeObservation(a);
    defer observed.deinit();
    try std.testing.expectEqualDeep(before, observed.binding);
    try std.testing.expectEqualDeep(before, try owner.runtimeBinding());
}

fn checkObservationRetry(
    prepared: *runtime.Prepared,
    checkpoint: []const u8,
    expected: []const u8,
    offset: usize,
) !void {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var owner = try runtime.Resident.restore(failing.allocator(), prepared, checkpoint);
    defer finish(&owner);
    const before = try owner.runtimeBinding();
    const rollbacks = (try owner.diagnostics()).transactions.rollback_entries;
    failing.fail_index = failing.alloc_index + offset;
    try std.testing.expectError(error.OutOfMemory, owner.runtimeObservation(a));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqualDeep(before, try owner.runtimeBinding());
    if (offset != 0) {
        try expect((try owner.diagnostics()).transactions.rollback_entries > rollbacks);
    }
    var empty: [0]u8 = .{};
    var output = std.heap.FixedBufferAllocator.init(&empty);
    try std.testing.expectError(error.OutOfMemory, owner.runtimeObservation(output.allocator()));
    try std.testing.expectEqualDeep(before, try owner.runtimeBinding());
    const unchanged = try owner.checkpoint(a);
    defer a.free(unchanged);
    try bytesEq(u8, checkpoint, unchanged);
    var retry = try owner.runtimeObservation(a);
    defer retry.deinit();
    try bytesEq(u8, expected, retry.observation);
    try eq(before.guest_revision, retry.binding.guest_revision);
    try eq(before.generation, retry.binding.generation);
    try eq(before.outer_revision + 2, retry.binding.outer_revision);
    try std.testing.expectError(error.OutOfMemory, owner.runtimeObservation(output.allocator()));
    try std.testing.expectEqualDeep(retry.binding, try owner.runtimeBinding());
    var cached = try owner.runtimeObservation(a);
    defer cached.deinit();
    try bytesEq(u8, expected, cached.observation);
    try std.testing.expectEqualDeep(retry.binding, cached.binding);
}

fn rejected(session: *runtime.Session, reply: []const u8) anyerror {
    session.answer(reply) catch |err| return err;
    return error.UnexpectedSuccess;
}

test "public expected replies remain bound to the request through advance restore and rollback" {
    const image = try sequentialImage();
    defer a.free(image);
    var prepared = try runtime.Prepared.init(a, image);
    defer prepared.deinit();
    var session = try runtime.Session.start(a, &prepared, &.{});
    defer session.deinit();
    try expect(try session.run(null) == .requested);
    var first = try session.pendingBinding(a, false);
    defer first.deinit();
    const binding_a: ExpectedReply = .{
        .identity = first.request.request_identity,
        .effect = first.request.binding.effect,
    };
    const reply_a = try protocol.encodeOwned(protocol.Result, a, .{
        .request_identity = first.request.request_identity,
        .value = &.{},
    });
    defer a.free(reply_a);
    var transaction = try session.begin();
    var transaction_live = true;
    defer if (transaction_live) transaction.rollback(&session);
    try session.answerExpected(reply_a, binding_a);
    try expect(try session.run(null) == .requested);
    var second = try session.pendingBinding(a, false);
    defer second.deinit();
    const binding_b: ExpectedReply = .{
        .identity = second.request.request_identity,
        .effect = second.request.binding.effect,
    };
    const reply_b = try protocol.encodeOwned(protocol.Result, a, .{
        .request_identity = second.request.request_identity,
        .value = &.{},
    });
    defer a.free(reply_b);
    try expect(!std.mem.eql(u8, &binding_a.identity, &binding_b.identity));
    transaction.rollback(&session);
    transaction_live = false;
    try std.testing.expectError(error.InvalidResult, session.answerExpected(reply_b, binding_b));
    try session.answerExpected(reply_a, binding_a);
    try expect(try session.run(null) == .requested);
    try std.testing.expectError(error.InvalidResult, session.answerExpected(reply_a, binding_a));
    try std.testing.expectError(error.InvalidResult, session.submitAdvance(
        .{ .reply = reply_a },
        0,
        binding_a,
    ));
    try std.testing.expectError(error.InvalidResult, session.answer(reply_a));
    var wrong_effect = binding_b;
    wrong_effect.effect += 1;
    try std.testing.expectError(error.InvalidResult, session.answerExpected(reply_b, wrong_effect));
    const state = try session.checkpoint(a);
    defer a.free(state);
    var restored = try runtime.Session.restore(a, &prepared, state);
    defer restored.deinit();
    try std.testing.expectError(error.InvalidResult, restored.answerExpected(reply_a, binding_a));
    try restored.answerExpected(reply_b, binding_b);
    try expect(try restored.run(null) == .completed);
    try session.submitAdvance(.{ .reply = reply_b }, 100, binding_b);
    for (0..std.math.maxInt(usize)) |_| {
        var progress = try session.pump(64);
        defer progress.deinit();
        if (progress == .suspended) continue;
        try expect(progress == .event and progress.event.value.cut.status == .completed);
        break;
    } else return error.PumpBoundExhausted;
}

test "resident reuses exact binding across independent invalid replies inspection and restore" {
    const program = try makeImage(false);
    defer a.free(program);
    var prepared = try runtime.Prepared.init(a, program);
    defer prepared.deinit();
    var resident = try runtime.Resident.start(a, &prepared, &.{ 42, 0, 0, 0, 0, 0, 0, 0 });
    defer finish(&resident);
    var stats: Statistics = .{};
    try resident.setStatistics(&stats);
    var first = try resident.drive(a, .none, .{ .checkpoint = true });
    defer first.deinit();
    try eq(1, stats.pending_bindings);
    try eq(1, stats.state_projections);
    const state = first.record.requested.state.?;
    const valid = try encodeReply(first.record.requested.request, &.{});
    defer a.free(valid);
    const ill_typed = try encodeReply(first.record.requested.request, &.{1});
    defer a.free(ill_typed);
    var decoded = try protocol.decode(protocol.Request, a, first.record.requested.request);
    defer decoded.deinit();
    var wrong_image = decoded.value.binding;
    wrong_image.program_identity[0] ^= 1;
    const unrelated = try protocol.request(wrong_image);
    const wrongly_bound = try protocol.encodeOwned(protocol.Result, a, .{
        .request_identity = unrelated.request_identity,
        .value = &.{},
    });
    defer a.free(wrongly_bound);
    var reference = try runtime.Session.restore(a, &prepared, state);
    defer reference.deinit();
    stats = .{};
    for ([_][]const u8{ &.{0}, wrongly_bound, ill_typed }) |reply| {
        try std.testing.expectError(
            rejected(&reference, reply),
            resident.drive(a, .{ .reply = reply }, .{}),
        );
        _ = try resident.diagnostics();
    }
    try eq(0, stats.pending_bindings);
    try eq(0, stats.state_projections);
    try eq(2, stats.expected_binding_checks);
    try eq(3, stats.reused_expected_bindings);
    const checkpoint = try resident.checkpoint(a);
    defer a.free(checkpoint);
    try bytesEq(u8, state, checkpoint);
    const projections = stats.state_projections;
    var completed = try resident.drive(a, .{ .reply = valid }, .{});
    defer completed.deinit();
    try eq(projections, stats.state_projections);
    try bytesEq(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, completed.record.completed);

    try checkRestoredBinding(&prepared, state, wrongly_bound, valid, completed.record.completed);
}

test "every resident output route restores the cached binding after late publication failure" {
    const program = try makeImage(false);
    defer a.free(program);
    var prepared = try runtime.Prepared.init(a, program);
    defer prepared.deinit();
    for (0..3) |route| {
        var resident = try runtime.Resident.start(a, &prepared, &.{ 42, 0, 0, 0, 0, 0, 0, 0 });
        defer finish(&resident);
        var stats: Statistics = .{};
        try resident.setStatistics(&stats);
        var first = try resident.drive(a, .none, .{ .checkpoint = true });
        defer first.deinit();
        const reply = try encodeReply(first.record.requested.request, &.{});
        defer a.free(reply);
        var empty: [0]u8 = .{};
        var output = std.heap.FixedBufferAllocator.init(&empty);
        stats = .{};
        switch (route) {
            0 => try std.testing.expectError(error.OutOfMemory, resident.drive(
                output.allocator(),
                .{ .reply = reply },
                .{},
            )),
            1 => try std.testing.expectError(error.OutOfMemory, resident.driveEncoded(
                output.allocator(),
                .{ .reply = reply },
                .{},
            )),
            2 => try std.testing.expectError(
                error.Capacity,
                resident.driveInto(.{ .reply = reply }, .{}, &empty),
            ),
            else => unreachable,
        }
        try expect(stats.transitions != 0);
        try eq(0, stats.state_projections);
        const unchanged = try resident.checkpoint(a);
        defer a.free(unchanged);
        try bytesEq(u8, first.record.requested.state.?, unchanged);
        stats = .{};
        var retry = try resident.drive(a, .{ .reply = reply }, .{});
        defer retry.deinit();
        try bytesEq(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, retry.record.completed);
        try eq(1, stats.reused_expected_bindings);
        try eq(0, stats.state_projections);
    }
}

test "resident cancellation replaces a cleanup binding and rejects its actual predecessor" {
    const program = try makeImage(true);
    defer a.free(program);
    var prepared = try runtime.Prepared.init(a, program);
    defer prepared.deinit();
    var resident = try runtime.Resident.start(a, &prepared, &.{0});
    defer finish(&resident);
    var first = try resident.drive(a, .none, .{ .checkpoint = true });
    defer first.deinit();
    const previous = try encodeReply(first.record.requested.request, &.{});
    defer a.free(previous);
    var reference = try runtime.Session.restore(a, &prepared, first.record.requested.state.?);
    defer reference.deinit();
    try reference.cancel(.{ .text = "stop" });
    var expected = try reference.pendingRequest(a);
    defer expected.deinit();
    var rebound = try resident.drive(a, .{ .cancel = .{ .text = "stop" } }, .{ .quantum = 0 });
    defer rebound.deinit();
    var request = try protocol.decode(protocol.Request, a, rebound.record.requested.request);
    defer request.deinit();
    try std.testing.expectEqualDeep(expected.request, request.value);
    try std.testing.expectError(error.InvalidResult, reference.answer(previous));
    var stats: Statistics = .{};
    try resident.setStatistics(&stats);
    try std.testing.expectError(
        error.InvalidResult,
        resident.drive(a, .{ .reply = previous }, .{}),
    );
    try eq(0, stats.state_projections);
    const reply = try encodeReply(rebound.record.requested.request, &.{});
    defer a.free(reply);
    var next = try resident.drive(a, .{ .reply = reply }, .{});
    defer next.deinit();
    const final_reply = try encodeReply(next.record.requested.request, &.{});
    defer a.free(final_reply);
    var done = try resident.drive(a, .{ .reply = final_reply }, .{});
    defer done.deinit();
    try expect(done.record == .failed);
    try std.testing.expectEqualStrings("stop", done.record.failed.cancellation.?.text);
}

test "bounded resident reply uses retained binding and consumes control once" {
    const image = try makeImage(false);
    defer a.free(image);
    var prepared = try runtime.Prepared.init(a, image);
    defer prepared.deinit();
    var owner = try runtime.Resident.start(a, &prepared, &.{ 42, 0, 0, 0, 0, 0, 0, 0 });
    defer if (owner.live) {
        const state = owner.takeCheckpoint(a) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        a.free(state);
    };
    var first = try owner.drive(a, .none, .{});
    defer first.deinit();
    const reply = try encodeReply(first.record.requested.request, &.{});
    defer a.free(reply);
    const invalid = try encodeReply(first.record.requested.request, &.{1});
    defer a.free(invalid);
    var stats: runtime.Statistics = .{};
    try owner.setStatistics(&stats);
    try std.testing.expectError(error.NonCanonical, owner.beginAdvance(.{ .reply = invalid }, 100));
    try std.testing.expectEqual(@as(u64, 0), stats.state_projections);
    try owner.beginAdvance(.{ .reply = reply }, 100);
    try std.testing.expectEqual(@as(u64, 0), stats.state_projections);
    try std.testing.expectEqual(@as(u64, 2), stats.reused_expected_bindings);
    for (0..std.math.maxInt(usize)) |_| {
        var progress = try owner.pump(64);
        defer progress.deinit();
        if (progress == .suspended) continue;
        try std.testing.expect(progress == .event and progress.event.value == .cut);
        break;
    } else return error.PumpBoundExhausted;
    try std.testing.expectError(error.NoOperation, owner.pump(64));
    var done = try owner.drive(a, .none, .{ .quantum = 0 });
    defer done.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, done.record.completed);
    try std.testing.expectEqual(@as(u64, 0), stats.state_projections);
    try owner.close();
}

fn sequentialImage() ![]u8 {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const effect = try b.effect(.{
        .identity = "binding/sequential",
        .payload = unit,
        .result = unit,
    });
    const entry = try b.declare(&.{}, unit, &.{effect}, &.{});
    const first_op = try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.constant(void, {}),
    } });
    const second_op = try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.constant(void, {}),
    } });
    try b.define(entry, try b.bind(try b.variable(unit), first_op, second_op));
    var compiled = try horos.program.compile(a, b.module(entry, unit));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(image);
    _ = try compiled.encode(a, image);
    return image;
}

fn checkRestoredBinding(
    prepared: *runtime.Prepared,
    state: []const u8,
    wrongly_bound: []const u8,
    valid: []const u8,
    completed: []const u8,
) !void {
    var restored = try runtime.Resident.restore(a, prepared, state);
    defer finish(&restored);
    var restored_stats: Statistics = .{};
    try restored.setStatistics(&restored_stats);
    try std.testing.expectError(error.InvalidResult, restored.drive(
        a,
        .{ .reply = wrongly_bound },
        .{},
    ));
    try eq(1, restored_stats.pending_bindings);
    try eq(1, restored_stats.state_projections);
    restored_stats = .{};
    try std.testing.expectError(error.InvalidResult, restored.drive(
        a,
        .{ .reply = wrongly_bound },
        .{},
    ));
    try eq(0, restored_stats.state_projections);
    var resumed = try restored.drive(a, .{ .reply = valid }, .{ .quantum = 0 });
    defer resumed.deinit();
    try expect(resumed.record == .progressed);
    var restored_done = try restored.drive(a, .none, .{});
    defer restored_done.deinit();
    try bytesEq(u8, completed, restored_done.record.completed);
}
