// Copyright (c) 2026 World contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const ir = data.activation;
const g = data.graph;
const bindings = @import("../interpreter_v2/activation_frames.zig");
const read = @import("../interpreter_v2/operands.zig").read;
const Values = @import("../interpreter_v2/values.zig").Values;
const Session = @import("session.zig").Session;
const Error = @import("session.zig").Error;
const unwind = @import("unwind.zig");
const resumption = @import("resumption.zig");

const small_arguments_max = 8;

pub fn execute(
    session: *Session,
    current: g.NodeRef,
    saved: g.Control,
    code: ir.Block,
    frame: *bindings.Frame,
    body_constructor: ?p.Id,
) Error!void {
    const reader = try session.frames.slots.reader(frame.view);
    var temporary = std.heap.ArenaAllocator.init(session.allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    switch (code.terminator) {
        .return_value => |slot| try returnTo(session, saved.parent, try read(reader, slot)),
        .fail => |slot| try session.failCurrent(current, try read(reader, slot)),
        .jump => |edge| try jump(session, current, saved, frame, edge, null),
        .yield_value => |edge| {
            try jump(session, current, saved, frame, edge, null);
            session.status = .yielded;
        },
        .branch => |branch| {
            const condition = try read(reader, branch.condition);
            const edge = if (condition.body.scalar[0] == 1) branch.when_true else branch.when_false;
            try jump(session, current, saved, frame, edge, null);
        },
        .call => |call| try callFunction(session, current, saved, frame, call, reader, scratch),
        .switch_variant, .unpack_product => try aggregateControl(
            session,
            current,
            saved,
            frame,
            code.terminator,
            reader,
            scratch,
        ),
        else => try higherOrder(
            session,
            current,
            saved,
            frame.*,
            code.terminator,
            reader,
            scratch,
            body_constructor,
        ),
    }
}

fn higherOrder(
    session: *Session,
    current: g.NodeRef,
    saved: g.Control,
    frame: bindings.Frame,
    terminator: ir.Terminator,
    reader: anytype,
    scratch: std.mem.Allocator,
    body_constructor: ?p.Id,
) Error!void {
    switch (terminator) {
        .apply => |operation| {
            const computation = try read(reader, operation.computation);
            const arguments = try collectArguments(scratch, reader, operation.arguments);
            const parent = if (isTail(session, operation.next))
                saved.parent
            else
                try captureContinuation(session, current, saved, frame, operation.next);
            try applyComputation(
                session,
                computation,
                arguments,
                parent,
                saved.evidence,
                saved.region,
            );
        },
        .protect => |protection| try unwind.protect(session, protection, reader, saved),
        .dispose => |disposal| try unwind.dispose(session, disposal, reader, saved),
        .handle => |operation| try install(
            session,
            current,
            saved,
            frame,
            operation,
            reader,
            scratch,
            body_constructor,
        ),
        .perform => |operation| try perform(
            session,
            current,
            saved,
            frame,
            operation,
            reader,
            scratch,
        ),
        .resume_value, .resume_with, .resume_computation => try resumeControl(
            session,
            current,
            saved,
            frame,
            terminator,
            reader,
            scratch,
        ),
        .with_region => |region| try withRegion(
            session,
            current,
            saved,
            frame,
            region,
            reader,
            scratch,
        ),
        else => return error.InvalidState,
    }
}

fn callFunction(
    session: *Session,
    current: g.NodeRef,
    saved: g.Control,
    frame: *bindings.Frame,
    call: @FieldType(ir.Terminator, "call"),
    reader: anytype,
    scratch: std.mem.Allocator,
) Error!void {
    var small: [small_arguments_max]g.Value = undefined;
    const arguments = if (call.arguments.len <= small.len) local: {
        const values = small[0..call.arguments.len];
        for (values, call.arguments) |*value, slot| value.* = try read(reader, slot);
        if (session.statistics) |statistics| statistics.stack_argument_calls +|= 1;
        break :local values;
    } else allocated: {
        if (session.statistics) |statistics| statistics.heap_argument_calls +|= 1;
        break :allocated try collectArguments(scratch, reader, call.arguments);
    };
    const tail = isTail(session, call.next);
    if (tail and session.frames.canRestart(frame.*, call.function)) {
        const entry = session.program.functions[@intCast(call.function)].entry;
        const live = session.flow.facts.live[@intCast(entry)][0];
        try session.frames.restart(frame, call.function, live, arguments);
        var changed = saved;
        changed.block = entry;
        try session.store.replace(current, .{ .control = changed });
        try session.frames.update(current.id, frame.*);
        if (session.statistics) |statistics| statistics.tail_frame_reuses +|= 1;
        return;
    }
    if (tail) if (session.statistics) |statistics| {
        statistics.tail_frame_reuse_fallbacks +|= 1;
    };
    const parent = if (tail)
        saved.parent
    else
        try captureContinuation(session, current, saved, frame.*, call.next);
    try enter(session, call.function, arguments, parent, saved.evidence, saved.region);
}

fn withRegion(
    session: *Session,
    current: g.NodeRef,
    saved: g.Control,
    frame: bindings.Frame,
    region: @FieldType(ir.Terminator, "with_region"),
    reader: anytype,
    scratch: std.mem.Allocator,
) Error!void {
    const descriptor = try session.store.add(.{ .region = .{
        .descriptor = region.region,
        .outer = saved.region,
        .obligations = &.{},
    } });
    const body = try read(reader, region.body);
    const schema = session.program.schemas[@intCast(body.schema)];
    const parameters = schema.internal.computation.parameters;
    const arguments = try scratch.alloc(g.Value, region.arguments.len + 1);
    arguments[0] = .{ .schema = parameters[0], .body = .{ .reference = descriptor } };
    for (arguments[1..], region.arguments) |*value, slot| value.* = try read(reader, slot);
    const after = try captureContinuation(session, current, saved, frame, region.next);
    const wrapper = try session.store.add(.{ .region_scope = .{
        .source_block = saved.block,
        .region = descriptor,
        .return_to = after,
    } });
    try applyComputation(session, body, arguments, wrapper, saved.evidence, descriptor);
}

fn resumeControl(
    session: *Session,
    current: g.NodeRef,
    saved: g.Control,
    frame: bindings.Frame,
    terminator: ir.Terminator,
    reader: anytype,
    scratch: std.mem.Allocator,
) Error!void {
    switch (terminator) {
        inline .resume_value, .resume_with, .resume_computation => |operation, kind| {
            const value = try read(reader, operation.resumption);
            const token = try takeCapture(session, value);
            defer if (session.program.schemas[@intCast(value.schema)].internal.resumption.use ==
                .multi) session.allocator.free(token.use_site_capabilities);
            const argument = try read(reader, if (comptime kind == .resume_computation)
                operation.computation
            else
                operation.argument);
            const state = if (comptime kind == .resume_with)
                try collectArguments(scratch, reader, operation.state)
            else
                &.{};
            const after = try captureContinuation(session, current, saved, frame, operation.next);
            if (comptime kind == .resume_with) {
                try reinstall(session, saved, token, operation.handler, state, after, argument);
            } else {
                const evidence = try resumption.prepare(session, token, after);
                if (comptime kind == .resume_value) {
                    try resumeContinuation(session, token.capture.?, argument);
                } else try inject(session, token, argument, evidence);
            }
        },
        else => return error.InvalidState,
    }
}

fn reinstall(
    session: *Session,
    saved: g.Control,
    token: g.Capture,
    definition: p.Id,
    state: []const g.Value,
    after: g.NodeRef,
    argument: g.Value,
) Error!void {
    const handler = try session.store.add(.{ .handler = .{
        .definition = definition,
        .state = state,
        .evidence = saved.evidence,
        .region = saved.region,
    } });
    try session.store.replace(token.delimiter, .{ .attachment = .{
        .handler = handler,
        .outer = saved.evidence,
        .return_to = after,
        .region = saved.region,
    } });
    try resumeContinuation(session, token.capture.?, argument);
}

fn inject(
    session: *Session,
    token: g.Capture,
    computation: g.Value,
    evidence: ?g.NodeRef,
) Error!void {
    const captured = token.capture.?;
    const saved = (try session.store.get(captured)).continuation;
    const injection = try session.store.add(.{ .injection = .{ .continuation = captured } });
    try applyComputation(
        session,
        computation,
        token.use_site_capabilities,
        injection,
        evidence,
        saved.region,
    );
}

fn collectArguments(
    allocator: std.mem.Allocator,
    reader: anytype,
    operands: []const p.Id,
) Error![]g.Value {
    const values = try allocator.alloc(g.Value, operands.len);
    for (values, operands) |*value, slot| value.* = try read(reader, slot);
    return values;
}

fn isTail(session: *const Session, edge: ir.Edge) bool {
    const target = session.program.blocks[@intCast(edge.block)];
    return target.instructions.len == 0 and target.terminator == .return_value and
        edge.assignments.len == 1 and edge.assignments[0].source == .returned and
        edge.assignments[0].destination == target.terminator.return_value;
}

pub fn enter(
    session: *Session,
    function: p.Id,
    arguments: []const g.Value,
    parent: ?g.NodeRef,
    evidence: ?g.NodeRef,
    region: ?g.NodeRef,
) Error!void {
    const target = session.program.functions[@intCast(function)];
    if (target.inputs.len != arguments.len) return error.InvalidState;
    const record: g.Node = .{ .control = .{
        .block = target.entry,
        .parent = parent,
        .evidence = evidence,
        .region = region,
    } };
    const reuse = if (session.roots.current) |current|
        if (try session.store.get(current) == .control) current else null
    else
        null;
    const node = reuse orelse try session.store.add(record);
    var frame = try session.frames.create(function);
    errdefer session.frames.releaseFrame(frame);
    const live = session.flow.facts.live[@intCast(target.entry)][0];
    try session.frames.apply(&frame, live, target.inputs, arguments);
    if (reuse != null) {
        const previous = try session.frames.get(node.id);
        try session.store.replace(node, record);
        try session.frames.update(node.id, frame);
        session.frames.releaseFrame(previous);
    } else try session.frames.put(node.id, frame);
    session.roots.current = node;
    session.roots.evidence = evidence;
}

pub fn applyComputation(
    session: *Session,
    value: g.Value,
    supplied: []const g.Value,
    parent: ?g.NodeRef,
    evidence: ?g.NodeRef,
    region: ?g.NodeRef,
) Error!void {
    const closure = (try session.store.get(valueRef(value))).computation;
    const definition = session.program.constructors[@intCast(closure.constructor)];
    const captured = (try session.store.get(closure.environment)).environment.values;
    const values = try std.mem.concat(session.allocator, g.Value, &.{ captured, supplied });
    defer session.allocator.free(values);
    try enter(session, definition.function, values, parent, evidence, region);
}

fn retainedSlots(session: *Session, edge: ir.Edge) Error!data.analysis_sets.Root {
    const pool = session.flow.facts.pool;
    const after = session.flow.facts.live[@intCast(edge.block)][0];
    var root = after;
    for (edge.assignments) |assignment| root = try pool.remove(root, assignment.destination);
    for (edge.assignments) |assignment| {
        if (assignment.source == .slot and pool.contains(after, assignment.destination))
            root = try pool.insert(root, assignment.source.slot);
    }
    return root;
}

pub fn captureContinuation(
    session: *Session,
    current: g.NodeRef,
    saved: g.Control,
    original: bindings.Frame,
    edge: ir.Edge,
) Error!g.NodeRef {
    var frame = original;
    try session.frames.prune(&frame, try retainedSlots(session, edge));
    try session.store.replace(current, .{ .continuation = .{
        .source_block = saved.block,
        .parent = saved.parent,
        .evidence = saved.evidence,
        .region = saved.region,
    } });
    try session.frames.update(current.id, frame);
    return current;
}

fn assignEdge(
    session: *Session,
    frame: *bindings.Frame,
    next: ir.Edge,
    returned: ?g.Value,
) Error!void {
    const values = try session.allocator.alloc(g.Value, next.assignments.len);
    defer session.allocator.free(values);
    const live = session.flow.facts.live[@intCast(next.block)][0];
    for (values, next.assignments) |*value, assignment| {
        if (!session.flow.facts.pool.contains(live, assignment.destination)) continue;
        value.* = switch (assignment.source) {
            .slot => |slot| try session.frames.slots.get(frame.view, @intCast(slot)),
            .returned => returned orelse return error.InvalidState,
        };
    }
    const block = session.program.blocks[@intCast(next.block)];
    const layout = session.program.functions[@intCast(block.function)].layout.slots;
    for (next.assignments) |assignment| if (assignment.source == .slot) {
        const slot = assignment.source.slot;
        if (!session.uses.copy[@intCast(layout[@intCast(slot)])])
            try session.frames.clear(frame, slot);
    };
    try session.frames.scope(frame, block.custody);
    try session.frames.apply(frame, live, next.assignments, values);
    frame.position = 0;
}

fn jump(
    session: *Session,
    current: g.NodeRef,
    saved: g.Control,
    frame: *bindings.Frame,
    next: ir.Edge,
    returned: ?g.Value,
) Error!void {
    try assignEdge(session, frame, next, returned);
    var changed = saved;
    changed.block = next.block;
    try session.store.replace(current, .{ .control = changed });
    try session.frames.update(current.id, frame.*);
}

pub fn resumeContinuation(session: *Session, reference: g.NodeRef, value: g.Value) Error!void {
    const saved = (try session.store.get(reference)).continuation;
    const terminator = session.program.blocks[@intCast(saved.source_block)].terminator;
    const next = nextEdge(terminator) orelse return error.InvalidState;
    try session.store.replace(reference, .{ .control = .{
        .block = next.block,
        .parent = saved.parent,
        .evidence = saved.evidence,
        .region = saved.region,
    } });
    var frame = try session.frames.getForUpdate(reference.id);
    try assignEdge(session, &frame, next, value);
    try session.frames.update(reference.id, frame);
    session.roots.current = reference;
    session.roots.evidence = saved.evidence;
}

pub fn returnTo(session: *Session, parent: ?g.NodeRef, value: g.Value) Error!void {
    var cursor = parent;
    while (cursor) |reference| {
        switch (try session.store.get(reference)) {
            .region_scope => |region| {
                cursor = region.return_to;
                continue;
            },
            .continuation => |saved| {
                const terminator = session.program.blocks[@intCast(saved.source_block)].terminator;
                if (value.body == .owned and terminator == .dispose)
                    try unwind.begin(session, .abandoned, reference, reference, &.{value})
                else
                    try resumeContinuation(session, reference, value);
            },
            .injection => |injection| try resumeContinuation(
                session,
                injection.continuation,
                value,
            ),
            .protection => |protection| try unwind.begin(
                session,
                .{ .normal = value },
                reference,
                protection.return_to,
                &.{},
            ),
            .cleanup_return => try unwind.returned(session, reference),
            .disposal_return => |disposal| try unwind.returnedDisposal(session, disposal, value),
            .attachment => |attachment| try returnFromHandler(session, attachment, value),
            else => return error.UnsupportedTransition,
        }
        return;
    }
    try session.finishTerminal(.{ .reason = .{ .normal = value } });
}

fn returnFromHandler(
    session: *Session,
    attachment: @FieldType(g.Node, "attachment"),
    value: g.Value,
) Error!void {
    if (attachment.phase != .active) return error.InvalidState;
    const handler = (try session.store.get(attachment.handler)).handler;
    const definition = session.program.handlers[@intCast(handler.definition)];
    const values = try std.mem.concat(session.allocator, g.Value, &.{ handler.state, &.{value} });
    defer session.allocator.free(values);
    try enter(
        session,
        definition.return_function,
        values,
        attachment.return_to,
        handler.evidence,
        handler.region,
    );
}

pub fn knownHandlerBody(session: *const Session, code: ir.Block) ?p.Id {
    const instruction = code.instructions[code.instructions.len - 1];
    const operation = code.terminator.handle;
    if (instruction.opcode != .computation or instruction.operands.len != 0 or
        instruction.destination != operation.body) return null;
    const definition = session.program.constructors[@intCast(instruction.immediate)];
    const schema = session.program.schemas[@intCast(definition.schema)];
    if (schema.internal.computation.use != .reusable) return null;
    if (std.mem.indexOfScalar(p.Id, operation.arguments, instruction.destination) != null or
        std.mem.indexOfScalar(p.Id, operation.state, instruction.destination) != null)
        return null;
    const live = session.flow.facts.live[@intCast(operation.next.block)][0];
    var overwritten = false;
    for (operation.next.assignments) |assignment| {
        overwritten = overwritten or assignment.destination == instruction.destination;
        if (assignment.source == .slot and assignment.source.slot == instruction.destination)
            return null;
    }
    if (!overwritten and session.flow.facts.pool.contains(live, instruction.destination))
        return null;
    return instruction.immediate;
}

fn install(
    session: *Session,
    current: g.NodeRef,
    saved: g.Control,
    frame: bindings.Frame,
    operation: @FieldType(ir.Terminator, "handle"),
    reader: anytype,
    scratch: std.mem.Allocator,
    body_constructor: ?p.Id,
) Error!void {
    const definition = session.program.handlers[@intCast(operation.handler)];
    try session.store.reserveNodes(3);
    const state = try collectArguments(scratch, reader, operation.state);
    const known = if (body_constructor) |id| session.program.constructors[@intCast(id)] else null;
    const body: ?g.Value = if (known == null) try read(reader, operation.body) else null;
    const body_schema = if (known) |constructor| constructor.schema else body.?.schema;
    const signature = session.program.schemas[@intCast(body_schema)].internal.computation;
    const clauses = definition.clauses.len;
    const arguments = try scratch.alloc(g.Value, clauses + operation.arguments.len);
    for (arguments[clauses..], operation.arguments) |*value, slot| value.* = try read(reader, slot);
    const handler = try session.store.add(.{ .handler = .{
        .definition = operation.handler,
        .state = state,
        .evidence = saved.evidence,
        .region = saved.region,
    } });
    const after = try captureContinuation(session, current, saved, frame, operation.next);
    const attachment = try session.store.add(.{ .attachment = .{
        .handler = handler,
        .outer = saved.evidence,
        .return_to = after,
        .region = saved.region,
    } });
    for (arguments[0..clauses], 0..) |*argument, index| argument.* = .{
        .schema = signature.parameters[index],
        .body = .{ .reference = attachment },
    };
    if (known) |constructor| {
        try enter(session, constructor.function, arguments, attachment, attachment, saved.region);
    } else try applyComputation(session, body.?, arguments, attachment, attachment, saved.region);
}

fn perform(
    session: *Session,
    current: g.NodeRef,
    saved: g.Control,
    frame: bindings.Frame,
    operation: ir.Perform,
    reader: anytype,
    scratch: std.mem.Allocator,
) Error!void {
    const payload = try read(reader, operation.payload);
    const capability = operation.capability orelse {
        const captured = try captureContinuation(session, current, saved, frame, operation.next);
        session.roots.pending = try session.store.add(.{ .pending = .{
            .effect = operation.effect,
            .payload = payload,
            .continuation = captured,
            .source_block = saved.block,
        } });
        session.roots.current = null;
        session.status = .parked;
        return;
    };
    const selected = valueRef(try read(reader, capability));
    try inScope(session, saved.parent, selected);
    const record = try session.store.get(selected);
    if (record != .attachment or record.attachment.phase != .active) return error.InvalidScope;
    const handler = (try session.store.get(record.attachment.handler)).handler;
    const definition = session.program.handlers[@intCast(handler.definition)];
    var found: ?ir.Clause = null;
    for (definition.clauses) |clause| if (clause.effect == operation.effect) {
        found = clause;
        break;
    };
    const clause = found orelse return error.InvalidEffect;
    if (clause.strategy == .tail) {
        const captured = try captureContinuation(session, current, saved, frame, operation.next);
        return enterTailClause(session, scratch, handler, clause.function, payload, captured);
    }
    const use_site = try collectArguments(scratch, reader, operation.use_site_capabilities);
    const state = handler.state.len;
    const arguments = try scratch.alloc(g.Value, state + operation.bodies.len + 2);
    @memcpy(arguments[0..state], handler.state);
    arguments[state] = payload;
    for (operation.bodies, arguments[state + 1 ..][0..operation.bodies.len]) |slot, *argument|
        argument.* = try read(reader, slot);
    const captured = try captureContinuation(session, current, saved, frame, operation.next);
    arguments[arguments.len - 1] = try suspendHandler(session, .{
        .schema = clause.resumption,
        .capture = captured,
        .delimiter = selected,
        .evidence = saved.evidence,
        .use_site_capabilities = use_site,
    }, record.attachment);
    try enter(
        session,
        clause.function,
        arguments,
        record.attachment.return_to,
        handler.evidence,
        handler.region,
    );
}

fn suspendHandler(
    session: *Session,
    capture: g.Capture,
    active: @FieldType(g.Node, "attachment"),
) Error!g.Value {
    const resumption_schema = session.program.schemas[@intCast(capture.schema)];
    const multi = resumption_schema.internal.resumption.use == .multi;
    const token = try session.store.add(if (multi)
        .{ .multi_template = capture }
    else
        .{ .one_shot = capture });
    if (session.statistics) |statistics| {
        if (multi) statistics.multi_templates +|= 1 else statistics.one_shot_captures +|= 1;
    }
    var attachment = active;
    attachment.return_to = null;
    attachment.phase = .suspended;
    try session.store.replace(capture.delimiter, .{ .attachment = attachment });
    return .{
        .schema = capture.schema,
        .body = if (multi) .{ .reference = token } else .{ .owned = .{ .node = token } },
    };
}

fn enterTailClause(
    session: *Session,
    scratch: std.mem.Allocator,
    handler: @FieldType(g.Node, "handler"),
    function: p.Id,
    payload: g.Value,
    captured: g.NodeRef,
) Error!void {
    const arguments = try scratch.alloc(g.Value, handler.state.len + 1);
    @memcpy(arguments[0..handler.state.len], handler.state);
    arguments[handler.state.len] = payload;
    try enter(session, function, arguments, captured, handler.evidence, handler.region);
    if (session.statistics) |statistics| statistics.direct_clauses +|= 1;
}

pub fn takeCapture(session: *Session, value: g.Value) Error!g.Capture {
    const reference = valueRef(value);
    const record = try session.store.get(reference);
    if (record == .multi_template) {
        const branch = try @import("clone.zig").instantiate(
            session.allocator,
            &session.store,
            record.multi_template,
            &session.frames,
        );
        if (session.statistics) |statistics| statistics.branch_activations +|= 1;
        return branch;
    }
    if (record != .one_shot or record.one_shot.capture == null) return error.InvalidOwnership;
    var consumed = record.one_shot;
    consumed.capture = null;
    try session.store.replace(reference, .{ .one_shot = consumed });
    var result = record.one_shot;
    const retained = (try session.store.get(reference)).one_shot;
    result.use_site_capabilities = retained.use_site_capabilities;
    return result;
}

fn inScope(session: *Session, parent: ?g.NodeRef, target: g.NodeRef) Error!void {
    var cursor = parent;
    while (cursor) |reference| {
        if (reference.id == target.id) return;
        cursor = switch (try session.store.get(reference)) {
            .continuation => |saved| saved.parent,
            .attachment => |attachment| attachment.return_to,
            .region_scope => |region| region.return_to,
            .injection => |injection| injection.continuation,
            .protection => |protection| protection.return_to,
            .cleanup_return => |cleanup| cleanup.parent,
            .disposal_return => |disposal| disposal.parent,
            else => return error.InvalidScope,
        };
    }
    return error.InvalidScope;
}

fn aggregateControl(
    session: *Session,
    current: g.NodeRef,
    saved: g.Control,
    frame: *bindings.Frame,
    terminator: ir.Terminator,
    reader: anytype,
    scratch: std.mem.Allocator,
) Error!void {
    var values: Values = .{
        .allocator = scratch,
        .schemas = session.program.schemas,
        .store = &session.store,
    };
    switch (terminator) {
        .switch_variant => |selected| {
            const parts = try values.split(try read(reader, selected.value));
            const function = session.program.blocks[@intCast(saved.block)].function;
            const layout = session.program.functions[@intCast(function)].layout.slots;
            if (!session.uses.copy[@intCast(layout[@intCast(selected.value)])])
                try session.frames.clear(frame, selected.value);
            const edge = selected.cases[@intCast(parts.tag)];
            try jump(session, current, saved, frame, edge, parts.fields[0]);
        },
        .unpack_product => |unpack| {
            const value = try read(reader, unpack.value);
            const parts = try values.split(value);
            if (!session.uses.copy[@intCast(value.schema)])
                try session.frames.clear(frame, unpack.value);
            const custody = session.program.blocks[@intCast(unpack.next.block)].custody;
            try session.frames.scope(frame, custody);
            for (parts.fields, unpack.destinations) |field, slot|
                try session.frames.write(frame, slot, field);
            try jump(session, current, saved, frame, unpack.next, null);
        },
        else => return error.InvalidState,
    }
}

pub fn valueRef(value: g.Value) g.NodeRef {
    return switch (value.body) {
        .reference => |reference| reference,
        .owned => |owned| owned.node,
        else => unreachable,
    };
}

pub fn nextEdge(terminator: ir.Terminator) ?ir.Edge {
    return switch (terminator) {
        inline .call,
        .perform,
        .apply,
        .handle,
        .resume_value,
        .resume_with,
        .resume_computation,
        .with_region,
        .protect,
        .dispose,
        => |operation| operation.next,
        else => null,
    };
}
