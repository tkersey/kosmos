//! Guest instruction evaluation. The evolving machine and guest fault are
//! explicit ordinary values; native guest execution is never called here.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const values = @import("values.zig");
const scalar = @import("scalar.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;

pub const Outcome = values.Outcome;
pub const Definition = struct { evaluate: Id, result: Id, outcome: Id };

pub fn define(b: *source.Builder, machine: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.instructions/1", machine.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const ordinary = try values.define(b, machine);
    const scalars = try scalar.define(b);
    const aggregate = try @import("aggregate.zig").define(b, machine);
    const edges = try @import("edges.zig").define(b, machine);
    const collection = try @import("collection_instructions.zig").define(b, machine);
    const memory = try @import("memory_instructions.zig").define(b, machine);
    const blobs = try @import("blob_instructions.zig").define(b, machine);
    const instruction = try projection.schema(data.activation.Instruction, b);
    const outcome = try projection.schema(Outcome, b);
    const result = try b.schema(.{ .product = &.{ machine.schema, outcome } });
    const d: Definition = .{
        .evaluate = try b.declare(&.{ machine.schema, machine.frames.schema, instruction, e.integer, try projection.schema([]const Id, b), e.boolean }, result, &.{}, &.{}),
        .result = result,
        .outcome = outcome,
    };
    const input = try e.param(d.evaluate, 0);
    const frame = try e.param(d.evaluate, 1);
    const code = try e.param(d.evaluate, 2);
    const result_type = try e.param(d.evaluate, 3);
    const layout = try e.param(d.evaluate, 4);
    const virtualize = try e.param(d.evaluate, 5);
    const opcode = try e.field(code, machines.index(data.activation.Instruction, "opcode"));
    const operands = try e.field(code, machines.index(data.activation.Instruction, "operands"));
    const program = try e.field(try machine.field(e, input, .program), machines.index(projection.Program, "code"));
    const schemas = try e.field(program, machines.index(data.activation.Program, "schemas"));
    const literals = try e.field(program, machines.index(data.activation.Program, "constants"));
    const left = try b.variable(ordinary.value);
    const right = try b.variable(ordinary.value);
    const l = try b.reference(left);
    const r = try b.reference(right);
    const scalar_result = try b.variable(scalars.result);
    const scalar_bytes = try b.variable(try projection.schema([8]u8, b));
    const fault = try b.variable(try projection.schema(data.program.Fault, b));
    const body_type = b.schemas.items[@intCast(ordinary.value)].product[1];
    const wrapped_scalar = try e.tuple(ordinary.value, &.{ result_type, try e.variant(body_type, 0, try b.reference(scalar_bytes)) });
    const finish_scalar = try b.term(.{ .match_sum = .{
        .value = try b.reference(scalar_result),
        .cases = &.{
            .{ .variable = scalar_bytes, .body = try b.pure(try e.tuple(result, &.{ input, try e.variant(outcome, 0, wrapped_scalar) })) },
            .{ .variable = fault, .body = try b.pure(try e.tuple(result, &.{ input, try e.variant(outcome, 1, try b.reference(fault)) })) },
        },
    } });
    // Admitted frames have the schema of their slot. Reading that immutable
    // declaration makes scalar dispatch static without inspecting input bytes.
    const left_schema = try e.required(schemas, try e.required(layout, try e.required(operands, e.zero)));
    const left_bytes = try e.payload(try e.field(l, 1), 0);
    const right_bytes = try e.payload(try e.field(r, 1), 0);
    const read_left = try e.call(machine.frames.read, &.{ frame, try e.required(operands, e.zero) });
    const read_right = try e.call(machine.frames.read, &.{ frame, try e.required(operands, e.one) });
    const binary = try b.bind(left, read_left, try b.bind(right, read_right, try b.bind(scalar_result, try e.call(scalars.binary, &.{ opcode, left_schema, left_bytes, right_bytes }), finish_scalar)));
    const unary = try b.bind(left, read_left, try b.bind(scalar_result, try e.call(scalars.unary, &.{ opcode, left_schema, try e.required(schemas, result_type), left_bytes }), finish_scalar));
    const raw_left = try b.variable(e.integer);
    const raw_right = try b.variable(e.integer);
    const raw_result = try b.variable(scalars.raw_result);
    const raw_bits = try b.variable(e.integer);
    const raw_scalar = try projection.schema(@import("frames.zig").Scalar, b);
    const raw_finish = try b.term(.{ .match_sum = .{ .value = try b.reference(raw_result), .cases = &.{
        .{ .variable = raw_bits, .body = try b.pure(try e.tuple(result, &.{ input, try e.variant(outcome, 2, try e.tuple(raw_scalar, &.{ result_type, try b.reference(raw_bits) })) })) },
        .{ .variable = fault, .body = try b.pure(try e.tuple(result, &.{ input, try e.variant(outcome, 1, try b.reference(fault)) })) },
    } } });
    const raw_read_left = try e.call(machine.frames.read_raw, &.{ frame, try e.required(operands, e.zero) });
    const raw_binary = try b.bind(raw_left, raw_read_left, try b.bind(raw_right, try e.call(machine.frames.read_raw, &.{ frame, try e.required(operands, e.one) }), try b.bind(raw_result, try e.call(scalars.binary_raw, &.{ opcode, left_schema, try b.reference(raw_left), try b.reference(raw_right) }), raw_finish)));
    const raw_unary = try b.bind(raw_left, raw_read_left, try b.bind(raw_result, try e.call(scalars.unary_raw, &.{ opcode, left_schema, try e.required(schemas, result_type), try b.reference(raw_left) }), raw_finish));
    var body = try e.fail();
    inline for (.{ data.program.Opcode.integer_add, .integer_sub, .integer_mul, .integer_div, .integer_rem, .integer_bit_and, .integer_bit_or, .integer_bit_xor, .equal, .less }) |kind|
        body = try e.when(try is(e, opcode, kind), try e.when(virtualize, raw_binary, binary), body);
    inline for (.{ data.program.Opcode.integer_bit_not, .integer_convert, .enum_tag, .boolean_not }) |kind|
        body = try e.when(try is(e, opcode, kind), try e.when(virtualize, raw_unary, unary), body);
    const moved = try b.bind(left, read_left, try b.pure(try e.tuple(result, &.{ input, try e.variant(outcome, 0, l) })));
    body = try e.when(try is(e, opcode, .move), moved, body);
    const literal_result = try b.variable(ordinary.result);
    const constant = try e.required(literals, try e.field(code, machines.index(data.activation.Instruction, "immediate")));
    const literal = try b.bind(literal_result, try e.call(ordinary.literal, &.{ input, constant }), try b.pure(try e.tuple(result, &.{ try e.field(try b.reference(literal_result), 0), try e.variant(outcome, 0, try e.field(try b.reference(literal_result), 1)) })));
    body = try e.when(try is(e, opcode, .constant), literal, body);
    const produced = try b.variable(ordinary.result);
    const produced_value = try b.reference(produced);
    const success = try b.pure(try e.tuple(result, &.{ try e.field(produced_value, 0), try e.variant(outcome, 0, try e.field(produced_value, 1)) }));
    const immediate = try e.field(code, machines.index(data.activation.Instruction, "immediate"));
    const children = try b.variable(try projection.schema([]const data.graph.Value, b));
    const construct = try b.bind(children, try e.call(edges.collect, &.{ frame, operands }), try b.bind(produced, try e.call(aggregate.construct, &.{ input, result_type, immediate, try b.reference(children) }), success));
    inline for (.{ data.program.Opcode.product, .variant, .sequence }) |kind|
        body = try e.when(try is(e, opcode, kind), construct, body);
    const project_field = try b.bind(left, read_left, try b.bind(produced, try e.call(aggregate.field, &.{ input, l, immediate }), success));
    body = try e.when(try is(e, opcode, .field), project_field, body);
    const tag = try b.variable(e.integer);
    const tag_result = try b.variable(ordinary.value);
    const read_tag = try e.call(aggregate.tag, &.{ input, l });
    const variant_tag = try b.bind(left, read_left, try b.bind(tag, read_tag, try b.bind(tag_result, try e.call(ordinary.natural, &.{ result_type, try b.reference(tag) }), try b.pure(try e.tuple(result, &.{ input, try e.variant(outcome, 0, try b.reference(tag_result)) })))));
    body = try e.when(try is(e, opcode, .variant_tag), variant_tag, body);
    const mismatch = try b.pure(try e.tuple(result, &.{ input, try e.variant(outcome, 1, try e.literal(data.program.Fault, .invalid_variant)) }));
    const payload = try b.bind(left, read_left, try b.bind(tag, read_tag, try e.when(try e.binary(.equal, try b.reference(tag), immediate), try b.bind(produced, try e.call(aggregate.payload, &.{ input, l }), success), mismatch)));
    body = try e.when(try is(e, opcode, .variant_payload), payload, body);
    const selected_slot = try b.variable(e.integer);
    const condition = try e.binary(.equal, try e.required(left_bytes, e.zero), try b.constant(u8, 1));
    const selected = try b.bind(left, read_left, try b.bind(selected_slot, try e.when(condition, try b.pure(try e.required(operands, e.one)), try b.pure(try e.required(operands, try b.constant(u64, 2)))), try b.bind(right, try e.call(machine.frames.read, &.{ frame, try b.reference(selected_slot) }), try b.pure(try e.tuple(result, &.{ input, try e.variant(outcome, 0, r) })))));
    body = try e.when(try is(e, opcode, .select), selected, body);
    inline for (.{ data.program.Opcode.sequence_length, .sequence_get, .sequence_append, .sequence_concat, .sequence_pop, .sequence_set, .sequence_take, .sequence_pop_last }) |kind|
        body = try e.when(try is(e, opcode, kind), try e.call(collection.evaluate, &.{ input, frame, code, result_type }), body);
    inline for (.{ data.program.Opcode.computation, .cell_new, .cell_get, .cell_set, .package, .unpack, .resource_pack, .resource_unpack, .clone_resumption }) |kind|
        body = try e.when(try is(e, opcode, kind), try e.call(memory.evaluate, &.{ input, frame, code, result_type }), body);
    inline for (.{ data.program.Opcode.blob_length, .blob_concat, .blob_slice, .blob_compare, .blob_byte, .text_scalar, .text_integer, .blob_from_byte }) |kind|
        body = try e.when(try is(e, opcode, kind), try e.call(blobs.evaluate, &.{ input, frame, code, result_type }), body);
    try b.define(d.evaluate, body);
    return cache.finish(b, d);
}

pub fn is(e: Author, opcode: Id, expected: data.program.Opcode) Error!Id {
    const tag = try e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{opcode}, 0);
    return e.binary(.equal, tag, try e.b.constant(u32, @backingInt(expected)));
}
