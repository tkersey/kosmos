const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const analysis = @import("analysis.zig");
const projection = @import("projection.zig");
const base = @import("../base/session.zig");
const native = @import("native_baseline");
const support = @import("test_support.zig");
const Author = @import("author.zig").Author;
const a = std.testing.allocator;

fn integer(value: u64) [8]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return bytes;
}

fn requests(b: *source.Builder, repeated: bool) !source.Module {
    const e = try Author.init(b);
    const effect = try b.effect(.{
        .identity = "replay/test-request",
        .payload = e.integer,
        .result = e.integer,
    });
    const entry = try b.declare(&.{}, e.integer, &.{effect}, &.{});
    const first = try b.variable(e.integer);
    const second = try b.variable(e.integer);
    const sum = try e.binary(.integer_add, try b.reference(first), try b.reference(second));
    const last = try b.bind(second, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.constant(u64, if (repeated) 11 else 22),
    } }), try b.pure(sum));
    try b.define(entry, try b.bind(first, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.constant(u64, 11),
    } }), last));
    return b.module(entry, e.unit);
}

const matching = [_]analysis.ReplayExchange{
    .{ .expected_request = .{ .effect = 0, .payload = &integer(11) }, .response = &integer(5) },
    .{ .expected_request = .{ .effect = 0, .payload = &integer(22) }, .response = &integer(7) },
};

const Replay = struct {
    prepared: base.Prepared,
    binding: analysis.ReplayBinding,

    fn init(
        guest: *const data.program_image.Admitted,
        start: analysis.ReplayStart,
        capture: analysis.ReplayCapture,
    ) !Replay {
        var builder = source.Builder.init(a);
        defer builder.deinit();
        const replay = try analysis.replay(&builder, guest, start, capture);
        var compiled = try source.lower(a, replay.module);
        defer compiled.deinit();
        try std.testing.expectEqual(@as(usize, 0), compiled.program.effects.len);
        const image = try support.encodeCompiled(&compiled);
        defer a.free(image);
        return .{ .prepared = try base.Prepared.init(a, image), .binding = replay.binding };
    }

    fn deinit(self: *Replay) void {
        self.prepared.deinit();
    }

    fn input(
        self: *const Replay,
        exchanges: []const analysis.ReplayExchange,
        ending: analysis.ReplayEnding,
        quantum: u64,
    ) analysis.ReplayInput {
        return .{ .transcript = .{
            .binding = self.binding,
            .exchanges = exchanges,
            .ending = ending,
        }, .guest_quantum = quantum };
    }

    fn run(
        self: *const Replay,
        value: analysis.ReplayInput,
    ) !projection.Owned(analysis.ReplayOutput) {
        const input_bytes = try projection.encode(analysis.ReplayInput, a, value);
        defer a.free(input_bytes);
        var session = try base.Session.start(a, &self.prepared, input_bytes, .{});
        defer session.deinit();
        const outcome = try session.run(null);
        try std.testing.expect(outcome == .completed);
        return projection.decode(analysis.ReplayOutput, a, try session.bytes(&outcome.completed));
    }

    fn expectFailure(self: *const Replay, value: analysis.ReplayInput) !void {
        const input_bytes = try projection.encode(analysis.ReplayInput, a, value);
        defer a.free(input_bytes);
        var session = try base.Session.start(a, &self.prepared, input_bytes, .{});
        defer session.deinit();
        try std.testing.expect(try session.run(null) == .failed);
    }
};

fn requestImage(repeated: bool) ![]u8 {
    var b = source.Builder.init(a);
    defer b.deinit();
    return support.encode(try requests(&b, repeated));
}

fn expectState(expected: []const u8, actual: projection.State) !void {
    const bytes = try data.state_image.emit(a, actual);
    defer a.free(bytes);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

fn answer(session: *native.Session, value: []const u8) !void {
    var pending = try session.pendingRequest(a);
    defer pending.deinit();
    const envelope = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = pending.request.request_identity,
        .value = value,
    });
    defer a.free(envelope);
    try session.answer(envelope);
}

