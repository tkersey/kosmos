//! Guest handler installation, effect capture, and resumption in Horos.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const graphs = @import("graph.zig");
const captures = @import("captures.zig");
const access = @import("edges.zig");
const tables = @import("table.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const p = data.program;
const ir = data.activation;
const field = access.field;
pub const Calls = struct { enter: Id, apply: Id, capture: Id, resume_continuation: Id };
pub const Definition = struct { install: Id, perform: Id, resume_control: Id };

pub fn define(b: *source.Builder, m: machines.Definition, calls: Calls) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.handlers/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const tokens = try captures.define(b, m);
    const edge = try access.define(b, m);
    const ref_type = try projection.schema(g.NodeRef, b);
    const optional_ref = try projection.schema(?g.NodeRef, b);
    const value = try projection.schema(g.Value, b);
    const values = try projection.schema([]const g.Value, b);
    const control_type = try projection.schema(g.Control, b);
    const node = try projection.schema(g.Node, b);
    const d: Definition = .{
        .install = try b.declare(
            &.{
                m.schema,
                ref_type,
                control_type,
                m.frames.schema,
                try projection.schema(@FieldType(ir.Terminator, "handle"), b),
            },
            m.schema,
            &.{},
            &.{},
        ),
        .perform = try b.declare(&.{
            m.schema, ref_type, control_type, m.frames.schema, try projection.schema(ir.Perform, b),
        }, m.schema, &.{}, &.{}),
        .resume_control = try b.declare(&.{
            m.schema,                                ref_type, control_type, m.frames.schema,
            try projection.schema(ir.Terminator, b),
        }, m.schema, &.{}, &.{}),
    };
    const ctx: Context = .{
        .m = m,
        .calls = calls,
        .e = e,
        .graph = graph,
        .tokens = tokens,
        .edge = edge,
        .ref_type = ref_type,
        .optional_ref = optional_ref,
        .value = value,
        .values = values,
        .node = node,
        .d = d,
    };
    const capability_arguments = try b.declare(&.{
        try projection.schema([]const Id, b),
        e.integer,
        ref_type,
        e.integer,
        (try tables.define(b, value)).table,
    }, values, &.{}, &.{});
    const list = try tables.define(b, value);
    try emitCapabilityArguments(e, capability_arguments, list);
    try emitInstall(ctx, capability_arguments, list);
    try emitHandlerControls(ctx);
    return cache.finish(b, d);
}
fn is(e: Author, record: Id, tag: g.NodeTag) Error!Id {
    return e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{record},
        0,
    ), try e.b.constant(u64, @backingInt(tag)));
}

fn emitCapabilityArguments(
    e: Author,
    capability_arguments: Id,
    list: tables.Definition,
) Error!void {
    const types = try e.param(capability_arguments, 0);
    const count = try e.param(capability_arguments, 1);
    const ref = try e.param(capability_arguments, 2);
    const index = try e.param(capability_arguments, 3);
    const prior = try e.param(capability_arguments, 4);
    const appended = try e.b.variable(list.table);
    const next = try e.b.bind(appended, try e.call(list.append, &.{ prior, try graphs.value(
        e,
        try e.required(types, index),
        ref,
        false,
    ) }), try e.call(capability_arguments, &.{
        types, count, ref, try e.binary(.integer_add, index, e.one), try e.b.reference(appended),
    }));
    try e.b.define(capability_arguments, try e.when(
        try e.binary(.less, index, count),
        next,
        try e.call(list.to_sequence, &.{prior}),
    ));
}

fn emitInstall(
    ctx: Context,
    capability_arguments: Id,
    list: tables.Definition,
) Error!void {
    const e = ctx.e;
    const input = try e.param(ctx.d.install, 0);
    const current = try e.param(ctx.d.install, 1);
    const control = try e.param(ctx.d.install, 2);
    const frame = try e.param(ctx.d.install, 3);
    const operation = try e.param(ctx.d.install, 4);
    const T = @FieldType(ir.Terminator, "handle");
    const program = try ctx.m.field(e, input, .program);
    const code = try access.code(e, program);
    const definition = try e.required(
        try field(e, code, ir.Program, "handlers"),
        try field(e, operation, T, "handler"),
    );
    const state = try e.b.variable(ctx.values);
    const body = try e.b.variable(ctx.value);
    const arguments = try e.b.variable(ctx.values);
    const handler = try e.b.variable(ctx.graph.appended);
    const captured = try e.b.variable(ctx.m.schema);
    const attachment = try e.b.variable(ctx.graph.appended);
    const capabilities = try e.b.variable(ctx.values);
    const attachment_ref = try e.field(try e.b.reference(attachment), 1);
    const signature = try e.payload(try e.payload(try e.required(
        try field(e, code, ir.Program, "schemas"),
        try e.field(try e.b.reference(body), 0),
    ), @backingInt(p.SchemaTag.internal)), @backingInt(p.InternalTag.computation));
    const parent = try e.variant(ctx.optional_ref, 1, attachment_ref);
    var install = try emitInstallInstall(
        ctx.calls,
        e,
        ctx.values,
        control,
        body,
        arguments,
        attachment,
        capabilities,
        parent,
    );
    install = try bindCapabilities(
        e,
        capability_arguments,
        signature,
        definition,
        attachment_ref,
        list,
        capabilities,
        install,
    );
    try bindInstalledHandler(
        ctx,
        current,
        control,
        handler,
        captured,
        attachment,
        frame,
        operation,
        input,
        arguments,
        body,
        state,
        install,
    );
}

