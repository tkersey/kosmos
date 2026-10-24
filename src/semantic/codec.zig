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
pub const Definition = struct {
    read: Id,
    natural: Id,
    skip: Id,
    skip_many: Id,
    skip_fields: Id,
    fixed: Id,
    fixed_bytes: Id,
};

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
        .skip_many = try b.declare(&.{
            m.program, e.integer, bytes, e.integer, e.integer,
        }, e.integer, &.{}, &.{}),
        .skip_fields = try b.declare(&.{ m.program, ids, bytes, e.integer }, e.integer, &.{}, &.{}),
        .fixed = try b.declare(&.{fixed_bytes}, e.integer, &.{}, &.{}),
        .fixed_bytes = try b.declare(&.{e.integer}, fixed_bytes, &.{}, &.{}),
    };
    const byte = try b.scalar(u8);
    const optional_byte = try b.schema(.{ .sum = &.{ e.unit, byte } });
    const base = try b.constant(u64, 128);
    try emitLoop(e, bytes, read, d, optional_byte, base);
    try emitLoopBody(e, bytes, d, byte, base);
    try emitFixed(e, fixed_bytes, d, byte);
    const skip_shape = try emitSkip(e, read, d);
    try emitSkipMany(e, d, skip_shape);
    try emitSkipFields(e, ids, d);
    return cache.finish(b, d);
}

fn emitLoop(e: Author, bytes: Id, read: Id, d: Definition, optional_byte: Id, base: Id) Error!void {
    const loop = try e.b.declare(&.{ bytes, e.integer, e.integer, e.integer }, read, &.{}, &.{});
    const input = try e.param(loop, 0);
    const position = try e.param(loop, 1);
    const accumulated = try e.param(loop, 2);
    const multiplier = try e.param(loop, 3);
    const octet = try e.convert(try e.payload(try e.b.primitive(
        optional_byte,
        .blob_byte,
        &.{ input, position },
        0,
    ), 1), e.integer, false);
    const low = try e.binary(.integer_rem, octet, base);
    const combined = try e.binary(
        .integer_add,
        accumulated,
        try e.binary(.integer_mul, low, multiplier),
    );
    const next = try e.binary(.integer_add, position, e.one);
    try e.b.define(loop, try e.when(try e.binary(.less, octet, base), try e.b.pure(
        try e.tuple(read, &.{ combined, next }),
    ), try e.call(loop, &.{
        input, next, combined, try e.binary(.integer_mul, multiplier, base),
    })));
    try e.b.define(d.read, try e.call(loop, &.{
        try e.param(d.read, 0), try e.param(d.read, 1), e.zero, e.one,
    }));
}

fn emitLoopBody(e: Author, bytes: Id, d: Definition, byte: Id, base: Id) Error!void {
    const loop = try e.b.declare(&.{ e.integer, bytes }, bytes, &.{}, &.{});
    const input = try e.param(loop, 0);
    const prior = try e.param(loop, 1);
    const remaining = try e.binary(.integer_div, input, base);
    const low = try e.binary(.integer_rem, input, base);
    const final_byte = try e.b.primitive(
        bytes,
        .blob_from_byte,
        &.{try e.convert(low, byte, true)},
        0,
    );
    const continuation = try e.b.primitive(bytes, .blob_from_byte, &.{try e.convert(
        try e.binary(.integer_add, low, base),
        byte,
        true,
    )}, 0);
    try e.b.define(
        loop,
        try e.when(
            try e.binary(.equal, remaining, e.zero),
            try e.b.pure(try e.concat(
                prior,
                final_byte,
            )),
            try e.call(loop, &.{
                remaining,
                try e.concat(prior, continuation),
            }),
        ),
    );
    try e.b.define(d.natural, try e.call(loop, &.{
        try e.param(d.natural, 0), try e.literal([]const u8, &.{}),
    }));
}

