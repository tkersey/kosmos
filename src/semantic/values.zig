//! Guest value construction in Horos. Guest scalar bytes and blob IDs remain
//! explicit data. Canonical publication interns equal blobs; live node identity
//! is never inferred from value equality.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
pub const Outcome = union(enum) {
    value: data.graph.Value,
    fault: data.program.Fault,
    scalar: @import("frames.zig").Scalar,
};

pub const Definition = struct {
    result: Id,
    value: Id,
    literal: Id,
    width: Id,
    bytes: Id,
    natural: Id,
};

pub fn define(b: *source.Builder, machine: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.values/1", machine.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const value = try projection.schema(data.graph.Value, b);
    const literal = try projection.schema(data.program.Literal, b);
    const result = try b.schema(.{ .product = &.{ machine.schema, value } });
    const descriptor = try projection.schema(data.program.Schema, b);
    const optional_width = try b.schema(.{ .sum = &.{ e.unit, e.integer } });
    const d: Definition = .{
        .result = result,
        .value = value,
        .literal = try b.declare(&.{ machine.schema, literal }, result, &.{}, &.{}),
        .width = try b.declare(&.{descriptor}, optional_width, &.{}, &.{}),
        .bytes = try b.declare(&.{ machine.schema, value }, try b.schema(.bytes), &.{}, &.{}),
        .natural = try b.declare(&.{ e.integer, e.integer }, value, &.{}, &.{}),
    };
    try emitWidth(e, descriptor, optional_width, d);
    const value_body = b.schemas.items[@intCast(value)].product[1];
    const scalar_bytes = try projection.schema([8]u8, b);
    try emitLiteral(e, machine, d, value, result, optional_width, value_body, scalar_bytes);
    const codec = try @import("codec.zig").define(b, machine);
    try emitNatural(e, value, d, value_body, scalar_bytes, codec);
    try emitBytes(machine, e, optional_width, d);
    return cache.finish(b, d);
}

fn emitNatural(
    e: Author,
    value: Id,
    d: Definition,
    value_body: anytype,
    scalar_bytes: Id,
    codec: anytype,
) Error!void {
    const fixed = try e.b.variable(scalar_bytes);
    try e.b.define(d.natural, try e.b.bind(fixed, try e.call(
        codec.fixed_bytes,
        &.{try e.param(d.natural, 1)},
    ), try e.b.pure(try e.tuple(value, &.{ try e.param(d.natural, 0), try e.variant(
        value_body,
        0,
        try e.b.reference(fixed),
    ) }))));
}

fn emitBytes(
    machine: machines.Definition,
    e: Author,
    optional_width: Id,
    d: Definition,
) Error!void {
    const input_state = try e.param(d.bytes, 0);
    const input_value = try e.param(d.bytes, 1);
    const body = try e.field(input_value, 1);
    const tag = try e.b.primitive(e.integer, .variant_tag, &.{body}, 0);
    const scalar = try e.payload(body, 0);
    const blob_bytes = try e.b.schema(.bytes);
    var buffer = try e.literal([]const u8, &.{});
    for (0..8) |i| buffer = try e.concat(
        buffer,
        try e.b.primitive(
            blob_bytes,
            .blob_from_byte,
            &.{try e.required(scalar, try e.b.constant(u64, i))},
            0,
        ),
    );
    const selected_width = try e.b.variable(optional_width);
    const program_code = try @import("edges.zig").code(
        e,
        try machine.field(e, input_state, .program),
    );
    const shapes = try @import("edges.zig").field(
        e,
        program_code,
        data.activation.Program,
        "schemas",
    );
    const scalar_result_bytes = try e.b.bind(
        selected_width,
        try e.call(d.width, &.{
            try e.required(
                shapes,
                try e.field(input_value, 0),
            ),
        }),
        try e.b.pure(try e.slice(
            buffer,
            e.zero,
            try e.payload(try e.b.reference(selected_width), 1),
        )),
    );
    const found = try e.b.variable(machine.blobs.optional);
    const blob_result = try e.b.bind(found, try e.call(machine.blobs.get, &.{
        try machine.field(e, input_state, .blobs), try e.field(try e.payload(body, 1), 0),
    }), try e.b.pure(try e.field(
        try e.payload(try e.b.reference(found), 1),
        1,
    )));
    try e.b.define(d.bytes, try e.when(
        try e.binary(.equal, tag, e.zero),
        scalar_result_bytes,
        blob_result,
    ));
}

fn defineScalarResult(
    e: Author,
    value: Id,
    result: Id,
    input_machine: Id,
    schema: Id,
    value_body: anytype,
    scalar_bytes: Id,
    byte_values: [8]Id,
) Error!Id {
    return try e.b.pure(
        try e.tuple(
            result,
            &.{
                input_machine,
                try e.tuple(
                    value,
                    &.{
                        schema,
                        try e.variant(
                            value_body,
                            0,
                            try e.b.primitive(scalar_bytes, .sequence, &byte_values, 0),
                        ),
                    },
                ),
            },
        ),
    );
}

