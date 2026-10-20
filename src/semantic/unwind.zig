//! Guest disposal and exit traversal, authored as ordinary Horos computation.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const graphs = @import("graph.zig");
const control = @import("control.zig");
const edges = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const Reason = @FieldType(g.Exit, "reason");
const field = edges.field;
pub const Definition = struct {
    position: Id,
    begin: Id,
    outermost: Id,
    discarded: Id,
    remember_failure: Id,
    fail_current: Id,
    dispose: Id,
    returned_disposal: Id,
    step: Id,
    cleanup: @import("cleanup.zig").Definition,
};
pub fn declare(b: *source.Builder, m: machines.Definition) Error!Definition {
    const ref = try projection.schema(g.NodeRef, b);
    const maybe = try projection.schema(?g.NodeRef, b);
    const values = try projection.schema([]const g.Value, b);
    return .{
        .cleanup = try @import("cleanup.zig").declare(b, m),
        .position = try b.declare(&.{ m.schema, maybe, values }, m.schema, &.{}, &.{}),
        .begin = try b.declare(&.{
            m.schema, try projection.schema(Reason, b), maybe, maybe, values,
        }, m.schema, &.{}, &.{}),
        .outermost = try b.declare(&.{ m.schema, ref }, ref, &.{}, &.{}),
        .discarded = try b.declare(&.{try projection.schema(g.Exit, b)}, values, &.{}, &.{}),
        .remember_failure = try b.declare(&.{
            m.schema, try projection.schema(g.Value, b),
        }, m.schema, &.{}, &.{}),
        .fail_current = try b.declare(&.{
            m.schema, try projection.schema(g.Value, b),
        }, m.schema, &.{}, &.{}),
        .dispose = try b.declare(
            &.{
                m.schema,                            ref,
                try projection.schema(g.Control, b), m.frames.schema,
                try projection.schema(@FieldType(
                    data.activation.Terminator,
                    "dispose",
                ), b),
            },
            m.schema,
            &.{},
            &.{},
        ),
        .returned_disposal = try b.declare(&.{ m.schema, try projection.schema(
            @FieldType(g.Node, "disposal_return"),
            b,
        ), try projection.schema(g.Value, b) }, m.schema, &.{}, &.{}),
        .step = try b.declare(&.{m.schema}, m.schema, &.{}, &.{}),
    };
}
pub fn tag(e: Author, value: Id) Error!Id {
    return e.b.primitive(e.integer, .variant_tag, &.{value}, 0);
}
pub fn is(e: Author, value: Id, n: u64) Error!Id {
    return e.binary(.equal, try tag(e, value), try e.b.constant(u64, n));
}
pub fn some(e: Author, ref: Id) Error!Id {
    return e.variant(try projection.schema(?g.NodeRef, e.b), 1, ref);
}
pub fn empty(e: Author) Error!Id {
    return e.literal([]const g.Value, &.{});
}
pub fn seq(e: Author, values: []const Id) Error!Id {
    return e.b.primitive(try projection.schema([]const g.Value, e.b), .sequence, values, 0);
}
pub fn concat(e: Author, a: Id, b: Id) Error!Id {
    return e.b.primitive(
        try projection.schema([]const g.Value, e.b),
        .sequence_concat,
        &.{ a, b },
        0,
    );
}
fn tailOf(e: Author, values: Id) Error!Id {
    const t = try projection.schema([]const g.Value, e.b);
    const pair = try e.b.schema(.{ .product = &.{ try projection.schema(g.Value, e.b), t } });
    const optional = try e.b.schema(.{ .sum = &.{ e.unit, pair } });
    return e.field(try e.payload(try e.b.primitive(optional, .sequence_pop, &.{values}, 0), 1), 1);
}
pub fn status(
    e: Author,
    m: machines.Definition,
    input: Id,
    value: data.process_state.Status,
) Error!Id {
    return e.replace(input, @backingInt(machines.Field.header), try e.replace(
        try m.field(e, input, .header),
        machines.index(machines.Header, "status"),
        try e.literal(data.process_state.Status, value),
    ));
}
pub fn root(
    e: Author,
    m: machines.Definition,
    input: Id,
    comptime name: []const u8,
    value: Id,
) Error!Id {
    return control.withRoots(e, input, try e.replace(
        try control.roots(e, m, input),
        machines.index(g.Roots, name),
        value,
    ));
}
pub fn emit(
    b: *source.Builder,
    m: machines.Definition,
    d: Definition,
    calls: control.Definition,
) Error!void {
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const captures = try @import("captures.zig").define(b, m);
    const node_type = try projection.schema(g.Node, b);
    const ref_type = try projection.schema(g.NodeRef, b);
    const values_type = try projection.schema([]const g.Value, b);
    const null_ref = try e.literal(?g.NodeRef, null);
    try emitPosition(m, d, e, graph, null_ref);
    try emitBegin(m, d, e, graph, node_type);
    try emitOutermost(d, e, graph, node_type);
    try emitDiscarded(d, e);
    try emitRememberFailure(m, d, e, graph, node_type, ref_type, values_type, null_ref);
    try emitFailCurrent(m, d, e, graph, values_type, null_ref);
    try emitDispose(m, d, calls, e, captures);
    try emitReturnedDisposal(d, e, values_type);
    // Flatten owned children in their original custody order.
    const owned = try b.declare(&.{values_type}, values_type, &.{}, &.{});
    try emitOwned(e, values_type, owned);
    try emitStep(m, d, calls, e, graph, captures, node_type, ref_type, values_type, owned);
    try @import("cleanup.zig").emit(b, m, d.cleanup, d, calls);
}

