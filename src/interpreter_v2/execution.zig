// Copyright (c) 2026 World contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const g = data.graph;
const protocol = data.invocation;
const runtime_types = @import("runtime_types.zig");
const core = @import("../semantic/session.zig");
const direct = @import("../direct/session.zig");
const lockstep = @import("../direct/lockstep.zig");
pub const Realization = runtime_types.Realization;
pub const Observation = runtime_types.Observation;
pub const ExpectedReply = runtime_types.ExpectedReply;
pub const Statistics = runtime_types.Statistics;
pub const Error = lockstep.Error || error{RealizationUnsupported};

fn Resolved(comptime Pointer: type) type {
    const Child = @typeInfo(Pointer).pointer.child;
    return if (@typeInfo(Child) == .pointer) Child else Pointer;
}

fn resolve(pointer: anytype) Resolved(@TypeOf(pointer)) {
    return if (comptime @typeInfo(@TypeOf(pointer.*)) == .pointer) pointer.* else pointer;
}

comptime {
    std.debug.assert(@sizeOf(Execution) <= @sizeOf(core.Session) + 64);
}

pub const Execution = struct {
    pub const ExecutionError = Error;
    allocator: std.mem.Allocator,
    realized: Realized,
    fallback: ?*core.Prepared = null,

    pub const Realized = union(Realization) {
        core: core.Session,
        direct: direct.Session,
        lockstep: *lockstep.Lockstep,
    };

    pub const Transaction = union(Realization) {
        core: core.Session.Transaction,
        direct: direct.Session.Transaction,
        lockstep: lockstep.Lockstep.Transaction,

        pub fn commit(self: *Transaction, owner: *Execution) void {
            switch (self.*) {
                inline else => |*transaction, tag| transaction.commit(
                    resolve(&@field(owner.realized, @tagName(tag))),
                ),
            }
            self.* = undefined;
        }
        pub fn rollback(self: *Transaction, owner: *Execution) void {
            switch (self.*) {
                inline else => |*transaction, tag| transaction.rollback(
                    resolve(&@field(owner.realized, @tagName(tag))),
                ),
            }
            self.* = undefined;
        }
    };

    pub fn start(
        allocator: std.mem.Allocator,
        prepared: *const core.Prepared,
        arguments: []const u8,
    ) Error!Execution {
        const fallback = try fallbackFor(allocator, prepared);
        errdefer release(allocator, fallback);
        const realized: Realized = switch (prepared.realization) {
            .core => .{ .core = try core.Session.start(allocator, prepared, arguments) },
            .direct => .{
                .direct = try direct.Session.start(allocator, &prepared.guest, arguments),
            },
            .lockstep => .{ .lockstep = try paired(
                allocator,
                lockstep.Lockstep.start(allocator, prepared, arguments),
            ) },
        };
        return .{ .allocator = allocator, .fallback = fallback, .realized = realized };
    }

    pub fn restore(
        allocator: std.mem.Allocator,
        prepared: *const core.Prepared,
        checkpoint_bytes: []const u8,
    ) Error!Execution {
        const fallback = try fallbackFor(allocator, prepared);
        errdefer release(allocator, fallback);
        const realized: Realized = switch (prepared.realization) {
            .core => .{ .core = try core.Session.restore(allocator, prepared, checkpoint_bytes) },
            .direct => .{ .direct = try direct.Session.restore(
                allocator,
                &prepared.guest,
                checkpoint_bytes,
            ) },
            .lockstep => .{ .lockstep = try paired(
                allocator,
                lockstep.Lockstep.restore(allocator, prepared, checkpoint_bytes),
            ) },
        };
        return .{ .allocator = allocator, .fallback = fallback, .realized = realized };
    }

    fn paired(
        allocator: std.mem.Allocator,
        result: lockstep.Error!lockstep.Lockstep,
    ) Error!*lockstep.Lockstep {
        var pair = try result;
        errdefer pair.deinit();
        const owned = try allocator.create(lockstep.Lockstep);
        owned.* = pair;
        return owned;
    }

    fn fallbackFor(
        allocator: std.mem.Allocator,
        prepared: *const core.Prepared,
    ) Error!?*core.Prepared {
        if (prepared.realization != .direct) return null;
        const owned = try allocator.create(core.Prepared);
        errdefer allocator.destroy(owned);
        owned.* = try prepared.clone();
        return owned;
    }

    fn release(allocator: std.mem.Allocator, fallback: ?*core.Prepared) void {
        const prepared = fallback orelse return;
        prepared.deinit();
        allocator.destroy(prepared);
    }

    pub fn fromCore(session: core.Session) Execution {
        return .{ .allocator = session.allocator, .realized = .{ .core = session } };
    }

    pub fn realization(self: *const Execution) Realization {
        return std.meta.activeTag(self.realized);
    }

    pub fn currentCore(self: *Execution) ?*core.Session {
        return switch (self.realized) {
            .core => |*session| session,
            else => null,
        };
    }

    pub fn coreSession(self: *Execution) Error!*core.Session {
        switch (self.realized) {
            .core => {},
            .lockstep => |pair| {
                pair.candidate.deinit();
                const reference = pair.reference;
                self.allocator.destroy(pair);
                self.realized = .{ .core = reference };
            },
            .direct => |*session| {
                const prepared = self.fallback orelse return error.RealizationUnsupported;
                const saved = try session.checkpoint(self.allocator);
                defer self.allocator.free(saved);
                var reference = try core.Session.restore(self.allocator, prepared, saved);
                reference.setStatistics(session.statistics);
                reference.transitions = session.transitions;
                session.deinit();
                self.realized = .{ .core = reference };
            },
        }
        return &self.realized.core;
    }

    pub fn deinit(self: *Execution) void {
        switch (self.realized) {
            .core => |*session| session.deinit(),
            .direct => |*session| session.deinit(),
            .lockstep => |pair| {
                pair.deinit();
                self.allocator.destroy(pair);
            },
        }
        release(self.allocator, self.fallback);
        self.* = undefined;
    }

    pub fn begin(self: *Execution) Error!Transaction {
        return switch (self.realized) {
            inline else => |*session, tag| @unionInit(
                Transaction,
                @tagName(tag),
                try resolve(session).begin(),
            ),
        };
    }

    pub fn transitions(self: *Execution) usize {
        return switch (self.realized) {
            .core => |*session| session.transitions,
            .direct => |*session| session.transitions,
            .lockstep => |pair| pair.transitions(),
        };
    }

    pub fn statistics(self: *Execution) ?*Statistics {
        return switch (self.realized) {
            .core => |*session| session.statistics,
            .direct => |*session| session.statistics,
            .lockstep => |pair| pair.reference.statistics,
        };
    }

    pub fn setStatistics(self: *Execution, value: ?*Statistics) void {
        switch (self.realized) {
            inline else => |*session| resolve(session).setStatistics(value),
        }
    }

    pub fn isTerminal(self: *Execution) bool {
        return switch (self.realized) {
            inline else => |*session| resolve(session).isTerminal(),
        };
    }

    pub fn observe(self: *Execution) Error!Observation {
        return switch (self.realized) {
            inline else => |*session| resolve(session).observe(),
        };
    }

    pub fn run(self: *Execution, quantum: ?u64) Error!Observation {
        return switch (self.realized) {
            inline else => |*session| resolve(session).run(quantum),
        };
    }

    pub fn step(self: *Execution) Error!void {
        return switch (self.realized) {
            inline else => |*session| resolve(session).step(),
        };
    }

    pub fn resumeYield(self: *Execution) Error!void {
        return switch (self.realized) {
            inline else => |*session| resolve(session).resumeYield(),
        };
    }

    pub fn cancel(self: *Execution, reason: protocol.Reason) Error!void {
        return switch (self.realized) {
            inline else => |*session| resolve(session).cancel(reason),
        };
    }

    pub fn answer(self: *Execution, input: []const u8) Error!void {
        return switch (self.realized) {
            inline else => |*session| resolve(session).answer(input),
        };
    }

    pub fn answerExpected(self: *Execution, input: []const u8, expected: ExpectedReply) Error!void {
        return switch (self.realized) {
            inline else => |*session| resolve(session).answerExpected(input, expected),
        };
    }

    pub fn pendingBinding(
        self: *Execution,
        allocator: std.mem.Allocator,
        materialize: bool,
    ) Error!core.Pending {
        return switch (self.realized) {
            inline else => |*session| resolve(session).pendingBinding(allocator, materialize),
        };
    }

    pub fn pendingRequest(self: *Execution, allocator: std.mem.Allocator) Error!core.Pending {
        return self.pendingBinding(allocator, true);
    }

    pub fn checkpoint(self: *Execution, allocator: std.mem.Allocator) Error![]u8 {
        return switch (self.realized) {
            inline else => |*session| resolve(session).checkpoint(allocator),
        };
    }

    pub fn bytes(self: *Execution, value: *const g.Value) Error![]const u8 {
        return switch (self.realized) {
            inline else => |*session| resolve(session).bytes(value),
        };
    }

    pub fn terminalExit(self: *Execution) Error!g.Exit {
        return switch (self.realized) {
            inline else => |*session| resolve(session).terminalExit(),
        };
    }
};
