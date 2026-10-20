//! Logical collection ranges over encoded bytes or internal guest values.
//! Zero-width cardinality never becomes a host-sized array of empty elements.
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const values = @import("values.zig");
const aggregates = @import("aggregate.zig");
const codecs = @import("codec.zig");
const access = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const p = data.program;
const g = data.graph;
const field = access.field;

pub const Encoded = struct { bytes: []const u8, start: u64, end: u64 };
pub const Collection = struct {
    element: u64,
    count: u64,
    storage: union(enum) { encoded: Encoded, fields: []const g.Value },
};
pub const Definition = struct {
    schema: Id,
    view: Id,
    range: Id,
    item: Id,
    cached_item: Id,
    rebuild: Id,
};

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.collections/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const v = try values.define(b, m);
    const aggregate = try aggregates.define(b, m);
    const codec = try codecs.define(b, m);
    const schema = try projection.schema(Collection, b);
    const encoded_type = try projection.schema(Encoded, b);
    const storage_type = b.schemas.items[@intCast(schema)].product[2];
    const fields = try projection.schema([]const g.Value, b);
    const bytes = try b.schema(.bytes);
    const segments = try projection.schema([]const Collection, b);
    const d: Definition = .{
        .schema = schema,
        .view = try b.declare(&.{ m.schema, v.value }, schema, &.{}, &.{}),
        .range = try b.declare(&.{ m.program, schema, e.integer, e.integer }, schema, &.{}, &.{}),
        .item = try b.declare(&.{ m.schema, schema, e.integer }, v.result, &.{}, &.{}),
        .cached_item = try b.declare(&.{
            m.schema, v.value, schema, e.integer,
        }, v.result, &.{}, &.{}),
        .rebuild = try b.declare(&.{
            m.schema, e.integer, e.integer, segments,
        }, v.result, &.{}, &.{}),
    };
    try emitView(m, e, v, aggregate, codec, schema, encoded_type, storage_type, bytes, d);
    try emitDrop(e, v, codec, schema, encoded_type, storage_type, fields, d);
    try emitItem(m, e, v, schema, encoded_type, fields, d);
    try emitCachedItem(m, e, codec, encoded_type, fields, d);
    try emitEntry(m, e, v, aggregate, codec, schema, encoded_type, fields, bytes, segments, d);
    return cache.finish(b, d);
}

fn emitCachedItem(
    m: machines.Definition,
    e: Author,
    codec: codecs.Definition,
    encoded_type: Id,
    fields: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.cached_item, 0);
    const value = try e.param(d.cached_item, 1);
    const collection = try e.param(d.cached_item, 2);
    const index = try e.param(d.cached_item, 3);
    const encoded_var = try e.b.variable(encoded_type);
    const fields_var = try e.b.variable(fields);
    const encoded = try e.b.reference(encoded_var);
    const range = try cachedRange(m, e, codec, input, value, collection, index, encoded);
    const cached = try @import("projection_cache.zig").read(
        e,
        m,
        input,
        value,
        index,
        .element,
        range,
    );
    try e.b.define(d.cached_item, try e.b.term(.{ .match_sum = .{
        .value = try e.field(collection, 2),
        .cases = &.{
            .{ .variable = encoded_var, .body = cached },
            .{ .variable = fields_var, .body = try e.call(d.item, &.{
                input, collection, index,
            }) },
        },
    } }));
}

fn cachedRange(
    m: machines.Definition,
    e: Author,
    codec: codecs.Definition,
    input: Id,
    value: Id,
    collection: Id,
    index: Id,
    encoded: Id,
) Error!Id {
    const program = try m.field(e, input, .program);
    const element = try e.field(collection, 0);
    const bytes = try e.field(encoded, 0);
    const begin = try e.b.variable(e.integer);
    const end = try e.b.variable(e.integer);
    const from_start = try e.call(codec.skip_many, &.{
        program, element, bytes, try e.field(encoded, 1), index,
    });
    const optional = try e.b.schema(.{ .sum = &.{ e.unit, m.cache.range } });
    const prior = try e.b.variable(optional);
    const absent = try e.b.variable(e.unit);
    const present = try e.b.variable(m.cache.range);
    const seek = try e.b.bind(prior, try @import("projection_cache.zig").lookup(
        e,
        m,
        input,
        value,
        try e.binary(.integer_sub, index, e.one),
    ), try e.b.term(.{ .match_sum = .{ .value = try e.b.reference(prior), .cases = &.{
        .{ .variable = absent, .body = from_start },
        .{ .variable = present, .body = try e.b.pure(try e.field(try e.b.reference(present), 2)) },
    } } }));
    const start = try e.when(try e.binary(.equal, index, e.zero), from_start, seek);
    return e.b.bind(begin, start, try e.b.bind(end, try e.call(codec.skip, &.{
        program, element, bytes, try e.b.reference(begin),
    }), try e.b.pure(try e.tuple(m.cache.range, &.{
        element, try e.b.reference(begin), try e.b.reference(end),
    }))));
}

