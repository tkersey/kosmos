// Copyright (c) 2026 World contributors. MIT license.
//! Reusable caller-owned storage. Allocation metadata is never process State.
const std = @import("std");

pub const Arena = struct {
    const Block = struct {
        length: usize,
        requested: usize = 0,
        previous: ?*Block = null,
        next: ?*Block = null,
        available: bool = true,
    };
    const block_alignment = @alignOf(Block);
    buffer: []u8,
    first: ?*Block,
    // Blocks before this hint are known allocated. Unsuccessful holes remain
    // candidates for later, smaller allocations.
    search: ?*Block = null,
    address_ordered: bool = true,
    live_payload: usize = 0,
    live_blocks: usize = 0,
    peak_payload: usize = 0,
    required: u64 = 0,
    grow_context: ?*anyopaque = null,
    grow: ?*const fn (*anyopaque, usize) ?[]u8 = null,

    pub fn init(buffer: []u8) Arena {
        const start = @intFromPtr(buffer.ptr);
        const aligned = std.mem.alignForward(usize, start, block_alignment);
        const padding = aligned - start;
        if (padding > buffer.len or buffer.len - padding < @sizeOf(Block))
            return .{ .buffer = buffer, .first = null };
        const first: *Block = @ptrFromInt(aligned);
        first.* = .{ .length = buffer.len - padding };
        return .{ .buffer = buffer, .first = first };
    }

    pub fn allocator(self: *Arena) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocate,
                // Keep arena-slab growth unchanged; movable arrays use remap.
                .resize = std.mem.Allocator.noResize,
                .remap = remap,
                .free = release,
            },
        };
    }

    fn allocate(context: *anyopaque, length: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(context));
        // Simultaneously live payload and mandatory metadata form a lower bound.
        // It intentionally does not promise a sufficient size under fragmentation.
        const overhead = @as(u64, @sizeOf(Block) + @sizeOf(usize));
        const live_metadata = (@as(u64, self.live_blocks) +| 1) *| overhead;
        const demand = @as(u64, self.live_payload) +| length +| live_metadata;
        self.required = @max(self.required, demand);
        const requested_alignment = @max(alignment.toByteUnits(), @alignOf(usize));
        const search = self.allocateAvailable(length, requested_alignment) orelse return null;
        if (search.result) |result| return result;
        if (!self.growAvailable(length, requested_alignment, search)) return null;
        return (self.allocateAvailable(length, requested_alignment) orelse return null).result;
    }

    const AllocationSearch = struct {
        result: ?[*]u8 = null,
        last: ?*Block = null,
        first_available: ?*Block = null,
    };

    fn allocateAvailable(
        self: *Arena,
        length: usize,
        requested_alignment: usize,
    ) ?AllocationSearch {
        var cursor = self.search orelse self.first;
        var last: ?*Block = null;
        var first_available: ?*Block = null;
        while (cursor) |block| : (cursor = block.next) {
            last = block;
            if (!block.available) continue;
            if (first_available == null) first_available = block;
            const start = @intFromPtr(block);
            const header_end = std.math.add(
                usize,
                start,
                @sizeOf(Block) + @sizeOf(usize),
            ) catch return null;
            const padding = (0 -% header_end) & (requested_alignment - 1);
            const address = std.math.add(usize, header_end, padding) catch return null;
            const end = std.math.add(usize, address, length) catch return null;
            const used = end - start;
            if (used > block.length) continue;
            const padded = std.math.add(
                usize,
                used,
                (0 -% end) & (block_alignment - 1),
            ) catch return null;
            if (padded <= block.length and
                block.length - padded >= @sizeOf(Block) + @sizeOf(usize) + 1)
            {
                const successor: *Block = @ptrFromInt(start + padded);
                successor.* = .{
                    .length = block.length - padded,
                    .previous = block,
                    .next = block.next,
                };
                if (block.next) |next| next.previous = successor;
                block.next = successor;
                block.length = padded;
            }
            block.available = false;
            block.requested = length;
            self.search = if (first_available == block) block.next else first_available;
            const saved: *usize = @ptrFromInt(address - @sizeOf(usize));
            saved.* = start;
            self.live_payload += length;
            self.live_blocks += 1;
            self.peak_payload = @max(self.peak_payload, self.live_payload);
            return .{ .result = @ptrFromInt(address) };
        }
        return .{ .last = last, .first_available = first_available };
    }

    fn growAvailable(
        self: *Arena,
        length: usize,
        requested_alignment: usize,
        search: AllocationSearch,
    ) bool {
        const grow = self.grow orelse return false;
        {
            const metadata = std.math.add(
                usize,
                @sizeOf(Block) + @sizeOf(usize),
                requested_alignment,
            ) catch return false;
            const needed = std.math.add(usize, length, metadata) catch return false;
            const segment = grow(self.grow_context.?, needed) orelse return false;
            const added = Arena.init(segment);
            const first = added.first orelse return false;
            if (search.last) |tail| self.address_ordered = self.address_ordered and
                @intFromPtr(tail) < @intFromPtr(first);
            if (search.last) |tail| {
                if (tail.available and @intFromPtr(tail) + tail.length == @intFromPtr(first)) {
                    tail.length += first.length;
                } else {
                    tail.next = first;
                    first.previous = tail;
                }
            } else self.first = first;
            self.search = search.first_available orelse first;
            return true;
        }
    }

    fn remap(
        context: *anyopaque,
        bytes: []u8,
        _: std.mem.Alignment,
        length: usize,
        _: usize,
    ) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(context));
        const address = @intFromPtr(bytes.ptr);
        const saved: *const usize = @ptrFromInt(address - @sizeOf(usize));
        const block: *Block = @ptrFromInt(saved.*);
        std.debug.assert(!block.available and block.requested == bytes.len);
        const demand = (@as(u64, self.live_payload - bytes.len) +| length) +|
            (@as(u64, self.live_blocks) *| (@sizeOf(Block) + @sizeOf(usize)));
        self.required = @max(self.required, demand);
        if (length == bytes.len) return bytes.ptr;
        const end = std.math.add(usize, address, length) catch return null;
        const padding = (0 -% end) & (block_alignment - 1);
        const padded_end = std.math.add(usize, end, padding) catch return null;
        const needed = end - @intFromPtr(block);
        const used = padded_end - @intFromPtr(block);
        var span = block.length;
        var after = block.next;
        var removed_hint = false;
        while (span < needed) {
            const next = after orelse return null;
            if (!next.available or @intFromPtr(next) != @intFromPtr(block) + span)
                return null;
            span = std.math.add(usize, span, next.length) catch return null;
            removed_hint = removed_hint or self.search == next;
            after = next.next;
        }
        // All failure paths precede mutation. The pointer and retained prefix stay fixed.
        block.length = span;
        block.next = after;
        if (after) |next| next.previous = block;
        if (removed_hint) self.search = after;
        if (used <= span and span - used >= @sizeOf(Block) + @sizeOf(usize) + 1) {
            const tail: *Block = @ptrFromInt(padded_end);
            tail.* = .{ .length = span - used, .previous = block, .next = after };
            while (tail.next) |next| {
                if (!next.available or @intFromPtr(tail) + tail.length != @intFromPtr(next))
                    break;
                if (self.search == next) self.search = tail;
                tail.length += next.length;
                tail.next = next.next;
            }
            if (tail.next) |next| next.previous = tail;
            block.next = tail;
            block.length = used;
            if (self.search) |hint| {
                if (@intFromPtr(tail) < @intFromPtr(hint)) self.search = tail;
            }
        }
        if (!self.address_ordered) self.search = null;
        self.live_payload = self.live_payload - bytes.len + length;
        block.requested = length;
        self.peak_payload = @max(self.peak_payload, self.live_payload);
        return bytes.ptr;
    }

    fn release(context: *anyopaque, bytes: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *Arena = @ptrCast(@alignCast(context));
        const saved: *const usize = @ptrFromInt(@intFromPtr(bytes.ptr) - @sizeOf(usize));
        const block: *Block = @ptrFromInt(saved.*);
        self.live_payload -= block.requested;
        self.live_blocks -= 1;
        block.available = true;
        var merged = block;
        if (block.next) |next| if (next.available and
            @intFromPtr(block) + block.length == @intFromPtr(next))
        {
            block.length += next.length;
            block.next = next.next;
            if (next.next) |after| after.previous = block;
        };
        if (block.previous) |previous| if (previous.available and
            @intFromPtr(previous) + previous.length == @intFromPtr(block))
        {
            previous.length += block.length;
            previous.next = block.next;
            if (block.next) |after| after.previous = previous;
            merged = previous;
        };
        // Address order is a proof of list order only while appended segments
        // remain ordered. Otherwise invalidate and use the original full scan.
        if (self.address_ordered) {
            if (self.search) |hint| {
                if (@intFromPtr(merged) < @intFromPtr(hint)) self.search = merged;
            }
        } else self.search = null;
    }
};

