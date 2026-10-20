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
const Expression = @FieldType(source.ast.Value, "expression");
const Primitive = @FieldType(Expression, "primitive");
const Definition = struct {
    input: Id,
    module: Id,
    proposal: Id,
    match: Id,
    matcher: Id,
    primitive: Id,
    projection: Id,
    leaves: Id,
    total: Id,
    identity: Id,
    scan: Id,
};

pub fn scalar(b: *source.Builder) !source.ast.Module {
    const e = try Author.init(b);
    const d = try definitions(e);
    try defineLeaves(e, d);
    try defineTotal(e, d);
    try defineProjection(e, d);
    try defineIdentity(e, d);
    try definePrimitive(e, d);
    try defineMatcher(e, d);
    try defineScan(e, d);
    const entry = try b.declare(&.{d.input}, d.proposal, &.{}, &.{});
    const input = try e.param(entry, 0);
    try b.define(entry, try e.call(d.scan, &.{
        try e.field(input, 0),
        try e.field(input, 1),
        try e.field(input, 2),
        try e.literal([]const source.relation.RecordStep, &.{}),
    }));
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
    return .{
        .input = try projection.schema(Input, b),
        .module = module,
        .proposal = output_schema,
        .match = match,
        .matcher = try b.declare(&.{ module, e.integer }, match, &.{}, &.{}),
        .primitive = try b.declare(&.{ module, primitive }, match, &.{}, &.{}),
        .projection = try b.declare(&.{ module, primitive }, match, &.{}, &.{}),
        .leaves = try b.declare(&.{ module, ids, e.integer }, e.boolean, &.{}, &.{}),
        .total = try b.declare(&.{ module, e.integer }, e.boolean, &.{}, &.{}),
        .identity = try b.declare(&.{ module, primitive }, match, &.{}, &.{}),
        .scan = try b.declare(
            &.{ module, e.integer, e.integer, steps_schema },
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

fn defineMatcher(e: Author, d: Definition) !void {
    const module = try e.param(d.matcher, 0);
    const values = try field(e, source.ast.Module, module, "values");
    const value = try e.required(values, try e.param(d.matcher, 1));
    const expression = try e.field(value, 1);
    const primitive = try e.payload(expression, machines.index(Expression, "primitive"));
    try e.b.define(d.matcher, try e.when(
        try tag(e, expression, machines.index(Expression, "primitive")),
        try e.call(d.primitive, &.{ module, primitive }),
        try noMatch(e, d),
    ));
}

fn definePrimitive(e: Author, d: Definition) !void {
    const module = try e.param(d.primitive, 0);
    const op = try e.param(d.primitive, 1);
    const values = try field(e, source.ast.Module, module, "values");
    const operands = try e.field(op, 1);
    const operand = try e.required(values, try e.required(operands, e.zero));
    const moved = try replacement(e, d, operand, .identity);
    var body = try e.when(
        try opcode(e, op, .field),
        try e.call(d.projection, &.{ module, op }),
        try e.call(d.identity, &.{ module, op }),
    );
    body = try e.when(try opcode(e, op, .move), moved, body);
    try e.b.define(d.primitive, body);
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
    const module = try e.param(d.leaves, 0);
    const operands = try e.param(d.leaves, 1);
    const index = try e.param(d.leaves, 2);
    const count = try e.b.primitive(e.integer, .sequence_length, &.{operands}, 0);
    const total = try e.b.variable(e.boolean);
    const next = try e.call(d.leaves, &.{
        module, operands, try e.binary(.integer_add, index, e.one),
    });
    const false_result = try e.b.pure(try e.b.constant(bool, false));
    const true_result = try e.b.pure(try e.b.constant(bool, true));
    const continue_total = try e.when(try e.b.reference(total), next, false_result);
    const advance = try e.b.bind(total, try e.call(d.total, &.{
        module, try e.required(operands, index),
    }), continue_total);
    try e.b.define(d.leaves, try e.when(try e.binary(.less, index, count), advance, true_result));
}

fn defineTotal(e: Author, d: Definition) !void {
    const module = try e.param(d.total, 0);
    const values = try field(e, source.ast.Module, module, "values");
    const value = try e.required(values, try e.param(d.total, 1));
    const expression = try e.field(value, 1);
    const primitive = try e.payload(expression, machines.index(Expression, "primitive"));
    const no = try e.b.pure(try e.b.constant(bool, false));
    const yes = try e.b.pure(try e.b.constant(bool, true));
    const all_total = try e.call(d.leaves, &.{ module, try e.field(primitive, 1), e.zero });
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
    }) |op| accepted = try e.when(try opcode(e, primitive, op), all_total, accepted);
    const failure_values = try e.field(primitive, 3);
    const failures = try e.b.primitive(e.integer, .sequence_length, &.{failure_values}, 0);
    const checked = try e.when(try e.binary(.equal, failures, e.zero), accepted, no);
    const is_primitive = try tag(e, expression, machines.index(Expression, "primitive"));
    var body = try e.when(is_primitive, checked, no);
    inline for (.{ "literal", "variable" }) |name|
        body = try e.when(try tag(e, expression, machines.index(Expression, name)), yes, body);
    const schemas = try field(e, source.ast.Module, module, "schemas");
    const schema = try e.required(schemas, try e.field(value, 0));
    try e.b.define(d.total, try e.when(
        try tag(e, schema, machines.index(data.program.Schema, "internal")),
        no,
        body,
    ));
}

fn defineProjection(e: Author, d: Definition) !void {
    const module = try e.param(d.projection, 0);
    const op = try e.param(d.projection, 1);
    const values = try field(e, source.ast.Module, module, "values");
    const product = try e.required(values, try e.required(try e.field(op, 1), e.zero));
    const expression = try e.field(product, 1);
    const constructor = try e.payload(expression, machines.index(Expression, "primitive"));
    const operands = try e.field(constructor, 1);
    const leaves = try e.b.variable(e.boolean);
    const selected = try e.required(values, try e.required(operands, try e.field(op, 2)));
    const result = try replacement(e, d, selected, .projection);
    const leaf_result = try e.when(try e.b.reference(leaves), result, try noMatch(e, d));
    const check_leaves = try e.call(d.leaves, &.{ module, operands, e.zero });
    const yes = try e.b.bind(leaves, check_leaves, leaf_result);
    const constructed = try e.when(try opcode(e, constructor, .product), yes, try noMatch(e, d));
    try e.b.define(d.projection, try e.when(
        try tag(e, expression, machines.index(Expression, "primitive")),
        constructed,
        try noMatch(e, d),
    ));
}

fn defineIdentity(e: Author, d: Definition) !void {
    const module = try e.param(d.identity, 0);
    const op = try e.param(d.identity, 1);
    const values = try field(e, source.ast.Module, module, "values");
    const operands = try e.field(op, 1);
    const first_id = try e.required(operands, e.zero);
    const first = try e.required(values, first_id);
    const repeated_leaf = try e.when(
        try leaf(e, first),
        try replacement(e, d, first, .identity),
        try noMatch(e, d),
    );
    const repeat = try e.when(
        try e.binary(.equal, first_id, try e.required(operands, e.one)),
        repeated_leaf,
        try noMatch(e, d),
    );
    var body = try noMatch(e, d);
    inline for ([_]data.program.Opcode{ .integer_bit_and, .integer_bit_or }) |op_tag|
        body = try e.when(try opcode(e, op, op_tag), repeat, body);
    const unary = try inversePair(e, d, values, op, first);
    inline for ([_]data.program.Opcode{ .boolean_not, .integer_bit_not }) |op_tag|
        body = try e.when(try opcode(e, op, op_tag), unary, body);
    try e.b.define(d.identity, body);
}

fn inversePair(e: Author, d: Definition, values: Id, op: Id, first: Id) !Id {
    const expression = try e.field(first, 1);
    const primitive = try e.payload(expression, machines.index(Expression, "primitive"));
    const child = try e.required(values, try e.required(try e.field(primitive, 1), e.zero));
    const same = try e.binary(
        .equal,
        try enumTag(e, try e.field(op, 0)),
        try enumTag(e, try e.field(primitive, 0)),
    );
    return e.when(
        try tag(e, expression, machines.index(Expression, "primitive")),
        try e.when(same, try replacement(e, d, child, .identity), try noMatch(e, d)),
        try noMatch(e, d),
    );
}

fn proposal(e: Author, d: Definition, module: Id, steps: Id) !Id {
    return e.b.pure(try e.tuple(d.proposal, &.{
        module, steps, try e.literal(@FieldType(compiler.RecordProposal, "interfaces"), null),
    }));
}

fn defineScan(e: Author, d: Definition) !void {
    const module = try e.param(d.scan, 0);
    const index = try e.param(d.scan, 1);
    const remaining = try e.param(d.scan, 2);
    const steps = try e.param(d.scan, 3);
    const values = try field(e, source.ast.Module, module, "values");
    const count = try e.b.primitive(e.integer, .sequence_length, &.{values}, 0);
    const matched = try e.b.variable(d.match);
    const result = try e.b.reference(matched);
    const next = try e.call(d.scan, &.{
        module, try e.binary(.integer_add, index, e.one), remaining, steps,
    });
    const rewrite = try rewriteAndContinue(e, d, result);
    const choose = try e.when(try tag(e, result, 1), rewrite, next);
    const scan = try e.b.bind(matched, try e.call(d.matcher, &.{ module, index }), choose);
    const finish = try proposal(e, d, module, steps);
    try e.b.define(d.scan, try e.when(
        try e.binary(.less, e.zero, remaining),
        try e.when(try e.binary(.less, index, count), scan, finish),
        finish,
    ));
}

fn rewriteAndContinue(e: Author, d: Definition, matched: Id) !Id {
    const module = try e.param(d.scan, 0);
    const index = try e.param(d.scan, 1);
    const rewrite = try e.payload(matched, 1);
    const values = try field(e, source.ast.Module, module, "values");
    const changed = try e.checked(
        try projection.schema([]const source.ast.Value, e.b),
        .sequence_set,
        &.{ values, index, try e.field(rewrite, 0) },
        &.{.invalid_index},
    );
    const selected = try e.replace(module, machines.index(source.ast.Module, "values"), changed);
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
        &.{ selected, rule },
    );
    const steps = try e.b.primitive(
        try projection.schema([]const source.relation.RecordStep, e.b),
        .sequence_append,
        &.{ try e.param(d.scan, 3), step },
        0,
    );
    return e.call(d.scan, &.{
        selected,
        try e.binary(.integer_add, index, e.one),
        try e.binary(.integer_sub, try e.param(d.scan, 2), e.one),
        steps,
    });
}

fn enumTag(e: Author, value: Id) !Id {
    return e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{value}, 0);
}
