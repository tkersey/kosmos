//! Ordinary Horos algorithms for guest scalar rules. Sign/magnitude retains
//! the whole u64 and i64 domains without requiring an outer i128 primitive.
//! Guards establish each outer arithmetic operation's domain; a guest fault
//! is an ordinary Result value, not an outer failure or native guest callback.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const source = @import("horos").source;
const projection = @import("projection.zig");
const Author = @import("author.zig").Author;
const Id = p.Id;
const Error = source.Error;

const Shape = struct { mask: u64, sign: u64 };
pub const Number = struct { negative: bool, magnitude: u64 };
pub const RawResult = union(enum) { value: u64, fault: p.Fault };

pub const Definition = struct {
    binary: Id,
    unary: Id,
    result: Id,
    interpret: Id,
    binary_raw: Id,
    unary_raw: Id,
    raw_result: Id,
    decode: Id,
    encode: Id,
};

pub fn define(b: *source.Builder) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.scalar/1", 0);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const schemas = try projection.schema(p.Schema, b);
    const opcode = try projection.schema(p.Opcode, b);
    const shape = try projection.schema(Shape, b);
    const number = try projection.schema(Number, b);
    const bytes = try projection.schema([8]u8, b);
    const result = try projection.schema(data.scalar.Result, b);
    const raw_result = try projection.schema(RawResult, b);
    const d: Definition = .{
        .binary = try b.declare(&.{ opcode, schemas, bytes, bytes }, result, &.{}, &.{}),
        .unary = try b.declare(&.{ opcode, schemas, schemas, bytes }, result, &.{}, &.{}),
        .binary_raw = try b.declare(&.{
            opcode, schemas, e.integer, e.integer,
        }, raw_result, &.{}, &.{}),
        .unary_raw = try b.declare(&.{
            opcode, schemas, schemas, e.integer,
        }, raw_result, &.{}, &.{}),
        .raw_result = raw_result,
        .decode = try b.declare(&.{bytes}, e.integer, &.{}, &.{}),
        .encode = try b.declare(&.{e.integer}, bytes, &.{}, &.{}),
        .result = result,
        .interpret = try b.declare(&.{ schemas, bytes }, number, &.{}, &.{}),
    };
    const g: Generator = .{
        .e = e,
        .result = raw_result,
        .shape = shape,
        .number = number,
        .bytes = bytes,
        .describe = try b.declare(&.{schemas}, shape, &.{}, &.{}),
        .decode = d.decode,
        .encode = d.encode,
        .signed = try b.declare(&.{ e.integer, shape }, number, &.{}, &.{}),
        .finish = try b.declare(&.{ shape, e.boolean, e.integer }, raw_result, &.{}, &.{}),
        .bits_result = try b.declare(&.{e.integer}, raw_result, &.{}, &.{}),
    };
    try g.emitRepresentation(schemas);
    try g.emitBinary(d.binary_raw);
    try g.emitUnary(d.unary_raw);
    try emitByteAdapters(e, d, raw_result, bytes, result);
    const description = try b.variable(shape);
    const raw = try b.variable(e.integer);
    try b.define(d.interpret, try b.bind(description, try e.call(
        g.describe,
        &.{try e.param(d.interpret, 0)},
    ), try b.bind(raw, try e.call(
        g.decode,
        &.{try e.param(d.interpret, 1)},
    ), try e.call(g.signed, &.{ try b.reference(raw), try b.reference(description) }))));
    return cache.finish(b, d);
}