fn emitChanged(e: Author, exit: Id, value: Id) Error!Id {
    return try e.replace(
        exit,
        machines.index(g.Exit, "cleanup_failures"),
        try concat(e, try field(e, exit, g.Exit, "cleanup_failures"), try seq(e, &.{value})),
    );
}

fn emitChoose(e: Author, changed: anytype, exit: Id, failure: Id) Error!Id {
    return try e.when(
        try is(e, try e.field(exit, 0), 0),
        try e.b.pure(failure),
        try e.when(
            try is(e, try e.field(exit, 0), 3),
            try e.b.pure(failure),
            try e.b.pure(changed),
        ),
    );
}

fn emitBody(
    e: Author,
    graph: anytype,
    node_type: Id,
    input: Id,
    ref: Id,
    selected: Id,
    choose: Id,
) Error!Id {
    return try e.b.bind(
        selected,
        choose,
        try e.call(
            graph.replace,
            &.{
                input,
                try e.b.reference(ref),
                try e.variant(
                    node_type,
                    @backingInt(g.NodeTag.exit),
                    try e.b.reference(selected),
                ),
            },
        ),
    );
}

fn emitDrain(
    d: Definition,
    e: Author,
    graph: anytype,
    node_type: Id,
    input: Id,
    changed: anytype,
    discarded: Id,
    cursor: Id,
    current_values: Id,
    root_ref: Id,
    root_exit: Id,
) Error!Id {
    return try e.b.bind(
        changed,
        try e.call(
            graph.replace,
            &.{
                input,
                try e.b.reference(root_ref),
                try e.variant(
                    node_type,
                    @backingInt(g.NodeTag.exit),
                    try e.replace(root_exit, machines.index(g.Exit, "discarded"), try empty(e)),
                ),
            },
        ),
        try e.call(
            d.position,
            &.{ try e.b.reference(changed), cursor, try concat(e, discarded, current_values) },
        ),
    );
}

