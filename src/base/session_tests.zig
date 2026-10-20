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
    try std.testing.expectError(
        error.UnsupportedBaseSchema,
        Session.initImage(a, image, &.{}, .{}),
    );
}

test "base bridge response binding survives checkpoint and transaction rollback" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const effect = try b.effect(.{
        .identity = "kosmos.base.test/1",
        .payload = integer,
        .result = integer,
    });
    const entry = try b.declare(&.{integer}, integer, &.{effect}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.reference(b.parameter(entry, 0)),
    } }));
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

test "base transaction rolls back and retries recursive execution at every allocation failure" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try encode(try source.examples.recursive(&b));
    defer a.free(image);
    var prepared = try @import("session.zig").Prepared.init(a, image);
    defer prepared.deinit();
    const input = std.mem.toBytes(@as(u64, 17));
    var reference = try Session.start(a, &prepared, &input, .{});
    defer reference.deinit();
    const before = try reference.checkpoint(a);
    defer a.free(before);
    const result = try reference.run(null);
    try std.testing.expect(result == .completed);
    const expected = try a.dupe(u8, try reference.bytes(&result.completed));
    defer a.free(expected);
    const allocation_count = try recursiveAllocationCount(&prepared, &input);
    var failed_after_mutation = false;
    for (0..allocation_count + 1) |failures| {
        var fixed_growth = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
        var failing = std.testing.FailingAllocator.init(fixed_growth.allocator(), .{});
        var session = try Session.start(failing.allocator(), &prepared, &input, .{});
        defer session.deinit();
        var statistics: @import("../interpreter_v2/runtime_types.zig").Statistics = .{};
        session.statistics = &statistics;
        failing.fail_index = failing.alloc_index + failures;
        runTransaction(&session) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed_after_mutation = failed_after_mutation or statistics.transitions != 0;
            const unchanged = try session.checkpoint(a);
            defer a.free(unchanged);
            try std.testing.expectEqualSlices(u8, before, unchanged);
            try runTransaction(&session);
            const retried = try session.observe();
            try std.testing.expectEqualSlices(u8, expected, try session.bytes(&retried.completed));
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        const actual = try session.observe();
        try std.testing.expectEqualSlices(u8, expected, try session.bytes(&actual.completed));
        try std.testing.expect(failures != 0 and failed_after_mutation);
        return;
    }
    return error.AllocationSweepIncomplete;
}

fn runTransaction(subject: *Session) !void {
    var transaction = try subject.begin();
    errdefer transaction.rollback(subject);
    try std.testing.expect(try subject.run(null) == .completed);
    transaction.commit(subject);
}

fn recursiveAllocationCount(prepared: *const SessionPrepared, input: []const u8) !usize {
    var fixed_growth = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    var counting = std.testing.FailingAllocator.init(fixed_growth.allocator(), .{});
    var session = try Session.start(counting.allocator(), prepared, input, .{});
    defer session.deinit();
    const before = counting.alloc_index;
    try runTransaction(&session);
    return counting.alloc_index - before;
}

const SessionPrepared = @import("session.zig").Prepared;

const AllocationCounter = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.backing.rawAlloc(length, alignment, address);
    }
    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        length: usize,
        address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, length, address);
    }
    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        length: usize,
        address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, length, address);
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, address);
    }
};

test "base temporary allocation cost preserves recursive dynamic results" {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const e = try @import("../semantic/author.zig").Author.init(&builder);
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const entry = try builder.declare(&.{integer}, integer, &.{}, &.{});
    const count = try e.param(entry, 0);
    const zero = try builder.constant(u64, 0);
    const one = try builder.constant(u64, 1);
    try builder.define(
        entry,
        try e.when(
            try e.binary(.equal, count, zero),
            try builder.pure(count),
            try e.call(entry, &.{
                try e.binary(.integer_sub, count, one),
            }),
        ),
    );
    const image = try encode(builder.module(entry, unit));
    defer a.free(image);
    for ([_]u64{ 64, 512 }) |iterations| {
        var counted: AllocationCounter = .{ .backing = a };
        const input = std.mem.toBytes(iterations);
        var session = try Session.initImage(counted.allocator(), image, &input, .{});
        defer session.deinit();
        const before = counted.allocations;
        const result = try session.run(null);
        try std.testing.expect(result == .completed);
        try std.testing.expectEqualSlices(
            u8,
            &std.mem.toBytes(@as(u64, 0)),
            try session.bytes(&result.completed),
        );
        try std.testing.expect(counted.allocations - before <= 8);
        std.debug.print("base recursive iterations={d} physical_allocations={d}\n", .{
            iterations, counted.allocations - before,
        });
    }
}