const Generator = struct {
    e: Author,
    result: Id,
    shape: Id,
    number: Id,
    bytes: Id,
    describe: Id,
    decode: Id,
    encode: Id,
    signed: Id,
    finish: Id,
    bits_result: Id,

    fn fault(g: Generator, value: p.Fault) Error!Id {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @backingInt(value), .little);
        const literal = try g.e.b.literal(.{
            .schema = try projection.schema(p.Fault, g.e.b),
            .bytes = &bytes,
        });
        return g.e.b.pure(try g.e.variant(g.result, 1, literal));
    }
    fn not(g: Generator, value: Id) Error!Id {
        return g.e.b.primitive(g.e.boolean, .boolean_not, &.{value}, 0);
    }
    fn convert(g: Generator, value: Id, target: Id, fallible: bool) Error!Id {
        return g.e.b.value(.{ .schema = target, .expression = .{ .primitive = .{
            .opcode = .integer_convert,
            .operands = &.{value},
            .failures = if (fallible) &.{.{
                .kind = .arithmetic_overflow,
                .value = g.e.failure_literal,
            }} else &.{},
        } } });
    }
    fn is(g: Generator, op: Id, expected: p.Opcode) Error!Id {
        const tag = try g.e.b.primitive(try g.e.b.scalar(u32), .enum_tag, &.{op}, 0);
        return g.e.binary(.equal, tag, try g.e.b.constant(u32, @backingInt(expected)));
    }
    fn boolResult(g: Generator, condition: Id) Error!Id {
        return g.e.when(
            condition,
            try g.e.call(g.bits_result, &.{g.e.one}),
            try g.e.call(g.bits_result, &.{g.e.zero}),
        );
    }

    fn emitRepresentation(g: Generator, schemas: Id) Error!void {
        const e = g.e;
        const b = e.b;
        const variants = b.schemas.items[@intCast(schemas)].sum;
        const fields = @typeInfo(p.Schema).@"union";
        var cases: [fields.field_names.len]std.meta.Elem(@FieldType(
            @FieldType(source.ast.Term, "match_sum"),
            "cases",
        )) = undefined;
        inline for (fields.field_names, 0..) |name, i| {
            const value = try b.variable(variants[i]);
            const descriptor: ?Shape = comptime blk: {
                if (std.mem.eql(u8, name, "boolean")) break :blk .{ .mask = 1, .sign = 0 };
                if (std.mem.eql(u8, name, "enumeration")) break :blk .{
                    .mask = std.math.maxInt(u32),
                    .sign = 0,
                };
                const types = .{ i8, i16, i32, i64, u8, u16, u32, u64 };
                for (types) |T| if (std.mem.eql(u8, name, @typeName(T))) {
                    const bits = @typeInfo(T).int.bits;
                    break :blk .{
                        .mask = if (bits == 64) std.math.maxInt(u64) else (@as(u64, 1) << bits) - 1,
                        .sign = if (@typeInfo(
                            T,
                        ).int.signedness == .signed) @as(u64, 1) << (bits - 1) else 0,
                    };
                };
                break :blk null;
            };
            cases[i] = .{
                .variable = value,
                .body = if (descriptor) |s| try b.pure(
                    try e.tuple(
                        g.shape,
                        &.{ try b.constant(u64, s.mask), try b.constant(u64, s.sign) },
                    ),
                ) else try e.fail(),
            };
        }
        try b.define(g.describe, try b.term(.{ .match_sum = .{
            .value = try e.param(g.describe, 0),
            .cases = &cases,
        } }));
        try emitG(g, e);
        try emitRepresentationG(g, e);
        try emitSignedRepresentation(g);
    }

    fn emitBinary(g: Generator, function: Id) Error!void {
        const e = g.e;
        const b = e.b;
        const info_var = try b.variable(g.shape);
        const raw_a_var = try b.variable(e.integer);
        const raw_b_var = try b.variable(e.integer);
        const a_var = try b.variable(g.number);
        const b_var = try b.variable(g.number);
        const info = try b.reference(info_var);
        const raw_a = try b.reference(raw_a_var);
        const raw_b = try b.reference(raw_b_var);
        const left = try b.reference(a_var);
        const right = try b.reference(b_var);
        const a = try e.field(left, 1);
        const c = try e.field(right, 1);
        const an = try e.field(left, 0);
        const bn = try e.field(right, 0);
        const op = try e.param(function, 0);
        const overflow = try g.fault(.arithmetic_overflow);
        const sign_differs = try g.not(try e.binary(.equal, an, bn));
        var result = try e.fail();
        // Checked division bounds multiplication without evaluating a product
        // that does not fit u64. The final guest-width check is shared.
        const multiplication = try emitBinaryMultiplication(
            g,
            e,

            info,
            a,
            c,
            overflow,
            sign_differs,
        );
        result = try e.when(try g.is(op, .integer_mul), multiplication, result);
        result = try emitSignedArithmetic(
            g,
            op,
            info,
            a,
            c,
            an,
            bn,
            overflow,
            sign_differs,
            result,
        );
        const less = try e.when(sign_differs, try g.boolResult(an), try e.when(
            an,
            try g.boolResult(try e.binary(.less, c, a)),
            try g.boolResult(try e.binary(.less, a, c)),
        ));
        result = try e.when(try g.is(op, .less), less, result);
        result = try e.when(
            try g.is(op, .equal),
            try g.boolResult(try e.binary(.equal, raw_a, raw_b)),
            result,
        );
        inline for (.{ p.Opcode.integer_bit_and, .integer_bit_or, .integer_bit_xor }) |kind|
            result = try e.when(try g.is(op, kind), try e.call(
                g.bits_result,
                &.{try e.binary(kind, raw_a, raw_b)},
            ), result);
        result = try b.bind(b_var, try e.call(g.signed, &.{ raw_b, info }), result);
        result = try b.bind(a_var, try e.call(g.signed, &.{ raw_a, info }), result);
        result = try b.bind(raw_b_var, try b.pure(try e.param(function, 3)), result);
        result = try b.bind(raw_a_var, try b.pure(try e.param(function, 2)), result);
        result = try b.bind(info_var, try e.call(g.describe, &.{try e.param(function, 1)}), result);
        try b.define(function, result);
    }

    fn emitUnary(g: Generator, function: Id) Error!void {
        const e = g.e;
        const b = e.b;
        const info_var = try b.variable(g.shape);
        const target_var = try b.variable(g.shape);
        const raw_var = try b.variable(e.integer);
        const number_var = try b.variable(g.number);
        const info = try b.reference(info_var);
        const raw = try b.reference(raw_var);
        const op = try e.param(function, 0);
        const number = try b.reference(number_var);
        const converted = try b.bind(
            number_var,
            try e.call(g.signed, &.{
                raw,
                info,
            }),
            try b.bind(
                target_var,
                try e.call(g.describe, &.{try e.param(function, 2)}),
                try e.call(g.finish, &.{
                    try b.reference(target_var), try e.field(number, 0), try e.field(number, 1),
                }),
            ),
        );
        var result = try e.when(try g.is(op, .integer_convert), converted, try e.fail());
        result = try e.when(
            try g.is(op, .integer_bit_not),
            try e.call(
                g.bits_result,
                &.{try e.binary(
                    .integer_bit_xor,
                    raw,
                    try e.field(info, 0),
                )},
            ),
            result,
        );
        result = try e.when(try g.is(op, .boolean_not), try e.call(g.bits_result, &.{
            try e.binary(.integer_sub, e.one, raw),
        }), result);
        result = try e.when(try g.is(op, .enum_tag), try e.call(g.bits_result, &.{raw}), result);
        result = try b.bind(raw_var, try b.pure(try e.param(function, 3)), result);
        result = try b.bind(info_var, try e.call(g.describe, &.{try e.param(function, 1)}), result);
        try b.define(function, result);
    }
};

