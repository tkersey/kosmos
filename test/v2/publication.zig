//! Native publication bytes, failure atomicity, and issuer/generation custody.
const std = @import("std");
const horos = @import("horos");
const kosmos = @import("kosmos");
const data = horos.data;
const a = std.testing.allocator;
const argument = [_]u8{ 42, 0, 0, 0, 0, 0, 0, 0 };

fn image(external: bool) ![]u8 {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const effect = try b.effect(.{ .identity = "publication/test", .payload = unit, .result = unit });
    const entry = try b.declare(&.{integer}, integer, if (external) &.{effect} else &.{}, &.{});
    const returned = try b.pure(try b.reference(b.parameter(entry, 0)));
    const body = if (external)
        try b.bind(try b.variable(unit), try b.term(.{ .perform = .{ .effect = effect, .payload = try b.constant(void, {}) } }), returned)
    else
        try b.term(.{ .yield_then = returned });
    try b.define(entry, body);
    var compiled = try horos.program.compile(a, b.module(entry, unit));
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    return bytes;
}

fn release(resident: *kosmos.Resident) void {
    if (!resident.live) return;
    resident.close() catch {
        const bytes = resident.takeCheckpoint(a) catch unreachable;
        a.free(bytes);
    };
}

test "one receipt publication binds exact pending bytes and transfer performs no projection" {
    const program = try image(true);
    defer a.free(program);
    var prepared = try kosmos.Prepared.init(a, program);
    defer prepared.deinit();
    var resident = try kosmos.Resident.start(a, &prepared, &argument);
    defer release(&resident);
    var statistics: kosmos.Statistics = .{};
    try resident.setStatistics(&statistics);
    var publication = try resident.publish(.{ .encoded = a }, .none, .{ .checkpoint = .receipt });
    defer publication.deinit();
    try std.testing.expectEqual(1, statistics.state_projections);
    try std.testing.expectEqual(1, statistics.pending_bindings);
    var outcome = try data.invocation.decode(data.invocation.Outcome, a, publication.outcome.encoded);
    defer outcome.deinit();
    try std.testing.expect(outcome.value.requested.state == null);
    var request = try data.invocation.decode(data.invocation.Request, a, outcome.value.requested.request);
    defer request.deinit();
    const receipt = publication.takeCheckpoint().?;
    defer receipt.deinit();
    const digest = data.invocation.stateDigest(receipt.bytes());
    try std.testing.expectEqualSlices(u8, &digest, &request.value.binding.pending_state_digest);
    try std.testing.expectEqualSlices(u8, &digest, &receipt.pendingStateDigest().?);
    const ordinary = try resident.checkpoint(a);
    defer a.free(ordinary);
    try std.testing.expectEqualSlices(u8, ordinary, receipt.bytes());
    const before = statistics.state_projections;
    try resident.transferCheckpoint(receipt);
    try std.testing.expectEqual(before, statistics.state_projections);
    try std.testing.expectError(error.InvalidState, resident.transferCheckpoint(receipt));
    var restored = try kosmos.Resident.restore(a, &prepared, receipt.bytes());
    defer release(&restored);
    const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = request.value.request_identity, .value = &.{} });
    defer a.free(reply);
    var terminal = try restored.publish(.{ .record = a }, .{ .reply = reply }, .{ .checkpoint = .receipt });
    defer terminal.deinit();
    try std.testing.expectEqualSlices(u8, &argument, terminal.outcome.record.record.completed);
    const terminal_bytes = try restored.checkpoint(a);
    defer a.free(terminal_bytes);
    try std.testing.expectEqualSlices(u8, terminal_bytes, terminal.checkpoint.?.bytes());
    try restored.close();
}

test "equal content cannot transfer a foreign stale consumed or prior-incarnation receipt" {
    const program = try image(false);
    defer a.free(program);
    var prepared = try kosmos.Prepared.init(a, program);
    defer prepared.deinit();
    var resident = try kosmos.Resident.start(a, &prepared, &argument);
    defer release(&resident);
    var first = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer first.deinit();
    var other = try kosmos.Resident.restore(a, &prepared, first.checkpoint.?.bytes());
    defer release(&other);
    var foreign = try other.publish(.{ .record = a }, .none, .{ .quantum = 0, .checkpoint = .receipt });
    defer foreign.deinit();
    try std.testing.expectEqualSlices(u8, first.checkpoint.?.bytes(), foreign.checkpoint.?.bytes());
    try std.testing.expectError(error.InvalidState, resident.transferCheckpoint(foreign.checkpoint.?));
    var later = try resident.publish(.{ .record = a }, .none, .{ .quantum = 0, .checkpoint = .receipt });
    defer later.deinit();
    try std.testing.expectEqualSlices(u8, first.checkpoint.?.bytes(), later.checkpoint.?.bytes());
    try std.testing.expectError(error.InvalidState, resident.transferCheckpoint(first.checkpoint.?));
    const fallback = try resident.takeCheckpoint(a);
    defer a.free(fallback);
    // Reuse the exact native handle address while old receipts retain its cell.
    resident = try kosmos.Resident.restore(a, &prepared, fallback);
    try std.testing.expectError(error.InvalidState, resident.transferCheckpoint(later.checkpoint.?));
    var fresh = try resident.publish(.{ .record = a }, .none, .{ .quantum = 0, .checkpoint = .receipt });
    defer fresh.deinit();
    try resident.transferCheckpoint(fresh.checkpoint.?);
    resident = try kosmos.Resident.restore(a, &prepared, fresh.checkpoint.?.bytes());
    try std.testing.expectError(error.InvalidState, resident.transferCheckpoint(fresh.checkpoint.?));
}

