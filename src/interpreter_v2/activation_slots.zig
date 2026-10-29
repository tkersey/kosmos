// Copyright (c) 2026 World contributors. MIT license.
//! Private, indexed activation storage. Values are descriptors; this store never
//! clones referenced objects, grants semantic ownership, or executes finalizers.
//! Handles and node addresses must never enter portable State or identity.
const std = @import("std");

const bits = 4;
const width = 1 << bits;
const maximum_depth = (@bitSizeOf(usize) - bits + bits - 1) / bits;

fn SlotLayout(comptime Value: type) type {
    return struct {
        const Node = union(enum) { empty, page: *Page, branch: *Branch };
        const Page = struct {
            references: usize = 1,
            initialized: u16 = 0,
            capacity: u8,
        };
        const page_alignment = std.mem.Alignment.fromByteUnits(
            @max(@alignOf(Page), @alignOf(Value)),
        );
        const value_offset = std.mem.alignForward(usize, @sizeOf(Page), @alignOf(Value));
        fn pageBytes(capacity: usize) usize {
            return value_offset + capacity * @sizeOf(Value);
        }
        const DensePage = struct {
            bytes: [pageBytes(width)]u8 align(page_alignment.toByteUnits()),
        };
        comptime {
            std.debug.assert(@sizeOf(DensePage) == pageBytes(width));
        }
        fn values(page: *Page) []Value {
            const bytes: [*]u8 = @ptrCast(page);
            const items: [*]Value = @ptrCast(@alignCast(bytes + value_offset));
            return items[0..page.capacity];
        }
        const Branch = struct { references: usize = 1, children: [width]Node = @splat(.empty) };
        const View = struct {
            generation: u64 = 1,
            revision: u64 = 0,
            active: bool = true,
            root: Node = .empty,
            // Active views carry a slot limit; retired views use the same word
            // for an intrusive free-list link. lookupView rejects retired views.
            limit: usize,
            depth: u8,
            owner: usize = std.math.maxInt(usize),
        };
        pub const Handle = struct { instance: u64, index: usize, generation: u64 };
        pub const Binding = struct { slot: usize, value: Value };
        pub const ReadError = error{ InvalidHandle, InvalidSlot, UninitializedSlot };
        pub const Error = std.mem.Allocator.Error || error{
            InvalidHandle,
            InvalidSlot,
            UninitializedSlot,
            CapacityExceeded,
            InvalidSelection,
            StaleIterator,
        };
        pub const Statistics = struct {
            live_pages: usize = 0,
            live_directories: usize = 0,
            peak_pages: usize = 0,
            value_copies: u64 = 0,
            directory_copies: u64 = 0,
            writes: u64 = 0,
            live_page_bytes: usize = 0,
            peak_page_bytes: usize = 0,
            packed_moves: u64 = 0,
        };
    };
}

fn SlotIterator(comptime Store: type) type {
    return struct {
        const Visit = struct { node: Store.Node, depth: u8, base: usize };
        store: *Store,
        handle: Store.Handle,
        revision: u64,
        pending: [maximum_depth * (width - 1) + 1]Visit = undefined,
        length: usize = 0,
        page: ?*Store.Page = null,
        live: u16 = 0,
        base: usize = 0,

        pub fn next(self: *@This()) Store.Error!?Store.Binding {
            if ((try self.store.lookupView(self.handle)).revision != self.revision)
                return error.StaleIterator;
            while (self.live == 0) {
                if (self.length == 0) return null;
                self.length -= 1;
                const current = self.pending[self.length];
                if (current.depth == 0) {
                    self.page = current.node.page;
                    self.live = current.node.page.initialized;
                    self.base = current.base;
                } else {
                    var index: usize = width;
                    while (index != 0) {
                        index -= 1;
                        const child = current.node.branch.children[index];
                        if (child == .empty) continue;
                        std.debug.assert(self.length < self.pending.len);
                        self.pending[self.length] = .{
                            .node = child,
                            .depth = current.depth - 1,
                            .base = current.base | (index << @intCast(bits * current.depth)),
                        };
                        self.length += 1;
                    }
                }
            }
            const index = @ctz(self.live);
            self.live &= self.live - 1;
            return .{ .slot = self.base + index, .value = Store.values(self.page.?)[
                Store.physicalIndex(self.page.?, self.page.?.initialized, index)
            ] };
        }
    };
}