fn emitTerminalStatus(
    m: machines.Definition,
    e: Author,
    root_exit: Id,
    terminal_input: Id,
    terminal_roots: Id,
) Error!Id {
    return try e.when(
        try is(e, try e.field(root_exit, 0), 1),
        try e.b.pure(
            try status(e, m, try control.withRoots(e, terminal_input, terminal_roots), .failed),
        ),
        try e.b.pure(try status(
            e,
            m,
            try control.withRoots(e, terminal_input, terminal_roots),
            .cancelled,
        )),
    );
}

fn emitResumeSaved(
    calls: control.Definition,
    e: Author,
    exit: Id,
    cursor: Id,
    restored: anytype,
) Error!Id {
    return try e.when(
        try is(e, try e.field(exit, 0), 0),
        try e.call(
            calls.return_to,
            &.{ restored, cursor, try e.payload(try e.field(exit, 0), 0) },
        ),
        try e.call(
            calls.resume_continuation,
            &.{
                restored,
                try e.payload(cursor, 1),
                try e.literal(g.Value, .{
                    .schema = 0,
                    .body = .{ .scalar = @splat(0) },
                }),
            },
        ),
    );
}

fn emitPosition(
    m: machines.Definition,
    d: Definition,
    e: Author,
    graph: anytype,
    null_ref: Id,
) Error!void {
    const input = try e.param(d.position, 0);
    const appended = try e.b.variable(graph.appended);
    var changed = try root(e, m, try e.field(try e.b.reference(appended), 0), "current", try some(
        e,
        try e.field(try e.b.reference(appended), 1),
    ));
    changed = try root(e, m, changed, "pending", null_ref);
    changed = try root(e, m, changed, "evidence", null_ref);
    const record = try graphs.record(e, .unwind, &.{
        try e.param(d.position, 1), try e.param(d.position, 2),
    });
    try e.b.define(
        d.position,
        try e.b.bind(
            appended,
            try e.call(graph.append, &.{
                input,
                record,
            }),
            try e.b.pure(try status(e, m, changed, .unwinding)),
        ),
    );
}

fn emitBegin(
    m: machines.Definition,
    d: Definition,
    e: Author,
    graph: anytype,
    node_type: Id,
) Error!void {
    const input = try e.param(d.begin, 0);
    const appended = try e.b.variable(graph.appended);
    var exit = try e.literal(g.Exit, .{ .reason = .abandoned });
    exit = try e.replace(exit, 0, try e.param(d.begin, 1));
    exit = try e.replace(exit, machines.index(g.Exit, "stop"), try e.param(d.begin, 3));
    exit = try e.replace(exit, machines.index(g.Exit, "outer"), try field(
        e,
        try control.roots(e, m, input),
        g.Roots,
        "exit",
    ));
    const changed = try root(e, m, try e.field(try e.b.reference(appended), 0), "exit", try some(
        e,
        try e.field(try e.b.reference(appended), 1),
    ));
    try e.b.define(
        d.begin,
        try e.b.bind(
            appended,
            try e.call(
                graph.append,
                &.{ input, try e.variant(
                    node_type,
                    @backingInt(g.NodeTag.exit),
                    exit,
                ) },
            ),
            try e.call(d.position, &.{
                changed, try e.param(d.begin, 2), try e.param(d.begin, 4),
            }),
        ),
    );
}

fn emitOutermost(d: Definition, e: Author, graph: anytype, node_type: Id) Error!void {
    const input = try e.param(d.outermost, 0);
    const ref = try e.param(d.outermost, 1);
    const record = try e.b.variable(node_type);
    const outer = try field(e, try e.payload(
        try e.b.reference(record),
        @backingInt(g.NodeTag.exit),
    ), g.Exit, "outer");
    try e.b.define(
        d.outermost,
        try e.b.bind(
            record,
            try e.call(graph.record, &.{
                input,
                ref,
            }),
            try e.when(
                try is(e, outer, 0),
                try e.b.pure(ref),
                try e.call(d.outermost, &.{ input, try e.payload(outer, 1) }),
            ),
        ),
    );
}

