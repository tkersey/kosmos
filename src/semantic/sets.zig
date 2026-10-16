//! Ordinary sparse ID sets, shared by liveness and continuation capture.
const data = @import("horos_data");
const source = @import("horos").source;
const Author = @import("author.zig").Author;
const maps = @import("map.zig");
const Id = data.program.Id;
pub const Definition = struct { map: maps.Definition, from_sequence: Id, contains: Id };

pub fn define(b: *source.Builder) source.Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.sets/1", 0);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const map = try maps.define(b, e.unit);
    const ids = try b.schema(.{ .seq = e.integer });
    const d: Definition = .{
        .map = map,
        .from_sequence = try b.declare(&.{ids}, map.tree, &.{}, &.{}),
        .contains = try b.declare(&.{ map.tree, e.integer }, e.boolean, &.{}, &.{}),
    };
    const found = try b.variable(map.optional);
    try b.define(d.contains, try b.bind(found, try e.call(map.get, &.{ try e.param(d.contains, 0), try e.param(d.contains, 1) }), try b.pure(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{try b.reference(found)}, 0), e.one))));
    const loop = try b.declare(&.{ ids, map.tree }, map.tree, &.{}, &.{});
    const parts = try b.schema(.{ .product = &.{ e.integer, ids } });
    const popped = try b.schema(.{ .sum = &.{ e.unit, parts } });
    const nil = try b.variable(e.unit);
    const pair_var = try b.variable(parts);
    const pair = try b.reference(pair_var);
    const prior = try e.param(loop, 1);
    const next = try b.variable(map.tree);
    try b.define(loop, try b.term(.{ .match_sum = .{
        .value = try b.primitive(popped, .sequence_pop, &.{try e.param(loop, 0)}, 0),
        .cases = &.{
            .{ .variable = nil, .body = try b.pure(prior) },
            .{ .variable = pair_var, .body = try b.bind(next, try e.call(map.set, &.{ prior, try e.field(pair, 0), e.unit_value }), try e.call(loop, &.{ try e.field(pair, 1), try b.reference(next) })) },
        },
    } }));
    try b.define(d.from_sequence, try e.call(loop, &.{ try e.param(d.from_sequence, 0), try map.empty(e) }));
    return cache.finish(b, d);
}
