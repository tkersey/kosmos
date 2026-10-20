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
        return g.e.convert(try g.e.payload(try g.e.b.primitive(
            optional,
            .blob_byte,
            &.{ input, offset },
            0,
        ), 1), g.e.integer, false);
    }

    fn within(g: Generator, value: Id, low: Id, high: Id, body: Id) Error!Id {
        return g.e.when(try g.e.binary(.less, value, low), try g.e.fail(), try g.e.when(
            try g.e.binary(.less, high, value),
            try g.e.fail(),
            body,
        ));
    }

    fn utf8Sequence(
        g: Generator,
        input: Id,
        at: Id,
        end: Id,
        comptime width: u64,
        low_second: Id,
        high_second: Id,
    ) Error!Id {
        const e = g.e;
        const next = try e.binary(.integer_add, at, try e.b.constant(u64, width));
        var body = try e.call(g.utf8, &.{ input, next, end });
        var i: u64 = width - 1;
        while (i != 0) : (i -= 1) {
            const octet = try g.byte(input, try e.binary(
                .integer_add,
                at,
                try e.b.constant(u64, i),
            ));
            body = try g.within(
                octet,
                if (i == 1) low_second else try e.b.constant(u64, 128),
                if (i == 1) high_second else try e.b.constant(u64, 191),
                body,
            );
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
    const many = try b.declare(&.{
        m.program, e.integer, bytes, e.integer, e.integer,
    }, e.integer, &.{}, &.{});
    const d: Definition = .{
        .value = try b.declare(&.{ m.program, e.integer, bytes, e.integer }, e.integer, &.{}, &.{}),
        .fields = try b.declare(&.{ m.program, ids, bytes, e.integer }, e.integer, &.{}, &.{}),
    };
    const g: Generator = .{ .e = e, .utf8 = try b.declare(
        &.{ bytes, e.integer, e.integer },
        e.integer,
        &.{},
        &.{},
    ) };
    try emitRead(e, bytes, read_type, trusted_codec, read);
    try emitG(e, g);
    try emitMany(e, many, d);
    try emitFields(e, ids, d);
    try emitValue(e, read_type, read, many, d, g);
    return cache.finish(b, d);
}

fn emitRead(
    e: Author,
    bytes: Id,
    read_type: Id,
    trusted_codec: codec.Definition,
    read: Id,
) Error!void {
    const input = try e.param(read, 0);
    const at = try e.param(read, 1);
    const decoded = try e.b.variable(read_type);
    const value = try e.b.reference(decoded);
    const canonical = try e.b.variable(bytes);
    const prefix = try e.slice(input, at, try e.field(value, 1));
    const comparison = try e.b.primitive(try e.b.scalar(i8), .blob_compare, &.{
        prefix, try e.b.reference(canonical),
    }, 0);
    // The codec's checked arithmetic rejects overflow/truncation. Comparing
    // with the unique encoder also rejects every overlong natural.
    try e.b.define(read, try e.b.bind(decoded, try e.call(
        trusted_codec.read,
        &.{ input, at },
    ), try e.b.bind(canonical, try e.call(
        trusted_codec.natural,
        &.{try e.field(value, 0)},
    ), try e.when(try e.binary(
        .equal,
        comparison,
        try e.b.constant(i8, 0),
    ), try e.b.pure(value), try e.fail()))));
}

fn emitG(e: Author, g: Generator) Error!void {
    const input = try e.param(g.utf8, 0);
    const at = try e.param(g.utf8, 1);
    const end = try e.param(g.utf8, 2);
    const octet = try g.byte(input, at);
    const low = try e.b.constant(u64, 128);
    const high = try e.b.constant(u64, 191);
    const two = try g.utf8Sequence(input, at, end, 2, low, high);
    const three = try emitGThree(e, g, input, at, end, octet, low, high);
    const four = try emitGFour(e, g, input, at, end, octet, low, high);
    const ascii = try e.call(g.utf8, &.{ input, try e.binary(.integer_add, at, e.one), end });
    const nonempty = try emitGNonempty(e, octet, low, two, three, four, ascii);
    try e.b.define(g.utf8, try e.when(try e.binary(.less, end, at), try e.fail(), try e.when(
        try e.binary(.equal, at, end),
        try e.b.pure(end),
        nonempty,
    )));
}

fn emitMany(e: Author, many: Id, d: Definition) Error!void {
    const program = try e.param(many, 0);
    const schema = try e.param(many, 1);
    const input = try e.param(many, 2);
    const offset = try e.param(many, 3);
    const count = try e.param(many, 4);
    const minimum = try e.required(try edges.field(e, try edges.field(
        e,
        program,
        projection.Program,
        "schemas",
    ), data.admission.SchemaFacts, "minimum"), schema);
    const length = try e.b.primitive(e.integer, .blob_length, &.{input}, 0);
    const remaining = try e.binary(.integer_sub, length, offset);
    const next = try e.b.variable(e.integer);
    const more = try e.b.bind(next, try e.call(
        d.value,
        &.{ program, schema, input, offset },
    ), try e.call(many, &.{
        program, schema, input, try e.b.reference(next), try e.binary(.integer_sub, count, e.one),
    }));
    const bounded = try e.when(try e.binary(
        .less,
        try e.binary(.integer_div, remaining, minimum),
        count,
    ), try e.fail(), more);
    // Zero-width values require no iteration, even for a u64-sized sequence.
    const body = try e.when(try e.binary(.equal, count, e.zero), try e.b.pure(offset), try e.when(
        try e.binary(.equal, minimum, e.zero),
        try e.b.pure(offset),
        bounded,
    ));
    try e.b.define(many, try e.when(try e.binary(.less, length, offset), try e.fail(), body));
}

fn emitFields(e: Author, ids: Id, d: Definition) Error!void {
    const program = try e.param(d.fields, 0);
    const types = try e.param(d.fields, 1);
    const input = try e.param(d.fields, 2);
    const offset = try e.param(d.fields, 3);
    const parts = try e.b.schema(.{ .product = &.{ e.integer, ids } });
    const popped = try e.b.schema(.{ .sum = &.{ e.unit, parts } });
    const nil = try e.b.variable(e.unit);
    const pair_var = try e.b.variable(parts);
    const pair = try e.b.reference(pair_var);
    const next = try e.b.variable(e.integer);
    try e.b.define(d.fields, try e.b.term(.{ .match_sum = .{ .value = try e.b.primitive(
        popped,
        .sequence_pop,
        &.{types},
        0,
    ), .cases = &.{
        .{ .variable = nil, .body = try e.b.pure(offset) },
        .{ .variable = pair_var, .body = try e.b.bind(next, try e.call(d.value, &.{
            program, try e.field(pair, 0), input, offset,
        }), try e.call(d.fields, &.{
            program, try e.field(pair, 1), input, try e.b.reference(next),
        })) },
    } } }));
}

fn emitGThree(
    e: Author,
    g: Generator,
    input: Id,
    at: Id,
    end: Id,
    octet: anytype,
    low: Id,
    high: Id,
) Error!Id {
    return try e.when(try e.binary(
        .equal,
        octet,
        try e.b.constant(u64, 224),
    ), try g.utf8Sequence(
        input,
        at,
        end,
        3,
        try e.b.constant(u64, 160),
        high,
    ), try e.when(try e.binary(
        .equal,
        octet,
        try e.b.constant(u64, 237),
    ), try g.utf8Sequence(
        input,
        at,
        end,
        3,
        low,
        try e.b.constant(u64, 159),
    ), try g.utf8Sequence(input, at, end, 3, low, high)));
}

fn emitGFour(
    e: Author,
    g: Generator,
    input: Id,
    at: Id,
    end: Id,
    octet: anytype,
    low: Id,
    high: Id,
) Error!Id {
    return try e.when(try e.binary(
        .equal,
        octet,
        try e.b.constant(u64, 240),
    ), try g.utf8Sequence(
        input,
        at,
        end,
        4,
        try e.b.constant(u64, 144),
        high,
    ), try e.when(try e.binary(
        .equal,
        octet,
        try e.b.constant(u64, 244),
    ), try g.utf8Sequence(
        input,
        at,
        end,
        4,
        low,
        try e.b.constant(u64, 143),
    ), try g.utf8Sequence(input, at, end, 4, low, high)));
}

fn emitGNonempty(
    e: Author,
    octet: anytype,
    low: Id,
    two: anytype,
    three: Id,
    four: Id,
    ascii: Id,
) Error!Id {
    return try e.when(try e.binary(.less, octet, low), ascii, try e.when(try e.binary(
        .less,
        octet,
        try e.b.constant(u64, 194),
    ), try e.fail(), try e.when(try e.binary(
        .less,
        octet,
        try e.b.constant(u64, 224),
    ), two, try e.when(try e.binary(
        .less,
        octet,
        try e.b.constant(u64, 240),
    ), three, try e.when(try e.binary(
        .less,
        octet,
        try e.b.constant(u64, 245),
    ), four, try e.fail())))));
}

fn defineContainsDefinition(
    e: Author,
    contains: Id,
    tags: Id,
    wanted: Id,
    at: Id,
    found: Id,
) Error!void {
    try e.b.define(contains, try e.when(try e.binary(.less, at, try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{tags},
        0,
    )), try e.when(
        found,
        try e.b.pure(try e.b.constant(
            bool,
            true,
        )),
        try e.call(contains, &.{ tags, wanted, try e.binary(.integer_add, at, e.one) }),
    ), try e.b.pure(try e.b.constant(bool, false))));
}

