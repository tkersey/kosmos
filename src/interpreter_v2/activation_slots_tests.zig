// Copyright (c) 2026 World contributors. MIT license.
const std = @import("std");
const slots = @import("activation_slots.zig");
const Slots = slots.Slots(u64);
const testing = std.testing;

test "frame pruning keeps initialization separate from liveness and preserves older views" {
    for ([_]usize{ 3, 64, 65, 256 }) |count| try pruneFrame(count);
}

fn pruneFrame(count: usize) !void {
    const data = @import("horos_data");
    const Frames = @import("activation_frames.zig").Frames;
    const Values = @import("values.zig").Values;
    var pool: data.analysis_sets.Pool = .{ .allocator = testing.allocator, .limit = count };
    defer pool.deinit();
    const layout = try testing.allocator.alloc(data.program.Id, count);
    defer testing.allocator.free(layout);
    @memset(layout, 0);
    const last = count - 1;
    const program: data.activation.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{.u64},
        .constants = &.{},
        .effects = &.{},
        .blocks = &.{},
        .functions = &.{.{ .entry = 0, .inputs = &.{ 0, last }, .layout = .{ .slots = layout }, .result = 0 }},
    };
    var frame_layouts = try @import("frame_layouts.zig").Layouts.init(testing.allocator, program.functions);
    defer frame_layouts.deinit();
    var frames = try Frames.init(testing.allocator, &pool, &frame_layouts);
    defer frames.deinit();
    var original = try frames.create(0);
    defer frames.releaseFrame(original);
    try frames.write(&original, 0, Values.natural(0, 42));
    try frames.write(&original, last, Values.natural(0, 99));
    var successor = try frames.forkFrame(original);
    defer frames.releaseFrame(successor);
    try frames.prune(&successor, try pool.run(0, last));
    try testing.expect(successor.live_bound.contains(&pool, 0));
    if (last > 1) try testing.expect(successor.live_bound.contains(&pool, 1));
    try testing.expect(!successor.live_bound.contains(&pool, last));
    try testing.expectError(error.UninitializedSlot, frames.slots.get(successor.view, 1));
    try testing.expectError(error.UninitializedSlot, frames.slots.get(successor.view, last));
    try testing.expectEqual(99, (try frames.slots.get(original.view, last)).body.scalar[0]);
    try testing.expectEqual(42, (try frames.slots.get(successor.view, 0)).body.scalar[0]);
}

test "stable slots establish growing bindings without copying prior values" {
    for ([_]usize{ 1, 8, 64, 128, 256, 4096 }) |count| {
        var store = try Slots.init(testing.allocator);
        defer store.deinit();
        const view = try store.create(count);
        for (0..count) |index| try store.set(view, index, index + 1);
        var sum: u64 = 0;
        for (0..count) |index| sum += try store.get(view, index);
        try testing.expectEqual(count * (count + 1) / 2, sum);
        try testing.expectEqual(0, store.statistics.value_copies);
        try testing.expectEqual(count, store.statistics.writes);
        try testing.expect(store.statistics.directory_copies <= count * 16);
        try store.release(view);
        try testing.expectEqual(0, store.statistics.live_pages);
        try testing.expectEqual(0, store.statistics.live_directories);
    }
}

test "stable slots isolate retained loop versions and reentrant storage branches" {
    var store = try Slots.init(testing.allocator);
    defer store.deinit();
    const original = try store.create(4096);
    try store.set(original, 0, 10);
    try store.set(original, 2000, 20);
    const first = try store.fork(original);
    try store.set(first, 0, 11);
    const reentrant = try store.fork(original);
    try store.set(reentrant, 2000, 21);
    try testing.expectEqual(10, try store.get(original, 0));
    try testing.expectEqual(20, try store.get(original, 2000));
    try testing.expectEqual(11, try store.get(first, 0));
    try testing.expectEqual(20, try store.get(first, 2000));
    try testing.expectEqual(10, try store.get(reentrant, 0));
    try testing.expectEqual(21, try store.get(reentrant, 2000));
    try store.clear(first, 2000);
    try testing.expectError(error.UninitializedSlot, store.get(first, 2000));
    try testing.expectEqual(20, try store.get(original, 2000));
}

