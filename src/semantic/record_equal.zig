//! Total structural equality for ordinary projected records, authored as Horos
//! data algorithms. Reference IDs are compared, never dereferenced or merged.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;

pub fn define(comptime T: type, b: *source.Builder) source.Error!Id {
    return Equality(T).define(b);
}

fn Equality(comptime T: type) type {
    _ = data.schema.native.info(T);
    return struct {
        fn define(b: *source.Builder) source.Error!Id {
            const schema = try projection.schema(T, b);
            const cache = try b.specialization(
                Id,
                "kosmos.semantic.record-equal/1/" ++ @typeName(T),
                schema,
            );
            if (cache.cached) |saved| return saved;
            const e = try Author.init(b);
            const entry = try b.declare(&.{ schema, schema }, e.boolean, &.{}, &.{});
            const left = try e.param(entry, 0);
            const right = try e.param(entry, 1);
            const yes = try b.pure(try b.constant(bool, true));
            const no = try b.pure(try b.constant(bool, false));
            const body = switch (@typeInfo(T)) {
                .void => yes,
                .bool, .int => try b.pure(try e.binary(.equal, left, right)),
                .@"enum" => try b.pure(try e.binary(.equal, try b.primitive(
                    try b.scalar(u32),
                    .enum_tag,
                    &.{left},
                    0,
                ), try b.primitive(try b.scalar(u32), .enum_tag, &.{right}, 0))),
                .@"struct" => |info| try structure(info, b, e, left, right, yes, no),
                .@"union" => |info| try unionRecord(info, b, e, left, right, no),
                .optional => |info| try optionalRecord(info, b, e, left, right, yes, no),
                .array => |info| try arrayRecord(info, b, e, left, right, yes, no),
                .pointer => |info| try sliceRecord(info, b, e, schema, entry, left, right, yes, no),
                else => @compileError("not an ordinary record: " ++ @typeName(T)),
            };
            try b.define(entry, body);
            return cache.finish(b, entry);
        }
    };
}

fn structure(
    comptime info: anytype,
    b: *source.Builder,
    e: Author,
    left: Id,
    right: Id,
    yes: Id,
    no: Id,
) source.Error!Id {
    var next = yes;
    inline for (0..info.field_types.len) |reverse| {
        const i = info.field_types.len - 1 - reverse;
        const same = try b.variable(e.boolean);
        next = try b.bind(same, try e.call(try Equality(info.field_types[i]).define(b), &.{
            try e.field(left, i), try e.field(right, i),
        }), try e.when(try b.reference(same), next, no));
    }
    return next;
}

fn unionRecord(
    comptime info: anytype,
    b: *source.Builder,
    e: Author,
    left: Id,
    right: Id,
    no: Id,
) source.Error!Id {
    const Case = std.meta.Elem(@FieldType(
        @FieldType(source.ast.Term, "match_sum"),
        "cases",
    ));
    var cases: [info.field_types.len]Case = undefined;
    inline for (info.field_types, 0..) |Field, i| {
        const variable = try b.variable(try projection.schema(Field, b));
        cases[i] = .{ .variable = variable, .body = try e.call(try Equality(Field).define(b), &.{
            try b.reference(variable), try e.payload(right, i),
        }) };
    }
    const same_tag = try e.binary(.equal, try b.primitive(
        e.integer,
        .variant_tag,
        &.{left},
        0,
    ), try b.primitive(e.integer, .variant_tag, &.{right}, 0));
    return try e.when(same_tag, try b.term(.{
        .match_sum = .{ .value = left, .cases = &cases },
    }), no);
}

fn optionalRecord(
    comptime info: anytype,
    b: *source.Builder,
    e: Author,
    left: Id,
    right: Id,
    yes: Id,
    no: Id,
) source.Error!Id {
    const same_tag = try e.binary(.equal, try b.primitive(
        e.integer,
        .variant_tag,
        &.{left},
        0,
    ), try b.primitive(e.integer, .variant_tag, &.{right}, 0));
    const empty = try e.binary(.equal, try b.primitive(
        e.integer,
        .variant_tag,
        &.{left},
        0,
    ), e.zero);
    return try e.when(
        same_tag,
        try e.when(
            empty,
            yes,
            try e.call(
                try Equality(info.child).define(b),
                &.{ try e.payload(left, 1), try e.payload(right, 1) },
            ),
        ),
        no,
    );
}

fn arrayRecord(
    comptime info: anytype,
    b: *source.Builder,
    e: Author,
    left: Id,
    right: Id,
    yes: Id,
    no: Id,
) source.Error!Id {
    var next = yes;
    for (0..info.len) |reverse| {
        const at = try b.constant(u64, info.len - 1 - reverse);
        const same = try b.variable(e.boolean);
        next = try b.bind(same, try e.call(try Equality(info.child).define(b), &.{
            try e.required(left, at), try e.required(right, at),
        }), try e.when(try b.reference(same), next, no));
    }
    return next;
}

fn sliceRecord(
    comptime info: anytype,
    b: *source.Builder,
    e: Author,
    schema: Id,
    entry: Id,
    left: Id,
    right: Id,
    yes: Id,
    no: Id,
) source.Error!Id {
    if (info.size != .slice) @compileError("projected records contain only slices");
    if (info.child == u8) {
        const compared = try b.primitive(
            try b.scalar(i8),
            .blob_compare,
            &.{ left, right },
            0,
        );
        return try b.pure(try e.binary(.equal, compared, try b.constant(i8, 0)));
    }
    const element = try projection.schema(info.child, b);
    const pair = try b.schema(.{ .product = &.{ element, schema } });
    const option = try b.schema(.{ .sum = &.{ e.unit, pair } });
    const lhs = try b.variable(option);
    const rhs = try b.variable(option);
    const l = try b.reference(lhs);
    const r = try b.reference(rhs);
    const lp = try e.payload(l, 1);
    const rp = try e.payload(r, 1);
    const same = try b.variable(e.boolean);
    const next = try e.call(entry, &.{ try e.field(lp, 1), try e.field(rp, 1) });
    const elements = try b.bind(same, try e.call(try Equality(info.child).define(b), &.{
        try e.field(lp, 0), try e.field(rp, 0),
    }), try e.when(try b.reference(same), next, no));
    const same_tag = try e.binary(
        .equal,
        try b.primitive(e.integer, .variant_tag, &.{l}, 0),
        try b.primitive(e.integer, .variant_tag, &.{r}, 0),
    );
    const empty = try e.binary(
        .equal,
        try b.primitive(e.integer, .variant_tag, &.{l}, 0),
        e.zero,
    );
    return try b.bind(lhs, try b.pure(
        try b.primitive(option, .sequence_pop, &.{left}, 0),
    ), try b.bind(rhs, try b.pure(try b.primitive(
        option,
        .sequence_pop,
        &.{right},
        0,
    )), try e.when(same_tag, try e.when(empty, yes, elements), no)));
}