fn defineNumber(
    e: Author,
    g: anytype,
    input: Id,
    offset: Id,
    number: anytype,
    j: anytype,
) Error!Id {
    return try e.binary(
        .integer_add,
        number,
        try e.binary(
            .integer_mul,
            try g.byte(input, try e.binary(.integer_add, offset, try e.b.constant(u64, j))),
            try e.b.constant(u64, @as(u64, 1) << @intCast(j * 8)),
        ),
    );
}

fn emitValue(e: Author, read_type: Id, read: Id, many: Id, d: Definition, g: Generator) Error!void {
    const program = try e.param(d.value, 0);
    const schema = try e.param(d.value, 1);
    const input = try e.param(d.value, 2);
    const offset = try e.param(d.value, 3);
    const length = try e.b.primitive(e.integer, .blob_length, &.{input}, 0);
    const facts = try edges.field(e, program, projection.Program, "schemas");
    const exportable = try e.required(try edges.field(
        e,
        facts,
        data.admission.SchemaFacts,
        "exportable",
    ), schema);
    const minimum = try e.required(try edges.field(
        e,
        facts,
        data.admission.SchemaFacts,
        "minimum",
    ), schema);
    const schemas = try edges.field(
        e,
        try edges.code(e, program),
        data.activation.Program,
        "schemas",
    );
    const descriptor = try projection.schema(data.program.Schema, e.b);
    const variants = e.b.schemas.items[@intCast(descriptor)].sum;
    const names = @typeInfo(data.program.Schema).@"union".field_names;
    const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
    var cases: [names.len]Case = undefined;
    inline for (names, 0..) |name, i| {
        const variable = try e.b.variable(variants[i]);
        const shape = try e.b.reference(variable);
        const tag: data.program.SchemaTag = @field(data.program.SchemaTag, name);
        const body = try emitValueCase(
            e,
            read_type,
            read,
            many,
            d,
            g,
            program,
            input,
            offset,
            length,
            minimum,
            shape,
            tag,
        );
        cases[i] = .{ .variable = variable, .body = body };
    }
    const inspect = try e.b.term(.{ .match_sum = .{
        .value = try e.required(schemas, schema),
        .cases = &cases,
    } });
    const body = try e.when(try e.binary(.equal, minimum, e.zero), try e.b.pure(offset), inspect);
    try e.b.define(d.value, try e.when(exportable, try e.when(
        try e.binary(.less, length, offset),
        try e.fail(),
        body,
    ), try e.fail()));
}

