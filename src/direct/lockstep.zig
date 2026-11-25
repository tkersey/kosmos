// Copyright (c) 2026 World contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const g = data.graph;
const protocol = data.invocation;
const core = @import("../semantic/session.zig");
const direct = @import("session.zig");
const runtime_types = @import("../interpreter_v2/runtime_types.zig");
const Observation = runtime_types.Observation;
const ExpectedReply = runtime_types.ExpectedReply;
const Statistics = runtime_types.Statistics;

pub const Divergence = enum { rejection, work, outcome, request, checkpoint };
pub const Error = core.Error || direct.Error || error{RealizationDiverged};

pub const Lockstep = struct {
    pub const ExecutionError = Error;
    allocator: std.mem.Allocator,
    reference: core.Session,
    candidate: direct.Session,
    divergence: ?Divergence = null,
    rejected: ?anyerror = null,

    pub const Transaction = struct {
        reference: core.Session.Transaction,
        candidate: direct.Session.Transaction,
        divergence: ?Divergence,

        pub fn commit(self: *Transaction, owner: *Lockstep) void {
            self.reference.commit(&owner.reference);
            self.candidate.commit(&owner.candidate);
            self.* = undefined;
        }
        pub fn rollback(self: *Transaction, owner: *Lockstep) void {
            self.reference.rollback(&owner.reference);
            self.candidate.rollback(&owner.candidate);
            owner.divergence = self.divergence;
            self.* = undefined;
        }
    };

    pub fn start(
        allocator: std.mem.Allocator,
        prepared: *const core.Prepared,
        arguments: []const u8,
    ) Error!Lockstep {
        return pair(
            allocator,
            core.Session.start(allocator, prepared, arguments),
            direct.Session.start(allocator, &prepared.guest, arguments),
        );
    }

    pub fn restore(
        allocator: std.mem.Allocator,
        prepared: *const core.Prepared,
        checkpoint_bytes: []const u8,
    ) Error!Lockstep {
        return pair(
            allocator,
            core.Session.restore(allocator, prepared, checkpoint_bytes),
            direct.Session.restore(allocator, &prepared.guest, checkpoint_bytes),
        );
    }

    fn pair(
        allocator: std.mem.Allocator,
        reference_result: core.Error!core.Session,
        candidate_result: direct.Error!direct.Session,
    ) Error!Lockstep {
        var candidate = candidate_result catch |candidate_error| {
            var reference = reference_result catch |reference_error| {
                if (sameError(reference_error, candidate_error)) return reference_error;
                return error.RealizationDiverged;
            };
            reference.deinit();
            return error.RealizationDiverged;
        };
        errdefer candidate.deinit();
        var reference = reference_result catch return error.RealizationDiverged;
        errdefer reference.deinit();
        var result: Lockstep = .{
            .allocator = allocator,
            .reference = reference,
            .candidate = candidate,
        };
        try result.compareCut();
        return result;
    }

    pub fn deinit(self: *Lockstep) void {
        self.candidate.deinit();
        self.reference.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Lockstep) Error!Transaction {
        var reference = try self.reference.begin();
        errdefer reference.rollback(&self.reference);
        return .{
            .reference = reference,
            .candidate = try self.candidate.begin(),
            .divergence = self.divergence,
        };
    }

    pub fn transitions(self: *const Lockstep) usize {
        return self.reference.transitions;
    }

    pub fn setStatistics(self: *Lockstep, statistics: ?*Statistics) void {
        self.reference.setStatistics(statistics);
    }

    pub fn isTerminal(self: *const Lockstep) bool {
        return self.reference.isTerminal();
    }

    pub fn observe(self: *Lockstep) Error!Observation {
        try self.usable();
        return self.reference.observe();
    }

    pub fn bytes(self: *Lockstep, value: *const g.Value) Error![]const u8 {
        return self.reference.bytes(value);
    }

    pub fn terminalExit(self: *Lockstep) Error!g.Exit {
        try self.usable();
        return self.reference.terminalExit();
    }

    pub fn run(self: *Lockstep, quantum: ?u64) Error!Observation {
        try self.usable();
        const before = self.reference.transitions;
        const candidate_before = self.candidate.transitions;
        const reference = self.reference.run(quantum);
        const candidate = self.candidate.run(quantum);
        try self.agree(reference, candidate);
        if (self.reference.transitions -% before != self.candidate.transitions -% candidate_before)
            return self.fail(.work);
        try self.compareCut();
        return self.reference.observe();
    }

    pub fn step(self: *Lockstep) Error!void {
        _ = try self.run(1);
    }

    pub fn resumeYield(self: *Lockstep) Error!void {
        try self.usable();
        try self.agree(self.reference.resumeYield(), self.candidate.resumeYield());
    }

    pub fn cancel(self: *Lockstep, reason: protocol.Reason) Error!void {
        try self.usable();
        try self.agree(self.reference.cancel(reason), self.candidate.cancel(reason));
    }

    pub fn answer(self: *Lockstep, input: []const u8) Error!void {
        try self.usable();
        try self.agree(self.reference.answer(input), self.candidate.answer(input));
    }

    pub fn answerExpected(self: *Lockstep, input: []const u8, expected: ExpectedReply) Error!void {
        try self.usable();
        try self.agree(
            self.reference.answerExpected(input, expected),
            self.candidate.answerExpected(input, expected),
        );
    }

    pub fn pendingRequest(self: *Lockstep, allocator: std.mem.Allocator) Error!core.Pending {
        return self.pendingBinding(allocator, true);
    }

    pub fn pendingBinding(
        self: *Lockstep,
        allocator: std.mem.Allocator,
        materialize: bool,
    ) Error!core.Pending {
        try self.usable();
        var reference = try self.reference.pendingBinding(allocator, materialize);
        errdefer reference.deinit();
        var candidate = self.candidate.pendingBinding(allocator, materialize) catch |err|
            return self.failWith(.rejection, err);
        defer candidate.deinit();
        if (!std.mem.eql(u8, reference.state, candidate.state) or
            !try sameRequest(allocator, reference.request, candidate.request))
            return self.fail(.request);
        return reference;
    }

    pub fn checkpoint(self: *Lockstep, allocator: std.mem.Allocator) Error![]u8 {
        try self.usable();
        const reference = try self.reference.checkpoint(allocator);
        errdefer allocator.free(reference);
        const candidate = self.candidate.checkpoint(allocator) catch |err|
            return self.failWith(.rejection, err);
        defer allocator.free(candidate);
        if (!std.mem.eql(u8, reference, candidate)) return self.fail(.checkpoint);
        return reference;
    }

    fn usable(self: *const Lockstep) Error!void {
        if (self.divergence != null) return error.RealizationDiverged;
    }

    fn fail(self: *Lockstep, divergence: Divergence) Error {
        self.divergence = divergence;
        return error.RealizationDiverged;
    }

    fn failWith(self: *Lockstep, divergence: Divergence, err: anyerror) Error {
        self.rejected = err;
        return self.fail(divergence);
    }

    fn agree(self: *Lockstep, reference: anytype, candidate: anytype) Error!void {
        const reference_error: ?anyerror = if (reference) |_| null else |err| err;
        const candidate_error: ?anyerror = if (candidate) |_| null else |err| err;
        if (reference_error == null and candidate_error == null) return;
        if (reference_error != null and candidate_error != null and
            sameError(reference_error.?, candidate_error.?))
        {
            _ = try reference;
            unreachable;
        }
        self.rejected = candidate_error;
        return self.fail(.rejection);
    }

    fn compareCut(self: *Lockstep) Error!void {
        if (self.reference.driver.operation != null) return;
        const reference_result = self.reference.checkpoint(self.allocator);
        const candidate_result = self.candidate.checkpoint(self.allocator);
        defer if (reference_result) |owned| self.allocator.free(owned) else |_| {};
        defer if (candidate_result) |owned| self.allocator.free(owned) else |_| {};
        try self.agree(reference_result, candidate_result);
        const reference = try reference_result;
        const candidate = try candidate_result;
        if (!std.mem.eql(u8, reference, candidate)) return self.fail(.checkpoint);
        try self.compareOutcome();
    }

    fn compareOutcome(self: *Lockstep) Error!void {
        const reference = try self.reference.observe();
        const candidate = self.candidate.observe() catch |err|
            return self.failWith(.rejection, err);
        if (std.meta.activeTag(reference) != std.meta.activeTag(candidate))
            return self.fail(.outcome);
        const same = switch (reference) {
            .progressed, .yielded => true,
            .requested => |request| request.effect == candidate.requested.effect and
                try self.sameValue(&request.payload, &candidate.requested.payload),
            .completed => |*value| try self.sameValue(value, &candidate.completed),
            .failed => |*value| try self.sameValue(value, &candidate.failed),
            .cancelled => |reason| sameReason(reason, candidate.cancelled),
        };
        if (!same) return self.fail(.outcome);
        if (reference == .requested) {
            var pending = try self.pendingBinding(self.allocator, false);
            pending.deinit();
        }
    }

    fn sameValue(self: *Lockstep, reference: *const g.Value, candidate: *const g.Value) Error!bool {
        const candidate_bytes = self.candidate.bytes(candidate) catch |err|
            return self.failWith(.rejection, err);
        return std.mem.eql(u8, try self.reference.bytes(reference), candidate_bytes);
    }
};

fn sameError(left: anyerror, right: anyerror) bool {
    return std.mem.eql(u8, @errorName(left), @errorName(right));
}

fn sameReason(left: protocol.Reason, right: protocol.Reason) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .text => |text| std.mem.eql(u8, text, right.text),
        .bytes => |content| std.mem.eql(u8, content, right.bytes),
    };
}

fn sameRequest(
    allocator: std.mem.Allocator,
    left: protocol.Request,
    right: protocol.Request,
) Error!bool {
    const left_bytes = try protocol.encodeOwned(protocol.Request, allocator, left);
    defer allocator.free(left_bytes);
    const right_bytes = try protocol.encodeOwned(protocol.Request, allocator, right);
    defer allocator.free(right_bytes);
    return std.mem.eql(u8, left_bytes, right_bytes);
}