fn emitInScope(
    e: Author,
    graph: graphs.Definition,
    optional_ref: Id,
    node: Id,
    in_scope: Id,
) Error!void {
    const input = try e.param(in_scope, 0);
    const ref = try e.payload(try e.param(in_scope, 1), 1);
    const target = try e.param(in_scope, 2);
    const record_var = try e.b.variable(node);
    const record = try e.b.reference(record_var);
    var visit = try e.fail();
    inline for ([_]g.NodeTag{
        .continuation,
        .attachment,
        .region_scope,
        .injection,
        .protection,
        .cleanup_return,
        .disposal_return,
    }) |tag| {
        const T = @FieldType(g.Node, @tagName(tag));
        const payload = try e.payload(record, @backingInt(tag));
        const parent = if (tag == .injection) try e.variant(
            optional_ref,
            1,
            try e.field(payload, 0),
        ) else try field(
            e,
            payload,
            T,
            if (tag == .continuation or
                tag == .cleanup_return or tag == .disposal_return) "parent" else "return_to",
        );
        visit = try e.when(try is(e, record, tag), try e.call(
            in_scope,
            &.{ input, parent, target },
        ), visit);
    }
    try e.b.define(in_scope, try e.when(try e.binary(
        .equal,
        try e.field(ref, 0),
        try e.field(target, 0),
    ), try e.b.pure(e.unit_value), try e.b.bind(
        record_var,
        try e.call(graph.record, &.{ input, ref }),
        visit,
    )));
}

fn emitFindClause(e: Author, find_clause: Id) Error!void {
    const clauses = try e.param(find_clause, 0);
    const pair_type = try e.b.schema(.{ .product = &.{
        try projection.schema(ir.Clause, e.b), try projection.schema([]const ir.Clause, e.b),
    } });
    const optional = try e.b.schema(.{ .sum = &.{ e.unit, pair_type } });
    const pair = try e.payload(try e.b.primitive(optional, .sequence_pop, &.{clauses}, 0), 1);
    const head = try e.field(pair, 0);
    const effect = try e.param(find_clause, 1);
    try e.b.define(find_clause, try e.when(try e.binary(
        .equal,
        try field(e, head, ir.Clause, "effect"),
        effect,
    ), try e.b.pure(head), try e.call(find_clause, &.{ try e.field(pair, 1), effect })));
}

fn emitPerform(
    ctx: Context,
    in_scope: Id,
    find_clause: Id,
) Error!void {
    const e = ctx.e;
    const input = try e.param(ctx.d.perform, 0);
    const current = try e.param(ctx.d.perform, 1);
    const control = try e.param(ctx.d.perform, 2);
    const frame = try e.param(ctx.d.perform, 3);
    const operation = try e.param(ctx.d.perform, 4);
    const program = try ctx.m.field(e, input, .program);
    const code = try access.code(e, program);
    const payload_var = try e.b.variable(ctx.value);
    const payload = try e.b.reference(payload_var);
    const captured = try e.b.variable(ctx.m.schema);
    const pending = try e.b.variable(ctx.graph.appended);
    const external = try externalEffect(
        ctx,
        operation,
        payload,
        pending,
        captured,
        input,
        current,
        control,
        frame,
    );
    const local = try prepareLocalEffect(ctx, code, payload);
    const tail = try emitPerformTail(
        ctx.calls,
        e,
        ctx.optional_ref,
        input,
        current,
        control,
        frame,
        operation,
        captured,
        local.handler,
        local.clause,
        local.state_and_payload,
    );
    const general = try generalEffect(
        ctx,
        code,
        current,
        control,
        captured,
        input,
        frame,
        operation,
        local,
    );
    try bindLocalEffect(
        ctx,
        tail,
        general,
        find_clause,
        operation,
        input,
        in_scope,
        control,
        frame,
        payload_var,
        external,
        local,
    );
}

