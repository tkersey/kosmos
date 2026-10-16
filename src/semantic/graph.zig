//! Guest graph operations over persistent ordinary node tables. References are
//! numeric guest data and cannot address the outer executor's control graph.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;

pub const Definition = struct { element: Id, record: Id, replace: Id, append: Id, appended: Id, template: Id, value_ref: Id };

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.graph/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const reference = try projection.schema(g.NodeRef, b);
    const record_schema = try projection.schema(g.Node, b);
    const value_schema = try projection.schema(g.Value, b);
    const appended = try b.schema(.{ .product = &.{ m.schema, reference } });
    const d: Definition = .{
        .element = try b.declare(&.{ m.schema, reference }, m.nodes.element, &.{}, &.{}),
        .record = try b.declare(&.{ m.schema, reference }, record_schema, &.{}, &.{}),
        .replace = try b.declare(&.{ m.schema, reference, record_schema }, m.schema, &.{}, &.{}),
        .append = try b.declare(&.{ m.schema, record_schema }, appended, &.{}, &.{}),
        .appended = appended,
        .template = try b.declare(&.{ m.schema, try projection.schema(g.Capture, b) }, appended, &.{}, &.{}),
        .value_ref = try b.declare(&.{value_schema}, reference, &.{}, &.{}),
    };
    {
        const found = try b.variable(m.nodes.optional);
        try b.define(d.element, try b.bind(found, try e.call(m.nodes.get, &.{ try m.field(e, try e.param(d.element, 0), .nodes), try e.field(try e.param(d.element, 1), 0) }), try b.pure(try e.payload(try b.reference(found), 1))));
        const element = try b.variable(m.nodes.element);
        try b.define(d.record, try b.bind(element, try e.call(d.element, &.{ try e.param(d.record, 0), try e.param(d.record, 1) }), try b.pure(try e.field(try b.reference(element), 0))));
    }
    const optional_frame = b.schemas.items[@intCast(m.nodes.element)].product[1];
    {
        const input = try e.param(d.replace, 0);
        const ref = try e.param(d.replace, 1);
        const replacement = try e.param(d.replace, 2);
        const prior = try b.variable(m.nodes.element);
        const table = try b.variable(m.nodes.table);
        const element = try e.replace(try b.reference(prior), 0, replacement);
        const tag = try b.primitive(e.integer, .variant_tag, &.{replacement}, 0);
        const selected = try b.variable(m.nodes.element);
        const keep = try b.pure(element);
        const clear = try b.pure(try e.replace(element, 1, try e.variant(optional_frame, 0, e.unit_value)));
        const choose = try e.when(try e.binary(.less, tag, try b.constant(u64, 2)), keep, clear);
        try b.define(d.replace, try b.bind(prior, try e.call(d.element, &.{ input, ref }), try b.bind(selected, choose, try b.bind(table, try e.call(m.nodes.set, &.{ try m.field(e, input, .nodes), try e.field(ref, 0), try b.reference(selected) }), try b.pure(try e.replace(input, @backingInt(machines.Field.nodes), try b.reference(table)))))));
    }
    {
        const input = try e.param(d.append, 0);
        const prior = try m.field(e, input, .nodes);
        const ref = try e.tuple(reference, &.{try e.field(prior, 0)});
        const element = try e.tuple(m.nodes.element, &.{ try e.param(d.append, 1), try e.variant(optional_frame, 0, e.unit_value) });
        const table = try b.variable(m.nodes.table);
        try b.define(d.append, try b.bind(table, try e.call(m.nodes.append, &.{ prior, element }), try b.pure(try e.tuple(appended, &.{ try e.replace(input, @backingInt(machines.Field.nodes), try b.reference(table)), ref }))));
    }
    {
        const body = try e.field(try e.param(d.value_ref, 0), 1);
        const tag = try b.primitive(e.integer, .variant_tag, &.{body}, 0);
        try b.define(d.value_ref, try e.when(try e.binary(.equal, tag, try b.constant(u64, 2)), try b.pure(try e.payload(body, 2)), try b.pure(try e.field(try e.payload(body, 3), 0))));
    }
    try b.define(d.template, try e.call(d.append, &.{ try e.param(d.template, 0), try e.variant(record_schema, @backingInt(g.NodeTag.multi_template), try e.param(d.template, 1)) }));
    return cache.finish(b, d);
}

pub fn record(e: Author, comptime tag: g.NodeTag, fields: []const Id) Error!Id {
    const schema = try projection.schema(g.Node, e.b);
    const payload = e.b.schemas.items[@intCast(schema)].sum[@backingInt(tag)];
    return e.variant(schema, @backingInt(tag), try e.tuple(payload, fields));
}

pub fn value(e: Author, schema: Id, reference: Id, owned: bool) Error!Id {
    const value_schema = try projection.schema(g.Value, e.b);
    const body = e.b.schemas.items[@intCast(value_schema)].product[1];
    const payload = if (owned) try e.tuple(try projection.schema(g.OwnedRef, e.b), &.{reference}) else reference;
    return e.tuple(value_schema, &.{ schema, try e.variant(body, if (owned) 3 else 2, payload) });
}
