//! Source algorithms over already admitted guest value encodings. This is value
//! interpretation, not a second native decoder or a substitute for admission.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const access = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;

pub const Read = struct { value: u64, next: u64 };
pub const Definition = struct { read: Id, natural: Id, skip: Id, skip_many: Id, skip_fields: Id, fixed: Id, fixed_bytes: Id };

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.codec/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const bytes = try b.schema(.bytes);
    const read = try projection.schema(Read, b);
    const fixed_bytes = try projection.schema([8]u8, b);
    const ids = try projection.schema([]const Id, b);
    const d: Definition = .{
        .read = try b.declare(&.{ bytes, e.integer }, read, &.{}, &.{}),
        .natural = try b.declare(&.{e.integer}, bytes, &.{}, &.{}),
        .skip = try b.declare(&.{ m.program, e.integer, bytes, e.integer }, e.integer, &.{}, &.{}),
        .skip_many = try b.declare(&.{ m.program, e.integer, bytes, e.integer, e.integer }, e.integer, &.{}, &.{}),
        .skip_fields = try b.declare(&.{ m.program, ids, bytes, e.integer }, e.integer, &.{}, &.{}),
        .fixed = try b.declare(&.{fixed_bytes}, e.integer, &.{}, &.{}),
        .fixed_bytes = try b.declare(&.{e.integer}, fixed_bytes, &.{}, &.{}),
    };
    const byte = try b.scalar(u8);
    const optional_byte = try b.schema(.{ .sum = &.{ e.unit, byte } });
    const base = try b.constant(u64, 128);
    {
        const loop = try b.declare(&.{ bytes, e.integer, e.integer, e.integer }, read, &.{}, &.{});
        const input = try e.param(loop, 0);
        const position = try e.param(loop, 1);
        const accumulated = try e.param(loop, 2);
        const multiplier = try e.param(loop, 3);
        const octet = try e.convert(try e.payload(try b.primitive(optional_byte, .blob_byte, &.{ input, position }, 0), 1), e.integer, false);
        const low = try e.binary(.integer_rem, octet, base);
        const combined = try e.binary(.integer_add, accumulated, try e.binary(.integer_mul, low, multiplier));
        const next = try e.binary(.integer_add, position, e.one);
        try b.define(loop, try e.when(try e.binary(.less, octet, base), try b.pure(try e.tuple(read, &.{ combined, next })), try e.call(loop, &.{ input, next, combined, try e.binary(.integer_mul, multiplier, base) })));
        try b.define(d.read, try e.call(loop, &.{ try e.param(d.read, 0), try e.param(d.read, 1), e.zero, e.one }));
    }
    {
        const loop = try b.declare(&.{ e.integer, bytes }, bytes, &.{}, &.{});
        const input = try e.param(loop, 0);
        const prior = try e.param(loop, 1);
        const remaining = try e.binary(.integer_div, input, base);
        const low = try e.binary(.integer_rem, input, base);
        const final_byte = try b.primitive(bytes, .blob_from_byte, &.{try e.convert(low, byte, true)}, 0);
        const continuation = try b.primitive(bytes, .blob_from_byte, &.{try e.convert(try e.binary(.integer_add, low, base), byte, true)}, 0);
        try b.define(loop, try e.when(try e.binary(.equal, remaining, e.zero), try b.pure(try e.concat(prior, final_byte)), try e.call(loop, &.{ remaining, try e.concat(prior, continuation) })));
        try b.define(d.natural, try e.call(loop, &.{ try e.param(d.natural, 0), try e.literal([]const u8, &.{}) }));
    }
    {
        var decoded = e.zero;
        var encoded: [8]Id = undefined;
        const input_bytes = try e.param(d.fixed, 0);
        const input = try e.param(d.fixed_bytes, 0);
        for (0..8) |i| {
            const divisor = try b.constant(u64, @as(u64, 1) << @intCast(i * 8));
            const octet = try e.convert(try e.required(input_bytes, try b.constant(u64, i)), e.integer, false);
            decoded = try e.binary(.integer_add, decoded, try e.binary(.integer_mul, octet, divisor));
            encoded[i] = try e.convert(try e.binary(.integer_rem, try e.binary(.integer_div, input, divisor), try b.constant(u64, 256)), byte, true);
        }
        try b.define(d.fixed, try b.pure(decoded));
        try b.define(d.fixed_bytes, try b.pure(try b.primitive(fixed_bytes, .sequence, &encoded, 0)));
    }
    {
        const program = try e.param(d.skip_many, 0);
        const schema = try e.param(d.skip_many, 1);
        const input = try e.param(d.skip_many, 2);
        const offset = try e.param(d.skip_many, 3);
        const count = try e.param(d.skip_many, 4);
        const minimum = try e.required(try access.field(e, try access.field(e, program, projection.Program, "schemas"), data.admission.SchemaFacts, "minimum"), schema);
        const next = try b.variable(e.integer);
        const more = try b.bind(next, try e.call(d.skip, &.{ program, schema, input, offset }), try e.call(d.skip_many, &.{ program, schema, input, try b.reference(next), try e.binary(.integer_sub, count, e.one) }));
        const done = try b.pure(offset);
        try b.define(d.skip_many, try e.when(try e.binary(.equal, count, e.zero), done, try e.when(try e.binary(.equal, minimum, e.zero), done, more)));
    }
    {
        const program = try e.param(d.skip_fields, 0);
        const types = try e.param(d.skip_fields, 1);
        const input = try e.param(d.skip_fields, 2);
        const offset = try e.param(d.skip_fields, 3);
        const parts = try b.schema(.{ .product = &.{ e.integer, ids } });
        const popped = try b.schema(.{ .sum = &.{ e.unit, parts } });
        const nil = try b.variable(e.unit);
        const pair_var = try b.variable(parts);
        const pair = try b.reference(pair_var);
        const next = try b.variable(e.integer);
        try b.define(d.skip_fields, try b.term(.{ .match_sum = .{ .value = try b.primitive(popped, .sequence_pop, &.{types}, 0), .cases = &.{
            .{ .variable = nil, .body = try b.pure(offset) },
            .{ .variable = pair_var, .body = try b.bind(next, try e.call(d.skip, &.{ program, try e.field(pair, 0), input, offset }), try e.call(d.skip_fields, &.{ program, try e.field(pair, 1), input, try b.reference(next) })) },
        } } }));
    }
    {
        const program = try e.param(d.skip, 0);
        const schema = try e.param(d.skip, 1);
        const input = try e.param(d.skip, 2);
        const offset = try e.param(d.skip, 3);
        const schemas = try access.field(e, try access.code(e, program), data.activation.Program, "schemas");
        const descriptor = try projection.schema(data.program.Schema, b);
        const variants = b.schemas.items[@intCast(descriptor)].sum;
        const names = @typeInfo(data.program.Schema).@"union".field_names;
        const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
        var cases: [names.len]Case = undefined;
        inline for (names, 0..) |name, i| {
            const variable = try b.variable(variants[i]);
            const shape = try b.reference(variable);
            const tag: data.program.SchemaTag = @field(data.program.SchemaTag, name);
            const width: ?u64 = switch (tag) {
                .unit => 0,
                .boolean, .u8, .i8 => 1,
                .u16, .i16 => 2,
                .u32, .i32, .enumeration => 4,
                .u64, .i64 => 8,
                else => null,
            };
            const count = try b.variable(read);
            const decoded = try b.reference(count);
            const body = if (width) |n| try b.pure(try e.binary(.integer_add, offset, try b.constant(u64, n))) else switch (tag) {
                .bytes, .text, .bounded_bytes, .bounded_text => try b.bind(count, try e.call(d.read, &.{ input, offset }), try b.pure(try e.binary(.integer_add, try e.field(decoded, 1), try e.field(decoded, 0)))),
                .product => try e.call(d.skip_fields, &.{ program, shape, input, offset }),
                .sum => try b.bind(count, try e.call(d.read, &.{ input, offset }), try e.call(d.skip, &.{ program, try e.required(shape, try e.field(decoded, 0)), input, try e.field(decoded, 1) })),
                .seq, .vector => try b.bind(count, try e.call(d.read, &.{ input, offset }), try e.call(d.skip_many, &.{ program, if (tag == .seq) shape else try e.field(shape, 0), input, try e.field(decoded, 1), try e.field(decoded, 0) })),
                .array => try e.call(d.skip_many, &.{ program, try e.field(shape, 0), input, offset, try e.field(shape, 1) }),
                else => try e.fail(),
            };
            cases[i] = .{ .variable = variable, .body = body };
        }
        try b.define(d.skip, try b.term(.{ .match_sum = .{ .value = try e.required(schemas, schema), .cases = &cases } }));
    }
    return cache.finish(b, d);
}