fn emitView(
    m: machines.Definition,
    e: Author,
    v: values.Definition,
    aggregate: aggregates.Definition,
    codec: codecs.Definition,
    schema: Id,
    encoded_type: Id,
    storage_type: anytype,
    bytes: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.view, 0);
    const value = try e.param(d.view, 1);
    const program = try m.field(e, input, .program);
    const shapes = try field(
        e,
        try access.code(e, program),
        data.activation.Program,
        "schemas",
    );
    const shape = try e.required(shapes, try e.field(value, 0));
    const kind = try e.b.primitive(e.integer, .variant_tag, &.{shape}, 0);
    const element = try e.b.variable(e.integer);
    const choose_element = try chooseElement(e, shape, kind);
    const raw = try e.b.variable(bytes);
    const read = try e.b.variable(try projection.schema(codecs.Read, e.b));
    const count_offset = try e.b.reference(read);
    const array_count = try emitViewArrayCount(e, shape);
    const choose_count = try e.when(try e.binary(.equal, kind, try e.b.constant(
        u64,
        @backingInt(p.SchemaTag.array),
    )), try e.b.pure(array_count), try e.call(codec.read, &.{ try e.b.reference(raw), e.zero }));
    const encoded = try emitViewEncoded(e, encoded_type, raw, count_offset);
    const ordinary = try emitViewOrdinary(
        e,
        v,
        schema,
        storage_type,
        input,
        value,
        element,
        raw,
        read,
        count_offset,
        choose_count,
        encoded,
    );
    const parts = try e.b.variable(try projection.schema(aggregates.Parts, e.b));
    const children = try e.field(try e.b.reference(parts), 1);
    const internal = try e.b.bind(parts, try e.call(
        aggregate.parts,
        &.{ input, value },
    ), try e.b.pure(try e.tuple(schema, &.{ try e.b.reference(element), try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{children},
        0,
    ), try e.variant(storage_type, 1, children) })));
    try emitViewViewDefinition(e, d, value, element, choose_element, ordinary, internal);
}

fn emitDrop(
    e: Author,
    v: values.Definition,
    codec: codecs.Definition,
    schema: Id,
    encoded_type: Id,
    storage_type: anytype,
    fields: Id,
    d: Definition,
) Error!void {
    const drop = try e.b.declare(&.{ fields, e.integer }, fields, &.{}, &.{});
    const input = try e.param(drop, 0);
    const count = try e.param(drop, 1);
    const pair_type = try e.b.schema(.{ .product = &.{ v.value, fields } });
    const optional = try e.b.schema(.{ .sum = &.{ e.unit, pair_type } });
    const rest = try e.field(try e.payload(try e.b.primitive(
        optional,
        .sequence_pop,
        &.{input},
        0,
    ), 1), 1);
    try e.b.define(
        drop,
        try e.when(
            try e.binary(.equal, count, e.zero),
            try e.b.pure(input),
            try e.call(drop, &.{
                rest,
                try e.binary(.integer_sub, count, e.one),
            }),
        ),
    );
    const program = try e.param(d.range, 0);
    const collection = try e.param(d.range, 1);
    const start = try e.param(d.range, 2);
    const length = try e.param(d.range, 3);
    const encoded_var = try e.b.variable(encoded_type);
    const fields_var = try e.b.variable(fields);
    const encoded = try e.b.reference(encoded_var);
    const begin = try e.b.variable(e.integer);
    const end = try e.b.variable(e.integer);
    const ordinary = try emitDropOrdinary(
        e,
        codec,
        schema,
        encoded_type,
        storage_type,
        program,
        collection,
        start,
        length,
        encoded,
        begin,
        end,
    );
    const dropped = try e.b.variable(fields);
    const internal = try emitDropInternal(
        e,
        schema,
        storage_type,
        fields,
        drop,
        collection,
        start,
        length,
        fields_var,
        dropped,
    );
    try emitDropRangeDefinition(e, d, collection, encoded_var, fields_var, ordinary, internal);
}