test "out-of-order frees coalesce and permit reuse of the complete buffer" {
    var buffer: [8192]u8 align(64) = undefined;
    var arena = Arena.init(&buffer);
    const allocator = arena.allocator();
    const a = try allocator.alignedAlloc(u8, .@"64", 500);
    const b = try allocator.alloc(u64, 100);
    const c = try allocator.alloc(u8, 300);
    allocator.free(b);
    allocator.free(a);
    allocator.free(c);
    try std.testing.expectEqual(@as(usize, 0), arena.live_payload);
    try std.testing.expectEqual(@as(usize, 0), arena.live_blocks);
    const all = try allocator.alloc(u8, 8000);
    allocator.free(all);
}

test "contiguous growth extends the existing free tail before allocating" {
    const Growth = struct {
        bytes: []u8,
        calls: usize = 0,
        fn grow(context: *anyopaque, minimum: usize) ?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.calls != 1 or minimum > self.bytes.len) return null;
            return self.bytes;
        }
    };
    var bytes: [1024]u8 align(64) = undefined;
    var growth: Growth = .{ .bytes = bytes[256..] };
    var arena = Arena.init(bytes[0..256]);
    arena.grow = Growth.grow;
    arena.grow_context = &growth;
    const a = arena.allocator();
    const value = try a.alloc(u8, 300);
    try std.testing.expect(@intFromPtr(value.ptr) < @intFromPtr(bytes[256..].ptr));
    try std.testing.expectEqual(@as(usize, 1), growth.calls);
    @memset(value, 0x91);
    try std.testing.expect(std.mem.allEqual(u8, value, 0x91));
    a.free(value);
    try std.testing.expectEqual(bytes.len, arena.first.?.length);
    try std.testing.expectEqual(@as(?*Arena.Block, null), arena.first.?.next);
    try std.testing.expectEqual(@as(usize, 0), arena.live_payload);
    const all = try a.alloc(u8, 950);
    a.free(all);
    try std.testing.expectEqual(@as(usize, 1), growth.calls);
}

