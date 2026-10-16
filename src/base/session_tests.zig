const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const Session = @import("session.zig").Session;
const a = std.testing.allocator;

fn encode(module: source.Module) ![]u8 {
    var compiled = try source.lower(a, module);
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    return bytes;
}

test "base rejects guest control before running any instruction" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try encode(try source.examples.cloned(&b));
    defer a.free(image);
    try std.testing.expectError(error.UnsupportedBaseSchema, Session.initImage(a, image, &.{}, .{}));
}

test "base bridge response binding survives checkpoint and transaction rollback" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const effect = try b.effect(.{ .identity = "kosmos.base.test/1", .payload = integer, .result = integer });
    const entry = try b.declare(&.{integer}, integer, &.{effect}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{ .effect = effect, .payload = try b.reference(b.parameter(entry, 0)) } }));
    const image = try encode(b.module(entry, unit));
    defer a.free(image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const bridge: @import("profile.zig").Bridge = .{ .effects = admitted.program().effects };
    const input = std.mem.toBytes(@as(u64, 17));
    try std.testing.expectError(error.InvalidBridge, Session.initImage(a, image, &input, .{}));
    var session = try Session.initImage(a, image, &input, bridge);
    defer session.deinit();
    try std.testing.expect(try session.run(null) == .requested);
    var pending = try session.pendingRequest(a);
    defer pending.deinit();
    var restored = try Session.restoreImage(a, image, pending.state, bridge);
    defer restored.deinit();
    const wrong = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = @splat(0),
        .value = &input,
    });
    defer a.free(wrong);
    try std.testing.expectError(error.InvalidResult, restored.answer(wrong));
    const result = std.mem.toBytes(@as(u64, 38));
    const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = pending.request.request_identity,
        .value = &result,
    });
    defer a.free(reply);
    var transaction = try restored.begin();
    try restored.answer(reply);
    const first = try restored.run(null);
    try std.testing.expect(first == .completed);
    try std.testing.expectEqualSlices(u8, &result, try restored.bytes(&first.completed));
    transaction.rollback(&restored);
    const rolled_back = try restored.checkpoint(a);
    defer a.free(rolled_back);
    try std.testing.expectEqualSlices(u8, pending.state, rolled_back);
    try restored.answer(reply);
    const second = try restored.run(null);
    try std.testing.expect(second == .completed);
    try std.testing.expectEqualSlices(u8, &result, try restored.bytes(&second.completed));
    try std.testing.expectError(error.InvalidState, restored.answer(reply));
}
