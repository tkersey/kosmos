const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const analysis = @import("analysis.zig");
const projection = @import("projection.zig");
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");

test "hypothetical reply interpretation runs ordinary source without consuming a live request" {
    var guest_builder = source.Builder.init(a);
    defer guest_builder.deinit();
    const image = try support.encode(try analysis.exampleGuest(&guest_builder));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    const arguments = [_]u8{ 10, 0, 0, 0, 0, 0, 0, 0 };
    var live = try @import("../../test/oracle/stable_session.zig").Session.initImage(a, image, &arguments);
    defer live.deinit();
    try std.testing.expect(try live.run(null) == .requested);
    const before = try live.checkpoint(a);
    defer a.free(before);
    var pending = try live.pendingRequest(a);
    defer pending.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    // Exercise the public example entry point used by downstream construction.
    // Its embedded guest must still match the separately admitted guest above.
    var compiled = try source.lower(a, try analysis.example(&builder));
    defer compiled.deinit();
    // The simulated effect is data in the embedded program projection. The
    // analysis executable itself has no environmental effect declarations.
    try std.testing.expectEqual(@as(usize, 0), compiled.program.effects.len);
    const code = try support.encodeCompiled(&compiled);
    defer a.free(code);
    for ([_]u8{ 5, 99 }) |assumed| {
        const reply = [_]u8{ assumed, 0, 0, 0, 0, 0, 0, 0 };
        const input = try projection.encode(analysis.Input, a, .{ .arguments = &arguments, .assumed_reply = &reply, .guest_quantum = 100 });
        defer a.free(input);
        var experiment = try base.Session.initImage(a, code, input, .{});
        defer experiment.deinit();
        const completed = try experiment.run(null);
        try std.testing.expect(completed == .completed);
        var result = try projection.decode(analysis.Output, a, try experiment.bytes(&completed.completed));
        defer result.deinit();
        try std.testing.expectEqual(.hypothetical_first_reply, result.value.interpretation);
        try std.testing.expectEqualDeep(guest.identity(), result.value.guest);
        try std.testing.expectEqualSlices(u8, &reply, result.value.assumed_reply);
        try std.testing.expect(result.value.assumption_applied);
        try std.testing.expect(result.value.observation == .completed);
        try std.testing.expectEqual(@as(u64, 10 + @as(u64, assumed)), std.mem.readInt(u64, result.value.observation.completed[0..8], .little));
        try std.testing.expectError(error.InvalidFamily, live.answer(try experiment.bytes(&completed.completed)));
    }
    for ([_][]const u8{ &.{}, &.{5}, &.{ 5, 0, 0, 0, 0, 0, 0, 0, 99 } }) |malformed| {
        try std.testing.expectError(if (malformed.len > 8) error.NonCanonical else error.InvalidValue, data.admission.value(a, guest.program().schemas, guest.schemaFacts(), .{ .schema = guest.program().effects[0].result, .bytes = malformed }));
        const input = try projection.encode(analysis.Input, a, .{ .arguments = &arguments, .assumed_reply = malformed, .guest_quantum = 100 });
        defer a.free(input);
        var experiment = try base.Session.initImage(a, code, input, .{});
        defer experiment.deinit();
        try std.testing.expect(try experiment.run(null) == .failed);
    }
    const after = try live.checkpoint(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    const actual_reply = [_]u8{ 7, 0, 0, 0, 0, 0, 0, 0 };
    const response = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request.request_identity, .value = &actual_reply });
    defer a.free(response);
    try live.answer(response);
    const result = try live.run(null);
    try std.testing.expect(result == .completed);
    try std.testing.expectEqual(@as(u64, 17), std.mem.readInt(u64, (try live.bytes(&result.completed))[0..8], .little));
}

test "hypothetical analysis admits both arguments and the actual pending reply schema" {
    const Author = @import("author.zig").Author;
    var guest_builder = source.Builder.init(a);
    defer guest_builder.deinit();
    const e = try Author.init(&guest_builder);
    const effect = try guest_builder.effect(.{ .identity = "analysis/boolean", .payload = e.unit, .result = e.boolean });
    const entry = try guest_builder.declare(&.{e.boolean}, e.boolean, &.{effect}, &.{});
    const answer = try guest_builder.variable(e.boolean);
    try guest_builder.define(entry, try guest_builder.bind(answer, try guest_builder.term(.{ .perform = .{ .effect = effect, .payload = e.unit_value } }), try guest_builder.pure(try e.binary(.equal, try e.param(entry, 0), try guest_builder.reference(answer)))));
    const image = try support.encode(guest_builder.module(entry, e.unit));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    var compiled = try source.lower(a, try analysis.hypotheticalReply(&builder, guest));
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.program.effects.len);
    const code = try support.encodeCompiled(&compiled);
    defer a.free(code);
    const Case = struct { arguments: []const u8, reply: []const u8, expected: ?u8 };
    for ([_]Case{
        .{ .arguments = &.{1}, .reply = &.{1}, .expected = 1 },
        .{ .arguments = &.{0}, .reply = &.{1}, .expected = 0 },
        .{ .arguments = &.{1}, .reply = &.{2}, .expected = null },
        .{ .arguments = &.{2}, .reply = &.{1}, .expected = null },
        .{ .arguments = &.{1}, .reply = &.{ 1, 0 }, .expected = null },
        .{ .arguments = &.{ 1, 0 }, .reply = &.{1}, .expected = null },
        .{ .arguments = &.{}, .reply = &.{1}, .expected = null },
        .{ .arguments = &.{1}, .reply = &.{}, .expected = null },
    }) |case| {
        const input = try projection.encode(analysis.Input, a, .{ .arguments = case.arguments, .assumed_reply = case.reply, .guest_quantum = 100 });
        defer a.free(input);
        var experiment = try base.Session.initImage(a, code, input, .{});
        defer experiment.deinit();
        const outcome = try experiment.run(null);
        if (case.expected) |expected| {
            try std.testing.expect(outcome == .completed);
            var result = try projection.decode(analysis.Output, a, try experiment.bytes(&outcome.completed));
            defer result.deinit();
            try std.testing.expect(result.value.assumption_applied);
            try std.testing.expect(result.value.observation == .completed);
            try std.testing.expectEqualSlices(u8, &.{expected}, result.value.observation.completed);
        } else try std.testing.expect(outcome == .failed);
    }
}