test "stable slots reclaim large dead backing around a tiny surviving view" {
    var store = try Slots.init(testing.allocator);
    defer store.deinit();
    const view = try store.create(4096);
    for (0..4096) |index| try store.set(view, index, index);
    try testing.expectEqual(256, store.statistics.live_pages);
    const large_capacity = store.retainedBytes();
    try store.retainOnly(view, &.{4001});
    try testing.expectEqual(1, store.statistics.live_pages);
    try testing.expect(store.statistics.live_directories <= 2);
    try testing.expect(store.retainedBytes() < large_capacity / 8);
    try testing.expectEqual(4001, try store.get(view, 4001));
    try testing.expectError(error.UninitializedSlot, store.get(view, 4000));
    var iterator = try store.iterator(view);
    try testing.expectEqual(@as(usize, 4001), (try iterator.next()).?.slot);
    try testing.expect(try iterator.next() == null);
}

test "stable slots iterate logical bindings independently of allocation order" {
    var store = try Slots.init(testing.allocator);
    defer store.deinit();
    const left = try store.create(10000);
    const right = try store.create(10000);
    const indices = [_]usize{ 0, 17, 150, 257, 9999 };
    for (indices) |index| try store.set(left, index, index * 3);
    var count = indices.len;
    while (count != 0) {
        count -= 1;
        try store.set(right, indices[count], indices[count] * 3);
    }
    var a = try store.iterator(left);
    var b = try store.iterator(right);
    for (indices) |index| {
        const x = (try a.next()).?;
        const y = (try b.next()).?;
        try testing.expectEqual(index, x.slot);
        try testing.expectEqualDeep(x, y);
    }
    try testing.expect(try a.next() == null and try b.next() == null);
    try store.set(left, 0, 9);
    try testing.expectError(error.StaleIterator, a.next());
}

test "stable slots reject stale and foreign handles and invalid selections" {
    var a = try Slots.init(testing.allocator);
    defer a.deinit();
    var b = try Slots.init(testing.allocator);
    defer b.deinit();
    const dead = try a.create(32);
    try a.release(dead);
    const current = try a.create(32);
    try testing.expectEqual(dead.index, current.index);
    try testing.expectError(error.InvalidHandle, a.get(dead, 0));
    try testing.expectError(error.InvalidHandle, a.release(dead));
    try testing.expectError(error.InvalidHandle, b.get(current, 0));
    try testing.expectError(error.InvalidSlot, a.set(current, 32, 8));
    try a.set(current, 2, 7);
    try testing.expectError(error.InvalidSelection, a.retainOnly(current, &.{ 2, 2 }));
    try testing.expectEqual(7, try a.get(current, 2));
    const empty = try a.create(0);
    try testing.expectError(error.InvalidSlot, a.get(empty, 0));
}

test "stable slots publish or discard tentative roots without changing prior views" {
    var store = try Slots.init(testing.allocator);
    defer store.deinit();
    const view = try store.create(64);
    try store.set(view, 7, 1);
    const rollback = try store.fork(view);
    try store.set(rollback, 7, 2);
    try store.release(rollback);
    try testing.expectEqual(1, try store.get(view, 7));
    const successor = try store.fork(view);
    try store.set(successor, 7, 3);
    try store.commit(view, successor);
    try testing.expectEqual(3, try store.get(view, 7));
    try testing.expectError(error.InvalidHandle, store.get(successor, 7));
}

fn failedWrite(allocator: std.mem.Allocator) !void {
    var store = try Slots.init(allocator);
    defer store.deinit();
    const view = try store.create(4096);
    try store.set(view, 0, 1);
    try store.set(view, 4095, 2);
    const retained = try store.fork(view);
    const pages = store.statistics.live_pages;
    const directories = store.statistics.live_directories;
    store.set(view, 4095, 3) catch |err| {
        try testing.expectEqual(2, try store.get(view, 4095));
        try testing.expectEqual(2, try store.get(retained, 4095));
        try testing.expectEqual(pages, store.statistics.live_pages);
        try testing.expectEqual(directories, store.statistics.live_directories);
        return err;
    };
    try testing.expectEqual(3, try store.get(view, 4095));
    try testing.expectEqual(2, try store.get(retained, 4095));
}

