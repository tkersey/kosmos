//! Consumption, instantiation and deep/shallow reattachment of guest captures.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const graphs = @import("graph.zig");
const clones = @import("clone.zig");
const access = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const p = data.program;
pub const Definition = struct { take: Id, taken: Id, activate: Id, prepare: Id, prepared: Id };

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.captures/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const clone = try clones.define(b, m);
    const node = try projection.schema(g.Node, b);
    const ref_type = try projection.schema(g.NodeRef, b);
    const optional_ref = try projection.schema(?g.NodeRef, b);
    const capture = try projection.schema(g.Capture, b);
    const prepared = try b.schema(.{ .product = &.{ m.schema, optional_ref } });
    const d: Definition = .{
        .take = try b.declare(&.{
            m.schema, try projection.schema(g.Value, b),
        }, clone.result, &.{}, &.{}),
        .taken = clone.result,
        .activate = try b.declare(&.{ m.schema, capture, ref_type }, m.schema, &.{}, &.{}),
        .prepare = try b.declare(&.{ m.schema, capture, ref_type }, prepared, &.{}, &.{}),
        .prepared = prepared,
    };
    try emitTake(m, e, graph, clone, node, ref_type, d);
    try emitActivate(e, graph, node, optional_ref, d);
    const replace_links = try b.declare(&.{
        m.schema, ref_type, optional_ref, e.integer,
    }, m.schema, &.{}, &.{});
    try emitReplaceLinks(m, e, graph, node, ref_type, replace_links);
    try emitPrepare(m, e, graph, node, optional_ref, prepared, d, replace_links);
    return cache.finish(b, d);
}

fn emitTake(
    m: machines.Definition,
    e: Author,
    graph: graphs.Definition,
    clone: clones.Definition,
    node: Id,
    ref_type: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.take, 0);
    const reference = try e.b.variable(ref_type);
    const record = try e.b.variable(node);
    const saved = try e.b.reference(record);
    const single = try e.payload(saved, @backingInt(g.NodeTag.one_shot));
    const changed = try e.b.variable(m.schema);
    const consumed = try e.replace(
        single,
        machines.index(g.Capture, "capture"),
        try e.literal(?g.NodeRef, null),
    );
    const one = try emitTakeOne(e, graph, node, d, input, reference, single, changed, consumed);
    const valid_one = try emitTakeValidOne(e, single, one);
    const multiple = try e.call(clone.instantiate, &.{ input, try e.payload(
        saved,
        @backingInt(g.NodeTag.multi_template),
    ) });
    const tag = try e.b.primitive(e.integer, .variant_tag, &.{saved}, 0);
    const dispatch = try e.when(try e.binary(.equal, tag, try e.b.constant(
        u64,
        @backingInt(g.NodeTag.multi_template),
    )), multiple, try e.when(try e.binary(.equal, tag, try e.b.constant(
        u64,
        @backingInt(g.NodeTag.one_shot),
    )), valid_one, try e.fail()));
    try e.b.define(d.take, try e.b.bind(reference, try e.call(
        graph.value_ref,
        &.{try e.param(d.take, 1)},
    ), try e.b.bind(record, try e.call(graph.record, &.{
        input,
        try e.b.reference(reference),
    }), dispatch)));
}

fn emitActivate(
    e: Author,
    graph: graphs.Definition,
    node: Id,
    optional_ref: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.activate, 0);
    const token = try e.param(d.activate, 1);
    const ref = try e.field(token, machines.index(g.Capture, "delimiter"));
    const record = try e.b.variable(node);
    const attachment = try e.payload(
        try e.b.reference(record),
        @backingInt(g.NodeTag.attachment),
    );
    var changed = try e.replace(attachment, 2, try e.variant(
        optional_ref,
        1,
        try e.param(d.activate, 2),
    ));
    changed = try e.replace(changed, 3, try e.literal(@FieldType(
        @FieldType(g.Node, "attachment"),
        "phase",
    ), .active));
    try e.b.define(
        d.activate,
        try e.b.bind(
            record,
            try e.call(graph.record, &.{
                input,
                ref,
            }),
            try e.call(
                graph.replace,
                &.{
                    input,                                                           ref,
                    try e.variant(node, @backingInt(g.NodeTag.attachment), changed),
                },
            ),
        ),
    );
}

fn emitReplaceLinks(
    m: machines.Definition,
    e: Author,
    graph: graphs.Definition,
    node: Id,
    ref_type: Id,
    replace_links: Id,
) Error!void {
    const input = try e.param(replace_links, 0);
    const delimiter = try e.param(replace_links, 1);
    const outer = try e.param(replace_links, 2);
    const index = try e.param(replace_links, 3);
    const selected = try e.b.variable(m.nodes.optional);
    const element = try e.payload(try e.b.reference(selected), 1);
    const record = try e.field(element, 0);
    const changed = try e.b.variable(m.schema);
    var dispatch = try e.b.pure(input);
    inline for ([_]g.NodeTag{
        .control, .continuation, .handler, .attachment, .protection, .one_shot, .multi_template,
    }) |tag| {
        const name = @tagName(tag);
        const T = @FieldType(g.Node, name);
        const field_name = if (tag == .attachment) "outer" else "evidence";
        const payload = try e.payload(record, @backingInt(tag));
        const link = try e.field(payload, machines.index(T, field_name));
        const replacement = try e.variant(node, @backingInt(tag), try e.replace(
            payload,
            machines.index(T, field_name),
            outer,
        ));
        const same = try e.binary(
            .equal,
            try e.field(try e.payload(link, 1), 0),
            try e.field(delimiter, 0),
        );
        const update = try e.call(graph.replace, &.{
            input, try e.tuple(ref_type, &.{index}), replacement,
        });
        const unchanged = try e.b.pure(input);
        const choose = try e.when(try e.binary(.equal, try e.b.primitive(
            e.integer,
            .variant_tag,
            &.{link},
            0,
        ), e.zero), unchanged, try e.when(same, update, unchanged));
        dispatch = try e.when(try e.binary(.equal, try e.b.primitive(
            e.integer,
            .variant_tag,
            &.{record},
            0,
        ), try e.b.constant(u64, @backingInt(tag))), choose, dispatch);
    }
    const next = try e.b.bind(selected, try e.call(m.nodes.get, &.{
        try m.field(e, input, .nodes), index,
    }), try e.b.bind(changed, dispatch, try e.call(replace_links, &.{
        try e.b.reference(changed), delimiter, outer, try e.binary(.integer_add, index, e.one),
    })));
    try e.b.define(replace_links, try e.when(try e.binary(
        .less,
        index,
        try e.field(try m.field(e, input, .nodes), 0),
    ), next, try e.b.pure(input)));
}