test "unrepresentable allocation demand preserves live workspace contents" {
    var buffer: [256]u8 align(64) = undefined;
    var arena = Arena.init(&buffer);
    const allocator = arena.allocator();
    const live = try allocator.alloc(u8, 16);
    defer allocator.free(live);
    @memset(live, 0xa5);
    const first = arena.first.?.*;
    const tail = arena.first.?.next.?.*;
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, std.math.maxInt(usize)));
    try std.testing.expect(std.meta.eql(first, arena.first.?.*));
    try std.testing.expect(std.meta.eql(tail, arena.first.?.next.?.*));
    try std.testing.expectEqual(@as(usize, 16), arena.live_payload);
    try std.testing.expectEqual(@as(usize, 1), arena.live_blocks);
    try std.testing.expect(std.mem.allEqual(u8, live, 0xa5));
    try std.testing.expect(arena.required >= std.math.maxInt(usize));
    const next = try allocator.alloc(u8, 32);
    allocator.free(next);
}

test "search hint preserves earlier holes after a larger allocation" {
    var bytes: [4096]u8 align(64) = undefined;
    var arena = Arena.init(&bytes);
    const a = arena.allocator();
    const small = try a.alloc(u8, 32);
    const separator = try a.alloc(u8, 16);
    const large = try a.alloc(u8, 256);
    const end = try a.alloc(u8, 16);
    a.free(small);
    a.free(large);
    const middle = try a.alloc(u8, 128);
    try std.testing.expectEqual(@intFromPtr(large.ptr), @intFromPtr(middle.ptr));
    const first = try a.alloc(u8, 16);
    try std.testing.expectEqual(@intFromPtr(small.ptr), @intFromPtr(first.ptr));
    a.free(first);
    a.free(middle);
    a.free(separator);
    a.free(end);
    try std.testing.expectEqual(@as(usize, 0), arena.live_payload);
    const whole = try a.alloc(u8, 4000);
    a.free(whole);
}

