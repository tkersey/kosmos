// Copyright (c) 2026 World contributors. MIT license.
//! Cleanup runs ordinary authored computations on the same portable control graph.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const g = data.graph;
const Reason = @FieldType(g.Exit, "reason");

fn position(machine: anytype, cursor: ?g.NodeRef, values: []const g.Value) @TypeOf(machine.*).ExecutionError!void {
    setPosition(machine, try machine.store.add(.{ .unwind = .{ .cursor = cursor, .values = values } }));
}

fn positionOwned(machine: anytype, cursor: ?g.NodeRef, values: []g.Value) @TypeOf(machine.*).ExecutionError!void {
    setPosition(machine, try machine.store.addOwned(.{ .unwind = .{ .cursor = cursor, .values = values } }));
}

fn setPosition(machine: anytype, current: g.NodeRef) void {
    machine.roots.current = current;
    machine.roots.pending = null;
    machine.roots.evidence = null;
    machine.status = .unwinding;
}

pub fn begin(machine: anytype, reason: Reason, cursor: ?g.NodeRef, stop: ?g.NodeRef, values: []const g.Value) @TypeOf(machine.*).ExecutionError!void {
    machine.roots.exit = try machine.store.add(.{ .exit = .{ .reason = reason, .stop = stop, .outer = machine.roots.exit } });
    try position(machine, cursor, values);
}

fn outermost(machine: anytype) @TypeOf(machine.*).ExecutionError!g.NodeRef {
    var ref = machine.roots.exit orelse return error.InvalidState;
    while ((try machine.store.get(ref)).exit.outer) |outer| ref = outer;
    return ref;
}

fn rememberFailure(machine: anytype, value: g.Value) @TypeOf(machine.*).ExecutionError!void {
    const ref = try outermost(machine);
    var exit = (try machine.store.get(ref)).exit;
    const failures = try machine.allocator.alloc(g.Value, exit.cleanup_failures.len + 1);
    errdefer machine.allocator.free(failures);
    @memcpy(failures[0..exit.cleanup_failures.len], exit.cleanup_failures);
    failures[failures.len - 1] = value;
    exit.cleanup_failures = failures;
    const discarded = try discardedNormal(machine, exit);
    errdefer machine.allocator.free(discarded);
    exit.discarded = discarded;
    const storage = @import("store.zig");
    exit.cancellation = try storage.duplicate(@TypeOf(exit.cancellation), machine.allocator, exit.cancellation);
    errdefer storage.release(@TypeOf(exit.cancellation), machine.allocator, exit.cancellation);
    if (exit.reason == .normal or exit.reason == .abandoned) {
        exit.reason = .{ .failure = value };
        exit.stop = null;
    }
    try machine.store.replaceOwned(ref, .{ .exit = exit });
}

fn discardedNormal(machine: anytype, exit: g.Exit) @TypeOf(machine.*).ExecutionError![]g.Value {
    const extra: usize = if (exit.reason == .normal and exit.reason.normal.body == .owned) 1 else 0;
    const values = try machine.allocator.alloc(g.Value, exit.discarded.len + extra);
    @memcpy(values[0..exit.discarded.len], exit.discarded);
    if (extra != 0) values[values.len - 1] = exit.reason.normal;
    return values;
}

pub fn failValues(machine: anytype, value: g.Value, parent: ?g.NodeRef, values: []const g.Value) @TypeOf(machine.*).ExecutionError!void {
    if (machine.roots.exit != null) try rememberFailure(machine, value);
    try begin(machine, .{ .failure = value }, parent, null, values);
}

fn discardFrame(machine: anytype, frame: g.NodeRef, parent: ?g.NodeRef) @TypeOf(machine.*).ExecutionError!void {
    const values = try machine.frames.discards(frame.id);
    errdefer machine.allocator.free(values);
    try machine.frames.remove(frame.id);
    try positionOwned(machine, parent, values);
}

