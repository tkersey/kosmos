// Copyright (c) 2026 World contributors. MIT license.
//! One mutable native resident owner. No mutation escapes a failed drive.
const std = @import("std");
const data = @import("horos_data");
const protocol = data.invocation;
const runtime = @import("stable_session.zig");
const invocation = @import("invocation.zig");
const heap = @import("store.zig");
const Statistics = @import("runtime_types.zig").Statistics;
pub const Drive = struct { quantum: ?u64 = null, checkpoint: bool = false };
pub const Error = runtime.Error || error{ Busy, UnfinishedSession };
pub const Publish = struct { quantum: ?u64 = null, checkpoint: invocation.CheckpointMode = .none };
pub const Destination = union(enum) { record: std.mem.Allocator, encoded: std.mem.Allocator, buffer: []u8 };
pub const Published = union(enum) { record: invocation.Outcome, encoded: []u8, buffer: []const u8 };

const Identity = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),

    fn retain(self: *Identity) Error!void {
        var current = self.references.load(.monotonic);
        while (true) {
            const next = std.math.add(usize, current, 1) catch return error.InvalidState;
            current = self.references.cmpxchgWeak(current, next, .monotonic, .monotonic) orelse return;
        }
    }
    fn release(self: *Identity) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }
};

const CheckpointStorage = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    pending_digest: ?[32]u8,
    issuer: *Identity,
    generation: u64,
    transferable: bool = true,
};

/// Owning and non-copyable by contract. Only Resident can mint transfer
/// authorization. Bytes survive transfer and may outlive the issuing Resident.
pub const Checkpoint = opaque {
    fn owner(self: *const Checkpoint) *CheckpointStorage {
        return @ptrCast(@alignCast(@constCast(self)));
    }
    pub fn bytes(self: *const Checkpoint) []const u8 {
        return self.owner().bytes;
    }
    pub fn pendingStateDigest(self: *const Checkpoint) ?[32]u8 {
        return self.owner().pending_digest;
    }
    pub fn deinit(self: *Checkpoint) void {
        const storage = self.owner();
        const allocator = storage.allocator;
        storage.issuer.release();
        allocator.free(storage.bytes);
        allocator.destroy(storage);
    }
};

pub const Publication = struct {
    outcome: Published,
    checkpoint: ?*Checkpoint = null,
    allocator: ?std.mem.Allocator,

    pub fn takeCheckpoint(self: *Publication) ?*Checkpoint {
        const receipt = self.checkpoint;
        self.checkpoint = null;
        return receipt;
    }
    pub fn deinit(self: *Publication) void {
        if (self.checkpoint) |receipt| receipt.deinit();
        switch (self.outcome) {
            .record => |*record| record.deinit(),
            .encoded => |bytes| self.allocator.?.free(bytes),
            .buffer => {},
        }
        self.* = undefined;
    }
};

const State = struct {
    session: runtime.Session,
    expected: ?[32]u8 = null,
    identity: *Identity,
    generation: u64 = 0,
};

/// Read-only, non-contractual diagnostics. No mutable engine reference escapes.
pub const Diagnostics = struct {
    frames: usize,
    nodes: usize,
    transitions: usize,
    collection_cursors: usize,
    pending_blob_collection: bool,
    imported_backing: bool,
    slots: @import("activation_slots.zig").ActivationSlots.Statistics,
    custody: @import("custody.zig").Nodes.Statistics,
    transactions: @import("activation_frames.zig").Frames.Statistics,
};

