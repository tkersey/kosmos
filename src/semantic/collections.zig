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
pub const Collection = struct { element: u64, count: u64, storage: union(enum) { encoded: Encoded, fields: []const g.Value } };
pub const Definition = struct { schema: Id, view: Id, range: Id, item: Id, rebuild: Id };

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
        .rebuild = try b.declare(&.{ m.schema, e.integer, e.integer, segments }, v.result, &.{}, &.{}),
    };
    {
        const input = try e.param(d.view, 0);
        const value = try e.param(d.view, 1);
        const program = try m.field(e, input, .program);
        const shapes = try field(e, try access.code(e, program), data.activation.Program, "schemas");
        const shape = try e.required(shapes, try e.field(value, 0));
        const kind = try b.primitive(e.integer, .variant_tag, &.{shape}, 0);
        const element = try b.variable(e.integer);
        var choose_element = try b.pure(try e.payload(shape, @backingInt(p.SchemaTag.seq)));
        inline for ([_]p.SchemaTag{ .array, .vector }) |tag| choose_element = try e.when(try e.binary(.equal, kind, try b.constant(u64, @backingInt(tag))), try b.pure(try e.field(try e.payload(shape, @backingInt(tag)), 0)), choose_element);
        const raw = try b.variable(bytes);
        const read = try b.variable(try projection.schema(codecs.Read, b));
        const count_offset = try b.reference(read);
        const array_count = try e.tuple(try projection.schema(codecs.Read, b), &.{ try e.field(try e.payload(shape, @backingInt(p.SchemaTag.array)), 1), e.zero });
        const choose_count = try e.when(try e.binary(.equal, kind, try b.constant(u64, @backingInt(p.SchemaTag.array))), try b.pure(array_count), try e.call(codec.read, &.{ try b.reference(raw), e.zero }));
        const encoded = try e.tuple(encoded_type, &.{ try b.reference(raw), try e.field(count_offset, 1), try b.primitive(e.integer, .blob_length, &.{try b.reference(raw)}, 0) });
        const ordinary = try b.bind(raw, try e.call(v.bytes, &.{ input, value }), try b.bind(read, choose_count, try b.pure(try e.tuple(schema, &.{ try b.reference(element), try e.field(count_offset, 0), try e.variant(storage_type, 0, encoded) }))));
        const parts = try b.variable(try projection.schema(aggregates.Parts, b));
        const children = try e.field(try b.reference(parts), 1);
        const internal = try b.bind(parts, try e.call(aggregate.parts, &.{ input, value }), try b.pure(try e.tuple(schema, &.{ try b.reference(element), try b.primitive(e.integer, .sequence_length, &.{children}, 0), try e.variant(storage_type, 1, children) })));
        try b.define(d.view, try b.bind(element, choose_element, try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{try e.field(value, 1)}, 0), e.one), ordinary, internal)));
    }
    {
        const drop = try b.declare(&.{ fields, e.integer }, fields, &.{}, &.{});
        const input = try e.param(drop, 0);
        const count = try e.param(drop, 1);
        const pair_type = try b.schema(.{ .product = &.{ v.value, fields } });
        const optional = try b.schema(.{ .sum = &.{ e.unit, pair_type } });
        const rest = try e.field(try e.payload(try b.primitive(optional, .sequence_pop, &.{input}, 0), 1), 1);
        try b.define(drop, try e.when(try e.binary(.equal, count, e.zero), try b.pure(input), try e.call(drop, &.{ rest, try e.binary(.integer_sub, count, e.one) })));
        const program = try e.param(d.range, 0);
        const collection = try e.param(d.range, 1);
        const start = try e.param(d.range, 2);
        const length = try e.param(d.range, 3);
        const encoded_var = try b.variable(encoded_type);
        const fields_var = try b.variable(fields);
        const encoded = try b.reference(encoded_var);
        const begin = try b.variable(e.integer);
        const end = try b.variable(e.integer);
        const ordinary = try b.bind(begin, try e.call(codec.skip_many, &.{ program, try e.field(collection, 0), try e.field(encoded, 0), try e.field(encoded, 1), start }), try b.bind(end, try e.call(codec.skip_many, &.{ program, try e.field(collection, 0), try e.field(encoded, 0), try b.reference(begin), length }), try b.pure(try e.tuple(schema, &.{ try e.field(collection, 0), length, try e.variant(storage_type, 0, try e.tuple(encoded_type, &.{ try e.field(encoded, 0), try b.reference(begin), try b.reference(end) })) }))));
        const dropped = try b.variable(fields);
        const internal = try b.bind(dropped, try e.call(drop, &.{ try b.reference(fields_var), start }), try b.pure(try e.tuple(schema, &.{ try e.field(collection, 0), length, try e.variant(storage_type, 1, try b.primitive(fields, .sequence_take, &.{ try b.reference(dropped), length }, 0)) })));
        try b.define(d.range, try b.term(.{ .match_sum = .{ .value = try e.field(collection, 2), .cases = &.{ .{ .variable = encoded_var, .body = ordinary }, .{ .variable = fields_var, .body = internal } } } }));
    }
    {
        const input = try e.param(d.item, 0);
        const collection = try e.param(d.item, 1);
        const selected = try b.variable(schema);
        const encoded_var = try b.variable(encoded_type);
        const fields_var = try b.variable(fields);
        const encoded = try b.reference(encoded_var);
        const ordinary = try e.call(v.literal, &.{ input, try e.tuple(try projection.schema(p.Literal, b), &.{ try e.field(collection, 0), try e.slice(try e.field(encoded, 0), try e.field(encoded, 1), try e.field(encoded, 2)) }) });
        const internal = try b.pure(try e.tuple(v.result, &.{ input, try e.required(try b.reference(fields_var), e.zero) }));
        try b.define(d.item, try b.bind(selected, try e.call(d.range, &.{ try m.field(e, input, .program), collection, try e.param(d.item, 2), e.one }), try b.term(.{ .match_sum = .{ .value = try e.field(try b.reference(selected), 2), .cases = &.{ .{ .variable = encoded_var, .body = ordinary }, .{ .variable = fields_var, .body = internal } } } })));
    }
    {
        const pair_type = try b.schema(.{ .product = &.{ schema, segments } });
        const optional = try b.schema(.{ .sum = &.{ e.unit, pair_type } });
        const encode = try b.declare(&.{ m.schema, segments, bytes }, bytes, &.{}, &.{});
        const collect = try b.declare(&.{ segments, fields }, fields, &.{}, &.{});
        inline for (.{ true, false }) |encoding| {
            const entry = if (encoding) encode else collect;
            const input_segments = try e.param(entry, if (encoding) 1 else 0);
            const prior = try e.param(entry, if (encoding) 2 else 1);
            const nil = try b.variable(e.unit);
            const pair_var = try b.variable(pair_type);
            const pair = try b.reference(pair_var);
            const head = try e.field(pair, 0);
            const rest = try e.field(pair, 1);
            var visit: Id = undefined;
            if (encoding) {
                const machine = try e.param(entry, 0);
                const encoded_var = try b.variable(encoded_type);
                const fields_var = try b.variable(fields);
                const encoded = try b.reference(encoded_var);
                const part_bytes = try b.variable(bytes);
                const choose = try b.term(.{ .match_sum = .{ .value = try e.field(head, 2), .cases = &.{
                    .{ .variable = encoded_var, .body = try b.pure(try e.slice(try e.field(encoded, 0), try e.field(encoded, 1), try e.field(encoded, 2))) },
                    .{ .variable = fields_var, .body = try e.call(aggregate.encode_fields, &.{ machine, try b.reference(fields_var), try e.literal([]const u8, &.{}) }) },
                } } });
                visit = try b.bind(part_bytes, choose, try e.call(encode, &.{ machine, rest, try e.concat(prior, try b.reference(part_bytes)) }));
            } else {
                const children = try e.payload(try e.field(head, 2), 1);
                visit = try e.call(collect, &.{ rest, try b.primitive(fields, .sequence_concat, &.{ prior, children }, 0) });
            }
            try b.define(entry, try b.term(.{ .match_sum = .{ .value = try b.primitive(optional, .sequence_pop, &.{input_segments}, 0), .cases = &.{ .{ .variable = nil, .body = try b.pure(prior) }, .{ .variable = pair_var, .body = visit } } } }));
        }
        const input = try e.param(d.rebuild, 0);
        const result_type = try e.param(d.rebuild, 1);
        const count = try e.param(d.rebuild, 2);
        const input_segments = try e.param(d.rebuild, 3);
        const program = try m.field(e, input, .program);
        const shape = try e.required(try field(e, try access.code(e, program), data.activation.Program, "schemas"), result_type);
        const exportable = try e.required(try field(e, try field(e, program, projection.Program, "schemas"), data.admission.SchemaFacts, "exportable"), result_type);
        const prefix = try b.variable(bytes);
        const encoded = try b.variable(bytes);
        const choose_prefix = try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{shape}, 0), try b.constant(u64, @backingInt(p.SchemaTag.array))), try b.pure(try e.literal([]const u8, &.{})), try e.call(codec.natural, &.{count}));
        const ordinary = try b.bind(prefix, choose_prefix, try b.bind(encoded, try e.call(encode, &.{ input, input_segments, try b.reference(prefix) }), try e.call(v.literal, &.{ input, try e.tuple(try projection.schema(p.Literal, b), &.{ result_type, try b.reference(encoded) }) })));
        const children = try b.variable(fields);
        const internal = try b.bind(children, try e.call(collect, &.{ input_segments, try e.literal([]const g.Value, &.{}) }), try e.call(aggregate.construct, &.{ input, result_type, e.zero, try b.reference(children) }));
        try b.define(d.rebuild, try e.when(exportable, ordinary, internal));
    }
    return cache.finish(b, d);
}