fn emitPrepare(
    m: machines.Definition,
    e: Author,
    graph: graphs.Definition,
    node: Id,
    optional_ref: Id,
    prepared: Id,
    d: Definition,
    replace_links: Id,
) Error!void {
    const input = try e.param(d.prepare, 0);
    const token = try e.param(d.prepare, 1);
    const after = try e.param(d.prepare, 2);
    const delimiter = try e.field(token, machines.index(g.Capture, "delimiter"));
    const evidence = try e.field(token, machines.index(g.Capture, "evidence"));
    const program = try m.field(e, input, .program);
    const shapes = try access.field(
        e,
        try access.code(e, program),
        data.activation.Program,
        "schemas",
    );
    const signature = try e.payload(try e.payload(
        try e.required(shapes, try e.field(token, 0)),
        @backingInt(p.SchemaTag.internal),
    ), @backingInt(p.InternalTag.resumption));
    const mode = try access.field(e, signature, p.ResumptionType, "mode");
    const changed = try e.b.variable(m.schema);
    const deep = try e.b.bind(changed, try e.call(
        d.activate,
        &.{ input, token, after },
    ), try e.b.pure(try e.tuple(prepared, &.{
        try e.b.reference(changed),
        evidence,
    })));
    const original = try e.b.variable(node);
    const replacement = try e.b.variable(m.nodes.element);
    const nodes = try e.b.variable(m.nodes.table);
    const outer_shallow = try emitPrepareOuterShallow(
        e,
        optional_ref,
        prepared,
        delimiter,
        evidence,
        changed,
        original,
    );
    const outer = outer_shallow.outer;
    var shallow = outer_shallow.shallow;
    shallow = try e.b.bind(changed, try e.call(replace_links, &.{ try e.replace(
        input,
        @backingInt(machines.Field.nodes),
        try e.b.reference(nodes),
    ), delimiter, outer, e.zero }), shallow);
    shallow = try e.b.bind(nodes, try e.call(m.nodes.set, &.{
        try m.field(e, input, .nodes), try e.field(delimiter, 0), try e.b.reference(replacement),
    }), shallow);
    shallow = try e.b.bind(replacement, try e.call(graph.element, &.{ input, after }), shallow);
    shallow = try e.b.bind(original, try e.call(graph.record, &.{ input, delimiter }), shallow);
    try e.b.define(d.prepare, try e.when(try e.binary(.equal, try e.b.primitive(
        try e.b.scalar(u32),
        .enum_tag,
        &.{mode},
        0,
    ), try e.b.constant(u32, @backingInt(p.Mode.deep))), deep, shallow));
}

fn emitTakeOne(
    e: Author,
    graph: graphs.Definition,
    node: Id,
    d: Definition,
    input: Id,
    reference: Id,
    single: Id,
    changed: Id,
    consumed: Id,
) Error!Id {
    return try e.b.bind(
        changed,
        try e.call(
            graph.replace,
            &.{
                input,
                try e.b.reference(reference),
                try e.variant(node, @backingInt(g.NodeTag.one_shot), consumed),
            },
        ),
        try e.b.pure(try e.tuple(d.taken, &.{ try e.b.reference(changed), single })),
    );
}

fn emitTakeValidOne(e: Author, single: Id, one: Id) Error!Id {
    return try e.when(
        try e.binary(
            .equal,
            try e.b.primitive(
                e.integer,
                .variant_tag,
                &.{try e.field(
                    single,
                    machines.index(g.Capture, "capture"),
                )},
                0,
            ),
            e.one,
        ),
        one,
        try e.fail(),
    );
}

fn emitPrepareOuterShallow(
    e: Author,
    optional_ref: Id,
    prepared: Id,
    delimiter: Id,
    evidence: Id,
    changed: Id,
    original: Id,
) Error!struct { outer: Id, shallow: Id } {
    const outer = try e.field(try e.payload(
        try e.b.reference(original),
        @backingInt(g.NodeTag.attachment),
    ), 1);
    const selected_evidence = try e.b.variable(optional_ref);
    const unchanged = try e.b.pure(evidence);
    const same = try e.binary(
        .equal,
        try e.field(try e.payload(evidence, 1), 0),
        try e.field(delimiter, 0),
    );
    const choose = try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{evidence},
        0,
    ), e.zero), unchanged, try e.when(same, try e.b.pure(outer), unchanged));
    const shallow = try e.b.bind(selected_evidence, choose, try e.b.pure(try e.tuple(prepared, &.{
        try e.b.reference(changed), try e.b.reference(selected_evidence),
    })));
    return .{ .outer = outer, .shallow = shallow };
}
