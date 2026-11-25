// Copyright (c) 2026 World contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const g = data.graph;
const read = @import("../interpreter_v2/operands.zig").read;
const storage = @import("../interpreter_v2/store.zig");
const Values = @import("../interpreter_v2/values.zig").Values;
const Session = @import("session.zig").Session;
const Error = @import("session.zig").Error;
const Reason = @FieldType(g.Exit, "reason");
const unit_bits: [8]u8 = @splat(0);

fn position(session: *Session, cursor: ?g.NodeRef, values: []const g.Value) Error!void {
    setPosition(session, try session.store.add(.{ .unwind = .{
        .cursor = cursor,
        .values = values,
    } }));
}

fn positionOwned(session: *Session, cursor: ?g.NodeRef, values: []g.Value) Error!void {
    setPosition(session, try session.store.addOwned(.{ .unwind = .{
        .cursor = cursor,
        .values = values,
    } }));
}

fn setPosition(session: *Session, current: g.NodeRef) void {
    session.roots.current = current;
    session.roots.pending = null;
    session.roots.evidence = null;
    session.status = .unwinding;
}

pub fn begin(
    session: *Session,
    reason: Reason,
    cursor: ?g.NodeRef,
    stop: ?g.NodeRef,
    values: []const g.Value,
) Error!void {
    session.roots.exit = try session.store.add(.{ .exit = .{
        .reason = reason,
        .stop = stop,
        .outer = session.roots.exit,
    } });
    try position(session, cursor, values);
}

fn outermost(session: *Session) Error!g.NodeRef {
    var reference = session.roots.exit orelse return error.InvalidState;
    for (0..session.store.nodes.items.len) |_| {
        reference = (try session.store.get(reference)).exit.outer orelse return reference;
    }
    return error.InvalidState;
}

fn rememberFailure(session: *Session, value: g.Value) Error!void {
    const reference = try outermost(session);
    var exit = (try session.store.get(reference)).exit;
    const count = exit.cleanup_failures.len;
    const failures = try session.allocator.alloc(g.Value, count + 1);
    errdefer session.allocator.free(failures);
    @memcpy(failures[0..count], exit.cleanup_failures);
    failures[count] = value;
    exit.cleanup_failures = failures;
    const discarded = try discardedNormal(session, exit);
    errdefer session.allocator.free(discarded);
    exit.discarded = discarded;
    const Cancellation = @TypeOf(exit.cancellation);
    exit.cancellation = try storage.duplicate(Cancellation, session.allocator, exit.cancellation);
    errdefer storage.release(Cancellation, session.allocator, exit.cancellation);
    if (exit.reason == .normal or exit.reason == .abandoned) {
        exit.reason = .{ .failure = value };
        exit.stop = null;
    }
    try session.store.replaceOwned(reference, .{ .exit = exit });
}

fn discardedNormal(session: *Session, exit: g.Exit) Error![]g.Value {
    const owned = exit.reason == .normal and exit.reason.normal.body == .owned;
    const extra: usize = @intFromBool(owned);
    const values = try session.allocator.alloc(g.Value, exit.discarded.len + extra);
    @memcpy(values[0..exit.discarded.len], exit.discarded);
    if (owned) values[values.len - 1] = exit.reason.normal;
    return values;
}

pub fn failValues(
    session: *Session,
    value: g.Value,
    parent: ?g.NodeRef,
    values: []const g.Value,
) Error!void {
    if (session.roots.exit != null) try rememberFailure(session, value);
    try begin(session, .{ .failure = value }, parent, null, values);
}

fn discardFrame(session: *Session, frame: g.NodeRef, parent: ?g.NodeRef) Error!void {
    const values = try session.frames.discards(frame.id);
    errdefer session.allocator.free(values);
    try session.frames.remove(frame.id);
    try positionOwned(session, parent, values);
}

pub fn cancel(session: *Session, reason: data.invocation.Reason) Error!void {
    if (reason == .text and !std.unicode.utf8ValidateSlice(reason.text))
        return error.InvalidUtf8;
    if (session.roots.exit == null) {
        const cursor = if (session.roots.pending) |pending|
            (try session.store.get(pending)).pending.continuation
        else
            session.roots.current;
        try begin(session, .cancellation, cursor, null, &.{});
    }
    const reference = try outermost(session);
    var exit = (try session.store.get(reference)).exit;
    if (exit.cancellation != null) return;
    exit.cancellation = reason;
    const discarded = try discardedNormal(session, exit);
    defer session.allocator.free(discarded);
    if (exit.reason == .normal or exit.reason == .abandoned) {
        exit.reason = .cancellation;
        exit.stop = null;
        exit.discarded = discarded;
    }
    try session.store.replace(reference, .{ .exit = exit });
}

