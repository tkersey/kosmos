//! Source initialization and controls over admitted guest inputs. ERQ3/ERS3
//! binding and byte admission remain with the existing facade data owner.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const control = @import("control.zig");
const graphs = @import("graph.zig");
const edges = @import("edges.zig");
const unwind = @import("unwind.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const field = edges.field;
pub const Definition = struct { initialize: Id, respond: Id, resume_yield: Id, cancel: Id };
fn hasStatus(
    e: Author,
    m: machines.Definition,
    input: Id,
    wanted: data.process_state.Status,
) Error!Id {
    const current = try field(e, try m.field(e, input, .header), machines.Header, "status");
    return e.binary(.equal, try e.b.primitive(
        try e.b.scalar(u32),
        .enum_tag,
        &.{current},
        0,
    ), try e.b.constant(u32, @backingInt(wanted)));
}
pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.lifecycle/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const c = try control.define(b, m);
    const graph = try graphs.define(b, m);
    const values = try @import("values.zig").define(b, m);
    const codec = try @import("codec.zig").define(b, m);
    const bytes = try b.schema(.bytes);
    const d: Definition = .{
        .initialize = try b.declare(&.{ m.program, bytes }, m.schema, &.{}, &.{}),
        .respond = try b.declare(&.{ m.schema, bytes }, m.schema, &.{}, &.{}),
        .resume_yield = try b.declare(&.{m.schema}, m.schema, &.{}, &.{}),
        .cancel = try b.declare(&.{
            m.schema, try projection.schema(data.invocation.Reason, b),
        }, m.schema, &.{}, &.{}),
    };
    try emitInitialize(m, e, c, values, codec, bytes, d);
    try emitRespond(m, e, c, graph, values, d);
    {
        const input = try e.param(d.resume_yield, 0);
        try b.define(d.resume_yield, try e.when(try hasStatus(e, m, input, .yielded), try b.pure(
            try unwind.status(e, m, input, .active),
        ), try e.fail()));
    }
    try emitCancel(m, e, c, d);
    return cache.finish(b, d);
}

fn emitInitialize(
    m: machines.Definition,
    e: Author,
    c: control.Definition,
    values: anytype,
    codec: anytype,
    bytes: Id,
    d: Definition,
) Error!void {
    const program = try e.param(d.initialize, 0);
    const input = try e.param(d.initialize, 1);
    const code = try edges.code(e, program);
    const entry = try field(e, try field(
        e,
        code,
        data.activation.Program,
        "roots",
    ), data.program.Roots, "entry");
    const function = try edges.function(e, program, entry);
    const layout = try e.field(try field(e, function, data.activation.Function, "layout"), 0);
    const slots = try field(e, function, data.activation.Function, "inputs");
    const header = try e.tuple(m.header, &.{ try field(
        e,
        program,
        projection.Program,
        "identity",
    ), try e.literal(data.process_state.Status, .active), try e.literal(g.Roots, .{}) });
    const initial = try e.tuple(m.schema, &.{
        program,
        header,
        try m.nodes.empty(e.b),
        try m.blobs.empty(e.b),
        e.zero,
        try m.cache.entries.empty(e),
    });
    const vals = try projection.schema([]const g.Value, e.b);
    const loop = try e.b.declare(&.{
        m.schema, bytes, e.integer, e.integer, vals,
    }, m.schema, &.{}, &.{});
    try emitInitializationLoop(m, e, c, values, codec, loop);
    try e.b.define(d.initialize, try e.call(loop, &.{
        initial, input, e.zero, e.zero, try unwind.empty(e),
    }));
    _ = layout;
    _ = slots;
}