pub fn Slots(comptime Value: type) type {
    return struct {
        const Self = @This();
        const Layout = SlotLayout(Value);
        const Node = Layout.Node;
        const Page = Layout.Page;
        const Branch = Layout.Branch;
        const View = Layout.View;
        const DensePage = Layout.DensePage;
        const page_alignment = Layout.page_alignment;
        const pageBytes = Layout.pageBytes;
        const values = Layout.values;
        pub const Handle = Layout.Handle;
        pub const Binding = Layout.Binding;
        pub const ReadError = Layout.ReadError;
        pub const Error = Layout.Error;
        pub const Statistics = Layout.Statistics;
        fn rank(initialized: u16, slot: usize) usize {
            if (slot & (width - 1) == 0) return 0;
            return @popCount(initialized & (mask(slot) - 1));
        }
        fn physicalIndex(page: *const Page, initialized: u16, slot: usize) usize {
            return if (page.capacity == width) slot & (width - 1) else rank(initialized, slot);
        }
        fn createPage(self: *Self, count: usize) Error!*Page {
            const capacity = std.math.ceilPowerOfTwoAssert(usize, @max(1, count));
            const page: *Page = if (capacity == width)
                @ptrCast(try self.allocator.create(DensePage))
            else blk: {
                const bytes = try self.allocator.alignedAlloc(
                    u8,
                    page_alignment,
                    pageBytes(capacity),
                );
                break :blk @ptrCast(bytes.ptr);
            };
            page.* = .{ .capacity = @intCast(capacity) };
            self.statistics.live_pages += 1;
            self.statistics.peak_pages = @max(
                self.statistics.peak_pages,
                self.statistics.live_pages,
            );
            self.statistics.live_page_bytes += pageBytes(capacity);
            self.statistics.peak_page_bytes = @max(
                self.statistics.peak_page_bytes,
                self.statistics.live_page_bytes,
            );
            return page;
        }

        allocator: std.mem.Allocator,
        instance: u64,
        views: std.ArrayList(View) = .empty,
        free_view: usize = std.math.maxInt(usize),
        statistics: Statistics = .{},
        before_mutation: ?*const fn (*Self, usize) Error!void = null,
        var next_instance = std.atomic.Value(usize).init(1);

        pub fn init(allocator: std.mem.Allocator) Error!Self {
            var current = next_instance.load(.monotonic);
            while (current < std.math.maxInt(usize)) { // tiger: event-loop
                if (next_instance.cmpxchgWeak(
                    current,
                    current + 1,
                    .monotonic,
                    .monotonic,
                )) |next| {
                    current = next;
                } else return .{ .allocator = allocator, .instance = current };
            }
            return error.CapacityExceeded;
        }

        pub fn deinit(self: *Self) void {
            for (self.views.items) |view| if (view.active) self.drop(view.root);
            self.views.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn retainedBytes(self: *const Self) usize {
            return self.statistics.live_page_bytes +
                self.statistics.live_directories * @sizeOf(Branch) +
                self.views.capacity * @sizeOf(View);
        }

        pub fn create(self: *Self, limit: usize) Error!Handle {
            var high = if (limit == 0) 0 else (limit - 1) >> bits;
            var depth: u8 = 0;
            while (high != 0) : (high >>= bits) depth += 1;
            return self.addView(.{ .limit = limit, .depth = depth });
        }

        fn addView(self: *Self, view: View) Error!Handle {
            var result = view;
            const index = if (self.free_view != std.math.maxInt(usize)) blk: {
                const free = self.free_view;
                std.debug.assert(!self.views.items[free].active);
                self.free_view = self.views.items[free].limit;
                result.generation = self.views.items[free].generation;
                self.views.items[free] = result;
                break :blk free;
            } else blk: {
                try self.views.ensureUnusedCapacity(self.allocator, 1);
                const id = self.views.items.len;
                self.views.appendAssumeCapacity(result);
                break :blk id;
            };
            return .{ .instance = self.instance, .index = index, .generation = result.generation };
        }

        fn lookupView(self: *Self, handle: Handle) error{InvalidHandle}!*View {
            if (handle.instance != self.instance or handle.index >= self.views.items.len)
                return error.InvalidHandle;
            const result = &self.views.items[handle.index];
            if (!result.active or result.generation != handle.generation)
                return error.InvalidHandle;
            return result;
        }

        pub fn fork(self: *Self, handle: Handle) Error!Handle {
            var copy = (try self.lookupView(handle)).*;
            copy.root = try retain(copy.root);
            errdefer self.drop(copy.root);
            copy.revision = 0;
            copy.owner = std.math.maxInt(usize);
            return self.addView(copy);
        }

        pub fn registerOwner(self: *Self, handle: Handle, owner: usize) Error!void {
            (try self.lookupView(handle)).owner = owner;
        }

        pub fn canTransfer(self: *Self, handle: Handle) error{InvalidHandle}!bool {
            return (try self.lookupView(handle)).generation != std.math.maxInt(u64);
        }

        pub fn transfer(self: *Self, handle: Handle) error{
            InvalidHandle,
            CapacityExceeded,
        }!Handle {
            const entry = try self.lookupView(handle);
            if (entry.generation == std.math.maxInt(u64)) return error.CapacityExceeded;
            entry.generation += 1;
            var result = handle;
            result.generation = entry.generation;
            return result;
        }

        pub fn protect(self: *Self, handle: Handle) Error!void {
            const owner = (try self.lookupView(handle)).owner;
            if (owner != std.math.maxInt(usize)) {
                if (self.before_mutation) |before| try before(self, owner);
            }
        }

        pub fn release(self: *Self, handle: Handle) Error!void {
            const entry = try self.lookupView(handle);
            // Protection may fork a view and relocate the handle table.
            self.views.lockPointers();
            defer self.views.unlockPointers();
            self.retire(handle.index, entry);
        }

        fn retire(self: *Self, index: usize, entry: *View) void {
            const root = entry.root;
            entry.active = false;
            entry.root = .empty;
            if (entry.generation != std.math.maxInt(u64)) {
                entry.generation += 1;
                // No allocation or extra array capacity is needed to retire.
                entry.limit = self.free_view;
                self.free_view = index;
            }
            self.drop(root);
        }

        pub fn commit(self: *Self, target: Handle, candidate: Handle) Error!void {
            if (target.index == candidate.index) return error.InvalidHandle;
            {
                const destination = try self.lookupView(target);
                const source = try self.lookupView(candidate);
                if (destination.limit != source.limit or destination.depth != source.depth)
                    return error.InvalidSelection;
                if (destination.revision == std.math.maxInt(u64)) return error.CapacityExceeded;
            }
            try self.protect(target);
            self.views.lockPointers();
            defer self.views.unlockPointers();
            const destination = try self.lookupView(target);
            const source = try self.lookupView(candidate);
            const previous = destination.root;
            destination.root = source.root;
            source.root = .empty;
            destination.revision += 1;
            self.retire(candidate.index, source);
            self.drop(previous);
        }

        pub fn get(self: *Self, handle: Handle, slot: usize) ReadError!Value {
            const entry = try self.lookupView(handle);
            if (slot >= entry.limit) return error.InvalidSlot;
            const page = locate(entry.root, entry.depth, slot) orelse
                return error.UninitializedSlot;
            if (page.initialized & mask(slot) == 0) return error.UninitializedSlot;
            return values(page)[physicalIndex(page, page.initialized, slot)];
        }

        pub fn lookupLimit(self: *Self, handle: Handle) error{InvalidHandle}!usize {
            return (try self.lookupView(handle)).limit;
        }

        pub const Reader = struct {
            store: *Self,
            handle: Handle,

            pub fn at(self: Reader, slot: usize) ReadError!Value {
                return self.store.get(self.handle, slot);
            }
        };

        pub fn reader(self: *Self, handle: Handle) ReadError!Reader {
            _ = try self.lookupView(handle);
            return .{ .store = self, .handle = handle };
        }

        pub fn set(self: *Self, handle: Handle, slot: usize, value: Value) Error!void {
            try self.change(handle, slot, value);
        }

        pub fn clear(self: *Self, handle: Handle, slot: usize) Error!void {
            try self.change(handle, slot, null);
        }

        fn change(self: *Self, handle: Handle, slot: usize, value: ?Value) Error!void {
            {
                const entry = try self.lookupView(handle);
                if (slot >= entry.limit) return error.InvalidSlot;
                if (entry.revision == std.math.maxInt(u64)) return error.CapacityExceeded;
                if (value == null) {
                    const page = locate(entry.root, entry.depth, slot) orelse return;
                    if (page.initialized & mask(slot) == 0) return;
                }
            }
            try self.protect(handle);
            self.views.lockPointers();
            defer self.views.unlockPointers();
            const entry = try self.lookupView(handle);
            try self.changeOwned(&entry.root, entry.depth, slot, value);
            entry.revision += 1;
            self.statistics.writes +|= 1;
        }

        pub fn retainOnly(self: *Self, handle: Handle, selected: []const usize) Error!void {
            const original = (try self.lookupView(handle)).*;
            if (original.revision == std.math.maxInt(u64)) return error.CapacityExceeded;
            for (selected, 0..) |slot, index| {
                if (index != 0 and selected[index - 1] >= slot) return error.InvalidSelection;
                _ = try self.get(handle, slot);
            }
            const temporary = try self.create(original.limit);
            defer self.release(temporary) catch |err| std.debug.panic("{s}", .{@errorName(err)});
            for (selected) |slot| try self.set(temporary, slot, try self.get(handle, slot));
            try self.protect(handle);
            self.views.lockPointers();
            defer self.views.unlockPointers();
            const replacement = try self.lookupView(temporary);
            const entry = try self.lookupView(handle);
            const previous = entry.root;
            entry.root = replacement.root;
            replacement.root = .empty;
            entry.revision += 1;
            self.drop(previous);
        }

        fn changed(self: *Self, node: Node, depth: u8, slot: usize, value: ?Value) Error!Node {
            std.debug.assert(depth <= maximum_depth);
            var ancestors: [maximum_depth]Node = undefined;
            var current = node;
            var remaining = depth;
            while (remaining != 0) : (remaining -= 1) {
                ancestors[remaining - 1] = current;
                current = if (current == .empty)
                    .empty
                else
                    current.branch.children[childIndex(remaining, slot)];
            }
            var child = try self.changedPage(current, slot, value);
            errdefer self.drop(child);
            for (ancestors[0..depth], 1..) |ancestor, level|
                child = try self.changedBranch(ancestor, @intCast(level), slot, child);
            return child;
        }

        fn changedBranch(
            self: *Self,
            node: Node,
            depth: u8,
            slot: usize,
            child: Node,
        ) Error!Node {
            const index = childIndex(depth, slot);
            if (child == .empty and (node == .empty or
                onlyChild(node.branch, index))) return .empty;
            const result = try self.allocator.create(Branch);
            result.* = .{};
            self.statistics.live_directories += 1;
            errdefer self.drop(.{ .branch = result });
            if (node == .branch) for (node.branch.children, 0..) |other, i| {
                if (i == index) continue;
                result.children[i] = try retain(other);
                if (other != .empty) self.statistics.directory_copies +|= 1;
            };
            result.children[index] = child;
            return .{ .branch = result };
        }

        fn changedPage(self: *Self, node: Node, slot: usize, value: ?Value) Error!Node {
            if (value == null and (node == .empty or node.page.initialized == mask(slot)))
                return .empty;
            const before: u16 = if (node == .page) node.page.initialized else 0;
            const after = if (value != null) before | mask(slot) else before & ~mask(slot);
            // Preserve ordinary unique growth without copying prior values.
            // Sparse allocation is earned at a COW boundary, where copying is
            // already required to isolate a retained activation version.
            const capacity = if (node == .empty or
                node.page.references == 1) width else @popCount(after);
            const page = try self.createPage(capacity);
            if (node == .page) {
                // Copy only the resulting live values; a removed slot need not
                // fit into the smaller successor's storage.
                const destination = values(page);
                const source = values(node.page);
                const dense_destination = page.capacity == width;
                const dense_source = node.page.capacity == width;
                var packed_index: usize = 0;
                var live = after;
                while (live != 0) {
                    const index = @ctz(live);
                    const destination_index = if (dense_destination) index else packed_index;
                    if (index == (slot & (width - 1)) and value != null) {
                        destination[destination_index] = value.?;
                    } else {
                        destination[destination_index] = source[
                            if (dense_source) index else rank(before, index)
                        ];
                        self.statistics.value_copies +|= 1;
                    }
                    packed_index += 1;
                    live &= live - 1;
                }
            } else values(page)[physicalIndex(page, after, slot)] = value.?;
            page.initialized = after;
            return .{ .page = page };
        }

        fn changeOwned(self: *Self, node: *Node, depth: u8, slot: usize, value: ?Value) Error!void {
            std.debug.assert(depth <= maximum_depth);
            var ancestors: [maximum_depth]*Node = undefined;
            var current = node;
            var remaining = depth;
            while (remaining != 0 and current.* == .branch and
                current.branch.references == 1) : (remaining -= 1)
            {
                ancestors[remaining - 1] = current;
                current = &current.branch.children[childIndex(remaining, slot)];
            }
            if (remaining == 0 and current.* == .page and current.page.references == 1) {
                try self.changeUniquePage(current, slot, value);
            } else {
                const successor = try self.changed(current.*, remaining, slot, value);
                const previous = current.*;
                current.* = successor;
                self.drop(previous);
            }
            for (ancestors[remaining..depth]) |ancestor| {
                for (ancestor.branch.children) |child| if (child != .empty) return;
                self.drop(ancestor.*);
                ancestor.* = .empty;
            }
        }

        fn changeUniquePage(self: *Self, node: *Node, slot: usize, value: ?Value) Error!void {
            if (node.page.capacity != width and
                value != null and node.page.initialized & mask(slot) == 0 and
                @popCount(node.page.initialized) == node.page.capacity)
            {
                const successor = try self.changedPage(node.*, slot, value);
                self.drop(node.*);
                node.* = successor;
            } else {
                self.assign(node.page, slot, value);
                if (node.page.initialized == 0) {
                    self.drop(node.*);
                    node.* = .empty;
                }
            }
        }

        fn assign(self: *Self, page: *Page, slot: usize, value: ?Value) void {
            if (page.capacity == width) {
                const index = slot & (width - 1);
                if (value) |present| {
                    values(page)[index] = present;
                    page.initialized |= mask(slot);
                } else {
                    page.initialized &= ~mask(slot);
                    values(page)[index] = undefined;
                }
                return;
            }
            const index = rank(page.initialized, slot);
            const items = values(page);
            if (value) |present| {
                if (page.initialized & mask(slot) != 0) {
                    items[index] = present;
                    return;
                }
                const count: usize = @popCount(page.initialized);
                std.mem.copyBackwards(Value, items[index + 1 .. count + 1], items[index..count]);
                self.statistics.packed_moves +|= count - index;
                items[index] = present;
                page.initialized |= mask(slot);
            } else {
                const count: usize = @popCount(page.initialized);
                std.mem.copyForwards(Value, items[index .. count - 1], items[index + 1 .. count]);
                self.statistics.packed_moves +|= count - index - 1;
                page.initialized &= ~mask(slot);
                items[count - 1] = undefined;
            }
        }

        fn mask(slot: usize) u16 {
            return @as(u16, 1) << @intCast(slot & (width - 1));
        }

        fn childIndex(depth: u8, slot: usize) usize {
            std.debug.assert(depth > 0 and depth <= maximum_depth);
            return (slot >> @intCast(bits * depth)) & (width - 1);
        }

        fn locate(root: Node, levels: u8, slot: usize) ?*Page {
            var node = root;
            var depth = levels;
            while (node != .empty) {
                if (depth == 0) return node.page;
                node = node.branch.children[childIndex(depth, slot)];
                depth -= 1;
            }
            return null;
        }

        fn onlyChild(branch: *Branch, index: usize) bool {
            for (branch.children, 0..) |child, i| if (i != index and child != .empty) return false;
            return true;
        }

        fn retain(node: Node) Error!Node {
            const references = switch (node) {
                .empty => return .empty,
                .page => |page| &page.references,
                .branch => |branch| &branch.references,
            };
            references.* = std.math.add(usize, references.*, 1) catch return error.CapacityExceeded;
            return node;
        }

        fn drop(self: *Self, node: Node) void {
            switch (node) {
                .empty => {},
                .page => |page| self.dropPage(page),
                .branch => |branch| self.dropBranch(branch),
            }
        }

        noinline fn dropBranch(self: *Self, root: *Branch) void {
            const Visit = struct { node: Node, release: bool = false };
            var pending: [maximum_depth * width + 1]Visit = undefined;
            pending[0] = .{ .node = .{ .branch = root } };
            var length: usize = 1;
            while (length != 0) {
                length -= 1;
                const current = pending[length];
                switch (current.node) {
                    .empty => {},
                    .page => |page| self.dropPage(page),
                    .branch => |branch| {
                        if (current.release) {
                            self.statistics.live_directories -= 1;
                            self.allocator.destroy(branch);
                            continue;
                        }
                        std.debug.assert(branch.references != 0);
                        branch.references -= 1;
                        if (branch.references != 0) continue;
                        std.debug.assert(length + width + 1 <= pending.len);
                        pending[length] = .{ .node = current.node, .release = true };
                        length += 1;
                        var index: usize = width;
                        while (index != 0) {
                            index -= 1;
                            pending[length] = .{ .node = branch.children[index] };
                            length += 1;
                        }
                    },
                }
            }
        }

        fn dropPage(self: *Self, page: *Page) void {
            std.debug.assert(page.references != 0);
            page.references -= 1;
            if (page.references != 0) return;
            self.statistics.live_pages -= 1;
            const size = pageBytes(page.capacity);
            self.statistics.live_page_bytes -= size;
            if (page.capacity == width) {
                const dense: *DensePage = @ptrCast(@alignCast(page));
                self.allocator.destroy(dense);
            } else {
                const bytes: [*]align(page_alignment.toByteUnits()) u8 =
                    @ptrCast(@alignCast(page));
                self.allocator.free(bytes[0..size]);
            }
        }
        pub fn iterator(self: *Self, handle: Handle) Error!Iterator {
            const entry = try self.lookupView(handle);
            var result: Iterator = .{
                .store = self,
                .handle = handle,
                .revision = entry.revision,
            };
            if (entry.root != .empty) {
                result.pending[0] = .{ .node = entry.root, .depth = entry.depth, .base = 0 };
                result.length = 1;
            }
            return result;
        }

        pub const Iterator = SlotIterator(Self);
    };
}

pub const ActivationSlots = Slots(@import("horos_data").graph.Value);

test "maximum-depth slots retain and release sparse shared paths" {
    var store = try Slots(u64).init(std.testing.allocator);
    defer store.deinit();
    const limit = std.math.maxInt(usize);
    const original = try store.create(limit);
    try store.set(original, 0, 10);
    try store.set(original, limit - 1, 20);
    const successor = try store.fork(original);
    try store.set(successor, limit - 1, 30);
    try std.testing.expectEqual(20, try store.get(original, limit - 1));
    try std.testing.expectEqual(30, try store.get(successor, limit - 1));
    try store.clear(successor, 0);
    try store.clear(successor, limit - 1);
    try std.testing.expectEqual(10, try store.get(original, 0));
    try std.testing.expectError(error.UninitializedSlot, store.get(successor, limit - 1));
    try store.release(original);
    try store.release(successor);
    try std.testing.expectEqual(0, store.statistics.live_pages);
    try std.testing.expectEqual(0, store.statistics.live_directories);
}

test "retained bytes match allocator storage across dense and packed page lifetimes" {
    var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var store = try Slots(u64).init(counter.allocator());
    defer store.deinit();
    const original = try store.create(32);
    try store.set(original, 0, 1);
    try store.set(original, 31, 2);
    try std.testing.expectEqual(
        counter.allocated_bytes - counter.freed_bytes,
        store.retainedBytes(),
    );
    const branch = try store.fork(original);
    try store.set(branch, 0, 3);
    try std.testing.expectEqual(
        counter.allocated_bytes - counter.freed_bytes,
        store.retainedBytes(),
    );
    try store.clear(branch, 31);
    try store.release(original);
    try std.testing.expectEqual(
        counter.allocated_bytes - counter.freed_bytes,
        store.retainedBytes(),
    );
    try store.release(branch);
    try std.testing.expectEqual(
        counter.allocated_bytes - counter.freed_bytes,
        store.retainedBytes(),
    );
}

test "sparse retained pages pack distinct logical slots and preserve predecessor views" {
    const S = Slots(u64);
    var store = try S.init(std.testing.allocator);
    defer store.deinit();
    const original = try store.create(16);
    defer store.release(original) catch |err| std.debug.panic("{s}", .{@errorName(err)});
    try store.set(original, 0, 10);
    try store.set(original, 15, 20);
    const before = store.statistics.live_page_bytes;
    const active = try store.fork(original);
    defer store.release(active) catch |err| std.debug.panic("{s}", .{@errorName(err)});
    try store.set(active, 0, 11);
    const page = S.locate((try store.lookupView(active)).root, 0, 0).?;
    try std.testing.expectEqual(@as(u8, 2), page.capacity);
    try std.testing.expectEqual(S.pageBytes(2), store.statistics.live_page_bytes - before);
    try std.testing.expect(S.pageBytes(2) < before);
    try std.testing.expectEqual(@as(u64, 10), try store.get(original, 0));
    try std.testing.expectEqual(@as(u64, 20), try store.get(original, 15));
    const reusable_address = &S.values(page)[0];
    try store.clear(active, 0);
    try std.testing.expectError(error.UninitializedSlot, store.get(active, 0));
    try std.testing.expectEqual(@as(u64, 20), try store.get(active, 15));
    try std.testing.expectEqual(
        reusable_address,
        &S.values(page)[S.physicalIndex(page, page.initialized, 15)],
    );
    var iterator = try store.iterator(active);
    try std.testing.expectEqual(@as(usize, 15), (try iterator.next()).?.slot);
    try std.testing.expect(try iterator.next() == null);
    try store.set(active, 7, 99);
    try std.testing.expectEqual(@as(u64, 99), try store.get(active, 7));
    try std.testing.expectEqual(@as(u64, 20), try store.get(active, 15));
    try store.set(active, 8, 88); // Growth returns to ordinary dense storage.
    try std.testing.expectEqual(@as(u64, 99), try store.get(active, 7));
    try std.testing.expectEqual(@as(u64, 88), try store.get(active, 8));
    try std.testing.expectEqual(@as(u64, 20), try store.get(active, 15));
    try std.testing.expectError(error.UninitializedSlot, store.get(original, 7));
}

test "packed page lookup and iteration match every eight-position occupancy subset" {
    const S = Slots(u64);
    for (0..256) |subset| {
        var store = try S.init(std.testing.allocator);
        defer store.deinit();
        const original = try store.create(16);
        defer store.release(original) catch |err| std.debug.panic("{s}", .{@errorName(err)});
        // Noncontiguous logical positions include both ends of the page.
        const positions = [_]usize{ 0, 2, 4, 6, 9, 11, 13, 15 };
        for (positions, 0..) |slot, bit| if (subset & (@as(
            usize,
            1,
        ) << @intCast(
            bit,
        )) != 0) try store.set(original, slot, slot + 100);
        for (0..16) |changed| for ([_]bool{ false, true }) |insert| {
            const active = try store.fork(original);
            defer store.release(active) catch |err| std.debug.panic("{s}", .{@errorName(err)});
            if (insert) try store.set(active, changed, 999) else try store.clear(active, changed);
            var iterator = try store.iterator(active);
            for (0..16) |slot| {
                const bit = std.mem.indexOfScalar(usize, &positions, slot);
                const present = if (bit) |i| subset & (@as(
                    usize,
                    1,
                ) << @intCast(
                    i,
                )) != 0 else false;
                if (present) try std.testing.expectEqual(
                    @as(u64, slot + 100),
                    try store.get(original, slot),
                ) else try std.testing.expectError(
                    error.UninitializedSlot,
                    store.get(original, slot),
                );
                const current = if (slot == changed) insert else present;
                if (current) {
                    const expected: u64 = if (slot == changed) 999 else slot + 100;
                    try std.testing.expectEqual(expected, try store.get(active, slot));
                    const binding = (try iterator.next()).?;
                    try std.testing.expectEqual(slot, binding.slot);
                    try std.testing.expectEqual(expected, binding.value);
                } else try std.testing.expectError(
                    error.UninitializedSlot,
                    store.get(active, slot),
                );
            }
            try std.testing.expect(try iterator.next() == null);
        };
    }
}

test "trailing packed payload preserves over-aligned and zero-sized values" {
    const Wide = struct { number: u64 align(32) };
    inline for (.{ Wide, void }) |Value| {
        const S = Slots(Value);
        var store = try S.init(std.testing.allocator);
        defer store.deinit();
        const original = try store.create(16);
        defer store.release(original) catch |err| std.debug.panic("{s}", .{@errorName(err)});
        const first: Value = if (Value == void) {} else .{ .number = 42 };
        const second: Value = if (Value == void) {} else .{ .number = 99 };
        try store.set(original, 15, first);
        const active = try store.fork(original);
        defer store.release(active) catch |err| std.debug.panic("{s}", .{@errorName(err)});
        try store.set(active, 0, second);
        try std.testing.expectEqualDeep(first, try store.get(original, 15));
        try std.testing.expectEqualDeep(first, try store.get(active, 15));
        try std.testing.expectEqualDeep(second, try store.get(active, 0));
        const page = S.locate((try store.lookupView(active)).root, 0, 0).?;
        try std.testing.expectEqual(
            @as(usize, 0),
            @intFromPtr(S.values(page).ptr) % @alignOf(Value),
        );
    }
}

fn packedGrowthFailure(allocator: std.mem.Allocator) !void {
    const S = Slots(u64);
    var store = try S.init(allocator);
    defer store.deinit();
    const original = try store.create(16);
    defer store.release(original) catch |err| std.debug.panic("{s}", .{@errorName(err)});
    try store.set(original, 15, 42);
    const active = try store.fork(original);
    defer store.release(active) catch |err| std.debug.panic("{s}", .{@errorName(err)});
    try store.set(active, 15, 99);
    const page = S.locate((try store.lookupView(active)).root, 0, 15).?;
    try std.testing.expectEqual(@as(u8, 1), page.capacity);
    store.set(active, 0, 7) catch |err| {
        try std.testing.expectEqual(@as(u64, 42), try store.get(original, 15));
        try std.testing.expectEqual(@as(u64, 99), try store.get(active, 15));
        try std.testing.expectError(error.UninitializedSlot, store.get(active, 0));
        try std.testing.expectEqual(page, S.locate((try store.lookupView(active)).root, 0, 15).?);
        return err;
    };
    try std.testing.expectEqual(@as(u64, 42), try store.get(original, 15));
    try std.testing.expectEqual(@as(u64, 99), try store.get(active, 15));
    try std.testing.expectEqual(@as(u64, 7), try store.get(active, 0));
}

test "sparse-to-dense allocation failure leaves both activation versions intact" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, packedGrowthFailure, .{});
}