pub fn cancel(machine: anytype, reason: data.invocation.Reason) @TypeOf(machine.*).ExecutionError!void {
    if (reason == .text and !std.unicode.utf8ValidateSlice(reason.text)) return error.InvalidUtf8;
    if (machine.roots.exit == null) {
        const cursor = if (machine.roots.pending) |pending| (try machine.store.get(pending)).pending.continuation else machine.roots.current;
        try begin(machine, .cancellation, cursor, null, &.{});
    }
    const ref = try outermost(machine);
    var exit = (try machine.store.get(ref)).exit;
    if (exit.cancellation != null) return;
    exit.cancellation = reason;
    const discarded = try discardedNormal(machine, exit);
    defer machine.allocator.free(discarded);
    if (exit.reason == .normal or exit.reason == .abandoned) {
        exit.reason = .cancellation;
        exit.stop = null;
        exit.discarded = discarded;
    }
    try machine.store.replace(ref, .{ .exit = exit });
}

pub fn protect(machine: anytype, protection: anytype, slots: anytype, control: g.Control) @TypeOf(machine.*).ExecutionError!void {
    const body = try @import("operands.zig").read(slots, protection.body);
    const resource: ?g.Value = if (protection.resource) |slot| (try @import("operands.zig").read(slots, slot)) else null;
    const obligation = try machine.store.add(.{ .obligation = .{ .source_block = control.block, .cleanup = (try @import("operands.zig").read(slots, protection.cleanup)), .resource = resource, .status = .pending } });
    const loan: ?g.NodeRef = if (protection.loan_region) |descriptor| try machine.store.add(.{ .region = .{ .descriptor = descriptor, .outer = control.region, .obligations = &.{} } }) else null;
    const extra: usize = @intFromBool(resource != null);
    const arguments = try machine.allocator.alloc(g.Value, protection.arguments.len + extra);
    defer machine.allocator.free(arguments);
    if (resource) |owned| {
        const schema = machine.program.schemas[@intCast(body.schema)].internal.computation.parameters[0];
        const borrowed = try machine.store.add(.{ .borrow = .{ .schema = schema, .resource = owned.body.owned.node, .region = loan.? } });
        arguments[0] = .{ .schema = schema, .body = .{ .reference = borrowed } };
    }
    for (arguments[extra..], protection.arguments) |*argument, slot| argument.* = (try @import("operands.zig").read(slots, slot));
    const after = try machine.continuation(control.block, slots, control);
    const frame = try machine.store.add(.{ .protection = .{ .source_block = control.block, .obligation = .{ .node = obligation }, .return_to = after, .evidence = control.evidence, .region = control.region, .loan = loan } });
    try machine.applyComputation(body, arguments, frame, control.evidence, loan orelse control.region);
}

pub fn dispose(machine: anytype, disposal: anytype, slots: anytype, control: g.Control) @TypeOf(machine.*).ExecutionError!void {
    const token = try machine.takeCapture((try @import("operands.zig").read(slots, disposal.owned)));
    const after = try machine.continuation(control.block, slots, control);
    try machine.activate(token, after);
    try begin(machine, .abandoned, token.capture, after, &.{});
}

fn information(machine: anytype, values: *@import("values.zig").Values, schema: p.Id, exit: g.Exit) @TypeOf(machine.*).ExecutionError!g.Value {
    const types = try data.cleanup_contract.types(machine.program, schema);
    const unit: g.Value = .{ .schema = types.unit, .body = .{ .scalar = @as([8]u8, @splat(0)) } };
    var reason_value = unit;
    if (exit.cancellation) |reason| {
        var measure: data.wire.Writer = .{};
        const bytes = if (reason == .text) reason.text else reason.bytes;
        try measure.bytes(bytes);
        const encoded = try values.allocator.alloc(u8, measure.position);
        var writer: data.wire.Writer = .{ .output = encoded };
        try writer.bytes(bytes);
        const payload = try machine.store.literal(machine.program.schemas, .{ .schema = if (reason == .text) types.text else types.bytes, .bytes = encoded });
        reason_value = try values.aggregate(types.reason, .{ .tag = @backingInt(std.meta.activeTag(reason)), .fields = &.{payload} });
    }
    const primary = try values.aggregate(types.primary, .{ .tag = @backingInt(std.meta.activeTag(exit.reason)), .fields = &.{switch (exit.reason) {
        .normal, .abandoned => unit,
        .failure => |failure| failure,
        .cancellation => reason_value,
    }} });
    const optional = try values.aggregate(types.optional_reason, .{ .tag = if (exit.cancellation != null) 1 else 0, .fields = &.{reason_value} });
    const failures = try values.aggregate(types.failures, .{ .fields = exit.cleanup_failures });
    return values.aggregate(schema, .{ .fields = &.{ primary, optional, failures } });
}

