const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const compiler = @import("compiler.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Value = source.ast.Value;
const Term = source.ast.Term;
const Expression = @FieldType(Value, "expression");
const Primitive = @FieldType(Expression, "primitive");
const Case = std.meta.Elem(@FieldType(@FieldType(Term, "match_sum"), "cases"));
const Product = struct { variables: []const Id, values: []const Id };
const Map = struct {
    function: Id,
    selected: Id,
    order: Id,
    source_values: Id,
    original: Id,
    cursor: Id,
    result: Id,
};

pub const Input = struct { module: source.ast.Module, layout: source.relation.Layout };
const Definition = struct {
    entry: Id,
    reorder: Id,
    inverse: Id,
    values: Id,
    terms: Id,
};

pub fn define(b: *source.Builder) !Id {
    const e = try Author.init(b);
    const ids = try projection.schema([]const Id, b);
    const input = try projection.schema(Input, b);
    const values = try projection.schema([]const Value, b);
    const terms = try projection.schema([]const Term, b);
    const output = try projection.schema(compiler.RecordProposal, b);
    const d: Definition = .{
        .entry = try b.declare(&.{input}, output, &.{}, &.{}),
        .reorder = try b.declare(&.{ ids, ids, e.integer, ids }, ids, &.{}, &.{}),
        .inverse = try b.declare(&.{ ids, e.integer, e.integer }, e.integer, &.{}, &.{}),
        .values = try b.declare(
            &.{ e.integer, ids, values, values, e.integer, values },
            values,
            &.{},
            &.{},
        ),
        .terms = try b.declare(
            &.{ e.integer, ids, values, terms, e.integer, terms },
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

fn productBindings(e: Author, comptime T: type) !Product {
    const schema = try shape(e, T);
    const fields = e.b.schemas.items[@intCast(schema)].product;
    const variables = try e.b.allocator().alloc(Id, fields.len);
    const values = try e.b.allocator().alloc(Id, fields.len);
    for (fields, variables, values) |field_schema, *variable, *value| {
        variable.* = try e.b.variable(field_schema);
        value.* = try e.b.reference(variable.*);
    }
    return .{ .variables = variables, .values = values };
}

fn unpack(e: Author, value: Id, fields: Product, body: Id) !Id {
    return e.b.term(.{ .unpack_product = .{
        .value = value,
        .variables = fields.variables,
        .body = body,
    } });
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
        &.{ m.result, m.cursor, value },
        &.{.invalid_index},
    ) else m.result;
    return e.call(m.function, &.{
        m.selected,                                  m.order, m.source_values, m.original,
        try e.binary(.integer_add, m.cursor, e.one), result,
    });
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
    const fields = try productBindings(e, Primitive);
    const opcode = try e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{fields.values[0]}, 0);
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
    return unpack(e, value, fields, try e.when(
        product_case,
        try primitiveProduct(e, d, m, schema, fields.values),
        try e.when(
            field_case,
            try primitiveField(e, d, m, schema, fields.values),
            try continueMap(e, m, null),
        ),
    ));
}

fn transformValue(e: Author, d: Definition, m: Map, value: Id) !Id {
    const fields = try productBindings(e, Value);
    const payload = try e.b.variable(try shape(e, Primitive));
    const body = try match(
        e,
        fields.values[1],
        index(Expression, "primitive"),
        payload,
        try transformPrimitive(e, d, m, fields.values[0], try e.b.reference(payload)),
        try continueMap(e, m, null),
    );
    return unpack(e, value, fields, body);
}

fn transformTerm(e: Author, d: Definition, m: Map, term: Id) !Id {
    const T = @FieldType(Term, "unpack_product");
    const fields = try productBindings(e, T);
    const payload = try e.b.variable(try shape(e, T));
    const operand_schema = try e.field(try e.required(m.source_values, fields.values[0]), 0);
    const output = try e.b.variable(try shape(e, []const Id));
    const updated = try e.tuple(try shape(e, T), &.{
        fields.values[0], try e.b.reference(output), fields.values[2],
    });
    const tag = index(Term, "unpack_product");
    const changed = try continueMap(e, m, try e.variant(try shape(e, Term), tag, updated));
    const call = try e.call(d.reorder, &.{
        fields.values[1], m.order, e.zero, try e.literal([]const Id, &.{}),
    });
    const unchanged = try continueMap(e, m, null);
    const selected_body = try e.when(
        try e.binary(.equal, operand_schema, m.selected),
        try e.b.bind(output, call, changed),
        unchanged,
    );
    const body = try unpack(e, try e.b.reference(payload), fields, selected_body);
    return match(e, term, tag, payload, body, unchanged);
}

fn defineMap(e: Author, d: Definition, function: Id, comptime T: type) !void {
    const m: Map = .{
        .function = function,
        .selected = try e.param(function, 0),
        .order = try e.param(function, 1),
        .source_values = try e.param(function, 2),
        .original = try e.param(function, 3),
        .cursor = try e.param(function, 4),
        .result = try e.param(function, 5),
    };
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
    const module_schema = e.b.values.items[@intCast(module)].schema;
    const fields = e.b.schemas.items[@intCast(module_schema)].product;
    const selected_fields = try e.b.allocator().alloc(Id, fields.len);
    for (selected_fields, 0..) |*selected_field, i| selected_field.* = switch (i) {
        2 => changed_schemas,
        9 => try e.b.reference(values),
        10 => try e.b.reference(terms),
        else => try e.field(module, i),
    };
    const selected_module = try e.tuple(module_schema, selected_fields);
    var body = try e.b.pure(try proposal(e, selected_module, requested_layout));
    body = try e.b.bind(terms, try e.call(d.terms, &.{
        selected_id,    try coordinates(e, requested_layout), original_values,
        original_terms, e.zero,                               original_terms,
    }), body);
    body = try e.b.bind(values, try e.call(d.values, &.{
        selected_id,     try coordinates(e, requested_layout), original_values,
        original_values, e.zero,                               original_values,
    }), body);
    const reorder = try reordered(e, d, requested_layout, try e.payload(original, product));
    body = try e.b.bind(reordered_fields, reorder, body);
    body = try e.when(try tagged(e, original, product), body, try e.fail());
    body = try e.b.bind(bound_schemas, try e.b.pure(try e.field(module, 2)), body);
    body = try e.b.bind(bound_terms, try e.b.pure(try e.field(module, 10)), body);
    body = try e.b.bind(bound_values, try e.b.pure(try e.field(module, 9)), body);
    body = try e.b.bind(bound_layout, try e.b.pure(try e.field(input, 1)), body);
    body = try e.b.bind(bound_module, try e.b.pure(try e.field(input, 0)), body);
    try e.b.define(d.entry, body);
}
