// Copyright (c) 2026 World contributors. MIT license.
//! Reusable caller-owned storage. Allocation metadata is never process State.
const std = @import("std");

pub const Arena = struct {
    const Block = struct {
        size: usize,
        requested: usize = 0,
        physical_previous: ?*Block = null,
        available: bool = true,
        last: bool = true,
    };
    const Links = struct { previous: ?*Block = null, next: ?*Block = null };
    const granularity = @max(@alignOf(Block), @alignOf(u64));
    const payload_offset = std.mem.alignForward(
        usize,
        @sizeOf(Block) + @sizeOf(usize),
        granularity,
    );
    const block_minimum = std.mem.alignForward(
        usize,
        @max(payload_offset + 1, @sizeOf(Block) + @sizeOf(Links)),
        granularity,
    );
    const second_log2 = 4;
    const second_count = 1 << second_log2;
    const linear_log2 = second_log2 + std.math.log2(granularity);
    const first_count = @bitSizeOf(usize) - linear_log2 + 1;
    const FirstMap = @Int(.unsigned, first_count);
    const SecondMap = @Int(.unsigned, second_count);
    const Class = struct { first: usize, second: usize };

    comptime {
        std.debug.assert(@sizeOf(Block) % @alignOf(Links) == 0);
        std.debug.assert(block_minimum >= @sizeOf(Block) + @sizeOf(Links));
        std.debug.assert(block_minimum < 1 << linear_log2);
    }

    first_map: FirstMap = 0,
    second_maps: [first_count]SecondMap = @splat(0),
    heads: [first_count][second_count]?*Block = @splat(@splat(null)),
    tail: ?*Block = null,
    live_payload: usize = 0,
    live_blocks: usize = 0,
    peak_payload: usize = 0,
    required: u64 = 0,
    grow_context: ?*anyopaque = null,
    grow: ?*const fn (*anyopaque, usize) ?[]u8 = null,

    pub fn init(buffer: []u8) Arena {
        var arena: Arena = .{};
        _ = arena.addSegment(buffer);
        return arena;
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

    const Request = struct {
        length: usize,
        alignment: usize,
        minimum: usize,
        maximum: usize,

        fn init(length: usize, alignment: usize) ?Request {
            const used = std.math.add(usize, payload_offset, length) catch return null;
            const minimum = @max(block_minimum, alignUp(used) orelse return null);
            const padding = alignment -| granularity;
            return .{
                .length = length,
                .alignment = alignment,
                .minimum = minimum,
                .maximum = std.math.add(usize, minimum, padding) catch return null,
            };
        }
    };

    const Placement = struct { payload: usize, used: usize };

    fn alignUp(value: usize) ?usize {
        const raised = std.math.add(usize, value, granularity - 1) catch return null;
        return std.mem.alignBackward(usize, raised, granularity);
    }

    fn placement(block: *const Block, request: Request) ?Placement {
        const start = @intFromPtr(block);
        const header_end = std.math.add(usize, start, payload_offset) catch return null;
        const raised = std.math.add(usize, header_end, request.alignment - 1) catch return null;
        const payload = std.mem.alignBackward(usize, raised, request.alignment);
        const end = std.math.add(usize, payload, request.length) catch return null;
        const used = @max(block_minimum, alignUp(end - start) orelse return null);
        if (used > block.size) return null;
        return .{ .payload = payload, .used = used };
    }

    fn classOf(size: usize) Class {
        std.debug.assert(size >= block_minimum);
        if (size < 1 << linear_log2) {
            std.debug.assert(size % granularity == 0);
            return .{ .first = 0, .second = size / granularity };
        }
        const top: usize = std.math.log2_int(usize, size);
        return .{
            .first = top - linear_log2 + 1,
            .second = (size >> @intCast(top - second_log2)) - second_count,
        };
    }

    fn classAtLeast(size: usize) ?Class {
        if (size < 1 << linear_log2) return classOf(size);
        const top = std.math.log2_int(usize, size);
        const step = @as(usize, 1) << @intCast(top - second_log2);
        return classOf(std.math.add(usize, size, step - 1) catch return null);
    }

    fn classAfter(class: Class) ?Class {
        if (class.second + 1 < second_count)
            return .{ .first = class.first, .second = class.second + 1 };
        if (class.first + 1 < first_count) return .{ .first = class.first + 1, .second = 0 };
        return null;
    }

    fn links(block: *Block) *Links {
        return @ptrFromInt(@intFromPtr(block) + @sizeOf(Block));
    }

    fn physicalNext(block: *const Block) ?*Block {
        if (block.last) return null;
        return @ptrFromInt(@intFromPtr(block) + block.size);
    }

    fn insert(self: *Arena, block: *Block) void {
        std.debug.assert(block.available);
        const class = classOf(block.size);
        const head = &self.heads[class.first][class.second];
        links(block).* = .{ .next = head.* };
        if (head.*) |next| links(next).previous = block;
        head.* = block;
        self.second_maps[class.first] |= @as(SecondMap, 1) << @intCast(class.second);
        self.first_map |= @as(FirstMap, 1) << @intCast(class.first);
    }

    fn remove(self: *Arena, block: *Block) void {
        std.debug.assert(block.available);
        const class = classOf(block.size);
        const entry = links(block).*;
        if (entry.next) |next| links(next).previous = entry.previous;
        if (entry.previous) |previous| {
            links(previous).next = entry.next;
            return;
        }
        std.debug.assert(self.heads[class.first][class.second] == block);
        self.heads[class.first][class.second] = entry.next;
        if (entry.next != null) return;
        self.second_maps[class.first] &= ~(@as(SecondMap, 1) << @intCast(class.second));
        if (self.second_maps[class.first] == 0)
            self.first_map &= ~(@as(FirstMap, 1) << @intCast(class.first));
    }

    fn availableClass(self: *const Arena, from: Class) ?Class {
        const local = self.second_maps[from.first] &
            std.math.shl(SecondMap, std.math.maxInt(SecondMap), from.second);
        if (local != 0) return .{ .first = from.first, .second = @ctz(local) };
        const higher = self.first_map &
            std.math.shl(FirstMap, std.math.maxInt(FirstMap), from.first + 1);
        if (higher == 0) return null;
        const first: usize = @ctz(higher);
        return .{ .first = first, .second = @ctz(self.second_maps[first]) };
    }

    fn findFit(self: *const Arena, request: Request) ?*Block {
        const own = classOf(request.minimum);
        if (self.heads[own.first][own.second]) |head| if (placement(head, request) != null)
            return head;
        if (classAtLeast(request.maximum)) |class| if (self.availableClass(class)) |found|
            return self.heads[found.first][found.second];
        var candidate: ?Class = classOf(request.minimum);
        while (candidate) |from| {
            const found = self.availableClass(from) orelse return null;
            var cursor = self.heads[found.first][found.second];
            while (cursor) |block| : (cursor = links(block).next) {
                if (placement(block, request) != null) return block;
            }
            candidate = classAfter(found);
        }
        return null;
    }

    fn absorb(self: *Arena, left: *Block, right: *Block) void {
        std.debug.assert(@intFromPtr(left) + left.size == @intFromPtr(right));
        left.size += right.size;
        left.last = right.last;
        if (physicalNext(left)) |next| next.physical_previous = left;
        if (self.tail == right) self.tail = left;
    }

    fn coalesce(self: *Arena, block: *Block) void {
        var merged = block;
        if (physicalNext(block)) |next| if (next.available) {
            self.remove(next);
            self.absorb(block, next);
        };
        if (block.physical_previous) |previous| if (previous.available) {
            self.remove(previous);
            self.absorb(previous, block);
            merged = previous;
        };
        self.insert(merged);
    }

    fn split(self: *Arena, block: *Block, used: usize) void {
        std.debug.assert(!block.available and block.size - used >= block_minimum);
        const remainder: *Block = @ptrFromInt(@intFromPtr(block) + used);
        remainder.* = .{
            .size = block.size - used,
            .physical_previous = block,
            .last = block.last,
        };
        if (physicalNext(remainder)) |next| next.physical_previous = remainder;
        if (self.tail == block) self.tail = remainder;
        block.size = used;
        block.last = false;
        self.coalesce(remainder);
    }

    fn place(self: *Arena, block: *Block, request: Request) [*]u8 {
        const selected = placement(block, request).?;
        self.remove(block);
        block.available = false;
        block.requested = request.length;
        if (block.size - selected.used >= block_minimum) self.split(block, selected.used);
        const saved: *usize = @ptrFromInt(selected.payload - @sizeOf(usize));
        saved.* = @intFromPtr(block);
        self.live_payload += request.length;
        self.live_blocks += 1;
        self.peak_payload = @max(self.peak_payload, self.live_payload);
        return @ptrFromInt(selected.payload);
    }

    fn addSegment(self: *Arena, segment: []u8) bool {
        const start = std.mem.alignForward(usize, @intFromPtr(segment.ptr), granularity);
        const padding = start - @intFromPtr(segment.ptr);
        if (padding > segment.len) return false;
        const size = std.mem.alignBackward(usize, segment.len - padding, granularity);
        const adjacent = if (self.tail) |tail|
            (if (@intFromPtr(tail) + tail.size == start) tail else null)
        else
            null;
        if (adjacent) |tail| if (tail.available) {
            self.remove(tail);
            tail.size += size;
            self.insert(tail);
            return true;
        };
        if (size < block_minimum) return false;
        const block: *Block = @ptrFromInt(start);
        block.* = .{ .size = size, .physical_previous = adjacent };
        if (adjacent) |tail| tail.last = false;
        self.tail = block;
        self.insert(block);
        return true;
    }

    fn growFor(self: *Arena, request: Request) bool {
        const grow = self.grow orelse return false;
        const minimum = std.math.add(usize, request.maximum, granularity - 1) catch return false;
        const segment = grow(self.grow_context.?, minimum) orelse return false;
        return self.addSegment(segment);
    }

    fn allocate(context: *anyopaque, length: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(context));
        // Simultaneously live payload and mandatory metadata form a lower bound.
        // It intentionally does not promise a sufficient size under fragmentation.
        const live_metadata = (@as(u64, self.live_blocks) +| 1) *| payload_offset;
        const demand = @as(u64, self.live_payload) +| length +| live_metadata;
        self.required = @max(self.required, demand);
        const request = Request.init(length, alignment.toByteUnits()) orelse return null;
        const block = self.findFit(request) orelse grown: {
            if (!self.growFor(request)) return null;
            break :grown self.findFit(request) orelse return null;
        };
        return self.place(block, request);
    }

    fn owner(bytes: []u8) *Block {
        const saved: *const usize = @ptrFromInt(@intFromPtr(bytes.ptr) - @sizeOf(usize));
        const block: *Block = @ptrFromInt(saved.*);
        std.debug.assert(!block.available and block.requested == bytes.len);
        return block;
    }

    fn remap(
        context: *anyopaque,
        bytes: []u8,
        _: std.mem.Alignment,
        length: usize,
        _: usize,
    ) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(context));
        const block = owner(bytes);
        const demand = (@as(u64, self.live_payload - bytes.len) +| length) +|
            (@as(u64, self.live_blocks) *| payload_offset);
        self.required = @max(self.required, demand);
        if (length == bytes.len) return bytes.ptr;
        const end = std.math.add(usize, @intFromPtr(bytes.ptr), length) catch return null;
        const used = @max(block_minimum, alignUp(end - @intFromPtr(block)) orelse return null);
        const following = if (used > block.size) next: {
            const next = physicalNext(block) orelse return null;
            if (!next.available) return null;
            const span = std.math.add(usize, block.size, next.size) catch return null;
            if (used > span) return null;
            break :next next;
        } else null;
        // All failure paths precede mutation. The pointer and retained prefix stay fixed.
        if (following) |next| {
            self.remove(next);
            self.absorb(block, next);
        }
        if (block.size - used >= block_minimum) self.split(block, used);
        self.live_payload = self.live_payload - bytes.len + length;
        block.requested = length;
        self.peak_payload = @max(self.peak_payload, self.live_payload);
        return bytes.ptr;
    }

    fn release(context: *anyopaque, bytes: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *Arena = @ptrCast(@alignCast(context));
        const block = owner(bytes);
        self.live_payload -= block.requested;
        self.live_blocks -= 1;
        block.available = true;
        self.coalesce(block);
    }
};

