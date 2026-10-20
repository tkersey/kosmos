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

pub const Input = struct { module: source.ast.Module, layout: source.relation.Layout };
const Definition = struct {
    entry: Id,
    reorder: Id,
    inverse: Id,
    values: Id,
    value: Id,
    primitive: Id,
    terms: Id,
    term: Id,
};

pub fn define(b: *source.Builder) !Id {
    const e = try Author.init(b);
    const ids = try projection.schema([]const Id, b);
    const input = try projection.schema(Input, b);
    const value = try projection.schema(Value, b);
    const term = try projection.schema(Term, b);
    const values = try projection.schema([]const Value, b);
    const terms = try projection.schema([]const Term, b);
    const output = try projection.schema(compiler.RecordProposal, b);
    const d: Definition = .{
        .entry = try b.declare(&.{input}, output, &.{}, &.{}),
        .reorder = try b.declare(&.{ ids, ids, e.integer, ids }, ids, &.{}, &.{}),
        .inverse = try b.declare(&.{ ids, e.integer, e.integer }, e.integer, &.{}, &.{}),
        .values = try b.declare(&.{ input, e.integer, values }, values, &.{}, &.{}),
        .value = try b.declare(&.{ input, value }, value, &.{}, &.{}),
        .primitive = try b.declare(&.{ input, value }, value, &.{}, &.{}),
        .terms = try b.declare(&.{ input, e.integer, terms }, terms, &.{}, &.{}),
        .term = try b.declare(&.{ input, term }, term, &.{}, &.{}),
    };
    try defineReorder(e, d);
    try defineInverse(e, d);
    try defineValue(e, d);
    try definePrimitive(e, d);
    try defineTerm(e, d);
    try defineMap(e, d.values, d.value, 9, Value);
    try defineMap(e, d.terms, d.term, 10, Term);
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

fn layout(e: Author, input: Id) !Id {
    return e.field(input, 1);
}

fn coordinates(e: Author, input: Id) !Id {
    return e.field(try layout(e, input), 1);
}

fn selected(e: Author, input: Id, schema: Id) !Id {
    return e.binary(.equal, schema, try e.field(try layout(e, input), 0));
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

fn defineValue(e: Author, d: Definition) !void {
    const input = try e.param(d.value, 0);
    const value = try e.param(d.value, 1);
    try e.b.define(d.value, try e.when(
        try tagged(e, try e.field(value, 1), index(Expression, "primitive")),
        try e.call(d.primitive, &.{ input, value }),
        try e.b.pure(value),
    ));
}

fn primitiveValue(e: Author, value: Id, primitive: Id) !Id {
    return e.replace(value, 1, try e.variant(
        try shape(e, Expression),
        index(Expression, "primitive"),
        primitive,
    ));
}

fn primitiveProduct(e: Author, d: Definition, input: Id, value: Id, primitive: Id) !Id {
    const output = try e.b.variable(try shape(e, []const Id));
    const changed = try e.b.pure(try primitiveValue(e, value, try e.replace(
        primitive,
        1,
        try e.b.reference(output),
    )));
    const call = try reordered(e, d, input, try e.field(primitive, 1));
    return e.when(
        try selected(e, input, try e.field(value, 0)),
        try e.b.bind(output, call, changed),
        try e.b.pure(value),
    );
}

fn primitiveField(e: Author, d: Definition, input: Id, value: Id, primitive: Id) !Id {
    const source_values = try e.field(try e.field(input, 0), 9);
    const operand = try e.required(try e.field(primitive, 1), e.zero);
    const operand_schema = try e.field(try e.required(source_values, operand), 0);
    const output = try e.b.variable(e.integer);
    const changed = try e.b.pure(try primitiveValue(e, value, try e.replace(
        primitive,
        2,
        try e.b.reference(output),
    )));
    const inverse = try e.call(d.inverse, &.{
        try coordinates(e, input), try e.field(primitive, 2), e.zero,
    });
    return e.when(
        try selected(e, input, operand_schema),
        try e.b.bind(output, inverse, changed),
        try e.b.pure(value),
    );
}

fn definePrimitive(e: Author, d: Definition) !void {
    const input = try e.param(d.primitive, 0);
    const value = try e.param(d.primitive, 1);
    const primitive = try e.payload(try e.field(value, 1), index(Expression, "primitive"));
    const opcode = try e.b.primitive(
        try e.b.scalar(u32),
        .enum_tag,
        &.{try e.field(primitive, 0)},
        0,
    );
    const product = try e.binary(
        .equal,
        opcode,
        try e.b.constant(u32, @backingInt(data.program.Opcode.product)),
    );
    const field = try e.binary(
        .equal,
        opcode,
        try e.b.constant(u32, @backingInt(data.program.Opcode.field)),
    );
    const product_body = try primitiveProduct(e, d, input, value, primitive);
    const field_body = try primitiveField(e, d, input, value, primitive);
    const otherwise = try e.when(field, field_body, try e.b.pure(value));
    const body = try e.when(product, product_body, otherwise);
    try e.b.define(d.primitive, body);
}

fn defineTerm(e: Author, d: Definition) !void {
    const input = try e.param(d.term, 0);
    const term = try e.param(d.term, 1);
    const tag = index(Term, "unpack_product");
    const unpack = try e.payload(term, tag);
    const source_values = try e.field(try e.field(input, 0), 9);
    const operand_schema = try e.field(try e.required(source_values, try e.field(unpack, 0)), 0);
    const output = try e.b.variable(try shape(e, []const Id));
    const updated = try e.replace(unpack, 1, try e.b.reference(output));
    const changed = try e.b.pure(try e.variant(try shape(e, Term), tag, updated));
    const call = try reordered(e, d, input, try e.field(unpack, 1));
    const rewrite = try e.b.bind(output, call, changed);
    const unchanged = try e.b.pure(term);
    try e.b.define(d.term, try e.when(
        try tagged(e, term, tag),
        try e.when(try selected(e, input, operand_schema), rewrite, unchanged),
        unchanged,
    ));
}

fn defineMap(e: Author, function: Id, transform: Id, field: usize, comptime T: type) !void {
    const input = try e.param(function, 0);
    const cursor = try e.param(function, 1);
    const result = try e.param(function, 2);
    const original = try e.field(try e.field(input, 0), field);
    const output = try e.b.variable(try shape(e, T));
    const next = try e.call(function, &.{
        input,
        try e.binary(.integer_add, cursor, e.one),
        try append(e, result, try e.b.reference(output)),
    });
    const call = try e.call(transform, &.{ input, try e.required(original, cursor) });
    try e.b.define(function, try e.when(
        try e.binary(.less, cursor, try length(e, original)),
        try e.b.bind(output, call, next),
        try e.b.pure(result),
    ));
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
    const module = try e.field(input, 0);
    const schemas = try e.field(module, 2);
    const selected_id = try e.field(try layout(e, input), 0);
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
    var selected_module = try e.replace(module, 2, changed_schemas);
    selected_module = try e.replace(selected_module, 9, try e.b.reference(values));
    selected_module = try e.replace(selected_module, 10, try e.b.reference(terms));
    var body = try e.b.pure(try proposal(e, selected_module, try layout(e, input)));
    body = try e.b.bind(terms, try e.call(d.terms, &.{
        input,                             e.zero,
        try e.literal([]const Term, &.{}),
    }), body);
    body = try e.b.bind(values, try e.call(d.values, &.{
        input,                              e.zero,
        try e.literal([]const Value, &.{}),
    }), body);
    const reorder = try reordered(e, d, input, try e.payload(original, product));
    body = try e.b.bind(reordered_fields, reorder, body);
    try e.b.define(d.entry, try e.when(try tagged(e, original, product), body, try e.fail()));
}
