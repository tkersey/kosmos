//! Portable guest control transitions. All graph changes are ordinary values.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const edges = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const ir = data.activation;
const g = data.graph;
const field = edges.field;

pub const Definition = struct {
    execute: Id,
    jump: Id,
    capture: Id,
    enter: Id,
    apply: Id,
    resume_continuation: Id,
    return_to: Id,
    unwind: @import("unwind.zig").Definition,
};

pub fn roots(e: Author, m: machines.Definition, input: Id) Error!Id {
    return field(e, try m.field(e, input, .header), machines.Header, "roots");
}
pub fn withRoots(e: Author, input: Id, changed: Id) Error!Id {
    return e.replace(input, @backingInt(machines.Field.header), try e.replace(try e.field(
        input,
        @backingInt(machines.Field.header),
    ), machines.index(machines.Header, "roots"), changed));
}
fn node(e: Author, m: machines.Definition, record: Id, frame: ?Id) Error!Id {
    const optional = e.b.schemas.items[@intCast(m.nodes.element)].product[1];
    return e.tuple(m.nodes.element, &.{ record, try e.variant(
        optional,
        if (frame != null) 1 else 0,
        frame orelse e.unit_value,
    ) });
}
fn reference(e: Author, id: Id) Error!Id {
    return e.tuple(try projection.schema(g.NodeRef, e.b), &.{id});
}
fn optionalRef(e: Author, ref: ?Id) Error!Id {
    return e.variant(
        try projection.schema(?g.NodeRef, e.b),
        if (ref != null) 1 else 0,
        ref orelse e.unit_value,
    );
}
fn changedNodes(e: Author, input: Id, table: Id) Error!Id {
    return e.replace(input, @backingInt(machines.Field.nodes), table);
}

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.control/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const edge = try edges.define(b, m);
    const aggregate = try @import("aggregate.zig").define(b, m);
    const graph = try @import("graph.zig").define(b, m);
    const ref_type = try projection.schema(g.NodeRef, b);
    const maybe_ref = try projection.schema(?g.NodeRef, b);
    const value = try projection.schema(g.Value, b);
    const maybe_value = try projection.schema(?g.Value, b);
    const control_type = try projection.schema(g.Control, b);
    const edge_type = try projection.schema(ir.Edge, b);
    const node_type = try projection.schema(g.Node, b);
    const d: Definition = try defineD(
        m,
        e,
        ref_type,
        maybe_ref,
        value,
        maybe_value,
        control_type,
        edge_type,
    );
    const handlers = try @import("handlers.zig").define(b, m, .{
        .enter = d.enter,
        .apply = d.apply,
        .capture = d.capture,
        .resume_continuation = d.resume_continuation,
    });
    try emitApply(m, e, graph, ref_type, node_type, d);
    try emitJump(m, e, edge, node_type, d);
    try emitCapture(m, e, edge, node_type, d);
    try emitEnter(m, e, edge, ref_type, control_type, node_type, d);
    try emitResumeContinuation(m, e, edge, maybe_value, control_type, edge_type, d);
    try emitReturnTo(m, e, graph, ref_type, node_type, d);
    try emitExecute(m, e, edge, aggregate, graph, value, maybe_value, d, handlers);
    try @import("unwind.zig").emit(b, m, d.unwind, d);
    return cache.finish(b, d);
}

fn emitApply(
    m: machines.Definition,
    e: Author,
    graph: anytype,
    ref_type: Id,
    node_type: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.apply, 0);
    const ref = try e.b.variable(ref_type);
    const closure = try e.b.variable(node_type);
    const environment = try e.b.variable(node_type);
    const closure_data = try e.payload(
        try e.b.reference(closure),
        @backingInt(g.NodeTag.computation),
    );
    const constructors = try field(
        e,
        try edges.code(e, try m.field(e, input, .program)),
        ir.Program,
        "constructors",
    );
    const constructor = try e.required(constructors, try e.field(closure_data, 0));
    const captured = try e.field(try e.payload(
        try e.b.reference(environment),
        @backingInt(g.NodeTag.environment),
    ), 0);
    const arguments = try e.b.primitive(
        try projection.schema([]const g.Value, e.b),
        .sequence_concat,
        &.{ captured, try e.param(d.apply, 2) },
        0,
    );
    try e.b.define(d.apply, try e.b.bind(ref, try e.call(
        graph.value_ref,
        &.{try e.param(d.apply, 1)},
    ), try e.b.bind(closure, try e.call(
        graph.record,
        &.{ input, try e.b.reference(ref) },
    ), try e.b.bind(environment, try e.call(graph.record, &.{
        input, try e.field(closure_data, 1),
    }), try e.call(d.enter, &.{ input, try field(
        e,
        constructor,
        data.program.Constructor,
        "function",
    ), arguments, try e.param(d.apply, 3), try e.param(d.apply, 4), try e.param(d.apply, 5) })))));
}