fn emitFixed(e: Author, fixed_bytes: Id, d: Definition, byte: Id) Error!void {
    var decoded = e.zero;
    var encoded: [8]Id = undefined;
    const input_bytes = try e.param(d.fixed, 0);
    const input = try e.param(d.fixed_bytes, 0);
    for (0..8) |i| {
        const divisor = try e.b.constant(u64, @as(u64, 1) << @intCast(i * 8));
        const octet = try e.convert(try e.required(
            input_bytes,
            try e.b.constant(u64, i),
        ), e.integer, false);
        decoded = try e.binary(
            .integer_add,
            decoded,
            try e.binary(.integer_mul, octet, divisor),
        );
        encoded[i] = try e.convert(try e.binary(
            .integer_rem,
            try e.binary(.integer_div, input, divisor),
            try e.b.constant(u64, 256),
        ), byte, true);
    }
    try e.b.define(d.fixed, try e.b.pure(decoded));
    try e.b.define(d.fixed_bytes, try e.b.pure(try e.b.primitive(
        fixed_bytes,
        .sequence,
        &encoded,
        0,
    )));
}

fn emitSkipMany(e: Author, d: Definition, skip_shape: Id) Error!void {
    const program = try e.param(d.skip_many, 0);
    const schema = try e.param(d.skip_many, 1);
    const input = try e.param(d.skip_many, 2);
    const offset = try e.param(d.skip_many, 3);
    const count = try e.param(d.skip_many, 4);
    const minimum = try e.required(try access.field(e, try access.field(
        e,
        program,
        projection.Program,
        "schemas",
    ), data.admission.SchemaFacts, "minimum"), schema);
    const descriptor = try projection.schema(data.program.Schema, e.b);
    const loop = try e.b.declare(&.{
        e.b.values.items[@intCast(program)].schema, descriptor,
        try e.b.schema(.bytes),                     e.integer,
        e.integer,
    }, e.integer, &.{}, &.{});
    try emitSkipManyLoop(e, loop, skip_shape);
    const schemas = try access.field(
        e,
        try access.code(e, program),
        data.activation.Program,
        "schemas",
    );
    const selected = try e.b.variable(descriptor);
    const shape = try e.b.reference(selected);
    const variants = e.b.schemas.items[@intCast(descriptor)].sum;
    const names = @typeInfo(data.program.Schema).@"union".field_names;
    const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
    var cases: [names.len]Case = undefined;
    const variable = try e.call(loop, &.{ program, shape, input, offset, count });
    inline for (names, 0..) |name, i| {
        const tag: data.program.SchemaTag = @field(data.program.SchemaTag, name);
        cases[i] = .{
            .variable = try e.b.variable(variants[i]),
            .body = if (scalarWidth(tag)) |width| try e.b.pure(try e.binary(
                .integer_add,
                offset,
                try e.binary(.integer_mul, count, try e.b.constant(u64, width)),
            )) else variable,
        };
    }
    const dispatched = try e.b.bind(
        selected,
        try e.b.pure(try e.required(schemas, schema)),
        try e.b.term(.{ .match_sum = .{ .value = shape, .cases = &cases } }),
    );
    const done = try e.b.pure(offset);
    try e.b.define(d.skip_many, try e.when(try e.binary(.equal, count, e.zero), done, try e.when(
        try e.binary(.equal, minimum, e.zero),
        done,
        dispatched,
    )));
}

fn emitSkipManyLoop(e: Author, loop: Id, skip_shape: Id) Error!void {
    const loop_program = try e.param(loop, 0);
    const loop_shape = try e.param(loop, 1);
    const loop_input = try e.param(loop, 2);
    const loop_offset = try e.param(loop, 3);
    const loop_count = try e.param(loop, 4);
    const next = try e.b.variable(e.integer);
    const more = try e.b.bind(next, try e.call(skip_shape, &.{
        loop_program, loop_shape, loop_input, loop_offset,
    }), try e.call(loop, &.{
        loop_program,
        loop_shape,
        loop_input,
        try e.b.reference(next),
        try e.binary(.integer_sub, loop_count, e.one),
    }));
    try e.b.define(loop, try e.when(
        try e.binary(.equal, loop_count, e.zero),
        try e.b.pure(loop_offset),
        more,
    ));
}

fn emitSkipFields(e: Author, ids: Id, d: Definition) Error!void {
    const program = try e.param(d.skip_fields, 0);
    const types = try e.param(d.skip_fields, 1);
    const input = try e.param(d.skip_fields, 2);
    const offset = try e.param(d.skip_fields, 3);
    const parts = try e.b.schema(.{ .product = &.{ e.integer, ids } });
    const popped = try e.b.schema(.{ .sum = &.{ e.unit, parts } });
    const nil = try e.b.variable(e.unit);
    const pair_var = try e.b.variable(parts);
    const pair = try e.b.reference(pair_var);
    const next = try e.b.variable(e.integer);
    try e.b.define(d.skip_fields, try e.b.term(.{ .match_sum = .{ .value = try e.b.primitive(
        popped,
        .sequence_pop,
        &.{types},
        0,
    ), .cases = &.{
        .{ .variable = nil, .body = try e.b.pure(offset) },
        .{ .variable = pair_var, .body = try e.b.bind(next, try e.call(d.skip, &.{
            program, try e.field(pair, 0), input, offset,
        }), try e.call(d.skip_fields, &.{
            program, try e.field(pair, 1), input, try e.b.reference(next),
        })) },
    } } }));
}