test "search hint resets on free and preserves segment order during growth" {
    const Growth = struct {
        bytes: []u8,
        used: bool = false,
        fn grow(context: *anyopaque, minimum: usize) ?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.used or minimum > self.bytes.len) return null;
            self.used = true;
            return self.bytes;
        }
    };
    for ([_]usize{ 0, 1 }) |initial| {
        var buffers: [2][256]u8 align(64) = undefined;
        var growth: Growth = .{ .bytes = &buffers[1 - initial] };
        // Exercise both address orders. A free tail in the new segment must
        // not hide a subsequently freed block in the first segment.
        var arena = Arena.init(&buffers[initial]);
        arena.grow_context = &growth;
        arena.grow = Growth.grow;
        const a = arena.allocator();
        const first = try a.alloc(u8, 200);
        const second = try a.alloc(u8, 64);
        try std.testing.expect(growth.used);
        try std.testing.expectEqual(initial == 1, @intFromPtr(second.ptr) < @intFromPtr(first.ptr));
        try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 200));
        a.free(first);
        const reused = try a.alloc(u8, 64);
        try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused.ptr));
        a.free(reused);
        a.free(second);
        try std.testing.expectEqual(@as(usize, 0), arena.live_payload);
        try std.testing.expectEqual(@as(usize, 0), arena.live_blocks);
    }
}

test "remap preserves aligned prefixes and reclaims a released tail" {
    var bytes: [2048]u8 align(64) = @splat(0);
    var arena = Arena.init(&bytes);
    const a = arena.allocator();
    var first = try a.alignedAlloc(u8, .@"64", 64);
    const second = try a.alloc(u8, 64);
    const last = try a.alloc(u8, 64);
    @memset(first, 0xa7);
    @memset(last, 0xb7);
    const address = @intFromPtr(first.ptr);
    a.free(second);
    try std.testing.expect(tryRemap(a, first, 128));
    first = first.ptr[0..128];
    try std.testing.expectEqual(address, @intFromPtr(first.ptr));
    try std.testing.expect(std.mem.allEqual(u8, first[0..64], 0xa7));
    @memset(first, 0xa7);
    try std.testing.expect(tryRemap(a, first, 16));
    first = first.ptr[0..16];
    const reused = try a.alloc(u8, 48);
    try std.testing.expect(
        @intFromPtr(reused.ptr) > address and @intFromPtr(reused.ptr) < @intFromPtr(last.ptr),
    );
    try std.testing.expect(std.mem.allEqual(u8, first, 0xa7));
    try std.testing.expect(std.mem.allEqual(u8, last, 0xb7));
    a.free(reused);
    a.free(first);
    a.free(last);
    try std.testing.expectEqual(@as(usize, 0), arena.live_payload);
    try std.testing.expectEqual(@as(usize, 0), arena.live_blocks);
    const whole = try a.alloc(u8, 1900);
    a.free(whole);
}

test "failed remap preserves allocation metadata and bytes" {
    var bytes: [512]u8 align(64) = @splat(0);
    var arena = Arena.init(&bytes);
    const a = arena.allocator();
    const first = try a.alloc(u8, 32);
    const second = try a.alloc(u8, 32);
    @memset(first, 0x31);
    @memset(second, 0x62);
    const before = bytes;
    const hint = arena.search;
    try std.testing.expect(!tryRemap(a, first, 256));
    try std.testing.expect(!tryRemap(a, first, std.math.maxInt(usize)));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
    try std.testing.expectEqual(hint, arena.search);
    try std.testing.expectEqual(@as(usize, 64), arena.live_payload);
    try std.testing.expectEqual(@as(usize, 2), arena.live_blocks);
    a.free(second);
    a.free(first);
}

test "remap preserves a full-scan hint and an earlier free hole" {
    var bytes: [1024]u8 align(64) = undefined;
    var arena = Arena.init(&bytes);
    const a = arena.allocator();
    const hole = try a.alloc(u8, 64);
    const middle = try a.alloc(u8, 64);
    var tail = try a.alloc(u8, 128);
    const address = @intFromPtr(hole.ptr);
    a.free(hole);
    arena.search = null;
    try std.testing.expect(tryRemap(a, tail, 16));
    tail = tail.ptr[0..16];
    const next = try a.alloc(u8, 32);
    try std.testing.expectEqual(address, @intFromPtr(next.ptr));
    a.free(next);
    a.free(tail);
    a.free(middle);
}