test "buffer failure after receipt construction preserves state and prior receipt" {
    const program = try image(false);
    defer a.free(program);
    var prepared = try kosmos.Prepared.init(a, program);
    defer prepared.deinit();
    var resident = try kosmos.Resident.start(a, &prepared, &argument);
    defer release(&resident);
    var before = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer before.deinit();
    var buffer: [1]u8 = undefined;
    try std.testing.expectError(error.Capacity, resident.publish(.{ .buffer = &buffer }, .resume_yield, .{ .checkpoint = .receipt }));
    const unchanged = try resident.checkpoint(a);
    defer a.free(unchanged);
    try std.testing.expectEqualSlices(u8, before.checkpoint.?.bytes(), unchanged);
    try resident.transferCheckpoint(before.checkpoint.?);
    var restored = try kosmos.Resident.restore(a, &prepared, before.checkpoint.?.bytes());
    defer release(&restored);
    var retry = try restored.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
    defer retry.deinit();
    try std.testing.expectEqualSlices(u8, &argument, retry.outcome.record.record.completed);
}

test "polling yielded state without a checkpoint performs no projection" {
    const program = try image(false);
    defer a.free(program);
    var prepared = try kosmos.Prepared.init(a, program);
    defer prepared.deinit();
    var resident = try kosmos.Resident.start(a, &prepared, &argument);
    defer release(&resident);
    var statistics: kosmos.Statistics = .{};
    try resident.setStatistics(&statistics);
    var yielded = try resident.drive(a, .none, .{});
    defer yielded.deinit();
    try std.testing.expect(yielded.record == .yielded);
    try std.testing.expectEqual(0, statistics.state_projections);
    var poll = try resident.drive(a, .none, .{ .quantum = 0 });
    defer poll.deinit();
    try std.testing.expectEqual(0, statistics.state_projections);
}

test "moved receipt outlives a temporary publication output allocator" {
    const program = try image(false);
    defer a.free(program);
    var prepared = try kosmos.Prepared.init(a, program);
    defer prepared.deinit();
    var resident = try kosmos.Resident.start(a, &prepared, &argument);
    defer release(&resident);
    const receipt = blk: {
        var temporary = std.heap.ArenaAllocator.init(a);
        defer temporary.deinit();
        var publication = try resident.publish(.{ .encoded = temporary.allocator() }, .none, .{ .checkpoint = .receipt });
        defer publication.deinit();
        break :blk publication.takeCheckpoint().?;
    };
    defer receipt.deinit();
    try resident.transferCheckpoint(receipt);
    var restored = try kosmos.Resident.restore(a, &prepared, receipt.bytes());
    defer release(&restored);
    var result = try restored.drive(a, .resume_yield, .{});
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, &argument, result.record.completed);
}

test "receipt publication allocation failure rolls back and allows exact retry" {
    const program = try image(false);
    defer a.free(program);
    var prepared = try kosmos.Prepared.init(a, program);
    defer prepared.deinit();
    var failures: usize = 0;
    while (true) : (failures += 1) {
        var failing = std.testing.FailingAllocator.init(a, .{});
        var resident = try kosmos.Resident.start(failing.allocator(), &prepared, &argument);
        defer release(&resident);
        var before = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
        defer before.deinit();
        failing.fail_index = failing.alloc_index + failures;
        failing.resize_fail_index = failing.resize_index;
        var publication = resident.publish(.{ .encoded = failing.allocator() }, .resume_yield, .{ .checkpoint = .receipt }) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(error.OutOfMemory, err);
            const unchanged = try resident.checkpoint(a);
            defer a.free(unchanged);
            try std.testing.expectEqualSlices(u8, before.checkpoint.?.bytes(), unchanged);
            var retry = try resident.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
            defer retry.deinit();
            try std.testing.expectEqualSlices(u8, &argument, retry.outcome.record.record.completed);
            try resident.transferCheckpoint(retry.checkpoint.?);
            continue;
        };
        defer publication.deinit();
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try std.testing.expect(failures > 0);
        try resident.transferCheckpoint(publication.checkpoint.?);
        break;
    }
}