fn failedTrim(allocator: std.mem.Allocator) !void {
    var store = try Slots.init(allocator);
    defer store.deinit();
    const view = try store.create(4096);
    try store.set(view, 0, 11);
    try store.set(view, 4095, 22);
    const pages = store.statistics.live_pages;
    store.retainOnly(view, &.{4095}) catch |err| {
        try testing.expectEqual(11, try store.get(view, 0));
        try testing.expectEqual(22, try store.get(view, 4095));
        try testing.expectEqual(pages, store.statistics.live_pages);
        return err;
    };
    try testing.expectError(error.UninitializedSlot, store.get(view, 0));
    try testing.expectEqual(22, try store.get(view, 4095));
}

test "stable slots preserve entry roots at every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, failedWrite, .{});
    try testing.checkAllAllocationFailures(testing.allocator, failedTrim, .{});
}

test "stable slots preserve an actual outer mutable cell across retained views" {
    var heap: @import("store.zig").Store = .{ .allocator = testing.allocator };
    defer heap.deinit();
    const region = try heap.add(.{ .region = .{
        .descriptor = 0,
        .outer = null,
        .obligations = &.{},
    } });
    const cell = try heap.add(.{ .cell = .{
        .schema = 1,
        .region = region,
        .value = .{ .schema = 0, .body = .{ .scalar = @splat(1) } },
    } });
    var store = try slots.ActivationSlots.init(testing.allocator);
    defer store.deinit();
    const view = try store.create(32);
    try store.set(view, 0, .{ .schema = 1, .body = .{ .reference = cell } });
    const retained = try store.fork(view);
    try store.set(view, 1, .{ .schema = 0, .body = .{ .scalar = @splat(0) } });
    var changed = (try heap.get(cell)).cell;
    changed.value = .{ .schema = 0, .body = .{ .scalar = @splat(9) } };
    try heap.replace(cell, .{ .cell = changed });
    const saved = (try store.get(retained, 0)).body.reference;
    const active = (try store.get(view, 0)).body.reference;
    try testing.expectEqual(cell.id, saved.id);
    try testing.expectEqual(cell.id, active.id);
    try testing.expectEqual(9, (try heap.get(saved)).cell.value.?.body.scalar[0]);
    try testing.expectEqual(1, store.statistics.value_copies);
}

test "existing Kosmos value operations read stable slots without full-frame materialization" {
    const data = @import("horos_data");
    const Values = @import("values.zig").Values;
    const schemas = [_]data.program.Schema{
        .u64, .{ .product = &.{ 0, 0 } }, .{ .bounded_bytes = 64 },
    };
    var heap: @import("store.zig").Store = .{ .allocator = testing.allocator };
    defer heap.deinit();
    var temporary = std.heap.ArenaAllocator.init(testing.allocator);
    defer temporary.deinit();
    var values: Values = .{
        .allocator = temporary.allocator(),
        .schemas = &schemas,
        .store = &heap,
    };
    var store = try slots.ActivationSlots.init(testing.allocator);
    defer store.deinit();
    const view = try store.create(2048);
    try store.set(view, 11, Values.natural(0, 7));
    try store.set(view, 1031, Values.natural(0, 42));
    const reader = try store.reader(view);
    const product = try values.evaluate(.{
        .opcode = .product,
        .destination = 0,
        .operands = &.{ 11, 1031 },
    }, 1, reader);
    try store.set(view, 2047, product);
    const field = try values.evaluate(.{
        .opcode = .field,
        .destination = 0,
        .operands = &.{2047},
        .immediate = 1,
    }, 0, reader);
    try testing.expectEqual(42, std.mem.readInt(u64, &field.body.scalar, .little));
    try testing.expectEqualSlices(u8, &.{ 7, 0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 0, 0, 0, 0 }, try values.bytes(&product));
    try store.set(view, 3, try heap.literal(&schemas, .{ .schema = 2, .bytes = &.{ 1, 'a' } }));
    try store.set(view, 1900, try heap.literal(&schemas, .{ .schema = 2, .bytes = &.{ 1, 'b' } }));
    const result = try @import("blobs.zig").evaluate(&values, .{
        .opcode = .blob_concat,
        .destination = 0,
        .operands = &.{ 3, 1900 },
    }, 2, reader);
    try testing.expectEqualSlices(u8, &.{ 2, 'a', 'b' }, try values.bytes(&result.value));
    try store.release(view);
    try testing.expectError(error.InvalidState, values.evaluate(.{
        .opcode = .field,
        .destination = 0,
        .operands = &.{2047},
    }, 0, reader));
}