pub fn protect(
    session: *Session,
    protection: anytype,
    slots: anytype,
    saved: g.Control,
) Error!void {
    const body = try read(slots, protection.body);
    const resource: ?g.Value = if (protection.resource) |slot| try read(slots, slot) else null;
    const obligation = try session.store.add(.{ .obligation = .{
        .source_block = saved.block,
        .cleanup = try read(slots, protection.cleanup),
        .resource = resource,
        .status = .pending,
    } });
    const loan: ?g.NodeRef = if (protection.loan_region) |descriptor|
        try session.store.add(.{ .region = .{
            .descriptor = descriptor,
            .outer = saved.region,
            .obligations = &.{},
        } })
    else
        null;
    const extra: usize = @intFromBool(resource != null);
    const arguments = try session.allocator.alloc(g.Value, protection.arguments.len + extra);
    defer session.allocator.free(arguments);
    if (resource) |owned| arguments[0] = try borrowResource(session, body, owned, loan.?);
    for (arguments[extra..], protection.arguments) |*argument, slot|
        argument.* = try read(slots, slot);
    const after = try session.continuation(saved.block, slots, saved);
    const frame = try session.store.add(.{ .protection = .{
        .source_block = saved.block,
        .obligation = .{ .node = obligation },
        .return_to = after,
        .evidence = saved.evidence,
        .region = saved.region,
        .loan = loan,
    } });
    try session.applyComputation(body, arguments, frame, saved.evidence, loan orelse saved.region);
}

fn borrowResource(session: *Session, body: g.Value, owned: g.Value, loan: g.NodeRef) Error!g.Value {
    const computation = session.program.schemas[@intCast(body.schema)].internal.computation;
    const schema = computation.parameters[0];
    const borrowed = try session.store.add(.{ .borrow = .{
        .schema = schema,
        .resource = owned.body.owned.node,
        .region = loan,
    } });
    return .{ .schema = schema, .body = .{ .reference = borrowed } };
}

pub fn dispose(session: *Session, disposal: anytype, slots: anytype, saved: g.Control) Error!void {
    const token = try session.takeCapture(try read(slots, disposal.owned));
    const after = try session.continuation(saved.block, slots, saved);
    try session.activate(token, after);
    try begin(session, .abandoned, token.capture, after, &.{});
}

fn information(session: *Session, values: *Values, schema: p.Id, exit: g.Exit) Error!g.Value {
    const types = try data.cleanup_contract.types(session.program, schema);
    const unit: g.Value = .{ .schema = types.unit, .body = .{ .scalar = unit_bits } };
    const reason_value = if (exit.cancellation) |reason|
        try cancellationValue(session, values, types, reason)
    else
        unit;
    const primary = try values.aggregate(types.primary, .{
        .tag = @backingInt(std.meta.activeTag(exit.reason)),
        .fields = &.{switch (exit.reason) {
            .normal, .abandoned => unit,
            .failure => |failure| failure,
            .cancellation => reason_value,
        }},
    });
    const optional = try values.aggregate(types.optional_reason, .{
        .tag = if (exit.cancellation != null) 1 else 0,
        .fields = &.{reason_value},
    });
    const failures = try values.aggregate(types.failures, .{ .fields = exit.cleanup_failures });
    return values.aggregate(schema, .{ .fields = &.{ primary, optional, failures } });
}

fn cancellationValue(
    session: *Session,
    values: *Values,
    types: anytype,
    reason: data.invocation.Reason,
) Error!g.Value {
    const content = if (reason == .text) reason.text else reason.bytes;
    var measure: data.wire.Writer = .{};
    try measure.bytes(content);
    const encoded = try values.allocator.alloc(u8, measure.position);
    var writer: data.wire.Writer = .{ .output = encoded };
    try writer.bytes(content);
    const payload = try session.store.literal(session.program.schemas, .{
        .schema = if (reason == .text) types.text else types.bytes,
        .bytes = encoded,
    });
    return values.aggregate(types.reason, .{
        .tag = @backingInt(std.meta.activeTag(reason)),
        .fields = &.{payload},
    });
}