fn emitResumeControl(
    ctx: Context,
) Error!void {
    const e = ctx.e;
    const input = try e.param(ctx.d.resume_control, 0);
    const current = try e.param(ctx.d.resume_control, 1);
    const control = try e.param(ctx.d.resume_control, 2);
    const frame = try e.param(ctx.d.resume_control, 3);
    const term = try e.param(ctx.d.resume_control, 4);
    const info = @typeInfo(ir.Terminator).@"union";
    const term_schema = try projection.schema(ir.Terminator, e.b);
    const Case = @import("std").meta.Elem(@FieldType(
        @FieldType(source.ast.Term, "match_sum"),
        "cases",
    ));
    var cases: [info.field_names.len]Case = undefined;
    inline for (info.field_names, 0..) |name, i| {
        const variable = try e.b.variable(e.b.schemas.items[@intCast(term_schema)].sum[i]);
        const operation = try e.b.reference(variable);
        const T = @FieldType(ir.Terminator, name);
        const tag: p.TerminatorTag = @field(p.TerminatorTag, name);
        var body = try e.fail();
        if (tag == .resume_value or tag == .resume_with or tag == .resume_computation) {
            body = try resumeOperation(
                ctx,
                input,
                current,
                control,
                frame,
                operation,
                T,
                tag,
                body,
            );
        }
        cases[i] = .{ .variable = variable, .body = body };
    }
    try e.b.define(ctx.d.resume_control, try e.b.term(.{
        .match_sum = .{ .value = term, .cases = &cases },
    }));
}

fn emitInstallInstall(
    calls: Calls,
    e: Author,
    values: Id,
    control: Id,
    body: Id,
    arguments: Id,
    attachment: Id,
    capabilities: Id,
    parent: Id,
) Error!Id {
    return try e.call(
        calls.apply,
        &.{
            try e.field(try e.b.reference(attachment), 0),
            try e.b.reference(body),
            try e.b.primitive(
                values,
                .sequence_concat,
                &.{ try e.b.reference(capabilities), try e.b.reference(arguments) },
                0,
            ),
            parent,
            parent,
            try e.field(control, 3),
        },
    );
}

fn emitInstallAttachmentRecord(
    e: Author,
    optional_ref: Id,
    current: Id,
    control: Id,
    handler: Id,
) Error!Id {
    return try graphs.record(
        e,
        .attachment,
        &.{
            try e.field(try e.b.reference(handler), 1),
            try e.field(control, 2),
            try e.variant(optional_ref, 1, current),
            try e.literal(@FieldType(
                @FieldType(g.Node, "attachment"),
                "phase",
            ), .active),
            try e.field(control, 3),
        },
    );
}

fn emitInstallHandlerRecord(e: Author, control: Id, operation: Id, T: anytype, state: Id) Error!Id {
    return try graphs.record(e, .handler, &.{
        try field(e, operation, T, "handler"),
        try e.b.reference(state),
        try e.field(control, 2),
        try e.field(control, 3),
    });
}

fn emitPerformTail(
    calls: Calls,
    e: Author,
    optional_ref: Id,
    input: Id,
    current: Id,
    control: Id,
    frame: Id,
    operation: Id,
    captured: Id,
    handler: Id,
    clause: Id,
    state_and_payload: Id,
) Error!Id {
    return try e.b.bind(captured, try e.call(calls.capture, &.{
        input, current, control, frame, try field(e, operation, ir.Perform, "next"),
    }), try e.call(calls.enter, &.{
        try e.b.reference(captured),
        try field(e, clause, ir.Clause, "function"),
        state_and_payload,
        try e.variant(optional_ref, 1, current),
        try e.field(handler, 2),
        try e.field(handler, 3),
    }));
}

fn emitPerformCapture(
    e: Author,
    optional_ref: Id,
    current: Id,
    control: Id,
    selected: Id,
    use_site: Id,
    token_schema: Id,
) Error!Id {
    return try e.tuple(try projection.schema(g.Capture, e.b), &.{
        token_schema,
        try e.variant(optional_ref, 1, current),
        try e.b.reference(selected),
        try e.field(control, 2),
        try e.b.reference(use_site),
    });
}