test "strict replay checks complete requests before response admission and application" {
    const image = try requestImage(false);
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var replay = try Replay.init(guest, .{ .arguments = &.{} }, .{
        .observation = true,
        .snapshot = true,
    });
    defer replay.deinit();
    var reference = try native.Session.initImage(a, image, &.{});
    defer reference.deinit();
    try std.testing.expect(try reference.run(null) == .requested);
    const pending = try reference.checkpoint(a);
    defer a.free(pending);
    const other_image = try requestImage(true);
    defer a.free(other_image);
    const other_guest = try data.program_image.Admitted.decode(a, other_image);
    defer other_guest.deinit();
    try expectRejectedStart(other_guest, .{ .checkpoint = pending });
    try expectRequestMismatches(&replay, pending);
    try answer(&reference, &integer(5));
    try std.testing.expect(try reference.run(null) == .requested);
    try answer(&reference, &integer(7));
    const terminal = try reference.run(null);
    try std.testing.expect(terminal == .completed);
    try std.testing.expectEqualSlices(u8, &integer(12), try reference.bytes(&terminal.completed));
    const expected = try reference.checkpoint(a);
    defer a.free(expected);
    var output = try replay.run(replay.input(&matching, .{ .terminal = .{
        .completed = &integer(12),
    } }, 100));
    defer output.deinit();
    try std.testing.expect(output.value.stopping == .terminal_matched);
    try std.testing.expectEqual(@as(u64, 2), output.value.matched_exchanges);
    try std.testing.expectEqual(reference.transitions, output.value.guest_steps);
    try std.testing.expectEqualDeep(replay.binding, output.value.binding);
    try std.testing.expectEqualSlices(u8, &integer(12), output.value.observation.?.completed);
    try expectState(expected, output.value.snapshot.?);
    try expectReplayStops(&replay);
}

fn expectRequestMismatches(replay: *const Replay, pending: []const u8) !void {
    const Case = struct { effect: data.program.Id, payload: []const u8, first: ?u64 };
    for ([_]Case{
        .{ .effect = 0, .payload = &integer(22), .first = 0 },
        .{ .effect = 0, .payload = &integer(0x800000000000000b), .first = 7 },
        .{ .effect = 0, .payload = &.{11}, .first = 1 },
        .{ .effect = 0, .payload = &.{ 11, 0, 0, 0, 0, 0, 0, 0, 99 }, .first = 8 },
        .{ .effect = 1, .payload = &integer(11), .first = null },
        .{ .effect = std.math.maxInt(data.program.Id), .payload = &integer(11), .first = null },
    }) |case| {
        const exchange: analysis.ReplayExchange = .{
            .expected_request = .{ .effect = case.effect, .payload = case.payload },
            .response = &.{255},
        };
        var output = try replay.run(replay.input(&.{exchange}, .prefix, 100));
        defer output.deinit();
        try std.testing.expectEqual(@as(u64, 0), output.value.matched_exchanges);
        try std.testing.expectEqual(.parked, output.value.boundary);
        try expectState(pending, output.value.snapshot.?);
        if (case.first) |first| {
            try std.testing.expect(output.value.stopping == .payload_mismatch);
            const mismatch = output.value.stopping.payload_mismatch;
            try std.testing.expectEqual(@as(u64, 0), mismatch.index);
            try std.testing.expectEqual(first, mismatch.first_difference);
            try std.testing.expectEqual(case.payload.len, mismatch.expected_length);
            try std.testing.expectEqual(@as(u64, 8), mismatch.actual_length);
        } else {
            try std.testing.expect(output.value.stopping == .effect_mismatch);
            const mismatch = output.value.stopping.effect_mismatch;
            try std.testing.expectEqual(case.effect, mismatch.expected);
            try std.testing.expectEqual(@as(data.program.Id, 0), mismatch.actual);
        }
    }
}

