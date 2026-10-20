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
        return c.e.b.pure(try c.e.tuple(c.result, &.{
            input, try c.e.variant(c.outcome, 0, value),
        }));
    }
    fn fault(c: Generator, input: Id, kind: p.Fault) Error!Id {
        return c.e.b.pure(try c.e.tuple(c.result, &.{ input, try c.e.variant(
            c.outcome,
            1,
            try c.e.literal(p.Fault, kind),
        ) }));
    }
    fn byteBlob(c: Generator, value: Id) Error!Id {
        return c.e.b.primitive(c.bytes, .blob_from_byte, &.{
            try c.e.convert(value, try c.e.b.scalar(u8), true),
        }, 0);
    }
    fn is(c: Generator, opcode: Id, expected: p.Opcode) Error!Id {
        return c.e.binary(.equal, try c.e.b.primitive(
            try c.e.b.scalar(u32),
            .enum_tag,
            &.{opcode},
            0,
        ), try c.e.b.constant(u32, @backingInt(expected)));
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
    const d: Definition = .{ .evaluate = try b.declare(&.{
        m.schema, m.frames.schema, try projection.schema(data.activation.Instruction, b), e.integer,
    }, result, &.{}, &.{}), .result = result };
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
    try emitC(e, c);
    try emitCBody(m, e, v, codec, bytes, c);
    const payload = try b.declare(&.{ m.schema, v.value }, bytes, &.{}, &.{});
    try emitPayload(e, v, codec, bytes, payload);
    const boundary = try b.declare(&.{ bytes, e.integer }, e.boolean, &.{}, &.{});
    try emitBoundary(e, boundary);
    try emitEvaluation(c, d, aggregate, scalar, payload, boundary);
    return cache.finish(b, d);
}

fn emitC(e: Author, c: Generator) Error!void {
    const shape = try e.param(c.maximum, 0);
    const kind = try e.b.primitive(e.integer, .variant_tag, &.{shape}, 0);
    var body = try e.b.pure(try e.b.constant(u64, std.math.maxInt(u64)));
    inline for ([_]p.SchemaTag{
        .bounded_bytes,
        .bounded_text,
    }) |tag| body = try e.when(
        try e.binary(.equal, kind, try e.b.constant(u64, @backingInt(tag))),
        try e.b.pure(try e.payload(shape, @backingInt(tag))),
        body,
    );
    try e.b.define(c.maximum, body);
}

fn emitCBody(
    m: machines.Definition,
    e: Author,
    v: values.Definition,
    codec: codecs.Definition,
    bytes: Id,
    c: Generator,
) Error!void {
    const input = try e.param(c.make, 0);
    const schema = try e.param(c.make, 1);
    const raw = try e.param(c.make, 2);
    const program = try m.field(e, input, .program);
    const shapes = try field(
        e,
        try access.code(e, program),
        data.activation.Program,
        "schemas",
    );
    const maximum = try e.b.variable(e.integer);
    const prefix = try e.b.variable(bytes);
    const made = try e.b.variable(v.result);
    const count = try e.b.primitive(e.integer, .blob_length, &.{raw}, 0);
    const success = try e.b.bind(
        prefix,
        try e.call(codec.natural, &.{
            count,
        }),
        try e.b.bind(
            made,
            try e.call(
                v.literal,
                &.{
                    input,
                    try e.tuple(
                        try projection.schema(p.Literal, e.b),
                        &.{ schema, try e.concat(try e.b.reference(prefix), raw) },
                    ),
                },
            ),
            try c.success(
                try e.field(try e.b.reference(made), 0),
                try e.field(try e.b.reference(made), 1),
            ),
        ),
    );
    try e.b.define(c.make, try e.b.bind(maximum, try e.call(
        c.maximum,
        &.{try e.required(shapes, schema)},
    ), try e.when(try e.binary(
        .less,
        try e.b.reference(maximum),
        count,
    ), try c.fault(input, .capacity_exceeded), success)));
}

fn emitPayload(
    e: Author,
    v: values.Definition,
    codec: codecs.Definition,
    bytes: Id,
    payload: Id,
) Error!void {
    const raw = try e.b.variable(bytes);
    const read = try e.b.variable(try projection.schema(codecs.Read, e.b));
    const decoded = try e.b.reference(read);
    try e.b.define(payload, try e.b.bind(raw, try e.call(v.bytes, &.{
        try e.param(payload, 0), try e.param(payload, 1),
    }), try e.b.bind(read, try e.call(
        codec.read,
        &.{ try e.b.reference(raw), e.zero },
    ), try e.b.pure(try e.slice(try e.b.reference(raw), try e.field(decoded, 1), try e.binary(
        .integer_add,
        try e.field(decoded, 1),
        try e.field(decoded, 0),
    ))))));
}

