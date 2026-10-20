const std = @import("std");
const data = @import("horos_data");
const Frames = @import("activation_frames.zig").Frames;
const Frame = @import("activation_frames.zig").Frame;
const Layouts = @import("frame_layouts.zig").Layouts;
const Values = @import("values.zig").Values;
const testing = std.testing;

// Adapted from PR #60, 750f8ec74f909735c96992eb05bfe0c22904526e:
// "direct slot roots and later frame protection share the entry version".
test "direct slot roots and later frame protection share the entry version" {
    for ([_]bool{ false, true }) |before_begin| {
        var c: Context = undefined;
        try c.init(testing.allocator, 65);
        defer c.deinit();
        try c.insert(0, 42);
        var initial = try c.frames.get(0);
        try c.frames.write(&initial, 64, Values.natural(0, 99));
        const before = try c.frames.forkFrame(try c.frames.get(0));
        defer c.frames.releaseFrame(before);
        const descriptor = if (before_begin) try c.frames.get(0) else null;
        try c.frames.begin(1);
        const view = (descriptor orelse try c.frames.get(0)).view;
        try c.frames.slots.set(view, 0, Values.natural(0, 100));
        const during = try c.frames.forkFrame(try c.frames.get(0));
        defer c.frames.releaseFrame(during);
        try c.frames.slots.set(during.view, 0, Values.natural(0, 33));
        try c.frames.slots.clear(view, 64);
        const raw = try c.frames.getMutable(0);
        raw.position = 19;
        try c.frames.write(raw, 1, Values.natural(0, 200));
        try c.frames.remove(0);
        try c.insert(0, 255);
        c.frames.rollback(1);
        try testing.expectEqual(0, (try c.frames.get(0)).position);
        try testing.expectEqual(42, try c.value(0, 0));
        try testing.expectEqual(99, try c.value(0, 64));
        try testing.expectError(error.UninitializedSlot, c.value(0, 1));
        try testing.expectEqual(42, (try c.frames.slots.get(before.view, 0)).body.scalar[0]);
        try testing.expectEqual(33, (try c.frames.slots.get(during.view, 0)).body.scalar[0]);
        try testing.expectEqual(1, c.frames.statistics.saved_entries);
    }
}

// Same allocation-disabled rollback/iterator discriminator as PR #60's
// "direct slot rollback restores without allocation and invalidates both
// iterator versions". #61 restores the saved frame's handle, so the retired
// predecessor reports InvalidHandle (also W0's behavior), not StaleIterator.
test "direct slot rollback restores without allocation and retires iterator handles" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var c: Context = undefined;
    try c.init(failing.allocator(), 1);
    defer c.deinit();
    try c.insert(0, 42);
    const frame = try c.frames.get(0);
    var old_iterator = try c.frames.slots.iterator(frame.view);
    try c.frames.begin(1);
    try c.frames.slots.set(frame.view, 0, Values.natural(0, 100));
    var tentative_iterator = try c.frames.slots.iterator(frame.view);
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    failing.resize_fail_index = failing.resize_index;
    c.frames.rollback(1);
    try testing.expectEqual(allocations, failing.alloc_index);
    try testing.expectEqual(42, try c.value(0, 0));
    try testing.expectError(error.InvalidHandle, old_iterator.next());
    try testing.expectError(error.InvalidHandle, tentative_iterator.next());
}

test "all direct slot root publications preserve the entry version" {
    const Operation = enum { clear, retain_only, commit };
    inline for (std.meta.tags(Operation)) |operation| {
        var c: Context = undefined;
        try c.init(testing.allocator, 65);
        defer c.deinit();
        try c.insert(0, 42);
        const frame = try c.frames.get(0);
        try c.frames.begin(1);
        switch (operation) {
            .clear => try c.frames.slots.clear(frame.view, 0),
            .retain_only => try c.frames.slots.retainOnly(frame.view, &.{}),
            .commit => {
                const candidate = try c.frames.slots.fork(frame.view);
                try c.frames.slots.set(candidate, 0, Values.natural(0, 99));
                try c.frames.slots.commit(frame.view, candidate);
            },
        }
        c.frames.rollback(1);
        try testing.expectEqual(42, try c.value(0, 0));
        try testing.expectEqual(1, c.frames.statistics.saved_entries);
    }
}