fn emitItem(
    m: machines.Definition,
    e: Author,
    v: values.Definition,
    schema: Id,
    encoded_type: Id,
    fields: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.item, 0);
    const collection = try e.param(d.item, 1);
    const selected = try e.b.variable(schema);
    const encoded_var = try e.b.variable(encoded_type);
    const fields_var = try e.b.variable(fields);
    const encoded = try e.b.reference(encoded_var);
    const ordinary = try e.call(
        v.literal,
        &.{
            input,
            try e.tuple(
                try projection.schema(p.Literal, e.b),
                &.{
                    try e.field(collection, 0),
                    try e.slice(
                        try e.field(encoded, 0),
                        try e.field(encoded, 1),
                        try e.field(encoded, 2),
                    ),
                },
            ),
        },
    );
    const internal = try e.b.pure(try e.tuple(v.result, &.{ input, try e.required(
        try e.b.reference(fields_var),
        e.zero,
    ) }));
    try e.b.define(d.item, try e.b.bind(selected, try e.call(d.range, &.{
        try m.field(e, input, .program), collection, try e.param(d.item, 2), e.one,
    }), try e.b.term(
        .{
            .match_sum = .{
                .value = try e.field(try e.b.reference(
                    selected,
                ), 2),
                .cases = &.{
                    .{ .variable = encoded_var, .body = ordinary },
                    .{ .variable = fields_var, .body = internal },
                },
            },
        },
    )));
}

fn emitEntry(
    m: machines.Definition,
    e: Author,
    v: values.Definition,
    aggregate: aggregates.Definition,
    codec: codecs.Definition,
    schema: Id,
    encoded_type: Id,
    fields: Id,
    bytes: Id,
    segments: Id,
    d: Definition,
) Error!void {
    const pair_type = try e.b.schema(.{ .product = &.{ schema, segments } });
    const optional = try e.b.schema(.{ .sum = &.{ e.unit, pair_type } });
    const encode = try e.b.declare(&.{ m.schema, segments, bytes }, bytes, &.{}, &.{});
    const collect = try e.b.declare(&.{ segments, fields }, fields, &.{}, &.{});
    try emitSegments(
        e,
        aggregate,
        encoded_type,
        fields,
        bytes,
        pair_type,
        optional,
        encode,
        collect,
    );
    const input = try e.param(d.rebuild, 0);
    const result_type = try e.param(d.rebuild, 1);
    const count = try e.param(d.rebuild, 2);
    const input_segments = try e.param(d.rebuild, 3);
    const program = try m.field(e, input, .program);
    const shape_choose_prefix = try emitEntryShapeChoosePrefix(
        e,
        codec,
        bytes,
        result_type,
        count,
        program,
    );
    const exportable = shape_choose_prefix.exportable;
    const prefix = shape_choose_prefix.prefix;
    const encoded = shape_choose_prefix.encoded;
    const choose_prefix = shape_choose_prefix.choose_prefix;
    const ordinary = try emitEntryOrdinary(
        e,
        v,
        encode,
        input_segments,
        encoded,
        input,
        result_type,
        prefix,
        choose_prefix,
    );
    const children = try e.b.variable(fields);
    const internal = try e.b.bind(children, try e.call(collect, &.{
        input_segments, try e.literal([]const g.Value, &.{}),
    }), try e.call(aggregate.construct, &.{
        input, result_type, e.zero, try e.b.reference(children),
    }));
    try e.b.define(d.rebuild, try e.when(exportable, ordinary, internal));
}

fn emitViewArrayCount(e: Author, shape: Id) Error!Id {
    return try e.tuple(
        try projection.schema(codecs.Read, e.b),
        &.{ try e.field(
            try e.payload(
                shape,
                @backingInt(p.SchemaTag.array),
            ),
            1,
        ), e.zero },
    );
}

fn emitViewEncoded(e: Author, encoded_type: Id, raw: Id, count_offset: Id) Error!Id {
    return try e.tuple(
        encoded_type,
        &.{
            try e.b.reference(raw),
            try e.field(count_offset, 1),
            try e.b.primitive(e.integer, .blob_length, &.{try e.b.reference(raw)}, 0),
        },
    );
}