fn emitValueEnumeration(
    e: Author,
    g: Generator,
    input: Id,
    offset: Id,
    shape: Id,
    fixed: Id,
) Error!Id {
    const tags_type = try projection.schema([]const u32, e.b);
    const contains = try e.b.declare(
        &.{ tags_type, e.integer, e.integer },
        e.boolean,
        &.{},
        &.{},
    );
    const tags = try e.param(contains, 0);
    const wanted = try e.param(contains, 1);
    const at = try e.param(contains, 2);
    const found = try e.binary(.equal, try e.convert(
        try e.required(tags, at),
        e.integer,
        false,
    ), wanted);
    try defineContainsDefinition(e, contains, tags, wanted, at, found);
    var number = e.zero;
    for (0..4) |j| number = try defineNumber(e, g, input, offset, number, j);
    const valid = try e.b.variable(e.boolean);
    return try e.b.bind(valid, try e.call(
        contains,
        &.{ shape, number, e.zero },
    ), try e.when(try e.b.reference(valid), fixed, try e.fail()));
}

fn emitValueBytes(
    e: Author,
    read: Id,
    g: Generator,
    input: Id,
    offset: Id,
    length: Id,
    shape: Id,
    comptime tag: anytype,
    count: Id,
    n: Id,
    after_count: Id,
) Error!Id {
    const end = try e.binary(.integer_add, after_count, n);
    var valid = if (tag == .text or tag == .bounded_text) try e.call(
        g.utf8,
        &.{ input, after_count, end },
    ) else try e.b.pure(end);
    if (tag == .bounded_bytes or tag == .bounded_text) valid = try e.when(
        try e.binary(.less, shape, n),
        try e.fail(),
        valid,
    );
    return try e.b.bind(count, try e.call(read, &.{ input, offset }), try e.when(
        try e.binary(.less, length, end),
        try e.fail(),
        valid,
    ));
}