fn emitDiscarded(d: Definition, e: Author) Error!void {
    const exit = try e.param(d.discarded, 0);
    const prior = try field(e, exit, g.Exit, "discarded");
    const reason = try e.field(exit, 0);
    const normal = try e.payload(reason, 0);
    const keep = try e.b.pure(prior);
    try e.b.define(
        d.discarded,
        try e.when(
            try is(e, reason, 0),
            try e.when(
                try is(e, try e.field(normal, 1), 3),
                try e.b.pure(try concat(e, prior, try seq(e, &.{normal}))),
                keep,
            ),
            keep,
        ),
    );
}

fn emitRememberFailure(
    m: machines.Definition,
    d: Definition,
    e: Author,
    graph: anytype,
    node_type: Id,
    ref_type: Id,
    values_type: Id,
    null_ref: Id,
) Error!void {
    const input = try e.param(d.remember_failure, 0);
    const value = try e.param(d.remember_failure, 1);
    const ref = try e.b.variable(ref_type);
    const record = try e.b.variable(node_type);
    const exit = try e.payload(try e.b.reference(record), @backingInt(g.NodeTag.exit));
    const discarded = try e.b.variable(values_type);
    var changed = try emitChanged(e, exit, value);
    changed = try e.replace(
        changed,
        machines.index(g.Exit, "discarded"),
        try e.b.reference(discarded),
    );
    const selected = try e.b.variable(try projection.schema(g.Exit, e.b));
    const failure = try e.replace(try e.replace(changed, 0, try e.variant(
        try projection.schema(Reason, e.b),
        1,
        value,
    )), machines.index(g.Exit, "stop"), null_ref);
    const choose = try emitChoose(e, changed, exit, failure);
    var body = try emitBody(e, graph, node_type, input, ref, selected, choose);
    body = try e.b.bind(discarded, try e.call(d.discarded, &.{exit}), body);
    body = try e.b.bind(record, try e.call(
        graph.record,
        &.{ input, try e.b.reference(ref) },
    ), body);
    try e.b.define(
        d.remember_failure,
        try e.b.bind(
            ref,
            try e.call(
                d.outermost,
                &.{
                    input,
                    try e.payload(
                        try field(e, try control.roots(e, m, input), g.Roots, "exit"),
                        1,
                    ),
                },
            ),
            body,
        ),
    );
}

fn emitFailCurrent(
    m: machines.Definition,
    d: Definition,
    e: Author,
    graph: anytype,
    values_type: Id,
    null_ref: Id,
) Error!void {
    const input = try e.param(d.fail_current, 0);
    const current = try e.payload(try field(
        e,
        try control.roots(e, m, input),
        g.Roots,
        "current",
    ), 1);
    const element = try e.b.variable(m.nodes.element);
    const saved = try e.payload(try e.field(try e.b.reference(element), 0), 0);
    const discarded = try e.b.variable(values_type);
    const changed = try e.b.variable(m.schema);
    const value = try e.param(d.fail_current, 1);
    const prior_exit = try field(e, try control.roots(e, m, input), g.Roots, "exit");
    const remember = try e.when(try is(e, prior_exit, 0), try e.b.pure(input), try e.call(
        d.remember_failure,
        &.{ input, value },
    ));
    var body = try e.b.bind(
        changed,
        remember,
        try e.call(
            d.begin,
            &.{
                try e.b.reference(changed),
                try e.variant(try projection.schema(Reason, e.b), 1, value),
                try e.field(saved, 1),
                null_ref,
                try e.b.reference(discarded),
            },
        ),
    );
    body = try e.b.bind(discarded, try e.call(m.frames.discards, &.{try e.payload(
        try e.field(try e.b.reference(element), 1),
        1,
    )}), body);
    try e.b.define(d.fail_current, try e.b.bind(element, try e.call(
        graph.element,
        &.{ input, current },
    ), body));
}