fn emitJump(
    m: machines.Definition,
    e: Author,
    edge: edges.Definition,
    node_type: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.jump, 0);
    const current = try e.param(d.jump, 1);
    const control = try e.param(d.jump, 2);
    const transfer = try e.param(d.jump, 4);
    const frame = try e.b.variable(m.frames.schema);
    const table = try e.b.variable(m.nodes.table);
    const record = try e.variant(node_type, @backingInt(g.NodeTag.control), try e.replace(
        control,
        0,
        try e.field(transfer, 0),
    ));
    try e.b.define(d.jump, try e.b.bind(frame, try e.call(edge.assign, &.{
        try m.field(e, input, .program),
        try e.param(d.jump, 3),
        transfer,
        try e.param(d.jump, 5),
    }), try e.b.bind(
        table,
        try e.call(
            m.nodes.set,
            &.{
                try m.field(e, input, .nodes),
                try e.field(current, 0),
                try node(e, m, record, try e.b.reference(frame)),
            },
        ),
        try e.b.pure(try changedNodes(e, input, try e.b.reference(table))),
    )));
}

fn emitCapture(
    m: machines.Definition,
    e: Author,
    edge: edges.Definition,
    node_type: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.capture, 0);
    const current = try e.param(d.capture, 1);
    const control = try e.param(d.capture, 2);
    const mask = try e.b.variable((try @import("sets.zig").define(e.b)).map.tree);
    const frame = try e.b.variable(m.frames.schema);
    const table = try e.b.variable(m.nodes.table);
    const saved = try e.tuple(try projection.schema(g.Continuation, e.b), &.{
        try e.field(control, 0),
        try e.field(control, 1),
        try e.field(control, 2),
        try e.field(control, 3),
    });
    const record = try e.variant(node_type, @backingInt(g.NodeTag.continuation), saved);
    try e.b.define(d.capture, try e.b.bind(mask, try e.call(edge.retained, &.{
        try m.field(e, input, .program), try e.param(d.capture, 4),
    }), try e.b.bind(frame, try e.call(m.frames.retain, &.{
        try e.param(d.capture, 3), try e.b.reference(mask),
    }), try e.b.bind(
        table,
        try e.call(
            m.nodes.set,
            &.{
                try m.field(e, input, .nodes),
                try e.field(current, 0),
                try node(e, m, record, try e.b.reference(frame)),
            },
        ),
        try e.b.pure(try changedNodes(e, input, try e.b.reference(table))),
    ))));
}

fn emitEnter(
    m: machines.Definition,
    e: Author,
    edge: edges.Definition,
    ref_type: Id,
    control_type: Id,
    node_type: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.enter, 0);
    const program = try m.field(e, input, .program);
    const fn_code = try edges.function(e, program, try e.param(d.enter, 1));
    const entry = try field(e, fn_code, ir.Function, "entry");
    const parent = try e.param(d.enter, 3);
    const evidence = try e.param(d.enter, 4);
    const region = try e.param(d.enter, 5);
    const frame = try e.b.variable(m.frames.schema);
    const pruned = try e.b.variable(m.frames.schema);
    const chosen = try e.b.variable(e.integer);
    const table = try e.b.variable(m.nodes.table);
    const prior = try m.field(e, input, .nodes);
    const record = try e.variant(node_type, @backingInt(g.NodeTag.control), try e.tuple(
        control_type,
        &.{ entry, parent, evidence, region },
    ));
    const replacement = try node(e, m, record, try e.b.reference(pruned));
    const count = try e.field(prior, 0);
    const id = try e.b.reference(chosen);
    const append = try e.call(m.nodes.append, &.{ prior, replacement });
    const replace = try e.call(m.nodes.set, &.{ prior, id, replacement });
    const save = try saveEnteredControl(m, e, input, id, evidence, table, count, append, replace);
    const absent = try e.b.variable(e.unit);
    const present = try e.b.variable(ref_type);
    const found = try e.b.variable(m.nodes.optional);
    const current = try e.b.reference(present);
    const record_tag = try e.b.primitive(e.integer, .variant_tag, &.{try e.field(
        try e.payload(try e.b.reference(found), 1),
        0,
    )}, 0);
    const select = try emitEnterSelect(
        m,
        e,
        input,
        prior,
        count,
        absent,
        present,
        found,
        current,
        record_tag,
    );
    const empty_frame = try e.tuple(
        m.frames.schema,
        &.{
            e.zero,                      e.zero,
            try m.frames.slots.empty(e), try e.literal([]const data.process_state.Owner, &.{}),
        },
    );
    try e.b.define(d.enter, try e.b.bind(frame, try e.call(edge.write, &.{
        empty_frame, try field(e, fn_code, ir.Function, "inputs"), try e.param(d.enter, 2),
    }), try e.b.bind(pruned, try e.call(m.frames.prune, &.{
        try e.b.reference(frame), try edges.live(e, program, entry),
    }), try e.b.bind(chosen, select, save))));
}

