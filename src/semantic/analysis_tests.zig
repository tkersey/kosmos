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
