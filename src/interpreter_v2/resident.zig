// Copyright (c) 2026 World contributors. MIT license.
//! One mutable native resident owner. No mutation escapes a failed drive.
const std = @import("std");
const data = @import("horos_data");
const protocol = data.invocation;
const heap = @import("store.zig");
const Statistics = @import("runtime_types.zig").Statistics;
const capsules = @import("../semantic/capsule.zig");
pub fn For(comptime runtime: type) type {
    return struct {
        const invocation = runtime.invocation;
        pub const Drive = struct { quantum: ?u64 = null, checkpoint: bool = false };
        pub const Error = runtime.Error || error{ Busy, UnfinishedSession, PublicationUncertain };
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
            outer_revision: ?u64 = null,
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

        const CapsuleStorage = struct {
            allocator: std.mem.Allocator,
            bytes: []u8,
            kind: capsules.Kind,
            issuer: *Identity,
            generation: u64,
            outer_revision: u64,
            transferable: bool = true,
        };
        pub const CapsuleReceipt = opaque {
            fn owner(self: *const CapsuleReceipt) *CapsuleStorage {
                return @ptrCast(@alignCast(@constCast(self)));
            }
            pub fn bytes(self: *const CapsuleReceipt) []const u8 {
                return self.owner().bytes;
            }
            pub fn kind(self: *const CapsuleReceipt) capsules.Kind {
                return self.owner().kind;
            }
            pub fn deinit(self: *CapsuleReceipt) void {
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
            switching: ?*SwitchStorage = null,
        };
        const SwitchStorage = struct {
            allocator: std.mem.Allocator,
            candidate: runtime.Session,
            binding: capsules.Binding,
            source: []u8,
            target: []u8,
            generation: u64,
            fn deinit(self: *SwitchStorage) void {
                self.candidate.deinit();
                self.allocator.free(self.source);
                self.allocator.free(self.target);
                self.allocator.destroy(self);
            }
        };

        /// Read-only, non-contractual diagnostics. No mutable engine reference escapes.
        pub const Diagnostics = struct {
            level: enum { guest, outer } = .guest,
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
            pub fn restoreCapsule(allocator: std.mem.Allocator, prepared: *const runtime.Prepared, bytes: []const u8, verifier: capsules.Verifier) !Resident {
                return restoreCapsuleSelected(allocator, prepared, &prepared.runtime, bytes, verifier);
            }
            pub fn restoreCapsuleSelected(allocator: std.mem.Allocator, prepared: *const runtime.Prepared, origin: *const @import("../semantic/artifact.zig").Admitted, bytes: []const u8, verifier: capsules.Verifier) !Resident {
                const identity = try allocator.create(Identity);
                errdefer allocator.destroy(identity);
                identity.* = .{ .allocator = allocator };
                const restored = try capsules.restoreSelected(allocator, &prepared.guest, origin, &prepared.runtime, bytes, verifier);
                // No fallible work follows successful custody consumption.
                var result: Resident = .{};
                result.owner().* = .{ .session = runtime.Session.fromDriver(restored), .identity = identity };
                result.live = true;
                return result;
            }
            fn owner(self: *Resident) *State {
                return @ptrCast(&self.storage);
            }
            fn enter(self: *Resident) Error!*State {
                if (self.gate.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.Busy;
                if (self.live) {
                    if (self.owner().switching == null) return self.owner();
                    self.gate.store(false, .release);
                    return error.PublicationUncertain;
                }
                self.gate.store(false, .release);
                return error.InvalidState;
            }
            fn leave(self: *Resident) void {
                // No mutable engine borrow escapes this closed owner. Its next drive
                // need not protect pointers whose entire operation has already ended.
                if (self.live) {
                    if (@hasField(runtime.Session, "driver")) self.owner().session.driver.outer.frames.endMutableBorrows() else self.owner().session.frames.endMutableBorrows();
                }
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
                    try session.answerExpected(owned.reply, state.expected.?);
                    state.expected = null;
                    _ = try session.run(options.quantum);
                } else {
                    if (owned != .none) state.expected = null;
                    _ = try invocation.advance(session, owned, options.quantum);
                }
                const staging_allocator = switch (destination) {
                    .record => |allocator| allocator,
                    .encoded, .buffer => session.allocator,
                };
                var finished = try invocation.finishPublication(staging_allocator, session, options.checkpoint, &state.expected);
                errdefer finished.outcome.deinit();
                errdefer if (finished.checkpoint) |bytes| session.allocator.free(bytes);
                var receipt: ?*Checkpoint = null;
                if (finished.checkpoint) |bytes| {
                    const storage = try session.allocator.create(CheckpointStorage);
                    errdefer session.allocator.destroy(storage);
                    try state.identity.retain();
                    storage.* = .{ .allocator = session.allocator, .bytes = bytes, .pending_digest = finished.pending_digest, .issuer = state.identity, .generation = generation, .outer_revision = if (@hasField(runtime.Session, "driver")) session.driver.revision else null };
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
                if (@hasField(runtime.Session, "driver")) session.driver.outer.store.compactImported() catch {} else session.store.compactImported() catch {};
                return .{ .outcome = published, .checkpoint = receipt, .allocator = if (destination == .encoded) destination.encoded else null };
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
            fn binding(state: *State) capsules.Binding {
                const selected = state.session.driver.selected;
                return .{ .artifact = .{ .digest = selected.identity, .bytes = selected.encoded_length }, .guest_revision = state.session.driver.guest_revision, .outer_revision = state.session.driver.revision, .generation = state.generation };
            }
            pub fn runtimeBinding(self: *Resident) Error!capsules.Binding {
                const state = try self.enter();
                defer self.leave();
                return binding(state);
            }
            pub fn runtimeBytes(self: *Resident, a: std.mem.Allocator) ![]u8 {
                const state = try self.enter();
                defer self.leave();
                return @import("../semantic/projection.zig").encode(@import("../semantic/artifact.zig").Bundle, a, state.session.driver.selected.content.value);
            }
            pub fn realize(self: *Resident, expected: capsules.Binding, target: *const @import("../semantic/artifact.zig").Admitted, provenance: capsules.Provenance, publisher: capsules.SwitchOwner) !capsules.SwitchDecision {
                const state = try self.enter();
                defer self.leave();
                if (!std.meta.eql(expected, binding(state))) return error.StaleRuntimeBinding;
                const generation = try std.math.add(u64, state.generation, 1);
                const a = state.session.allocator;
                var candidate = runtime.Session.fromDriver(try capsules.rehydrate(a, &state.session.driver, target));
                errdefer candidate.deinit();
                const source = try capsules.publish(a, &state.session.driver, .guest_cut, provenance);
                errdefer a.free(source);
                const next = try capsules.publish(a, &candidate.driver, .guest_cut, provenance);
                errdefer a.free(next);
                const pending = try a.create(SwitchStorage);
                pending.* = .{ .allocator = a, .candidate = candidate, .binding = expected, .source = source, .target = next, .generation = generation };
                state.switching = pending;
                // All construction and allocation precede durable publication.
                return settleSwitch(state, publisher);
            }
            pub fn resolveRealization(self: *Resident, publisher: capsules.SwitchOwner) Error!capsules.SwitchDecision {
                if (self.gate.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.Busy;
                defer self.leave();
                if (!self.live or self.owner().switching == null) return error.InvalidState;
                return settleSwitch(self.owner(), publisher);
            }
            fn settleSwitch(state: *State, publisher: capsules.SwitchOwner) capsules.SwitchDecision {
                const pending = state.switching.?;
                const decision = publisher.publish(publisher.context, pending.binding, pending.source, pending.target);
                switch (decision) {
                    .uncertain => {},
                    .rejected => {
                        state.switching = null;
                        pending.deinit();
                    },
                    .committed => {
                        // Swapping leaves the old session in pending for disposal.
                        // The stable identity survives; every old receipt is stale.
                        std.mem.swap(runtime.Session, &state.session, &pending.candidate);
                        state.session.statistics = pending.candidate.statistics;
                        state.session.transitions = pending.candidate.transitions;
                        state.session.driver.outer.store.statistics = if (state.session.statistics) |s| &s.storage else null;
                        state.generation = pending.generation;
                        state.switching = null;
                        pending.deinit();
                    },
                }
                return decision;
            }
            pub fn beginAdvance(self: *Resident, control: protocol.Control, guest_quantum: u64) Error!void {
                const state = try self.enter();
                defer self.leave();
                const generation = std.math.add(u64, state.generation, 1) catch return error.InvalidState;
                var transaction = try state.session.begin();
                errdefer transaction.rollback(&state.session);
                try state.session.submitAdvance(control, guest_quantum);
                transaction.commit(&state.session);
                state.expected = null;
                state.generation = generation;
            }
            pub fn pump(self: *Resident, base_quantum: u64) Error!runtime.Session.Pump {
                const state = try self.enter();
                defer self.leave();
                const generation = std.math.add(u64, state.generation, 1) catch return error.InvalidState;
                var transaction = try state.session.begin();
                errdefer transaction.rollback(&state.session);
                const result = try state.session.pumpAdvance(base_quantum);
                transaction.commit(&state.session);
                state.generation = generation;
                return result;
            }
            pub fn publishCapsule(self: *Resident, output: std.mem.Allocator, kind: capsules.Kind, provenance: capsules.Provenance) !*CapsuleReceipt {
                const state = try self.enter();
                defer self.leave();
                const bytes = try capsules.publish(output, &state.session.driver, kind, provenance);
                errdefer output.free(bytes);
                const storage = try output.create(CapsuleStorage);
                errdefer output.destroy(storage);
                try state.identity.retain();
                storage.* = .{ .allocator = output, .bytes = bytes, .kind = kind, .issuer = state.identity, .generation = state.generation, .outer_revision = state.session.driver.revision };
                return @ptrCast(storage);
            }
            pub fn transferCapsule(self: *Resident, receipt: *CapsuleReceipt, expected_kind: capsules.Kind) Error!void {
                const state = try self.enter();
                defer self.leave();
                const saved = receipt.owner();
                if (!saved.transferable or saved.kind != expected_kind or saved.issuer != state.identity or saved.generation != state.generation or saved.outer_revision != state.session.driver.revision) return error.InvalidState;
                saved.transferable = false;
                state.session.deinit();
                state.identity.release();
                state.expected = null;
                self.live = false;
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
                if (@hasField(runtime.Session, "driver")) if (checkpoint_owner.outer_revision) |revision| {
                    if (revision != state.session.driver.revision) return error.InvalidState;
                };
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
                if (if (@hasField(runtime.Session, "driver")) !state.session.isTerminal() else state.session.terminal == null) return error.UnfinishedSession;
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
                if (@hasField(runtime.Session, "driver")) state.session.driver.outer.store.statistics = if (statistics) |s| &s.storage else null else state.session.store.statistics = if (statistics) |s| &s.storage else null;
            }
            pub fn diagnostics(self: *Resident) Error!Diagnostics {
                const state = try self.enter();
                defer self.leave();
                const session = &state.session;
                if (@hasField(runtime.Session, "driver")) {
                    const outer = &session.driver.outer;
                    return .{
                        .level = .outer,
                        .frames = outer.frames.entries.count(),
                        .nodes = outer.store.nodes.items.len,
                        .transitions = outer.transitions,
                        .collection_cursors = 0,
                        .pending_blob_collection = false,
                        .imported_backing = outer.store.imported != null,
                        .slots = outer.frames.slots.statistics,
                        .custody = outer.frames.custody.nodes.statistics,
                        .transactions = outer.frames.statistics,
                    };
                }
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
    };
}