fn emitResumeContinuation(
    m: machines.Definition,
    e: Author,
    edge: edges.Definition,
    maybe_value: Id,
    control_type: Id,
    edge_type: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.resume_continuation, 0);
    const current = try e.param(d.resume_continuation, 1);
    const found = try e.b.variable(m.nodes.optional);
    const saved_node = try e.payload(try e.b.reference(found), 1);
    const saved = try e.payload(
        try e.field(saved_node, 0),
        @backingInt(g.NodeTag.continuation),
    );
    const frame = try e.payload(try e.field(saved_node, 1), 1);
    const transfer = try e.b.variable(edge_type);
    const next = try e.b.reference(transfer);
    const control = try emitResumeContinuationControl(e, control_type, saved, next);
    const changed = try e.b.variable(m.schema);
    var new_roots = try roots(e, m, input);
    new_roots = try e.replace(
        new_roots,
        machines.index(g.Roots, "current"),
        try optionalRef(e, current),
    );
    new_roots = try e.replace(
        new_roots,
        machines.index(g.Roots, "evidence"),
        try e.field(saved, 2),
    );
    const target = try edges.block(e, try m.field(e, input, .program), try e.field(saved, 0));
    try e.b.define(d.resume_continuation, try e.b.bind(found, try e.call(m.nodes.get, &.{
        try m.field(e, input, .nodes), try e.field(current, 0),
    }), try e.b.bind(transfer, try e.call(edge.next, &.{
        try field(e, target, ir.Block, "terminator"),
    }), try e.b.bind(
        changed,
        try e.call(
            d.jump,
            &.{
                input,
                current,
                control,
                frame,
                next,
                try e.variant(maybe_value, 1, try e.param(d.resume_continuation, 2)),
            },
        ),
        try e.b.pure(try withRoots(
            e,
            try e.b.reference(changed),
            new_roots,
        )),
    ))));
}

fn defineD(
    m: machines.Definition,
    e: Author,
    ref_type: Id,
    maybe_ref: Id,
    value: Id,
    maybe_value: Id,
    control_type: Id,
    edge_type: Id,
) Error!Definition {
    return .{
        .unwind = try @import("unwind.zig").declare(e.b, m),
        .execute = try e.b.declare(&.{m.schema}, m.schema, &.{}, &.{}),
        .jump = try e.b.declare(&.{
            m.schema, ref_type, control_type, m.frames.schema, edge_type, maybe_value,
        }, m.schema, &.{}, &.{}),
        .capture = try e.b.declare(&.{
            m.schema, ref_type, control_type, m.frames.schema, edge_type,
        }, m.schema, &.{}, &.{}),
        .enter = try e.b.declare(&.{
            m.schema,                                    e.integer,
            try projection.schema([]const g.Value, e.b), maybe_ref,
            maybe_ref,                                   maybe_ref,
        }, m.schema, &.{}, &.{}),
        .apply = try e.b.declare(&.{
            m.schema,                                    value,
            try projection.schema([]const g.Value, e.b), maybe_ref,
            maybe_ref,                                   maybe_ref,
        }, m.schema, &.{}, &.{}),
        .resume_continuation = try e.b.declare(
            &.{ m.schema, ref_type, value },
            m.schema,
            &.{},
            &.{},
        ),
        .return_to = try e.b.declare(&.{ m.schema, maybe_ref, value }, m.schema, &.{}, &.{}),
    };
}

fn defineArguments(e: Author, returned: Id, definition: Id) Error!Id {
    return try e.b.primitive(
        try projection.schema([]const g.Value, e.b),
        .sequence_concat,
        &.{
            try e.field(definition, 1),
            try e.b.primitive(
                try projection.schema([]const g.Value, e.b),
                .sequence,
                &.{returned},
                0,
            ),
        },
        0,
    );
}

fn defineEnter(
    e: Author,
    graph: anytype,
    d: Definition,
    input: Id,
    attachment: Id,
    handler: Id,
    definition: Id,
    handler_code: Id,
    arguments: Id,
) Error!Id {
    return try e.b.bind(handler, try e.call(graph.record, &.{
        input, try e.field(attachment, 0),
    }), try e.call(d.enter, &.{
        input,
        try field(e, handler_code, ir.Handler, "return_function"),
        arguments,
        try e.field(attachment, 2),
        try e.field(definition, 2),
        try e.field(definition, 3),
    }));
}

fn defineFinish(
    m: machines.Definition,
    e: Author,
    node_type: Id,
    exit_record: Id,
    table: Id,
    old: anytype,
    completed: anytype,
) Error!Id {
    return try e.b.bind(
        table,
        try e.call(
            m.nodes.append,
            &.{
                old,
                try node(
                    e,
                    m,
                    try e.variant(node_type, @backingInt(g.NodeTag.exit), exit_record),
                    null,
                ),
            },
        ),
        try e.b.pure(completed),
    );
}

fn defineChoose(
    e: Author,
    maybe_value: Id,
    d: Definition,
    input: Id,
    current: Id,
    control: Id,
    frame: Id,
    operation: Id,
    T: anytype,
    condition_bytes: Id,
) Error!Id {
    return try e.when(try e.binary(
        .equal,
        try e.required(condition_bytes, e.zero),
        try e.b.constant(u8, 1),
    ), try e.call(d.jump, &.{
        input,
        current,
        control,
        frame,
        try field(e, operation, T, "when_true"),
        try e.variant(maybe_value, 0, e.unit_value),
    }), try e.call(d.jump, &.{
        input,
        current,
        control,
        frame,
        try field(e, operation, T, "when_false"),
        try e.variant(maybe_value, 0, e.unit_value),
    }));
}

fn defineTailCall(
    e: Author,
    input: Id,
    arguments: Id,
    control: Id,
    function_id: anytype,
    invoke: anytype,
) Error!Id {
    return try e.call(invoke, &.{
        input,                        function_id,
        try e.b.reference(arguments), try e.field(control, 1),
        try e.field(control, 2),      try e.field(control, 3),
    });
}