fn emitBoundary(e: Author, boundary: Id) Error!void {
    const raw = try e.param(boundary, 0);
    const position = try e.param(boundary, 1);
    const optional = try e.b.schema(.{ .sum = &.{ e.unit, try e.b.scalar(u8) } });
    const byte = try e.payload(try e.b.primitive(optional, .blob_byte, &.{ raw, position }, 0), 1);
    const valid = try e.when(try e.binary(
        .less,
        byte,
        try e.b.constant(u8, 128),
    ), try e.b.pure(try e.b.constant(
        bool,
        true,
    )), try e.b.pure(
        try e.b.primitive(
            e.boolean,
            .boolean_not,
            &.{try e.binary(
                .less,
                byte,
                try e.b.constant(u8, 192),
            )},
            0,
        ),
    ));
    try e.b.define(boundary, try e.when(try e.binary(.equal, position, try e.b.primitive(
        e.integer,
        .blob_length,
        &.{raw},
        0,
    )), try e.b.pure(try e.b.constant(bool, true)), valid));
}

fn defineBody(
    e: Author,
    c: Generator,
    payload: Id,
    input: Id,
    shape: Id,
    right_var: Id,
    right: Id,
    read_right: Id,
    second: Id,
    maximum: Id,
    guard: Id,
) Error!Id {
    return try e.b.bind(
        right_var,
        read_right,
        try e.b.bind(
            second,
            try e.call(payload, &.{
                input,
                right,
            }),
            try e.b.bind(maximum, try e.call(c.maximum, &.{shape}), guard),
        ),
    );
}

fn defineFinish(
    i: usize,
    e: Author,
    v: anytype,
    aggregate: anytype,
    c: Generator,
    input: Id,
    result_type: Id,
    natural: Id,
    made: Id,
    payload_schema: Id,
    content: anytype,
) Error!Id {
    return try e.b.bind(natural, try e.call(v.natural, &.{ payload_schema, content }), try e.b.bind(
        made,
        try e.call(
            aggregate.construct,
            &.{
                input,                    result_type,
                try e.b.constant(u64, i),
                try e.b.primitive(
                    try projection.schema([]const data.graph.Value, e.b),
                    .sequence,
                    &.{try e.b.reference(natural)},
                    0,
                ),
            },
        ),
        try c.success(
            try e.field(try e.b.reference(made), 0),
            try e.field(try e.b.reference(made), 1),
        ),
    ));
}

fn defineNonemptyText(
    e: Author,
    boundary: Id,
    raw: Id,
    build: Id,
    valid_start: Id,
    valid_end: Id,
    a: Id,
    z: Id,
    invalid_utf8: anytype,
) Error!Id {
    return try e.b.bind(
        valid_start,
        try e.call(boundary, &.{
            raw,
            a,
        }),
        try e.when(
            try e.b.reference(valid_start),
            try e.b.bind(
                valid_end,
                try e.call(boundary, &.{
                    raw,
                    z,
                }),
                try e.when(try e.b.reference(valid_end), build, invalid_utf8),
            ),
            invalid_utf8,
        ),
    );
}

fn emitBlobConcat(o: Operands, blob_body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var blob_body = blob_body_initial;

    const second = try e.b.variable(c.bytes);
    const maximum = try e.b.variable(e.integer);
    const second_length = try e.b.primitive(
        e.integer,
        .blob_length,
        &.{try e.b.reference(second)},
        0,
    );
    const overflow = try c.fault(o.input, .capacity_exceeded);
    const build = try e.call(c.make, &.{
        o.input, o.result_type, try e.concat(o.raw, try e.b.reference(second)),
    });
    const guard = try e.when(try e.binary(
        .less,
        try e.b.reference(maximum),
        o.length,
    ), overflow, try e.when(try e.binary(.less, try e.binary(
        .integer_sub,
        try e.b.reference(maximum),
        o.length,
    ), second_length), overflow, build));
    const body = try defineBody(
        e,
        c,
        o.payload,
        o.input,
        o.shape,
        o.right_var,
        o.right,
        o.read_right,
        second,
        maximum,
        guard,
    );
    blob_body = try e.when(try c.is(o.opcode, .blob_concat), body, blob_body);

    return blob_body;
}

