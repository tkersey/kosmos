//! Guest collection operations built from logical ranges and explicit values.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const values = @import("values.zig");
const aggregates = @import("aggregate.zig");
const collections = @import("collections.zig");
const codecs = @import("codec.zig");
const access = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const p = data.program;
const g = data.graph;
const field = access.field;

pub const Definition = struct { evaluate: Id, result: Id };
const Generator = struct {
    e: Author,
    m: machines.Definition,
    v: values.Definition,
    aggregate: aggregates.Definition,
    collection: collections.Definition,
    input: Id,
    program: Id,
    shapes: Id,
    result: Id,
    outcome: Id,
    segments: Id,
    fields: Id,
    fn success(c: Generator, machine: Id, value: Id) Error!Id {
        return c.e.b.pure(try c.e.tuple(c.result, &.{ machine, try c.e.variant(c.outcome, 0, value) }));
    }
    fn fault(c: Generator, machine: Id, kind: p.Fault) Error!Id {
        return c.e.b.pure(try c.e.tuple(c.result, &.{ machine, try c.e.variant(c.outcome, 1, try c.e.literal(p.Fault, kind)) }));
    }
    fn finish(c: Generator, term: Id) Error!Id {
        const variable = try c.e.b.variable(c.v.result);
        const pair = try c.e.b.reference(variable);
        return c.e.b.bind(variable, term, try c.success(try c.e.field(pair, 0), try c.e.field(pair, 1)));
    }
    fn singleton(c: Generator, element: Id, value: Id) Error!Id {
        const storage = c.e.b.schemas.items[@intCast(c.collection.schema)].product[2];
        return c.e.tuple(c.collection.schema, &.{ element, c.e.one, try c.e.variant(storage, 1, try c.e.b.primitive(c.fields, .sequence, &.{value}, 0)) });
    }
    fn rebuild(c: Generator, machine: Id, schema: Id, count: Id, segments: []const Id) Error!Id {
        return c.e.call(c.collection.rebuild, &.{ machine, schema, count, try c.e.b.primitive(c.segments, .sequence, segments, 0) });
    }
    fn is(c: Generator, opcode: Id, expected: p.Opcode) Error!Id {
        const tag = try c.e.b.primitive(try c.e.b.scalar(u32), .enum_tag, &.{opcode}, 0);
        return c.e.binary(.equal, tag, try c.e.b.constant(u32, @backingInt(expected)));
    }
    fn make(c: Generator, machine: Id, schema: Id, tag: Id, fields: []const Id) Error!Id {
        return c.e.call(c.aggregate.construct, &.{ machine, schema, tag, try c.e.b.primitive(c.fields, .sequence, fields, 0) });
    }
};

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.collection_instructions/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const v = try values.define(b, m);
    const aggregate = try aggregates.define(b, m);
    const collection = try collections.define(b, m);
    const codec = try codecs.define(b, m);
    const outcome = try projection.schema(values.Outcome, b);
    const result = try b.schema(.{ .product = &.{ m.schema, outcome } });
    const d: Definition = .{ .evaluate = try b.declare(&.{ m.schema, m.frames.schema, try projection.schema(data.activation.Instruction, b), e.integer }, result, &.{}, &.{}), .result = result };
    const input = try e.param(d.evaluate, 0);
    const frame = try e.param(d.evaluate, 1);
    const instruction = try e.param(d.evaluate, 2);
    const result_schema = try e.param(d.evaluate, 3);
    const program = try m.field(e, input, .program);
    const shapes = try field(e, try access.code(e, program), data.activation.Program, "schemas");
    const c: Generator = .{ .e = e, .m = m, .v = v, .aggregate = aggregate, .collection = collection, .input = input, .program = program, .shapes = shapes, .result = result, .outcome = outcome, .segments = try projection.schema([]const collections.Collection, b), .fields = try projection.schema([]const g.Value, b) };
    const opcode = try field(e, instruction, data.activation.Instruction, "opcode");
    const operands = try field(e, instruction, data.activation.Instruction, "operands");
    const left_var = try b.variable(v.value);
    const left = try b.reference(left_var);
    const right_var = try b.variable(v.value);
    const right = try b.reference(right_var);
    const view_var = try b.variable(collection.schema);
    const view = try b.reference(view_var);
    const count = try e.field(view, 1);
    const element = try e.field(view, 0);
    const shape = try e.required(shapes, result_schema);
    const index_var = try b.variable(e.integer);
    const index = try b.reference(index_var);
    const read_right = try e.call(m.frames.read, &.{ frame, try e.required(operands, e.one) });
    const read_index = try e.call(codec.fixed, &.{try e.payload(try e.field(right, 1), 0)});
    var body = try e.fail();
    {
        const natural = try b.variable(v.value);
        const length = try b.bind(natural, try e.call(v.natural, &.{ result_schema, count }), try c.success(input, try b.reference(natural)));
        body = try e.when(try c.is(opcode, .sequence_length), length, body);
    }
    {
        const item = try b.variable(v.result);
        const absent = try b.variable(v.value);
        const sum_types = try e.payload(shape, @backingInt(p.SchemaTag.sum));
        const no = try b.bind(absent, try e.call(v.natural, &.{ try e.required(sum_types, e.zero), e.zero }), try c.finish(try c.make(input, result_schema, e.zero, &.{try b.reference(absent)})));
        const yes = try b.bind(item, try e.call(collection.item, &.{ input, view, index }), try c.finish(try c.make(try e.field(try b.reference(item), 0), result_schema, e.one, &.{try e.field(try b.reference(item), 1)})));
        const get = try b.bind(right_var, read_right, try b.bind(index_var, read_index, try e.when(try e.binary(.less, index, count), yes, no)));
        body = try e.when(try c.is(opcode, .sequence_get), get, body);
    }
    inline for (.{ p.Opcode.sequence_append, .sequence_concat }) |opcode_kind| {
        const second_var = try b.variable(collection.schema);
        const second = try b.reference(second_var);
        const right_count = try e.field(second, 1);
        const total = try e.binary(.integer_add, count, right_count);
        const maximum = try b.variable(e.integer);
        const max_value = try b.reference(maximum);
        const vector = try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{shape}, 0), try b.constant(u64, @backingInt(p.SchemaTag.vector)));
        const overflow = try e.when(vector, try c.fault(input, .capacity_exceeded), try e.fail());
        const finish = try c.finish(try c.rebuild(input, result_schema, total, &.{ view, second }));
        const within = try e.when(try e.binary(.less, max_value, count), overflow, try e.when(try e.binary(.less, try e.binary(.integer_sub, max_value, count), right_count), overflow, finish));
        const choose_max = try e.when(vector, try b.pure(try e.field(try e.payload(shape, @backingInt(p.SchemaTag.vector)), 1)), try b.pure(try b.constant(u64, @import("std").math.maxInt(u64))));
        const choose_second = if (opcode_kind == .sequence_concat) try e.call(collection.view, &.{ input, right }) else try b.pure(try c.singleton(element, right));
        const operation = try b.bind(right_var, read_right, try b.bind(second_var, choose_second, try b.bind(maximum, choose_max, within)));
        body = try e.when(try c.is(opcode, opcode_kind), operation, body);
    }
    {
        const length = try b.variable(e.integer);
        const range = try b.variable(collection.schema);
        const take = try b.bind(right_var, read_right, try b.bind(index_var, read_index, try b.bind(length, try e.when(try e.binary(.less, index, count), try b.pure(index), try b.pure(count)), try b.bind(range, try e.call(collection.range, &.{ program, view, e.zero, try b.reference(length) }), try c.finish(try c.rebuild(input, result_schema, try b.reference(length), &.{try b.reference(range)}))))));
        body = try e.when(try c.is(opcode, .sequence_take), take, body);
    }
    {
        const replacement = try b.variable(v.value);
        const prefix = try b.variable(collection.schema);
        const suffix = try b.variable(collection.schema);
        const next = try e.binary(.integer_add, index, e.one);
        var set = try c.finish(try c.rebuild(input, result_schema, count, &.{ try b.reference(prefix), try c.singleton(element, try b.reference(replacement)), try b.reference(suffix) }));
        set = try b.bind(suffix, try e.call(collection.range, &.{ program, view, next, try e.binary(.integer_sub, count, next) }), set);
        set = try b.bind(prefix, try e.call(collection.range, &.{ program, view, e.zero, index }), set);
        set = try b.bind(replacement, try e.call(m.frames.read, &.{ frame, try e.required(operands, try b.constant(u64, 2)) }), set);
        set = try b.bind(right_var, read_right, try b.bind(index_var, read_index, try e.when(try e.binary(.less, index, count), set, try c.fault(input, .invalid_index))));
        body = try e.when(try c.is(opcode, .sequence_set), set, body);
    }
    {
        const sum_types = try e.payload(shape, @backingInt(p.SchemaTag.sum));
        const pair_type = try e.required(sum_types, e.one);
        const range = try b.variable(collection.schema);
        const remainder = try b.variable(v.result);
        const first = try b.variable(v.result);
        const pair = try b.variable(v.result);
        const absent = try b.variable(v.value);
        const length = try e.binary(.integer_sub, count, e.one);
        var present = try c.finish(try c.make(try e.field(try b.reference(pair), 0), result_schema, e.one, &.{try e.field(try b.reference(pair), 1)}));
        present = try b.bind(pair, try c.make(try e.field(try b.reference(first), 0), pair_type, e.zero, &.{ try e.field(try b.reference(first), 1), try e.field(try b.reference(remainder), 1) }), present);
        present = try b.bind(first, try e.call(collection.item, &.{ try e.field(try b.reference(remainder), 0), view, e.zero }), present);
        present = try b.bind(remainder, try c.rebuild(input, try e.field(left, 0), length, &.{try b.reference(range)}), present);
        present = try b.bind(range, try e.call(collection.range, &.{ program, view, e.one, length }), present);
        const empty = try b.bind(absent, try e.call(v.natural, &.{ try e.required(sum_types, e.zero), e.zero }), try c.finish(try c.make(input, result_schema, e.zero, &.{try b.reference(absent)})));
        body = try e.when(try c.is(opcode, .sequence_pop), try e.when(try e.binary(.equal, count, e.zero), empty, present), body);
    }
    {
        const product_types = try e.payload(shape, @backingInt(p.SchemaTag.product));
        const optional_type = try e.required(product_types, e.one);
        const optional_types = try e.payload(try e.required(shapes, optional_type), @backingInt(p.SchemaTag.sum));
        const length = try b.variable(e.integer);
        const tag = try b.variable(e.integer);
        const range = try b.variable(collection.schema);
        const remainder = try b.variable(v.result);
        const item = try b.variable(v.result);
        const optional = try b.variable(v.result);
        const absent = try b.variable(v.value);
        const remaining_machine = try e.field(try b.reference(remainder), 0);
        const none = try b.bind(absent, try e.call(v.natural, &.{ try e.required(optional_types, e.zero), e.zero }), try b.pure(try e.tuple(v.result, &.{ remaining_machine, try b.reference(absent) })));
        const some = try e.call(collection.item, &.{ remaining_machine, view, try b.reference(length) });
        var pop = try c.finish(try c.make(try e.field(try b.reference(optional), 0), result_schema, e.zero, &.{ try e.field(try b.reference(remainder), 1), try e.field(try b.reference(optional), 1) }));
        pop = try b.bind(optional, try c.make(try e.field(try b.reference(item), 0), optional_type, try b.reference(tag), &.{try e.field(try b.reference(item), 1)}), pop);
        pop = try b.bind(item, try e.when(try e.binary(.equal, count, e.zero), none, some), pop);
        pop = try b.bind(remainder, try c.rebuild(input, try e.field(left, 0), try b.reference(length), &.{try b.reference(range)}), pop);
        pop = try b.bind(range, try e.call(collection.range, &.{ program, view, e.zero, try b.reference(length) }), pop);
        pop = try b.bind(tag, try e.when(try e.binary(.equal, count, e.zero), try b.pure(e.zero), try b.pure(e.one)), pop);
        pop = try b.bind(length, try e.when(try e.binary(.equal, count, e.zero), try b.pure(e.zero), try b.pure(try e.binary(.integer_sub, count, e.one))), pop);
        body = try e.when(try c.is(opcode, .sequence_pop_last), pop, body);
    }
    try b.define(d.evaluate, try b.bind(left_var, try e.call(m.frames.read, &.{ frame, try e.required(operands, e.zero) }), try b.bind(view_var, try e.call(collection.view, &.{ input, left }), body)));
    return cache.finish(b, d);
}