fn defineCall(
    e: Author,
    d: Definition,
    input: Id,
    current: Id,
    arguments: Id,
    control: Id,
    frame: Id,
    captured: Id,
    next: Id,
    function_id: anytype,
    invoke: anytype,
) Error!Id {
    return try e.b.bind(captured, try e.call(d.capture, &.{
        input, current, control, frame, next,
    }), try e.call(invoke, &.{
        try e.b.reference(captured),
        function_id,
        try e.b.reference(arguments),
        try optionalRef(e, current),
        try e.field(control, 2),
        try e.field(control, 3),
    }));
}

fn defineFollow(
    e: Author,
    d: Definition,
    control: Id,
    body_value: Id,
    wrapper: Id,
    region_ref: Id,
    supplied: Id,
) Error!Id {
    return try e.call(
        d.apply,
        &.{
            try e.field(try e.b.reference(wrapper), 0),
            try e.b.reference(body_value),
            supplied,
            try optionalRef(e, try e.field(try e.b.reference(wrapper), 1)),
            try e.field(control, 2),
            try optionalRef(e, region_ref),
        },
    );
}

fn defineRegionRecord(e: Author, control: Id, operation: Id, T: anytype, graphs: anytype) Error!Id {
    return try graphs.record(e, .region, &.{
        try field(e, operation, T, "region"),
        try e.field(control, 3),
        try e.literal([]const g.OwnedRef, &.{}),
    });
}

fn emitEnterSelect(
    m: machines.Definition,
    e: Author,
    input: Id,
    prior: anytype,
    count: Id,
    absent: Id,
    present: Id,
    found: Id,
    current: Id,
    record_tag: Id,
) Error!Id {
    return try e.b.term(.{ .match_sum = .{ .value = try field(
        e,
        try roots(e, m, input),
        g.Roots,
        "current",
    ), .cases = &.{
        .{ .variable = absent, .body = try e.b.pure(count) },
        .{ .variable = present, .body = try e.b.bind(found, try e.call(
            m.nodes.get,
            &.{ prior, try e.field(current, 0) },
        ), try e.when(
            try e.binary(.equal, record_tag, e.zero),
            try e.b.pure(try e.field(current, 0)),
            try e.b.pure(count),
        )) },
    } } });
}

fn emitResumeContinuationControl(e: Author, control_type: Id, saved: Id, next: Id) Error!Id {
    return try e.tuple(control_type, &.{
        try e.field(next, 0),
        try e.field(saved, 1),
        try e.field(saved, 2),
        try e.field(saved, 3),
    });
}

fn emitReturnTo(
    m: machines.Definition,
    e: Author,
    graph: anytype,
    ref_type: Id,
    node_type: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.return_to, 0);
    const returned = try e.param(d.return_to, 2);
    const absent = try e.b.variable(e.unit);
    const present = try e.b.variable(ref_type);
    const current = try e.b.reference(present);
    const found = try e.b.variable(m.nodes.optional);
    const saved = try e.field(try e.payload(try e.b.reference(found), 1), 0);
    const tag = try e.b.primitive(e.integer, .variant_tag, &.{saved}, 0);
    var dispatch = try e.fail();
    dispatch = try returnToAttachment(
        m,
        e,
        graph,
        node_type,
        d,
        input,
        saved,
        returned,
        tag,
        dispatch,
    );
    dispatch = try returnToCleanup(e, d, input, saved, current, returned, tag, dispatch);
    dispatch = try emitReturnToContinuation(
        m,
        e,
        d,
        input,
        returned,
        current,
        saved,
        tag,
        dispatch,
    );
    dispatch = try e.when(try e.binary(.equal, tag, try e.b.constant(
        u64,
        @backingInt(g.NodeTag.injection),
    )), try e.call(d.resume_continuation, &.{ input, try e.field(try e.payload(
        saved,
        @backingInt(g.NodeTag.injection),
    ), 0), returned }), dispatch);
    dispatch = try e.when(try e.binary(.equal, tag, try e.b.constant(
        u64,
        @backingInt(g.NodeTag.region_scope),
    )), try e.call(d.return_to, &.{ input, try e.field(try e.payload(
        saved,
        @backingInt(g.NodeTag.region_scope),
    ), 2), returned }), dispatch);
    const terminal = try rootReturn(m, e, node_type, input, returned);
    try emitReturnToReturnToDefinition(
        m,
        e,
        d,
        absent,
        present,
        current,
        found,
        dispatch,
        terminal.old,
        terminal.finish,
    );
}

fn rootReturn(
    m: machines.Definition,
    e: Author,
    node_type: Id,
    input: Id,
    returned: Id,
) Error!struct { old: Id, finish: Id } {
    const exit_schema = try projection.schema(g.Exit, e.b);
    const reason_type = e.b.schemas.items[@intCast(exit_schema)].product[0];
    const exit_record = try e.replace(
        try e.literal(g.Exit, .{ .reason = .abandoned }),
        0,
        try e.variant(reason_type, 0, returned),
    );
    const table = try e.b.variable(m.nodes.table);
    const old = try m.field(e, input, .nodes);
    const ref = try reference(e, try e.field(old, 0));
    const new_roots = try e.replace(
        try e.literal(g.Roots, .{}),
        machines.index(g.Roots, "exit"),
        try optionalRef(e, ref),
    );
    var completed = try withRoots(
        e,
        try changedNodes(e, input, try e.b.reference(table)),
        new_roots,
    );
    completed = try e.replace(
        completed,
        @backingInt(machines.Field.header),
        try e.replace(
            try m.field(e, completed, .header),
            machines.index(machines.Header, "status"),
            try e.literal(data.process_state.Status, .completed),
        ),
    );
    const finish = try defineFinish(m, e, node_type, exit_record, table, old, completed);
    return .{ .old = old, .finish = finish };
}

