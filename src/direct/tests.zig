const std = @import("std");
const data = @import("horos_data");
const core = @import("../semantic/session.zig");
const Lockstep = @import("lockstep.zig").Lockstep;
const workloads = @import("../semantic_workloads.zig");
const Resident = @import("../interpreter_v2/resident.zig").Resident;
const protocol = data.invocation;
const a = std.testing.allocator;
const cuts_max = 4096;

const Drive = struct { quantum: ?u64, restore_every: usize };
const drives = [_]Drive{
    .{ .quantum = null, .restore_every = 1 },
    .{ .quantum = 256, .restore_every = 1 },
    .{ .quantum = 1, .restore_every = 7 },
};

fn replyTo(execution: anytype, sample: usize) ![]u8 {
    var pending = try execution.pendingRequest(a);
    defer pending.deinit();
    const request = try protocol.encodeOwned(protocol.Request, a, pending.request);
    defer a.free(request);
    return workloads.reply(a, request, sample);
}

fn advance(execution: *Lockstep, drive: Drive, sample: usize) !bool {
    switch (try execution.run(drive.quantum)) {
        .progressed => {},
        .yielded => try execution.resumeYield(),
        .requested => {
            const answer = try replyTo(execution, sample);
            defer a.free(answer);
            try execution.answer(answer);
        },
        .completed, .failed, .cancelled => return false,
    }
    return true;
}

fn driveLockstep(
    prepared: *const core.Prepared,
    input: []const u8,
    drive: Drive,
    sample: usize,
) !usize {
    var execution = try Lockstep.start(a, prepared, input);
    defer execution.deinit();
    for (0..cuts_max) |cut| {
        if (!try advance(&execution, drive, sample)) return cut + 1;
        if (cut % drive.restore_every != 0) continue;
        const saved = try execution.checkpoint(a);
        defer a.free(saved);
        var restored = try Lockstep.restore(a, prepared, saved);
        std.mem.swap(Lockstep, &execution, &restored);
        restored.deinit();
    }
    return error.TooManyCuts;
}

test "economy workloads run in lockstep at every cut and restore across realizations" {
    for (std.meta.tags(workloads.Workload)) |kind| {
        const image = try workloads.image(a, kind);
        defer a.free(image);
        var prepared = try core.Prepared.init(a, image);
        defer prepared.deinit();
        for (0..3) |sample| {
            const input = try workloads.arguments(a, kind, sample);
            defer a.free(input);
            for (drives) |drive| _ = try driveLockstep(&prepared, input, drive, sample);
        }
    }
}

test "residents publish identical outcomes and receipts on every realization" {
    const image = try workloads.image(a, .multi_shot);
    defer a.free(image);
    const input = try workloads.arguments(a, .multi_shot, 0);
    defer a.free(input);
    var outcomes: [3][]u8 = undefined;
    inline for (.{ .core, .direct, .lockstep }, 0..) |realization, index| {
        var prepared = try core.Prepared.initRealization(a, image, realization);
        defer prepared.deinit();
        outcomes[index] = try publishAll(&prepared, input);
    }
    defer for (outcomes) |bytes| a.free(bytes);
    try std.testing.expectEqualSlices(u8, outcomes[0], outcomes[1]);
    try std.testing.expectEqualSlices(u8, outcomes[0], outcomes[2]);
}

fn publishAll(prepared: *const core.Prepared, input: []const u8) ![]u8 {
    var resident = try Resident.start(a, prepared, input);
    defer if (resident.live) closeResident(&resident);
    var transcript: std.ArrayList(u8) = .empty;
    errdefer transcript.deinit(a);
    var control: protocol.Control = .none;
    var reply: ?[]u8 = null;
    defer if (reply) |bytes| a.free(bytes);
    for (0..cuts_max) |_| {
        var publication = try resident.publish(.{ .encoded = a }, control, .{
            .quantum = 5,
            .checkpoint = .receipt,
        });
        defer publication.deinit();
        try transcript.appendSlice(a, publication.outcome.encoded);
        if (publication.checkpoint) |receipt| try transcript.appendSlice(a, receipt.bytes());
        var decoded = try protocol.decode(protocol.Outcome, a, publication.outcome.encoded);
        defer decoded.deinit();
        if (reply) |bytes| a.free(bytes);
        reply = null;
        control = switch (decoded.value) {
            .progressed => .none,
            .yielded => .resume_yield,
            .requested => |pending| blk: {
                reply = try workloads.reply(a, pending.request, 0);
                break :blk .{ .reply = reply.? };
            },
            else => return transcript.toOwnedSlice(a),
        };
    }
    return error.TooManyCuts;
}

