const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const Author = @import("author.zig").Author;
const compiler = @import("compiler.zig");
const Id = data.program.Id;
const ScalarRule = @FieldType(source.relation.Scalar, "rule");

pub const layout = @import("transformation_layout.zig").define;
pub const LayoutInput = @import("transformation_layout.zig").Input;

pub const Input = struct {
    module: source.ast.Module,
    first_value: u64 = 0,
    edits_max: u64 = 1,
};
const Rewrite = struct { value: source.ast.Value, rule: ScalarRule };
const Match = union(enum) { none, rewrite: Rewrite };
const Route = union(enum) { none, move, projection, inverse, repeated };
const Expression = @FieldType(source.ast.Value, "expression");
const Primitive = @FieldType(Expression, "primitive");
const Definition = struct {
    input: Id,
    module: Id,
    values: Id,
    schemas: Id,
    proposal: Id,
    match: Id,
    projection: Id,
    leaves: Id,
    total: Id,
    scan: Id,
};

pub fn scalar(b: *source.Builder) !source.ast.Module {
    const e = try Author.init(b);
    const d = try definitions(e);
    try defineLeaves(e, d);
    try defineTotal(e, d);
    try defineProjection(e, d);
    try defineScan(e, d);
    const entry = try b.declare(&.{d.input}, d.proposal, &.{}, &.{});
    const input = try e.param(entry, 0);
    const module = try b.variable(d.module);
    const values = try b.variable(d.values);
    const schemas = try b.variable(d.schemas);
    const table = routes();
    const scan = try e.call(d.scan, &.{
        try b.reference(module),
        try b.reference(values),
        try b.reference(schemas),
        try e.field(input, 1),
        try e.field(input, 2),
        try e.literal([]const source.relation.RecordStep, &.{}),
        try e.literal([]const Route, &table),
    });
    const begin = try e.when(
        try e.binary(.less, e.zero, try e.field(input, 2)),
        scan,
        try proposal(
            e,
            d,
            try b.reference(module),
            try e.literal([]const source.relation.RecordStep, &.{}),
        ),
    );
    const schema_values = try field(e, source.ast.Module, try b.reference(module), "schemas");
    const value_values = try field(e, source.ast.Module, try b.reference(module), "values");
    try b.define(entry, try b.bind(module, try b.pure(try e.field(input, 0)), try b.bind(
        values,
        try b.pure(value_values),
        try b.bind(schemas, try b.pure(schema_values), begin),
    )));
    return b.module(entry, e.unit);
}

fn definitions(e: Author) !Definition {
    const b = e.b;
    const module = try projection.schema(source.ast.Module, b);
    const match = try projection.schema(Match, b);
    const primitive = try projection.schema(Primitive, b);
    const output_schema = try projection.schema(compiler.RecordProposal, b);
    const steps_schema = try projection.schema([]const source.relation.RecordStep, b);
    const ids = try projection.schema([]const Id, b);
    const values = try projection.schema([]const source.ast.Value, b);
    const schemas = try projection.schema([]const data.program.Schema, b);
    const route_schema = try projection.schema([]const Route, b);
    return .{
        .input = try projection.schema(Input, b),
        .module = module,
        .values = values,
        .schemas = schemas,
        .proposal = output_schema,
        .match = match,
        .projection = try b.declare(&.{ values, schemas, primitive }, match, &.{}, &.{}),
        .leaves = try b.declare(&.{ values, schemas, ids, e.integer }, e.boolean, &.{}, &.{}),
        .total = try b.declare(&.{ values, schemas, e.integer }, e.boolean, &.{}, &.{}),
        .scan = try b.declare(
            &.{ module, values, schemas, e.integer, e.integer, steps_schema, route_schema },
            output_schema,
            &.{},
            &.{},
        ),
    };
}

fn tag(e: Author, value: Id, expected: u64) !Id {
    const actual = try e.b.primitive(e.integer, .variant_tag, &.{value}, 0);
    return e.binary(.equal, actual, try e.b.constant(u64, expected));
}

fn opcode(e: Author, primitive: Id, expected: data.program.Opcode) !Id {
    const actual = try enumTag(e, try e.field(primitive, 0));
    return e.binary(.equal, actual, try e.b.constant(u32, @backingInt(expected)));
}

fn field(e: Author, comptime T: type, value: Id, comptime name: []const u8) !Id {
    return e.field(value, machines.index(T, name));
}

fn noMatch(e: Author, d: Definition) !Id {
    return e.b.pure(try e.variant(d.match, 0, e.unit_value));
}