fn emitBlobByte(o: Operands, blob_body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var blob_body = blob_body_initial;

    const index = try e.b.variable(e.integer);
    const index_value = try e.b.reference(index);
    const optional = try e.b.schema(.{ .sum = &.{ e.unit, try e.b.scalar(u8) } });
    const selected = try e.b.primitive(optional, .blob_byte, &.{ o.raw, index_value }, 0);
    const guest_sum = try e.payload(o.shape, @backingInt(p.SchemaTag.sum));
    const absent = try e.b.variable(e.unit);
    const present = try e.b.variable(try e.b.scalar(u8));
    const made = try e.b.variable(c.v.result);
    var cases: [2]std.meta.Elem(@FieldType(
        @FieldType(source.ast.Term, "match_sum"),
        "cases",
    )) = undefined;
    inline for (0..2) |i| {
        const payload_schema = try e.required(guest_sum, try e.b.constant(u64, i));
        const content = if (i == 0) e.zero else try e.convert(
            try e.b.reference(present),
            e.integer,
            false,
        );
        const finish = try defineFinish(
            i,

            e,
            c.v,
            o.aggregate,
            c,
            o.input,
            o.result_type,
            o.natural,
            made,
            payload_schema,
            content,
        );
        cases[i] = .{ .variable = if (i == 0) absent else present, .body = finish };
    }
    const body = try e.b.bind(o.right_var, o.read_right, try e.b.bind(index, try e.call(
        c.codec.fixed,
        &.{try e.payload(try e.field(o.right, 1), 0)},
    ), try e.b.term(.{ .match_sum = .{
        .value = selected,
        .cases = &cases,
    } })));
    blob_body = try e.when(try c.is(o.opcode, .blob_byte), body, blob_body);

    return blob_body;
}

fn emitBlobCompare(o: Operands, blob_body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var blob_body = blob_body_initial;

    const second = try e.b.variable(c.bytes);
    const comparison = try e.b.primitive(
        try e.b.scalar(i8),
        .blob_compare,
        &.{ o.raw, try e.b.reference(second) },
        0,
    );
    const numeric = try e.b.variable(e.integer);
    const choose = try e.when(try e.binary(
        .less,
        comparison,
        try e.b.constant(i8, 0),
    ), try e.b.pure(try e.b.constant(u64, 255)), try e.when(try e.binary(
        .equal,
        comparison,
        try e.b.constant(i8, 0),
    ), try e.b.pure(e.zero), try e.b.pure(e.one)));
    const body = try e.b.bind(
        o.right_var,
        o.read_right,
        try e.b.bind(
            second,
            try e.call(o.payload, &.{
                o.input,
                o.right,
            }),
            try e.b.bind(
                numeric,
                choose,
                try e.b.bind(
                    o.natural,
                    try e.call(c.v.natural, &.{
                        o.result_type,
                        try e.b.reference(numeric),
                    }),
                    try c.success(o.input, try e.b.reference(o.natural)),
                ),
            ),
        ),
    );
    blob_body = try e.when(try c.is(o.opcode, .blob_compare), body, blob_body);

    return blob_body;
}

fn emitBlobSlice(o: Operands, blob_body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var blob_body = blob_body_initial;

    const third = try e.b.variable(c.v.value);
    const start = try e.b.variable(e.integer);
    const end = try e.b.variable(e.integer);
    const maximum = try e.b.variable(e.integer);
    const valid_start = try e.b.variable(e.boolean);
    const valid_end = try e.b.variable(e.boolean);
    const a = try e.b.reference(start);
    const z = try e.b.reference(end);
    const capacity = try c.fault(o.input, .capacity_exceeded);
    const invalid_utf8 = try c.fault(o.input, .invalid_utf8);
    const build = try e.call(c.make, &.{ o.input, o.result_type, try e.slice(o.raw, a, z) });
    const nonempty_text = try defineNonemptyText(
        e,
        o.boundary,
        o.raw,
        build,
        valid_start,
        valid_end,
        a,
        z,
        invalid_utf8,
    );
    const text_guard = try e.when(try e.binary(.equal, a, z), build, nonempty_text);
    const kind = try e.b.primitive(e.integer, .variant_tag, &.{o.shape}, 0);
    var checked = build;
    inline for ([_]p.SchemaTag{ .text, .bounded_text }) |tag| checked = try e.when(try e.binary(
        .equal,
        kind,
        try e.b.constant(u64, @backingInt(tag)),
    ), text_guard, checked);
    checked = try e.b.bind(maximum, try e.call(c.maximum, &.{o.shape}), try e.when(try e.binary(
        .less,
        try e.b.reference(maximum),
        try e.binary(.integer_sub, z, a),
    ), capacity, checked));
    checked = try e.when(try e.binary(.less, z, a), capacity, try e.when(
        try e.binary(.less, o.length, z),
        capacity,
        checked,
    ));
    const body = try e.b.bind(
        o.right_var,
        o.read_right,
        try e.b.bind(
            third,
            try e.call(
                c.m.frames.read,
                &.{ o.frame, try e.required(o.operands, try e.b.constant(u64, 2)) },
            ),
            try e.b.bind(start, try e.call(c.codec.fixed, &.{
                try e.payload(try e.field(o.right, 1), 0),
            }), try e.b.bind(end, try e.call(c.codec.fixed, &.{try e.payload(
                try e.field(try e.b.reference(third), 1),
                0,
            )}), checked)),
        ),
    );
    blob_body = try e.when(try c.is(o.opcode, .blob_slice), body, blob_body);

    return blob_body;
}