test "direct custody mutations join the same frame entry journal" {
    const scopes = [_]data.activation.CustodyScope{.{}};
    var c: Context = undefined;
    try c.init(testing.allocator, 65);
    defer c.deinit();
    c.functions[0].custody = &scopes;
    var initial = try c.frames.create(0);
    try c.frames.write(&initial, 0, Values.natural(0, 42));
    try c.frames.custody.establish(&initial.custody, &scopes, 0);
    try c.frames.put(0, initial);
    const entry = try c.frames.custody.project(initial.custody, testing.allocator);
    defer testing.allocator.free(entry);
    try c.frames.begin(1);
    var copy = try c.frames.get(0);
    try c.frames.custody.remove(&copy.custody, 0);
    try c.frames.custody.establish(&copy.custody, &scopes, 64);
    try c.frames.slots.set(copy.view, 0, Values.natural(0, 99));
    (try c.frames.getMutable(0)).position = 12;
    c.frames.rollback(1);
    const restored = try c.frames.get(0);
    const actual = try c.frames.custody.project(restored.custody, testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualDeep(entry, actual);
    try testing.expectEqual(42, try c.value(0, 0));
    try testing.expectEqual(0, restored.position);
    try testing.expectEqual(1, c.frames.statistics.saved_entries);
}

// PR #60, 750f8ec: "copied mutable and read views survive map growth
// without bypassing rollback". The direct-root spelling exercises #61's cut.
test "copied direct slot descriptor survives map and view table growth" {
    var c: Context = undefined;
    try c.init(testing.allocator, 1);
    defer c.deinit();
    try c.insert(0, 42);
    const copied = try c.frames.get(0);
    for (1..1024) |id| try c.insert(id, id);
    try c.frames.begin(1024);
    try c.frames.slots.set(copied.view, 0, Values.natural(0, 100));
    c.frames.rollback(1024);
    try testing.expectEqual(42, try c.value(0, 0));
    for (1..1024) |id| try testing.expectEqual(id, try c.value(id, 0));
    try testing.expectEqual(1, c.frames.statistics.saved_entries);
}

test "removal retires borrowed slot and custody handles before journal ownership" {
    for (0..4) |exhausted| {
        var c: Context = undefined;
        try c.init(testing.allocator, 4);
        defer c.deinit();
        try c.insert(0, 42);
        if (exhausted & 1 != 0) {
            const entry = c.frames.entries.getPtr(0).?;
            entry.view.generation = std.math.maxInt(u64);
            c.frames.slots.views.items[entry.view.index].generation = entry.view.generation;
        }
        if (exhausted & 2 != 0) {
            const entry = c.frames.entries.getPtr(0).?;
            entry.custody.view.generation = std.math.maxInt(u64);
            c.frames.custody.nodes.views.items[entry.custody.view.index].generation =
                entry.custody.view.generation;
        }
        const descriptor = try c.frames.get(0);
        var iterator = try c.frames.slots.iterator(descriptor.view);
        const independent = try c.frames.forkFrame(descriptor);
        defer c.frames.releaseFrame(independent);
        try c.frames.begin(1);
        defer if (c.frames.journal != null) c.frames.rollback(1);
        try c.frames.remove(0);
        try testing.expectError(error.InvalidHandle, c.frames.slots.get(descriptor.view, 0));
        try testing.expectError(error.InvalidHandle, c.frames.slots.set(
            descriptor.view,
            0,
            Values.natural(0, 99),
        ));
        try testing.expectError(error.InvalidHandle, c.frames.slots.clear(descriptor.view, 1));
        try testing.expectError(
            error.InvalidHandle,
            c.frames.slots.retainOnly(descriptor.view, &.{}),
        );
        try testing.expectError(
            error.InvalidHandle,
            c.frames.custody.nodes.clear(descriptor.custody.view, 0),
        );
        try testing.expectError(error.InvalidHandle, iterator.next());
        try c.insert(0, 100);
        try c.frames.slots.set(independent.view, 0, Values.natural(0, 33));
        c.frames.rollback(1);
        try testing.expectEqual(42, try c.value(0, 0));
        try testing.expectError(error.InvalidHandle, c.frames.slots.get(descriptor.view, 0));
        try testing.expectEqual(33, (try c.frames.slots.get(independent.view, 0)).body.scalar[0]);
    }
}

test "direct first touch allocation failure rolls back and retries without history" {
    for ([_]usize{ 1, 65, 1024 }) |width| {
        var saw_failure = false;
        for (0..16) |offset| {
            var failing = testing.FailingAllocator.init(testing.allocator, .{});
            var c: Context = undefined;
            try c.init(failing.allocator(), width);
            defer c.deinit();
            for (0..3) |id| try c.insert(id, 42 + id);
            try c.frames.begin(3);
            failing.fail_index = failing.alloc_index + offset;
            failing.resize_fail_index = failing.resize_index;
            for (0..3) |id| {
                const frame = try c.frames.get(id);
                c.frames.slots.set(frame.view, width - 1, Values.natural(0, 99)) catch |err| {
                    try testing.expectEqual(error.OutOfMemory, err);
                    saw_failure = true;
                    break;
                };
            }
            const allocations = failing.alloc_index;
            failing.fail_index = allocations;
            failing.resize_fail_index = failing.resize_index;
            c.frames.rollback(3);
            try testing.expectEqual(allocations, failing.alloc_index);
            for (0..3) |id| try testing.expectEqual(42 + id, try c.value(id, 0));
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            var plateau: ?usize = null;
            for (0..32) |cycle| {
                try c.frames.begin(3);
                const frame = try c.frames.get(0);
                try c.frames.slots.set(frame.view, width - 1, Values.natural(0, 99));
                if (cycle % 2 == 0) c.frames.rollback(3) else c.frames.commit();
                if (cycle > 2) {
                    const live = c.frames.slots.retainedBytes() +
                        c.frames.custody.nodes.retainedBytes();
                    if (plateau) |bound| try testing.expect(live <= bound) else plateau = live;
                }
                try testing.expect(c.frames.journal == null);
                try testing.expect(c.frames.slots.before_mutation == null);
                try testing.expect(c.frames.custody.nodes.before_mutation == null);
            }
        }
        try testing.expect(saw_failure);
    }
}

const Context = struct {
    allocator: std.mem.Allocator,
    pool: data.analysis_sets.Pool,
    slots: []data.program.Id,
    functions: [1]data.activation.Function,
    layouts: Layouts,
    frames: Frames,

    fn init(self: *Context, allocator: std.mem.Allocator, width: usize) !void {
        self.allocator = allocator;
        self.pool = .{ .allocator = allocator, .limit = width };
        errdefer self.pool.deinit();
        self.slots = try allocator.alloc(data.program.Id, width);
        errdefer allocator.free(self.slots);
        @memset(self.slots, 0);
        self.functions = .{.{
            .entry = 0,
            .inputs = &.{0},
            .layout = .{ .slots = self.slots },
            .result = 0,
        }};
        self.layouts = try Layouts.init(allocator, &self.functions);
        errdefer self.layouts.deinit();
        self.frames = try Frames.init(allocator, &self.pool, &self.layouts);
    }
    fn deinit(self: *Context) void {
        self.frames.deinit();
        self.layouts.deinit();
        self.allocator.free(self.slots);
        self.pool.deinit();
    }
    fn insert(self: *Context, id: u64, number: u64) !void {
        var frame = try self.frames.create(0);
        errdefer self.frames.releaseFrame(frame);
        try self.frames.write(&frame, 0, Values.natural(0, number));
        try self.frames.put(id, frame);
    }
    fn value(self: *Context, id: u64, slot: usize) !u64 {
        const frame = try self.frames.get(id);
        const item = try self.frames.slots.get(frame.view, slot);
        return std.mem.readInt(u64, item.body.scalar[0..8], .little);
    }
};

test "frame transaction setup and commit visit only acquired entries" {
    for ([_]usize{ 1, 7, 16, 31, 63, 64, 65, 256, 257, 1024 }) |count| {
        var c: Context = undefined;
        try c.init(testing.allocator, 65);
        defer c.deinit();
        for (0..count) |id| try c.insert(id, id + 10);
        for (0..count) |id| _ = try c.frames.get(id);
        try c.frames.begin(count);
        for (0..count) |id| _ = try c.frames.get(id);
        try testing.expectEqual(0, c.frames.statistics.saved_entries);
        const frame = try c.frames.getMutable(0);
        try c.frames.write(frame, 0, Values.natural(0, 20));
        try c.frames.write(try c.frames.getMutable(0), 64, Values.natural(0, 30));
        try testing.expectEqual(1, c.frames.statistics.saved_entries);
        try testing.expectEqual(1, c.frames.statistics.forked_frames);
        c.frames.commit();
        try testing.expectEqual(1, c.frames.statistics.commit_entries);
        try testing.expectEqual(20, try c.value(0, 0));
        try testing.expectEqual(30, try c.value(0, 64));
        for (1..count) |id| try testing.expectEqual(id + 10, try c.value(id, 0));
    }
}

test "mutable map borrows survive begin and commit with entry-time protection" {
    var c: Context = undefined;
    try c.init(testing.allocator, 65);
    defer c.deinit();
    for (0..257) |id| try c.insert(id, id + 10);
    const first = try c.frames.getMutable(0);
    const second = try c.frames.getMutable(1);
    _ = try c.frames.getMutable(0); // Reacquisition must not duplicate the list.
    try c.frames.write(first, 0, Values.natural(0, 15));
    try c.frames.begin(257);
    try testing.expectEqual(2, c.frames.statistics.borrowed_entries);
    try testing.expectEqual(2, c.frames.statistics.saved_entries);
    try c.frames.write(first, 0, Values.natural(0, 20));
    second.position = 7; // A raw metadata write through the supported borrow.
    c.frames.commit();
    // Commit does not mutate the map and cannot invalidate either pointer.
    try c.frames.begin(257);
    try testing.expectEqual(4, c.frames.statistics.borrowed_entries);
    try c.frames.write(first, 0, Values.natural(0, 30));
    second.position = 9;
    c.frames.rollback(257);
    try testing.expectEqual(20, try c.value(0, 0));
    try testing.expectEqual(7, (try c.frames.get(1)).position);
    try testing.expectEqual(null, c.frames.borrowed);
    for (2..257) |id| try testing.expectEqual(id + 10, try c.value(id, 0));
}

test "copied read descriptors acquire protection at each sanctioned mutation" {
    const Operation = enum { write, clear, apply, prune, restart };
    for ([_]bool{ false, true }) |before_begin| inline for (std.meta.tags(Operation)) |operation| {
        var c: Context = undefined;
        try c.init(testing.allocator, 65);
        defer c.deinit();
        try c.insert(0, 10);
        const live = try c.pool.insert(data.analysis_sets.empty, 0);
        var frame: Frame = if (before_begin) try c.frames.get(0) else undefined;
        try c.frames.begin(1);
        if (!before_begin) frame = try c.frames.get(0);
        try testing.expectEqual(0, c.frames.statistics.saved_entries);
        switch (operation) {
            .write => try c.frames.write(&frame, 0, Values.natural(0, 20)),
            .clear => try c.frames.clear(&frame, 0),
            .apply => try c.frames.apply(&frame, live, &[_]u64{0}, &.{Values.natural(0, 20)}),
            .prune => try c.frames.prune(&frame, data.analysis_sets.empty),
            .restart => try c.frames.restart(&frame, 0, live, &.{Values.natural(0, 20)}),
        }
        try testing.expectEqual(1, c.frames.statistics.saved_entries);
        c.frames.rollback(1);
        try testing.expectEqual(10, try c.value(0, 0));
        try testing.expectEqual(0, (try c.frames.get(0)).position);
    };
}

fn borrowedBeginFailure(allocator: std.mem.Allocator) !void {
    var c: Context = undefined;
    try c.init(allocator, 65);
    defer c.deinit();
    try c.insert(0, 10);
    while (c.frames.slots.views.items.len < c.frames.slots.views.capacity)
        try c.insert(c.frames.entries.count(), 11);
    const count = c.frames.entries.count();
    const first = try c.frames.getMutable(0);
    const second = try c.frames.getMutable(1);
    c.frames.begin(count) catch |err| {
        try testing.expectEqual(null, c.frames.journal);
        try testing.expect(c.frames.borrowed != null);
        try testing.expectEqual(0, first.position);
        try testing.expectEqual(0, second.position);
        try testing.expectEqual(10, try c.value(0, 0));
        try testing.expectEqual(11, try c.value(1, 0));
        return err;
    };
    first.position = 9;
    second.position = 10;
    c.frames.rollback(count);
    try testing.expectEqual(0, (try c.frames.get(0)).position);
    try testing.expectEqual(0, (try c.frames.get(1)).position);
}

test "failure protecting preexisting borrows leaves begin unpublished" {
    try testing.checkAllAllocationFailures(testing.allocator, borrowedBeginFailure, .{});
}

test "failed borrowed begin retries with the latest entry and no stale pointer list" {
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    var c: Context = undefined;
    try c.init(counting.allocator(), 65);
    defer c.deinit();
    try c.insert(0, 10);
    // Protection must grow a view table even when the first journal entry
    // needs no allocation of its own.
    while (c.frames.slots.views.items.len < c.frames.slots.views.capacity)
        try c.insert(c.frames.entries.count(), 11);
    const count = c.frames.entries.count();
    const frame = try c.frames.getMutable(0);
    counting.fail_index = counting.alloc_index;
    try testing.expectError(error.OutOfMemory, c.frames.begin(count));
    try testing.expectEqual(null, c.frames.journal);
    counting.fail_index = std.math.maxInt(usize);
    try c.frames.write(frame, 0, Values.natural(0, 15));
    try c.frames.begin(count);
    try c.frames.write(frame, 0, Values.natural(0, 20));
    const allocations = counting.allocations;
    counting.fail_index = counting.alloc_index;
    c.frames.rollback(count);
    try testing.expectEqual(allocations, counting.allocations);
    try testing.expectEqual(15, try c.value(0, 0));
    counting.fail_index = std.math.maxInt(usize);
    _ = try c.frames.getMutable(0);
    try c.insert(count, 11); // Successful map mutation ends the documented borrow.
    try testing.expectEqual(null, c.frames.borrowed);
    try c.frames.begin(count + 1);
    try testing.expectEqual(null, c.frames.journal.?.first);
    try testing.expectEqual(0, c.frames.journal.?.entries.count());
    c.frames.commit();
}

test "independent semantic forks do not acquire their source frame" {
    var c: Context = undefined;
    try c.init(testing.allocator, 65);
    defer c.deinit();
    try c.insert(0, 10);
    var fork = try c.frames.forkFrame(try c.frames.get(0));
    defer c.frames.releaseFrame(fork);
    try c.frames.begin(1);
    try c.frames.write(&fork, 0, Values.natural(0, 20));
    try testing.expectEqual(0, c.frames.statistics.saved_entries);
    c.frames.commit();
    try testing.expectEqual(10, try c.value(0, 0));
    try testing.expectEqual(20, (try c.frames.slots.get(fork.view, 0)).body.scalar[0]);
}

test "first appended identity becomes an ordinary protected entry in the next transaction" {
    var c: Context = undefined;
    try c.init(testing.allocator, 65);
    defer c.deinit();
    try c.frames.begin(0);
    try c.insert(0, 10);
    try c.frames.write(try c.frames.getMutable(0), 0, Values.natural(0, 11));
    try testing.expectEqual(0, c.frames.statistics.saved_entries);
    c.frames.rollback(1);
    try testing.expectEqual(0, c.frames.entries.count());
    try c.insert(0, 20);
    try c.frames.begin(1);
    try c.frames.write(try c.frames.getMutable(0), 0, Values.natural(0, 21));
    try testing.expectEqual(1, c.frames.statistics.saved_entries);
    c.frames.rollback(1);
    try testing.expectEqual(20, try c.value(0, 0));
}

test "frame transaction restores membership through reuse and semantic forks without allocation" {
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    var c: Context = undefined;
    try c.init(counting.allocator(), 65);
    defer c.deinit();
    try c.insert(0, 10);
    try c.insert(1, 11);
    try c.insert(2, 12);
    const original = try c.frames.get(0);
    const semantic = try c.frames.forkFrame(original);
    defer c.frames.releaseFrame(semantic);
    try c.frames.begin(5);
    // Two writes must preserve the entry version and packed occupancy/rank.
    var changed = try c.frames.getForUpdate(0);
    try c.frames.write(&changed, 0, Values.natural(0, 20));
    try c.frames.write(&changed, 1, Values.natural(0, 21));
    try c.frames.write(&changed, 64, Values.natural(0, 22));
    changed.position = 42;
    changed.custody.scope = 7;
    try c.frames.update(0, changed);
    try c.frames.clear(try c.frames.getMutable(0), 0);
    try c.frames.remove(1); // Transfer untouched entry ownership.
    try c.insert(1, 90); // Reuse an entry identity.
    try c.insert(3, 33); // Reuse an entry-era Store hole.
    try c.frames.remove(3);
    try c.insert(3, 34);
    try c.frames.copyFrame(0, 5); // Fork during transaction, in appended range.
    try c.frames.write(try c.frames.getMutable(5), 1, Values.natural(0, 99));
    try testing.expectEqual(1, c.frames.statistics.moved_frames);
    // Rollback must not even ask for another allocation.
    const allocations = counting.allocations;
    counting.fail_index = counting.alloc_index;
    c.frames.rollback(6);
    try testing.expectEqual(allocations, counting.allocations);
    try testing.expect(!counting.has_induced_failure);
    try testing.expectEqual(3, c.frames.entries.count());
    try testing.expectEqual(10, try c.value(0, 0));
    try testing.expectEqual(11, try c.value(1, 0));
    try testing.expectEqual(12, try c.value(2, 0));
    const restored = try c.frames.get(0);
    try testing.expectEqual(0, restored.position);
    try testing.expectEqual(0, restored.custody.scope);
    try testing.expectError(error.UninitializedSlot, c.frames.slots.get(restored.view, 1));
    try testing.expectError(error.UninitializedSlot, c.frames.slots.get(restored.view, 64));
    try testing.expectEqual(10, (try c.frames.slots.get(semantic.view, 0)).body.scalar[0]);
    try testing.expectError(error.InvalidState, c.frames.get(3));
    try testing.expectError(error.InvalidState, c.frames.get(5));
}

fn mutate(c: *Context) !void {
    var frame = try c.frames.getForUpdate(0);
    try c.frames.write(&frame, 0, Values.natural(0, 90));
    try c.frames.write(&frame, 1, Values.natural(0, 91));
    try c.frames.write(&frame, 64, Values.natural(0, 92));
    frame.position = 9;
    try c.frames.update(0, frame);
    try c.frames.remove(1);
    try c.insert(1, 70);
    try c.insert(3, 71);
    try c.frames.copyFrame(0, 4);
    try c.frames.remove(4);
    try c.insert(4, 72);
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var c: Context = undefined;
    try c.init(allocator, 65);
    defer c.deinit();
    try c.insert(0, 10);
    try c.insert(1, 11);
    try c.frames.begin(4);
    mutate(&c) catch |err| {
        c.frames.rollback(5);
        try testing.expectEqual(2, c.frames.entries.count());
        try testing.expectEqual(10, try c.value(0, 0));
        try testing.expectEqual(11, try c.value(1, 0));
        try testing.expectEqual(0, (try c.frames.get(0)).position);
        return err;
    };
    c.frames.rollback(5);
    try testing.expectEqual(2, c.frames.entries.count());
    try testing.expectEqual(10, try c.value(0, 0));
    try testing.expectEqual(11, try c.value(1, 0));
}

test "every frame journal allocation failure preserves entry values and membership" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailure, .{});
}