fn emitReturnToReturnToDefinition(
    m: machines.Definition,
    e: Author,
    d: Definition,
    absent: Id,
    present: Id,
    current: Id,
    found: Id,
    dispatch: Id,
    old: anytype,
    finish: anytype,
) Error!void {
    try e.b.define(
        d.return_to,
        try e.b.term(
            .{
                .match_sum = .{
                    .value = try e.param(d.return_to, 1),
                    .cases = &.{
                        .{ .variable = absent, .body = finish },
                        .{ .variable = present, .body = try e.b.bind(found, try e.call(
                            m.nodes.get,
                            &.{ old, try e.field(current, 0) },
                        ), dispatch) },
                    },
                },
            },
        ),
    );
}

fn emitReturnToContinuation(
    m: machines.Definition,
    e: Author,
    d: Definition,
    input: Id,
    returned: Id,
    current: Id,
    saved: Id,
    tag: Id,
    dispatch: Id,
) Error!Id {
    return try e.when(try e.binary(.equal, tag, try e.b.constant(
        u64,
        @backingInt(g.NodeTag.continuation),
    )), try e.when(
        try @import("unwind.zig").is(e, try e.field(returned, 1), 3),
        try e.when(
            try @import("unwind.zig").is(
                e,
                try field(
                    e,
                    try edges.block(
                        e,
                        try m.field(e, input, .program),
                        try e.field(
                            try e.payload(saved, @backingInt(g.NodeTag.continuation)),
                            0,
                        ),
                    ),
                    ir.Block,
                    "terminator",
                ),
                machines.index(ir.Terminator, "dispose"),
            ),
            try e.call(
                d.unwind.begin,
                &.{
                    input,
                    try e.literal(@FieldType(g.Exit, "reason"), .abandoned),
                    try optionalRef(e, current),
                    try optionalRef(e, current),
                    try @import("unwind.zig").seq(e, &.{
                        returned,
                    }),
                },
            ),
            try e.call(d.resume_continuation, &.{ input, current, returned }),
        ),
        try e.call(d.resume_continuation, &.{ input, current, returned }),
    ), dispatch);
}

fn emitExecute(
    m: machines.Definition,
    e: Author,
    edge: anytype,
    aggregate: anytype,
    graph: anytype,
    value: Id,
    maybe_value: Id,
    d: Definition,
    handlers: anytype,
) Error!void {
    const input = try e.param(d.execute, 0);
    const current = try e.payload(try field(e, try roots(e, m, input), g.Roots, "current"), 1);
    const found = try e.b.variable(m.nodes.optional);
    const selected = try e.payload(try e.b.reference(found), 1);
    const control = try e.payload(try e.field(selected, 0), 0);
    const frame = try e.payload(try e.field(selected, 1), 1);
    const program = try m.field(e, input, .program);
    const target = try edges.block(e, program, try e.field(control, 0));
    const term = try field(e, target, ir.Block, "terminator");
    const term_type = try projection.schema(ir.Terminator, e.b);
    const variants = e.b.schemas.items[@intCast(term_type)].sum;
    const info = @typeInfo(ir.Terminator).@"union";
    const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
    var cases: [info.field_names.len]Case = undefined;
    inline for (info.field_names, 0..) |name, i| {
        const variable = try e.b.variable(variants[i]);
        const operation = try e.b.reference(variable);
        const T = @FieldType(ir.Terminator, name);
        const tag: data.program.TerminatorTag = @field(data.program.TerminatorTag, name);
        const body = try executeTerminator(.{
            .m = m,
            .e = e,
            .edge = edge,
            .aggregate = aggregate,
            .graph = graph,
            .value = value,
            .maybe_value = maybe_value,
            .d = d,
            .handlers = handlers,
            .input = input,
            .current = current,
            .control = control,
            .frame = frame,
            .program = program,
            .term = term,
        }, operation, T, tag);
        cases[i] = .{ .variable = variable, .body = body };
    }
    try e.b.define(d.execute, try e.b.bind(found, try e.call(m.nodes.get, &.{
        try m.field(e, input, .nodes), try e.field(current, 0),
    }), try e.b.term(.{
        .match_sum = .{ .value = term, .cases = &cases },
    })));
}

fn emitExecuteJump(
    c: Execution,
    operation: Id,
    comptime tag: anytype,
) Error!Id {
    const m = c.m;
    const e = c.e;
    const maybe_value = c.maybe_value;
    const d = c.d;
    const input = c.input;
    const current = c.current;
    const control = c.control;
    const frame = c.frame;
    const jump = try e.call(d.jump, &.{
        input,                                       current, control, frame, operation,
        try e.variant(maybe_value, 0, e.unit_value),
    });
    if (tag == .jump) return jump;
    const changed = try e.b.variable(m.schema);
    return try e.b.bind(
        changed,
        jump,
        try e.b.pure(
            try e.replace(
                try e.b.reference(changed),
                @backingInt(machines.Field.header),
                try e.replace(
                    try m.field(e, try e.b.reference(changed), .header),
                    machines.index(machines.Header, "status"),
                    try e.literal(data.process_state.Status, .yielded),
                ),
            ),
        ),
    );
}