fn expectReplayStops(replay: *const Replay) !void {
    var wrong_terminal = try replay.run(replay.input(&matching, .{ .terminal = .{
        .completed = &integer(13),
    } }, 100));
    defer wrong_terminal.deinit();
    try std.testing.expect(wrong_terminal.value.stopping == .terminal_mismatch);
    try std.testing.expectEqualSlices(
        u8,
        &integer(12),
        wrong_terminal.value.observation.?.completed,
    );
    var observed = try replay.run(replay.input(&matching, .prefix, 100));
    defer observed.deinit();
    try std.testing.expect(observed.value.stopping == .terminal_observed);
    var missing = try replay.run(replay.input(matching[0..1], .{ .terminal = .{
        .completed = &integer(12),
    } }, 100));
    defer missing.deinit();
    try std.testing.expect(missing.value.stopping == .missing_exchange);
    try std.testing.expectEqual(@as(u64, 1), missing.value.matched_exchanges);
    var prefix = try replay.run(replay.input(matching[0..1], .prefix, 100));
    defer prefix.deinit();
    try std.testing.expect(prefix.value.stopping == .prefix_exhausted);
    const extra = matching ++ [_]analysis.ReplayExchange{.{
        .expected_request = .{ .effect = 999, .payload = &.{255} },
        .response = &.{255},
    }};
    var unused = try replay.run(replay.input(&extra, .prefix, 100));
    defer unused.deinit();
    try std.testing.expect(unused.value.stopping == .unused_exchanges);
    try std.testing.expectEqual(@as(u64, 2), unused.value.stopping.unused_exchanges);
    var zero = try replay.run(replay.input(&matching, .prefix, 0));
    defer zero.deinit();
    try std.testing.expect(zero.value.stopping == .guest_quantum);
    try std.testing.expectEqual(@as(u64, 0), zero.value.guest_steps);
    var exact = try replay.run(replay.input(&matching, .{ .terminal = .{
        .completed = &integer(12),
    } }, observed.value.guest_steps));
    defer exact.deinit();
    try std.testing.expect(exact.value.stopping == .terminal_matched);
    try expectBadInputs(replay);
}

fn expectBadInputs(replay: *const Replay) !void {
    var wrong = replay.input(&matching, .prefix, 100);
    wrong.transcript.binding.guest[0] ^= 1;
    try replay.expectFailure(wrong);
    wrong = replay.input(&matching, .prefix, 100);
    wrong.transcript.binding.origin.arguments[0] ^= 1;
    try replay.expectFailure(wrong);
    for ([_]@import("observe.zig").Observation{
        .progressed, .yielded, .{ .requested = .{ .effect = 0, .payload = &.{} } },
    }) |nonterminal| try replay.expectFailure(replay.input(
        &matching,
        .{ .terminal = nonterminal },
        100,
    ));
    for ([_][]const u8{ &.{}, &.{5}, &.{ 5, 0, 0, 0, 0, 0, 0, 0, 99 } }) |malformed| {
        var exchanges = matching;
        exchanges[0].response = malformed;
        try replay.expectFailure(replay.input(&exchanges, .prefix, 100));
    }
    var reordered = matching;
    std.mem.swap(analysis.ReplayExchange, &reordered[0], &reordered[1]);
    var mismatch = try replay.run(replay.input(&reordered, .prefix, 100));
    defer mismatch.deinit();
    try std.testing.expect(mismatch.value.stopping == .payload_mismatch);
    try std.testing.expectEqual(@as(u64, 0), mismatch.value.stopping.payload_mismatch.index);
    for ([_]u64{ 9007199254740993, std.math.maxInt(u64) - 7 }) |value| {
        var exact = matching;
        exact[0].response = &integer(value);
        var output = try replay.run(replay.input(&exact, .{ .terminal = .{
            .completed = &integer(value + 7),
        } }, 100));
        defer output.deinit();
        try std.testing.expect(output.value.stopping == .terminal_matched);
    }
}

