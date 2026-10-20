const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const compiler = @import("compiler.zig");
const sites_data = @import("transformation_sites.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Value = source.ast.Value;
const Term = source.ast.Term;
const Expression = @FieldType(Value, "expression");
const Primitive = @FieldType(Expression, "primitive");
const Case = std.meta.Elem(@FieldType(@FieldType(Term, "match_sum"), "cases"));
const Map = struct {
    function: Id,
    selected: Id,
    order: Id,
    source_values: Id,
    original: Id,
    cursor: Id,
    result: Id,
    sites: ?Id,
    row: Id,
};

pub const Input = struct { module: source.ast.Module, layout: source.relation.Layout };
pub const IndexedInput = struct {
    module: source.ast.Module,
    layout: source.relation.Layout,
    references: compiler.SourceReferences,
};
const Definition = struct {
    entry: Id,
    reorder: Id,
    inverse: Id,
    values: Id,
    terms: Id,
    collect: ?Id,
};

pub fn define(b: *source.Builder) !Id {
    return defineWithIndex(b, false);
}

pub fn defineIndexed(b: *source.Builder) !Id {
    return defineWithIndex(b, true);
}

fn defineWithIndex(b: *source.Builder, comptime indexed: bool) !Id {
    const e = try Author.init(b);
    const ids = try projection.schema([]const Id, b);
    const input = try projection.schema(if (indexed) IndexedInput else Input, b);
    const values = try projection.schema([]const Value, b);
    const terms = try projection.schema([]const Term, b);
    const output = try projection.schema(compiler.RecordProposal, b);
    const value_parameters = [_]Id{ e.integer, ids, values, values, e.integer, values, ids };
    const term_parameters = [_]Id{ e.integer, ids, values, terms, e.integer, terms, ids };
    const d: Definition = .{
        .collect = if (indexed) try sites_data.define(b) else null,
        .entry = try b.declare(&.{input}, output, &.{}, &.{}),
        .reorder = try b.declare(&.{ ids, ids, e.integer, ids }, ids, &.{}, &.{}),
        .inverse = try b.declare(&.{ ids, e.integer, e.integer }, e.integer, &.{}, &.{}),
        .values = try b.declare(
            value_parameters[0..if (indexed) 7 else 6],
            values,
            &.{},
            &.{},
        ),
        .terms = try b.declare(
            term_parameters[0..if (indexed) 7 else 6],
            terms,
            &.{},
            &.{},
        ),
    };
    try defineReorder(e, d);
    try defineInverse(e, d);
    try defineMap(e, d, d.values, Value);
    try defineMap(e, d, d.terms, Term);
    try defineEntry(e, d);
    return d.entry;
}

fn shape(e: Author, comptime T: type) !Id {
    return projection.schema(T, e.b);
}

fn index(comptime T: type, comptime name: []const u8) usize {
    return std.meta.fieldIndex(T, name).?;
}

fn tagged(e: Author, value: Id, tag: usize) !Id {
    const found = try e.b.primitive(e.integer, .variant_tag, &.{value}, 0);
    return e.binary(.equal, found, try e.b.constant(u64, tag));
}

fn length(e: Author, sequence: Id) !Id {
    return e.b.primitive(e.integer, .sequence_length, &.{sequence}, 0);
}

fn append(e: Author, sequence: Id, value: Id) !Id {
    const schema = e.b.values.items[@intCast(sequence)].schema;
    return e.b.primitive(schema, .sequence_append, &.{ sequence, value }, 0);
}

fn coordinates(e: Author, input: Id) !Id {
    return e.field(input, 1);
}

fn reordered(e: Author, d: Definition, input: Id, sequence: Id) !Id {
    return e.call(d.reorder, &.{
        sequence, try coordinates(e, input), e.zero, try e.literal([]const Id, &.{}),
    });
}

fn defineReorder(e: Author, d: Definition) !void {
    const values = try e.param(d.reorder, 0);
    const order = try e.param(d.reorder, 1);
    const cursor = try e.param(d.reorder, 2);
    const result = try e.param(d.reorder, 3);
    const next = try append(e, result, try e.required(values, try e.required(order, cursor)));
    try e.b.define(d.reorder, try e.when(
        try e.binary(.less, cursor, try length(e, order)),
        try e.call(d.reorder, &.{ values, order, try e.binary(.integer_add, cursor, e.one), next }),
        try e.b.pure(result),
    ));
}

fn defineInverse(e: Author, d: Definition) !void {
    const order = try e.param(d.inverse, 0);
    const target = try e.param(d.inverse, 1);
    const cursor = try e.param(d.inverse, 2);
    try e.b.define(d.inverse, try e.when(
        try e.binary(.less, cursor, try length(e, order)),
        try e.when(
            try e.binary(.equal, try e.required(order, cursor), target),
            try e.b.pure(cursor),
            try e.call(d.inverse, &.{ order, target, try e.binary(.integer_add, cursor, e.one) }),
        ),
        try e.fail(),
    ));
}

fn match(e: Author, value: Id, tag: usize, variable: Id, yes: Id, no: Id) !Id {
    const schema = e.b.values.items[@intCast(value)].schema;
    const variants = e.b.schemas.items[@intCast(schema)].sum;
    const cases = try e.b.allocator().alloc(Case, variants.len);
    for (variants, cases, 0..) |payload, *case, i| case.* = .{
        .variable = if (i == tag) variable else try e.b.variable(payload),
        .body = if (i == tag) yes else no,
    };
    return e.b.term(.{ .match_sum = .{ .value = value, .cases = cases } });
}

fn continueMap(e: Author, m: Map, replacement: ?Id) !Id {
    const result = if (replacement) |value| try e.checked(
        e.b.values.items[@intCast(m.result)].schema,
        .sequence_set,
        &.{ m.result, m.row, value },
        &.{.invalid_index},
    ) else m.result;
    const args = [_]Id{
        m.selected,                                  m.order, m.source_values,       m.original,
        try e.binary(.integer_add, m.cursor, e.one), result,  m.sites orelse e.zero,
    };
    return e.call(m.function, args[0..if (m.sites != null) 7 else 6]);
}

fn rewritePrimitive(e: Author, m: Map, schema: Id, fields: []const Id) !Id {
    const primitive = try e.tuple(try shape(e, Primitive), fields);
    const expression = try e.variant(
        try shape(e, Expression),
        index(Expression, "primitive"),
        primitive,
    );
    return continueMap(e, m, try e.tuple(try shape(e, Value), &.{ schema, expression }));
}

fn primitiveProduct(e: Author, d: Definition, m: Map, schema: Id, fields: []const Id) !Id {
    const output = try e.b.variable(try shape(e, []const Id));
    const changed = try rewritePrimitive(e, m, schema, &.{
        fields[0], try e.b.reference(output), fields[2], fields[3],
    });
    const call = try e.call(d.reorder, &.{
        fields[1], m.order, e.zero, try e.literal([]const Id, &.{}),
    });
    return e.when(
        try e.binary(.equal, schema, m.selected),
        try e.b.bind(output, call, changed),
        try continueMap(e, m, null),
    );
}

fn primitiveField(e: Author, d: Definition, m: Map, schema: Id, fields: []const Id) !Id {
    const operand = try e.required(fields[1], e.zero);
    const operand_schema = try e.field(try e.required(m.source_values, operand), 0);
    const output = try e.b.variable(e.integer);
    const changed = try rewritePrimitive(e, m, schema, &.{
        fields[0], fields[1], try e.b.reference(output), fields[3],
    });
    const inverse = try e.call(d.inverse, &.{ m.order, fields[2], e.zero });
    return e.when(
        try e.binary(.equal, operand_schema, m.selected),
        try e.b.bind(output, inverse, changed),
        try continueMap(e, m, null),
    );
}

fn transformPrimitive(e: Author, d: Definition, m: Map, schema: Id, value: Id) !Id {
    var fields: [4]Id = undefined;
    for (&fields, 0..) |*field, i| field.* = try e.field(value, i);
    const bound_opcode = try e.b.variable(try e.b.scalar(u32));
    const opcode = try e.b.reference(bound_opcode);
    const product_case = try e.binary(
        .equal,
        opcode,
        try e.b.constant(u32, @backingInt(data.program.Opcode.product)),
    );
    const field_case = try e.binary(
        .equal,
        opcode,
        try e.b.constant(u32, @backingInt(data.program.Opcode.field)),
    );
    const body = try e.when(
        product_case,
        try primitiveProduct(e, d, m, schema, &fields),
        try e.when(
            field_case,
            try primitiveField(e, d, m, schema, &fields),
            try continueMap(e, m, null),
        ),
    );
    return e.b.bind(bound_opcode, try e.b.pure(try e.b.primitive(
        try e.b.scalar(u32),
        .enum_tag,
        &.{fields[0]},
        0,
    )), body);
}

fn transformValue(e: Author, d: Definition, m: Map, value: Id) !Id {
    const payload = try e.b.variable(try shape(e, Primitive));
    return match(
        e,
        try e.field(value, 1),
        index(Expression, "primitive"),
        payload,
        try transformPrimitive(e, d, m, try e.field(value, 0), try e.b.reference(payload)),
        try continueMap(e, m, null),
    );
}

fn transformTerm(e: Author, d: Definition, m: Map, term: Id) !Id {
    const T = @FieldType(Term, "unpack_product");
    const payload = try e.b.variable(try shape(e, T));
    const unpacking = try e.b.reference(payload);
    const operand = try e.field(unpacking, 0);
    const operand_schema = try e.field(try e.required(m.source_values, operand), 0);
    const output = try e.b.variable(try shape(e, []const Id));
    const updated = try e.tuple(try shape(e, T), &.{
        operand, try e.b.reference(output), try e.field(unpacking, 2),
    });
    const tag = index(Term, "unpack_product");
    const changed = try continueMap(e, m, try e.variant(try shape(e, Term), tag, updated));
    const call = try e.call(d.reorder, &.{
        try e.field(unpacking, 1), m.order, e.zero, try e.literal([]const Id, &.{}),
    });
    const unchanged = try continueMap(e, m, null);
    const selected_body = try e.when(
        try e.binary(.equal, operand_schema, m.selected),
        try e.b.bind(output, call, changed),
        unchanged,
    );
    return match(e, term, tag, payload, selected_body, unchanged);
}

fn defineMap(e: Author, d: Definition, function: Id, comptime T: type) !void {
    const sites = if (d.collect != null) try e.param(function, 6) else null;
    const cursor = try e.param(function, 4);
    const m: Map = .{
        .function = function,
        .selected = try e.param(function, 0),
        .order = try e.param(function, 1),
        .source_values = try e.param(function, 2),
        .original = try e.param(function, 3),
        .cursor = cursor,
        .result = try e.param(function, 5),
        .sites = sites,
        .row = if (sites) |ids| try e.required(ids, cursor) else cursor,
    };
    if (sites) |ids| {
        const current = try e.required(m.original, m.row);
        const changed = if (T == Value)
            try transformValue(e, d, m, current)
        else
            try transformTerm(e, d, m, current);
        return e.b.define(function, try e.when(
            try e.binary(.less, cursor, try length(e, ids)),
            changed,
            try e.b.pure(m.result),
        ));
    }
    const element = try shape(e, T);
    const optional = try e.b.schema(.{ .sum = &.{ e.unit, element } });
    const value = try e.b.variable(element);
    const current = try e.b.reference(value);
    const changed = if (T == Value)
        try transformValue(e, d, m, current)
    else
        try transformTerm(e, d, m, current);
    const read = try e.b.primitive(optional, .sequence_get, &.{ m.original, m.cursor }, 0);
    try e.b.define(function, try match(e, read, 1, value, changed, try e.b.pure(m.result)));
}

fn proposal(e: Author, selected_module: Id, requested_layout: Id) !Id {
    const layouts = try e.b.primitive(
        try shape(e, []const source.relation.Layout),
        .sequence,
        &.{requested_layout},
        0,
    );
    const rule = try e.variant(
        try shape(e, source.relation.RecordRule),
        index(source.relation.RecordRule, "product_layout"),
        layouts,
    );
    const step = try e.tuple(try shape(e, source.relation.RecordStep), &.{ selected_module, rule });
    const steps = try e.b.primitive(
        try shape(e, []const source.relation.RecordStep),
        .sequence,
        &.{step},
        0,
    );
    const interfaces = try e.literal(@FieldType(compiler.RecordProposal, "interfaces"), null);
    return e.tuple(try shape(e, compiler.RecordProposal), &.{ selected_module, steps, interfaces });
}

fn defineEntry(e: Author, d: Definition) !void {
    const input = try e.param(d.entry, 0);
    const sites = if (d.collect != null)
        try e.b.variable(try shape(e, sites_data.Sites))
    else
        null;
    const bound_module = try e.b.variable(try shape(e, source.ast.Module));
    const bound_layout = try e.b.variable(try shape(e, source.relation.Layout));
    const bound_values = try e.b.variable(try shape(e, []const Value));
    const bound_terms = try e.b.variable(try shape(e, []const Term));
    const bound_schemas = try e.b.variable(try shape(e, []const data.program.Schema));
    const module = try e.b.reference(bound_module);
    const requested_layout = try e.b.reference(bound_layout);
    const original_values = try e.b.reference(bound_values);
    const original_terms = try e.b.reference(bound_terms);
    const schemas = try e.b.reference(bound_schemas);
    const selected_id = try e.field(requested_layout, 0);
    const original = try e.required(schemas, selected_id);
    const reordered_fields = try e.b.variable(try shape(e, []const Id));
    const values = try e.b.variable(try shape(e, []const Value));
    const terms = try e.b.variable(try shape(e, []const Term));
    const product = index(data.program.Schema, "product");
    const replacement = try e.variant(
        try shape(e, data.program.Schema),
        product,
        try e.b.reference(reordered_fields),
    );
    const changed_schemas = try e.checked(
        try shape(e, []const data.program.Schema),
        .sequence_set,
        &.{ schemas, selected_id, replacement },
        &.{.invalid_index},
    );
    const selected_module = try updatedModule(e, module, changed_schemas, values, terms);
    var body = try e.b.pure(try proposal(e, selected_module, requested_layout));
    body = try e.b.bind(terms, try mapCall(
        e,
        d.terms,
        requested_layout,
        original_values,
        original_terms,
        sites,
        1,
    ), body);
    body = try e.b.bind(values, try mapCall(
        e,
        d.values,
        requested_layout,
        original_values,
        original_values,
        sites,
        0,
    ), body);
    const reorder = try reordered(e, d, requested_layout, try e.payload(original, product));
    body = try e.b.bind(reordered_fields, reorder, body);
    body = try e.when(try tagged(e, original, product), body, try e.fail());
    if (d.collect) |collect| body = try e.b.bind(sites.?, try e.call(collect, &.{
        try e.field(try e.field(input, 2), 1), selected_id,
    }), body);
    body = try e.b.bind(bound_schemas, try e.b.pure(try e.field(module, 2)), body);
    body = try e.b.bind(bound_terms, try e.b.pure(try e.field(module, 10)), body);
    body = try e.b.bind(bound_values, try e.b.pure(try e.field(module, 9)), body);
    body = try e.b.bind(bound_layout, try e.b.pure(try e.field(input, 1)), body);
    body = try e.b.bind(bound_module, try e.b.pure(try e.field(input, 0)), body);
    try e.b.define(d.entry, body);
}

fn updatedModule(e: Author, module: Id, schemas: Id, values: Id, terms: Id) !Id {
    const module_schema = e.b.values.items[@intCast(module)].schema;
    const fields = e.b.schemas.items[@intCast(module_schema)].product;
    const selected_fields = try e.b.allocator().alloc(Id, fields.len);
    for (selected_fields, 0..) |*selected_field, i| selected_field.* = switch (i) {
        2 => schemas,
        9 => try e.b.reference(values),
        10 => try e.b.reference(terms),
        else => try e.field(module, i),
    };
    return e.tuple(module_schema, selected_fields);
}

fn mapCall(
    e: Author,
    function: Id,
    layout: Id,
    source_values: Id,
    original: Id,
    sites: ?Id,
    position: usize,
) !Id {
    const args = [_]Id{
        try e.field(layout, 0),
        try coordinates(e, layout),
        source_values,
        original,
        e.zero,
        original,
        if (sites) |bound| try e.field(try e.b.reference(bound), position) else e.zero,
    };
    return e.call(function, args[0..if (sites != null) 7 else 6]);
}