const testing = std.testing;

const Walk = struct {
    allocated: usize = 0,
    available: usize = 0,
    end: usize = 0,
    last: ?*Arena.Block = null,
};

fn chainHead(segment: []u8) *Arena.Block {
    return @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(segment.ptr), Arena.granularity));
}

fn expectChain(head: *Arena.Block) !Walk {
    var walk: Walk = .{};
    var previous: ?*Arena.Block = null;
    var cursor: ?*Arena.Block = head;
    while (cursor) |block| : (cursor = Arena.physicalNext(block)) {
        try testing.expectEqual(previous, block.physical_previous);
        try testing.expect(block.size >= Arena.block_minimum);
        try testing.expectEqual(@as(usize, 0), block.size % Arena.granularity);
        if (block.available) {
            try testing.expect(previous == null or !previous.?.available);
            walk.available += 1;
        } else walk.allocated += 1;
        walk.end = @intFromPtr(block) + block.size;
        walk.last = block;
        previous = block;
    }
    return walk;
}

fn expectIndexed(arena: *const Arena, available: usize) !void {
    var count: usize = 0;
    for (arena.heads, arena.second_maps, 0..) |row, second_map, first| {
        try testing.expectEqual(second_map != 0, (arena.first_map >> @intCast(first)) & 1 == 1);
        for (row, 0..) |head, second| {
            try testing.expectEqual(head != null, (second_map >> @intCast(second)) & 1 == 1);
            var previous: ?*Arena.Block = null;
            var cursor = head;
            while (cursor) |block| : (cursor = Arena.links(block).next) {
                try testing.expect(block.available);
                const class = Arena.classOf(block.size);
                try testing.expectEqual(first, class.first);
                try testing.expectEqual(second, class.second);
                try testing.expectEqual(previous, Arena.links(block).previous);
                previous = block;
                count += 1;
            }
        }
    }
    try testing.expectEqual(available, count);
}

