//! Portable product, sum and collection construction. Exportable guest data
//! keeps canonical bytes; internal aggregate identity and ownership stay explicit.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const access = @import("edges.zig");
const values = @import("values.zig");
const codecs = @import("codec.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const p = data.program;
const field = access.field;
pub const Parts = struct { tag: u64, fields: []const g.Value };
pub const Definition = struct {
    construct: Id,
    parts: Id,
    tag: Id,
    field: Id,
    payload: Id,
    split: Id,
    split_result: Id,
    encode_fields: Id,
};

fn schemaTag(e: Author, name: p.SchemaTag) Error!Id {
    return e.b.constant(u64, @backingInt(name));
}

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.aggregate/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const v = try values.define(b, m);
    const codec = try codecs.define(b, m);
    const fields = try projection.schema([]const g.Value, b);
    const parts = try projection.schema(Parts, b);
    const bytes = try b.schema(.bytes);
    const node_type = try projection.schema(g.Node, b);
    const split_result = try b.schema(.{ .product = &.{ m.schema, parts } });
    const d: Definition = .{
        .construct = try b.declare(&.{
            m.schema, e.integer, e.integer, fields,
        }, v.result, &.{}, &.{}),
        .parts = try b.declare(&.{ m.schema, v.value }, parts, &.{}, &.{}),
        .tag = try b.declare(&.{ m.schema, v.value }, e.integer, &.{}, &.{}),
        .field = try b.declare(&.{ m.schema, v.value, e.integer }, v.result, &.{}, &.{}),
        .payload = try b.declare(&.{ m.schema, v.value }, v.result, &.{}, &.{}),
        .split = try b.declare(&.{ m.schema, v.value }, split_result, &.{}, &.{}),
        .split_result = split_result,
        .encode_fields = try b.declare(&.{ m.schema, fields, bytes }, bytes, &.{}, &.{}),
    };
    try emitParts(m, e, parts, d);
    try emitConstruct(m, e, v, codec, fields, bytes, node_type, d);
    try emitTag(e, v, codec, parts, bytes, d);
    try emitAccessors(m, e, v, codec, parts, bytes, d);
    try emitLoop(m, e, v, fields, parts, split_result, d);
    return cache.finish(b, d);
}

fn emitParts(m: machines.Definition, e: Author, parts: Id, d: Definition) Error!void {
    const input = try e.param(d.parts, 0);
    const value = try e.param(d.parts, 1);
    const body = try e.field(value, 1);
    const ref = try e.b.variable(try projection.schema(g.NodeRef, e.b));
    const found = try e.b.variable(m.nodes.optional);
    const record = try e.payload(try e.field(
        try e.payload(try e.b.reference(found), 1),
        0,
    ), @backingInt(g.NodeTag.aggregate));
    const select = try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{body},
        0,
    ), try e.b.constant(
        u64,
        @backingInt(g.ValueTag.reference),
    )), try e.b.pure(try e.payload(body, 2)), try e.b.pure(
        try e.field(try e.payload(body, 3), 0),
    ));
    try e.b.define(d.parts, try e.b.bind(ref, select, try e.b.bind(found, try e.call(
        m.nodes.get,
        &.{
            try m.field(e, input, .nodes), try e.field(try e.b.reference(ref), 0),
        },
    ), try e.b.pure(try e.tuple(parts, &.{
        try e.field(record, 1),
        try e.field(record, 2),
    })))));
}