pub fn returned(session: *Session, reference: g.NodeRef) Error!void {
    const frame = (try session.store.get(reference)).cleanup_return;
    var obligation = (try session.store.get(frame.obligation.node)).obligation;
    obligation.status = .completed;
    try session.store.replace(frame.obligation.node, .{ .obligation = obligation });
    session.roots.exit = frame.exit;
    try position(session, frame.parent, &.{});
}

fn unlinkSuspendedExit(session: *Session, retired: g.NodeRef) Error!void {
    const prior = (try session.store.get(retired)).exit;
    var cursor = session.roots.exit orelse return error.InvalidState;
    if (cursor.id == retired.id) return;
    for (0..session.store.nodes.items.len) |_| {
        var record = (try session.store.get(cursor)).exit;
        const outer = record.outer orelse return error.InvalidState;
        if (outer.id == retired.id) {
            record.outer = prior.outer;
            try session.store.replace(cursor, .{ .exit = record });
            if (prior.reason == .failure or prior.reason == .cancellation or
                prior.cancellation != null) try mergeSuspendedExit(session, prior);
            return;
        }
        cursor = outer;
    }
    return error.InvalidState;
}

fn mergeSuspendedExit(session: *Session, prior: g.Exit) Error!void {
    const active = session.roots.exit.?;
    var current = (try session.store.get(active)).exit;
    var failures: std.ArrayList(g.Value) = .empty;
    defer failures.deinit(session.allocator);
    try failures.appendSlice(session.allocator, prior.cleanup_failures);
    try failures.appendSlice(session.allocator, current.cleanup_failures);
    current.reason = if (prior.reason == .failure) prior.reason else .cancellation;
    current.cancellation = prior.cancellation orelse current.cancellation;
    current.cleanup_failures = failures.items;
    current.stop = null;
    try session.store.replace(active, .{ .exit = current });
}

pub fn returnedDisposal(session: *Session, frame: anytype, value: g.Value) Error!void {
    var remaining: std.ArrayList(g.Value) = .empty;
    defer remaining.deinit(session.allocator);
    if (value.body == .owned) try remaining.append(session.allocator, value);
    try remaining.appendSlice(session.allocator, frame.values);
    try position(session, frame.parent, remaining.items);
}

fn crossedCleanupReturn(session: *Session, frame: anytype, exit: g.Exit) Error!void {
    var obligation = (try session.store.get(frame.obligation.node)).obligation;
    if (exit.reason == .abandoned or exit.reason == .cancellation) {
        const suspended = (try session.store.get(frame.exit)).exit;
        const discarded = try discardedNormal(session, suspended);
        defer session.allocator.free(discarded);
        try unlinkSuspendedExit(session, frame.exit);
        obligation.status = .completed;
        try session.store.replace(frame.obligation.node, .{ .obligation = obligation });
        try position(session, frame.parent, discarded);
        return;
    }
    if (exit.reason != .failure) return error.InvalidState;
    obligation.status = .{ .failed = exit.reason.failure };
    try session.store.replace(frame.obligation.node, .{ .obligation = obligation });
    var parent_exit = (try session.store.get(frame.exit)).exit;
    if (parent_exit.reason == .normal or parent_exit.reason == .abandoned) {
        const discarded = try discardedNormal(session, parent_exit);
        defer session.allocator.free(discarded);
        parent_exit.reason = exit.reason;
        parent_exit.stop = null;
        parent_exit.discarded = discarded;
        try session.store.replace(frame.exit, .{ .exit = parent_exit });
    }
    session.roots.exit = frame.exit;
    try position(session, frame.parent, &.{});
}

pub fn step(session: *Session) Error!?void {
    const current = (try session.store.get(session.roots.current.?)).unwind;
    const exit_reference = session.roots.exit orelse return error.InvalidState;
    const exit = (try session.store.get(exit_reference)).exit;
    const root_reference = try outermost(session);
    var root_exit = (try session.store.get(root_reference)).exit;
    if (root_exit.discarded.len != 0) {
        const count = root_exit.discarded.len;
        const values = try session.allocator.alloc(g.Value, count + current.values.len);
        errdefer session.allocator.free(values);
        @memcpy(values[0..count], root_exit.discarded);
        @memcpy(values[count..], current.values);
        root_exit.discarded = &.{};
        try session.store.replace(root_reference, .{ .exit = root_exit });
        try positionOwned(session, current.cursor, values);
        return null;
    }
    if (current.values.len != 0) {
        try releaseValue(session, current);
        return null;
    }
    if (std.meta.eql(current.cursor, exit.stop) and
        (exit.reason == .normal or exit.reason == .abandoned))
    {
        session.roots.exit = exit.outer;
        session.status = .active;
        if (exit.reason == .normal)
            return session.unwindReturnTo(current.cursor, exit.reason.normal);
        const cursor = current.cursor orelse return error.InvalidState;
        try session.resumeContinuation(cursor, .{ .schema = 0, .body = .{ .scalar = unit_bits } });
        return null;
    }
    const cursor = current.cursor orelse return try session.finishUnwind(root_exit);
    try unwindNode(session, cursor, exit_reference, exit, root_exit);
    return null;
}