fn protectionFailure(allocator: std.mem.Allocator, remove: bool) !void {
    var c: Context = undefined;
    try c.init(allocator, 65);
    defer c.deinit();
    try c.insert(0, 10);
    // Fill both view tables so first-touch protection must grow them. This
    // reaches failures after the slot fork but before the custody fork finishes.
    while (c.frames.slots.views.items.len < c.frames.slots.views.capacity)
        try c.insert(c.frames.entries.count(), 11);
    try testing.expectEqual(
        c.frames.custody.nodes.views.items.len,
        c.frames.custody.nodes.views.capacity,
    );
    const count = c.frames.entries.count();
    try c.frames.begin(count);
    // The first untouched removal can transfer ownership without allocation.
    // Force overflow storage for the next removal and verify both on rollback.
    if (remove) try c.frames.remove(count - 1);
    const attempted = if (remove) c.frames.remove(0) else blk: {
        _ = c.frames.getMutable(0) catch |err| break :blk @as(FramesError!void, err);
        break :blk @as(FramesError!void, {});
    };
    attempted catch |err| {
        c.frames.rollback(count);
        try testing.expectEqual(count, c.frames.entries.count());
        try testing.expectEqual(10, try c.value(0, 0));
        try testing.expectEqual(11, try c.value(count - 1, 0));
        return err;
    };
    c.frames.rollback(count);
    try testing.expectEqual(count, c.frames.entries.count());
    try testing.expectEqual(10, try c.value(0, 0));
    try testing.expectEqual(11, try c.value(count - 1, 0));
}
const FramesError = @import("activation_frames.zig").Error;