fn emitPerformArgs(
    b: *source.Builder,
    values: Id,
    state_and_payload: Id,
    bodies: Id,
    token_value: Id,
) Error!Id {
    return try b.primitive(
        values,
        .sequence_concat,
        &.{
            try b.primitive(
                values,
                .sequence_concat,
                &.{ state_and_payload, try b.reference(bodies) },
                0,
            ),
            try b.primitive(values, .sequence, &.{try b.reference(token_value)}, 0),
        },
        0,
    );
}

fn emitPerformGeneral(
    calls: Calls,
    e: Author,
    attachment: Id,
    handler: Id,
    clause: Id,
    changed: Id,
    args: Id,
) Error!Id {
    return try e.call(calls.enter, &.{
        try e.b.reference(changed),
        try field(e, clause, ir.Clause, "function"),
        args,
        try e.field(attachment, 2),
        try e.field(handler, 2),
        try e.field(handler, 3),
    });
}

fn emitResumeControlRecord(e: Author, control: Id, operation: Id, T: anytype, state: Id) Error!Id {
    return try graphs.record(e, .handler, &.{
        try field(e, operation, T, "handler"),
        try e.b.reference(state),
        try e.field(control, 2),
        try e.field(control, 3),
    });
}

fn emitResumeControlAttachment(
    e: Author,
    optional_ref: Id,
    current: Id,
    control: Id,
    handler: Id,
) Error!Id {
    return try graphs.record(
        e,
        .attachment,
        &.{
            try e.field(try e.b.reference(handler), 1),
            try e.field(control, 2),
            try e.variant(optional_ref, 1, current),
            try e.literal(@FieldType(
                @FieldType(g.Node, "attachment"),
                "phase",
            ), .active),
            try e.field(control, 3),
        },
    );
}

fn emitPerformPerformDefinition(
    m: machines.Definition,
    e: Author,
    d: Definition,
    frame: Id,
    operation: Id,
    payload_var: Id,
    external: Id,
    cap_slot: Id,
    local: Id,
    absent: Id,
) Error!void {
    try e.b.define(
        d.perform,
        try e.b.bind(
            payload_var,
            try e.call(
                m.frames.read,
                &.{ frame, try field(e, operation, ir.Perform, "payload") },
            ),
            try e.b.term(.{ .match_sum = .{ .value = try field(
                e,
                operation,
                ir.Perform,
                "capability",
            ), .cases = &.{ .{ .variable = absent, .body = external }, .{
                .variable = cap_slot,
                .body = local,
            } } } }),
        ),
    );
}

fn emitPerformAttachment(
    e: Author,
    graph: graphs.Definition,
    node: Id,
    selected: Id,
    token: Id,
    changed: Id,
    general: anytype,
    suspended: Id,
) Error!Id {
    return try e.b.bind(
        changed,
        try e.call(
            graph.replace,
            &.{
                try e.field(try e.b.reference(token), 0),
                try e.b.reference(selected),
                try e.variant(node, @backingInt(g.NodeTag.attachment), suspended),
            },
        ),
        general,
    );
}

fn emitResumeControlBody(
    calls: Calls,
    e: Author,
    graph: graphs.Definition,
    token: Id,
    argument: Id,
    captured: Id,
    capture_ref: Id,
    handler: Id,
    changed: Id,
    record: anytype,
    attachment: anytype,
) Error!Id {
    return try e.b.bind(handler, try e.call(graph.append, &.{
        try e.b.reference(captured), record,
    }), try e.b.bind(changed, try e.call(graph.replace, &.{
        try e.field(try e.b.reference(handler), 0),
        try field(e, token, g.Capture, "delimiter"),
        attachment,
    }), try e.call(calls.resume_continuation, &.{
        try e.b.reference(changed), capture_ref, try e.b.reference(argument),
    })));
}

fn emitResumeControlContinuation(
    calls: Calls,
    e: Author,
    graph: graphs.Definition,
    optional_ref: Id,
    token: Id,
    argument: Id,
    capture_ref: Id,
    record: anytype,
    prepared: Id,
    machine: Id,
    saved: Id,
    injection: Id,
) Error!Id {
    return try e.b.bind(saved, try e.call(
        graph.record,
        &.{ machine, capture_ref },
    ), try e.b.bind(injection, try e.call(graph.append, &.{ machine, record }), try e.call(
        calls.apply,
        &.{
            try e.field(try e.b.reference(injection), 0),
            try e.b.reference(argument),
            try field(e, token, g.Capture, "use_site_capabilities"),
            try e.variant(optional_ref, 1, try e.field(try e.b.reference(injection), 1)),
            try e.field(try e.b.reference(prepared), 1),
            try e.field(try e.payload(
                try e.b.reference(saved),
                @backingInt(g.NodeTag.continuation),
            ), 3),
        },
    )));
}