fn emitDispose(
    m: machines.Definition,
    d: Definition,
    calls: control.Definition,
    e: Author,
    captures: anytype,
) Error!void {
    const input = try e.param(d.dispose, 0);
    const current = try e.param(d.dispose, 1);
    const saved = try e.param(d.dispose, 2);
    const frame = try e.param(d.dispose, 3);
    const operation = try e.param(d.dispose, 4);
    const value = try e.b.variable(try projection.schema(g.Value, e.b));
    const taken = try e.b.variable(captures.taken);
    const captured = try e.b.variable(m.schema);
    const activated = try e.b.variable(m.schema);
    const token = try e.field(try e.b.reference(taken), 1);
    var body = try e.b.bind(activated, try e.call(captures.activate, &.{
        try e.b.reference(captured), token, current,
    }), try e.call(d.begin, &.{
        try e.b.reference(activated),
        try e.literal(Reason, .abandoned),
        try field(e, token, g.Capture, "capture"),
        try some(e, current),
        try empty(e),
    }));
    body = try e.b.bind(captured, try e.call(calls.capture, &.{
        try e.field(try e.b.reference(taken), 0),
        current,
        saved,
        frame,
        try e.field(operation, 1),
    }), body);
    body = try e.b.bind(taken, try e.call(
        captures.take,
        &.{ input, try e.b.reference(value) },
    ), body);
    try e.b.define(d.dispose, try e.b.bind(value, try e.call(
        m.frames.read,
        &.{ frame, try e.field(operation, 0) },
    ), body));
}

fn emitReturnedDisposal(d: Definition, e: Author, values_type: Id) Error!void {
    const input = try e.param(d.returned_disposal, 0);
    const frame = try e.param(d.returned_disposal, 1);
    const value = try e.param(d.returned_disposal, 2);
    const prior = try e.field(frame, 2);
    const selected = try e.b.variable(values_type);
    try e.b.define(
        d.returned_disposal,
        try e.b.bind(
            selected,
            try e.when(
                try is(e, try e.field(value, 1), 3),
                try e.b.pure(try concat(e, try seq(e, &.{value}), prior)),
                try e.b.pure(prior),
            ),
            try e.call(d.position, &.{
                input, try e.field(frame, 1), try e.b.reference(selected),
            }),
        ),
    );
}

fn emitOwned(e: Author, values_type: Id, owned: Id) Error!void {
    const values = try e.param(owned, 0);
    const head = try e.required(values, e.zero);
    const tail = try tailOf(e, values);
    const rest = try e.b.variable(values_type);
    const body = try e.b.bind(
        rest,
        try e.call(owned, &.{
            tail,
        }),
        try e.when(
            try is(e, try e.field(head, 1), 3),
            try e.b.pure(try concat(
                e,
                try seq(e, &.{head}),
                try e.b.reference(rest),
            )),
            try e.b.pure(try e.b.reference(rest)),
        ),
    );
    try e.b.define(owned, try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{values},
        0,
    ), e.zero), try e.b.pure(try empty(e)), body));
}

fn emitStep(
    m: machines.Definition,
    d: Definition,
    calls: control.Definition,
    e: Author,
    graph: anytype,
    captures: anytype,
    node_type: Id,
    ref_type: Id,
    values_type: Id,
    owned: Id,
) Error!void {
    const bindings = try unwindBindings(m, d, e, graph, node_type, ref_type);
    const disposal = try disposeUnwindHead(
        e,
        d,
        graph,
        captures,
        node_type,
        values_type,
        owned,
        bindings,
    );
    const walk = try walkUnwindControl(m, d, e, graph, values_type, bindings);
    const finish = try finishUnwind(m, e, graph, bindings);
    const onward = try e.when(try is(e, bindings.cursor, 0), finish, walk);
    const restored = try status(e, m, try root(
        e,
        m,
        bindings.input,
        "exit",
        try field(e, bindings.exit, g.Exit, "outer"),
    ), .active);
    const resume_saved = try emitResumeSaved(calls, e, bindings.exit, bindings.cursor, restored);
    const stop = try field(e, bindings.exit, g.Exit, "stop");
    var body = try emitStepBothPresentBody(e, bindings, disposal, onward, resume_saved, stop);
    body = try e.b.bind(bindings.root_node, try e.call(
        graph.record,
        &.{ bindings.input, try e.b.reference(bindings.root_ref) },
    ), body);
    body = try e.b.bind(
        bindings.root_ref,
        try e.call(d.outermost, &.{ bindings.input, bindings.exit_ref }),
        body,
    );
    body = try e.b.bind(
        bindings.exit_node,
        try e.call(graph.record, &.{ bindings.input, bindings.exit_ref }),
        body,
    );
    try emitStepStepDefinition(d, e, graph, bindings, body);
}