fn anyAvailableFits(heads: []const *Arena.Block, length: usize, alignment: usize) bool {
    for (heads) |head| {
        var cursor: ?*Arena.Block = head;
        while (cursor) |block| : (cursor = Arena.physicalNext(block)) {
            if (!block.available) continue;
            const header_end = @intFromPtr(block) + Arena.payload_offset;
            const payload = std.mem.alignForward(usize, header_end, alignment);
            const end = std.math.add(usize, payload, length) catch continue;
            if (end <= @intFromPtr(block) + block.size) return true;
        }
    }
    return false;
}

fn expectSameMetadata(before: Arena, after: Arena) !void {
    var normalized = after;
    normalized.required = before.required;
    try testing.expect(std.meta.eql(before, normalized));
}

fn classLowerBound(class: Arena.Class) usize {
    if (class.first == 0) return class.second * Arena.granularity;
    const shift: std.math.Log2Int(usize) =
        @intCast(class.first - 1 + Arena.linear_log2 - Arena.second_log2);
    return (Arena.second_count + class.second) << shift;
}

test "size classes contain their members and good-fit classes hold every request" {
    var size: usize = Arena.block_minimum;
    while (size < 1 << 22) : (size += if (size < 1 << 12) Arena.granularity else 4093) {
        const aligned = std.mem.alignForward(usize, size, Arena.granularity);
        const class = Arena.classOf(aligned);
        try testing.expect(class.first < Arena.first_count);
        try testing.expect(classLowerBound(class) <= aligned);
        if (Arena.classAfter(class)) |after| try testing.expect(aligned < classLowerBound(after));
        const fit = Arena.classAtLeast(aligned).?;
        try testing.expect(classLowerBound(fit) >= aligned);
        try testing.expect(fit.first == class.first and fit.second == class.second or
            classLowerBound(class) < aligned);
    }
    const largest = std.mem.alignBackward(usize, std.math.maxInt(usize), Arena.granularity);
    try testing.expectEqual(Arena.first_count - 1, Arena.classOf(largest).first);
    try testing.expectEqual(@as(?Arena.Class, null), Arena.classAtLeast(largest));
}

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
    const walk = try expectChain(chainHead(&bytes));
    try std.testing.expectEqual(@as(usize, 1), walk.available);
    try std.testing.expectEqual(@as(usize, 0), walk.allocated);
    try std.testing.expectEqual(@intFromPtr(&bytes) + bytes.len, walk.end);
    try std.testing.expectEqual(arena.tail, walk.last);
    try expectIndexed(&arena, 1);
    try std.testing.expectEqual(@as(usize, 0), arena.live_payload);
    const all = try a.alloc(u8, 950);
    a.free(all);
    try std.testing.expectEqual(@as(usize, 1), growth.calls);
}