fn emitExecuteBranch(
    c: Execution,
    operation: Id,
    comptime T: type,
) Error!Id {
    const m = c.m;
    const e = c.e;
    const value = c.value;
    const maybe_value = c.maybe_value;
    const d = c.d;
    const input = c.input;
    const current = c.current;
    const control = c.control;
    const frame = c.frame;
    const condition = try e.b.variable(value);
    const condition_bytes = try e.payload(try e.field(try e.b.reference(condition), 1), 0);
    const choose = try defineChoose(
        e,
        maybe_value,
        d,
        input,
        current,
        control,
        frame,
        operation,
        T,
        condition_bytes,
    );
    return try e.b.bind(condition, try e.call(m.frames.read, &.{
        frame, try field(e, operation, T, "condition"),
    }), choose);
}

fn emitExecuteCall(
    c: Execution,
    operation: Id,
    comptime T: type,
    comptime tag: anytype,
) Error!Id {
    const m = c.m;
    const e = c.e;
    const edge = c.edge;
    const value = c.value;
    const d = c.d;
    const input = c.input;
    const current = c.current;
    const control = c.control;
    const frame = c.frame;
    const program = c.program;
    const arguments = try e.b.variable(try projection.schema([]const g.Value, e.b));
    const computation = try e.b.variable(value);
    const tail = try e.b.variable(e.boolean);
    const captured = try e.b.variable(m.schema);
    const next = try field(e, operation, T, "next");
    const function_id = if (tag == .call) try field(
        e,
        operation,
        T,
        "function",
    ) else try e.b.reference(computation);
    const invoke = if (tag == .call) d.enter else d.apply;
    const tail_call = try defineTailCall(e, input, arguments, control, function_id, invoke);
    const call = try defineCall(
        e,
        d,
        input,
        current,
        arguments,
        control,
        frame,
        captured,
        next,
        function_id,
        invoke,
    );
    const invoke_term = try e.b.bind(arguments, try e.call(edge.collect, &.{
        frame, try field(e, operation, T, "arguments"),
    }), try e.b.bind(tail, try e.call(edge.tail, &.{ program, next }), try e.when(
        try e.b.reference(tail),
        tail_call,
        call,
    )));
    return if (tag == .call) invoke_term else try e.b.bind(
        computation,
        try e.call(m.frames.read, &.{ frame, try field(e, operation, T, "computation") }),
        invoke_term,
    );
}

fn emitExecuteWithRegion(
    c: Execution,
    operation: Id,
    comptime T: type,
) Error!Id {
    const m = c.m;
    const e = c.e;
    const edge = c.edge;
    const graph = c.graph;
    const value = c.value;
    const d = c.d;
    const input = c.input;
    const current = c.current;
    const control = c.control;
    const frame = c.frame;
    const program = c.program;
    const graphs = @import("graph.zig");
    const region = try e.b.variable(graph.appended);
    const body_value = try e.b.variable(value);
    const arguments = try e.b.variable(try projection.schema([]const g.Value, e.b));
    const captured = try e.b.variable(m.schema);
    const wrapper_parameter = try emitExecuteWithRegionWrapperParameter(
        e,
        graph,
        program,
        region,
        body_value,
    );
    const wrapper = wrapper_parameter.wrapper;
    const region_ref = wrapper_parameter.region_ref;
    const parameter = wrapper_parameter.parameter;
    const region_value = try graphs.value(e, parameter, region_ref, false);
    const prefix = try e.b.primitive(
        try projection.schema([]const g.Value, e.b),
        .sequence,
        &.{region_value},
        0,
    );
    const supplied = try e.b.primitive(
        try projection.schema([]const g.Value, e.b),
        .sequence_concat,
        &.{ prefix, try e.b.reference(arguments) },
        0,
    );
    const scope_record = try graphs.record(e, .region_scope, &.{
        try e.field(control, 0), region_ref, try optionalRef(e, current),
    });
    var follow = try defineFollow(e, d, control, body_value, wrapper, region_ref, supplied);
    follow = try e.b.bind(wrapper, try e.call(graph.append, &.{
        try e.b.reference(captured), scope_record,
    }), follow);
    follow = try e.b.bind(captured, try e.call(d.capture, &.{
        try e.field(try e.b.reference(region), 0),
        current,
        control,
        frame,
        try field(e, operation, T, "next"),
    }), follow);
    follow = try e.b.bind(arguments, try e.call(edge.collect, &.{
        frame, try field(e, operation, T, "arguments"),
    }), follow);
    follow = try e.b.bind(body_value, try e.call(m.frames.read, &.{
        frame, try field(e, operation, T, "body"),
    }), follow);
    const region_record = try defineRegionRecord(e, control, operation, T, graphs);
    return try e.b.bind(region, try e.call(graph.append, &.{ input, region_record }), follow);
}