fn emitStepStepDefinition(
    d: Definition,
    e: Author,
    graph: anytype,
    bindings: UnwindBindings,
    body: Id,
) Error!void {
    try e.b.define(
        d.step,
        try e.b.bind(
            bindings.current_node,
            try e.call(
                graph.record,
                &.{ bindings.input, try e.payload(
                    try field(e, bindings.roots, g.Roots, "current"),
                    1,
                ) },
            ),
            body,
        ),
    );
}

fn emitStepBothPresentBody(
    e: Author,
    bindings: UnwindBindings,
    disposal: anytype,
    onward: anytype,
    resume_saved: anytype,
    stop: anytype,
) Error!Id {
    const both_present = try e.when(try e.binary(
        .equal,
        try e.field(try e.payload(bindings.cursor, 1), 0),
        try e.field(try e.payload(stop, 1), 0),
    ), resume_saved, onward);
    const stopped = try e.when(try e.binary(
        .equal,
        try tag(e, bindings.cursor),
        try tag(e, stop),
    ), try e.when(try is(e, bindings.cursor, 0), resume_saved, both_present), onward);
    const progress = try e.when(try is(e, try e.field(bindings.exit, 0), 0), stopped, try e.when(
        try is(e, try e.field(bindings.exit, 0), 3),
        stopped,
        onward,
    ));
    const body = try e.when(try e.binary(.less, e.zero, try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{bindings.discarded},
        0,
    )), bindings.drain, try e.when(try e.binary(.less, e.zero, try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{bindings.current_values},
        0,
    )), disposal, progress));
    return body;
}

fn disposeOwnedChildren(
    e: Author,
    d: Definition,
    graph: anytype,
    captures: anytype,
    node_type: Id,
    values_type: Id,
    input: Id,
    head: Id,
    cursor: Id,
    tail: Id,
    changed: Id,
    record: Id,
    owned: Id,
) Error!Id {
    var disposal = try e.fail();
    disposal = try disposeToken(
        e,
        d,
        graph,
        captures,
        head,
        cursor,
        tail,
        changed,
        input,
        record,
        disposal,
    );
    inline for ([_]g.NodeTag{ .aggregate, .computation, .package }) |kind| {
        const payload = try e.payload(record, @backingInt(kind));
        const environment = try e.b.variable(node_type);
        const children = switch (kind) {
            .aggregate => try e.field(payload, 2),
            .package => try seq(e, &.{try field(
                e,
                payload,
                @FieldType(g.Node, "package"),
                "continuation",
            )}),
            .computation => try e.field(try e.payload(
                try e.b.reference(environment),
                @backingInt(g.NodeTag.environment),
            ), 0),
            else => unreachable,
        };
        const filtered = try e.b.variable(values_type);
        var body = try e.b.bind(
            filtered,
            try e.call(owned, &.{
                children,
            }),
            try e.call(
                d.position,
                &.{ input, cursor, try concat(e, try e.b.reference(filtered), tail) },
            ),
        );
        if (kind == .computation) body = try e.b.bind(environment, try e.call(
            graph.record,
            &.{ input, try e.field(payload, 1) },
        ), body);
        disposal = try e.when(try is(e, record, @backingInt(kind)), body, disposal);
    }
    return disposal;
}

