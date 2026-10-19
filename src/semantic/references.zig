//! Generate ordinary Horos reference traversal and rebasing from the actual
//! guest record types. Blob references are a different identity domain.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const tables = @import("table.zig");
const maps = @import("map.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
pub const Definition = struct { walk: Id, rebase: Id, references: Id, map: maps.Definition, refs: tables.Definition };

fn contains(comptime T: type, comptime Ref: type) bool {
    if (T == g.NodeRef or T == g.BlobRef) return T == Ref;
    return switch (@typeInfo(T)) {
        .pointer => |info| contains(info.child, Ref),
        .optional => |info| contains(info.child, Ref),
        .array => |info| contains(info.child, Ref),
        inline .@"struct", .@"union" => |info| blk: {
            inline for (info.field_types) |Field| if (contains(Field, Ref)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

pub fn define(comptime T: type, b: *source.Builder) Error!Definition {
    return defineDomain(T, g.NodeRef, b);
}
pub fn defineBlobs(comptime T: type, b: *source.Builder) Error!Definition {
    return defineDomain(T, g.BlobRef, b);
}
fn defineDomain(comptime T: type, comptime Ref: type, b: *source.Builder) Error!Definition {
    const schema = try projection.schema(T, b);
    // NodeRef and BlobRef have the same ordinary shape but different meaning.
    const cache = try b.specialization(Definition, "kosmos.semantic.references/1/" ++ @typeName(Ref) ++ "/" ++ @typeName(T), schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const reference = try projection.schema(Ref, b);
    const refs = try tables.define(b, reference);
    const map = try maps.define(b, reference);
    const d: Definition = .{
        .walk = try b.declare(&.{ schema, refs.table }, refs.table, &.{}, &.{}),
        .rebase = try b.declare(&.{ schema, map.tree }, schema, &.{}, &.{}),
        .references = try b.declare(&.{schema}, refs.table, &.{}, &.{}),
        .refs = refs,
        .map = map,
    };
    try b.define(d.references, try e.call(d.walk, &.{ try e.param(d.references, 0), try refs.empty(b) }));
    const walk_input = try e.param(d.walk, 0);
    const prior = try e.param(d.walk, 1);
    const input = try e.param(d.rebase, 0);
    const mapping = try e.param(d.rebase, 1);
    if (!comptime contains(T, Ref)) {
        try b.define(d.walk, try b.pure(prior));
        try b.define(d.rebase, try b.pure(input));
    } else if (T == Ref) {
        try b.define(d.walk, try e.call(refs.append, &.{ prior, walk_input }));
        const found = try b.variable(map.optional);
        const nil = try b.variable(e.unit);
        const present = try b.variable(reference);
        try b.define(d.rebase, try b.bind(found, try e.call(map.get, &.{ mapping, try e.field(input, 0) }), try b.term(.{ .match_sum = .{ .value = try b.reference(found), .cases = &.{
            .{ .variable = nil, .body = try b.pure(input) },
            .{ .variable = present, .body = try b.pure(try b.reference(present)) },
        } } })));
    } else switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result_fields: [info.field_names.len]Id = undefined;
            var changed: [info.field_names.len]?Id = @splat(null);
            var accumulators: [info.field_names.len]?Id = @splat(null);
            var current = prior;
            inline for (info.field_types, 0..) |Field, i| {
                if (comptime contains(Field, Ref)) {
                    changed[i] = try b.variable(try projection.schema(Field, b));
                    accumulators[i] = try b.variable(refs.table);
                    result_fields[i] = try b.reference(changed[i].?);
                    current = try b.reference(accumulators[i].?);
                } else result_fields[i] = try e.field(input, i);
            }
            var walk = try b.pure(current);
            var rebase = try b.pure(try e.tuple(schema, &result_fields));
            inline for (0..info.field_types.len) |reverse| {
                const i = info.field_types.len - 1 - reverse;
                const Field = info.field_types[i];
                if (comptime contains(Field, Ref)) {
                    const child = try defineDomain(Field, Ref, b);
                    var previous = prior;
                    inline for (0..i) |j| if (accumulators[j]) |v| {
                        previous = try b.reference(v);
                    };
                    walk = try b.bind(accumulators[i].?, try e.call(child.walk, &.{ try e.field(walk_input, i), previous }), walk);
                    rebase = try b.bind(changed[i].?, try e.call(child.rebase, &.{ try e.field(input, i), mapping }), rebase);
                }
            }
            try b.define(d.walk, walk);
            try b.define(d.rebase, rebase);
        },
        .@"union" => |info| {
            const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
            var walk_cases: [info.field_types.len]Case = undefined;
            var rebase_cases: [info.field_types.len]Case = undefined;
            inline for (info.field_types, 0..) |Field, i| {
                const variable = try b.variable(try projection.schema(Field, b));
                const value = try b.reference(variable);
                const child = try defineDomain(Field, Ref, b);
                const changed = try b.variable(try projection.schema(Field, b));
                walk_cases[i] = .{ .variable = variable, .body = try e.call(child.walk, &.{ value, prior }) };
                rebase_cases[i] = .{ .variable = variable, .body = try b.bind(changed, try e.call(child.rebase, &.{ value, mapping }), try b.pure(try e.variant(schema, i, try b.reference(changed)))) };
            }
            try b.define(d.walk, try b.term(.{ .match_sum = .{ .value = walk_input, .cases = &walk_cases } }));
            try b.define(d.rebase, try b.term(.{ .match_sum = .{ .value = input, .cases = &rebase_cases } }));
        },
        .optional => |info| {
            const child = try defineDomain(info.child, Ref, b);
            const nil = try b.variable(e.unit);
            const present = try b.variable(try projection.schema(info.child, b));
            const value = try b.reference(present);
            const changed = try b.variable(try projection.schema(info.child, b));
            try b.define(d.walk, try b.term(.{ .match_sum = .{ .value = walk_input, .cases = &.{
                .{ .variable = nil, .body = try b.pure(prior) },
                .{ .variable = present, .body = try e.call(child.walk, &.{ value, prior }) },
            } } }));
            try b.define(d.rebase, try b.term(.{ .match_sum = .{ .value = input, .cases = &.{
                .{ .variable = nil, .body = try b.pure(input) },
                .{ .variable = present, .body = try b.bind(changed, try e.call(child.rebase, &.{ value, mapping }), try b.pure(try e.variant(schema, 1, try b.reference(changed)))) },
            } } }));
        },
        .pointer => |info| {
            const child = try defineDomain(info.child, Ref, b);
            const child_type = try projection.schema(info.child, b);
            const output = try tables.define(b, child_type);
            const pair_type = try b.schema(.{ .product = &.{ child_type, schema } });
            const optional = try b.schema(.{ .sum = &.{ e.unit, pair_type } });
            const nil = try b.variable(e.unit);
            const pair_var = try b.variable(pair_type);
            const pair = try b.reference(pair_var);
            const head = try e.field(pair, 0);
            const rest = try e.field(pair, 1);
            const walked = try b.variable(refs.table);
            try b.define(d.walk, try b.term(.{ .match_sum = .{ .value = try b.primitive(optional, .sequence_pop, &.{walk_input}, 0), .cases = &.{
                .{ .variable = nil, .body = try b.pure(prior) },
                .{ .variable = pair_var, .body = try b.bind(walked, try e.call(child.walk, &.{ head, prior }), try e.call(d.walk, &.{ rest, try b.reference(walked) })) },
            } } }));
            const loop = try b.declare(&.{ schema, map.tree, output.table }, output.table, &.{}, &.{});
            const source_values = try e.param(loop, 0);
            const map_value = try e.param(loop, 1);
            const prior_values = try e.param(loop, 2);
            const changed = try b.variable(child_type);
            const appended = try b.variable(output.table);
            try b.define(loop, try b.term(.{ .match_sum = .{ .value = try b.primitive(optional, .sequence_pop, &.{source_values}, 0), .cases = &.{
                .{ .variable = nil, .body = try b.pure(prior_values) },
                .{ .variable = pair_var, .body = try b.bind(changed, try e.call(child.rebase, &.{ head, map_value }), try b.bind(appended, try e.call(output.append, &.{ prior_values, try b.reference(changed) }), try e.call(loop, &.{ rest, map_value, try b.reference(appended) }))) },
            } } }));
            const collected = try b.variable(output.table);
            try b.define(d.rebase, try b.bind(collected, try e.call(loop, &.{ input, mapping, try output.empty(b) }), try e.call(output.to_sequence, &.{try b.reference(collected)})));
        },
        else => @compileError("unsupported reference-bearing guest record " ++ @typeName(T)),
    }
    return cache.finish(b, d);
}