fn emitHandlerControls(
    ctx: Context,
) Error!void {
    const e = ctx.e;
    const in_scope = try e.b.declare(
        &.{ ctx.m.schema, ctx.optional_ref, ctx.ref_type },
        e.unit,
        &.{},
        &.{},
    );
    try emitInScope(e, ctx.graph, ctx.optional_ref, ctx.node, in_scope);
    const find_clause = try e.b.declare(&.{
        try projection.schema([]const ir.Clause, e.b), e.integer,
    }, try projection.schema(ir.Clause, e.b), &.{}, &.{});
    try emitFindClause(e, find_clause);
    try emitPerform(ctx, in_scope, find_clause);
    try emitResumeControl(ctx);
}

fn bindCapabilities(
    e: Author,
    capability_arguments: Id,
    signature: Id,
    definition: Id,
    attachment_ref: Id,
    list: tables.Definition,
    capabilities: Id,
    install: Id,
) Error!Id {
    var install_result = install;
    install_result = try e.b.bind(capabilities, try e.call(capability_arguments, &.{ try field(
        e,
        signature,
        p.ComputationType,
        "parameters",
    ), try e.b.primitive(e.integer, .sequence_length, &.{try field(
        e,
        definition,
        ir.Handler,
        "clauses",
    )}, 0), attachment_ref, e.zero, try list.empty(e.b) }), install_result);
    return install_result;
}

fn bindInstalledHandler(
    ctx: Context,
    current: Id,
    control: Id,
    handler: Id,
    captured: Id,
    attachment: Id,
    frame: Id,
    operation: Id,
    input: Id,
    arguments: Id,
    body: Id,
    state: Id,
    next: Id,
) Error!void {
    const e = ctx.e;
    const T = @FieldType(ir.Terminator, "handle");
    var install = next;
    const attachment_record = try emitInstallAttachmentRecord(
        e,
        ctx.optional_ref,
        current,
        control,
        handler,
    );
    install = try e.b.bind(attachment, try e.call(ctx.graph.append, &.{
        try e.b.reference(captured), attachment_record,
    }), install);
    install = try e.b.bind(captured, try e.call(ctx.calls.capture, &.{
        try e.field(try e.b.reference(handler), 0),
        current,
        control,
        frame,
        try field(e, operation, T, "next"),
    }), install);
    const handler_record = try emitInstallHandlerRecord(e, control, operation, T, state);
    install = try e.b.bind(handler, try e.call(
        ctx.graph.append,
        &.{ input, handler_record },
    ), install);
    install = try e.b.bind(arguments, try e.call(ctx.edge.collect, &.{
        frame, try field(e, operation, T, "arguments"),
    }), install);
    install = try e.b.bind(body, try e.call(ctx.m.frames.read, &.{
        frame, try field(e, operation, T, "body"),
    }), install);
    install = try e.b.bind(state, try e.call(ctx.edge.collect, &.{
        frame, try field(e, operation, T, "state"),
    }), install);
    try e.b.define(ctx.d.install, install);
}

fn externalEffect(
    ctx: Context,
    operation: Id,
    payload: Id,
    pending: Id,
    captured: Id,
    input: Id,
    current: Id,
    control: Id,
    frame: Id,
) Error!Id {
    const e = ctx.e;
    const pending_record = try graphs.record(e, .pending, &.{
        try field(e, operation, ir.Perform, "effect"),
        payload,
        current,
        try e.field(control, 0),
    });
    const pending_machine = try e.field(try e.b.reference(pending), 0);
    var pending_roots = try @import("control.zig").roots(e, ctx.m, pending_machine);
    pending_roots = try e.replace(
        pending_roots,
        machines.index(g.Roots, "current"),
        try e.literal(?g.NodeRef, null),
    );
    pending_roots = try e.replace(
        pending_roots,
        machines.index(g.Roots, "pending"),
        try e.variant(ctx.optional_ref, 1, try e.field(try e.b.reference(pending), 1)),
    );
    var parked = try @import("control.zig").withRoots(e, pending_machine, pending_roots);
    parked = try e.replace(parked, @backingInt(machines.Field.header), try e.replace(
        try ctx.m.field(e, parked, .header),
        machines.index(machines.Header, "status"),
        try e.literal(data.process_state.Status, .parked),
    ));
    const external = try e.b.bind(captured, try e.call(ctx.calls.capture, &.{
        input, current, control, frame, try field(e, operation, ir.Perform, "next"),
    }), try e.b.bind(pending, try e.call(ctx.graph.append, &.{
        try e.b.reference(captured), pending_record,
    }), try e.b.pure(parked)));
    return external;
}