test "stable slots match an independent flat model across mixed view lifecycles" {
    const count = 257;
    var store = try Slots.init(testing.allocator);
    defer store.deinit();
    var handles: [8]?Slots.Handle = @splat(null);
    var model: [8][count]?u64 = @splat(@splat(null));
    handles[0] = try store.create(count);
    var random_state = std.Random.DefaultPrng.init(0xb3_6001);
    const random = random_state.random();
    for (0..600) |step| {
        var index = random.uintLessThan(usize, handles.len);
        var searched: usize = 0;
        while (handles[index] == null and searched < handles.len) : (searched += 1)
            index = (index + 1) % handles.len;
        if (handles[index] == null) {
            handles[index] = try store.create(count);
            model[index] = @splat(null);
        }
        const handle = handles[index].?;
        const other = (index + 1) % handles.len;
        const slot = random.uintLessThan(usize, count);
        switch (random.uintLessThan(u8, 5)) {
            0 => {
                try store.set(handle, slot, step);
                model[index][slot] = step;
            },
            1 => {
                try store.clear(handle, slot);
                model[index][slot] = null;
            },
            2 => if (handles[other] == null) {
                handles[other] = try store.fork(handle);
                model[other] = model[index];
            },
            3 => if (handles[other]) |candidate| {
                try store.commit(handle, candidate);
                model[index] = model[other];
                handles[other] = null;
            },
            4 => if (index != 0) {
                try store.release(handle);
                handles[index] = null;
            },
            else => unreachable,
        }
        for (handles, model) |present, expected| {
            const current = present orelse continue;
            var iterator = try store.iterator(current);
            for (expected, 0..) |value, position| {
                if (value) |known| {
                    try testing.expectEqual(known, try store.get(current, position));
                    const binding = (try iterator.next()).?;
                    try testing.expectEqual(position, binding.slot);
                    try testing.expectEqual(known, binding.value);
                } else try testing.expectError(error.UninitializedSlot, store.get(current, position));
            }
            try testing.expect(try iterator.next() == null);
        }
    }
    for (handles) |present| if (present) |handle| try store.release(handle);
    try testing.expectEqual(0, store.statistics.live_pages);
    try testing.expectEqual(0, store.statistics.live_directories);
}

test "unshared sparse insertion preserves existing directory prefixes" {
    var store = try Slots.init(testing.allocator);
    defer store.deinit();
    const view = try store.create(4096);
    for ([_]usize{ 0, 16, 256, 4095 }) |slot| try store.set(view, slot, slot + 1);
    try testing.expectEqual(0, store.statistics.directory_copies);
    try testing.expectEqual(0, store.statistics.value_copies);
    for ([_]usize{ 0, 16, 256, 4095 }) |slot|
        try testing.expectEqual(slot + 1, try store.get(view, slot));
}

fn failedSharedSuffix(allocator: std.mem.Allocator) !void {
    var store = try Slots.init(allocator);
    defer store.deinit();
    const view = try store.create(4096);
    try store.set(view, 0, 11);
    try store.set(view, 16, 22);
    const retained = try store.fork(view);
    // Copy the root while its original low subtree remains shared.
    try store.set(view, 256, 33);
    const pages = store.statistics.live_pages;
    const directories = store.statistics.live_directories;
    var before = try store.iterator(view);
    store.set(view, 16, 44) catch |err| {
        try testing.expectEqual(11, (try before.next()).?.value);
        try testing.expectEqual(22, (try before.next()).?.value);
        try testing.expectEqual(33, (try before.next()).?.value);
        try testing.expect(try before.next() == null);
        try testing.expectEqual(22, try store.get(retained, 16));
        try testing.expectEqual(pages, store.statistics.live_pages);
        try testing.expectEqual(directories, store.statistics.live_directories);
        return err;
    };
    try testing.expectEqual(44, try store.get(view, 16));
    try testing.expectEqual(22, try store.get(retained, 16));
    try testing.expectError(error.UninitializedSlot, store.get(retained, 256));
    try testing.expectError(error.StaleIterator, before.next());
}