fn replacement(e: Author, d: Definition, value: Id, rule: ScalarRule) !Id {
    const rewritten = try e.tuple(try projection.schema(Rewrite, e.b), &.{
        value, try e.literal(ScalarRule, rule),
    });
    return e.b.pure(try e.variant(d.match, 1, rewritten));
}

fn routes() [256]Route {
    var result: [256]Route = @splat(.none);
    result[@backingInt(data.program.Opcode.move)] = .move;
    result[@backingInt(data.program.Opcode.field)] = .projection;
    inline for (.{ .boolean_not, .integer_bit_not }) |op|
        result[@backingInt(@as(data.program.Opcode, op))] = .inverse;
    inline for (.{ .integer_bit_and, .integer_bit_or }) |op|
        result[@backingInt(@as(data.program.Opcode, op))] = .repeated;
    return result;
}

fn primitiveScan(e: Author, d: Definition, op: Id, next: Id) !Id {
    const values = try e.param(d.scan, 1);
    const schemas = try e.param(d.scan, 2);
    const code = try enumTag(e, try e.field(op, 0));
    const route = try e.required(
        try e.param(d.scan, 6),
        try e.convert(code, e.integer, false),
    );
    const operand = try e.required(values, try e.required(try e.field(op, 1), e.zero));
    const moved = try e.tuple(try projection.schema(Rewrite, e.b), &.{
        operand, try e.literal(ScalarRule, .identity),
    });
    const cases = [_]@import("std").meta.Elem(
        @FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"),
    ){
        .{ .variable = try e.b.variable(e.unit), .body = next },
        .{ .variable = try e.b.variable(e.unit), .body = try rewriteAndContinue(e, d, moved) },
        .{ .variable = try e.b.variable(e.unit), .body = try matchedScan(
            e,
            d,
            try e.call(d.projection, &.{ values, schemas, op }),
            next,
        ) },
        .{ .variable = try e.b.variable(e.unit), .body = try matchedScan(
            e,
            d,
            try inversePair(e, d, values, code, operand),
            next,
        ) },
        .{ .variable = try e.b.variable(e.unit), .body = try matchedScan(
            e,
            d,
            try repeated(e, d, values, op),
            next,
        ) },
    };
    return e.b.term(.{ .match_sum = .{ .value = route, .cases = &cases } });
}

fn matchedScan(e: Author, d: Definition, body: Id, next: Id) !Id {
    const matched = try e.b.variable(d.match);
    const rewritten = try e.b.variable(try projection.schema(Rewrite, e.b));
    const rewrite = try rewriteAndContinue(e, d, try e.b.reference(rewritten));
    const choose = try matchSum(e, try e.b.reference(matched), 1, rewritten, rewrite, next);
    return e.b.bind(matched, body, choose);
}

fn leaf(e: Author, value: Id) !Id {
    const expression = try e.field(value, 1);
    const variable = try tag(e, expression, machines.index(Expression, "variable"));
    const literal = try tag(e, expression, machines.index(Expression, "literal"));
    return e.b.primitive(
        e.boolean,
        .select,
        &.{ variable, try e.b.constant(bool, true), literal },
        0,
    );
}

fn defineLeaves(e: Author, d: Definition) !void {
    const values = try e.param(d.leaves, 0);
    const schemas = try e.param(d.leaves, 1);
    const operands = try e.param(d.leaves, 2);
    const index = try e.param(d.leaves, 3);
    const count = try e.b.primitive(e.integer, .sequence_length, &.{operands}, 0);
    const total = try e.b.variable(e.boolean);
    const next = try e.call(d.leaves, &.{
        values, schemas, operands, try e.binary(.integer_add, index, e.one),
    });
    const false_result = try e.b.pure(try e.b.constant(bool, false));
    const true_result = try e.b.pure(try e.b.constant(bool, true));
    const continue_total = try e.when(try e.b.reference(total), next, false_result);
    const advance = try e.b.bind(total, try e.call(d.total, &.{
        values, schemas, try e.required(operands, index),
    }), continue_total);
    try e.b.define(d.leaves, try e.when(try e.binary(.less, index, count), advance, true_result));
}