test "contiguous growth extends a free tail formed by backward coalescing" {
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
    const first = try a.alloc(u8, 100);
    const second = try a.alloc(u8, 50);
    try std.testing.expectEqual(arena.tail, (try expectChain(chainHead(&bytes))).last);
    a.free(first);
    a.free(second);
    try std.testing.expectEqual(arena.tail, (try expectChain(chainHead(&bytes))).last);
    const value = try a.alloc(u8, 700);
    try std.testing.expectEqual(@as(usize, 1), growth.calls);
    try std.testing.expectEqual(@intFromPtr(&bytes) + Arena.payload_offset, @intFromPtr(value.ptr));
    a.free(value);
    const walk = try expectChain(chainHead(&bytes));
    try std.testing.expectEqual(@as(usize, 1), walk.available);
    try std.testing.expectEqual(@intFromPtr(&bytes) + bytes.len, walk.end);
    try std.testing.expectEqual(arena.tail, walk.last);
    try expectIndexed(&arena, 1);
}

test "unrepresentable allocation demand preserves live workspace contents" {
    var buffer: [256]u8 align(64) = undefined;
    var arena = Arena.init(&buffer);
    const allocator = arena.allocator();
    const live = try allocator.alloc(u8, 16);
    defer allocator.free(live);
    @memset(live, 0xa5);
    const before = arena;
    const bytes = buffer;
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, std.math.maxInt(usize)));
    try expectSameMetadata(before, arena);
    try std.testing.expectEqualSlices(u8, &bytes, &buffer);
    try std.testing.expectEqual(@as(usize, 16), arena.live_payload);
    try std.testing.expectEqual(@as(usize, 1), arena.live_blocks);
    try std.testing.expect(std.mem.allEqual(u8, live, 0xa5));
    try std.testing.expect(arena.required >= std.math.maxInt(usize));
    const next = try allocator.alloc(u8, 32);
    allocator.free(next);
}