fn emitConstruct(
    m: machines.Definition,
    e: Author,
    v: values.Definition,
    codec: codecs.Definition,
    fields: Id,
    bytes: Id,
    node_type: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.construct, 0);
    const schema = try e.param(d.construct, 1);
    const tag = try e.param(d.construct, 2);
    const children = try e.param(d.construct, 3);
    const program = try m.field(e, input, .program);
    const shapes = try field(
        e,
        try access.code(e, program),
        data.activation.Program,
        "schemas",
    );
    const shape = try e.required(shapes, schema);
    const kind = try e.b.primitive(e.integer, .variant_tag, &.{shape}, 0);
    const facts = try field(e, program, projection.Program, "schemas");
    const exportable = try e.required(try field(
        e,
        facts,
        data.admission.SchemaFacts,
        "exportable",
    ), schema);
    const prefix = try e.b.variable(bytes);
    const empty = try e.b.pure(try e.literal([]const u8, &.{}));
    const count_prefix = try e.call(codec.natural, &.{try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{children},
        0,
    )});
    var choose_prefix = try e.when(try e.binary(
        .equal,
        kind,
        try schemaTag(e, .sum),
    ), try e.call(codec.natural, &.{tag}), empty);
    inline for (.{ p.SchemaTag.seq, .vector }) |k| choose_prefix = try e.when(
        try e.binary(.equal, kind, try schemaTag(e, k)),
        count_prefix,
        choose_prefix,
    );
    const encode = d.encode_fields;
    try emitEncode(e, v, fields, bytes, encode);
    const encoded = try e.b.variable(bytes);
    const literal_type = try projection.schema(p.Literal, e.b);
    const ordinary = try emitConstructOrdinary(
        e,
        v,
        input,
        schema,
        children,
        prefix,
        choose_prefix,
        encode,
        encoded,
        literal_type,
    );
    const internal = try constructNode(m, e, v, node_type, input, schema, tag, children, program);
    try e.b.define(d.construct, try e.when(exportable, ordinary, internal));
}

fn emitTag(
    e: Author,
    v: values.Definition,
    codec: codecs.Definition,
    parts: Id,
    bytes: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.tag, 0);
    const value = try e.param(d.tag, 1);
    const selected = try e.b.variable(parts);
    const encoded = try e.b.variable(bytes);
    const decoded = try e.b.variable(try projection.schema(codecs.Read, e.b));
    const from_bytes = try e.b.bind(
        encoded,
        try e.call(v.bytes, &.{
            input,
            value,
        }),
        try e.b.bind(
            decoded,
            try e.call(codec.read, &.{ try e.b.reference(encoded), e.zero }),
            try e.b.pure(try e.field(try e.b.reference(decoded), 0)),
        ),
    );
    const from_fields = try e.b.bind(
        selected,
        try e.call(d.parts, &.{
            input,
            value,
        }),
        try e.b.pure(try e.field(try e.b.reference(selected), 0)),
    );
    try e.b.define(d.tag, try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{try e.field(value, 1)},
        0,
    ), e.one), from_bytes, from_fields));
}

fn emitLoop(
    m: machines.Definition,
    e: Author,
    v: values.Definition,
    fields: Id,
    parts: Id,
    split_result: Id,
    d: Definition,
) Error!void {
    const table = try @import("table.zig").define(e.b, v.value);
    const output = try e.b.schema(.{ .product = &.{ m.schema, table.table } });
    const loop = try e.b.declare(&.{
        m.schema, v.value, e.integer, e.integer, table.table,
    }, output, &.{}, &.{});
    const input = try e.param(loop, 0);
    const value = try e.param(loop, 1);
    const index = try e.param(loop, 2);
    const count = try e.param(loop, 3);
    const prior = try e.param(loop, 4);
    const selected = try e.b.variable(v.result);
    const appended = try e.b.variable(table.table);
    const more = try emitLoopMore(
        e,
        d,
        table,
        loop,
        input,
        value,
        index,
        count,
        prior,
        selected,
        appended,
    );
    try e.b.define(loop, try e.when(try e.binary(.less, index, count), more, try e.b.pure(
        try e.tuple(output, &.{ input, prior }),
    )));
    try emitSplit(m, e, v, fields, parts, split_result, d, table, output, loop);
}

fn defineFromFields(
    e: Author,
    v: anytype,
    d: Definition,
    input: Id,
    value: Id,
    index: anytype,
    selected: Id,
) Error!Id {
    return try e.b.bind(
        selected,
        try e.call(d.parts, &.{
            input,
            value,
        }),
        try e.b.pure(
            try e.tuple(
                v.result,
                &.{ input, try e.required(try e.field(try e.b.reference(selected), 1), index) },
            ),
        ),
    );
}