test "random allocation free and remap preserve contents and the block partition" {
    var memory: [65536]u8 align(64) = undefined;
    var arena = Arena.init(&memory);
    const a = arena.allocator();
    var values: [48]?[]u8 = @splat(null);
    var random = std.Random.DefaultPrng.init(0x726573697a65);
    const rng = random.random();
    var peak: usize = 0;
    for (0..10000) |_| {
        const index = rng.uintLessThan(usize, values.len);
        if (values[index]) |old| {
            if (rng.boolean()) {
                a.free(old);
                values[index] = null;
            } else {
                const length = rng.uintLessThan(usize, 2048) + 1;
                if (tryRemap(a, old, length)) {
                    const changed = old.ptr[0..length];
                    try std.testing.expect(std.mem.allEqual(
                        u8,
                        changed[0..@min(old.len, length)],
                        @intCast(index),
                    ));
                    @memset(changed, @intCast(index));
                    values[index] = changed;
                }
            }
        } else {
            if (a.alloc(u8, rng.uintLessThan(usize, 2048) + 1)) |value| {
                @memset(value, @intCast(index));
                values[index] = value;
            } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        }
        var live: usize = 0;
        var count: usize = 0;
        for (values, 0..) |value, id| if (value) |slice| {
            try std.testing.expect(std.mem.allEqual(u8, slice, @intCast(id)));
            live += slice.len;
            count += 1;
        };
        peak = @max(peak, live);
        try std.testing.expectEqual(live, arena.live_payload);
        try std.testing.expectEqual(count, arena.live_blocks);
        try std.testing.expectEqual(peak, arena.peak_payload);
        var cursor = arena.first;
        var previous: ?*Arena.Block = null;
        var address = @intFromPtr(&memory);
        var found_hint = arena.search == null;
        var allocated: usize = 0;
        while (cursor) |block| : (cursor = block.next) {
            try std.testing.expectEqual(address, @intFromPtr(block));
            try std.testing.expectEqual(previous, block.previous);
            try std.testing.expect(block.length >= @sizeOf(Arena.Block));
            if (arena.search == block) found_hint = true;
            if (!found_hint) try std.testing.expect(!block.available);
            if (!block.available) allocated += 1;
            address += block.length;
            previous = block;
        }
        try std.testing.expect(found_hint);
        try std.testing.expectEqual(@intFromPtr(&memory) + memory.len, address);
        try std.testing.expectEqual(count, allocated);
    }
    for (values) |value| if (value) |slice| a.free(slice);
    try std.testing.expectEqual(@as(usize, 0), arena.live_payload);
}

fn tryRemap(a: std.mem.Allocator, bytes: anytype, length: usize) bool {
    const changed = a.remap(bytes, length) orelse return false;
    std.debug.assert(changed.ptr == bytes.ptr);
    return true;
}

test "remap does not bridge noncontiguous growth segments" {
    const Growth = struct {
        bytes: []u8,
        used: bool = false,
        fn grow(context: *anyopaque, _: usize) ?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.used) return null;
            self.used = true;
            return self.bytes;
        }
    };
    var buffers: [3][256]u8 align(64) = @splat(@splat(0xcd));
    var growth: Growth = .{ .bytes = &buffers[0] };
    var arena = Arena.init(&buffers[1]);
    arena.grow = Growth.grow;
    arena.grow_context = &growth;
    const a = arena.allocator();
    const first = try a.alloc(u8, 200);
    @memset(first, 0x71);
    const second = try a.alloc(u8, 64);
    a.free(second);
    try std.testing.expect(!tryRemap(a, first, 300));
    try std.testing.expect(std.mem.allEqual(u8, first, 0x71));
    try std.testing.expect(std.mem.allEqual(u8, &buffers[2], 0xcd));
    const reused = try a.alloc(u8, 64);
    try std.testing.expectEqual(@intFromPtr(second.ptr), @intFromPtr(reused.ptr));
    a.free(reused);
    a.free(first);
}