fn emitValueSeq(
    e: Author,
    read: Id,
    many: Id,
    program: Id,
    input: Id,
    offset: Id,
    shape: Id,
    comptime tag: anytype,
    count: Id,
    n: Id,
    after_count: Id,
) Error!Id {
    const body = try e.call(many, &.{
        program,
        if (tag == .seq) shape else try e.field(shape, 0),
        input,
        after_count,
        n,
    });
    return try e.b.bind(
        count,
        try e.call(read, &.{
            input,
            offset,
        }),
        if (tag == .vector) try e.when(
            try e.binary(.less, try e.field(shape, 1), n),
            try e.fail(),
            body,
        ) else body,
    );
}

fn emitValueCase(
    e: Author,
    read_type: Id,
    read: Id,
    many: Id,
    d: Definition,
    g: Generator,
    program: Id,
    input: Id,
    offset: Id,
    length: Id,
    minimum: Id,
    shape: Id,
    comptime tag: data.program.SchemaTag,
) Error!Id {
    const count = try e.b.variable(read_type);
    const decoded = try e.b.reference(count);
    const n = try e.field(decoded, 0);
    const after_count = try e.field(decoded, 1);
    const fixed_end = try e.binary(.integer_add, offset, minimum);
    const fixed = try e.when(
        try e.binary(.less, length, fixed_end),
        try e.fail(),
        try e.b.pure(fixed_end),
    );
    return switch (tag) {
        .unit, .u8, .i8, .u16, .i16, .u32, .i32, .u64, .i64 => fixed,
        .boolean => try e.when(try e.binary(
            .less,
            e.one,
            try g.byte(input, offset),
        ), try e.fail(), fixed),
        .enumeration => try emitValueEnumeration(e, g, input, offset, shape, fixed),
        .bytes, .text, .bounded_bytes, .bounded_text => try emitValueBytes(
            e,
            read,
            g,
            input,
            offset,
            length,
            shape,
            tag,
            count,
            n,
            after_count,
        ),
        .product => try e.call(d.fields, &.{ program, shape, input, offset }),
        .sum => try e.b.bind(count, try e.call(read, &.{ input, offset }), try e.call(
            d.value,
            &.{ program, try e.required(shape, n), input, after_count },
        )),
        .seq, .vector => try emitValueSeq(
            e,
            read,
            many,
            program,
            input,
            offset,
            shape,
            tag,
            count,
            n,
            after_count,
        ),
        .array => try e.call(many, &.{
            program, try e.field(shape, 0), input, offset, try e.field(shape, 1),
        }),
        .internal => try e.fail(),
    };
}