test "good fit reuses earlier holes after a larger allocation" {
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

test "freed blocks in either growth segment remain allocatable" {
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
        const reused = try a.alloc(u8, 200);
        try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused.ptr));
        a.free(reused);
        a.free(second);
        try std.testing.expectEqual(@as(usize, 0), arena.live_payload);
        try std.testing.expectEqual(@as(usize, 0), arena.live_blocks);
        const merged = initial == 0;
        const walk = try expectChain(chainHead(&buffers[0]));
        try std.testing.expectEqual(@as(usize, 1), walk.available);
        try std.testing.expectEqual(merged, walk.end == @intFromPtr(&buffers[1]) + 256);
        try expectIndexed(&arena, if (merged) 1 else 2);
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
    const metadata = arena;
    try std.testing.expect(!tryRemap(a, first, 256));
    try std.testing.expect(!tryRemap(a, first, std.math.maxInt(usize)));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
    try expectSameMetadata(metadata, arena);
    try std.testing.expectEqual(@as(usize, 64), arena.live_payload);
    try std.testing.expectEqual(@as(usize, 2), arena.live_blocks);
    a.free(second);
    a.free(first);
}

test "remap shrink preserves an earlier free hole" {
    var bytes: [1024]u8 align(64) = undefined;
    var arena = Arena.init(&bytes);
    const a = arena.allocator();
    const hole = try a.alloc(u8, 64);
    const middle = try a.alloc(u8, 64);
    var tail = try a.alloc(u8, 128);
    const address = @intFromPtr(hole.ptr);
    a.free(hole);
    try std.testing.expect(tryRemap(a, tail, 16));
    tail = tail.ptr[0..16];
    const next = try a.alloc(u8, 32);
    try std.testing.expectEqual(address, @intFromPtr(next.ptr));
    a.free(next);
    a.free(tail);
    a.free(middle);
}

