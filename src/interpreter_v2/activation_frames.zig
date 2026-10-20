// Copyright (c) 2026 World contributors. MIT license.
//! Private control-node bindings. Every registered frame owns one slot view.
const std = @import("std");
const data = @import("horos_data");
const Slots = @import("activation_slots.zig").ActivationSlots;
const sets = data.analysis_sets;
const custody = @import("custody.zig");
pub const Layouts = @import("frame_layouts.zig").Layouts;
pub const Error = Slots.Error || data.graph_order.Error;
// A pruning bound may include uninitialized slots. Small bounds stay inline.
pub const Bound = union(enum) {
    bits: u64,
    tree: sets.Root,

    fn changed(self: Bound, pool: *sets.Pool, slot: u64, add: bool) Error!Bound {
        return switch (self) {
            .bits => |bits| blk: {
                if (slot >= 64) return error.InvalidSlot;
                const bit = @as(u64, 1) << @intCast(slot);
                break :blk .{ .bits = if (add) bits | bit else bits & ~bit };
            },
            .tree => |root| .{ .tree = if (add)
                try pool.insert(root, slot)
            else
                try pool.remove(root, slot) },
        };
    }
    pub fn contains(self: Bound, pool: *const sets.Pool, slot: u64) bool {
        return switch (self) {
            .bits => |bits| slot < 64 and bits & (@as(u64, 1) << @intCast(slot)) != 0,
            .tree => |root| pool.contains(root, slot),
        };
    }
    fn iterator(self: Bound, pool: *const sets.Pool) Iterator {
        return switch (self) {
            .bits => |bits| .{ .bits = bits },
            .tree => |root| .{ .tree = pool.iterator(root) },
        };
    }
    const Iterator = union(enum) {
        bits: u64,
        tree: sets.Iterator,
        fn next(self: *Iterator) ?u64 {
            return switch (self.*) {
                .bits => |*bits| blk: {
                    if (bits.* == 0) break :blk null;
                    const slot = @ctz(bits.*);
                    bits.* &= bits.* - 1;
                    break :blk slot;
                },
                .tree => |*tree| tree.next(),
            };
        }
    };
};
pub const Frame = struct {
    view: Slots.Handle,
    // Reclamation upper bound, never evidence that a slot is initialized.
    live_bound: Bound,
    position: usize = 0,
    function: data.program.Id,
    custody: custody.State,
};
pub const Frames = struct {
    allocator: std.mem.Allocator,
    slots: Slots,
    pool: *sets.Pool,
    layouts: *const Layouts,
    custody: custody.Custody,
    entries: std.AutoHashMapUnmanaged(data.program.Id, Frame) = .empty,
    journal: ?Journal = null,
    borrowed: ?data.program.Id = null,
    // One pointer is the ordinary evaluator case. Additional simultaneous
    // low-level borrows have a set bounded by those borrows, not retained frames.
    borrowed_more: std.AutoHashMapUnmanaged(data.program.Id, void) = .empty,
    /// Diagnostic work includes failed attempts; never portable or rolled back.
    statistics: Statistics = .{},

    pub const Statistics = struct {
        saved_entries: u64 = 0,
        forked_frames: u64 = 0,
        moved_frames: u64 = 0,
        commit_entries: u64 = 0,
        rollback_entries: u64 = 0,
        borrowed_entries: u64 = 0,
        released_borrows: u64 = 0,
    };
    const Journal = struct {
        node_count: usize,
        // The ordinary drive changes one frame. Keep that saved owner here;
        // additional entries retain expected constant-time lookup.
        first: ?struct { id: data.program.Id, frame: ?Frame } = null,
        entries: std.AutoHashMapUnmanaged(data.program.Id, ?Frame) = .empty,
        // The entry extent itself is an initially safe (absent-at-entry) key.
        // Later keys are protected journal members; neither needs a tag.
        last_held: data.program.Id,

        fn contains(self: *const Journal, id: data.program.Id) bool {
            if (self.first) |first| if (first.id == id) return true;
            return self.entries.contains(id);
        }
        fn reserve(self: *Journal, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
            if (self.first != null) try self.entries.ensureUnusedCapacity(allocator, 1);
        }
        fn save(self: *Journal, id: data.program.Id, frame: ?Frame) void {
            if (self.first == null) {
                self.first = .{ .id = id, .frame = frame };
            } else self.entries.putAssumeCapacity(id, frame);
        }
    };

    /// Frame IDs are Store node IDs. IDs at or above this entry extent have no
    /// entry frame; Store's append extent accounts for them without per-frame
    /// bookkeeping. Reused older IDs still require an explicit absent entry.
    pub fn begin(self: *Frames, node_count: usize) Error!void {
        if (self.journal != null) return error.InvalidState;
        self.journal = .{ .node_count = node_count, .last_held = node_count };
        errdefer self.commit(); // Only protection ran; entry contents are intact.
        if (self.borrowed) |id| {
            try self.hold(id);
            self.statistics.borrowed_entries +|= 1;
        }
        var borrowed = self.borrowed_more.keyIterator();
        while (borrowed.next()) |id| {
            try self.hold(id.*);
            self.statistics.borrowed_entries +|= 1;
        }
        self.slots.before_mutation = protectSlotRoot;
        self.custody.nodes.before_mutation = protectCustodyRoot;
    }
    fn protectSlotRoot(slots: *Slots, id: usize) Slots.Error!void {
        const self: *Frames = @fieldParentPtr("slots", slots);
        try self.hold(id);
    }
    fn protectCustodyRoot(nodes: *custody.Nodes, id: usize) custody.Nodes.Error!void {
        const owner: *custody.Custody = @fieldParentPtr("nodes", nodes);
        const self: *Frames = @fieldParentPtr("custody", owner);
        try self.hold(id);
    }
    inline fn hold(self: *Frames, id: data.program.Id) Slots.Error!void {
        const journal = if (self.journal) |*value| value else return;
        if (journal.last_held == id or id >= journal.node_count) return;
        return self.holdEntry(id, journal);
    }
    // Keep fresh/no-transaction and repeated active-frame acquisition cheap;
    // allocation and persistent-root preparation belong to first touch.
    noinline fn holdEntry(self: *Frames, id: data.program.Id, journal: *Journal) Slots.Error!void {
        if (journal.contains(id)) {
            journal.last_held = id;
            return;
        }
        // Reserve first: failure cannot strand a retained frame or admit a
        // mutable borrow without its transaction-entry version.
        try journal.reserve(self.allocator);
        const saved = if (self.entries.get(id)) |frame| try self.forkFrame(frame) else null;
        journal.save(id, saved);
        journal.last_held = id;
        self.statistics.saved_entries +|= 1;
        if (saved != null) self.statistics.forked_frames +|= 1;
    }
    pub fn commit(self: *Frames) void {
        self.slots.before_mutation = null;
        self.custody.nodes.before_mutation = null;
        var journal = self.journal.?;
        self.journal = null;
        if (journal.first) |first| {
            if (first.frame) |frame| self.releaseFrame(frame);
            self.statistics.commit_entries +|= 1;
        }
        var values = journal.entries.valueIterator();
        while (values.next()) |saved| {
            if (saved.*) |frame| self.releaseFrame(frame);
            self.statistics.commit_entries +|= 1;
        }
        journal.entries.deinit(self.allocator);
    }
    /// Store has not rolled back yet, so its current append extent is intact.
    /// Remove successors first; retained map capacity then suffices for every
    /// entry frame. No allocation or full retained-frame traversal is needed.
    pub fn rollback(self: *Frames, node_count: usize) void {
        self.slots.before_mutation = null;
        self.custody.nodes.before_mutation = null;
        self.endMutableBorrows(); // Restoring map entries ends their borrows.
        var journal = self.journal.?;
        self.journal = null;
        for (journal.node_count..node_count) |id| {
            if (self.entries.fetchRemove(id)) |entry| self.releaseFrame(entry.value);
            self.statistics.rollback_entries +|= 1;
        }
        if (journal.first) |first| {
            if (self.entries.fetchRemove(first.id)) |current| self.releaseFrame(current.value);
            self.statistics.rollback_entries +|= 1;
        }
        var entries = journal.entries.iterator();
        while (entries.next()) |entry| {
            if (self.entries.fetchRemove(
                entry.key_ptr.*,
            )) |current| self.releaseFrame(current.value);
            self.statistics.rollback_entries +|= 1;
        }
        if (journal.first) |first| if (first.frame) |saved| {
            self.registerRoots(saved, first.id) catch |err|
                std.debug.panic("{s}", .{@errorName(err)});
            self.entries.putAssumeCapacity(first.id, saved);
        };
        entries = journal.entries.iterator();
        while (entries.next()) |entry| if (entry.value_ptr.*) |saved| {
            self.registerRoots(saved, entry.key_ptr.*) catch |err|
                std.debug.panic("{s}", .{@errorName(err)});
            self.entries.putAssumeCapacity(entry.key_ptr.*, saved);
        };
        journal.entries.deinit(self.allocator);
    }

    /// The layout index and its immutable functions outlive these frame views.
    pub fn init(
        allocator: std.mem.Allocator,
        pool: *sets.Pool,
        layouts: *const Layouts,
    ) Error!Frames {
        var slots = try Slots.init(allocator);
        errdefer slots.deinit();
        return .{
            .allocator = allocator,
            .slots = slots,
            .pool = pool,
            .layouts = layouts,
            .custody = try custody.Custody.init(allocator),
        };
    }
    pub fn deinit(self: *Frames) void {
        if (self.journal != null) self.commit();
        self.endMutableBorrows();
        self.entries.deinit(self.allocator);
        self.slots.deinit();
        self.custody.deinit();
        self.* = undefined;
    }
    pub fn get(self: *Frames, id: data.program.Id) Error!Frame {
        return self.entries.get(id) orelse error.InvalidState;
    }
    /// The borrow ends before any operation that changes the frame map.
    pub fn getMutable(self: *Frames, id: data.program.Id) Error!*Frame {
        const frame = self.entries.getPtr(id) orelse return error.InvalidState;
        // Protection may grow the journal or view tables, never this frame map.
        try self.hold(id);
        if (self.borrowed) |first| {
            if (first != id and !self.borrowed_more.contains(id))
                try self.borrowed_more.put(self.allocator, id, {});
        } else self.borrowed = id;
        return frame;
    }
    /// A copied descriptor still mutates its owned slot/custody handles.
    /// Acquire protection before copying, not when later publishing the fields.
    pub fn getForUpdate(self: *Frames, id: data.program.Id) Error!Frame {
        const frame = try self.get(id);
        try self.hold(id);
        return frame;
    }
    /// Ends all outstanding map-pointer borrows. Map mutation does this
    /// automatically. A closed owner may also call it when no pointer escapes
    /// its operation; ordinary low-level callers need no extra choreography.
    pub fn endMutableBorrows(self: *Frames) void {
        if (self.borrowed == null) return;
        self.statistics.released_borrows +|= 1 + @as(u64, self.borrowed_more.count());
        self.borrowed = null;
        // Do not retain or repeatedly clear a large historical borrow set.
        self.borrowed_more.deinit(self.allocator);
        self.borrowed_more = .empty;
    }
    inline fn protect(self: *Frames, frame: *const Frame) Error!void {
        try self.slots.protect(frame.view);
    }
    pub fn project(
        self: *Frames,
        id: data.program.Id,
        allocator: std.mem.Allocator,
    ) Error!?data.process_state.Activation {
        const frame = self.entries.get(id) orelse return null;
        var bindings: std.ArrayList(data.process_state.Binding) = .empty;
        errdefer bindings.deinit(allocator);
        var iterator = try self.slots.iterator(frame.view);
        while (try iterator.next()) |binding|
            try bindings.append(allocator, .{ .slot = binding.slot, .value = binding.value });
        const owners = try self.custody.project(frame.custody, allocator);
        errdefer allocator.free(owners);
        return .{
            .position = frame.position,
            .scope = frame.custody.scope,
            .bindings = try bindings.toOwnedSlice(allocator),
            .owners = owners,
        };
    }
    /// The caller admits the complete portable State before materializing views.
    pub fn restore(
        self: *Frames,
        id: data.program.Id,
        function: data.program.Id,
        activation: data.process_state.Activation,
    ) Error!void {
        var frame = try self.create(function);
        errdefer self.releaseFrame(frame);
        for (activation.bindings) |binding| try self.rewriteValue(
            &frame,
            binding.slot,
            binding.value,
        );
        try self.custody.restore(
            &frame.custody,
            self.layouts.functions[@intCast(function)].custody,
            @intCast(activation.scope),
            activation.owners,
        );
        frame.position = @intCast(activation.position);
        try self.put(id, frame);
    }
    pub fn put(self: *Frames, id: data.program.Id, frame: Frame) Error!void {
        if (self.entries.contains(id)) return error.InvalidState;
        try self.hold(id);
        try self.entries.put(self.allocator, id, frame);
        try self.registerRoots(frame, id);
        self.endMutableBorrows();
    }
    fn registerRoots(self: *Frames, frame: Frame, id: data.program.Id) Error!void {
        try self.slots.registerOwner(frame.view, @intCast(id));
        try self.custody.nodes.registerOwner(frame.custody.view, @intCast(id));
    }
    pub fn update(self: *Frames, id: data.program.Id, frame: Frame) Error!void {
        try self.hold(id);
        self.endMutableBorrows();
        try self.registerRoots(frame, id);
        self.entries.getPtr(id).?.* = frame;
    }
    pub fn remove(self: *Frames, id: data.program.Id) Error!void {
        const frame = self.entries.get(id) orelse return;
        if (self.journal) |*journal| {
            if (id < journal.node_count and !journal.contains(id) and
                try self.slots.canTransfer(frame.view) and
                try self.custody.nodes.canTransfer(frame.custody.view))
            {
                // Removal transfers the untouched entry owner; no fork or
                // temporary view is necessary. Retire borrowed handles first;
                // otherwise a copied descriptor could mutate the saved owner.
                // Both generations are checked before either changes.
                try journal.reserve(self.allocator);
                var saved = frame;
                saved.view = self.slots.transfer(frame.view) catch |err|
                    std.debug.panic("{s}", .{@errorName(err)});
                saved.custody.view = self.custody.nodes.transfer(frame.custody.view) catch |err|
                    std.debug.panic("{s}", .{@errorName(err)});
                journal.save(id, saved);
                journal.last_held = id;
                self.endMutableBorrows();
                _ = self.entries.remove(id);
                self.statistics.saved_entries +|= 1;
                self.statistics.moved_frames +|= 1;
                return;
            }
        }
        // An exhausted generation cannot be renamed. Existing COW protection
        // retains its entry version while release permanently retires that view.
        try self.hold(id);
        self.endMutableBorrows();
        if (self.entries.fetchRemove(id)) |entry| self.releaseFrame(entry.value);
    }
    pub fn create(self: *Frames, function: data.program.Id) Error!Frame {
        const definition = self.layouts.functions[@intCast(function)];
        const view = try self.slots.create(definition.layout.slots.len);
        errdefer self.slots.release(view) catch |err| std.debug.panic("{s}", .{@errorName(err)});
        return .{
            .view = view,
            .function = function,
            .live_bound = if (definition.layout.slots.len <= 64)
                .{ .bits = 0 }
            else
                .{ .tree = sets.empty },
            .custody = try self.custody.create(
                definition.layout.slots.len,
                definition.custody.len,
            ),
        };
    }
    pub fn releaseFrame(self: *Frames, frame: Frame) void {
        self.slots.release(frame.view) catch |err| std.debug.panic("{s}", .{@errorName(err)});
        self.custody.release(frame.custody);
    }
    pub fn forkFrame(self: *Frames, original: Frame) Slots.Error!Frame {
        var result = original;
        result.view = try self.slots.fork(original.view);
        errdefer self.slots.release(result.view) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        result.custody = try self.custody.fork(original.custody);
        return result;
    }
    pub fn scope(self: *Frames, frame: *Frame, target: data.program.Id) Error!void {
        try self.protect(frame);
        try self.custody.moveTo(
            &frame.custody,
            self.layouts.functions[@intCast(frame.function)].custody,
            @intCast(target),
        );
    }
    pub fn write(
        self: *Frames,
        frame: *Frame,
        slot: data.program.Id,
        value: data.graph.Value,
    ) Error!void {
        try self.protect(frame);
        try self.custody.remove(&frame.custody, @intCast(slot));
        if (value.body == .owned) try self.custody.establish(
            &frame.custody,
            self.layouts.functions[@intCast(frame.function)].custody,
            @intCast(slot),
        );
        try self.rewriteValue(frame, slot, value);
    }
    fn rewriteValue(
        self: *Frames,
        frame: *Frame,
        slot: data.program.Id,
        value: data.graph.Value,
    ) Error!void {
        const bound = try frame.live_bound.changed(self.pool, slot, true);
        try self.slots.set(frame.view, @intCast(slot), value);
        frame.live_bound = bound;
    }
    pub fn discards(self: *Frames, id: data.program.Id) Error![]data.graph.Value {
        const frame = try self.get(id);
        const ordered = try self.custody.ordered(frame.custody, self.allocator);
        defer self.allocator.free(ordered);
        const values = try self.allocator.alloc(data.graph.Value, ordered.len);
        errdefer self.allocator.free(values);
        for (values, ordered) |*value, slot| value.* = try self.slots.get(frame.view, slot);
        return values;
    }
    pub fn clear(self: *Frames, frame: *Frame, slot: data.program.Id) Error!void {
        try self.protect(frame);
        try self.clearProtected(frame, slot);
    }
    fn clearProtected(self: *Frames, frame: *Frame, slot: data.program.Id) Error!void {
        try self.custody.remove(&frame.custody, @intCast(slot));
        try self.slots.clear(frame.view, @intCast(slot));
    }
    pub fn canRestart(self: *const Frames, frame: Frame, target: data.program.Id) bool {
        return !frame.custody.initialized and self.layouts.compatible(frame.function, target);
    }
    /// Consume a compatible frame after gathering simultaneous arguments.
    /// Exact schemas and custody capacity preserve its physical layout; retained
    /// views remain isolated by Slots' existing COW owner.
    pub fn restart(
        self: *Frames,
        frame: *Frame,
        target: data.program.Id,
        live: sets.Root,
        values: []const data.graph.Value,
    ) Error!void {
        if (!self.canRestart(frame.*, target)) return error.InvalidState;
        const function = self.layouts.functions[@intCast(target)];
        if (function.inputs.len != values.len) return error.InvalidState;
        try self.protect(frame);
        var old = frame.live_bound.iterator(self.pool);
        frame.function = target;
        frame.custody.scope = 0;
        // Arguments were gathered simultaneously before restart. Install them
        // before clearing the old temporaries so a unique slot page need not
        // become empty and be allocated again at every tail call.
        try self.writeSelected(frame, live, function.inputs, values);
        while (old.next()) |slot| {
            if (slot >= function.layout.slots.len) break;
            if (std.mem.indexOfScalar(data.program.Id, function.inputs, slot) == null)
                try self.clearProtected(frame, slot);
        }
        try self.pruneProtected(frame, live);
        frame.position = 0;
    }
    /// Writes and reclamation share one owner. The admitted liveness bound may
    /// include uninitialized slots; only Slots.get/iterator observe actual values.
    pub fn apply(
        self: *Frames,
        frame: *Frame,
        live: sets.Root,
        destinations: anytype,
        values: []const data.graph.Value,
    ) Error!void {
        if (destinations.len != values.len) return error.InvalidState;
        try self.protect(frame);
        try self.applyProtected(frame, live, destinations, values);
    }
    fn applyProtected(
        self: *Frames,
        frame: *Frame,
        live: sets.Root,
        destinations: anytype,
        values: []const data.graph.Value,
    ) Error!void {
        try self.writeSelected(frame, live, destinations, values);
        try self.pruneProtected(frame, live);
    }
    fn writeSelected(
        self: *Frames,
        frame: *Frame,
        live: sets.Root,
        destinations: anytype,
        values: []const data.graph.Value,
    ) Error!void {
        const selection: Bound = switch (frame.live_bound) {
            .bits => .{ .bits = self.pool.lowWord(live) },
            .tree => .{ .tree = live },
        };
        for (destinations, 0..) |destination, index| {
            const slot: data.program.Id = if (@TypeOf(
                destination,
            ) == data.program.Id) destination else destination.destination;
            if (!selection.contains(self.pool, slot)) continue;
            const value = values[index];
            try self.custody.remove(&frame.custody, @intCast(slot));
            if (value.body == .owned) try self.custody.establish(
                &frame.custody,
                self.layouts.functions[@intCast(frame.function)].custody,
                @intCast(slot),
            );
            try self.slots.set(frame.view, @intCast(slot), value);
        }
    }
    pub fn prune(self: *Frames, frame: *Frame, live: sets.Root) Error!void {
        try self.protect(frame);
        try self.pruneProtected(frame, live);
    }
    fn pruneProtected(self: *Frames, frame: *Frame, live: sets.Root) Error!void {
        const retained: Bound = switch (frame.live_bound) {
            .bits => .{ .bits = self.pool.lowWord(live) },
            .tree => .{ .tree = live },
        };
        const removed: Bound = switch (frame.live_bound) {
            .bits => |bits| .{ .bits = bits & ~retained.bits },
            .tree => |root| .{ .tree = try self.pool.difference(root, live) },
        };
        const limit = self.layouts.functions[@intCast(frame.function)].layout.slots.len;
        var iterator = removed.iterator(self.pool);
        while (iterator.next()) |slot| {
            if (slot >= limit) break;
            try self.clearProtected(frame, slot);
        }
        frame.live_bound = retained;
    }
    pub fn copyFrame(
        self: *Frames,
        from: data.program.Id,
        to: data.program.Id,
    ) data.graph_order.Error!void {
        var copy = self.entries.get(from) orelse return;
        if (self.entries.contains(to)) return error.InvalidState;
        copy = self.forkFrame(copy) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidState,
        };
        errdefer self.releaseFrame(copy);
        self.put(to, copy) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidState,
        };
    }

    pub fn rebaseFrame(
        self: *Frames,
        id: data.program.Id,
        map: anytype,
    ) data.graph_order.Error!void {
        if (!self.entries.contains(id)) return;
        const frame = self.getForUpdate(id) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidState,
        };
        var members = frame.live_bound.iterator(self.pool);
        const limit = self.layouts.functions[@intCast(frame.function)].layout.slots.len;
        while (members.next()) |slot| {
            if (slot >= limit) break;
            var value = self.slots.get(frame.view, @intCast(slot)) catch |err| switch (err) {
                error.UninitializedSlot => continue,
                else => return error.InvalidState,
            };
            const reference = switch (value.body) {
                .reference => |*ref| ref,
                .owned => |*owned| &owned.node,
                else => continue,
            };
            const replacement = map.get(reference.id) orelse continue;
            reference.* = replacement;
            self.slots.set(frame.view, @intCast(slot), value) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidState,
            };
        }
    }

    pub fn references(
        self: *Frames,
        id: data.program.Id,
        output: *std.ArrayList(data.graph_order.Reference),
        allocator: std.mem.Allocator,
    ) data.graph_order.Error!void {
        const frame = self.entries.get(id) orelse return;
        var iterator = self.slots.iterator(frame.view) catch return error.InvalidState;
        while (iterator.next() catch return error.InvalidState) |binding|
            try data.graph_order.references(data.graph.Value, binding.value, output, allocator);
    }
};