fn defineTotal(e: Author, d: Definition) !void {
    const values = try e.param(d.total, 0);
    const schemas = try e.param(d.total, 1);
    const row = try e.b.variable(try projection.schema(source.ast.Value, e.b));
    const value = try e.b.reference(row);
    const expression = try e.field(value, 1);
    const primitive_variable = try e.b.variable(try projection.schema(Primitive, e.b));
    const primitive = try e.b.reference(primitive_variable);
    const code_variable = try e.b.variable(try e.b.scalar(u32));
    const code = try e.b.reference(code_variable);
    const no = try e.b.pure(try e.b.constant(bool, false));
    const yes = try e.b.pure(try e.b.constant(bool, true));
    const all_total = try e.call(d.leaves, &.{
        values, schemas, try e.field(primitive, 1), e.zero,
    });
    var accepted = no;
    inline for ([_]data.program.Opcode{
        .constant,
        .move,
        .field,
        .equal,
        .less,
        .boolean_not,
        .variant_tag,
        .sequence_length,
        .integer_bit_not,
        .integer_bit_and,
        .integer_bit_or,
        .integer_bit_xor,
        .product,
    }) |op| accepted = try e.when(try e.binary(
        .equal,
        code,
        try e.b.constant(u32, @backingInt(op)),
    ), all_total, accepted);
    const failure_values = try e.field(primitive, 3);
    const failures = try e.b.primitive(e.integer, .sequence_length, &.{failure_values}, 0);
    const checked = try e.when(try e.binary(.equal, failures, e.zero), accepted, no);
    const decoded = try bind(e, code_variable, try enumTag(e, try e.field(primitive, 0)), checked);
    var body = try matchSum(
        e,
        expression,
        machines.index(Expression, "primitive"),
        primitive_variable,
        decoded,
        no,
    );
    inline for (.{ "literal", "variable" }) |name|
        body = try e.when(try tag(e, expression, machines.index(Expression, name)), yes, body);
    const schema = try e.required(schemas, try e.field(value, 0));
    const checked_schema = try e.when(
        try tag(e, schema, machines.index(data.program.Schema, "internal")),
        no,
        body,
    );
    try e.b.define(d.total, try bind(
        e,
        row,
        try e.required(values, try e.param(d.total, 2)),
        checked_schema,
    ));
}

fn defineProjection(e: Author, d: Definition) !void {
    const values = try e.param(d.projection, 0);
    const schemas = try e.param(d.projection, 1);
    const op = try e.param(d.projection, 2);
    const product = try e.required(values, try e.required(try e.field(op, 1), e.zero));
    const expression = try e.field(product, 1);
    const constructor_variable = try e.b.variable(try projection.schema(Primitive, e.b));
    const constructor = try e.b.reference(constructor_variable);
    const operands = try e.field(constructor, 1);
    const leaves = try e.b.variable(e.boolean);
    const selected = try e.required(values, try e.required(operands, try e.field(op, 2)));
    const result = try replacement(e, d, selected, .projection);
    const leaf_result = try e.when(try e.b.reference(leaves), result, try noMatch(e, d));
    const check_leaves = try e.call(d.leaves, &.{ values, schemas, operands, e.zero });
    const yes = try e.b.bind(leaves, check_leaves, leaf_result);
    const constructed = try e.when(try opcode(e, constructor, .product), yes, try noMatch(e, d));
    try e.b.define(d.projection, try matchSum(
        e,
        expression,
        machines.index(Expression, "primitive"),
        constructor_variable,
        constructed,
        try noMatch(e, d),
    ));
}

fn repeated(e: Author, d: Definition, values: Id, op: Id) !Id {
    const operands = try e.field(op, 1);
    const first_id = try e.required(operands, e.zero);
    const first_variable = try e.b.variable(try projection.schema(source.ast.Value, e.b));
    const first = try e.b.reference(first_variable);
    const repeated_leaf = try e.when(
        try leaf(e, first),
        try replacement(e, d, first, .identity),
        try noMatch(e, d),
    );
    return e.when(
        try e.binary(.equal, first_id, try e.required(operands, e.one)),
        try bind(e, first_variable, try e.required(values, first_id), repeated_leaf),
        try noMatch(e, d),
    );
}

fn inversePair(e: Author, d: Definition, values: Id, code: Id, first: Id) !Id {
    const expression = try e.field(first, 1);
    const primitive_variable = try e.b.variable(try projection.schema(Primitive, e.b));
    const primitive = try e.b.reference(primitive_variable);
    const child = try e.required(values, try e.required(try e.field(primitive, 1), e.zero));
    const same = try e.binary(
        .equal,
        code,
        try enumTag(e, try e.field(primitive, 0)),
    );
    return matchSum(
        e,
        expression,
        machines.index(Expression, "primitive"),
        primitive_variable,
        try e.when(same, try replacement(e, d, child, .identity), try noMatch(e, d)),
        try noMatch(e, d),
    );
}