test "strict replay answers parked requests at zero quantum without consuming guest steps" {
    const image = try requestImage(false);
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var reference = try native.Session.initImage(a, image, &.{});
    defer reference.deinit();
    try std.testing.expect(try reference.run(null) == .requested);
    const checkpoint = try reference.checkpoint(a);
    defer a.free(checkpoint);
    var replay = try Replay.init(guest, .{ .checkpoint = checkpoint }, .{
        .observation = true,
        .snapshot = true,
    });
    defer replay.deinit();
    var stopped = try replay.run(replay.input(&matching, .prefix, 0));
    defer stopped.deinit();
    try std.testing.expect(stopped.value.stopping == .guest_quantum);
    try std.testing.expectEqual(@as(u64, 1), stopped.value.matched_exchanges);
    try std.testing.expectEqual(@as(u64, 0), stopped.value.guest_steps);
    try answer(&reference, &integer(5));
    const answered = try reference.checkpoint(a);
    defer a.free(answered);
    try expectState(answered, stopped.value.snapshot.?);
    var wrong = matching;
    wrong[0].expected_request.payload = &integer(22);
    wrong[0].response = &.{255};
    var mismatch = try replay.run(replay.input(&wrong, .prefix, 0));
    defer mismatch.deinit();
    try std.testing.expect(mismatch.value.stopping == .payload_mismatch);
    try std.testing.expectEqual(@as(u64, 0), mismatch.value.matched_exchanges);
    try expectState(checkpoint, mismatch.value.snapshot.?);
    var empty = try replay.run(replay.input(&.{}, .prefix, 0));
    defer empty.deinit();
    try std.testing.expect(empty.value.stopping == .prefix_exhausted);
    try expectState(checkpoint, empty.value.snapshot.?);
}

fn yieldImage() ![]u8 {
    var b = source.Builder.init(a);
    defer b.deinit();
    const entry = try b.declare(&.{}, try b.scalar(u64), &.{}, &.{});
    const result = try b.pure(try b.constant(u64, 42));
    try b.define(entry, try b.term(.{ .yield_then = result }));
    return support.encode(b.module(entry, try b.scalar(void)));
}

test "strict replay preserves reached and initial yields and observes terminal checkpoints" {
    const image = try yieldImage();
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var reference = try native.Session.initImage(a, image, &.{});
    defer reference.deinit();
    try std.testing.expect(try reference.run(null) == .yielded);
    const checkpoint = try reference.checkpoint(a);
    defer a.free(checkpoint);
    for ([_]analysis.ReplayStart{ .{ .arguments = &.{} }, .{ .checkpoint = checkpoint } }) |start| {
        var replay = try Replay.init(guest, start, .{ .snapshot = true });
        defer replay.deinit();
        var stopped = try replay.run(replay.input(&matching, .prefix, 100));
        defer stopped.deinit();
        try std.testing.expect(stopped.value.stopping == .yielded);
        try std.testing.expectEqual(.yielded, stopped.value.boundary);
        try std.testing.expectEqual(@as(u64, 0), stopped.value.matched_exchanges);
        try std.testing.expect(stopped.value.observation == null);
        if (start == .checkpoint)
            try std.testing.expectEqual(@as(u64, 0), stopped.value.guest_steps);
        try expectState(checkpoint, stopped.value.snapshot.?);
    }
    try reference.resumeYield();
    try std.testing.expect(try reference.run(null) == .completed);
    const terminal = try reference.checkpoint(a);
    defer a.free(terminal);
    var replay = try Replay.init(guest, .{ .checkpoint = terminal }, .{});
    defer replay.deinit();
    var matched = try replay.run(replay.input(&.{}, .{ .terminal = .{
        .completed = &integer(42),
    } }, 0));
    defer matched.deinit();
    try std.testing.expect(matched.value.stopping == .terminal_matched);
    try std.testing.expectEqual(@as(u64, 0), matched.value.guest_steps);
    try std.testing.expect(matched.value.observation == null);
    try std.testing.expect(matched.value.snapshot == null);
    var unused = try replay.run(replay.input(&matching, .prefix, 0));
    defer unused.deinit();
    try std.testing.expect(unused.value.stopping == .unused_exchanges);
    try std.testing.expectEqual(@as(u64, 0), unused.value.stopping.unused_exchanges);
}

test "strict replay consumes repeated requests by occurrence and captures only selected details" {
    const image = try requestImage(true);
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var exchanges = matching;
    exchanges[1].expected_request.payload = &integer(11);
    for ([_]analysis.ReplayCapture{
        .{}, .{ .observation = true }, .{ .snapshot = true },
    }) |capture| {
        var replay = try Replay.init(guest, .{ .arguments = &.{} }, capture);
        defer replay.deinit();
        var output = try replay.run(replay.input(&exchanges, .{ .terminal = .{
            .completed = &integer(12),
        } }, 100));
        defer output.deinit();
        try std.testing.expect(output.value.stopping == .terminal_matched);
        try std.testing.expectEqual(@as(u64, 2), output.value.matched_exchanges);
        try std.testing.expectEqual(capture.observation, output.value.observation != null);
        try std.testing.expectEqual(capture.snapshot, output.value.snapshot != null);
        if (output.value.observation) |observation|
            try std.testing.expectEqualSlices(u8, &integer(12), observation.completed);
    }
}