/// Owning, non-copyable by contract. Caller keeps this handle at a stable address
/// while operations are in flight; the gate rejects concurrent/reentrant calls.
pub const Resident = struct {
    // Inline private representation preserves the existing allocation domain.
    // Only owner() interprets these bytes; native low-level mutation belongs to
    // the separate Session API, which always recomputes expected bindings.
    storage: [@sizeOf(State)]u8 align(@alignOf(State)) = undefined,
    live: bool = false,
    gate: std.atomic.Value(bool) = .init(false),

    pub fn start(allocator: std.mem.Allocator, prepared: *const runtime.Prepared, arguments: []const u8) Error!Resident {
        var result: Resident = .{};
        var session = try runtime.Session.start(allocator, prepared, arguments);
        errdefer session.deinit();
        const identity = try allocator.create(Identity);
        identity.* = .{ .allocator = allocator };
        result.owner().* = .{ .session = session, .identity = identity };
        result.live = true;
        return result;
    }
    pub fn restore(allocator: std.mem.Allocator, prepared: *const runtime.Prepared, checkpoint_bytes: []const u8) Error!Resident {
        var result: Resident = .{};
        var session = try runtime.Session.restore(allocator, prepared, checkpoint_bytes);
        errdefer session.deinit();
        const identity = try allocator.create(Identity);
        identity.* = .{ .allocator = allocator };
        result.owner().* = .{ .session = session, .identity = identity };
        result.live = true;
        return result;
    }
    fn owner(self: *Resident) *State {
        return @ptrCast(&self.storage);
    }
    fn enter(self: *Resident) Error!*State {
        if (self.gate.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.Busy;
        if (self.live) return self.owner();
        self.gate.store(false, .release);
        return error.InvalidState;
    }
    fn leave(self: *Resident) void {
        // No mutable engine borrow escapes this closed owner. Its next drive
        // need not protect pointers whose entire operation has already ended.
        if (self.live) self.owner().session.frames.endMutableBorrows();
        self.gate.store(false, .release);
    }

    /// Every publication route shares one commit fence, including allocation of
    /// encoded output. No encoder/capacity failure may follow that fence.
    pub fn publish(self: *Resident, destination: Destination, control: protocol.Control, options: Publish) Error!Publication {
        const state = try self.enter();
        defer self.leave();
        const session = &state.session;
        const generation = std.math.add(u64, state.generation, 1) catch return error.InvalidState;
        var input = std.heap.ArenaAllocator.init(session.allocator);
        defer input.deinit();
        const owned = try heap.duplicate(protocol.Control, input.allocator(), control);
        // Restoration starts without private metadata. Establish it from the
        // admitted parked state once; a rejected reply may keep this exact fact.
        if (owned == .reply and state.expected == null) {
            var pending = try session.pendingBinding(session.allocator, false);
            defer pending.deinit();
            state.expected = pending.request.request_identity;
        }
        const expected = state.expected;
        errdefer state.expected = expected;
        var transaction = try session.begin();
        errdefer transaction.rollback(session);
        if (owned == .reply) {
            if (session.statistics) |statistics| statistics.reused_expected_bindings +|= 1;
            try @import("response.zig").answer(session, owned.reply, state.expected.?);
            state.expected = null;
            _ = try session.run(options.quantum);
        } else {
            if (owned != .none) state.expected = null;
            _ = try invocation.advance(session, owned, options.quantum);
        }
        const output_allocator = switch (destination) {
            .record, .encoded => |allocator| allocator,
            .buffer => session.allocator,
        };
        var finished = try invocation.finishPublication(output_allocator, session, options.checkpoint, &state.expected);
        errdefer finished.outcome.deinit();
        errdefer if (finished.checkpoint) |bytes| session.allocator.free(bytes);
        var receipt: ?*Checkpoint = null;
        if (finished.checkpoint) |bytes| {
            const storage = try session.allocator.create(CheckpointStorage);
            errdefer session.allocator.destroy(storage);
            try state.identity.retain();
            storage.* = .{ .allocator = session.allocator, .bytes = bytes, .pending_digest = finished.pending_digest, .issuer = state.identity, .generation = generation };
            receipt = @ptrCast(storage);
            finished.checkpoint = null;
        }
        errdefer if (receipt) |checkpoint_receipt| checkpoint_receipt.deinit();
        const published: Published = switch (destination) {
            .record => .{ .record = finished.outcome },
            .encoded, .buffer => blk: {
                break :blk switch (destination) {
                    .encoded => |allocator| .{ .encoded = try protocol.encodeOwned(protocol.Outcome, allocator, finished.outcome.record) },
                    .buffer => |buffer| .{ .buffer = try protocol.encode(protocol.Outcome, session.allocator, finished.outcome.record, buffer) },
                    else => unreachable,
                };
            },
        };
        if (destination != .record) finished.outcome.deinit();
        state.generation = generation;
        transaction.commit(session);
        session.store.compactImported() catch {};
        return .{ .outcome = published, .checkpoint = receipt, .allocator = if (destination == .encoded) output_allocator else null };
    }

    pub fn drive(self: *Resident, output: std.mem.Allocator, control: protocol.Control, options: Drive) Error!invocation.Outcome {
        return (try self.publish(.{ .record = output }, control, .{ .quantum = options.quantum, .checkpoint = if (options.checkpoint) .inline_state else .none })).outcome.record;
    }
    pub fn driveEncoded(self: *Resident, output: std.mem.Allocator, control: protocol.Control, options: Drive) Error![]u8 {
        return (try self.publish(.{ .encoded = output }, control, .{ .quantum = options.quantum, .checkpoint = if (options.checkpoint) .inline_state else .none })).outcome.encoded;
    }
    pub fn driveInto(self: *Resident, control: protocol.Control, options: Drive, output: []u8) Error![]const u8 {
        return (try self.publish(.{ .buffer = output }, control, .{ .quantum = options.quantum, .checkpoint = if (options.checkpoint) .inline_state else .none })).outcome.buffer;
    }

    pub fn checkpoint(self: *Resident, output: std.mem.Allocator) Error![]u8 {
        const state = try self.enter();
        defer self.leave();
        return state.session.checkpoint(output);
    }
    pub fn takeCheckpoint(self: *Resident, output: std.mem.Allocator) Error![]u8 {
        const state = try self.enter();
        defer self.leave();
        const bytes = try state.session.checkpoint(output);
        state.session.deinit();
        state.identity.release();
        state.expected = null;
        self.live = false;
        return bytes;
    }
    /// Consume only the transfer authorization; the caller still owns the
    /// receipt and its immutable bytes. No allocation follows these checks.
    pub fn transferCheckpoint(self: *Resident, receipt: *Checkpoint) Error!void {
        const state = try self.enter();
        defer self.leave();
        const checkpoint_owner = receipt.owner();
        if (!checkpoint_owner.transferable or checkpoint_owner.issuer != state.identity or checkpoint_owner.generation != state.generation)
            return error.InvalidState;
        checkpoint_owner.transferable = false;
        state.session.deinit();
        state.identity.release();
        state.expected = null;
        self.live = false;
    }
    /// Physical release is permitted only after terminal observation. Unfinished
    /// execution must complete cancellation/cleanup or transfer a checkpoint.
    pub fn close(self: *Resident) Error!void {
        const state = try self.enter();
        defer self.leave();
        if (state.session.terminal == null) return error.UnfinishedSession;
        state.session.deinit();
        state.identity.release();
        state.expected = null;
        self.live = false;
    }

    /// Counters are caller-owned and must outlive their attachment to this handle.
    pub fn setStatistics(self: *Resident, statistics: ?*Statistics) Error!void {
        const state = try self.enter();
        defer self.leave();
        state.session.statistics = statistics;
        state.session.store.statistics = if (statistics) |s| &s.storage else null;
    }
    pub fn diagnostics(self: *Resident) Error!Diagnostics {
        const state = try self.enter();
        defer self.leave();
        const session = &state.session;
        return .{
            .frames = session.frames.entries.count(),
            .nodes = session.store.nodes.items.len,
            .transitions = session.transitions,
            .collection_cursors = session.collection_cursors,
            .pending_blob_collection = session.pending_blob_collection,
            .imported_backing = session.store.imported != null,
            .slots = session.frames.slots.statistics,
            .custody = session.frames.custody.nodes.statistics,
            .transactions = session.frames.statistics,
        };
    }
};

test "publication generation cannot wrap and its last receipt remains transferable" {
    const a = std.testing.allocator;
    var image: [52]u8 = undefined;
    _ = try std.fmt.hexToBytes(&image, "41424c5f4250493303000000200000000000000001000001020a0000000100000100010000020000070100000000000000000000");
    var prepared = try runtime.Prepared.init(a, &image);
    defer prepared.deinit();
    var resident = try Resident.start(a, &prepared, &.{0});
    defer if (resident.live) {
        const bytes = resident.takeCheckpoint(a) catch unreachable;
        a.free(bytes);
    };
    resident.owner().generation = std.math.maxInt(u64) - 1;
    var final = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer final.deinit();
    try std.testing.expectError(error.InvalidState, resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt }));
    try resident.transferCheckpoint(final.checkpoint.?);
}