pub fn returned(machine: anytype, reference: g.NodeRef) @TypeOf(machine.*).ExecutionError!void {
    const frame = (try machine.store.get(reference)).cleanup_return;
    var obligation = (try machine.store.get(frame.obligation.node)).obligation;
    obligation.status = .completed;
    try machine.store.replace(frame.obligation.node, .{ .obligation = obligation });
    machine.roots.exit = frame.exit;
    try position(machine, frame.parent, &.{});
}

fn unlinkSuspendedExit(machine: anytype, retired: g.NodeRef) @TypeOf(machine.*).ExecutionError!void {
    const prior = (try machine.store.get(retired)).exit;
    var cursor = machine.roots.exit orelse return error.InvalidState;
    if (cursor.id == retired.id) return;
    for (0..machine.store.nodes.items.len) |_| {
        var record = (try machine.store.get(cursor)).exit;
        const outer = record.outer orelse return error.InvalidState;
        if (outer.id == retired.id) {
            record.outer = prior.outer;
            try machine.store.replace(cursor, .{ .exit = record });
            if (prior.reason == .failure or prior.reason == .cancellation or prior.cancellation != null) {
                const active = machine.roots.exit.?;
                var current = (try machine.store.get(active)).exit;
                var failures: std.ArrayList(g.Value) = .empty;
                defer failures.deinit(machine.allocator);
                try failures.appendSlice(machine.allocator, prior.cleanup_failures);
                try failures.appendSlice(machine.allocator, current.cleanup_failures);
                current.reason = if (prior.reason == .failure) prior.reason else .cancellation;
                current.cancellation = prior.cancellation orelse current.cancellation;
                current.cleanup_failures = failures.items;
                current.stop = null;
                try machine.store.replace(active, .{ .exit = current });
            }
            return;
        }
        cursor = outer;
    }
    return error.InvalidState;
}

pub fn returnedDisposal(machine: anytype, frame: anytype, value: g.Value) @TypeOf(machine.*).ExecutionError!void {
    var remaining: std.ArrayList(g.Value) = .empty;
    defer remaining.deinit(machine.allocator);
    if (value.body == .owned) try remaining.append(machine.allocator, value);
    try remaining.appendSlice(machine.allocator, frame.values);
    try position(machine, frame.parent, remaining.items);
}

fn crossedCleanupReturn(machine: anytype, frame: anytype, exit: g.Exit) @TypeOf(machine.*).ExecutionError!void {
    var obligation = (try machine.store.get(frame.obligation.node)).obligation;
    if (exit.reason == .abandoned or exit.reason == .cancellation) {
        // Cancellation can replace an abandonment while its cleanup capture is
        // being disposed. Crossing that capture still completes its obligation;
        // the exit retains the cancellation until the outer unwind finishes.
        const suspended = (try machine.store.get(frame.exit)).exit;
        const discarded = try discardedNormal(machine, suspended);
        defer machine.allocator.free(discarded);
        try unlinkSuspendedExit(machine, frame.exit);
        obligation.status = .completed;
        try machine.store.replace(frame.obligation.node, .{ .obligation = obligation });
        try position(machine, frame.parent, discarded);
        return;
    }
    if (exit.reason != .failure) return error.InvalidState;
    obligation.status = .{ .failed = exit.reason.failure };
    try machine.store.replace(frame.obligation.node, .{ .obligation = obligation });
    var parent_exit = (try machine.store.get(frame.exit)).exit;
    if (parent_exit.reason == .normal or parent_exit.reason == .abandoned) {
        const discarded = try discardedNormal(machine, parent_exit);
        defer machine.allocator.free(discarded);
        parent_exit.reason = exit.reason;
        parent_exit.stop = null;
        parent_exit.discarded = discarded;
        try machine.store.replace(frame.exit, .{ .exit = parent_exit });
    }
    machine.roots.exit = frame.exit;
    try position(machine, frame.parent, &.{});
}