fn walkUnwindControl(
    m: machines.Definition,
    d: Definition,
    e: Author,
    graph: anytype,
    values_type: Id,
    bindings: UnwindBindings,
) Error!Id {
    const selected = try e.b.variable(m.nodes.element);
    const selected_record = try e.field(try e.b.reference(selected), 0);
    var walk = try e.fail();
    inline for ([_]g.NodeTag{
        .control, .continuation, .attachment, .region_scope, .injection, .disposal_return,
    }) |kind| {
        const payload = try e.payload(selected_record, @backingInt(kind));
        const parent = switch (kind) {
            .control, .continuation => try e.field(payload, 1),
            .attachment, .region_scope => try e.field(payload, 2),
            .injection => try some(e, try e.field(payload, 0)),
            .disposal_return => try e.field(payload, 1),
            else => unreachable,
        };
        var body = try e.call(d.position, &.{
            bindings.input,                                                          parent,
            if (kind == .disposal_return) try e.field(payload, 2) else try empty(e),
        });
        if (kind == .control or kind == .continuation) {
            const values = try e.b.variable(values_type);
            body = try e.b.bind(values, try e.call(m.frames.discards, &.{try e.payload(
                try e.field(try e.b.reference(selected), 1),
                1,
            )}), try e.call(d.position, &.{
                bindings.input,
                parent,
                try e.b.reference(values),
            }));
        }
        walk = try e.when(try is(e, selected_record, @backingInt(kind)), body, walk);
    }
    walk = try e.when(try is(
        e,
        selected_record,
        @backingInt(g.NodeTag.protection),
    ), try e.call(d.cleanup.run, &.{ bindings.input, try e.payload(
        selected_record,
        @backingInt(g.NodeTag.protection),
    ), bindings.exit_ref, bindings.root_exit }), walk);
    walk = try e.when(try is(
        e,
        selected_record,
        @backingInt(g.NodeTag.cleanup_return),
    ), try e.call(d.cleanup.crossed, &.{ bindings.input, try e.payload(
        selected_record,
        @backingInt(g.NodeTag.cleanup_return),
    ), bindings.exit }), walk);
    walk = try e.b.bind(selected, try e.call(
        graph.element,
        &.{ bindings.input, try e.payload(bindings.cursor, 1) },
    ), walk);
    return walk;
}

fn finishUnwind(
    m: machines.Definition,
    e: Author,
    graph: anytype,
    bindings: UnwindBindings,
) Error!Id {
    const terminal = try e.b.variable(graph.appended);
    const terminal_input = try e.field(try e.b.reference(terminal), 0);
    const terminal_roots = try e.replace(
        try e.literal(g.Roots, .{}),
        machines.index(g.Roots, "exit"),
        try some(e, try e.field(try e.b.reference(terminal), 1)),
    );
    const terminal_status = try emitTerminalStatus(
        m,
        e,
        bindings.root_exit,
        terminal_input,
        terminal_roots,
    );
    const finish = try e.b.bind(terminal, try e.call(graph.append, &.{
        bindings.input, try e.b.reference(bindings.root_node),
    }), terminal_status);
    return finish;
}