fn defineFinish(
    e: Author,
    result: Id,
    d: Definition,
    computed: Id,
    raw: Id,
    fault: Id,
    encoded: Id,
) Error!Id {
    return try e.b.term(
        .{
            .match_sum = .{
                .value = try e.b.reference(computed),
                .cases = &.{
                    .{
                        .variable = raw,
                        .body = try e.b.bind(
                            encoded,
                            try e.call(d.encode, &.{
                                try e.b.reference(
                                    raw,
                                ),
                            }),
                            try e.b.pure(try e.variant(result, 0, try e.b.reference(encoded))),
                        ),
                    },
                    .{ .variable = fault, .body = try e.b.pure(
                        try e.variant(result, 1, try e.b.reference(fault)),
                    ) },
                },
            },
        },
    );
}

fn defineBody(
    comptime unary: bool,
    e: Author,
    d: Definition,
    function: anytype,
    left: Id,
    right: Id,
    computed: Id,
    finish: Id,
) Error!Id {
    return try e.b.bind(computed, if (unary)
        try e.call(d.unary_raw, &.{
            try e.param(function, 0),
            try e.param(function, 1),
            try e.param(function, 2),
            try e.b.reference(left),
        })
    else
        try e.call(d.binary_raw, &.{
            try e.param(function, 0),
            try e.param(function, 1),
            try e.b.reference(left),
            try e.b.reference(right),
        }), finish);
}