test "shared suffix allocation failures leave unique prefixes and retained views unchanged" {
    try testing.checkAllAllocationFailures(testing.allocator, failedSharedSuffix, .{});
}

test "frame batch writes derive initialization from values rather than liveness bounds" {
    for ([_]usize{ 4, 65, 256 }) |count| {
        try batchFrame(testing.allocator, count);
        try testing.checkAllAllocationFailures(testing.allocator, batchFrame, .{count});
    }
}

fn batchFrame(allocator: std.mem.Allocator, count: usize) !void {
    const data = @import("horos_data");
    const Frames = @import("activation_frames.zig").Frames;
    const Values = @import("values.zig").Values;
    var pool: data.analysis_sets.Pool = .{ .allocator = allocator, .limit = count };
    defer pool.deinit();
    const layout = try allocator.alloc(data.program.Id, count);
    defer allocator.free(layout);
    @memset(layout, 0);
    const last = count - 1;
    const program: data.activation.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{.u64},
        .constants = &.{},
        .effects = &.{},
        .blocks = &.{},
        .functions = &.{.{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = layout }, .result = 0 }},
    };
    var frame_layouts = try @import("frame_layouts.zig").Layouts.init(allocator, program.functions);
    defer frame_layouts.deinit();
    var frames = try Frames.init(allocator, &pool, &frame_layouts);
    defer frames.deinit();
    var original = try frames.create(0);
    defer frames.releaseFrame(original);
    try frames.apply(&original, try pool.run(0, last), @as([]const data.program.Id, &.{ 0, last }), &.{ Values.natural(0, 42), Values.natural(0, 99) });
    try testing.expectEqual(42, (try frames.slots.get(original.view, 0)).body.scalar[0]);
    for ([_]usize{ 1, 2, last }) |slot|
        try testing.expectError(error.UninitializedSlot, frames.slots.get(original.view, slot));
    var next = try frames.forkFrame(original);
    defer frames.releaseFrame(next);
    frames.apply(&next, try pool.run(1, last), @as([]const data.program.Id, &.{1}), &.{Values.natural(0, 7)}) catch |err| {
        try testing.expectEqual(42, (try frames.slots.get(original.view, 0)).body.scalar[0]);
        try testing.expectError(error.UninitializedSlot, frames.slots.get(original.view, 1));
        return err;
    };
    try testing.expectEqual(7, (try frames.slots.get(next.view, 1)).body.scalar[0]);
    try testing.expectError(error.UninitializedSlot, frames.slots.get(next.view, 0));
    try testing.expectError(error.UninitializedSlot, frames.slots.get(next.view, 2));
    try testing.expectEqual(42, (try frames.slots.get(original.view, 0)).body.scalar[0]);
    var bindings = try frames.slots.iterator(next.view);
    try testing.expectEqual(1, (try bindings.next()).?.slot);
    try testing.expect((try bindings.next()) == null);
}

test "tail restart clears old locals and preserves retained input permutations on allocation failure" {
    for ([_]usize{ 4, 65, 256 }) |count| for ([_]u64{ 0, 1 }) |target| {
        try restartFrame(testing.allocator, count, target);
        try testing.checkAllAllocationFailures(testing.allocator, restartFrame, .{ count, target });
    };
}

