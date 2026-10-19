//! Canonical guest-value admission for the pure hypothetical interpreter.
//! Inputs are ordinary bytes, so the outer program's bytes schema cannot admit
//! their guest meaning. These Horos functions recognize the same value grammar
//! as Horos data admission; they neither advance a guest nor acquire authority.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const edges = @import("edges.zig");
const codec = @import("codec.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;

pub const Definition = struct { value: Id, fields: Id };

const Generator = struct {
    e: Author,
    utf8: Id,

    fn byte(g: Generator, input: Id, offset: Id) Error!Id {
        const byte_type = try g.e.b.scalar(u8);
        const optional = try g.e.b.schema(.{ .sum = &.{ g.e.unit, byte_type } });
        return g.e.convert(try g.e.payload(try g.e.b.primitive(optional, .blob_byte, &.{ input, offset }, 0), 1), g.e.integer, false);
    }

    fn within(g: Generator, value: Id, low: Id, high: Id, body: Id) Error!Id {
        return g.e.when(try g.e.binary(.less, value, low), try g.e.fail(), try g.e.when(try g.e.binary(.less, high, value), try g.e.fail(), body));
    }

    fn utf8Sequence(g: Generator, input: Id, at: Id, end: Id, comptime width: u64, low_second: Id, high_second: Id) Error!Id {
        const e = g.e;
        const next = try e.binary(.integer_add, at, try e.b.constant(u64, width));
        var body = try e.call(g.utf8, &.{ input, next, end });
        var i: u64 = width - 1;
        while (i != 0) : (i -= 1) {
            const octet = try g.byte(input, try e.binary(.integer_add, at, try e.b.constant(u64, i)));
            body = try g.within(octet, if (i == 1) low_second else try e.b.constant(u64, 128), if (i == 1) high_second else try e.b.constant(u64, 191), body);
        }
        return e.when(try e.binary(.less, end, next), try e.fail(), body);
    }
};

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.analysis_values/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const bytes = try b.schema(.bytes);
    const ids = try projection.schema([]const Id, b);
    const read_type = try projection.schema(codec.Read, b);
    const trusted_codec = try codec.define(b, m);
    const read = try b.declare(&.{ bytes, e.integer }, read_type, &.{}, &.{});
    const many = try b.declare(&.{ m.program, e.integer, bytes, e.integer, e.integer }, e.integer, &.{}, &.{});
    const d: Definition = .{
        .value = try b.declare(&.{ m.program, e.integer, bytes, e.integer }, e.integer, &.{}, &.{}),
        .fields = try b.declare(&.{ m.program, ids, bytes, e.integer }, e.integer, &.{}, &.{}),
    };
    const g: Generator = .{ .e = e, .utf8 = try b.declare(&.{ bytes, e.integer, e.integer }, e.integer, &.{}, &.{}) };
    {
        const input = try e.param(read, 0);
        const at = try e.param(read, 1);
        const decoded = try b.variable(read_type);
        const value = try b.reference(decoded);
        const canonical = try b.variable(bytes);
        const prefix = try e.slice(input, at, try e.field(value, 1));
        const comparison = try b.primitive(try b.scalar(i8), .blob_compare, &.{ prefix, try b.reference(canonical) }, 0);
        // The codec's checked arithmetic rejects overflow/truncation. Comparing
        // with the unique encoder also rejects every overlong natural.
        try b.define(read, try b.bind(decoded, try e.call(trusted_codec.read, &.{ input, at }), try b.bind(canonical, try e.call(trusted_codec.natural, &.{try e.field(value, 0)}), try e.when(try e.binary(.equal, comparison, try b.constant(i8, 0)), try b.pure(value), try e.fail()))));
    }
    {
        const input = try e.param(g.utf8, 0);
        const at = try e.param(g.utf8, 1);
        const end = try e.param(g.utf8, 2);
        const octet = try g.byte(input, at);
        const low = try b.constant(u64, 128);
        const high = try b.constant(u64, 191);
        const two = try g.utf8Sequence(input, at, end, 2, low, high);
        const three = try e.when(try e.binary(.equal, octet, try b.constant(u64, 224)), try g.utf8Sequence(input, at, end, 3, try b.constant(u64, 160), high), try e.when(try e.binary(.equal, octet, try b.constant(u64, 237)), try g.utf8Sequence(input, at, end, 3, low, try b.constant(u64, 159)), try g.utf8Sequence(input, at, end, 3, low, high)));
        const four = try e.when(try e.binary(.equal, octet, try b.constant(u64, 240)), try g.utf8Sequence(input, at, end, 4, try b.constant(u64, 144), high), try e.when(try e.binary(.equal, octet, try b.constant(u64, 244)), try g.utf8Sequence(input, at, end, 4, low, try b.constant(u64, 143)), try g.utf8Sequence(input, at, end, 4, low, high)));
        const ascii = try e.call(g.utf8, &.{ input, try e.binary(.integer_add, at, e.one), end });
        const nonempty = try e.when(try e.binary(.less, octet, low), ascii, try e.when(try e.binary(.less, octet, try b.constant(u64, 194)), try e.fail(), try e.when(try e.binary(.less, octet, try b.constant(u64, 224)), two, try e.when(try e.binary(.less, octet, try b.constant(u64, 240)), three, try e.when(try e.binary(.less, octet, try b.constant(u64, 245)), four, try e.fail())))));
        try b.define(g.utf8, try e.when(try e.binary(.less, end, at), try e.fail(), try e.when(try e.binary(.equal, at, end), try b.pure(end), nonempty)));
    }
    {
        const program = try e.param(many, 0);
        const schema = try e.param(many, 1);
        const input = try e.param(many, 2);
        const offset = try e.param(many, 3);
        const count = try e.param(many, 4);
        const minimum = try e.required(try edges.field(e, try edges.field(e, program, projection.Program, "schemas"), data.admission.SchemaFacts, "minimum"), schema);
        const length = try b.primitive(e.integer, .blob_length, &.{input}, 0);
        const remaining = try e.binary(.integer_sub, length, offset);
        const next = try b.variable(e.integer);
        const more = try b.bind(next, try e.call(d.value, &.{ program, schema, input, offset }), try e.call(many, &.{ program, schema, input, try b.reference(next), try e.binary(.integer_sub, count, e.one) }));
        const bounded = try e.when(try e.binary(.less, try e.binary(.integer_div, remaining, minimum), count), try e.fail(), more);
        // Zero-width values require no iteration, even for a u64-sized sequence.
        const body = try e.when(try e.binary(.equal, count, e.zero), try b.pure(offset), try e.when(try e.binary(.equal, minimum, e.zero), try b.pure(offset), bounded));
        try b.define(many, try e.when(try e.binary(.less, length, offset), try e.fail(), body));
    }
    {
        const program = try e.param(d.fields, 0);
        const types = try e.param(d.fields, 1);
        const input = try e.param(d.fields, 2);
        const offset = try e.param(d.fields, 3);
        const parts = try b.schema(.{ .product = &.{ e.integer, ids } });
        const popped = try b.schema(.{ .sum = &.{ e.unit, parts } });
        const nil = try b.variable(e.unit);
        const pair_var = try b.variable(parts);
        const pair = try b.reference(pair_var);
        const next = try b.variable(e.integer);
        try b.define(d.fields, try b.term(.{ .match_sum = .{ .value = try b.primitive(popped, .sequence_pop, &.{types}, 0), .cases = &.{
            .{ .variable = nil, .body = try b.pure(offset) },
            .{ .variable = pair_var, .body = try b.bind(next, try e.call(d.value, &.{ program, try e.field(pair, 0), input, offset }), try e.call(d.fields, &.{ program, try e.field(pair, 1), input, try b.reference(next) })) },
        } } }));
    }
    {
        const program = try e.param(d.value, 0);
        const schema = try e.param(d.value, 1);
        const input = try e.param(d.value, 2);
        const offset = try e.param(d.value, 3);
        const length = try b.primitive(e.integer, .blob_length, &.{input}, 0);
        const facts = try edges.field(e, program, projection.Program, "schemas");
        const exportable = try e.required(try edges.field(e, facts, data.admission.SchemaFacts, "exportable"), schema);
        const minimum = try e.required(try edges.field(e, facts, data.admission.SchemaFacts, "minimum"), schema);
        const schemas = try edges.field(e, try edges.code(e, program), data.activation.Program, "schemas");
        const descriptor = try projection.schema(data.program.Schema, b);
        const variants = b.schemas.items[@intCast(descriptor)].sum;
        const names = @typeInfo(data.program.Schema).@"union".field_names;
        const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
        var cases: [names.len]Case = undefined;
        inline for (names, 0..) |name, i| {
            const variable = try b.variable(variants[i]);
            const shape = try b.reference(variable);
            const tag: data.program.SchemaTag = @field(data.program.SchemaTag, name);
            const count = try b.variable(read_type);
            const decoded = try b.reference(count);
            const n = try e.field(decoded, 0);
            const after_count = try e.field(decoded, 1);
            const fixed_end = try e.binary(.integer_add, offset, minimum);
            const fixed = try e.when(try e.binary(.less, length, fixed_end), try e.fail(), try b.pure(fixed_end));
            const body = switch (tag) {
                .unit, .u8, .i8, .u16, .i16, .u32, .i32, .u64, .i64 => fixed,
                .boolean => try e.when(try e.binary(.less, e.one, try g.byte(input, offset)), try e.fail(), fixed),
                .enumeration => blk: {
                    const tags_type = try projection.schema([]const u32, b);
                    const contains = try b.declare(&.{ tags_type, e.integer, e.integer }, e.boolean, &.{}, &.{});
                    const tags = try e.param(contains, 0);
                    const wanted = try e.param(contains, 1);
                    const at = try e.param(contains, 2);
                    const found = try e.binary(.equal, try e.convert(try e.required(tags, at), e.integer, false), wanted);
                    try b.define(contains, try e.when(try e.binary(.less, at, try b.primitive(e.integer, .sequence_length, &.{tags}, 0)), try e.when(found, try b.pure(try b.constant(bool, true)), try e.call(contains, &.{ tags, wanted, try e.binary(.integer_add, at, e.one) })), try b.pure(try b.constant(bool, false))));
                    var number = e.zero;
                    for (0..4) |j| number = try e.binary(.integer_add, number, try e.binary(.integer_mul, try g.byte(input, try e.binary(.integer_add, offset, try b.constant(u64, j))), try b.constant(u64, @as(u64, 1) << @intCast(j * 8))));
                    const valid = try b.variable(e.boolean);
                    break :blk try b.bind(valid, try e.call(contains, &.{ shape, number, e.zero }), try e.when(try b.reference(valid), fixed, try e.fail()));
                },
                .bytes, .text, .bounded_bytes, .bounded_text => blk: {
                    const end = try e.binary(.integer_add, after_count, n);
                    var valid = if (tag == .text or tag == .bounded_text) try e.call(g.utf8, &.{ input, after_count, end }) else try b.pure(end);
                    if (tag == .bounded_bytes or tag == .bounded_text) valid = try e.when(try e.binary(.less, shape, n), try e.fail(), valid);
                    break :blk try b.bind(count, try e.call(read, &.{ input, offset }), try e.when(try e.binary(.less, length, end), try e.fail(), valid));
                },
                .product => try e.call(d.fields, &.{ program, shape, input, offset }),
                .sum => try b.bind(count, try e.call(read, &.{ input, offset }), try e.call(d.value, &.{ program, try e.required(shape, n), input, after_count })),
                .seq, .vector => blk: {
                    const body = try e.call(many, &.{ program, if (tag == .seq) shape else try e.field(shape, 0), input, after_count, n });
                    break :blk try b.bind(count, try e.call(read, &.{ input, offset }), if (tag == .vector) try e.when(try e.binary(.less, try e.field(shape, 1), n), try e.fail(), body) else body);
                },
                .array => try e.call(many, &.{ program, try e.field(shape, 0), input, offset, try e.field(shape, 1) }),
                .internal => try e.fail(),
            };
            cases[i] = .{ .variable = variable, .body = body };
        }
        const inspect = try b.term(.{ .match_sum = .{ .value = try e.required(schemas, schema), .cases = &cases } });
        const body = try e.when(try e.binary(.equal, minimum, e.zero), try b.pure(offset), inspect);
        try b.define(d.value, try e.when(exportable, try e.when(try e.binary(.less, length, offset), try e.fail(), body), try e.fail()));
    }
    return cache.finish(b, d);
}
