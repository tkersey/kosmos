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
pub const Definition = struct { construct: Id, parts: Id, tag: Id, field: Id, payload: Id, split: Id, split_result: Id, encode_fields: Id };

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
        .construct = try b.declare(&.{ m.schema, e.integer, e.integer, fields }, v.result, &.{}, &.{}),
        .parts = try b.declare(&.{ m.schema, v.value }, parts, &.{}, &.{}),
        .tag = try b.declare(&.{ m.schema, v.value }, e.integer, &.{}, &.{}),
        .field = try b.declare(&.{ m.schema, v.value, e.integer }, v.result, &.{}, &.{}),
        .payload = try b.declare(&.{ m.schema, v.value }, v.result, &.{}, &.{}),
        .split = try b.declare(&.{ m.schema, v.value }, split_result, &.{}, &.{}),
        .split_result = split_result,
        .encode_fields = try b.declare(&.{ m.schema, fields, bytes }, bytes, &.{}, &.{}),
    };
    {
        const input = try e.param(d.parts, 0);
        const value = try e.param(d.parts, 1);
        const body = try e.field(value, 1);
        const ref = try b.variable(try projection.schema(g.NodeRef, b));
        const found = try b.variable(m.nodes.optional);
        const record = try e.payload(try e.field(try e.payload(try b.reference(found), 1), 0), @backingInt(g.NodeTag.aggregate));
        const select = try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{body}, 0), try b.constant(u64, @backingInt(g.ValueTag.reference))), try b.pure(try e.payload(body, 2)), try b.pure(try e.field(try e.payload(body, 3), 0)));
        try b.define(d.parts, try b.bind(ref, select, try b.bind(found, try e.call(m.nodes.get, &.{ try m.field(e, input, .nodes), try e.field(try b.reference(ref), 0) }), try b.pure(try e.tuple(parts, &.{ try e.field(record, 1), try e.field(record, 2) })))));
    }
    {
        const input = try e.param(d.construct, 0);
        const schema = try e.param(d.construct, 1);
        const tag = try e.param(d.construct, 2);
        const children = try e.param(d.construct, 3);
        const program = try m.field(e, input, .program);
        const shapes = try field(e, try access.code(e, program), data.activation.Program, "schemas");
        const shape = try e.required(shapes, schema);
        const kind = try b.primitive(e.integer, .variant_tag, &.{shape}, 0);
        const facts = try field(e, program, projection.Program, "schemas");
        const exportable = try e.required(try field(e, facts, data.admission.SchemaFacts, "exportable"), schema);
        const prefix = try b.variable(bytes);
        const empty = try b.pure(try e.literal([]const u8, &.{}));
        const count_prefix = try e.call(codec.natural, &.{try b.primitive(e.integer, .sequence_length, &.{children}, 0)});
        var choose_prefix = try e.when(try e.binary(.equal, kind, try schemaTag(e, .sum)), try e.call(codec.natural, &.{tag}), empty);
        inline for (.{ p.SchemaTag.seq, .vector }) |k| choose_prefix = try e.when(try e.binary(.equal, kind, try schemaTag(e, k)), count_prefix, choose_prefix);
        const encode = d.encode_fields;
        {
            const machine = try e.param(encode, 0);
            const tail_fields = try e.param(encode, 1);
            const prior = try e.param(encode, 2);
            const pair_type = try b.schema(.{ .product = &.{ v.value, fields } });
            const optional = try b.schema(.{ .sum = &.{ e.unit, pair_type } });
            const nil = try b.variable(e.unit);
            const pair_var = try b.variable(pair_type);
            const pair = try b.reference(pair_var);
            const encoded = try b.variable(bytes);
            try b.define(encode, try b.term(.{ .match_sum = .{ .value = try b.primitive(optional, .sequence_pop, &.{tail_fields}, 0), .cases = &.{
                .{ .variable = nil, .body = try b.pure(prior) },
                .{ .variable = pair_var, .body = try b.bind(encoded, try e.call(v.bytes, &.{ machine, try e.field(pair, 0) }), try e.call(encode, &.{ machine, try e.field(pair, 1), try e.concat(prior, try b.reference(encoded)) })) },
            } } }));
        }
        const encoded = try b.variable(bytes);
        const literal_type = try projection.schema(p.Literal, b);
        const ordinary = try b.bind(prefix, choose_prefix, try b.bind(encoded, try e.call(encode, &.{ input, children, try b.reference(prefix) }), try e.call(v.literal, &.{ input, try e.tuple(literal_type, &.{ schema, try b.reference(encoded) }) })));
        const old = try m.field(e, input, .nodes);
        const ref = try e.tuple(try projection.schema(g.NodeRef, b), &.{try e.field(old, 0)});
        const body_type = b.schemas.items[@intCast(v.value)].product[1];
        const selected = try b.variable(body_type);
        const copy = try e.required(try field(e, try field(e, program, projection.Program, "uses"), data.traits.Facts, "copy"), schema);
        const choose = try e.when(copy, try b.pure(try e.variant(body_type, 2, ref)), try b.pure(try e.variant(body_type, 3, try e.tuple(try projection.schema(g.OwnedRef, b), &.{ref}))));
        const table = try b.variable(m.nodes.table);
        const aggregate_type = b.schemas.items[@intCast(node_type)].sum[@backingInt(g.NodeTag.aggregate)];
        const record = try e.variant(node_type, @backingInt(g.NodeTag.aggregate), try e.tuple(aggregate_type, &.{ schema, tag, children }));
        const optional_frame = b.schemas.items[@intCast(m.nodes.element)].product[1];
        const item = try e.tuple(m.nodes.element, &.{ record, try e.variant(optional_frame, 0, e.unit_value) });
        const internal = try b.bind(selected, choose, try b.bind(table, try e.call(m.nodes.append, &.{ old, item }), try b.pure(try e.tuple(v.result, &.{ try e.replace(input, @backingInt(machines.Field.nodes), try b.reference(table)), try e.tuple(v.value, &.{ schema, try b.reference(selected) }) }))));
        try b.define(d.construct, try e.when(exportable, ordinary, internal));
    }
    {
        const input = try e.param(d.tag, 0);
        const value = try e.param(d.tag, 1);
        const selected = try b.variable(parts);
        const encoded = try b.variable(bytes);
        const decoded = try b.variable(try projection.schema(codecs.Read, b));
        const from_bytes = try b.bind(encoded, try e.call(v.bytes, &.{ input, value }), try b.bind(decoded, try e.call(codec.read, &.{ try b.reference(encoded), e.zero }), try b.pure(try e.field(try b.reference(decoded), 0))));
        const from_fields = try b.bind(selected, try e.call(d.parts, &.{ input, value }), try b.pure(try e.field(try b.reference(selected), 0)));
        try b.define(d.tag, try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{try e.field(value, 1)}, 0), e.one), from_bytes, from_fields));
    }
    inline for (.{ false, true }) |variant| {
        const entry = if (variant) d.payload else d.field;
        const input = try e.param(entry, 0);
        const value = try e.param(entry, 1);
        const index = if (variant) e.zero else try e.param(entry, 2);
        const selected = try b.variable(parts);
        const from_fields = try b.bind(selected, try e.call(d.parts, &.{ input, value }), try b.pure(try e.tuple(v.result, &.{ input, try e.required(try e.field(try b.reference(selected), 1), index) })));
        const program = try m.field(e, input, .program);
        const shapes = try field(e, try access.code(e, program), data.activation.Program, "schemas");
        const shape = try e.required(shapes, try e.field(value, 0));
        const types = try e.payload(shape, @backingInt(if (variant) p.SchemaTag.sum else p.SchemaTag.product));
        const encoded = try b.variable(bytes);
        const start = try b.variable(e.integer);
        const end = try b.variable(e.integer);
        const child_schema = try b.variable(e.integer);
        const decoded = try b.variable(try projection.schema(codecs.Read, b));
        const bytes_value = try b.reference(encoded);
        const literal_type = try projection.schema(p.Literal, b);
        var read = try e.call(v.literal, &.{ input, try e.tuple(literal_type, &.{ try b.reference(child_schema), try e.slice(bytes_value, try b.reference(start), try b.reference(end)) }) });
        read = try b.bind(end, try e.call(codec.skip, &.{ program, try b.reference(child_schema), bytes_value, try b.reference(start) }), read);
        if (variant) {
            read = try b.bind(start, try b.pure(try e.field(try b.reference(decoded), 1)), read);
            read = try b.bind(child_schema, try b.pure(try e.required(types, try e.field(try b.reference(decoded), 0))), read);
            read = try b.bind(decoded, try e.call(codec.read, &.{ bytes_value, e.zero }), read);
        } else {
            const prefix = try b.primitive(try projection.schema([]const Id, b), .sequence_take, &.{ types, index }, 0);
            read = try b.bind(start, try e.call(codec.skip_fields, &.{ program, prefix, bytes_value, e.zero }), read);
            read = try b.bind(child_schema, try b.pure(try e.required(types, index)), read);
        }
        read = try b.bind(encoded, try e.call(v.bytes, &.{ input, value }), read);
        try b.define(entry, try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{try e.field(value, 1)}, 0), e.one), read, from_fields));
    }
    {
        const table = try @import("table.zig").define(b, v.value);
        const output = try b.schema(.{ .product = &.{ m.schema, table.table } });
        const loop = try b.declare(&.{ m.schema, v.value, e.integer, e.integer, table.table }, output, &.{}, &.{});
        const input = try e.param(loop, 0);
        const value = try e.param(loop, 1);
        const index = try e.param(loop, 2);
        const count = try e.param(loop, 3);
        const prior = try e.param(loop, 4);
        const selected = try b.variable(v.result);
        const appended = try b.variable(table.table);
        const more = try b.bind(selected, try e.call(d.field, &.{ input, value, index }), try b.bind(appended, try e.call(table.append, &.{ prior, try e.field(try b.reference(selected), 1) }), try e.call(loop, &.{ try e.field(try b.reference(selected), 0), value, try e.binary(.integer_add, index, e.one), count, try b.reference(appended) })));
        try b.define(loop, try e.when(try e.binary(.less, index, count), more, try b.pure(try e.tuple(output, &.{ input, prior }))));
        const machine = try e.param(d.split, 0);
        const argument = try e.param(d.split, 1);
        const program = try m.field(e, machine, .program);
        const shapes = try field(e, try access.code(e, program), data.activation.Program, "schemas");
        const shape = try e.required(shapes, try e.field(argument, 0));
        const result = try b.variable(output);
        const collected = try b.variable(fields);
        const product = try b.bind(result, try e.call(loop, &.{ machine, argument, e.zero, try b.primitive(e.integer, .sequence_length, &.{try e.payload(shape, @backingInt(p.SchemaTag.product))}, 0), try table.empty(b) }), try b.bind(collected, try e.call(table.to_sequence, &.{try e.field(try b.reference(result), 1)}), try b.pure(try e.tuple(split_result, &.{ try e.field(try b.reference(result), 0), try e.tuple(parts, &.{ e.zero, try b.reference(collected) }) }))));
        const tag = try b.variable(e.integer);
        const payload = try b.variable(v.result);
        const sum = try b.bind(tag, try e.call(d.tag, &.{ machine, argument }), try b.bind(payload, try e.call(d.payload, &.{ machine, argument }), try b.pure(try e.tuple(split_result, &.{ try e.field(try b.reference(payload), 0), try e.tuple(parts, &.{ try b.reference(tag), try b.primitive(fields, .sequence, &.{try e.field(try b.reference(payload), 1)}, 0) }) }))));
        try b.define(d.split, try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{shape}, 0), try schemaTag(e, .sum)), sum, product));
    }
    return cache.finish(b, d);
}