fn emitWidth(e: Author, descriptor: Id, optional_width: Id, d: Definition) Error!void {
    const types = @typeInfo(data.program.Schema).@"union";
    const variants = e.b.schemas.items[@intCast(descriptor)].sum;
    const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
    var cases: [types.field_names.len]Case = undefined;
    inline for (types.field_names, 0..) |name, i| {
        const width: ?u64 = comptime blk: {
            if (std.mem.eql(u8, name, "unit")) break :blk 0;
            if (std.mem.eql(u8, name, "boolean") or
                std.mem.eql(u8, name, "i8") or std.mem.eql(u8, name, "u8")) break :blk 1;
            if (std.mem.eql(u8, name, "i16") or std.mem.eql(u8, name, "u16")) break :blk 2;
            if (std.mem.eql(u8, name, "i32") or
                std.mem.eql(u8, name, "u32") or
                std.mem.eql(u8, name, "enumeration")) break :blk 4;
            if (std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "u64")) break :blk 8;
            break :blk null;
        };
        cases[i] = .{ .variable = try e.b.variable(variants[i]), .body = try e.b.pure(if (width) |n|
            try e.variant(optional_width, 1, try e.b.constant(u64, n))
        else
            try e.variant(optional_width, 0, e.unit_value)) };
    }
    try e.b.define(d.width, try e.b.term(.{ .match_sum = .{
        .value = try e.param(d.width, 0),
        .cases = &cases,
    } }));
}

fn literalScalar(
    e: Author,
    value: Id,
    result: Id,
    input_machine: Id,
    schema: Id,
    value_body: Id,
    scalar_bytes: Id,
    byte: Id,
    optional_byte: Id,
    bytes: Id,
    present: Id,
) Error!Id {
    const b = e.b;
    var byte_vars: [8]Id = undefined;
    var byte_values: [8]Id = undefined;
    for (&byte_vars, &byte_values) |*variable, *expression| {
        variable.* = try b.variable(byte);
        expression.* = try b.reference(variable.*);
    }
    var scalar_result = try defineScalarResult(
        e,
        value,
        result,
        input_machine,
        schema,
        value_body,
        scalar_bytes,
        byte_values,
    );
    var index: usize = 8;
    while (index != 0) {
        index -= 1;
        const offset = try b.constant(u64, index);
        const selected = try b.primitive(optional_byte, .blob_byte, &.{ bytes, offset }, 0);
        scalar_result = try b.bind(byte_vars[index], try e.when(try e.binary(
            .less,
            offset,
            try b.reference(present),
        ), try b.pure(try e.payload(
            selected,
            1,
        )), try b.pure(try b.constant(
            u8,
            0,
        ))), scalar_result);
    }
    return scalar_result;
}

fn emitLiteral(
    e: Author,
    machine: machines.Definition,
    d: Definition,
    value: Id,
    result: Id,
    optional_width: Id,
    value_body: Id,
    scalar_bytes: Id,
) Error!void {
    const b = e.b;
    const input_machine = try e.param(d.literal, 0);
    const input = try e.param(d.literal, 1);
    const schema = try e.field(input, 0);
    const bytes = try e.field(input, 1);
    const program = try machine.field(e, input_machine, .program);
    const code = try e.field(program, machines.index(projection.Program, "code"));
    const schemas = try e.field(code, machines.index(data.activation.Program, "schemas"));
    const width = try b.variable(optional_width);
    const absent = try b.variable(e.unit);
    const present = try b.variable(e.integer);
    const byte = try b.scalar(u8);
    const optional_byte = try b.schema(.{ .sum = &.{ e.unit, byte } });
    const scalar_result = try literalScalar(
        e,
        value,
        result,
        input_machine,
        schema,
        value_body,
        scalar_bytes,
        byte,
        optional_byte,
        bytes,
        present,
    );
    const old_blobs = try machine.field(e, input_machine, .blobs);
    const blob_id = try e.field(old_blobs, 0);
    const new_blobs = try b.variable(machine.blobs.table);
    const blob_ref = try e.tuple(try projection.schema(data.graph.BlobRef, b), &.{blob_id});
    const blob_value = try e.tuple(value, &.{ schema, try e.variant(value_body, 1, blob_ref) });
    const blob = try e.tuple(machine.blobs.element, &.{ schema, bytes });
    const appended = try b.bind(new_blobs, try e.call(
        machine.blobs.append,
        &.{ old_blobs, blob },
    ), try b.pure(try e.tuple(result, &.{ try e.replace(
        input_machine,
        @backingInt(machines.Field.blobs),
        try b.reference(new_blobs),
    ), blob_value })));
    try b.define(d.literal, try b.bind(width, try e.call(
        d.width,
        &.{try e.required(schemas, schema)},
    ), try b.term(.{ .match_sum = .{
        .value = try b.reference(width),
        .cases = &.{ .{
            .variable = absent,
            .body = appended,
        }, .{ .variable = present, .body = scalar_result } },
    } })));
}
