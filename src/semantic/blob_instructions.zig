//! Guest bytes/text operations as ordinary Horos algorithms. Text slicing uses
//! code-point boundaries for nonempty ranges in admitted UTF-8. Every in-bounds
//! empty range is valid; scalar encoding is explicit.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const values = @import("values.zig");
const aggregates = @import("aggregate.zig");
const codecs = @import("codec.zig");
const scalars = @import("scalar.zig");
const access = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const p = data.program;
const field = access.field;
pub const Definition = struct { evaluate: Id, result: Id };
const Generator = struct {
    e: Author,
    m: machines.Definition,
    v: values.Definition,
    codec: codecs.Definition,
    result: Id,
    outcome: Id,
    bytes: Id,
    make: Id,
    maximum: Id,
    fn success(c: Generator, input: Id, value: Id) Error!Id {
        return c.e.b.pure(try c.e.tuple(c.result, &.{ input, try c.e.variant(c.outcome, 0, value) }));
    }
    fn fault(c: Generator, input: Id, kind: p.Fault) Error!Id {
        return c.e.b.pure(try c.e.tuple(c.result, &.{ input, try c.e.variant(c.outcome, 1, try c.e.literal(p.Fault, kind)) }));
    }
    fn byteBlob(c: Generator, value: Id) Error!Id {
        return c.e.b.primitive(c.bytes, .blob_from_byte, &.{try c.e.convert(value, try c.e.b.scalar(u8), true)}, 0);
    }
    fn is(c: Generator, opcode: Id, expected: p.Opcode) Error!Id {
        return c.e.binary(.equal, try c.e.b.primitive(try c.e.b.scalar(u32), .enum_tag, &.{opcode}, 0), try c.e.b.constant(u32, @backingInt(expected)));
    }
};

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.blob_instructions/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const v = try values.define(b, m);
    const aggregate = try aggregates.define(b, m);
    const codec = try codecs.define(b, m);
    const scalar = try scalars.define(b);
    const bytes = try b.schema(.bytes);
    const outcome = try projection.schema(values.Outcome, b);
    const result = try b.schema(.{ .product = &.{ m.schema, outcome } });
    const d: Definition = .{ .evaluate = try b.declare(&.{ m.schema, m.frames.schema, try projection.schema(data.activation.Instruction, b), e.integer }, result, &.{}, &.{}), .result = result };
    const c: Generator = .{
        .e = e,
        .m = m,
        .v = v,
        .codec = codec,
        .result = result,
        .outcome = outcome,
        .bytes = bytes,
        .make = try b.declare(&.{ m.schema, e.integer, bytes }, result, &.{}, &.{}),
        .maximum = try b.declare(&.{try projection.schema(p.Schema, b)}, e.integer, &.{}, &.{}),
    };
    {
        const shape = try e.param(c.maximum, 0);
        const kind = try b.primitive(e.integer, .variant_tag, &.{shape}, 0);
        var body = try b.pure(try b.constant(u64, std.math.maxInt(u64)));
        inline for ([_]p.SchemaTag{ .bounded_bytes, .bounded_text }) |tag| body = try e.when(try e.binary(.equal, kind, try b.constant(u64, @backingInt(tag))), try b.pure(try e.payload(shape, @backingInt(tag))), body);
        try b.define(c.maximum, body);
    }
    {
        const input = try e.param(c.make, 0);
        const schema = try e.param(c.make, 1);
        const raw = try e.param(c.make, 2);
        const program = try m.field(e, input, .program);
        const shapes = try field(e, try access.code(e, program), data.activation.Program, "schemas");
        const maximum = try b.variable(e.integer);
        const prefix = try b.variable(bytes);
        const made = try b.variable(v.result);
        const count = try b.primitive(e.integer, .blob_length, &.{raw}, 0);
        const success = try b.bind(prefix, try e.call(codec.natural, &.{count}), try b.bind(made, try e.call(v.literal, &.{ input, try e.tuple(try projection.schema(p.Literal, b), &.{ schema, try e.concat(try b.reference(prefix), raw) }) }), try c.success(try e.field(try b.reference(made), 0), try e.field(try b.reference(made), 1))));
        try b.define(c.make, try b.bind(maximum, try e.call(c.maximum, &.{try e.required(shapes, schema)}), try e.when(try e.binary(.less, try b.reference(maximum), count), try c.fault(input, .capacity_exceeded), success)));
    }
    const payload = try b.declare(&.{ m.schema, v.value }, bytes, &.{}, &.{});
    {
        const raw = try b.variable(bytes);
        const read = try b.variable(try projection.schema(codecs.Read, b));
        const decoded = try b.reference(read);
        try b.define(payload, try b.bind(raw, try e.call(v.bytes, &.{ try e.param(payload, 0), try e.param(payload, 1) }), try b.bind(read, try e.call(codec.read, &.{ try b.reference(raw), e.zero }), try b.pure(try e.slice(try b.reference(raw), try e.field(decoded, 1), try e.binary(.integer_add, try e.field(decoded, 1), try e.field(decoded, 0)))))));
    }
    const boundary = try b.declare(&.{ bytes, e.integer }, e.boolean, &.{}, &.{});
    {
        const raw = try e.param(boundary, 0);
        const position = try e.param(boundary, 1);
        const optional = try b.schema(.{ .sum = &.{ e.unit, try b.scalar(u8) } });
        const byte = try e.payload(try b.primitive(optional, .blob_byte, &.{ raw, position }, 0), 1);
        const valid = try e.when(try e.binary(.less, byte, try b.constant(u8, 128)), try b.pure(try b.constant(bool, true)), try b.pure(try b.primitive(e.boolean, .boolean_not, &.{try e.binary(.less, byte, try b.constant(u8, 192))}, 0)));
        try b.define(boundary, try e.when(try e.binary(.equal, position, try b.primitive(e.integer, .blob_length, &.{raw}, 0)), try b.pure(try b.constant(bool, true)), valid));
    }
    const input = try e.param(d.evaluate, 0);
    const frame = try e.param(d.evaluate, 1);
    const instruction = try e.param(d.evaluate, 2);
    const result_type = try e.param(d.evaluate, 3);
    const program = try m.field(e, input, .program);
    const shapes = try field(e, try access.code(e, program), data.activation.Program, "schemas");
    const shape = try e.required(shapes, result_type);
    const operands = try field(e, instruction, data.activation.Instruction, "operands");
    const opcode = try field(e, instruction, data.activation.Instruction, "opcode");
    const left_var = try b.variable(v.value);
    const left = try b.reference(left_var);
    const right_var = try b.variable(v.value);
    const right = try b.reference(right_var);
    const raw_var = try b.variable(bytes);
    const raw = try b.reference(raw_var);
    const length = try b.primitive(e.integer, .blob_length, &.{raw}, 0);
    const read_right = try e.call(m.frames.read, &.{ frame, try e.required(operands, e.one) });
    const natural = try b.variable(v.value);
    var blob_body = try e.fail();
    {
        const body = try b.bind(natural, try e.call(v.natural, &.{ result_type, length }), try c.success(input, try b.reference(natural)));
        blob_body = try e.when(try c.is(opcode, .blob_length), body, blob_body);
    }
    {
        const second = try b.variable(bytes);
        const maximum = try b.variable(e.integer);
        const second_length = try b.primitive(e.integer, .blob_length, &.{try b.reference(second)}, 0);
        const overflow = try c.fault(input, .capacity_exceeded);
        const build = try e.call(c.make, &.{ input, result_type, try e.concat(raw, try b.reference(second)) });
        const guard = try e.when(try e.binary(.less, try b.reference(maximum), length), overflow, try e.when(try e.binary(.less, try e.binary(.integer_sub, try b.reference(maximum), length), second_length), overflow, build));
        const body = try b.bind(right_var, read_right, try b.bind(second, try e.call(payload, &.{ input, right }), try b.bind(maximum, try e.call(c.maximum, &.{shape}), guard)));
        blob_body = try e.when(try c.is(opcode, .blob_concat), body, blob_body);
    }
    {
        const index = try b.variable(e.integer);
        const index_value = try b.reference(index);
        const optional = try b.schema(.{ .sum = &.{ e.unit, try b.scalar(u8) } });
        const selected = try b.primitive(optional, .blob_byte, &.{ raw, index_value }, 0);
        const guest_sum = try e.payload(shape, @backingInt(p.SchemaTag.sum));
        const absent = try b.variable(e.unit);
        const present = try b.variable(try b.scalar(u8));
        const made = try b.variable(v.result);
        var cases: [2]std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases")) = undefined;
        inline for (0..2) |i| {
            const payload_schema = try e.required(guest_sum, try b.constant(u64, i));
            const content = if (i == 0) e.zero else try e.convert(try b.reference(present), e.integer, false);
            const finish = try b.bind(natural, try e.call(v.natural, &.{ payload_schema, content }), try b.bind(made, try e.call(aggregate.construct, &.{ input, result_type, try b.constant(u64, i), try b.primitive(try projection.schema([]const data.graph.Value, b), .sequence, &.{try b.reference(natural)}, 0) }), try c.success(try e.field(try b.reference(made), 0), try e.field(try b.reference(made), 1))));
            cases[i] = .{ .variable = if (i == 0) absent else present, .body = finish };
        }
        const body = try b.bind(right_var, read_right, try b.bind(index, try e.call(codec.fixed, &.{try e.payload(try e.field(right, 1), 0)}), try b.term(.{ .match_sum = .{ .value = selected, .cases = &cases } })));
        blob_body = try e.when(try c.is(opcode, .blob_byte), body, blob_body);
    }
    {
        const second = try b.variable(bytes);
        const comparison = try b.primitive(try b.scalar(i8), .blob_compare, &.{ raw, try b.reference(second) }, 0);
        const numeric = try b.variable(e.integer);
        const choose = try e.when(try e.binary(.less, comparison, try b.constant(i8, 0)), try b.pure(try b.constant(u64, 255)), try e.when(try e.binary(.equal, comparison, try b.constant(i8, 0)), try b.pure(e.zero), try b.pure(e.one)));
        const body = try b.bind(right_var, read_right, try b.bind(second, try e.call(payload, &.{ input, right }), try b.bind(numeric, choose, try b.bind(natural, try e.call(v.natural, &.{ result_type, try b.reference(numeric) }), try c.success(input, try b.reference(natural))))));
        blob_body = try e.when(try c.is(opcode, .blob_compare), body, blob_body);
    }
    {
        const third = try b.variable(v.value);
        const start = try b.variable(e.integer);
        const end = try b.variable(e.integer);
        const maximum = try b.variable(e.integer);
        const valid_start = try b.variable(e.boolean);
        const valid_end = try b.variable(e.boolean);
        const a = try b.reference(start);
        const z = try b.reference(end);
        const capacity = try c.fault(input, .capacity_exceeded);
        const invalid_utf8 = try c.fault(input, .invalid_utf8);
        const build = try e.call(c.make, &.{ input, result_type, try e.slice(raw, a, z) });
        const nonempty_text = try b.bind(valid_start, try e.call(boundary, &.{ raw, a }), try e.when(try b.reference(valid_start), try b.bind(valid_end, try e.call(boundary, &.{ raw, z }), try e.when(try b.reference(valid_end), build, invalid_utf8)), invalid_utf8));
        const text_guard = try e.when(try e.binary(.equal, a, z), build, nonempty_text);
        const kind = try b.primitive(e.integer, .variant_tag, &.{shape}, 0);
        var checked = build;
        inline for ([_]p.SchemaTag{ .text, .bounded_text }) |tag| checked = try e.when(try e.binary(.equal, kind, try b.constant(u64, @backingInt(tag))), text_guard, checked);
        checked = try b.bind(maximum, try e.call(c.maximum, &.{shape}), try e.when(try e.binary(.less, try b.reference(maximum), try e.binary(.integer_sub, z, a)), capacity, checked));
        checked = try e.when(try e.binary(.less, z, a), capacity, try e.when(try e.binary(.less, length, z), capacity, checked));
        const body = try b.bind(right_var, read_right, try b.bind(third, try e.call(m.frames.read, &.{ frame, try e.required(operands, try b.constant(u64, 2)) }), try b.bind(start, try e.call(codec.fixed, &.{try e.payload(try e.field(right, 1), 0)}), try b.bind(end, try e.call(codec.fixed, &.{try e.payload(try e.field(try b.reference(third), 1), 0)}), checked))));
        blob_body = try e.when(try c.is(opcode, .blob_slice), body, blob_body);
    }
    var body = try b.bind(raw_var, try e.call(payload, &.{ input, left }), blob_body);
    {
        const raw_byte = try e.required(try e.payload(try e.field(left, 1), 0), e.zero);
        body = try e.when(try c.is(opcode, .blob_from_byte), try e.call(c.make, &.{ input, result_type, try b.primitive(bytes, .blob_from_byte, &.{raw_byte}, 0) }), body);
    }
    {
        const decimal = try b.declare(&.{ e.integer, bytes }, bytes, &.{}, &.{});
        const n = try e.param(decimal, 0);
        const rest = try e.binary(.integer_div, n, try b.constant(u64, 10));
        const digit = try e.binary(.integer_add, try e.binary(.integer_rem, n, try b.constant(u64, 10)), try b.constant(u64, 48));
        const text = try e.concat(try c.byteBlob(digit), try e.param(decimal, 1));
        try b.define(decimal, try e.when(try e.binary(.equal, rest, e.zero), try b.pure(text), try e.call(decimal, &.{ rest, text })));
        const number = try b.variable(try projection.schema(scalars.Number, b));
        const text_var = try b.variable(bytes);
        const text_bytes = try b.reference(text_var);
        const number_value = try b.reference(number);
        const emit = try e.when(try e.field(number_value, 0), try e.call(c.make, &.{ input, result_type, try e.concat(try e.literal([]const u8, "-"), text_bytes) }), try e.call(c.make, &.{ input, result_type, text_bytes }));
        const convert = try b.bind(number, try e.call(scalar.interpret, &.{ try e.required(shapes, try e.field(left, 0)), try e.payload(try e.field(left, 1), 0) }), try b.bind(text_var, try e.call(decimal, &.{ try e.field(number_value, 1), try e.literal([]const u8, &.{}) }), emit));
        body = try e.when(try c.is(opcode, .text_integer), convert, body);
    }
    {
        const codepoint = try b.variable(e.integer);
        const cp = try b.reference(codepoint);
        var encodings: [4]Id = undefined;
        encodings[0] = try c.byteBlob(cp);
        inline for (2..5) |n| {
            const leading_divisor = try b.constant(u64, @as(u64, 1) << @intCast(6 * (n - 1)));
            const leading = try e.binary(.integer_add, try b.constant(u64, if (n == 2) 192 else if (n == 3) 224 else 240), try e.binary(.integer_div, cp, leading_divisor));
            var encoded = try c.byteBlob(leading);
            inline for (0..n - 1) |i| {
                const divisor = try b.constant(u64, @as(u64, 1) << @intCast(6 * (n - 2 - i)));
                const octet = try e.binary(.integer_add, try b.constant(u64, 128), try e.binary(.integer_rem, try e.binary(.integer_div, cp, divisor), try b.constant(u64, 64)));
                encoded = try e.concat(encoded, try c.byteBlob(octet));
            }
            encodings[n - 1] = encoded;
        }
        var encode = try e.call(c.make, &.{ input, result_type, encodings[3] });
        inline for (.{ .{ @as(u64, 65536), @as(usize, 2) }, .{ @as(u64, 2048), @as(usize, 1) }, .{ @as(u64, 128), @as(usize, 0) } }) |choice| encode = try e.when(try e.binary(.less, cp, try b.constant(u64, choice[0])), try e.call(c.make, &.{ input, result_type, encodings[choice[1]] }), encode);
        const invalid = try c.fault(input, .invalid_utf8);
        encode = try e.when(try e.binary(.less, cp, try b.constant(u64, 0xd800)), encode, try e.when(try e.binary(.less, cp, try b.constant(u64, 0xe000)), invalid, encode));
        encode = try e.when(try e.binary(.less, try b.constant(u64, 0x10ffff), cp), invalid, encode);
        body = try e.when(try c.is(opcode, .text_scalar), try b.bind(codepoint, try e.call(codec.fixed, &.{try e.payload(try e.field(left, 1), 0)}), encode), body);
    }
    try b.define(d.evaluate, try b.bind(left_var, try e.call(m.frames.read, &.{ frame, try e.required(operands, e.zero) }), body));
    return cache.finish(b, d);
}
