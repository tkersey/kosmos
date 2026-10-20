// Copyright (c) 2026 World contributors. MIT license.
//! Per-view lexical custody. Slot-indexed links permit constant-size splices;
//! closed scopes leave no historical chain behind. This owns ordering, not values.
const std = @import("std");
const data = @import("horos_data");
const Slots = @import("activation_slots.zig").Slots;
const Item = struct {
    previous: ?usize = null,
    next: ?usize = null,
    tail: usize = 0,
    child: ?usize = null,
};
pub const Nodes = Slots(Item);
pub const Error = Nodes.Error || error{InvalidState};
pub const State = struct {
    view: Nodes.Handle,
    slots: usize,
    scope: usize = 0,
    initialized: bool = false,
};

pub const Custody = struct {
    allocator: std.mem.Allocator,
    nodes: Nodes,

    pub fn init(allocator: std.mem.Allocator) Error!Custody {
        return .{ .allocator = allocator, .nodes = try Nodes.init(allocator) };
    }
    pub fn deinit(self: *Custody) void {
        self.nodes.deinit();
    }
    pub fn create(self: *Custody, slots: usize, scopes: usize) Error!State {
        const limit = std.math.add(usize, slots, scopes) catch return error.CapacityExceeded;
        return .{ .view = try self.nodes.create(limit), .slots = slots };
    }
    pub fn fork(self: *Custody, state: State) Nodes.Error!State {
        var result = state;
        result.view = try self.nodes.fork(state.view);
        return result;
    }
    pub fn release(self: *Custody, state: State) void {
        self.nodes.release(state.view) catch |err| std.debug.panic("{s}", .{@errorName(err)});
    }
    fn get(self: *Custody, state: State, index: usize) Error!Item {
        return self.nodes.get(state.view, index);
    }
    fn put(self: *Custody, state: State, index: usize, item: Item) Error!void {
        try self.nodes.set(state.view, index, item);
    }

    pub fn moveTo(
        self: *Custody,
        state: *State,
        scopes: []const data.activation.CustodyScope,
        target: usize,
    ) Error!void {
        if (state.scope == target) return;
        if (!state.initialized) {
            state.scope = target;
            return;
        }
        var common = state.scope;
        var candidate = target;
        while (common != candidate) {
            if (common > candidate)
                common = parentScope(scopes, common).?
            else
                candidate = parentScope(scopes, candidate).?;
        }
        var path: std.ArrayList(usize) = .empty;
        defer path.deinit(self.allocator);
        var cursor = target;
        while (cursor != common) {
            try path.append(self.allocator, cursor);
            cursor = parentScope(scopes, cursor).?;
        }
        while (state.scope != common)
            try self.leave(state, parentScope(scopes, state.scope).?);
        var index = path.items.len;
        while (index != 0) {
            index -= 1;
            try self.enter(state, path.items[index]);
        }
    }

    fn parentScope(scopes: []const data.activation.CustodyScope, scope: usize) ?usize {
        const parent = scopes[scope].parent orelse return null;
        std.debug.assert(parent < scope);
        return @intCast(parent);
    }

    fn ensure(
        self: *Custody,
        state: *State,
        scopes: []const data.activation.CustodyScope,
    ) Error!void {
        if (state.initialized) return;
        const target = state.scope;
        try self.put(state.*, state.slots, .{ .tail = state.slots });
        state.scope = 0;
        state.initialized = true;
        try self.moveTo(state, scopes, target);
    }

    fn enter(self: *Custody, state: *State, scope: usize) Error!void {
        const parent = state.slots + state.scope;
        const marker = state.slots + scope;
        var outer = try self.get(state.*, parent);
        outer.previous = marker;
        outer.child = marker;
        try self.put(state.*, marker, .{ .next = parent, .tail = marker });
        try self.put(state.*, parent, outer);
        state.scope = scope;
    }

    fn leave(self: *Custody, state: *State, parent_scope: usize) Error!void {
        const marker = state.slots + state.scope;
        const parent = state.slots + parent_scope;
        const inner = try self.get(state.*, marker);
        var outer = try self.get(state.*, parent);
        if (inner.child != null or outer.child != marker) return error.InvalidState;
        outer.previous = null;
        outer.child = null;
        if (inner.tail != marker) {
            const first = inner.next.?;
            var tail = try self.get(state.*, inner.tail);
            tail.next = outer.next;
            try self.put(state.*, inner.tail, tail);
            if (outer.next) |next| {
                var following = try self.get(state.*, next);
                following.previous = inner.tail;
                try self.put(state.*, next, following);
            }
            var head = try self.get(state.*, first);
            head.previous = parent;
            try self.put(state.*, first, head);
            outer.next = first;
            if (outer.tail == parent) outer.tail = inner.tail;
        }
        try self.put(state.*, parent, outer);
        try self.nodes.clear(state.view, marker);
        state.scope = parent_scope;
    }

    pub fn establish(
        self: *Custody,
        state: *State,
        scopes: []const data.activation.CustodyScope,
        slot: usize,
    ) Error!void {
        try self.ensure(state, scopes);
        try self.remove(state, slot);
        const marker = state.slots + state.scope;
        var scope = try self.get(state.*, marker);
        const last = scope.tail;
        var tail = try self.get(state.*, last);
        const next = tail.next;
        try self.put(state.*, slot, .{ .previous = last, .next = next });
        tail.next = slot;
        try self.put(state.*, last, tail);
        if (next) |index| {
            var following = try self.get(state.*, index);
            following.previous = slot;
            try self.put(state.*, index, following);
        }
        scope = try self.get(state.*, marker);
        scope.tail = slot;
        try self.put(state.*, marker, scope);
    }

    pub fn remove(self: *Custody, state: *State, slot: usize) Error!void {
        if (!state.initialized) return;
        const item = self.get(state.*, slot) catch |err| switch (err) {
            error.UninitializedSlot => return,
            else => return err,
        };
        const previous = item.previous orelse return error.InvalidState;
        var before = try self.get(state.*, previous);
        before.next = item.next;
        try self.put(state.*, previous, before);
        if (item.next) |next| {
            var after = try self.get(state.*, next);
            after.previous = previous;
            try self.put(state.*, next, after);
        }
        if (item.next == null or item.next.? >= state.slots) {
            const marker = if (item.next) |parent|
                (try self.get(state.*, parent)).child orelse return error.InvalidState
            else
                state.slots;
            var scope = try self.get(state.*, marker);
            scope.tail = previous;
            try self.put(state.*, marker, scope);
        }
        try self.nodes.clear(state.view, slot);
    }

    pub fn ordered(self: *Custody, state: State, allocator: std.mem.Allocator) Error![]usize {
        var result: std.ArrayList(usize) = .empty;
        errdefer result.deinit(allocator);
        if (!state.initialized) return result.toOwnedSlice(allocator);
        var next: ?usize = state.slots + state.scope;
        // Every live owner/marker appears once; reject a corrupt private cycle.
        const limit = (try self.nodes.lookupLimit(state.view));
        var count: usize = 0;
        while (next) |index| {
            if (count == limit) return error.InvalidState;
            count += 1;
            if (index < state.slots) try result.append(allocator, index);
            next = (try self.get(state, index)).next;
        }
        return result.toOwnedSlice(allocator);
    }

    /// Portable lexical order, excluding private markers, links and COW handles.
    pub fn project(
        self: *Custody,
        state: State,
        allocator: std.mem.Allocator,
    ) Error![]data.process_state.Owner {
        var result: std.ArrayList(data.process_state.Owner) = .empty;
        errdefer result.deinit(allocator);
        if (!state.initialized) return result.toOwnedSlice(allocator);
        var next: ?usize = state.slots + state.scope;
        var scope = state.scope;
        const limit = try self.nodes.lookupLimit(state.view);
        var count: usize = 0;
        while (next) |index| {
            if (count == limit) return error.InvalidState;
            count += 1;
            if (index < state.slots) {
                try result.append(allocator, .{ .scope = scope, .slot = index });
            } else scope = index - state.slots;
            next = (try self.get(state, index)).next;
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn restore(
        self: *Custody,
        state: *State,
        scopes: []const data.activation.CustodyScope,
        target: usize,
        owners: []const data.process_state.Owner,
    ) Error!void {
        var path: std.ArrayList(usize) = .empty;
        defer path.deinit(self.allocator);
        var cursor: ?usize = target;
        while (cursor) |scope| {
            try path.append(self.allocator, scope);
            cursor = parentScope(scopes, scope);
        }
        var end = owners.len;
        while (path.pop()) |scope| {
            try self.moveTo(state, scopes, scope);
            var start = end;
            while (start != 0 and owners[start - 1].scope == scope) start -= 1;
            for (owners[start..end]) |owner| try self.establish(
                state,
                scopes,
                @intCast(owner.slot),
            );
            end = start;
        }
        if (end != 0) return error.InvalidState;
    }
};