test "first saved version and untouched removal fail before ownership escapes" {
    try testing.checkAllAllocationFailures(testing.allocator, protectionFailure, .{false});
    try testing.checkAllAllocationFailures(testing.allocator, protectionFailure, .{true});
}

test "rollback never resurrects an exhausted slot handle generation" {
    var c: Context = undefined;
    try c.init(testing.allocator, 4);
    defer c.deinit();
    try c.insert(0, 10);
    const frame = c.frames.entries.getPtr(0).?;
    frame.view.generation = std.math.maxInt(u64);
    c.frames.slots.views.items[frame.view.index].generation = frame.view.generation;
    const exhausted = frame.view;
    try c.frames.begin(1);
    try c.frames.write(try c.frames.getMutable(0), 0, Values.natural(0, 20));
    c.frames.rollback(1);
    try testing.expectError(error.InvalidHandle, c.frames.slots.get(exhausted, 0));
    try testing.expectEqual(10, try c.value(0, 0));
    try c.insert(1, 30);
    try testing.expect((try c.frames.get(1)).view.index != exhausted.index);
    try testing.expectError(error.InvalidHandle, c.frames.slots.get(exhausted, 0));
}

test "repeated frame commits release rollback views and retain a bounded plateau" {
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    var c: Context = undefined;
    try c.init(counting.allocator(), 65);
    defer c.deinit();
    try c.insert(0, 10);
    var plateau: usize = 0;
    for (0..2048) |iteration| {
        try c.frames.begin(1);
        try c.frames.write(try c.frames.getMutable(0), 0, Values.natural(0, iteration));
        c.frames.commit();
        if (iteration == 16) plateau = counting.allocated_bytes - counting.freed_bytes;
        if (iteration > 16) try testing.expectEqual(
            plateau,
            counting.allocated_bytes - counting.freed_bytes,
        );
        try testing.expectEqual(1, c.frames.slots.statistics.live_pages);
    }
    try testing.expectEqual(2047, try c.value(0, 0));
}
