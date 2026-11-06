const std = @import("std");
const horos = @import("horos");
const data = horos.data;
const analysis = @import("kosmos").RuntimeAnalysis;
const fixture = @import("diagnostic_fixture");

fn guestImage(a: std.mem.Allocator) ![]u8 {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    var compiled = try horos.source.lower(a, try portableGuest(&b));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(image);
    _ = try compiled.encode(a, image);
    return image;
}

fn portableGuest(b: *horos.source.Builder) !horos.source.Module {
    const value = try b.scalar(u64);
    const unit = try b.scalar(void);
    const effect = try b.effect(.{
        .identity = "diagnostic/portable-request",
        .payload = value,
        .result = value,
    });
    const entry = try b.declare(&.{}, value, &.{effect}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.constant(u64, 11),
    } }));
    return b.module(entry, unit);
}

pub fn program(b: *horos.source.Builder) !horos.source.Module {
    const image = try guestImage(b.allocator());
    defer b.allocator().free(image);
    const guest = try data.program_image.Admitted.decode(b.allocator(), image);
    defer guest.deinit();
    const replay = try analysis.replay(b, guest, .{ .arguments = &.{} }, .{
        .observation = true,
        .snapshot = true,
    });
    return replay.module;
}

pub fn input(a: std.mem.Allocator, mismatch: bool) ![]u8 {
    const image = try guestImage(a);
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var origin: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&.{}, &origin, .{});
    const exchanges = [_]analysis.ReplayExchange{
        .{ .expected_request = .{ .effect = 0, .payload = &fixture.integer(
            if (mismatch) 12 else 11,
        ) }, .response = if (mismatch) &.{255} else &fixture.integer(5) },
    };
    return analysis.encodeReplayInput(a, .{ .transcript = .{
        .binding = .{ .guest = guest.identity(), .origin = .{ .arguments = origin } },
        .exchanges = &exchanges,
        .ending = .{ .terminal = .{ .completed = &fixture.integer(5) } },
    }, .guest_quantum = 100 });
}

pub fn inspect(a: std.mem.Allocator, bytes: []const u8, writer: *std.Io.Writer) !void {
    var output = try analysis.decodeReplayOutput(a, bytes);
    defer output.deinit();
    const state = output.value.snapshot orelse return error.MissingSnapshot;
    const checkpoint = try data.state_image.emit(a, state);
    defer a.free(checkpoint);
    const observation = output.value.observation orelse return error.MissingObservation;
    try std.json.Stringify.value(.{
        .stop = @tagName(output.value.stopping),
        .matched = output.value.matched_exchanges,
        .boundary = @tagName(output.value.boundary),
        .snapshot_status = @tagName(state.status),
        .checkpoint_bytes = checkpoint.len,
        .observation = @tagName(observation),
        .completed_hex = if (observation == .completed)
            std.fmt.bytesToHex(observation.completed[0..8].*, .lower)
        else
            null,
    }, .{}, writer);
}