pub fn step(machine: anytype) @TypeOf(machine.*).ExecutionError!?@TypeOf(machine.*).UnwindOutcome {
    var scratch = std.heap.ArenaAllocator.init(machine.allocator);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    const current = (try machine.store.get(machine.roots.current.?)).unwind;
    const exit_ref = machine.roots.exit orelse return error.InvalidState;
    const exit = (try machine.store.get(exit_ref)).exit;
    const root_ref = try outermost(machine);
    var root_exit = (try machine.store.get(root_ref)).exit;
    if (root_exit.discarded.len != 0) {
        const values = try machine.allocator.alloc(g.Value, root_exit.discarded.len + current.values.len);
        errdefer machine.allocator.free(values);
        @memcpy(values[0..root_exit.discarded.len], root_exit.discarded);
        @memcpy(values[root_exit.discarded.len..], current.values);
        root_exit.discarded = &.{};
        try machine.store.replace(root_ref, .{ .exit = root_exit });
        try positionOwned(machine, current.cursor, values);
        return null;
    }
    if (current.values.len != 0) {
        const value = current.values[0];
        const rest = current.values[1..];
        const record = try machine.store.get(value.body.owned.node);
        switch (record) {
            .one_shot => {
                const token = try machine.takeCapture(value);
                const after = try machine.store.add(.{ .disposal_return = .{ .schema = value.schema, .parent = current.cursor, .values = rest } });
                try machine.activate(token, after);
                try position(machine, token.capture, &.{});
            },
            .aggregate, .computation, .package => {
                const fields = if (record == .aggregate) record.aggregate.fields else if (record == .package) (&record.package.continuation)[0..1] else (try machine.store.get(record.computation.environment)).environment.values;
                var count = rest.len;
                for (fields) |field| if (field.body == .owned) {
                    count = std.math.add(usize, count, 1) catch return error.InvalidLength;
                };
                const values = try machine.allocator.alloc(g.Value, count);
                errdefer machine.allocator.free(values);
                var index: usize = 0;
                for (fields) |field| if (field.body == .owned) {
                    values[index] = field;
                    index += 1;
                };
                @memcpy(values[index..], rest);
                try positionOwned(machine, current.cursor, values);
            },
            .resource => try position(machine, current.cursor, rest), // No implicit effectful finalizer.
            else => return error.UnsupportedTransition,
        }
        return null;
    }
    if (std.meta.eql(current.cursor, exit.stop) and (exit.reason == .normal or exit.reason == .abandoned)) {
        machine.roots.exit = exit.outer;
        machine.status = .active;
        if (exit.reason == .normal) return machine.unwindReturnTo(current.cursor, exit.reason.normal);
        try machine.resumeContinuation(current.cursor orelse return error.InvalidState, .{ .schema = 0, .body = .{ .scalar = @as([8]u8, @splat(0)) } });
        return null;
    }
    const cursor = current.cursor orelse return try machine.finishUnwind(root_exit);
    switch (try machine.store.get(cursor)) {
        .control => |control| try discardFrame(machine, cursor, control.parent),
        .continuation => |saved| try discardFrame(machine, cursor, saved.parent),
        .attachment => |attachment| try position(machine, attachment.return_to, &.{}),
        .region_scope => |scope| try position(machine, scope.return_to, &.{}),
        .injection => |injected| try position(machine, injected.continuation, &.{}),
        .disposal_return => |disposal| try position(machine, disposal.parent, disposal.values),
        .protection => |protection| {
            var obligation = (try machine.store.get(protection.obligation.node)).obligation;
            if (obligation.status != .pending) return error.InvalidState;
            const cleanup = obligation.cleanup orelse return error.InvalidState;
            const resource = obligation.resource;
            const frame = try machine.store.add(.{ .cleanup_return = .{ .obligation = protection.obligation, .parent = protection.return_to, .exit = exit_ref } });
            obligation.cleanup = null;
            obligation.resource = null;
            obligation.status = .{ .running = frame };
            try machine.store.replace(protection.obligation.node, .{ .obligation = obligation });
            var values: @import("values.zig").Values = .{ .allocator = temporary, .schemas = machine.program.schemas, .store = &machine.store };
            const info = try information(machine, &values, machine.program.schemas[@intCast(cleanup.schema)].internal.computation.parameters[0], root_exit);
            machine.status = .active;
            const arguments = if (resource) |owned| &[_]g.Value{ info, owned } else &[_]g.Value{info};
            try machine.applyComputation(cleanup, arguments, frame, protection.evidence, protection.region);
        },
        .cleanup_return => |frame| try crossedCleanupReturn(machine, frame, exit),
        else => return error.InvalidState,
    }
    return null;
}
