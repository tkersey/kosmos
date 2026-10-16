const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const service = @import("service.zig");
const projection = @import("projection.zig");
const base = @import("../base/session.zig");
const profile = @import("../base/profile.zig");
const native = @import("../../test_oracle.zig");
const a = std.testing.allocator;

fn build() ![]u8 {
    var b = source.Builder.init(a);
    defer b.deinit();
    const d = try service.define(&b);
    var diagnostic: source.Diagnostic = .{};
    var compiled = source.lowerObserved(a, b.module(d.entry, try b.scalar(void)), .{ .diagnostic = &diagnostic }) catch |err| {
        std.debug.print("service lowering: {any}\n", .{diagnostic});
        return err;
    };
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    return bytes;
}
pub fn send(session: *base.Session, command: service.Command) !void {
    var pending = try session.pendingBinding(a, false);
    defer pending.deinit();
    const value = try projection.encode(service.Command, a, command);
    defer a.free(value);
    const response = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request.request_identity, .value = value });
    defer a.free(response);
    try session.answer(response);
}
pub fn event(session: *base.Session) !projection.Owned(service.Event) {
    const result = try session.run(null);
    if (result != .requested) std.debug.print("service event unexpectedly {s}\n", .{@tagName(result)});
    try std.testing.expect(result == .requested);
    return projection.decode(service.Event, a, try session.bytes(&result.requested.payload));
}

test "persistent authored service separates guest slices base pauses projections and terminal close" {
    const image = try build();
    defer a.free(image);
    var prepared = try base.Prepared.init(a, image);
    defer prepared.deinit();
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const bridge: profile.Bridge = .{ .effects = admitted.program().effects };
    _ = try profile.check(admitted, bridge);
    var b = source.Builder.init(a);
    defer b.deinit();
    var compiled = try source.lower(a, try source.examples.cloned(&b));
    defer compiled.deinit();
    const guest_image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(guest_image);
    _ = try compiled.encode(a, guest_image);
    const guest_program = try data.program_image.Admitted.decode(a, guest_image);
    defer guest_program.deinit();
    const program = try projection.programBytes(a, guest_program);
    defer a.free(program);
    const initial = try projection.encode(service.Initial, a, .{ .arguments = &.{} });
    defer a.free(initial);
    const arguments = try std.mem.concat(a, u8, &.{ program, initial });
    defer a.free(arguments);
    var session = try base.Session.start(a, &prepared, arguments, bridge);
    defer session.deinit();
    var guest = try native.Session.initImage(a, guest_image, &.{});
    defer guest.deinit();
    {
        var first = try event(&session);
        defer first.deinit();
        try std.testing.expect(first.value == .cut);
        try std.testing.expectEqual(@as(u64, 0), first.value.cut.guest_work);
        var transaction = try session.begin();
        try send(&session, .finish);
        try std.testing.expect(try session.run(null) == .failed);
        transaction.rollback(&session);
    }
    var restored = false;
    var finished = false;
    for (0..100) |slice| {
        const quantum: u64 = if (slice % 3 == 0) 1 else 7;
        try send(&session, .{ .advance = .{ .control = .none, .quantum = quantum } });
        if (!restored) {
            try std.testing.expect(try session.run(127) == .progressed);
            const checkpoint = try session.checkpoint(a);
            defer a.free(checkpoint);
            var replacement = try base.Session.restore(a, &prepared, checkpoint, bridge);
            session.deinit();
            session = replacement;
            replacement = undefined;
            restored = true;
        }
        var cut = try event(&session);
        defer cut.deinit();
        try std.testing.expect(cut.value == .cut);
        const observation = try guest.run(quantum);
        try std.testing.expect(cut.value.cut.guest_work <= quantum);
        try send(&session, .project);
        var state = try event(&session);
        defer state.deinit();
        try std.testing.expect(state.value == .projection);
        var canonical = try data.state_image.canonicalize(a, state.value.projection);
        defer canonical.deinit();
        try data.state_admission.validateAdmitted(a, guest_program, canonical.state);
        const actual = try data.state_image.emit(a, canonical.state);
        defer a.free(actual);
        const expected = try guest.checkpoint(a);
        defer a.free(expected);
        try std.testing.expectEqualSlices(u8, expected, actual);
        try send(&session, .observe);
        var observed = try event(&session);
        defer observed.deinit();
        try std.testing.expect(observed.value == .observation);
        if (observation == .completed) {
            try std.testing.expect(observed.value.observation == .completed);
            try std.testing.expectEqualSlices(u8, try guest.bytes(&observation.completed), observed.value.observation.completed);
            try send(&session, .finish);
            try std.testing.expect(try session.run(null) == .completed);
            finished = true;
            break;
        }
        if (observation == .yielded) {
            try std.testing.expect(observed.value.observation == .yielded);
            try send(&session, .{ .advance = .{ .control = .resume_yield, .quantum = 0 } });
            var resumed = try event(&session);
            defer resumed.deinit();
            try std.testing.expect(resumed.value == .cut);
            try std.testing.expectEqual(@as(u64, 0), resumed.value.cut.guest_work);
            try guest.resumeYield();
        } else {
            if (observation != .progressed) std.debug.print("service slice {d} observation {s}\n", .{ slice, @tagName(observation) });
            try std.testing.expect(observation == .progressed);
        }
    }
    try std.testing.expect(restored and finished);
}