const Model = struct {
    const Live = struct { bytes: []u8, alignment: std.mem.Alignment };
    const Pending = struct { length: usize = 0, alignment: usize = 1 };
    const alignments = [_]std.mem.Alignment{ .@"1", .@"8", .@"16", .@"64" };
    arena: *Arena,
    values: [48]?Live = @splat(null),
    pending: Pending = .{},
    peak: usize = 0,
    length_max: usize = 2048,

    fn change(model: *Model, rng: std.Random, index: usize, live: Live) !void {
        const a = model.arena.allocator();
        if (rng.boolean()) {
            a.rawFree(live.bytes, live.alignment, @returnAddress());
            model.values[index] = null;
            return;
        }
        const length = rng.uintLessThan(usize, model.length_max) + 1;
        const before = model.arena.*;
        const moved = a.rawRemap(live.bytes, live.alignment, length, @returnAddress()) orelse
            return expectSameMetadata(before, model.arena.*);
        try testing.expectEqual(live.bytes.ptr, moved);
        const changed = moved[0..length];
        const kept = changed[0..@min(live.bytes.len, length)];
        try testing.expect(std.mem.allEqual(u8, kept, @intCast(index)));
        @memset(changed, @intCast(index));
        model.values[index] = .{ .bytes = changed, .alignment = live.alignment };
    }

    fn step(model: *Model, rng: std.Random, heads: []const *Arena.Block) !void {
        const index = rng.uintLessThan(usize, model.values.len);
        if (model.values[index]) |live| return model.change(rng, index, live);
        const length = rng.uintLessThan(usize, model.length_max) + 1;
        const alignment = alignments[rng.uintLessThan(usize, alignments.len)];
        model.pending = .{ .length = length, .alignment = alignment.toByteUnits() };
        const a = model.arena.allocator();
        const pointer = a.rawAlloc(length, alignment, @returnAddress()) orelse {
            try testing.expect(!anyAvailableFits(heads, length, alignment.toByteUnits()));
            return;
        };
        try testing.expect(alignment.check(@intFromPtr(pointer)));
        @memset(pointer[0..length], @intCast(index));
        model.values[index] = .{ .bytes = pointer[0..length], .alignment = alignment };
    }

    fn expectLaws(model: *Model, heads: []const *Arena.Block) !Walk {
        var live: usize = 0;
        var count: usize = 0;
        for (model.values, 0..) |value, id| if (value) |slice| {
            try testing.expect(std.mem.allEqual(u8, slice.bytes, @intCast(id)));
            live += slice.bytes.len;
            count += 1;
        };
        model.peak = @max(model.peak, live);
        try testing.expectEqual(live, model.arena.live_payload);
        try testing.expectEqual(count, model.arena.live_blocks);
        try testing.expectEqual(model.peak, model.arena.peak_payload);
        var total: Walk = .{};
        for (heads) |head| {
            const walk = try expectChain(head);
            total.allocated += walk.allocated;
            total.available += walk.available;
            total.end = walk.end;
            total.last = walk.last;
        }
        try testing.expectEqual(model.arena.tail, total.last);
        try testing.expectEqual(count, total.allocated);
        try expectIndexed(model.arena, total.available);
        return total;
    }

    fn release(model: *Model) void {
        const a = model.arena.allocator();
        for (&model.values) |*value| if (value.*) |live| {
            a.rawFree(live.bytes, live.alignment, @returnAddress());
            value.* = null;
        };
    }
};