fn defineRead(
    e: Author,
    v: anytype,
    input: Id,
    start: Id,
    end: Id,
    child_schema: Id,
    bytes_value: Id,
    literal_type: Id,
) Error!Id {
    return try e.call(
        v.literal,
        &.{
            input,
            try e.tuple(
                literal_type,
                &.{
                    try e.b.reference(child_schema),
                    try e.slice(bytes_value, try e.b.reference(start), try e.b.reference(end)),
                },
            ),
        },
    );
}

fn emitConstructOrdinary(
    e: Author,
    v: values.Definition,
    input: Id,
    schema: Id,
    children: Id,
    prefix: Id,
    choose_prefix: Id,
    encode: anytype,
    encoded: Id,
    literal_type: Id,
) Error!Id {
    return try e.b.bind(
        prefix,
        choose_prefix,
        try e.b.bind(
            encoded,
            try e.call(encode, &.{
                input,
                children,
                try e.b.reference(prefix),
            }),
            try e.call(v.literal, &.{ input, try e.tuple(
                literal_type,
                &.{ schema, try e.b.reference(encoded) },
            ) }),
        ),
    );
}

fn emitConstructChoose(e: Author, ref: Id, body_type: anytype, copy: Id) Error!Id {
    return try e.when(
        copy,
        try e.b.pure(try e.variant(
            body_type,
            2,
            ref,
        )),
        try e.b.pure(
            try e.variant(
                body_type,
                3,
                try e.tuple(try projection.schema(g.OwnedRef, e.b), &.{ref}),
            ),
        ),
    );
}

fn emitConstructInternal(
    m: machines.Definition,
    e: Author,
    v: values.Definition,
    input: Id,
    schema: Id,
    old: anytype,
    selected: Id,
    choose: Id,
    table: Id,
    item: Id,
) Error!Id {
    return try e.b.bind(
        selected,
        choose,
        try e.b.bind(
            table,
            try e.call(m.nodes.append, &.{
                old,
                item,
            }),
            try e.b.pure(
                try e.tuple(
                    v.result,
                    &.{
                        try e.replace(
                            input,
                            @backingInt(machines.Field.nodes),
                            try e.b.reference(table),
                        ),
                        try e.tuple(v.value, &.{
                            schema,
                            try e.b.reference(selected),
                        }),
                    },
                ),
            ),
        ),
    );
}

fn emitLoopMore(
    e: Author,
    d: Definition,
    table: anytype,
    loop: Id,
    input: Id,
    value: Id,
    index: Id,
    count: Id,
    prior: Id,
    selected: Id,
    appended: Id,
) Error!Id {
    return try e.b.bind(
        selected,
        try e.call(d.field, &.{
            input,
            value,
            index,
        }),
        try e.b.bind(
            appended,
            try e.call(table.append, &.{
                prior,
                try e.field(try e.b.reference(selected), 1),
            }),
            try e.call(loop, &.{
                try e.field(try e.b.reference(
                    selected,
                ), 0),
                value,
                try e.binary(.integer_add, index, e.one),
                count,
                try e.b.reference(appended),
            }),
        ),
    );
}

fn emitLoopProduct(
    e: Author,
    parts: Id,
    split_result: Id,
    table: anytype,
    loop: Id,
    machine: Id,
    argument: Id,
    shape: Id,
    result: Id,
    collected: Id,
) Error!Id {
    return try e.b.bind(
        result,
        try e.call(
            loop,
            &.{
                machine,              argument, e.zero,
                try e.b.primitive(
                    e.integer,
                    .sequence_length,
                    &.{try e.payload(
                        shape,
                        @backingInt(p.SchemaTag.product),
                    )},
                    0,
                ),
                try table.empty(e.b),
            },
        ),
        try e.b.bind(collected, try e.call(table.to_sequence, &.{
            try e.field(try e.b.reference(result), 1),
        }), try e.b.pure(
            try e.tuple(
                split_result,
                &.{
                    try e.field(try e.b.reference(
                        result,
                    ), 0),
                    try e.tuple(parts, &.{
                        e.zero,
                        try e.b.reference(collected),
                    }),
                },
            ),
        )),
    );
}