fn generalEffect(
    ctx: Context,
    code: Id,
    current: Id,
    control: Id,
    captured: Id,
    input: Id,
    frame: Id,
    operation: Id,
    local_effect: LocalEffect,
) Error!Id {
    const e = ctx.e;
    const capture_terms = try captureTerms(ctx, code, current, control, captured, local_effect);
    const args = try emitPerformArgs(
        e.b,
        ctx.values,
        local_effect.state_and_payload,
        capture_terms.bodies,
        capture_terms.token_value,
    );
    var general = try emitPerformGeneral(
        ctx.calls,
        e,
        local_effect.attachment,
        local_effect.handler,
        local_effect.clause,
        capture_terms.changed,
        args,
    );
    var suspended = try e.replace(local_effect.attachment, 2, try e.literal(?g.NodeRef, null));
    suspended = try e.replace(suspended, 3, try e.literal(@FieldType(
        @FieldType(g.Node, "attachment"),
        "phase",
    ), .suspended));
    general = try emitPerformAttachment(
        e,
        ctx.graph,
        ctx.node,
        local_effect.selected,
        capture_terms.token,
        capture_terms.changed,
        general,
        suspended,
    );
    return bindCapturedEffect(
        ctx,
        input,
        current,
        control,
        frame,
        operation,
        captured,
        capture_terms,
        general,
    );
}

fn bindLocalEffect(
    ctx: Context,
    tail: Id,
    general: Id,
    find_clause: Id,
    operation: Id,
    input: Id,
    in_scope: Id,
    control: Id,
    frame: Id,
    payload_var: Id,
    external: Id,
    local_effect: LocalEffect,
) Error!void {
    const e = ctx.e;
    const strategy = try field(e, local_effect.clause, ir.Clause, "strategy");
    var local = try e.when(try e.binary(.equal, try e.b.primitive(
        try e.b.scalar(u32),
        .enum_tag,
        &.{strategy},
        0,
    ), try e.b.constant(u32, 2)), tail, general);
    local = try e.b.bind(local_effect.clause_var, try e.call(find_clause, &.{ try field(
        e,
        local_effect.definition,
        ir.Handler,
        "clauses",
    ), try field(e, operation, ir.Perform, "effect") }), local);
    local = try e.b.bind(local_effect.handler_var, try e.call(ctx.graph.record, &.{
        input, try e.field(local_effect.attachment, 0),
    }), local);
    const phase = try e.field(local_effect.attachment, 3);
    local = try e.when(try e.binary(.equal, try e.b.primitive(
        try e.b.scalar(u32),
        .enum_tag,
        &.{phase},
        0,
    ), try e.b.constant(u32, 0)), local, try e.fail());
    local = try e.b.bind(local_effect.attachment_var, try e.call(
        ctx.graph.record,
        &.{ input, try e.b.reference(local_effect.selected) },
    ), local);
    local = try e.b.bind(local_effect.scoped, try e.call(in_scope, &.{
        input, try e.field(control, 1), try e.b.reference(local_effect.selected),
    }), local);
    local = try e.b.bind(local_effect.selected, try e.call(
        ctx.graph.value_ref,
        &.{try e.b.reference(local_effect.cap_value)},
    ), local);
    local = try e.b.bind(local_effect.cap_value, try e.call(
        ctx.m.frames.read,
        &.{ frame, try e.b.reference(local_effect.cap_slot) },
    ), local);
    const absent = try e.b.variable(e.unit);
    try emitPerformPerformDefinition(
        ctx.m,
        e,
        ctx.d,
        frame,
        operation,
        payload_var,
        external,
        local_effect.cap_slot,
        local,
        absent,
    );
}