fn emitViewOrdinary(
    e: Author,
    v: values.Definition,
    schema: Id,
    storage_type: anytype,
    input: Id,
    value: Id,
    element: Id,
    raw: Id,
    read: Id,
    count_offset: Id,
    choose_count: Id,
    encoded: Id,
) Error!Id {
    return try e.b.bind(
        raw,
        try e.call(v.bytes, &.{
            input,
            value,
        }),
        try e.b.bind(
            read,
            choose_count,
            try e.b.pure(
                try e.tuple(
                    schema,
                    &.{
                        try e.b.reference(element),
                        try e.field(count_offset, 0),
                        try e.variant(storage_type, 0, encoded),
                    },
                ),
            ),
        ),
    );
}

fn emitDropOrdinary(
    e: Author,
    codec: codecs.Definition,
    schema: Id,
    encoded_type: Id,
    storage_type: anytype,
    program: Id,
    collection: Id,
    start: Id,
    length: Id,
    encoded: Id,
    begin: Id,
    end: Id,
) Error!Id {
    return try e.b.bind(begin, try e.call(codec.skip_many, &.{
        program,
        try e.field(collection, 0),
        try e.field(encoded, 0),
        try e.field(encoded, 1),
        start,
    }), try e.b.bind(end, try e.call(codec.skip_many, &.{
        program,
        try e.field(collection, 0),
        try e.field(encoded, 0),
        try e.b.reference(begin),
        length,
    }), try e.b.pure(
        try e.tuple(
            schema,
            &.{
                try e.field(collection, 0),
                length,
                try e.variant(
                    storage_type,
                    0,
                    try e.tuple(
                        encoded_type,
                        &.{
                            try e.field(encoded, 0),
                            try e.b.reference(begin),
                            try e.b.reference(end),
                        },
                    ),
                ),
            },
        ),
    )));
}

fn emitDropInternal(
    e: Author,
    schema: Id,
    storage_type: anytype,
    fields: Id,
    drop: Id,
    collection: Id,
    start: Id,
    length: Id,
    fields_var: Id,
    dropped: Id,
) Error!Id {
    return try e.b.bind(dropped, try e.call(drop, &.{
        try e.b.reference(fields_var),
        start,
    }), try e.b.pure(
        try e.tuple(
            schema,
            &.{
                try e.field(collection, 0),
                length,
                try e.variant(
                    storage_type,
                    1,
                    try e.b.primitive(
                        fields,
                        .sequence_take,
                        &.{ try e.b.reference(dropped), length },
                        0,
                    ),
                ),
            },
        ),
    ));
}

fn emitEntryChoose(
    e: Author,
    aggregate: aggregates.Definition,
    head: Id,
    machine: Id,
    encoded_var: Id,
    fields_var: Id,
    encoded: Id,
) Error!Id {
    return try e.b.term(
        .{
            .match_sum = .{
                .value = try e.field(head, 2),
                .cases = &.{
                    .{ .variable = encoded_var, .body = try e.b.pure(try e.slice(
                        try e.field(encoded, 0),
                        try e.field(encoded, 1),
                        try e.field(encoded, 2),
                    )) },
                    .{
                        .variable = fields_var,
                        .body = try e.call(
                            aggregate.encode_fields,
                            &.{
                                machine,
                                try e.b.reference(fields_var),
                                try e.literal([]const u8, &.{}),
                            },
                        ),
                    },
                },
            },
        },
    );
}

fn emitEntryOrdinary(
    e: Author,
    v: values.Definition,
    encode: Id,
    input_segments: Id,
    encoded: Id,
    input: Id,
    result_type: Id,
    prefix: Id,
    choose_prefix: Id,
) Error!Id {
    return try e.b.bind(
        prefix,
        choose_prefix,
        try e.b.bind(
            encoded,
            try e.call(encode, &.{
                input,
                input_segments,
                try e.b.reference(prefix),
            }),
            try e.call(
                v.literal,
                &.{
                    input,
                    try e.tuple(
                        try projection.schema(p.Literal, e.b),
                        &.{ result_type, try e.b.reference(encoded) },
                    ),
                },
            ),
        ),
    );
}

fn emitViewViewDefinition(
    e: Author,
    d: Definition,
    value: Id,
    element: Id,
    choose_element: Id,
    ordinary: anytype,
    internal: Id,
) Error!void {
    try e.b.define(
        d.view,
        try e.b.bind(
            element,
            choose_element,
            try e.when(
                try e.binary(
                    .equal,
                    try e.b.primitive(e.integer, .variant_tag, &.{try e.field(value, 1)}, 0),
                    e.one,
                ),
                ordinary,
                internal,
            ),
        ),
    );
}