fn emitRepresentationNegative(g: Generator, e: anytype, raw: Id, info: Id) Error!Id {
    return try e.b.pure(
        try e.tuple(
            g.number,
            &.{
                try e.b.constant(bool, true),
                try e.binary(
                    .integer_add,
                    try e.binary(.integer_sub, try e.field(info, 0), raw),
                    e.one,
                ),
            },
        ),
    );
}

fn emitBinaryMultiplication(
    g: Generator,
    e: anytype,
    info: Id,
    a: Id,
    c: Id,
    overflow: anytype,
    sign_differs: anytype,
) Error!Id {
    return try e.when(
        try e.binary(.equal, c, e.zero),
        try e.call(g.bits_result, &.{
            e.zero,
        }),
        try e.when(
            try e.binary(
                .less,
                try e.binary(.integer_div, try e.b.constant(u64, std.math.maxInt(u64)), c),
                a,
            ),
            overflow,
            try e.call(g.finish, &.{
                info,
                sign_differs,
                try e.binary(.integer_mul, a, c),
            }),
        ),
    );
}

fn emitBinaryOverflowPair(
    e: anytype,
    info: Id,
    a: Id,
    c: Id,
    an: Id,
    bn: Id,
    overflow: anytype,
    computed: Id,
) Error!Id {
    return try e.when(
        an,
        try e.when(
            bn,
            try e.when(
                try e.binary(.equal, c, e.one),
                try e.when(try e.binary(.equal, a, try e.field(info, 1)), overflow, computed),
                computed,
            ),
            computed,
        ),
        computed,
    );
}

fn emitG(g: Generator, e: anytype) Error!void {
    var value = e.zero;
    const input = try e.param(g.decode, 0);
    const byte = try e.b.scalar(u8);
    inline for (0..8) |i| {
        // Fixed array indexing is total at each of these literal indices.
        const optional = try e.b.schema(.{ .sum = &.{ e.unit, byte } });
        const selected = try e.b.primitive(
            optional,
            .sequence_get,
            &.{ input, try e.b.constant(u64, i) },
            0,
        );
        const element = try e.b.value(.{ .schema = byte, .expression = .{ .primitive = .{
            .opcode = .variant_payload,
            .operands = &.{selected},
            .immediate = 1,
            .failures = &.{.{ .kind = .invalid_variant, .value = e.failure_literal }},
        } } });
        const widened = try g.convert(element, e.integer, false);
        const shifted = try e.binary(
            .integer_mul,
            widened,
            try e.b.constant(u64, @as(u64, 1) << (8 * i)),
        );
        value = try e.binary(.integer_add, value, shifted);
    }
    try e.b.define(g.decode, try e.b.pure(value));
}

fn emitRepresentationG(g: Generator, e: anytype) Error!void {
    const input = try e.param(g.encode, 0);
    var bytes: [8]Id = undefined;
    inline for (&bytes, 0..) |*value, i| {
        const shifted = try e.binary(
            .integer_div,
            input,
            try e.b.constant(u64, @as(u64, 1) << (8 * i)),
        );
        value.* = try g.convert(try e.binary(
            .integer_rem,
            shifted,
            try e.b.constant(u64, 256),
        ), try e.b.scalar(u8), true);
    }
    try e.b.define(g.encode, try e.b.pure(try e.b.primitive(g.bytes, .sequence, &bytes, 0)));
    try e.b.define(g.bits_result, try e.b.pure(try e.variant(
        g.result,
        0,
        try e.param(g.bits_result, 0),
    )));
}