fn emitSkip(e: Author, read: Id, d: Definition) Error!Id {
    const program = try e.param(d.skip, 0);
    const schema = try e.param(d.skip, 1);
    const input = try e.param(d.skip, 2);
    const offset = try e.param(d.skip, 3);
    const schemas = try access.field(
        e,
        try access.code(e, program),
        data.activation.Program,
        "schemas",
    );
    const descriptor = try projection.schema(data.program.Schema, e.b);
    const skip_shape = try e.b.declare(&.{
        e.b.values.items[@intCast(program)].schema, descriptor,
        try e.b.schema(.bytes),                     e.integer,
    }, e.integer, &.{}, &.{});
    const shape_program = try e.param(skip_shape, 0);
    const selected = try e.param(skip_shape, 1);
    const shape_input = try e.param(skip_shape, 2);
    const shape_offset = try e.param(skip_shape, 3);
    const variants = e.b.schemas.items[@intCast(descriptor)].sum;
    const names = @typeInfo(data.program.Schema).@"union".field_names;
    const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
    var cases: [names.len]Case = undefined;
    inline for (names, 0..) |name, i| {
        const variable = try e.b.variable(variants[i]);
        const shape = try e.b.reference(variable);
        const tag: data.program.SchemaTag = @field(data.program.SchemaTag, name);
        const body = try emitSkipShape(
            e,
            read,
            d,
            shape_program,
            shape_input,
            shape_offset,
            shape,
            tag,
        );
        cases[i] = .{ .variable = variable, .body = body };
    }
    try e.b.define(skip_shape, try e.b.term(.{ .match_sum = .{
        .value = selected,
        .cases = &cases,
    } }));
    try e.b.define(d.skip, try e.call(skip_shape, &.{
        program, try e.required(schemas, schema), input, offset,
    }));
    return skip_shape;
}

fn scalarWidth(comptime tag: data.program.SchemaTag) ?u64 {
    return switch (tag) {
        .unit => 0,
        .boolean, .u8, .i8 => 1,
        .u16, .i16 => 2,
        .u32, .i32, .enumeration => 4,
        .u64, .i64 => 8,
        else => null,
    };
}

fn emitSkipShape(
    e: Author,
    read: Id,
    d: Definition,
    program: Id,
    input: Id,
    offset: Id,
    shape: Id,
    comptime tag: data.program.SchemaTag,
) Error!Id {
    const width = scalarWidth(tag);
    const count = try e.b.variable(read);
    const decoded = try e.b.reference(count);
    return if (width) |n| try e.b.pure(try e.binary(
        .integer_add,
        offset,
        try e.b.constant(u64, n),
    )) else switch (tag) {
        .bytes, .text, .bounded_bytes, .bounded_text => try e.b.bind(
            count,
            try e.call(d.read, &.{ input, offset }),
            try e.b.pure(try e.binary(
                .integer_add,
                try e.field(decoded, 1),
                try e.field(decoded, 0),
            )),
        ),
        .product => try e.call(d.skip_fields, &.{ program, shape, input, offset }),
        .sum => try e.b.bind(count, try e.call(d.read, &.{ input, offset }), try e.call(d.skip, &.{
            program, try e.required(shape, try e.field(decoded, 0)),
            input,   try e.field(decoded, 1),
        })),
        .seq, .vector => try e.b.bind(
            count,
            try e.call(d.read, &.{ input, offset }),
            try e.call(d.skip_many, &.{
                program,                 if (tag == .seq) shape else try e.field(shape, 0),
                input,                   try e.field(decoded, 1),
                try e.field(decoded, 0),
            }),
        ),
        .array => try e.call(d.skip_many, &.{
            program, try e.field(shape, 0), input, offset, try e.field(shape, 1),
        }),
        else => try e.fail(),
    };
}