fn emitDropRangeDefinition(
    e: Author,
    d: Definition,
    collection: Id,
    encoded_var: Id,
    fields_var: Id,
    ordinary: anytype,
    internal: anytype,
) Error!void {
    try e.b.define(
        d.range,
        try e.b.term(
            .{
                .match_sum = .{
                    .value = try e.field(collection, 2),
                    .cases = &.{
                        .{ .variable = encoded_var, .body = ordinary },
                        .{ .variable = fields_var, .body = internal },
                    },
                },
            },
        ),
    );
}

fn emitEntryShapeChoosePrefix(
    e: Author,
    codec: codecs.Definition,
    bytes: Id,
    result_type: anytype,
    count: anytype,
    program: anytype,
) Error!struct { exportable: Id, prefix: Id, encoded: Id, choose_prefix: Id } {
    const shape = try e.required(try field(
        e,
        try access.code(e, program),
        data.activation.Program,
        "schemas",
    ), result_type);
    const exportable = try e.required(try field(e, try field(
        e,
        program,
        projection.Program,
        "schemas",
    ), data.admission.SchemaFacts, "exportable"), result_type);
    const prefix = try e.b.variable(bytes);
    const encoded = try e.b.variable(bytes);
    const choose_prefix = try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{shape},
        0,
    ), try e.b.constant(
        u64,
        @backingInt(p.SchemaTag.array),
    )), try e.b.pure(try e.literal([]const u8, &.{})), try e.call(codec.natural, &.{count}));
    return .{
        .exportable = exportable,
        .prefix = prefix,
        .encoded = encoded,
        .choose_prefix = choose_prefix,
    };
}

fn chooseElement(e: Author, shape: Id, kind: Id) Error!Id {
    var choose_element = try e.b.pure(try e.payload(shape, @backingInt(p.SchemaTag.seq)));
    inline for ([_]p.SchemaTag{
        .array,
        .vector,
    }) |tag| choose_element = try e.when(
        try e.binary(.equal, kind, try e.b.constant(u64, @backingInt(tag))),
        try e.b.pure(try e.field(
            try e.payload(shape, @backingInt(tag)),
            0,
        )),
        choose_element,
    );
    return choose_element;
}

fn emitSegments(
    e: Author,
    aggregate: aggregates.Definition,
    encoded_type: Id,
    fields: Id,
    bytes: Id,
    pair_type: Id,
    optional: Id,
    encode: Id,
    collect: Id,
) Error!void {
    inline for (.{ true, false }) |encoding| {
        const entry = if (encoding) encode else collect;
        const input_segments = try e.param(entry, if (encoding) 1 else 0);
        const prior = try e.param(entry, if (encoding) 2 else 1);
        const nil = try e.b.variable(e.unit);
        const pair_var = try e.b.variable(pair_type);
        const pair = try e.b.reference(pair_var);
        const head = try e.field(pair, 0);
        const rest = try e.field(pair, 1);
        var visit: Id = undefined;
        if (encoding) {
            const machine = try e.param(entry, 0);
            const encoded_var = try e.b.variable(encoded_type);
            const fields_var = try e.b.variable(fields);
            const encoded = try e.b.reference(encoded_var);
            const part_bytes = try e.b.variable(bytes);
            const choose = try emitEntryChoose(
                e,
                aggregate,
                head,
                machine,
                encoded_var,
                fields_var,
                encoded,
            );
            visit = try e.b.bind(part_bytes, choose, try e.call(encode, &.{
                machine, rest, try e.concat(prior, try e.b.reference(part_bytes)),
            }));
        } else {
            const children = try e.payload(try e.field(head, 2), 1);
            visit = try e.call(collect, &.{ rest, try e.b.primitive(
                fields,
                .sequence_concat,
                &.{ prior, children },
                0,
            ) });
        }
        try e.b.define(entry, try e.b.term(.{ .match_sum = .{ .value = try e.b.primitive(
            optional,
            .sequence_pop,
            &.{input_segments},
            0,
        ), .cases = &.{ .{ .variable = nil, .body = try e.b.pure(prior) }, .{
            .variable = pair_var,
            .body = visit,
        } } } }));
    }
}