fn emitByteAdapters(e: Author, d: Definition, raw_result: Id, bytes: Id, result: Id) Error!void {
    const b = e.b;
    inline for (.{ false, true }) |unary| {
        const function = if (unary) d.unary else d.binary;
        const left = try b.variable(e.integer);
        const right = try b.variable(e.integer);
        const computed = try b.variable(raw_result);
        const raw = try b.variable(e.integer);
        const fault = try b.variable(try projection.schema(p.Fault, b));
        const encoded = try b.variable(bytes);
        const finish = try defineFinish(e, result, d, computed, raw, fault, encoded);
        var body = try defineBody(unary, e, d, function, left, right, computed, finish);
        if (!unary) body = try b.bind(right, try e.call(
            d.decode,
            &.{try e.param(function, 3)},
        ), body);
        body = try b.bind(left, try e.call(d.decode, &.{
            try e.param(function, if (unary) 3 else 2),
        }), body);
        try b.define(function, body);
    }
}

fn emitSignedRepresentation(g: Generator) Error!void {
    const e = g.e;
    const b = e.b;
    {
        const raw = try e.param(g.signed, 0);
        const info = try e.param(g.signed, 1);
        const sign = try e.field(info, 1);
        const positive = try b.pure(try e.tuple(
            g.number,
            &.{ try b.constant(bool, false), raw },
        ));
        const negative = try emitRepresentationNegative(g, e, raw, info);
        try b.define(
            g.signed,
            try e.when(
                try e.binary(.equal, sign, e.zero),
                positive,
                try e.when(try e.binary(.less, raw, sign), positive, negative),
            ),
        );
    }
    {
        const info = try e.param(g.finish, 0);
        const negative = try e.param(g.finish, 1);
        const magnitude = try e.param(g.finish, 2);
        const mask = try e.field(info, 0);
        const sign = try e.field(info, 1);
        const overflow = try g.fault(.arithmetic_overflow);
        const positive_result = try e.call(g.bits_result, &.{magnitude});
        const positive = try e.when(try e.binary(.equal, sign, e.zero), try e.when(
            try e.binary(.less, mask, magnitude),
            overflow,
            positive_result,
        ), try e.when(try e.binary(.less, magnitude, sign), positive_result, overflow));
        const negative_result = try e.call(g.bits_result, &.{try e.binary(
            .integer_add,
            try e.binary(.integer_sub, mask, magnitude),
            e.one,
        )});
        const negative_finish = try e.when(
            try e.binary(.equal, magnitude, e.zero),
            positive_result,
            try e.when(try e.binary(.less, sign, magnitude), overflow, negative_result),
        );
        try b.define(g.finish, try e.when(negative, negative_finish, positive));
    }
}

fn emitSignedArithmetic(
    g: Generator,
    op: Id,
    info: Id,
    a: Id,
    c: Id,
    an: Id,
    bn: Id,
    overflow: Id,
    sign_differs: Id,
    prior: Id,
) Error!Id {
    const e = g.e;
    const b = e.b;
    var result = prior;
    inline for (.{ p.Opcode.integer_div, .integer_rem }) |kind| {
        const computed = try e.call(g.finish, &.{
            info, if (kind == .integer_div) sign_differs else an, try e.binary(kind, a, c),
        });
        const overflow_pair = try emitBinaryOverflowPair(
            e,
            info,
            a,
            c,
            an,
            bn,
            overflow,
            computed,
        );
        const division = try e.when(
            try e.binary(.equal, c, e.zero),
            try g.fault(.division_by_zero),
            overflow_pair,
        );
        result = try e.when(try g.is(op, kind), division, result);
    }
    inline for (.{ p.Opcode.integer_add, .integer_sub }) |kind| {
        const right_negative = if (kind == .integer_sub) try g.not(bn) else bn;
        const sum = try e.when(try e.binary(.less, try e.binary(
            .integer_sub,
            try b.constant(u64, std.math.maxInt(u64)),
            a,
        ), c), overflow, try e.call(g.finish, &.{
            info, an, try e.binary(.integer_add, a, c),
        }));
        const difference = try e.when(try e.binary(.less, a, c), try e.call(g.finish, &.{
            info, right_negative, try e.binary(.integer_sub, c, a),
        }), try e.call(g.finish, &.{
            info,
            an,
            try e.binary(.integer_sub, a, c),
        }));
        result = try e.when(try g.is(op, kind), try e.when(
            try e.binary(.equal, an, right_negative),
            sum,
            difference,
        ), result);
    }
    return result;
}