fn emitExecuteSwitchVariant(
    c: Execution,
    operation: Id,
    comptime T: type,
    comptime tag: anytype,
) Error!Id {
    const m = c.m;
    const e = c.e;
    const edge = c.edge;
    const aggregate = c.aggregate;
    const value = c.value;
    const maybe_value = c.maybe_value;
    const d = c.d;
    const input = c.input;
    const current = c.current;
    const control = c.control;
    const frame = c.frame;
    const program = c.program;
    const aggregate_value = try e.b.variable(value);
    const split = try e.b.variable(aggregate.split_result);
    const changed = try e.field(try e.b.reference(split), 0);
    const parts = try e.field(try e.b.reference(split), 1);
    const source_slot = try field(e, operation, T, "value");
    const cleared = try e.b.variable(m.frames.schema);
    const clear = try clearAggregateSource(c, aggregate_value, source_slot);
    var follow: Id = undefined;
    if (tag == .switch_variant) {
        follow = try switchVariantTransfer(
            e,
            maybe_value,
            d,
            current,
            control,
            operation,
            T,
            parts,
            changed,
            cleared,
        );
    } else {
        follow = try unpackProductTransfer(
            m,
            e,
            edge,
            maybe_value,
            d,
            current,
            control,
            program,
            operation,
            T,
            parts,
            changed,
            cleared,
        );
    }
    return try e.b.bind(aggregate_value, try e.call(
        m.frames.read,
        &.{ frame, source_slot },
    ), try e.b.bind(split, try e.call(aggregate.split, &.{
        input, try e.b.reference(aggregate_value),
    }), try e.b.bind(cleared, clear, follow)));
}

fn clearAggregateSource(c: Execution, aggregate_value: Id, source_slot: Id) Error!Id {
    const e = c.e;
    const m = c.m;
    const program = c.program;
    const frame = c.frame;
    const copy = try e.required(try field(e, try field(
        e,
        program,
        projection.Program,
        "uses",
    ), data.traits.Facts, "copy"), try e.field(
        try e.b.reference(aggregate_value),
        0,
    ));
    return e.when(copy, try e.b.pure(frame), try e.call(
        m.frames.clear,
        &.{ frame, source_slot },
    ));
}

fn switchVariantTransfer(
    e: Author,
    maybe_value: Id,
    d: Definition,
    current: Id,
    control: Id,
    operation: Id,
    comptime T: type,
    parts: Id,
    changed: Id,
    cleared: Id,
) Error!Id {
    const transfer = try e.required(
        try field(e, operation, T, "cases"),
        try e.field(parts, 0),
    );
    return e.call(
        d.jump,
        &.{
            changed,                    current,  control,
            try e.b.reference(cleared), transfer,
            try e.variant(
                maybe_value,
                1,
                try e.required(try e.field(parts, 1), e.zero),
            ),
        },
    );
}

fn emitExecuteWithRegionWrapperParameter(
    e: Author,
    graph: anytype,
    program: anytype,
    region: anytype,
    body_value: anytype,
) Error!struct { wrapper: Id, region_ref: Id, parameter: Id } {
    const wrapper = try e.b.variable(graph.appended);
    const region_ref = try e.field(try e.b.reference(region), 1);
    const shape = try e.required(try field(
        e,
        try edges.code(e, program),
        ir.Program,
        "schemas",
    ), try e.field(try e.b.reference(body_value), 0));
    const computation = try e.payload(try e.payload(
        shape,
        @backingInt(data.program.SchemaTag.internal),
    ), @backingInt(data.program.InternalTag.computation));
    const parameter = try e.required(try field(
        e,
        computation,
        data.program.ComputationType,
        "parameters",
    ), e.zero);
    return .{ .wrapper = wrapper, .region_ref = region_ref, .parameter = parameter };
}

fn saveEnteredControl(
    m: machines.Definition,
    e: Author,
    input: Id,
    id: Id,
    evidence: Id,
    table: Id,
    count: Id,
    append: Id,
    replace: Id,
) Error!Id {
    var new_roots = try roots(e, m, input);
    new_roots = try e.replace(
        new_roots,
        machines.index(g.Roots, "current"),
        try optionalRef(e, try reference(e, id)),
    );
    new_roots = try e.replace(new_roots, machines.index(g.Roots, "evidence"), evidence);
    const changed = try withRoots(
        e,
        try changedNodes(e, input, try e.b.reference(table)),
        new_roots,
    );
    const save = try e.b.bind(table, try e.when(
        try e.binary(.equal, id, count),
        append,
        replace,
    ), try e.b.pure(changed));
    return save;
}

fn returnToAttachment(
    m: machines.Definition,
    e: Author,
    graph: anytype,
    node_type: Id,
    d: Definition,
    input: Id,
    saved: Id,
    returned: Id,
    tag: Id,
    dispatch: Id,
) Error!Id {
    var dispatch_result = dispatch;
    {
        const attachment = try e.payload(saved, @backingInt(g.NodeTag.attachment));
        const handler = try e.b.variable(node_type);
        const definition = try e.payload(
            try e.b.reference(handler),
            @backingInt(g.NodeTag.handler),
        );
        const catalog = try field(
            e,
            try edges.code(e, try m.field(e, input, .program)),
            ir.Program,
            "handlers",
        );
        const handler_code = try e.required(catalog, try e.field(definition, 0));
        const arguments = try defineArguments(e, returned, definition);
        const enter = try defineEnter(
            e,
            graph,
            d,
            input,
            attachment,
            handler,
            definition,
            handler_code,
            arguments,
        );
        const phase = try e.b.primitive(
            try e.b.scalar(u32),
            .enum_tag,
            &.{try e.field(attachment, 3)},
            0,
        );
        dispatch_result = try e.when(try e.binary(.equal, tag, try e.b.constant(
            u64,
            @backingInt(g.NodeTag.attachment),
        )), try e.when(try e.binary(
            .equal,
            phase,
            try e.b.constant(u32, 0),
        ), enter, try e.fail()), dispatch_result);
    }
    return dispatch_result;
}