test "random allocation free and remap preserve contents and the block partition" {
    var memory: [65536]u8 align(64) = undefined;
    var arena = Arena.init(&memory);
    var model: Model = .{ .arena = &arena };
    var random = std.Random.DefaultPrng.init(0x726573697a65);
    const rng = random.random();
    const heads = [_]*Arena.Block{chainHead(&memory)};
    for (0..10000) |_| {
        try model.step(rng, &heads);
        const walk = try model.expectLaws(&heads);
        try testing.expectEqual(@intFromPtr(&memory) + memory.len, walk.end);
    }
    model.release();
    try testing.expectEqual(@as(usize, 0), arena.live_payload);
    const whole = try expectChain(heads[0]);
    try testing.expectEqual(@as(usize, 1), whole.available);
    try testing.expectEqual(@intFromPtr(&memory) + memory.len, whole.end);
}

const Segments = struct {
    pool: *[6][2048]u8,
    order: [6]usize,
    pending: *const Model.Pending,
    handed: usize = 0,
    heads: [7]*Arena.Block = undefined,
    chains: usize = 0,
    end: usize = 0,
    grew_while_fitting: bool = false,

    fn grow(context: *anyopaque, minimum: usize) ?[]u8 {
        const self: *Segments = @ptrCast(@alignCast(context));
        const pending = self.pending.*;
        if (anyAvailableFits(self.heads[0..self.chains], pending.length, pending.alignment))
            self.grew_while_fitting = true;
        if (self.handed == self.order.len or minimum > self.pool[0].len) return null;
        const segment: []u8 = &self.pool[self.order[self.handed]];
        self.handed += 1;
        self.adopt(segment);
        return segment;
    }

    fn adopt(self: *Segments, segment: []u8) void {
        const head = chainHead(segment);
        if (self.chains == 0 or @intFromPtr(head) != self.end) {
            self.heads[self.chains] = head;
            self.chains += 1;
        }
        self.end = @intFromPtr(head) + segment.len;
    }
};

test "growth happens only when no available block can hold the request" {
    var pool: [6][2048]u8 align(64) = undefined;
    var initial: [2048]u8 align(64) = undefined;
    const orders = [_][6]usize{
        .{ 0, 1, 2, 3, 4, 5 },
        .{ 3, 1, 2, 0, 5, 4 },
        .{ 5, 4, 3, 2, 1, 0 },
    };
    for (orders) |order| {
        var arena = Arena.init(&initial);
        var model: Model = .{ .arena = &arena, .length_max = 3000 };
        var segments: Segments = .{ .pool = &pool, .order = order, .pending = &model.pending };
        segments.adopt(&initial);
        arena.grow = Segments.grow;
        arena.grow_context = &segments;
        var random = std.Random.DefaultPrng.init(0x67726f77 + order[0]);
        const rng = random.random();
        for (0..4000) |_| {
            try model.step(rng, segments.heads[0..segments.chains]);
            _ = try model.expectLaws(segments.heads[0..segments.chains]);
            try testing.expect(!segments.grew_while_fitting);
        }
        try testing.expect(segments.handed > 1);
        model.release();
        try testing.expectEqual(@as(usize, 0), arena.live_payload);
    }
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