test "strict replay restoration retains its transcript and rejects swapped programs" {
    const image = try requestImage(false);
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var replay = try Replay.init(guest, .{ .arguments = &.{} }, .{ .snapshot = true });
    defer replay.deinit();
    const input = replay.input(&matching, .{ .terminal = .{ .completed = &integer(12) } }, 100);
    var uninterrupted = try replay.run(input);
    defer uninterrupted.deinit();
    const expected = try projection.encode(analysis.ReplayOutput, a, uninterrupted.value);
    defer a.free(expected);
    try restoreAcrossExecution(&replay, input, expected);
    for ([_]u64{ 1, 53, 227 }) |quantum| {
        const bytes = try projection.encode(analysis.ReplayInput, a, input);
        defer a.free(bytes);
        var session = try base.Session.start(a, &replay.prepared, bytes, .{});
        defer session.deinit();
        try std.testing.expect(try session.run(quantum) == .progressed);
        const checkpoint = try session.checkpoint(a);
        defer a.free(checkpoint);
        @memset(bytes, 255);
        var restored = try base.Session.restore(a, &replay.prepared, checkpoint, .{});
        defer restored.deinit();
        const outcome = try restored.run(null);
        try std.testing.expect(outcome == .completed);
        try std.testing.expectEqualSlices(u8, expected, try restored.bytes(&outcome.completed));
        try expectRejectedStart(guest, .{ .checkpoint = checkpoint });
    }
    const subject = try data.state_image.emit(a, uninterrupted.value.snapshot.?);
    defer a.free(subject);
    if (base.Session.restore(a, &replay.prepared, subject, .{})) |value| {
        var invalid = value;
        invalid.deinit();
        return error.SubjectRestoredAsAnalysis;
    } else |_| {}
}

fn restoreAcrossExecution(
    replay: *const Replay,
    input: analysis.ReplayInput,
    expected: []const u8,
) !void {
    const bytes = try analysis.encodeReplayInput(a, input);
    defer a.free(bytes);
    var session = try base.Session.start(a, &replay.prepared, bytes, .{});
    defer session.deinit();
    var restores: u64 = 0;
    for (0..10000) |_| {
        const observed = try session.run(17);
        if (observed == .completed) {
            try std.testing.expectEqualSlices(u8, expected, try session.bytes(&observed.completed));
            try std.testing.expect(restores > 10);
            try restoreFinalTransition(
                replay,
                input,
                expected,
                restores * 17 + session.transitions,
            );
            return;
        }
        try std.testing.expect(observed == .progressed);
        const checkpoint = try session.checkpoint(a);
        defer a.free(checkpoint);
        @memset(bytes, 255);
        const next = try base.Session.restore(a, &replay.prepared, checkpoint, .{});
        session.deinit();
        session = next;
        restores += 1;
    }
    return error.ReplayRestoreBudgetExceeded;
}

fn restoreFinalTransition(
    replay: *const Replay,
    input: analysis.ReplayInput,
    expected: []const u8,
    steps: u64,
) !void {
    const bytes = try analysis.encodeReplayInput(a, input);
    defer a.free(bytes);
    var session = try base.Session.start(a, &replay.prepared, bytes, .{});
    defer session.deinit();
    try std.testing.expect(steps > 0);
    try std.testing.expect(try session.run(steps - 1) == .progressed);
    const checkpoint = try session.checkpoint(a);
    defer a.free(checkpoint);
    var restored = try base.Session.restore(a, &replay.prepared, checkpoint, .{});
    defer restored.deinit();
    const terminal = try restored.run(1);
    try std.testing.expect(terminal == .completed);
    try std.testing.expectEqualSlices(u8, expected, try restored.bytes(&terminal.completed));
}

fn expectRejectedStart(
    guest: *const data.program_image.Admitted,
    start: analysis.ReplayStart,
) !void {
    var b = source.Builder.init(a);
    defer b.deinit();
    if (analysis.replay(&b, guest, start, .{})) |_| return error.InvalidStartAccepted else |_| {}
}