fn returnToCleanup(
    e: Author,
    d: Definition,
    input: Id,
    saved: Id,
    current: Id,
    returned: Id,
    tag: Id,
    dispatch: Id,
) Error!Id {
    var dispatch_result = dispatch;
    const protection = try e.payload(saved, @backingInt(g.NodeTag.protection));
    dispatch_result = try e.when(try e.binary(.equal, tag, try e.b.constant(
        u64,
        @backingInt(g.NodeTag.protection),
    )), try e.call(d.unwind.begin, &.{ input, try e.variant(
        try projection.schema(@FieldType(g.Exit, "reason"), e.b),
        0,
        returned,
    ), try optionalRef(e, current), try e.field(protection, 2), try e.literal(
        []const g.Value,
        &.{},
    ) }), dispatch_result);
    dispatch_result = try e.when(try e.binary(.equal, tag, try e.b.constant(
        u64,
        @backingInt(g.NodeTag.cleanup_return),
    )), try e.call(d.unwind.cleanup.returned, &.{ input, try e.payload(
        saved,
        @backingInt(g.NodeTag.cleanup_return),
    ) }), dispatch_result);
    dispatch_result = try e.when(try e.binary(.equal, tag, try e.b.constant(
        u64,
        @backingInt(g.NodeTag.disposal_return),
    )), try e.call(d.unwind.returned_disposal, &.{ input, try e.payload(
        saved,
        @backingInt(g.NodeTag.disposal_return),
    ), returned }), dispatch_result);
    return dispatch_result;
}

fn unpackProductTransfer(
    m: machines.Definition,
    e: Author,
    edge: anytype,
    maybe_value: Id,
    d: Definition,
    current: Id,
    control: Id,
    program: Id,
    operation: Id,
    comptime T: type,
    parts: Id,
    changed: Id,
    cleared: Id,
) Error!Id {
    const transfer = try field(e, operation, T, "next");
    const destination_block = try edges.block(e, program, try e.field(transfer, 0));
    const destination_function = try edges.function(e, program, try field(
        e,
        destination_block,
        ir.Block,
        "function",
    ));
    const scoped = try e.b.variable(m.frames.schema);
    const written = try e.b.variable(m.frames.schema);
    const follow = try e.b.bind(
        scoped,
        try e.call(
            m.frames.scope,
            &.{
                try e.b.reference(cleared),
                try field(e, destination_function, ir.Function, "custody"),
                try field(e, destination_block, ir.Block, "custody"),
            },
        ),
        try e.b.bind(written, try e.call(edge.write, &.{
            try e.b.reference(scoped),
            try field(e, operation, T, "destinations"),
            try e.field(parts, 1),
        }), try e.call(d.jump, &.{
            changed,                    current,  control,
            try e.b.reference(written), transfer, try e.variant(maybe_value, 0, e.unit_value),
        })),
    );
    return follow;
}

const Execution = struct {
    m: machines.Definition,
    e: Author,
    edge: edges.Definition,
    aggregate: @import("aggregate.zig").Definition,
    graph: @import("graph.zig").Definition,
    value: Id,
    maybe_value: Id,
    d: Definition,
    handlers: @import("handlers.zig").Definition,
    input: Id,
    current: Id,
    control: Id,
    frame: Id,
    program: Id,
    term: Id,
};

fn executeTerminator(
    c: Execution,
    operation: Id,
    comptime T: type,
    comptime tag: data.program.TerminatorTag,
) Error!Id {
    const e = c.e;
    return switch (tag) {
        .jump, .yield_value => emitExecuteJump(c, operation, tag),
        .branch => emitExecuteBranch(c, operation, T),
        .call, .apply => emitExecuteCall(c, operation, T, tag),
        .with_region => emitExecuteWithRegion(c, operation, T),
        .protect => e.call(c.d.unwind.cleanup.protect, &.{
            c.input, c.current, c.control, c.frame, operation,
        }),
        .dispose => e.call(c.d.unwind.dispose, &.{
            c.input, c.current, c.control, c.frame, operation,
        }),
        .fail => blk: {
            const failed_value = try e.b.variable(c.value);
            break :blk e.b.bind(failed_value, try e.call(
                c.m.frames.read,
                &.{ c.frame, operation },
            ), try e.call(c.d.unwind.fail_current, &.{ c.input, try e.b.reference(failed_value) }));
        },
        .handle => e.call(c.handlers.install, &.{
            c.input, c.current, c.control, c.frame, operation,
        }),
        .perform => e.call(c.handlers.perform, &.{
            c.input, c.current, c.control, c.frame, operation,
        }),
        .resume_value, .resume_with, .resume_computation => e.call(
            c.handlers.resume_control,
            &.{ c.input, c.current, c.control, c.frame, c.term },
        ),
        .return_value => blk: {
            const returned = try e.b.variable(c.value);
            break :blk e.b.bind(returned, try e.call(
                c.m.frames.read,
                &.{ c.frame, operation },
            ), try e.call(c.d.return_to, &.{
                c.input, try e.field(c.control, 1), try e.b.reference(returned),
            }));
        },
        .switch_variant, .unpack_product => emitExecuteSwitchVariant(c, operation, T, tag),
    };
}
