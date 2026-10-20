// Copyright (c) 2026 World contributors. MIT license.
//! Fresh current-format invocation through the same stable Session evaluator.
const std = @import("std");
const data = @import("horos_data");
const protocol = data.invocation;
const heap = @import("store.zig");
const runtime = @import("../semantic/session.zig");
pub const Error = runtime.Error;
pub const Outcome = struct {
    arena: std.heap.ArenaAllocator,
    record: protocol.Outcome,
    pub fn deinit(self: *Outcome) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Own all mutable caller bytes before trust checks or execution.
pub fn invoke(allocator: std.mem.Allocator, input: protocol.Input) Error!Outcome {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = try heap.duplicate(protocol.Input, arena.allocator(), input);
    return execute(allocator, owned);
}

fn execute(allocator: std.mem.Allocator, input: protocol.Input) Error!Outcome {
    try protocol.validate(protocol.Input, allocator, input);
    var session = switch (input.instance) {
        .initial_args => |args| try runtime.Session.initImage(allocator, input.image, args),
        .state => |state| try runtime.Session.restoreImage(allocator, input.image, state),
    };
    defer session.deinit();
    _ = try advance(&session, input.control, input.quantum);
    return finish(allocator, &session, true);
}

pub fn advance(
    session: *runtime.Session,
    control: protocol.Control,
    quantum: ?u64,
) Error!runtime.Observation {
    switch (control) {
        .none => {},
        .reply => |bytes| try session.answer(bytes),
        .resume_yield => try session.resumeYield(),
        .cancel => |reason| try session.cancel(reason),
    }
    return session.run(quantum);
}

pub fn finish(
    allocator: std.mem.Allocator,
    session: *runtime.Session,
    checkpoint: bool,
) Error!Outcome {
    return finishObserved(allocator, session, checkpoint, null);
}

/// Observe the identity already constructed for publication. This exports no
/// validation authority and does not retain any output/checkpoint backing.
pub fn finishObserved(
    allocator: std.mem.Allocator,
    session: *runtime.Session,
    checkpoint: bool,
    binding: ?*?runtime.ExpectedReply,
) Error!Outcome {
    return (try finishPublication(
        allocator,
        session,
        if (checkpoint) .inline_state else .none,
        binding,
    )).outcome;
}

pub const CheckpointMode = enum { none, inline_state, receipt };
pub const Finished = struct {
    outcome: Outcome,
    checkpoint: ?[]u8 = null,
    pending_digest: ?[32]u8 = null,
};

/// Sidecar bytes use the Session allocator, independently of the output arena.
/// The caller must admit both before committing its resident transaction.
pub fn finishPublication(
    allocator: std.mem.Allocator,
    session: *runtime.Session,
    mode: CheckpointMode,
    binding: ?*?runtime.ExpectedReply,
) Error!Finished {
    const observation = try session.observe();
    if (binding) |output| output.* = null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var sidecar: ?[]u8 = null;
    errdefer if (sidecar) |bytes| session.allocator.free(bytes);
    var pending_digest: ?[32]u8 = null;
    if (mode == .receipt and observation != .requested) sidecar = try session.checkpoint(
        session.allocator,
    );
    const result: protocol.Outcome = switch (observation) {
        .progressed => .{
            .progressed = if (mode == .inline_state) try session.checkpoint(a) else null,
        },
        .yielded => .{
            .yielded = if (mode == .inline_state) try session.checkpoint(a) else null,
        },
        .requested => blk: {
            const pending_allocator = if (mode == .inline_state) a else session.allocator;
            var pending = try session.pendingBinding(pending_allocator, mode != .none);
            defer pending.deinit();
            if (binding) |output| output.* = runtime.ExpectedReply.fromRequest(pending.request);
            pending_digest = pending.request.binding.pending_state_digest;
            const request = try protocol.encodeOwned(protocol.Request, a, pending.request);
            const state: ?[]const u8 = if (mode == .inline_state) pending.state else null;
            if (mode == .receipt) sidecar = pending.state;
            if (mode != .none) pending.state = &.{}; // ownership moved to arena/sidecar
            break :blk .{ .requested = .{ .state = state, .request = request } };
        },
        .completed => |value| .{ .completed = try a.dupe(u8, try session.bytes(&value)) },
        .failed => |value| .{ .failed = .{
            .value = try a.dupe(u8, try session.bytes(&value)),
            .cleanup_failures = try failures(a, session),
            .cancellation = if ((try session.terminalExit()).cancellation) |reason|
                try heap.duplicate(protocol.Reason, a, reason)
            else
                null,
        } },
        .cancelled => |reason| .{ .cancelled = .{
            .reason = try heap.duplicate(protocol.Reason, a, reason),
            .cleanup_failures = try failures(a, session),
        } },
    };
    return .{
        .outcome = .{ .arena = arena, .record = result },
        .checkpoint = sidecar,
        .pending_digest = pending_digest,
    };
}

fn failures(allocator: std.mem.Allocator, session: *runtime.Session) Error![]const u8 {
    const values = (try session.terminalExit()).cleanup_failures;
    var measure: data.wire.Writer = .{};
    try measure.natural(values.len);
    for (values) |value| try measure.bytes(try session.bytes(&value));
    const bytes = try allocator.alloc(u8, measure.position);
    errdefer allocator.free(bytes);
    var writer: data.wire.Writer = .{ .output = bytes };
    try writer.natural(values.len);
    for (values) |value| try writer.bytes(try session.bytes(&value));
    return bytes;
}

/// No output is returned on operational failure; the original input is reusable.
pub fn invokeBytes(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    return invokeBytesWith(allocator, allocator, input);
}

pub fn invokeBytesWith(
    allocator: std.mem.Allocator,
    output: std.mem.Allocator,
    input: []const u8,
) Error![]u8 {
    var decoded = try protocol.decode(protocol.Input, allocator, input);
    defer decoded.deinit();
    var result = try execute(allocator, decoded.value);
    defer result.deinit();
    return protocol.encodeOwned(protocol.Outcome, output, result.record);
}

/// The completed invocation is private until all output checks pass. Input and
/// output may overlap because decode owns the complete command before execution.
pub fn invokeInto(allocator: std.mem.Allocator, input: []const u8, output: []u8) Error![]const u8 {
    var decoded = try protocol.decode(protocol.Input, allocator, input);
    defer decoded.deinit();
    var result = try execute(allocator, decoded.value);
    defer result.deinit();
    return protocol.encode(protocol.Outcome, allocator, result.record, output);
}