fn proposal(e: Author, d: Definition, module: Id, steps: Id) !Id {
    return e.b.pure(try e.tuple(d.proposal, &.{
        module, steps, try e.literal(@FieldType(compiler.RecordProposal, "interfaces"), null),
    }));
}

fn matchSum(e: Author, value: Id, selected: usize, variable: Id, yes: Id, no: Id) !Id {
    const schema = e.b.values.items[@intCast(value)].schema;
    const variants = e.b.schemas.items[@intCast(schema)].sum;
    const Case = @import("std").meta.Elem(
        @FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"),
    );
    const cases = try e.b.allocator().alloc(Case, variants.len);
    for (variants, cases, 0..) |payload, *case, i| case.* = .{
        .variable = if (i == selected) variable else try e.b.variable(payload),
        .body = if (i == selected) yes else no,
    };
    return e.b.term(.{ .match_sum = .{ .value = value, .cases = cases } });
}

fn bind(e: Author, variable: Id, value: Id, body: Id) !Id {
    return e.b.bind(variable, try e.b.pure(value), body);
}

fn defineScan(e: Author, d: Definition) !void {
    const module = try e.param(d.scan, 0);
    const values = try e.param(d.scan, 1);
    const schemas = try e.param(d.scan, 2);
    const index = try e.param(d.scan, 3);
    const remaining = try e.param(d.scan, 4);
    const steps = try e.param(d.scan, 5);
    const row_schema = try projection.schema(source.ast.Value, e.b);
    const row = try e.b.variable(row_schema);
    const optional = try e.b.schema(.{ .sum = &.{ e.unit, row_schema } });
    const found = try e.b.primitive(optional, .sequence_get, &.{ values, index }, 0);
    const primitive = try e.b.variable(try projection.schema(Primitive, e.b));
    const next = try e.call(d.scan, &.{
        module,    values, schemas,                try e.binary(.integer_add, index, e.one),
        remaining, steps,  try e.param(d.scan, 6),
    });
    const apply = try primitiveScan(e, d, try e.b.reference(primitive), next);
    const expression = try e.field(try e.b.reference(row), 1);
    const scan = try matchSum(
        e,
        expression,
        machines.index(Expression, "primitive"),
        primitive,
        apply,
        next,
    );
    const finish = try proposal(e, d, module, steps);
    try e.b.define(d.scan, try matchSum(e, found, 1, row, scan, finish));
}

fn rewriteAndContinue(e: Author, d: Definition, rewrite: Id) !Id {
    const module = try e.param(d.scan, 0);
    const values = try e.param(d.scan, 1);
    const schemas = try e.param(d.scan, 2);
    const index = try e.param(d.scan, 3);
    const changed = try e.b.variable(d.values);
    const selected = try e.b.variable(d.module);
    const updated = try e.checked(
        d.values,
        .sequence_set,
        &.{ values, index, try e.field(rewrite, 0) },
        &.{.invalid_index},
    );
    const replacement_module = try e.replace(
        module,
        machines.index(source.ast.Module, "values"),
        try e.b.reference(changed),
    );
    const scalar_rule = try e.tuple(try projection.schema(source.relation.Scalar, e.b), &.{
        index, try e.field(rewrite, 1),
    });
    const rule = try e.variant(
        try projection.schema(source.relation.RecordRule, e.b),
        machines.index(source.relation.RecordRule, "scalar"),
        scalar_rule,
    );
    const step = try e.tuple(
        try projection.schema(source.relation.RecordStep, e.b),
        &.{ try e.b.reference(selected), rule },
    );
    const steps = try e.b.primitive(
        try projection.schema([]const source.relation.RecordStep, e.b),
        .sequence_append,
        &.{ try e.param(d.scan, 5), step },
        0,
    );
    const next = try e.call(d.scan, &.{
        try e.b.reference(selected),
        try e.b.reference(changed),
        schemas,
        try e.binary(.integer_add, index, e.one),
        try e.binary(.integer_sub, try e.param(d.scan, 4), e.one),
        steps,
        try e.param(d.scan, 6),
    });
    const continue_scan = try e.when(
        try e.binary(.less, e.one, try e.param(d.scan, 4)),
        next,
        try proposal(e, d, try e.b.reference(selected), steps),
    );
    return e.b.bind(changed, try e.b.pure(updated), try e.b.bind(
        selected,
        try e.b.pure(replacement_module),
        continue_scan,
    ));
}

fn enumTag(e: Author, value: Id) !Id {
    return e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{value}, 0);
}
