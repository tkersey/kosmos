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

fn makeImage(cleanup: bool) ![]u8 {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const module = if (cleanup) try horos.source.examples.unwind(&b) else blk: {
        const integer = try b.scalar(u64);
        const unit = try b.scalar(void);
        const effect = try b.effect(.{ .identity = "binding/retained", .payload = unit, .result = unit });
        const entry = try b.declare(&.{integer}, integer, &.{effect}, &.{});
        const operation = try b.term(.{ .perform = .{ .effect = effect, .payload = try b.constant(void, {}) } });
        try b.define(entry, try b.bind(try b.variable(unit), operation, try b.pure(try b.reference(b.parameter(entry, 0)))));
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
            const state = resident.takeCheckpoint(a) catch unreachable;
            a.free(state);
        },
        else => unreachable,
    };
}
fn encodeReply(request: []const u8, value: []const u8) ![]u8 {
    var decoded = try protocol.decode(protocol.Request, a, request);
    defer decoded.deinit();
    return protocol.encodeOwned(protocol.Result, a, .{ .request_identity = decoded.value.request_identity, .value = value });
}
fn rejected(session: *runtime.Session, reply: []const u8) anyerror {
    session.answer(reply) catch |err| return err;
    return error.UnexpectedSuccess;
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
    const wrongly_bound = try protocol.encodeOwned(protocol.Result, a, .{ .request_identity = unrelated.request_identity, .value = &.{} });
    defer a.free(wrongly_bound);
    var reference = try runtime.Session.restore(a, &prepared, state);
    defer reference.deinit();
    stats = .{};
    for ([_][]const u8{ &.{0}, wrongly_bound, ill_typed }) |reply| {
        try std.testing.expectError(rejected(&reference, reply), resident.drive(a, .{ .reply = reply }, .{}));
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

    var restored = try runtime.Resident.restore(a, &prepared, state);
    defer finish(&restored);
    var restored_stats: Statistics = .{};
    try restored.setStatistics(&restored_stats);
    try std.testing.expectError(error.InvalidResult, restored.drive(a, .{ .reply = wrongly_bound }, .{}));
    try eq(1, restored_stats.pending_bindings);
    try eq(1, restored_stats.state_projections);
    restored_stats = .{};
    try std.testing.expectError(error.InvalidResult, restored.drive(a, .{ .reply = wrongly_bound }, .{}));
    try eq(0, restored_stats.state_projections);
    var resumed = try restored.drive(a, .{ .reply = valid }, .{ .quantum = 0 });
    defer resumed.deinit();
    try expect(resumed.record == .progressed);
    var restored_done = try restored.drive(a, .none, .{});
    defer restored_done.deinit();
    try bytesEq(u8, completed.record.completed, restored_done.record.completed);
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
            0 => try std.testing.expectError(error.OutOfMemory, resident.drive(output.allocator(), .{ .reply = reply }, .{})),
            1 => try std.testing.expectError(error.OutOfMemory, resident.driveEncoded(output.allocator(), .{ .reply = reply }, .{})),
            2 => try std.testing.expectError(error.Capacity, resident.driveInto(.{ .reply = reply }, .{}, &empty)),
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
    try std.testing.expectError(error.InvalidResult, resident.drive(a, .{ .reply = previous }, .{}));
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
        const state = owner.takeCheckpoint(a) catch unreachable;
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
    while (true) {
        var progress = try owner.pump(64);
        defer progress.deinit();
        if (progress == .suspended) continue;
        try std.testing.expect(progress == .event and progress.event.value == .cut);
        break;
    }
    try std.testing.expectError(error.NoOperation, owner.pump(64));
    var done = try owner.drive(a, .none, .{ .quantum = 0 });
    defer done.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, done.record.completed);
    try std.testing.expectEqual(@as(u64, 0), stats.state_projections);
    try owner.close();
}
