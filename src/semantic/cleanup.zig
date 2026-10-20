//! Ordinary authored cleanup obligations and the exit information they observe.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const graphs = @import("graph.zig");
const control = @import("control.zig");
const edges = @import("edges.zig");
const unwind = @import("unwind.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const field = edges.field;
const some = unwind.some;
const empty = unwind.empty;
const seq = unwind.seq;
const concat = unwind.concat;
const is = unwind.is;
const root = unwind.root;
const status = unwind.status;
pub const Definition = struct {
    protect: Id,
    information: Id,
    run: Id,
    returned: Id,
    crossed: Id,
    unlink: Id,
    cancel: Id,
};
pub fn declare(b: *source.Builder, m: machines.Definition) Error!Definition {
    const ref = try projection.schema(g.NodeRef, b);
    const value_result = (try @import("values.zig").define(b, m)).result;
    return .{
        .protect = try b.declare(
            &.{
                m.schema,                            ref,
                try projection.schema(g.Control, b), m.frames.schema,
                try projection.schema(@FieldType(
                    data.activation.Terminator,
                    "protect",
                ), b),
            },
            m.schema,
            &.{},
            &.{},
        ),
        .information = try b.declare(&.{
            m.schema, try b.scalar(u64), try projection.schema(g.Exit, b),
        }, value_result, &.{}, &.{}),
        .run = try b.declare(&.{ m.schema, try projection.schema(
            @FieldType(g.Node, "protection"),
            b,
        ), ref, try projection.schema(g.Exit, b) }, m.schema, &.{}, &.{}),
        .returned = try b.declare(&.{ m.schema, try projection.schema(
            @FieldType(g.Node, "cleanup_return"),
            b,
        ) }, m.schema, &.{}, &.{}),
        .crossed = try b.declare(&.{ m.schema, try projection.schema(
            @FieldType(g.Node, "cleanup_return"),
            b,
        ), try projection.schema(g.Exit, b) }, m.schema, &.{}, &.{}),
        .unlink = try b.declare(&.{ m.schema, ref, ref }, m.schema, &.{}, &.{}),
        .cancel = try b.declare(&.{
            m.schema, try projection.schema(data.invocation.Reason, b),
        }, m.schema, &.{}, &.{}),
    };
}
fn shapes(e: Author, m: machines.Definition, input: Id) Error!Id {
    return field(
        e,
        try edges.code(e, try m.field(e, input, .program)),
        data.activation.Program,
        "schemas",
    );
}
fn parameters(e: Author, m: machines.Definition, input: Id, value: Id) Error!Id {
    const schema = try e.required(try shapes(e, m, input), try e.field(value, 0));
    const computation = try e.payload(try e.payload(
        schema,
        @backingInt(data.program.SchemaTag.internal),
    ), @backingInt(data.program.InternalTag.computation));
    return field(e, computation, data.program.ComputationType, "parameters");
}
pub fn emit(
    b: *source.Builder,
    m: machines.Definition,
    d: Definition,
    u: unwind.Definition,
    calls: control.Definition,
) Error!void {
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const values = try @import("values.zig").define(b, m);
    const aggregate = try @import("aggregate.zig").define(b, m);
    const codec = try @import("codec.zig").define(b, m);
    const edge = try edges.define(b, m);
    const node = try projection.schema(g.Node, b);
    const value = try projection.schema(g.Value, b);
    const maybe_value = try projection.schema(?g.Value, b);
    const ref = try projection.schema(g.NodeRef, b);
    const maybe_ref = try projection.schema(?g.NodeRef, b);
    const vals = try projection.schema([]const g.Value, b);
    const null_ref = try e.literal(?g.NodeRef, null);
    const null_value = try e.literal(?g.Value, null);
    const obligation_type = @FieldType(g.Node, "obligation");
    const obligation_status = try projection.schema(@FieldType(obligation_type, "status"), b);
    try emitProtect(
        m,
        d,
        calls,
        e,
        graph,
        edge,
        value,
        maybe_value,
        maybe_ref,
        vals,
        null_ref,
        null_value,
        obligation_status,
    );
    try emitInformation(m, d, e, values, aggregate, codec, value);
    try emitRun(m, d, calls, e, graph, values, node, vals, null_value, obligation_status);
    try emitReturned(m, d, u, e, graph, node, obligation_status);
    try emitExitCrossing(b, m, d, u);
    _ = ref;
}

fn emitExitCrossing(
    b: *source.Builder,
    m: machines.Definition,
    d: Definition,
    u: unwind.Definition,
) Error!void {
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const node = try projection.schema(g.Node, b);
    const ref = try projection.schema(g.NodeRef, b);
    const vals = try projection.schema([]const g.Value, b);
    const exit_type = try projection.schema(g.Exit, b);
    const reason_type = try projection.schema(@FieldType(g.Exit, "reason"), b);
    const obligation_status = try projection.schema(@FieldType(
        @FieldType(g.Node, "obligation"),
        "status",
    ), b);
    const null_ref = try e.literal(?g.NodeRef, null);
    try emitUnlink(m, d, e, graph, node, reason_type, null_ref);
    try emitCrossed(m, d, u, e, graph, node, vals, obligation_status, null_ref);
    try emitCancel(m, d, u, e, graph, node, ref, vals, exit_type, null_ref);
}

fn emitObligationRecord(
    e: Author,
    maybe_value: Id,
    obligation_status: Id,
    saved: Id,
    cleanup_value: Id,
    resource_value: Id,
) Error!Id {
    return try graphs.record(
        e,
        .obligation,
        &.{
            try e.field(saved, 0),
            try e.variant(maybe_value, 1, try e.b.reference(cleanup_value)),
            try e.b.reference(resource_value),
            try e.variant(obligation_status, 0, e.unit_value),
        },
    );
}

fn emitLoan(
    e: Author,
    graph: anytype,
    null_ref: Id,
    loan_pair_type: Id,
    loan_node: Id,
    loan_descriptor: Id,
    after_obligation: Id,
    loan_record: Id,
) Error!Id {
    return try e.when(try is(e, loan_descriptor, 0), try e.b.pure(try e.tuple(
        loan_pair_type,
        &.{ after_obligation, null_ref },
    )), try e.b.bind(loan_node, try e.call(
        graph.append,
        &.{ after_obligation, loan_record },
    ), try e.b.pure(
        try e.tuple(
            loan_pair_type,
            &.{
                try e.field(try e.b.reference(loan_node), 0),
                try some(e, try e.field(try e.b.reference(loan_node), 1)),
            },
        ),
    )));
}

fn emitPrefix(
    e: Author,
    graph: anytype,
    resource_value: Id,
    after_loan: Id,
    arguments: Id,
    prefix_pair_type: Id,
    borrow: Id,
    borrow_record: Id,
    borrowed_value: anytype,
) Error!Id {
    return try e.when(try is(
        e,
        try e.b.reference(resource_value),
        0,
    ), try e.b.pure(try e.tuple(prefix_pair_type, &.{
        after_loan, try e.b.reference(arguments),
    })), try e.b.bind(borrow, try e.call(
        graph.append,
        &.{ after_loan, borrow_record },
    ), try e.b.pure(
        try e.tuple(
            prefix_pair_type,
            &.{
                try e.field(try e.b.reference(borrow), 0),
                try concat(e, try seq(e, &.{borrowed_value}), try e.b.reference(arguments)),
            },
        ),
    )));
}

fn emitProtectionRecord(e: Author, current: Id, saved: Id, obligation: Id, loan_ref: Id) Error!Id {
    return try graphs.record(
        e,
        .protection,
        &.{
            try e.field(saved, 0),
            try e.tuple(
                try projection.schema(g.OwnedRef, e.b),
                &.{try e.field(try e.b.reference(obligation), 1)},
            ),
            try some(e, current),
            try e.field(saved, 2),
            try e.field(saved, 3),
            loan_ref,
        },
    );
}

fn emitBody(
    calls: control.Definition,
    e: Author,
    saved: Id,
    body_value: Id,
    loan_ref: Id,
    prefix_pair: Id,
    protection: Id,
    region: Id,
) Error!Id {
    return try e.b.bind(region, try e.when(
        try is(e, loan_ref, 0),
        try e.b.pure(try e.field(saved, 3)),
        try e.b.pure(loan_ref),
    ), try e.call(
        calls.apply,
        &.{
            try e.field(try e.b.reference(protection), 0),
            try e.b.reference(body_value),
            try e.field(try e.b.reference(prefix_pair), 1),
            try some(e, try e.field(try e.b.reference(protection), 1)),
            try e.field(saved, 2),
            try e.b.reference(region),
        },
    ));
}

fn emitConstructReason(
    e: Author,
    values: anytype,
    aggregate: anytype,
    input: Id,
    prefix: Id,
    reason_schema: Id,
    reason_cases: Id,
    raw: Id,
    payload: Id,
    reason_kind: anytype,
) Error!Id {
    return try e.b.bind(
        payload,
        try e.call(
            values.literal,
            &.{
                input,
                try e.tuple(
                    try projection.schema(data.program.Literal, e.b),
                    &.{
                        try e.required(reason_cases, reason_kind),
                        try e.concat(try e.b.reference(prefix), try e.b.reference(raw)),
                    },
                ),
            },
        ),
        try e.call(
            aggregate.construct,
            &.{
                try e.field(try e.b.reference(payload), 0),
                reason_schema,
                reason_kind,
                try seq(e, &.{
                    try e.field(try e.b.reference(payload), 1),
                }),
            },
        ),
    );
}

fn emitChoosePrimary(e: Author, unit_value: Id, reason_value: Id, primary_reason: Id) Error!Id {
    return try e.when(
        try is(e, primary_reason, 1),
        try e.b.pure(try e.payload(primary_reason, 1)),
        try e.when(
            try is(e, primary_reason, 2),
            try e.b.pure(reason_value),
            try e.b.pure(unit_value),
        ),
    );
}

fn emitExitCrossingChoose(
    e: Author,
    prior_reason: Id,
    prior_cancellation: Id,
    merge: Id,
    keep: Id,
) Error!Id {
    return try e.when(
        try is(e, prior_reason, 1),
        merge,
        try e.when(
            try is(e, prior_reason, 2),
            merge,
            try e.when(try is(e, prior_cancellation, 1), merge, keep),
        ),
    );
}

fn emitExitCrossingAbandoned(
    u: unwind.Definition,
    e: Author,
    graph: anytype,
    node: Id,
    changed: Id,
    frame: Id,
    obligation_ref: Id,
    discarded: Id,
    finished: Id,
    completed_obligation: Id,
) Error!Id {
    return try e.b.bind(
        finished,
        try e.call(
            graph.replace,
            &.{
                try e.b.reference(changed),
                obligation_ref,
                try e.variant(node, @backingInt(g.NodeTag.obligation), completed_obligation),
            },
        ),
        try e.call(u.position, &.{
            try e.b.reference(finished), try e.field(frame, 1), try e.b.reference(discarded),
        }),
    );
}

fn emitExitCrossingUpdateParent(
    u: unwind.Definition,
    e: Author,
    graph: anytype,
    node: Id,
    prior: Id,
    changed: Id,
    prior_ref: Id,
    discarded: Id,
    parent_failed: Id,
) Error!Id {
    return try e.b.bind(
        discarded,
        try e.call(u.discarded, &.{
            prior,
        }),
        try e.call(
            graph.replace,
            &.{
                try e.b.reference(changed),
                prior_ref,
                try e.variant(node, @backingInt(g.NodeTag.exit), parent_failed),
            },
        ),
    );
}

fn emitExitCrossingChooseParent(e: Author, prior: Id, changed: Id, update_parent: Id) Error!Id {
    return try e.when(
        try is(e, try e.field(prior, 0), 0),
        update_parent,
        try e.when(
            try is(e, try e.field(prior, 0), 3),
            update_parent,
            try e.b.pure(try e.b.reference(changed)),
        ),
    );
}

fn emitExitCrossingSelect(e: Author, exit: Id, abandoned: Id, failure: Id) Error!Id {
    return try e.when(
        try is(e, try e.field(exit, 0), 3),
        abandoned,
        try e.when(
            try is(e, try e.field(exit, 0), 2),
            abandoned,
            try e.when(try is(e, try e.field(exit, 0), 1), failure, try e.fail()),
        ),
    );
}

fn emitExitCrossingStart(
    u: unwind.Definition,
    e: Author,
    null_ref: Id,
    input: Id,
    cursor: Id,
    prior_exit: Id,
    choose_cursor: Id,
) Error!Id {
    return try e.when(
        try is(e, prior_exit, 0),
        try e.b.bind(
            cursor,
            choose_cursor,
            try e.call(
                u.begin,
                &.{
                    input,
                    try e.literal(@FieldType(g.Exit, "reason"), .cancellation),
                    try e.b.reference(cursor),
                    null_ref,
                    try empty(e),
                },
            ),
        ),
        try e.b.pure(input),
    );
}

fn emitExitCrossingAnnotate(
    e: Author,
    graph: anytype,
    node: Id,
    select: Id,
    started: Id,
    root_ref: Id,
    selected: Id,
) Error!Id {
    return try e.b.bind(
        selected,
        select,
        try e.call(
            graph.replace,
            &.{
                try e.b.reference(started),
                try e.b.reference(root_ref),
                try e.variant(node, @backingInt(g.NodeTag.exit), try e.b.reference(selected)),
            },
        ),
    );
}

fn emitProtect(
    m: machines.Definition,
    d: Definition,
    calls: control.Definition,
    e: Author,
    graph: anytype,
    edge: anytype,
    value: Id,
    maybe_value: Id,
    maybe_ref: Id,
    vals: Id,
    null_ref: Id,
    null_value: Id,
    obligation_status: Id,
) Error!void {
    const bindings = try protectionBindings(
        m,
        d,
        e,
        graph,
        value,
        maybe_value,
        null_value,
        obligation_status,
    );
    const prepareProtectionLoan_result = try prepareProtectionLoan(
        m,
        e,
        graph,
        maybe_ref,
        bindings,
        null_ref,
    );
    const loan_pair = prepareProtectionLoan_result.loan_pair;
    const loan = prepareProtectionLoan_result.loan;
    const loan_ref = try e.field(try e.b.reference(loan_pair), 1);
    const after_loan = try e.field(try e.b.reference(loan_pair), 0);
    const arguments = try e.b.variable(vals);
    const prepareProtectionPrefix_result = try prepareProtectionPrefix(
        m,
        e,
        graph,
        vals,
        bindings,
        loan_ref,
        after_loan,
        arguments,
    );
    const prefix_pair = prepareProtectionPrefix_result.prefix_pair;
    const prefix = prepareProtectionPrefix_result.prefix;
    try bindProtection(
        m,
        d,
        calls,
        e,
        graph,
        edge,
        maybe_ref,
        bindings,
        loan_ref,
        prefix_pair,
        prefix,
        arguments,
        loan_pair,
        loan,
    );
}

fn emitInformation(
    m: machines.Definition,
    d: Definition,
    e: Author,
    values: anytype,
    aggregate: anytype,
    codec: anytype,
    value: Id,
) Error!void {
    const bindings = try informationBindings(m, d, e, values);
    const choose_reason = try chooseInformationReason(
        e,
        values,
        aggregate,
        codec,
        bindings.reason,
        bindings.prefix,
        bindings.input,
        bindings.reason_schema,
        bindings.reason_cases,
        bindings.raw,
        bindings.payload,
        bindings.cancellation,
        bindings.unit_value,
    );
    const primary_value = try e.b.variable(value);
    const primary = try e.b.variable(values.result);
    const optional = try e.b.variable(values.result);
    const failures = try e.b.variable(values.result);
    const reason_value = try e.field(try e.b.reference(bindings.encoded_reason), 1);
    const primary_reason = try e.field(bindings.exit, 0);
    const choose_primary = try emitChoosePrimary(
        e,
        bindings.unit_value,
        reason_value,
        primary_reason,
    );
    try bindInformation(
        e,
        d,
        aggregate,
        bindings.schema,
        failures,
        primary,
        optional,
        bindings.exit,
        bindings.failures_schema,
        bindings.optional_schema,
        bindings.cancellation,
        reason_value,
        bindings.encoded_reason,
        bindings.primary_schema,
        primary_reason,
        primary_value,
        choose_primary,
        choose_reason,
    );
}

fn emitRun(
    m: machines.Definition,
    d: Definition,
    calls: control.Definition,
    e: Author,
    graph: anytype,
    values: anytype,
    node: Id,
    vals: Id,
    null_value: Id,
    obligation_status: Id,
) Error!void {
    const input = try e.param(d.run, 0);
    const protection = try e.param(d.run, 1);
    const obligation_ref = try e.field(try e.field(protection, 1), 0);
    const record = try e.b.variable(node);
    const obligation = try e.payload(
        try e.b.reference(record),
        @backingInt(g.NodeTag.obligation),
    );
    const cleanup = try e.payload(try e.field(obligation, 1), 1);
    const resource = try e.field(obligation, 2);
    const frame = try e.b.variable(graph.appended);
    const changed = try e.b.variable(m.schema);
    var transferred = try e.replace(obligation, 1, null_value);
    transferred = try e.replace(transferred, 2, null_value);
    transferred = try e.replace(transferred, 3, try e.variant(
        obligation_status,
        1,
        try e.field(try e.b.reference(frame), 1),
    ));
    const info = try e.b.variable(values.result);
    var body = try applyCleanup(m, calls, e, vals, info, resource, cleanup, frame, protection);
    body = try emitRunBody(m, d, e, input, cleanup, changed, info, body);
    body = try emitRunObligation(
        e,
        graph,
        node,
        obligation_ref,
        frame,
        changed,
        transferred,
        body,
    );
    try bindCleanupFrame(
        e,
        d,
        graph,
        input,
        protection,
        frame,
        record,
        obligation_ref,
        obligation,
        body,
    );
}

fn emitReturned(
    m: machines.Definition,
    d: Definition,
    u: unwind.Definition,
    e: Author,
    graph: anytype,
    node: Id,
    obligation_status: Id,
) Error!void {
    const input = try e.param(d.returned, 0);
    const frame = try e.param(d.returned, 1);
    const obligation_ref = try e.field(try e.field(frame, 0), 0);
    const record = try e.b.variable(node);
    const changed = try e.b.variable(m.schema);
    const obligation = try e.payload(
        try e.b.reference(record),
        @backingInt(g.NodeTag.obligation),
    );
    const completed = try e.replace(
        obligation,
        3,
        try e.variant(obligation_status, 2, e.unit_value),
    );
    const restored = try root(
        e,
        m,
        try e.b.reference(changed),
        "exit",
        try some(e, try e.field(frame, 2)),
    );
    try e.b.define(d.returned, try e.b.bind(record, try e.call(
        graph.record,
        &.{ input, obligation_ref },
    ), try e.b.bind(changed, try e.call(graph.replace, &.{ input, obligation_ref, try e.variant(
        node,
        @backingInt(g.NodeTag.obligation),
        completed,
    ) }), try e.call(u.position, &.{
        restored,
        try e.field(frame, 1),
        try empty(e),
    }))));
}

fn emitUnlink(
    m: machines.Definition,
    d: Definition,
    e: Author,
    graph: anytype,
    node: Id,
    reason_type: Id,
    null_ref: Id,
) Error!void {
    const bindings = try unlinkBindings(m, d, e, node, reason_type);
    const merge = try mergeUnlinkedExit(
        e,
        graph,
        node,
        bindings.active,
        bindings.selected_reason,
        bindings.selected_cancellation,
        bindings.prior,
        bindings.active_ref,
        bindings.prior_cancellation,
        null_ref,
        bindings.changed,
        bindings.prior_reason,
        bindings.active_node,
    );
    const keep = try e.b.pure(try e.b.reference(bindings.changed));
    const choose = try emitExitCrossingChoose(
        e,
        bindings.prior_reason,
        bindings.prior_cancellation,
        merge,
        keep,
    );
    const replacement = try e.replace(
        bindings.current,
        machines.index(g.Exit, "outer"),
        try field(e, bindings.prior, g.Exit, "outer"),
    );
    const unlink = try e.b.bind(
        bindings.changed,
        try e.call(
            graph.replace,
            &.{
                bindings.input,                                                bindings.cursor,
                try e.variant(node, @backingInt(g.NodeTag.exit), replacement),
            },
        ),
        choose,
    );
    const walk = try e.when(try e.binary(
        .equal,
        try e.field(bindings.outer, 0),
        try e.field(bindings.retired, 0),
    ), unlink, try e.call(d.unlink, &.{ bindings.input, bindings.retired, bindings.outer }));
    var body = try e.b.bind(
        bindings.cursor_node,
        try e.call(graph.record, &.{ bindings.input, bindings.cursor }),
        walk,
    );
    body = try e.b.bind(
        bindings.prior_node,
        try e.call(graph.record, &.{ bindings.input, bindings.retired }),
        body,
    );
    try e.b.define(d.unlink, try e.when(try e.binary(
        .equal,
        try e.field(bindings.cursor, 0),
        try e.field(bindings.retired, 0),
    ), try e.b.pure(bindings.input), body));
}

fn emitCrossed(
    m: machines.Definition,
    d: Definition,
    u: unwind.Definition,
    e: Author,
    graph: anytype,
    node: Id,
    vals: Id,
    obligation_status: Id,
    null_ref: Id,
) Error!void {
    const bindings = try crossedBindings(m, d, e, node, vals, obligation_status);
    var abandoned = try emitExitCrossingAbandoned(
        u,
        e,
        graph,
        node,
        bindings.changed,
        bindings.frame,
        bindings.obligation_ref,
        bindings.discarded,
        bindings.finished,
        bindings.completed_obligation,
    );
    abandoned = try emitCrossedAbandoned(
        m,
        d,
        e,
        bindings.input,
        bindings.prior_ref,
        bindings.changed,
        abandoned,
    );
    abandoned = try e.b.bind(
        bindings.discarded,
        try e.call(u.discarded, &.{bindings.prior}),
        abandoned,
    );
    const failure = try failCrossedObligation(
        m,
        u,
        e,
        graph,
        node,
        bindings.obligation,
        obligation_status,
        bindings.exit,
        bindings.prior,
        null_ref,
        bindings.discarded,
        bindings.changed,
        bindings.prior_ref,
        bindings.finished,
        bindings.frame,
        bindings.input,
        bindings.obligation_ref,
    );
    const select = try emitExitCrossingSelect(e, bindings.exit, abandoned, failure);
    try e.b.define(d.crossed, try e.b.bind(bindings.obligation_node, try e.call(
        graph.record,
        &.{ bindings.input, bindings.obligation_ref },
    ), try e.b.bind(
        bindings.prior_node,
        try e.call(graph.record, &.{ bindings.input, bindings.prior_ref }),
        select,
    )));
}

fn emitCancel(
    m: machines.Definition,
    d: Definition,
    u: unwind.Definition,
    e: Author,
    graph: anytype,
    node: Id,
    ref: Id,
    vals: Id,
    exit_type: Id,
    null_ref: Id,
) Error!void {
    const input = try e.param(d.cancel, 0);
    const cancellation = try e.param(d.cancel, 1);
    const roots = try control.roots(e, m, input);
    const prior_exit = try field(e, roots, g.Roots, "exit");
    const pending = try field(e, roots, g.Roots, "pending");
    const pending_node = try e.b.variable(node);
    const cursor = try e.b.variable(try projection.schema(?g.NodeRef, e.b));
    const choose_cursor = try e.when(try is(e, pending, 0), try e.b.pure(
        try field(e, roots, g.Roots, "current"),
    ), try e.b.bind(pending_node, try e.call(
        graph.record,
        &.{ input, try e.payload(pending, 1) },
    ), try e.b.pure(try some(e, try e.field(try e.payload(
        try e.b.reference(pending_node),
        @backingInt(g.NodeTag.pending),
    ), 2)))));
    const started = try e.b.variable(m.schema);
    const start = try emitExitCrossingStart(
        u,
        e,
        null_ref,
        input,
        cursor,
        prior_exit,
        choose_cursor,
    );
    const root_ref = try e.b.variable(ref);
    const root_node = try e.b.variable(node);
    const exit = try e.payload(try e.b.reference(root_node), @backingInt(g.NodeTag.exit));
    const discarded = try e.b.variable(vals);
    const selected = try e.b.variable(exit_type);
    const select = try selectCancellation(e, exit, cancellation, null_ref, discarded);
    var annotate = try emitExitCrossingAnnotate(
        e,
        graph,
        node,
        select,
        started,
        root_ref,
        selected,
    );
    annotate = try e.b.bind(discarded, try e.call(u.discarded, &.{exit}), annotate);
    var body = try e.b.bind(root_node, try e.call(graph.record, &.{
        try e.b.reference(started), try e.b.reference(root_ref),
    }), try e.when(try is(
        e,
        try field(e, exit, g.Exit, "cancellation"),
        0,
    ), annotate, try e.b.pure(try e.b.reference(started))));
    body = try emitCancelBody(m, u, e, started, root_ref, body);
    try e.b.define(d.cancel, try e.b.bind(started, start, body));
}

fn emitInformationBody(
    e: Author,
    aggregate: anytype,
    exit: Id,
    failures_schema: Id,
    optional: Id,
    failures: Id,
    body: Id,
) Error!Id {
    return try e.b.bind(
        failures,
        try e.call(
            aggregate.construct,
            &.{
                try e.field(try e.b.reference(optional), 0),
                failures_schema,
                e.zero,
                try field(e, exit, g.Exit, "cleanup_failures"),
            },
        ),
        body,
    );
}

fn emitRunBody(
    m: machines.Definition,
    d: Definition,
    e: Author,
    input: Id,
    cleanup: Id,
    changed: Id,
    info: Id,
    body: Id,
) Error!Id {
    return try e.b.bind(
        info,
        try e.call(
            d.information,
            &.{
                try e.b.reference(changed),
                try e.required(try parameters(e, m, input, cleanup), e.zero),
                try e.param(d.run, 3),
            },
        ),
        body,
    );
}

fn emitRunObligation(
    e: Author,
    graph: anytype,
    node: Id,
    obligation_ref: Id,
    frame: Id,
    changed: Id,
    transferred: Id,
    body: Id,
) Error!Id {
    return try e.b.bind(
        changed,
        try e.call(
            graph.replace,
            &.{
                try e.field(try e.b.reference(frame), 0),
                obligation_ref,
                try e.variant(node, @backingInt(g.NodeTag.obligation), transferred),
            },
        ),
        body,
    );
}

fn emitUnlinkMerge(e: Author, selected_reason: Id, prior_reason: Id, merge: Id) Error!Id {
    return try e.b.bind(
        selected_reason,
        try e.when(
            try is(e, prior_reason, 1),
            try e.b.pure(prior_reason),
            try e.b.pure(try e.literal(
                @FieldType(g.Exit, "reason"),
                .cancellation,
            )),
        ),
        merge,
    );
}

fn emitCrossedAbandoned(
    m: machines.Definition,
    d: Definition,
    e: Author,
    input: Id,
    prior_ref: Id,
    changed: Id,
    abandoned: anytype,
) Error!Id {
    return try e.b.bind(
        changed,
        try e.call(
            d.unlink,
            &.{
                input,
                prior_ref,
                try e.payload(try field(e, try control.roots(e, m, input), g.Roots, "exit"), 1),
            },
        ),
        abandoned,
    );
}

fn emitCrossedObligation(
    e: Author,
    graph: anytype,
    node: Id,
    input: Id,
    obligation_ref: Id,
    changed: Id,
    failed_obligation: Id,
    failure: Id,
) Error!Id {
    return try e.b.bind(
        changed,
        try e.call(
            graph.replace,
            &.{
                input,
                obligation_ref,
                try e.variant(node, @backingInt(g.NodeTag.obligation), failed_obligation),
            },
        ),
        failure,
    );
}

fn emitCancelBody(
    m: machines.Definition,
    u: unwind.Definition,
    e: Author,
    started: Id,
    root_ref: Id,
    body: Id,
) Error!Id {
    return try e.b.bind(
        root_ref,
        try e.call(
            u.outermost,
            &.{
                try e.b.reference(started),
                try e.payload(
                    try field(
                        e,
                        try control.roots(e, m, try e.b.reference(started)),
                        g.Roots,
                        "exit",
                    ),
                    1,
                ),
            },
        ),
        body,
    );
}

fn prepareProtectionLoan(
    m: machines.Definition,
    e: Author,
    graph: anytype,
    maybe_ref: Id,
    bindings: ProtectionBindings,
    null_ref: Id,
) Error!struct { loan_pair: Id, loan: Id } {
    const T = @FieldType(data.activation.Terminator, "protect");
    const loan_pair_type = try e.b.schema(.{ .product = &.{ m.schema, maybe_ref } });
    const loan_pair = try e.b.variable(loan_pair_type);
    const loan_node = try e.b.variable(graph.appended);
    const loan_descriptor = try field(e, bindings.operation, T, "loan_region");
    const after_obligation = try e.field(try e.b.reference(bindings.obligation), 0);
    const loan_record = try graphs.record(e, .region, &.{
        try e.payload(loan_descriptor, 1),
        try e.field(bindings.saved, 3),
        try e.literal([]const g.OwnedRef, &.{}),
    });
    const loan = try emitLoan(
        e,
        graph,
        null_ref,
        loan_pair_type,
        loan_node,
        loan_descriptor,
        after_obligation,
        loan_record,
    );
    return .{ .loan_pair = loan_pair, .loan = loan };
}

fn prepareProtectionPrefix(
    m: machines.Definition,
    e: Author,
    graph: anytype,
    vals: Id,
    bindings: ProtectionBindings,
    loan_ref: Id,
    after_loan: Id,
    arguments: Id,
) Error!struct { prefix_pair: Id, prefix: Id } {
    const prefix_pair_type = try e.b.schema(.{ .product = &.{ m.schema, vals } });
    const prefix_pair = try e.b.variable(prefix_pair_type);
    const borrow = try e.b.variable(graph.appended);
    const borrowed_schema = try e.required(try parameters(
        e,
        m,
        bindings.input,
        try e.b.reference(bindings.body_value),
    ), e.zero);
    const owned_resource = try e.payload(try e.b.reference(bindings.resource_value), 1);
    const borrow_record = try graphs.record(e, .borrow, &.{ borrowed_schema, try e.field(
        try e.payload(try e.field(owned_resource, 1), 3),
        0,
    ), try e.payload(loan_ref, 1) });
    const borrowed_value = try graphs.value(
        e,
        borrowed_schema,
        try e.field(try e.b.reference(borrow), 1),
        false,
    );
    const prefix = try emitPrefix(
        e,
        graph,
        bindings.resource_value,
        after_loan,
        arguments,
        prefix_pair_type,
        borrow,
        borrow_record,
        borrowed_value,
    );
    return .{ .prefix_pair = prefix_pair, .prefix = prefix };
}

fn bindProtection(
    m: machines.Definition,
    d: Definition,
    calls: control.Definition,
    e: Author,
    graph: anytype,
    edge: anytype,
    maybe_ref: Id,
    bindings: ProtectionBindings,
    loan_ref: Id,
    prefix_pair: Id,
    prefix: Id,
    arguments: Id,
    loan_pair: Id,
    loan: Id,
) Error!void {
    const T = @FieldType(data.activation.Terminator, "protect");
    const captured = try e.b.variable(m.schema);
    const protection = try e.b.variable(graph.appended);
    const region = try e.b.variable(maybe_ref);
    const protection_record = try emitProtectionRecord(
        e,
        bindings.current,
        bindings.saved,
        bindings.obligation,
        loan_ref,
    );
    var body = try emitBody(
        calls,
        e,
        bindings.saved,
        bindings.body_value,
        loan_ref,
        prefix_pair,
        protection,
        region,
    );
    body = try e.b.bind(protection, try e.call(graph.append, &.{
        try e.b.reference(captured), protection_record,
    }), body);
    body = try e.b.bind(captured, try e.call(calls.capture, &.{
        try e.field(try e.b.reference(prefix_pair), 0),
        bindings.current,
        bindings.saved,
        bindings.frame,
        try field(e, bindings.operation, T, "next"),
    }), body);
    body = try e.b.bind(prefix_pair, prefix, body);
    body = try e.b.bind(arguments, try e.call(edge.collect, &.{
        bindings.frame, try field(e, bindings.operation, T, "arguments"),
    }), body);
    body = try e.b.bind(loan_pair, loan, body);
    body = try e.b.bind(
        bindings.obligation,
        try e.call(graph.append, &.{ bindings.input, bindings.obligation_record }),
        body,
    );
    body = try e.b.bind(bindings.resource_value, bindings.resource, body);
    body = try e.b.bind(bindings.cleanup_value, try e.call(m.frames.read, &.{
        bindings.frame, try field(e, bindings.operation, T, "cleanup"),
    }), body);
    try e.b.define(d.protect, try e.b.bind(bindings.body_value, try e.call(m.frames.read, &.{
        bindings.frame, try field(e, bindings.operation, T, "body"),
    }), body));
}

fn chooseInformationReason(
    e: Author,
    values: anytype,
    aggregate: anytype,
    codec: anytype,
    reason: Id,
    prefix: Id,
    input: Id,
    reason_schema: Id,
    reason_cases: Id,
    raw: Id,
    payload: Id,
    cancellation: Id,
    unit_value: Id,
) Error!Id {
    const reason_kind = try unwind.tag(e, reason);
    const choose_raw = try e.when(
        try is(e, reason, 0),
        try e.b.pure(try e.payload(reason, 0)),
        try e.b.pure(try e.payload(reason, 1)),
    );
    var construct_reason = try emitConstructReason(
        e,
        values,
        aggregate,
        input,
        prefix,
        reason_schema,
        reason_cases,
        raw,
        payload,
        reason_kind,
    );
    construct_reason = try e.b.bind(prefix, try e.call(codec.natural, &.{try e.b.primitive(
        e.integer,
        .blob_length,
        &.{try e.b.reference(raw)},
        0,
    )}), construct_reason);
    construct_reason = try e.b.bind(raw, choose_raw, construct_reason);
    const choose_reason = try e.when(try is(e, cancellation, 0), try e.b.pure(try e.tuple(
        values.result,
        &.{ input, unit_value },
    )), construct_reason);
    return choose_reason;
}

fn bindInformation(
    e: Author,
    d: Definition,
    aggregate: anytype,
    schema: Id,
    failures: Id,
    primary: Id,
    optional: Id,
    exit: Id,
    failures_schema: Id,
    optional_schema: Id,
    cancellation: Id,
    reason_value: Id,
    encoded_reason: Id,
    primary_schema: Id,
    primary_reason: Id,
    primary_value: Id,
    choose_primary: Id,
    choose_reason: Id,
) Error!void {
    var body = try e.call(
        aggregate.construct,
        &.{
            try e.field(try e.b.reference(failures), 0),
            schema,
            e.zero,
            try seq(
                e,
                &.{
                    try e.field(try e.b.reference(primary), 1),
                    try e.field(try e.b.reference(optional), 1),
                    try e.field(try e.b.reference(failures), 1),
                },
            ),
        },
    );
    body = try emitInformationBody(e, aggregate, exit, failures_schema, optional, failures, body);
    body = try e.b.bind(optional, try e.call(aggregate.construct, &.{
        try e.field(try e.b.reference(primary), 0),
        optional_schema,
        try unwind.tag(e, cancellation),
        try seq(e, &.{
            reason_value,
        }),
    }), body);
    body = try e.b.bind(
        primary,
        try e.call(
            aggregate.construct,
            &.{
                try e.field(try e.b.reference(encoded_reason), 0),
                primary_schema,
                try unwind.tag(e, primary_reason),
                try seq(e, &.{try e.b.reference(primary_value)}),
            },
        ),
        body,
    );
    body = try e.b.bind(primary_value, choose_primary, body);
    try e.b.define(d.information, try e.b.bind(encoded_reason, choose_reason, body));
}

fn bindCleanupFrame(
    e: Author,
    d: Definition,
    graph: anytype,
    input: Id,
    protection: Id,
    frame: Id,
    record: Id,
    obligation_ref: Id,
    obligation: Id,
    initial: Id,
) Error!void {
    var body = initial;
    body = try e.b.bind(
        frame,
        try e.call(
            graph.append,
            &.{
                input,
                try graphs.record(
                    e,
                    .cleanup_return,
                    &.{
                        try e.field(protection, 1),
                        try e.field(protection, 2),
                        try e.param(d.run, 2),
                    },
                ),
            },
        ),
        body,
    );
    body = try e.when(try is(e, try e.field(obligation, 3), 0), body, try e.fail());
    try e.b.define(d.run, try e.b.bind(record, try e.call(
        graph.record,
        &.{ input, obligation_ref },
    ), body));
}

fn mergeUnlinkedExit(
    e: Author,
    graph: anytype,
    node: Id,
    active: Id,
    selected_reason: Id,
    selected_cancellation: Id,
    prior: Id,
    active_ref: Id,
    prior_cancellation: Id,
    null_ref: Id,
    changed: Id,
    prior_reason: Id,
    active_node: Id,
) Error!Id {
    var merged = try e.replace(active, 0, try e.b.reference(selected_reason));
    merged = try e.replace(
        merged,
        machines.index(g.Exit, "cancellation"),
        try e.b.reference(selected_cancellation),
    );
    merged = try e.replace(
        merged,
        machines.index(g.Exit, "cleanup_failures"),
        try concat(
            e,
            try field(e, prior, g.Exit, "cleanup_failures"),
            try field(e, active, g.Exit, "cleanup_failures"),
        ),
    );
    merged = try e.replace(merged, machines.index(g.Exit, "stop"), null_ref);
    var merge = try e.call(
        graph.replace,
        &.{
            try e.b.reference(changed),
            active_ref,
            try e.variant(node, @backingInt(g.NodeTag.exit), merged),
        },
    );
    merge = try e.b.bind(
        selected_cancellation,
        try e.when(
            try is(e, prior_cancellation, 0),
            try e.b.pure(try field(e, active, g.Exit, "cancellation")),
            try e.b.pure(prior_cancellation),
        ),
        merge,
    );
    merge = try emitUnlinkMerge(e, selected_reason, prior_reason, merge);
    merge = try e.b.bind(active_node, try e.call(graph.record, &.{
        try e.b.reference(changed), active_ref,
    }), merge);
    return merge;
}

fn failCrossedObligation(
    m: machines.Definition,
    u: unwind.Definition,
    e: Author,
    graph: anytype,
    node: Id,
    obligation: Id,
    obligation_status: Id,
    exit: Id,
    prior: Id,
    null_ref: Id,
    discarded: Id,
    changed: Id,
    prior_ref: Id,
    finished: Id,
    frame: Id,
    input: Id,
    obligation_ref: Id,
) Error!Id {
    const failed_obligation = try e.replace(obligation, 3, try e.variant(
        obligation_status,
        3,
        try e.payload(try e.field(exit, 0), 1),
    ));
    var parent_failed = try e.replace(prior, 0, try e.field(exit, 0));
    parent_failed = try e.replace(parent_failed, machines.index(g.Exit, "stop"), null_ref);
    parent_failed = try e.replace(
        parent_failed,
        machines.index(g.Exit, "discarded"),
        try e.b.reference(discarded),
    );
    const update_parent = try emitExitCrossingUpdateParent(
        u,
        e,
        graph,
        node,
        prior,
        changed,
        prior_ref,
        discarded,
        parent_failed,
    );
    const choose_parent = try emitExitCrossingChooseParent(e, prior, changed, update_parent);
    var failure = try e.b.bind(finished, choose_parent, try e.call(u.position, &.{ try root(
        e,
        m,
        try e.b.reference(finished),
        "exit",
        try some(e, prior_ref),
    ), try e.field(frame, 1), try empty(e) }));
    failure = try emitCrossedObligation(
        e,
        graph,
        node,
        input,
        obligation_ref,
        changed,
        failed_obligation,
        failure,
    );
    return failure;
}

fn selectCancellation(
    e: Author,
    exit: Id,
    cancellation: Id,
    null_ref: Id,
    discarded: Id,
) Error!Id {
    const annotated = try e.replace(exit, machines.index(g.Exit, "cancellation"), try e.variant(
        try projection.schema(?data.invocation.Reason, e.b),
        1,
        cancellation,
    ));
    var replaced = try e.replace(annotated, 0, try e.literal(
        @FieldType(g.Exit, "reason"),
        .cancellation,
    ));
    replaced = try e.replace(replaced, machines.index(g.Exit, "stop"), null_ref);
    replaced = try e.replace(
        replaced,
        machines.index(g.Exit, "discarded"),
        try e.b.reference(discarded),
    );
    const select = try e.when(
        try is(e, try e.field(exit, 0), 0),
        try e.b.pure(replaced),
        try e.when(
            try is(e, try e.field(exit, 0), 3),
            try e.b.pure(replaced),
            try e.b.pure(annotated),
        ),
    );
    return select;
}

fn protectionBindings(
    m: machines.Definition,
    d: Definition,
    e: Author,
    graph: anytype,
    value: Id,
    maybe_value: Id,
    null_value: Id,
    obligation_status: Id,
) Error!ProtectionBindings {
    const input = try e.param(d.protect, 0);
    const current = try e.param(d.protect, 1);
    const saved = try e.param(d.protect, 2);
    const frame = try e.param(d.protect, 3);
    const operation = try e.param(d.protect, 4);
    const T = @FieldType(data.activation.Terminator, "protect");
    const body_value = try e.b.variable(value);
    const cleanup_value = try e.b.variable(value);
    const resource_value = try e.b.variable(maybe_value);
    const read_resource = try e.b.variable(value);
    const resource_slot = try field(e, operation, T, "resource");
    const read = try e.b.bind(read_resource, try e.call(m.frames.read, &.{
        frame, try e.payload(resource_slot, 1),
    }), try e.b.pure(try e.variant(maybe_value, 1, try e.b.reference(read_resource))));
    const resource = try e.when(try is(e, resource_slot, 0), try e.b.pure(null_value), read);
    const obligation = try e.b.variable(graph.appended);
    const obligation_record = try emitObligationRecord(
        e,
        maybe_value,
        obligation_status,
        saved,
        cleanup_value,
        resource_value,
    );
    return .{
        .input = input,
        .current = current,
        .saved = saved,
        .frame = frame,
        .operation = operation,
        .body_value = body_value,
        .cleanup_value = cleanup_value,
        .resource_value = resource_value,
        .resource = resource,
        .obligation = obligation,
        .obligation_record = obligation_record,
    };
}

const ProtectionBindings = struct {
    input: Id,
    current: Id,
    saved: Id,
    frame: Id,
    operation: Id,
    body_value: Id,
    cleanup_value: Id,
    resource_value: Id,
    resource: Id,
    obligation: Id,
    obligation_record: Id,
};

fn informationBindings(
    m: machines.Definition,
    d: Definition,
    e: Author,
    values: anytype,
) Error!InformationBindings {
    const input = try e.param(d.information, 0);
    const schema = try e.param(d.information, 1);
    const exit = try e.param(d.information, 2);
    const catalog = try shapes(e, m, input);
    const product = try e.payload(
        try e.required(catalog, schema),
        @backingInt(data.program.SchemaTag.product),
    );
    const primary_schema = try e.required(product, e.zero);
    const optional_schema = try e.required(product, e.one);
    const failures_schema = try e.required(product, try e.b.constant(u64, 2));
    const primary_cases = try e.payload(
        try e.required(catalog, primary_schema),
        @backingInt(data.program.SchemaTag.sum),
    );
    const unit_schema = try e.required(primary_cases, e.zero);
    const reason_schema = try e.required(primary_cases, try e.b.constant(u64, 2));
    const reason_cases = try e.payload(
        try e.required(catalog, reason_schema),
        @backingInt(data.program.SchemaTag.sum),
    );
    const unit_value = try e.replace(try e.literal(g.Value, .{
        .schema = 0,
        .body = .{ .scalar = @splat(0) },
    }), 0, unit_schema);
    const cancellation = try field(e, exit, g.Exit, "cancellation");
    const reason = try e.payload(cancellation, 1);
    const raw = try e.b.variable(try e.b.schema(.bytes));
    const prefix = try e.b.variable(try e.b.schema(.bytes));
    const payload = try e.b.variable(values.result);
    const encoded_reason = try e.b.variable(values.result);
    return .{
        .input = input,
        .schema = schema,
        .exit = exit,
        .primary_schema = primary_schema,
        .optional_schema = optional_schema,
        .failures_schema = failures_schema,
        .reason_schema = reason_schema,
        .reason_cases = reason_cases,
        .unit_value = unit_value,
        .cancellation = cancellation,
        .reason = reason,
        .raw = raw,
        .prefix = prefix,
        .payload = payload,
        .encoded_reason = encoded_reason,
    };
}

const InformationBindings = struct {
    input: Id,
    schema: Id,
    exit: Id,
    primary_schema: Id,
    optional_schema: Id,
    failures_schema: Id,
    reason_schema: Id,
    reason_cases: Id,
    unit_value: Id,
    cancellation: Id,
    reason: Id,
    raw: Id,
    prefix: Id,
    payload: Id,
    encoded_reason: Id,
};

fn unlinkBindings(
    m: machines.Definition,
    d: Definition,
    e: Author,
    node: Id,
    reason_type: Id,
) Error!UnlinkBindings {
    const input = try e.param(d.unlink, 0);
    const retired = try e.param(d.unlink, 1);
    const cursor = try e.param(d.unlink, 2);
    const prior_node = try e.b.variable(node);
    const prior = try e.payload(try e.b.reference(prior_node), @backingInt(g.NodeTag.exit));
    const cursor_node = try e.b.variable(node);
    const current = try e.payload(try e.b.reference(cursor_node), @backingInt(g.NodeTag.exit));
    const outer = try e.payload(try field(e, current, g.Exit, "outer"), 1);
    const changed = try e.b.variable(m.schema);
    const active_node = try e.b.variable(node);
    const active_ref = try e.payload(try field(
        e,
        try control.roots(e, m, input),
        g.Roots,
        "exit",
    ), 1);
    const active = try e.payload(try e.b.reference(active_node), @backingInt(g.NodeTag.exit));
    const selected_reason = try e.b.variable(reason_type);
    const selected_cancellation = try e.b.variable(
        try projection.schema(?data.invocation.Reason, e.b),
    );
    const prior_reason = try e.field(prior, 0);
    const prior_cancellation = try field(e, prior, g.Exit, "cancellation");
    return .{
        .input = input,
        .retired = retired,
        .cursor = cursor,
        .prior_node = prior_node,
        .prior = prior,
        .cursor_node = cursor_node,
        .current = current,
        .outer = outer,
        .changed = changed,
        .active_node = active_node,
        .active_ref = active_ref,
        .active = active,
        .selected_reason = selected_reason,
        .selected_cancellation = selected_cancellation,
        .prior_reason = prior_reason,
        .prior_cancellation = prior_cancellation,
    };
}

const UnlinkBindings = struct {
    input: Id,
    retired: Id,
    cursor: Id,
    prior_node: Id,
    prior: Id,
    cursor_node: Id,
    current: Id,
    outer: Id,
    changed: Id,
    active_node: Id,
    active_ref: Id,
    active: Id,
    selected_reason: Id,
    selected_cancellation: Id,
    prior_reason: Id,
    prior_cancellation: Id,
};

fn crossedBindings(
    m: machines.Definition,
    d: Definition,
    e: Author,
    node: Id,
    vals: Id,
    obligation_status: Id,
) Error!CrossedBindings {
    const input = try e.param(d.crossed, 0);
    const frame = try e.param(d.crossed, 1);
    const exit = try e.param(d.crossed, 2);
    const obligation_ref = try e.field(try e.field(frame, 0), 0);
    const prior_ref = try e.field(frame, 2);
    const obligation_node = try e.b.variable(node);
    const obligation = try e.payload(
        try e.b.reference(obligation_node),
        @backingInt(g.NodeTag.obligation),
    );
    const prior_node = try e.b.variable(node);
    const prior = try e.payload(try e.b.reference(prior_node), @backingInt(g.NodeTag.exit));
    const discarded = try e.b.variable(vals);
    const changed = try e.b.variable(m.schema);
    const finished = try e.b.variable(m.schema);
    const completed_obligation = try e.replace(
        obligation,
        3,
        try e.variant(obligation_status, 2, e.unit_value),
    );
    return .{
        .input = input,
        .frame = frame,
        .exit = exit,
        .obligation_ref = obligation_ref,
        .prior_ref = prior_ref,
        .obligation_node = obligation_node,
        .prior_node = prior_node,
        .prior = prior,
        .obligation = obligation,
        .discarded = discarded,
        .changed = changed,
        .finished = finished,
        .completed_obligation = completed_obligation,
    };
}

const CrossedBindings = struct {
    input: Id,
    frame: Id,
    exit: Id,
    obligation_ref: Id,
    prior_ref: Id,
    obligation_node: Id,
    prior_node: Id,
    prior: Id,
    obligation: Id,
    discarded: Id,
    changed: Id,
    finished: Id,
    completed_obligation: Id,
};

fn applyCleanup(
    m: machines.Definition,
    calls: control.Definition,
    e: Author,
    vals: Id,
    info: Id,
    resource: Id,
    cleanup: Id,
    frame: Id,
    protection: Id,
) Error!Id {
    const arguments = try e.b.variable(vals);
    const base_args = try seq(e, &.{try e.field(try e.b.reference(info), 1)});
    const body = try e.b.bind(
        arguments,
        try e.when(
            try is(e, resource, 0),
            try e.b.pure(base_args),
            try e.b.pure(try concat(e, base_args, try seq(e, &.{try e.payload(resource, 1)}))),
        ),
        try e.call(calls.apply, &.{ try status(
            e,
            m,
            try e.field(try e.b.reference(info), 0),
            .active,
        ), cleanup, try e.b.reference(arguments), try some(
            e,
            try e.field(try e.b.reference(frame), 1),
        ), try e.field(protection, 3), try e.field(protection, 4) }),
    );
    return body;
}