fn emitBlobFromByte(o: Operands, body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var body = body_initial;

    const raw_byte = try e.required(try e.payload(try e.field(o.left, 1), 0), e.zero);
    body = try e.when(
        try c.is(o.opcode, .blob_from_byte),
        try e.call(
            c.make,
            &.{
                o.input,                                                      o.result_type,
                try e.b.primitive(c.bytes, .blob_from_byte, &.{raw_byte}, 0),
            },
        ),
        body,
    );

    return body;
}

fn emitDecimal(o: Operands, body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var body = body_initial;

    const decimal = try e.b.declare(&.{ e.integer, c.bytes }, c.bytes, &.{}, &.{});
    const n = try e.param(decimal, 0);
    const rest = try e.binary(.integer_div, n, try e.b.constant(u64, 10));
    const digit = try e.binary(.integer_add, try e.binary(
        .integer_rem,
        n,
        try e.b.constant(u64, 10),
    ), try e.b.constant(u64, 48));
    const text = try e.concat(try c.byteBlob(digit), try e.param(decimal, 1));
    try e.b.define(decimal, try e.when(
        try e.binary(.equal, rest, e.zero),
        try e.b.pure(text),
        try e.call(decimal, &.{ rest, text }),
    ));
    const number = try e.b.variable(try projection.schema(scalars.Number, e.b));
    const text_var = try e.b.variable(c.bytes);
    const text_bytes = try e.b.reference(text_var);
    const number_value = try e.b.reference(number);
    const emit = try e.when(
        try e.field(number_value, 0),
        try e.call(
            c.make,
            &.{ o.input, o.result_type, try e.concat(try e.literal([]const u8, "-"), text_bytes) },
        ),
        try e.call(c.make, &.{ o.input, o.result_type, text_bytes }),
    );
    const convert = try e.b.bind(number, try e.call(o.scalar.interpret, &.{
        try e.required(o.shapes, try e.field(o.left, 0)), try e.payload(try e.field(o.left, 1), 0),
    }), try e.b.bind(text_var, try e.call(decimal, &.{
        try e.field(number_value, 1), try e.literal([]const u8, &.{}),
    }), emit));
    body = try e.when(try c.is(o.opcode, .text_integer), convert, body);

    return body;
}

fn emitTextScalar(o: Operands, body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var body = body_initial;

    const codepoint = try e.b.variable(e.integer);
    const cp = try e.b.reference(codepoint);
    const encodings = try encodeUtf8(c, cp);
    var encode = try e.call(c.make, &.{ o.input, o.result_type, encodings[3] });
    inline for (.{
        .{ @as(
            u64,
            65536,
        ), @as(
            usize,
            2,
        ) },
        .{ @as(
            u64,
            2048,
        ), @as(
            usize,
            1,
        ) },
        .{ @as(
            u64,
            128,
        ), @as(
            usize,
            0,
        ) },
    }) |choice| encode = try e.when(try e.binary(
        .less,
        cp,
        try e.b.constant(u64, choice[0]),
    ), try e.call(c.make, &.{
        o.input, o.result_type, encodings[choice[1]],
    }), encode);
    const invalid = try c.fault(o.input, .invalid_utf8);
    encode = try e.when(try e.binary(
        .less,
        cp,
        try e.b.constant(u64, 0xd800),
    ), encode, try e.when(try e.binary(.less, cp, try e.b.constant(u64, 0xe000)), invalid, encode));
    encode = try e.when(try e.binary(.less, try e.b.constant(u64, 0x10ffff), cp), invalid, encode);
    body = try emitTextScalarTextScalar(e, c.codec, c, o.opcode, o.left, body, codepoint, encode);

    return body;
}