fn releaseValue(session: *Session, current: @FieldType(g.Node, "unwind")) Error!void {
    const value = current.values[0];
    const rest = current.values[1..];
    const record = try session.store.get(value.body.owned.node);
    switch (record) {
        .one_shot => {
            const token = try session.takeCapture(value);
            const after = try session.store.add(.{ .disposal_return = .{
                .schema = value.schema,
                .parent = current.cursor,
                .values = rest,
            } });
            try session.activate(token, after);
            try position(session, token.capture, &.{});
        },
        .aggregate, .computation, .package => {
            const fields = switch (record) {
                .aggregate => |aggregate| aggregate.fields,
                .package => |*package| (&package.continuation)[0..1],
                else => (try session.store.get(record.computation.environment)).environment.values,
            };
            const values = try ownedFields(session, fields, rest);
            errdefer session.allocator.free(values);
            try positionOwned(session, current.cursor, values);
        },
        .resource => try position(session, current.cursor, rest),
        else => return error.UnsupportedTransition,
    }
}

fn ownedFields(session: *Session, fields: []const g.Value, rest: []const g.Value) Error![]g.Value {
    var count = rest.len;
    for (fields) |field| if (field.body == .owned) {
        count = std.math.add(usize, count, 1) catch return error.InvalidLength;
    };
    const values = try session.allocator.alloc(g.Value, count);
    var index: usize = 0;
    for (fields) |field| if (field.body == .owned) {
        values[index] = field;
        index += 1;
    };
    @memcpy(values[index..], rest);
    return values;
}

fn unwindNode(
    session: *Session,
    cursor: g.NodeRef,
    exit_reference: g.NodeRef,
    exit: g.Exit,
    root_exit: g.Exit,
) Error!void {
    switch (try session.store.get(cursor)) {
        .control => |saved| try discardFrame(session, cursor, saved.parent),
        .continuation => |saved| try discardFrame(session, cursor, saved.parent),
        .attachment => |attachment| try position(session, attachment.return_to, &.{}),
        .region_scope => |scope| try position(session, scope.return_to, &.{}),
        .injection => |injected| try position(session, injected.continuation, &.{}),
        .disposal_return => |disposal| try position(session, disposal.parent, disposal.values),
        .protection => |protection| try runCleanup(session, protection, exit_reference, root_exit),
        .cleanup_return => |frame| try crossedCleanupReturn(session, frame, exit),
        else => return error.InvalidState,
    }
}

fn runCleanup(
    session: *Session,
    protection: @FieldType(g.Node, "protection"),
    exit_reference: g.NodeRef,
    root_exit: g.Exit,
) Error!void {
    var obligation = (try session.store.get(protection.obligation.node)).obligation;
    if (obligation.status != .pending) return error.InvalidState;
    const cleanup = obligation.cleanup orelse return error.InvalidState;
    const resource = obligation.resource;
    const frame = try session.store.add(.{ .cleanup_return = .{
        .obligation = protection.obligation,
        .parent = protection.return_to,
        .exit = exit_reference,
    } });
    obligation.cleanup = null;
    obligation.resource = null;
    obligation.status = .{ .running = frame };
    try session.store.replace(protection.obligation.node, .{ .obligation = obligation });
    var scratch = std.heap.ArenaAllocator.init(session.allocator);
    defer scratch.deinit();
    var values: Values = .{
        .allocator = scratch.allocator(),
        .schemas = session.program.schemas,
        .store = &session.store,
    };
    const computation = session.program.schemas[@intCast(cleanup.schema)].internal.computation;
    const info = try information(session, &values, computation.parameters[0], root_exit);
    session.status = .active;
    const arguments = if (resource) |owned| &[_]g.Value{ info, owned } else &[_]g.Value{info};
    try session.applyComputation(cleanup, arguments, frame, protection.evidence, protection.region);
}