fn emitLoopSum(
    e: Author,
    fields: Id,
    parts: Id,
    split_result: Id,
    d: Definition,
    machine: Id,
    argument: Id,
    tag: Id,
    payload: Id,
) Error!Id {
    return try e.b.bind(
        tag,
        try e.call(d.tag, &.{
            machine,
            argument,
        }),
        try e.b.bind(
            payload,
            try e.call(d.payload, &.{
                machine,
                argument,
            }),
            try e.b.pure(
                try e.tuple(
                    split_result,
                    &.{
                        try e.field(try e.b.reference(
                            payload,
                        ), 0),
                        try e.tuple(
                            parts,
                            &.{
                                try e.b.reference(tag),
                                try e.b.primitive(
                                    fields,
                                    .sequence,
                                    &.{try e.field(try e.b.reference(payload), 1)},
                                    0,
                                ),
                            },
                        ),
                    },
                ),
            ),
        ),
    );
}

fn emitEncode(e: Author, v: values.Definition, fields: Id, bytes: Id, encode: anytype) Error!void {
    const machine = try e.param(encode, 0);
    const tail_fields = try e.param(encode, 1);
    const prior = try e.param(encode, 2);
    const pair_type = try e.b.schema(.{ .product = &.{ v.value, fields } });
    const optional = try e.b.schema(.{ .sum = &.{ e.unit, pair_type } });
    const nil = try e.b.variable(e.unit);
    const pair_var = try e.b.variable(pair_type);
    const pair = try e.b.reference(pair_var);
    const encoded = try e.b.variable(bytes);
    try e.b.define(encode, try e.b.term(.{ .match_sum = .{ .value = try e.b.primitive(
        optional,
        .sequence_pop,
        &.{tail_fields},
        0,
    ), .cases = &.{
        .{ .variable = nil, .body = try e.b.pure(prior) },
        .{ .variable = pair_var, .body = try e.b.bind(encoded, try e.call(
            v.bytes,
            &.{ machine, try e.field(pair, 0) },
        ), try e.call(encode, &.{
            machine, try e.field(pair, 1), try e.concat(prior, try e.b.reference(encoded)),
        })) },
    } } }));
}

fn emitAccessors(
    m: machines.Definition,
    e: Author,
    v: values.Definition,
    codec: codecs.Definition,
    parts: Id,
    bytes: Id,
    d: Definition,
) Error!void {
    const b = e.b;
    inline for (.{ false, true }) |variant| {
        const entry = if (variant) d.payload else d.field;
        const input = try e.param(entry, 0);
        const value = try e.param(entry, 1);
        const index = if (variant) e.zero else try e.param(entry, 2);
        const selected = try b.variable(parts);
        const from_fields = try defineFromFields(e, v, d, input, value, index, selected);
        const program = try m.field(e, input, .program);
        const shapes = try field(
            e,
            try access.code(e, program),
            data.activation.Program,
            "schemas",
        );
        const shape = try e.required(shapes, try e.field(value, 0));
        const types = try e.payload(shape, @backingInt(
            if (variant) p.SchemaTag.sum else p.SchemaTag.product,
        ));
        const encoded = try b.variable(bytes);
        const start = try b.variable(e.integer);
        const end = try b.variable(e.integer);
        const child_schema = try b.variable(e.integer);
        const decoded = try b.variable(try projection.schema(codecs.Read, b));
        const bytes_value = try b.reference(encoded);
        const literal_type = try projection.schema(p.Literal, b);
        var read = try defineRead(
            e,
            v,
            input,
            start,
            end,
            child_schema,
            bytes_value,
            literal_type,
        );
        read = try readChild(
            e,
            codec,
            variant,
            program,
            types,
            index,
            bytes_value,
            start,
            end,
            child_schema,
            decoded,
            read,
        );
        read = try b.bind(encoded, try e.call(v.bytes, &.{ input, value }), read);
        try b.define(entry, try e.when(try e.binary(.equal, try b.primitive(
            e.integer,
            .variant_tag,
            &.{try e.field(value, 1)},
            0,
        ), e.one), read, from_fields));
    }
}