fn unwindBindings(
    m: machines.Definition,
    d: Definition,
    e: Author,
    graph: anytype,
    node_type: Id,
    ref_type: Id,
) Error!UnwindBindings {
    const input = try e.param(d.step, 0);
    const roots = try control.roots(e, m, input);
    const current_node = try e.b.variable(node_type);
    const current = try e.payload(try e.b.reference(current_node), @backingInt(g.NodeTag.unwind));
    const cursor = try e.field(current, 0);
    const current_values = try e.field(current, 1);
    const exit_ref = try e.payload(try field(e, roots, g.Roots, "exit"), 1);
    const exit_node = try e.b.variable(node_type);
    const exit = try e.payload(try e.b.reference(exit_node), @backingInt(g.NodeTag.exit));
    const root_ref = try e.b.variable(ref_type);
    const root_node = try e.b.variable(node_type);
    const root_exit = try e.payload(try e.b.reference(root_node), @backingInt(g.NodeTag.exit));
    const discarded = try field(e, root_exit, g.Exit, "discarded");
    const changed = try e.b.variable(m.schema);
    const drain = try emitDrain(
        d,
        e,
        graph,
        node_type,
        input,
        changed,
        discarded,
        cursor,
        current_values,
        root_ref,
        root_exit,
    );
    return .{
        .input = input,
        .roots = roots,
        .current_node = current_node,
        .cursor = cursor,
        .current_values = current_values,
        .exit_ref = exit_ref,
        .exit_node = exit_node,
        .exit = exit,
        .root_ref = root_ref,
        .root_node = root_node,
        .root_exit = root_exit,
        .discarded = discarded,
        .changed = changed,
        .drain = drain,
    };
}

const UnwindBindings = struct {
    input: Id,
    roots: Id,
    current_node: Id,
    cursor: Id,
    current_values: Id,
    exit_ref: Id,
    exit_node: Id,
    exit: Id,
    root_ref: Id,
    root_node: Id,
    root_exit: Id,
    discarded: Id,
    changed: Id,
    drain: Id,
};

fn disposeToken(
    e: Author,
    d: Definition,
    graph: anytype,
    captures: anytype,
    head: Id,
    cursor: Id,
    tail: Id,
    changed: Id,
    input: Id,
    record: Id,
    disposal: Id,
) Error!Id {
    var disposal_result = disposal;
    {
        const taken = try e.b.variable(captures.taken);
        const after = try e.b.variable(graph.appended);
        const token = try e.field(try e.b.reference(taken), 1);
        const frame = try graphs.record(e, .disposal_return, &.{
            try e.field(head, 0), cursor, tail,
        });
        var body = try e.b.bind(changed, try e.call(captures.activate, &.{
            try e.field(try e.b.reference(after), 0),
            token,
            try e.field(try e.b.reference(after), 1),
        }), try e.call(d.position, &.{
            try e.b.reference(changed), try field(e, token, g.Capture, "capture"), try empty(e),
        }));
        body = try e.b.bind(after, try e.call(graph.append, &.{
            try e.field(try e.b.reference(taken), 0), frame,
        }), body);
        body = try e.b.bind(taken, try e.call(captures.take, &.{ input, head }), body);
        disposal_result = try e.when(
            try is(e, record, @backingInt(g.NodeTag.one_shot)),
            body,
            disposal_result,
        );
    }
    return disposal_result;
}

fn disposeUnwindHead(
    e: Author,
    d: Definition,
    graph: anytype,
    captures: anytype,
    node_type: Id,
    values_type: Id,
    owned: Id,
    bindings: UnwindBindings,
) Error!Id {
    const head = try e.required(bindings.current_values, e.zero);
    const tail = try tailOf(e, bindings.current_values);
    const owned_node = try e.b.variable(node_type);
    const record = try e.b.reference(owned_node);
    var disposal = try disposeOwnedChildren(
        e,
        d,
        graph,
        captures,
        node_type,
        values_type,
        bindings.input,
        head,
        bindings.cursor,
        tail,
        bindings.changed,
        record,
        owned,
    );
    disposal = try e.when(try is(e, record, @backingInt(g.NodeTag.resource)), try e.call(
        d.position,
        &.{ bindings.input, bindings.cursor, tail },
    ), disposal);
    disposal = try e.b.bind(owned_node, try e.call(graph.record, &.{ bindings.input, try e.field(
        try e.payload(try e.field(head, 1), 3),
        0,
    ) }), disposal);
    return disposal;
}