fn restartFrame(allocator: std.mem.Allocator, count: usize, target: u64) !void {
    const data = @import("horos_data");
    const Frames = @import("activation_frames.zig").Frames;
    const Values = @import("values.zig").Values;
    var pool: data.analysis_sets.Pool = .{ .allocator = allocator, .limit = count };
    defer pool.deinit();
    const layout = try allocator.alloc(data.program.Id, count);
    defer allocator.free(layout);
    @memset(layout, 0);
    const program: data.activation.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{.u64},
        .constants = &.{},
        .effects = &.{},
        .blocks = &.{},
        .functions = &.{
            .{ .entry = 0, .inputs = &.{ 0, 1 }, .layout = .{ .slots = layout }, .result = 0 },
            .{ .entry = 0, .inputs = &.{ 0, 1 }, .layout = .{ .slots = layout }, .result = 0 },
        },
    };
    var frame_layouts = try @import("frame_layouts.zig").Layouts.init(allocator, program.functions);
    defer frame_layouts.deinit();
    var frames = try Frames.init(allocator, &pool, &frame_layouts);
    defer frames.deinit();
    var original = try frames.create(0);
    defer frames.releaseFrame(original);
    try frames.write(&original, 0, Values.natural(0, 10));
    try frames.write(&original, 1, Values.natural(0, 20));
    try frames.write(&original, count - 1, Values.natural(0, 99));
    var next = try frames.forkFrame(original);
    defer frames.releaseFrame(next);
    next.position = 3;
    const arguments = [_]data.graph.Value{ try frames.slots.get(next.view, 1), try frames.slots.get(next.view, 0) };
    frames.restart(&next, target, try pool.run(0, 2), &arguments) catch |err| {
        try testing.expectEqual(10, (try frames.slots.get(original.view, 0)).body.scalar[0]);
        try testing.expectEqual(99, (try frames.slots.get(original.view, count - 1)).body.scalar[0]);
        return err;
    };
    try testing.expectEqual(0, next.position);
    try testing.expectEqual(target, next.function);
    try testing.expectEqual(20, (try frames.slots.get(next.view, 0)).body.scalar[0]);
    try testing.expectEqual(10, (try frames.slots.get(next.view, 1)).body.scalar[0]);
    try testing.expectError(error.UninitializedSlot, frames.slots.get(next.view, count - 1));
    try testing.expectEqual(10, (try frames.slots.get(original.view, 0)).body.scalar[0]);
    try testing.expectEqual(20, (try frames.slots.get(original.view, 1)).body.scalar[0]);
    try testing.expectEqual(99, (try frames.slots.get(original.view, count - 1)).body.scalar[0]);
}

test "cross-function restart rejects incompatible schemas capacity and active custody" {
    const data = @import("horos_data");
    const Frames = @import("activation_frames.zig").Frames;
    var pool: data.analysis_sets.Pool = .{ .allocator = testing.allocator, .limit = 3 };
    defer pool.deinit();
    const program: data.activation.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{ .u64, .u8 },
        .constants = &.{},
        .effects = &.{},
        .blocks = &.{},
        .functions = &.{
            .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0 } }, .result = 0 },
            .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0 } }, .result = 0 },
            .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 1 } }, .result = 0 },
            .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0, 0 } }, .result = 0 },
            .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0 } }, .result = 0, .custody = &.{ .{}, .{ .parent = 0 } } },
        },
    };
    var frame_layouts = try @import("frame_layouts.zig").Layouts.init(testing.allocator, program.functions);
    defer frame_layouts.deinit();
    var frames = try Frames.init(testing.allocator, &pool, &frame_layouts);
    defer frames.deinit();
    var frame = try frames.create(0);
    defer frames.releaseFrame(frame);
    try testing.expect(frames.canRestart(frame, 1));
    for ([_]u64{ 2, 3, 4, 99 }) |target| {
        try testing.expect(!frames.canRestart(frame, target));
        try testing.expectError(error.InvalidState, frames.restart(&frame, target, data.analysis_sets.empty, &.{}));
        try testing.expectEqual(0, frame.function);
    }
    // The gate is deliberately independent of the number of current owners.
    // Once custody has been initialized this shortcut cannot reset its history.
    frame.custody.initialized = true;
    try testing.expect(!frames.canRestart(frame, 0));
    try testing.expect(!frames.canRestart(frame, 1));
    frame.custody.initialized = false;
}

test "retired views recycle without allocation and never revive stale handles" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store = try Slots.init(failing.allocator());
    defer store.deinit();
    var old: [32]Slots.Handle = undefined;
    for (&old, 0..) |*handle, i| handle.* = try store.create(i + 1);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    for (old) |handle| try store.release(handle);
    var reused: [32]Slots.Handle = undefined;
    for (old, 0..) |handle, i| {
        const next = try store.create(100 + i);
        reused[i] = next;
        try testing.expectEqual(old[old.len - i - 1].index, next.index);
        try testing.expectEqual(100 + i, try store.lookupLimit(next));
        for (old) |stale| try testing.expectError(error.InvalidHandle, store.lookupLimit(stale));
        try testing.expectError(error.InvalidHandle, store.release(handle));
    }
    for (reused) |handle| try store.release(handle);
    try testing.expect(!failing.has_induced_failure);
}