fn booleanImage() ![]u8 {
    var b = source.Builder.init(a);
    defer b.deinit();
    const boolean = try b.scalar(bool);
    const entry = try b.declare(&.{boolean}, boolean, &.{}, &.{});
    try b.define(entry, try b.pure(try b.reference(b.parameter(entry, 0))));
    return support.encode(b.module(entry, try b.scalar(void)));
}

test "strict replay rejects invalid scalar responses and malformed outer records" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const boolean = try b.scalar(bool);
    const unit = try b.scalar(void);
    const effect = try b.effect(.{
        .identity = "replay/boolean",
        .payload = unit,
        .result = boolean,
    });
    const entry = try b.declare(&.{}, boolean, &.{effect}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.constant(void, {}),
    } }));
    const image = try support.encode(b.module(entry, unit));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var replay = try Replay.init(guest, .{ .arguments = &.{} }, .{});
    defer replay.deinit();
    const exchange: analysis.ReplayExchange = .{
        .expected_request = .{ .effect = 0, .payload = &.{} },
        .response = &.{2},
    };
    try replay.expectFailure(replay.input(&.{exchange}, .prefix, 100));
    const encoded = try analysis.encodeReplayInput(a, replay.input(&.{}, .prefix, 100));
    defer a.free(encoded);
    const trailing = try std.mem.concat(a, u8, &.{ encoded, &.{0} });
    defer a.free(trailing);
    for ([_][]const u8{ encoded[0 .. encoded.len - 1], trailing }) |bytes| {
        if (base.Session.start(a, &replay.prepared, bytes, .{})) |started| {
            var invalid = started;
            defer invalid.deinit();
            try std.testing.expect(try invalid.run(null) == .failed);
        } else |_| {}
    }
}

test "strict replay constructor admits exact starts and owns caller data" {
    const image = try booleanImage();
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    for ([_][]const u8{ &.{}, &.{2}, &.{ 1, 0 } }) |bytes|
        try expectRejectedStart(guest, .{ .arguments = bytes });
    var arguments = [_]u8{1};
    var b = source.Builder.init(a);
    defer b.deinit();
    const authored = try analysis.replay(&b, guest, .{ .arguments = &arguments }, .{
        .observation = true,
        .snapshot = true,
    });
    try std.testing.expectEqualDeep(
        @import("artifact.zig").digest(&arguments),
        authored.binding.origin.arguments,
    );
    arguments[0] = 0;
    var replay: Replay = .{
        .prepared = try support.prepare(authored.module),
        .binding = authored.binding,
    };
    defer replay.deinit();
    var output = try replay.run(replay.input(&.{}, .{ .terminal = .{ .completed = &.{1} } }, 100));
    defer output.deinit();
    try std.testing.expect(output.value.stopping == .terminal_matched);
    try std.testing.expectEqualSlices(u8, &.{1}, output.value.observation.?.completed);
    const encoded_output = try projection.encode(analysis.ReplayOutput, a, output.value);
    defer a.free(encoded_output);
    try std.testing.checkAllAllocationFailures(a, decodeFailing, .{encoded_output});
    var reference = try native.Session.initImage(a, image, &.{1});
    defer reference.deinit();
    const checkpoint = try reference.checkpoint(a);
    defer a.free(checkpoint);
    try expectCheckpointAdmission(guest, checkpoint);
    try std.testing.checkAllAllocationFailures(a, constructFailing, .{
        guest, analysis.ReplayStart{ .arguments = &.{1} },
    });
    try std.testing.checkAllAllocationFailures(a, constructFailing, .{
        guest, analysis.ReplayStart{ .checkpoint = checkpoint },
    });
}

fn decodeFailing(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var output = try analysis.decodeReplayOutput(allocator, bytes);
    defer output.deinit();
}

fn constructFailing(
    allocator: std.mem.Allocator,
    guest: *const data.program_image.Admitted,
    start: analysis.ReplayStart,
) !void {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    _ = try analysis.replay(&b, guest, start, .{});
}