fn emitRespond(
    m: machines.Definition,
    e: Author,
    c: control.Definition,
    graph: graphs.Definition,
    values: anytype,
    d: Definition,
) Error!void {
    const input = try e.param(d.respond, 0);
    const pending = try e.payload(try field(
        e,
        try control.roots(e, m, input),
        g.Roots,
        "pending",
    ), 1);
    const record = try e.b.variable(try projection.schema(g.Node, e.b));
    const request = try e.payload(try e.b.reference(record), @backingInt(g.NodeTag.pending));
    const effect = try e.required(try field(
        e,
        try edges.code(e, try m.field(e, input, .program)),
        data.activation.Program,
        "effects",
    ), try e.field(request, 0));
    const result = try e.b.variable(values.result);
    const changed = try e.b.variable(m.schema);
    const literal = try e.tuple(try projection.schema(data.program.Literal, e.b), &.{ try field(
        e,
        effect,
        data.program.Effect,
        "result",
    ), try e.param(d.respond, 1) });
    var body = try e.b.bind(changed, try e.call(c.resume_continuation, &.{
        try e.field(try e.b.reference(result), 0),
        try e.field(request, 2),
        try e.field(try e.b.reference(result), 1),
    }), try e.b.pure(try unwind.status(e, m, try unwind.root(
        e,
        m,
        try e.b.reference(changed),
        "pending",
        try e.literal(?g.NodeRef, null),
    ), .active)));
    body = try e.b.bind(result, try e.call(values.literal, &.{ input, literal }), body);
    body = try e.b.bind(record, try e.call(graph.record, &.{ input, pending }), body);
    try e.b.define(d.respond, try e.when(try hasStatus(e, m, input, .parked), body, try e.fail()));
}

fn emitCancel(m: machines.Definition, e: Author, c: control.Definition, d: Definition) Error!void {
    const input = try e.param(d.cancel, 0);
    var body = try e.fail();
    inline for (.{
        data.process_state.Status.active,
        data.process_state.Status.yielded,
        data.process_state.Status.parked,
        data.process_state.Status.unwinding,
    }) |s| body = try e.when(try hasStatus(e, m, input, s), try e.call(
        c.unwind.cleanup.cancel,
        &.{ input, try e.param(d.cancel, 1) },
    ), body);
    try e.b.define(d.cancel, body);
}

fn emitInitializeMore(
    e: Author,
    values: anytype,
    loop: Id,
    machine: Id,
    encoded: Id,
    at: Id,
    prior: Id,
    end: Id,
    decoded: Id,
    literal: Id,
) Error!Id {
    return try e.b.bind(decoded, try e.call(values.literal, &.{ machine, literal }), try e.call(
        loop,
        &.{
            try e.field(try e.b.reference(decoded), 0),
            encoded,
            try e.binary(.integer_add, at, e.one),
            try e.b.reference(end),
            try unwind.concat(
                e,
                prior,
                try unwind.seq(e, &.{
                    try e.field(try e.b.reference(decoded), 1),
                }),
            ),
        },
    ));
}

fn emitInitializationLoop(
    m: machines.Definition,
    e: Author,
    c: control.Definition,
    values: anytype,
    codec: anytype,
    loop: Id,
) Error!void {
    const machine = try e.param(loop, 0);
    const encoded = try e.param(loop, 1);
    const at = try e.param(loop, 2);
    const offset = try e.param(loop, 3);
    const prior = try e.param(loop, 4);
    const guest_program = try m.field(e, machine, .program);
    const guest_code = try edges.code(e, guest_program);
    const guest_entry = try field(e, try field(
        e,
        guest_code,
        data.activation.Program,
        "roots",
    ), data.program.Roots, "entry");
    const guest_fn = try edges.function(e, guest_program, guest_entry);
    const guest_slots = try field(e, guest_fn, data.activation.Function, "inputs");
    const guest_layout = try e.field(try field(e, guest_fn, data.activation.Function, "layout"), 0);
    const schema = try e.required(guest_layout, try e.required(guest_slots, at));
    const end = try e.b.variable(e.integer);
    const decoded = try e.b.variable(values.result);
    const literal = try e.tuple(
        try projection.schema(data.program.Literal, e.b),
        &.{ schema, try e.slice(
            encoded,
            offset,
            try e.b.reference(end),
        ) },
    );
    var more = try emitInitializeMore(
        e,
        values,
        loop,
        machine,
        encoded,
        at,
        prior,
        end,
        decoded,
        literal,
    );
    more = try e.b.bind(end, try e.call(codec.skip, &.{
        guest_program, schema, encoded, offset,
    }), more);
    const none = try e.literal(?g.NodeRef, null);
    const enter = try e.call(c.enter, &.{ machine, guest_entry, prior, none, none, none });
    const finish = try e.when(try e.binary(.equal, offset, try e.b.primitive(
        e.integer,
        .blob_length,
        &.{encoded},
        0,
    )), enter, try e.fail());
    try e.b.define(loop, try e.when(try e.binary(.less, at, try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{guest_slots},
        0,
    )), more, finish));
}