fn constructNode(
    m: machines.Definition,
    e: Author,
    v: values.Definition,
    node_type: Id,
    input: Id,
    schema: Id,
    tag: Id,
    children: Id,
    program: Id,
) Error!Id {
    const old = try m.field(e, input, .nodes);
    const ref = try e.tuple(try projection.schema(g.NodeRef, e.b), &.{try e.field(old, 0)});
    const body_type = e.b.schemas.items[@intCast(v.value)].product[1];
    const selected = try e.b.variable(body_type);
    const copy = try e.required(try field(e, try field(
        e,
        program,
        projection.Program,
        "uses",
    ), data.traits.Facts, "copy"), schema);
    const choose = try emitConstructChoose(e, ref, body_type, copy);
    const table = try e.b.variable(m.nodes.table);
    const aggregate_type = e.b.schemas.items[
        @intCast(node_type)
    ].sum[
        @backingInt(g.NodeTag.aggregate)
    ];
    const record = try e.variant(node_type, @backingInt(g.NodeTag.aggregate), try e.tuple(
        aggregate_type,
        &.{ schema, tag, children },
    ));
    const optional_frame = e.b.schemas.items[@intCast(m.nodes.element)].product[1];
    const item = try e.tuple(m.nodes.element, &.{
        record, try e.variant(optional_frame, 0, e.unit_value),
    });
    return emitConstructInternal(
        m,
        e,
        v,
        input,
        schema,
        old,
        selected,
        choose,
        table,
        item,
    );
}

fn emitSplit(
    m: machines.Definition,
    e: Author,
    v: values.Definition,
    fields: Id,
    parts: Id,
    split_result: Id,
    d: Definition,
    table: @import("table.zig").Definition,
    output: Id,
    loop: Id,
) Error!void {
    const machine = try e.param(d.split, 0);
    const argument = try e.param(d.split, 1);
    const program = try m.field(e, machine, .program);
    const shapes = try field(
        e,
        try access.code(e, program),
        data.activation.Program,
        "schemas",
    );
    const shape = try e.required(shapes, try e.field(argument, 0));
    const result = try e.b.variable(output);
    const collected = try e.b.variable(fields);
    const product = try emitLoopProduct(
        e,
        parts,
        split_result,
        table,
        loop,
        machine,
        argument,
        shape,
        result,
        collected,
    );
    const tag = try e.b.variable(e.integer);
    const payload = try e.b.variable(v.result);
    const sum = try emitLoopSum(
        e,
        fields,
        parts,
        split_result,
        d,
        machine,
        argument,
        tag,
        payload,
    );
    try e.b.define(d.split, try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{shape},
        0,
    ), try schemaTag(e, .sum)), sum, product));
}

fn readChild(
    e: Author,
    codec: codecs.Definition,
    comptime variant: bool,
    program: Id,
    types: Id,
    index: Id,
    bytes_value: Id,
    start: Id,
    end: Id,
    child_schema: Id,
    decoded: Id,
    next: Id,
) Error!Id {
    const b = e.b;
    var read = next;
    read = try b.bind(end, try e.call(codec.skip, &.{
        program, try b.reference(child_schema), bytes_value, try b.reference(start),
    }), read);
    if (variant) {
        read = try b.bind(start, try b.pure(try e.field(try b.reference(decoded), 1)), read);
        read = try b.bind(child_schema, try b.pure(try e.required(
            types,
            try e.field(try b.reference(decoded), 0),
        )), read);
        read = try b.bind(decoded, try e.call(codec.read, &.{ bytes_value, e.zero }), read);
    } else {
        const prefix = try b.primitive(
            try projection.schema([]const Id, b),
            .sequence_take,
            &.{ types, index },
            0,
        );
        read = try b.bind(start, try e.call(codec.skip_fields, &.{
            program, prefix, bytes_value, e.zero,
        }), read);
        read = try b.bind(child_schema, try b.pure(try e.required(types, index)), read);
    }
    return read;
}