fn expectCheckpointAdmission(
    guest: *const data.program_image.Admitted,
    checkpoint: []const u8,
) !void {
    try expectRejectedStart(guest, .{ .checkpoint = checkpoint[0 .. checkpoint.len - 1] });
    const trailing = try std.mem.concat(a, u8, &.{ checkpoint, &.{0} });
    defer a.free(trailing);
    try expectRejectedStart(guest, .{ .checkpoint = trailing });
    var state = try data.state_image.decodeGraph(a, checkpoint);
    defer state.deinit();
    const views = @import("views.zig");
    var bound = std.mem.zeroes(views.Binding);
    bound.guest = guest.identity();
    bound.checkpoint = @import("artifact.zig").digest(checkpoint);
    const mask = try a.alloc(bool, state.state.nodes.len);
    defer a.free(mask);
    @memset(mask, false);
    var partial = try views.capture(a, guest, checkpoint, bound, mask);
    defer partial.deinit();
    const view_bytes = try projection.encode(views.GuestView, a, partial.value);
    defer a.free(view_bytes);
    try expectRejectedStart(guest, .{ .checkpoint = view_bytes });
    var foreign = state.state;
    foreign.program_identity[0] ^= 1;
    const forged = try data.state_image.emit(a, foreign);
    defer a.free(forged);
    try expectRejectedStart(guest, .{ .checkpoint = forged });
    const owned = try a.dupe(u8, checkpoint);
    defer a.free(owned);
    var b = source.Builder.init(a);
    defer b.deinit();
    const authored = try analysis.replay(&b, guest, .{ .checkpoint = owned }, .{});
    try std.testing.expectEqualDeep(
        @import("artifact.zig").digest(checkpoint),
        authored.binding.origin.checkpoint,
    );
    @memset(owned, 255);
    var replay: Replay = .{
        .prepared = try support.prepare(authored.module),
        .binding = authored.binding,
    };
    defer replay.deinit();
    var output = try replay.run(replay.input(&.{}, .{ .terminal = .{ .completed = &.{1} } }, 100));
    defer output.deinit();
    try std.testing.expect(output.value.stopping == .terminal_matched);
}

test "strict replay checks cleanup requests and the ordered complete failure observation" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try support.encode(try source.examples.unwind(&b));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var reference = try native.Session.initImage(a, image, &.{1});
    defer reference.deinit();
    var payloads: [2][]u8 = undefined;
    var owned: usize = 0;
    defer for (payloads[0..owned]) |bytes| a.free(bytes);
    var exchanges: [2]analysis.ReplayExchange = undefined;
    for (&exchanges, &payloads) |*exchange, *payload| {
        const pending = try reference.run(null);
        try std.testing.expect(pending == .requested);
        payload.* = try a.dupe(u8, try reference.bytes(&pending.requested.payload));
        owned += 1;
        exchange.* = .{ .expected_request = .{
            .effect = pending.requested.effect,
            .payload = payload.*,
        }, .response = &.{} };
        try answer(&reference, &.{});
    }
    const failed = try reference.run(null);
    try std.testing.expect(failed == .failed);
    try std.testing.expectEqualSlices(u8, &integer(9), try reference.bytes(&failed.failed));
    const checkpoint = try reference.checkpoint(a);
    defer a.free(checkpoint);
    var replay = try Replay.init(guest, .{ .arguments = &.{1} }, .{
        .observation = true,
        .snapshot = true,
    });
    defer replay.deinit();
    const expected: @import("observe.zig").Observation = .{ .failed = .{
        .value = &integer(9),
        .cleanup_failures = &.{ &integer(7), &integer(8) },
        .cancellation = null,
    } };
    var output = try replay.run(replay.input(&exchanges, .{ .terminal = expected }, 500));
    defer output.deinit();
    try std.testing.expect(output.value.stopping == .terminal_matched);
    try std.testing.expectEqualDeep(expected, output.value.observation.?);
    try expectState(checkpoint, output.value.snapshot.?);
    var reversed = expected;
    reversed.failed.cleanup_failures = &.{ &integer(8), &integer(7) };
    var mismatch = try replay.run(replay.input(&exchanges, .{ .terminal = reversed }, 500));
    defer mismatch.deinit();
    try std.testing.expect(mismatch.value.stopping == .terminal_mismatch);
    reversed = expected;
    reversed.failed.value = &integer(10);
    var reason = try replay.run(replay.input(&exchanges, .{ .terminal = reversed }, 500));
    defer reason.deinit();
    try std.testing.expect(reason.value.stopping == .terminal_mismatch);
}