fn resumeOperation(
    ctx: Context,
    input: Id,
    current: Id,
    control: Id,
    frame: Id,
    operation: Id,
    comptime T: type,
    comptime tag: anytype,
    body: Id,
) Error!Id {
    const e = ctx.e;
    var body_result = body;
    const token_value = try e.b.variable(ctx.value);
    const taken = try e.b.variable(ctx.tokens.taken);
    const token = try e.field(try e.b.reference(taken), 1);
    const argument = try e.b.variable(ctx.value);
    const captured = try e.b.variable(ctx.m.schema);
    const state = try e.b.variable(ctx.values);
    const capture_ref = try e.payload(try field(e, token, g.Capture, "capture"), 1);
    body_result = try resumePath(
        ctx,
        current,
        control,
        operation,
        T,
        tag,
        token,
        argument,
        captured,
        state,
        capture_ref,
        body_result,
    );
    body_result = try e.b.bind(captured, try e.call(ctx.calls.capture, &.{
        try e.field(try e.b.reference(taken), 0),
        current,
        control,
        frame,
        try field(e, operation, T, "next"),
    }), body_result);
    if (tag == .resume_with) body_result = try e.b.bind(state, try e.call(ctx.edge.collect, &.{
        frame, try field(e, operation, T, "state"),
    }), body_result);
    body_result = try e.b.bind(argument, try e.call(ctx.m.frames.read, &.{ frame, try field(
        e,
        operation,
        T,
        if (tag == .resume_computation) "computation" else "argument",
    ) }), body_result);
    body_result = try e.b.bind(taken, try e.call(ctx.tokens.take, &.{
        input, try e.b.reference(token_value),
    }), body_result);
    body_result = try e.b.bind(token_value, try e.call(ctx.m.frames.read, &.{
        frame, try field(e, operation, T, "resumption"),
    }), body_result);
    return body_result;
}

const Context = struct {
    m: machines.Definition,
    calls: Calls,
    e: Author,
    graph: graphs.Definition,
    tokens: captures.Definition,
    edge: access.Definition,
    ref_type: Id,
    optional_ref: Id,
    value: Id,
    values: Id,
    node: Id,
    d: Definition,
};

const LocalEffect = struct {
    cap_slot: Id,
    cap_value: Id,
    selected: Id,
    scoped: Id,
    attachment_var: Id,
    handler_var: Id,
    attachment: Id,
    handler: Id,
    definition: Id,
    clause_var: Id,
    clause: Id,
    state_and_payload: Id,
};

fn prepareLocalEffect(ctx: Context, code: Id, payload: Id) Error!LocalEffect {
    const e = ctx.e;
    const cap_slot = try e.b.variable(e.integer);
    const cap_value = try e.b.variable(ctx.value);
    const selected = try e.b.variable(ctx.ref_type);
    const scoped = try e.b.variable(e.unit);
    const attachment_var = try e.b.variable(ctx.node);
    const handler_var = try e.b.variable(ctx.node);
    const attachment = try e.payload(
        try e.b.reference(attachment_var),
        @backingInt(g.NodeTag.attachment),
    );
    const handler = try e.payload(try e.b.reference(handler_var), @backingInt(g.NodeTag.handler));
    const definition = try e.required(
        try field(e, code, ir.Program, "handlers"),
        try e.field(handler, 0),
    );
    const clause_var = try e.b.variable(try projection.schema(ir.Clause, e.b));
    const clause = try e.b.reference(clause_var);
    const state_and_payload = try e.b.primitive(ctx.values, .sequence_concat, &.{
        try e.field(handler, 1), try e.b.primitive(ctx.values, .sequence, &.{payload}, 0),
    }, 0);
    return .{
        .cap_slot = cap_slot,
        .cap_value = cap_value,
        .selected = selected,
        .scoped = scoped,
        .attachment_var = attachment_var,
        .handler_var = handler_var,
        .attachment = attachment,
        .handler = handler,
        .definition = definition,
        .clause_var = clause_var,
        .clause = clause,
        .state_and_payload = state_and_payload,
    };
}

fn bindCapturedEffect(
    ctx: Context,
    input: Id,
    current: Id,
    control: Id,
    frame: Id,
    operation: Id,
    captured: Id,
    capture_terms: CaptureTerms,
    next: Id,
) Error!Id {
    const e = ctx.e;
    var general = next;
    general = try e.b.bind(capture_terms.token_value, capture_terms.choose_value, general);
    general = try e.b.bind(capture_terms.token, capture_terms.choose_token, general);
    general = try e.b.bind(captured, try e.call(ctx.calls.capture, &.{
        input, current, control, frame, try field(e, operation, ir.Perform, "next"),
    }), general);
    general = try e.b.bind(capture_terms.multi, try e.b.pure(capture_terms.is_multi), general);
    general = try e.b.bind(capture_terms.bodies, try e.call(ctx.edge.collect, &.{
        frame, try field(e, operation, ir.Perform, "bodies"),
    }), general);
    general = try e.b.bind(capture_terms.use_site, try e.call(
        ctx.edge.collect,
        &.{ frame, try field(e, operation, ir.Perform, "use_site_capabilities") },
    ), general);
    return general;
}