fn driveToEnd(resident: *Resident) ![]u8 {
    var control: protocol.Control = .none;
    var reply: ?[]u8 = null;
    defer if (reply) |bytes| a.free(bytes);
    for (0..cuts_max) |_| {
        const encoded = try resident.driveEncoded(a, control, .{ .quantum = 2 });
        errdefer a.free(encoded);
        var decoded = try protocol.decode(protocol.Outcome, a, encoded);
        defer decoded.deinit();
        if (reply) |bytes| a.free(bytes);
        reply = null;
        control = switch (decoded.value) {
            .progressed => .none,
            .yielded => .resume_yield,
            .requested => |pending| blk: {
                reply = try workloads.reply(a, pending.request, 0);
                break :blk .{ .reply = reply.? };
            },
            else => {
                try resident.close();
                return encoded;
            },
        };
        a.free(encoded);
    }
    return error.TooManyCuts;
}

fn closeResident(resident: *Resident) void {
    resident.close() catch |err| std.debug.panic("{s}", .{@errorName(err)});
}

test "a direct resident falls back to the core at a guest cut for core-only operations" {
    const image = try workloads.image(a, .long_cleanup);
    defer a.free(image);
    const input = try workloads.arguments(a, .long_cleanup, 0);
    defer a.free(input);
    var reference_prepared = try core.Prepared.initRealization(a, image, .core);
    defer reference_prepared.deinit();
    var reference = try Resident.start(a, &reference_prepared, input);
    const expected = try driveToEnd(&reference);
    defer a.free(expected);
    var prepared = try core.Prepared.initRealization(a, image, .direct);
    defer prepared.deinit();
    var resident = try Resident.start(a, &prepared, input);
    defer if (resident.live) closeResident(&resident);
    const first = try resident.driveEncoded(a, .none, .{ .quantum = 7 });
    a.free(first);
    try std.testing.expectEqual(.direct, try resident.realization());
    _ = try resident.runtimeBinding();
    try std.testing.expectEqual(.core, try resident.realization());
    const recovered = try driveToEnd(&resident);
    defer a.free(recovered);
    try std.testing.expectEqualSlices(u8, expected, recovered);
}

const Author = @import("../semantic/author.zig").Author;
const elements_max = 512;

fn sequenceSum() ![]u8 {
    const horos = @import("horos");
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const items = try b.schema(.{ .seq = e.integer });
    const loop = try b.declare(&.{ items, e.integer, e.integer }, e.integer, &.{}, &.{});
    const length = try b.primitive(e.integer, .sequence_length, &.{try e.param(loop, 0)}, 0);
    const element = try e.required(try e.param(loop, 0), try e.param(loop, 1));
    try b.define(loop, try e.when(
        try e.binary(.equal, try e.param(loop, 1), length),
        try b.pure(try e.param(loop, 2)),
        try e.call(loop, &.{
            try e.param(loop, 0),
            try e.binary(.integer_add, try e.param(loop, 1), e.one),
            try e.binary(.integer_bit_xor, try e.param(loop, 2), element),
        }),
    ));
    const entry = try b.declare(&.{items}, e.integer, &.{}, &.{});
    try b.define(entry, try e.call(loop, &.{ try e.param(entry, 0), e.zero, e.zero }));
    var compiled = try horos.source.lower(a, b.module(entry, e.unit));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(image);
    _ = try compiled.encode(a, image);
    return image;
}

test "direct element access over an encoded collection decodes each element position once" {
    const image = try sequenceSum();
    defer a.free(image);
    var prepared = try core.Prepared.initRealization(a, image, .core);
    defer prepared.deinit();
    var size: data.wire.Writer = .{};
    try size.natural(elements_max);
    const input = try a.alloc(u8, size.position + elements_max * 8);
    defer a.free(input);
    var writer: data.wire.Writer = .{ .output = input };
    try writer.natural(elements_max);
    for (0..elements_max) |index| try writer.fixed(u64, index *% 0x9e3779b97f4a7c15);
    var execution = try Lockstep.start(a, &prepared, input);
    defer execution.deinit();
    for (0..cuts_max) |_| if (try execution.run(256) != .progressed) break;
    try std.testing.expect(try execution.observe() == .completed);
    try std.testing.expectEqual(elements_max - 1, execution.candidate.offsets.scans);
}