fn emitTextScalarTextScalar(
    e: Author,
    codec: anytype,
    c: Generator,
    opcode: Id,
    left: Id,
    body: anytype,
    codepoint: Id,
    encode: Id,
) Error!Id {
    return try e.when(
        try c.is(opcode, .text_scalar),
        try e.b.bind(
            codepoint,
            try e.call(codec.fixed, &.{
                try e.payload(try e.field(left, 1), 0),
            }),
            encode,
        ),
        body,
    );
}

const Operands = struct {
    c: Generator,
    aggregate: aggregates.Definition,
    scalar: scalars.Definition,
    payload: Id,
    boundary: Id,
    input: Id,
    frame: Id,
    result_type: Id,
    shapes: Id,
    shape: Id,
    operands: Id,
    opcode: Id,
    left: Id,
    right_var: Id,
    right: Id,
    raw: Id,
    length: Id,
    read_right: Id,
    natural: Id,
};

fn emitEvaluation(
    c: Generator,
    d: Definition,
    aggregate: aggregates.Definition,
    scalar: scalars.Definition,
    payload: Id,
    boundary: Id,
) Error!void {
    const e = c.e;
    const b = e.b;
    const input = try e.param(d.evaluate, 0);
    const frame = try e.param(d.evaluate, 1);
    const instruction = try e.param(d.evaluate, 2);
    const result_type = try e.param(d.evaluate, 3);
    const program = try c.m.field(e, input, .program);
    const shapes = try field(e, try access.code(e, program), data.activation.Program, "schemas");
    const shape = try e.required(shapes, result_type);
    const operands = try field(e, instruction, data.activation.Instruction, "operands");
    const opcode = try field(e, instruction, data.activation.Instruction, "opcode");
    const left_var = try b.variable(c.v.value);
    const left = try b.reference(left_var);
    const right_var = try b.variable(c.v.value);
    const right = try b.reference(right_var);
    const raw_var = try b.variable(c.bytes);
    const raw = try b.reference(raw_var);
    const length = try b.primitive(e.integer, .blob_length, &.{raw}, 0);
    const read_right = try e.call(c.m.frames.read, &.{ frame, try e.required(operands, e.one) });
    const natural = try b.variable(c.v.value);
    const o: Operands = .{
        .c = c,
        .aggregate = aggregate,
        .scalar = scalar,
        .payload = payload,
        .boundary = boundary,
        .input = input,
        .frame = frame,
        .result_type = result_type,
        .shapes = shapes,
        .shape = shape,
        .operands = operands,
        .opcode = opcode,
        .left = left,
        .right_var = right_var,
        .right = right,
        .raw = raw,
        .length = length,
        .read_right = read_right,
        .natural = natural,
    };
    var blob_body = try e.fail();
    {
        const body = try b.bind(natural, try e.call(
            c.v.natural,
            &.{ result_type, length },
        ), try c.success(input, try b.reference(natural)));
        blob_body = try e.when(try c.is(opcode, .blob_length), body, blob_body);
    }
    blob_body = try emitBlobConcat(o, blob_body);
    blob_body = try emitBlobByte(o, blob_body);
    blob_body = try emitBlobCompare(o, blob_body);
    blob_body = try emitBlobSlice(o, blob_body);
    var body = try b.bind(raw_var, try e.call(payload, &.{ input, left }), blob_body);
    body = try emitBlobFromByte(o, body);
    body = try emitDecimal(o, body);
    body = try emitTextScalar(o, body);
    try b.define(d.evaluate, try b.bind(left_var, try e.call(c.m.frames.read, &.{
        frame, try e.required(operands, e.zero),
    }), body));
}

fn encodeUtf8(c: Generator, cp: Id) Error![4]Id {
    const e = c.e;
    var encodings: [4]Id = undefined;
    encodings[0] = try c.byteBlob(cp);
    inline for (2..5) |n| {
        const leading_divisor = try e.b.constant(u64, @as(u64, 1) << @intCast(6 * (n - 1)));
        const leading = try e.binary(.integer_add, try e.b.constant(
            u64,
            if (n == 2) 192 else if (n == 3) 224 else 240,
        ), try e.binary(.integer_div, cp, leading_divisor));
        var encoded = try c.byteBlob(leading);
        inline for (0..n - 1) |i| {
            const divisor = try e.b.constant(u64, @as(u64, 1) << @intCast(6 * (n - 2 - i)));
            const octet = try e.binary(.integer_add, try e.b.constant(u64, 128), try e.binary(
                .integer_rem,
                try e.binary(.integer_div, cp, divisor),
                try e.b.constant(u64, 64),
            ));
            encoded = try e.concat(encoded, try c.byteBlob(octet));
        }
        encodings[n - 1] = encoded;
    }
    return encodings;
}