fn resumePath(
    ctx: Context,
    current: Id,
    control: Id,
    operation: Id,
    comptime T: type,
    comptime tag: p.TerminatorTag,
    token: Id,
    argument: Id,
    captured: Id,
    state: Id,
    capture_ref: Id,
    next: Id,
) Error!Id {
    const e = ctx.e;
    var body_result = next;
    if (tag == .resume_with) {
        const handler = try e.b.variable(ctx.graph.appended);
        const changed = try e.b.variable(ctx.m.schema);
        const record = try emitResumeControlRecord(e, control, operation, T, state);
        const attachment = try emitResumeControlAttachment(
            e,
            ctx.optional_ref,
            current,
            control,
            handler,
        );
        body_result = try emitResumeControlBody(
            ctx.calls,
            e,
            ctx.graph,
            token,
            argument,
            captured,
            capture_ref,
            handler,
            changed,
            record,
            attachment,
        );
    } else {
        const prepared = try e.b.variable(ctx.tokens.prepared);
        const machine = try e.field(try e.b.reference(prepared), 0);
        if (tag == .resume_computation) {
            const saved = try e.b.variable(ctx.node);
            const injection = try e.b.variable(ctx.graph.appended);
            const record = try graphs.record(e, .injection, &.{capture_ref});
            body_result = try emitResumeControlContinuation(
                ctx.calls,
                e,
                ctx.graph,
                ctx.optional_ref,
                token,
                argument,
                capture_ref,
                record,
                prepared,
                machine,
                saved,
                injection,
            );
        } else body_result = try e.call(ctx.calls.resume_continuation, &.{
            machine, capture_ref, try e.b.reference(argument),
        });
        body_result = try e.b.bind(prepared, try e.call(ctx.tokens.prepare, &.{
            try e.b.reference(captured), token, current,
        }), body_result);
    }
    return body_result;
}

const CaptureTerms = struct {
    use_site: Id,
    bodies: Id,
    multi: Id,
    token: Id,
    changed: Id,
    token_value: Id,
    token_ref: Id,
    token_schema: Id,
    is_multi: Id,
    choose_token: Id,
    choose_value: Id,
};

fn captureTerms(
    ctx: Context,
    code: Id,
    current: Id,
    control: Id,
    captured: Id,
    local_effect: LocalEffect,
) Error!CaptureTerms {
    const e = ctx.e;
    const use_site = try e.b.variable(ctx.values);
    const bodies = try e.b.variable(ctx.values);
    const multi = try e.b.variable(e.boolean);
    const token = try e.b.variable(ctx.graph.appended);
    const changed = try e.b.variable(ctx.m.schema);
    const token_value = try e.b.variable(ctx.value);
    const token_ref = try e.field(try e.b.reference(token), 1);
    const token_schema = try field(e, local_effect.clause, ir.Clause, "resumption");
    const signature = try e.payload(try e.payload(try e.required(
        try field(e, code, ir.Program, "schemas"),
        token_schema,
    ), @backingInt(p.SchemaTag.internal)), @backingInt(p.InternalTag.resumption));
    const use = try field(e, signature, p.ResumptionType, "use");
    const is_multi = try e.binary(.equal, try e.b.primitive(
        try e.b.scalar(u32),
        .enum_tag,
        &.{use},
        0,
    ), try e.b.constant(u32, @backingInt(p.Use.multi)));
    const capture = try emitPerformCapture(
        e,
        ctx.optional_ref,
        current,
        control,
        local_effect.selected,
        use_site,
        token_schema,
    );
    const choose_token = try e.when(try e.b.reference(multi), try e.call(ctx.graph.template, &.{
        try e.b.reference(captured), capture,
    }), try e.call(ctx.graph.append, &.{ try e.b.reference(captured), try e.variant(
        ctx.node,
        @backingInt(g.NodeTag.one_shot),
        capture,
    ) }));
    const choose_value = try e.when(try e.b.reference(multi), try e.b.pure(
        try graphs.value(e, token_schema, token_ref, false),
    ), try e.b.pure(try graphs.value(e, token_schema, token_ref, true)));
    return .{
        .use_site = use_site,
        .bodies = bodies,
        .multi = multi,
        .token = token,
        .changed = changed,
        .token_value = token_value,
        .token_ref = token_ref,
        .token_schema = token_schema,
        .is_multi = is_multi,
        .choose_token = choose_token,
        .choose_value = choose_value,
    };
}