test "strict replay admits cancellation checkpoints without injecting a cancellation command" {
    const image = try yieldImage();
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var reference = try native.Session.initImage(a, image, &.{});
    defer reference.deinit();
    try std.testing.expect(try reference.run(null) == .yielded);
    try reference.cancel(.{ .text = "stop λ" });
    const unwinding = try reference.checkpoint(a);
    defer a.free(unwinding);
    try std.testing.expect(try reference.run(null) == .cancelled);
    const terminal = try reference.checkpoint(a);
    defer a.free(terminal);
    for ([_][]const u8{ unwinding, terminal }) |checkpoint| {
        var replay = try Replay.init(guest, .{ .checkpoint = checkpoint }, .{
            .observation = true,
            .snapshot = true,
        });
        defer replay.deinit();
        const expected: @import("observe.zig").Observation = .{ .cancelled = .{
            .reason = .{ .text = "stop λ" },
            .cleanup_failures = &.{},
        } };
        var output = try replay.run(replay.input(&.{}, .{ .terminal = expected }, 500));
        defer output.deinit();
        try std.testing.expect(output.value.stopping == .terminal_matched);
        try std.testing.expectEqualDeep(expected, output.value.observation.?);
        try expectState(terminal, output.value.snapshot.?);
        var wrong = expected;
        wrong.cancelled.reason = .{ .text = "stop" };
        var mismatch = try replay.run(replay.input(&.{}, .{ .terminal = wrong }, 500));
        defer mismatch.deinit();
        try std.testing.expect(mismatch.value.stopping == .terminal_mismatch);
        wrong.cancelled.reason = .{ .bytes = "stop λ" };
        var tag = try replay.run(replay.input(&.{}, .{ .terminal = wrong }, 500));
        defer tag.deinit();
        try std.testing.expect(tag.value.stopping == .terminal_mismatch);
    }
}

test "strict replay preserves retained multishot guest semantics and canonical state" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try support.encode(try source.examples.choicesAll(&b));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var reference = try native.Session.initImage(a, image, &.{});
    defer reference.deinit();
    const terminal = try reference.run(null);
    try std.testing.expect(terminal == .completed);
    const value = try reference.bytes(&terminal.completed);
    const checkpoint = try reference.checkpoint(a);
    defer a.free(checkpoint);
    var replay = try Replay.init(guest, .{ .arguments = &.{} }, .{ .snapshot = true });
    defer replay.deinit();
    var output = try replay.run(replay.input(&.{}, .{ .terminal = .{ .completed = value } }, 500));
    defer output.deinit();
    try std.testing.expect(output.value.stopping == .terminal_matched);
    try std.testing.expectEqual(reference.transitions, output.value.guest_steps);
    try expectState(checkpoint, output.value.snapshot.?);
}

test "strict replay distinguishes equal observations from different retained state" {
    const image = try requestImage(false);
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var replay = try Replay.init(guest, .{ .arguments = &.{} }, .{
        .observation = true,
        .snapshot = true,
    });
    defer replay.deinit();
    var first = try replay.run(replay.input(matching[0..1], .prefix, 100));
    defer first.deinit();
    var changed = matching[0];
    changed.response = &integer(6);
    var second = try replay.run(replay.input(&.{changed}, .prefix, 100));
    defer second.deinit();
    try std.testing.expect(first.value.stopping == .prefix_exhausted);
    try std.testing.expect(second.value.stopping == .prefix_exhausted);
    try std.testing.expectEqualDeep(first.value.observation.?, second.value.observation.?);
    const left = try data.state_image.emit(a, first.value.snapshot.?);
    defer a.free(left);
    const right = try data.state_image.emit(a, second.value.snapshot.?);
    defer a.free(right);
    try std.testing.expect(!std.mem.eql(u8, left, right));
    const envelope = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = @splat(0),
        .value = &integer(5),
    });
    defer a.free(envelope);
    changed.response = envelope;
    try replay.expectFailure(replay.input(&.{changed}, .prefix, 100));
}
