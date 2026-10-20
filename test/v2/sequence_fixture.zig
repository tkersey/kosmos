//! Consume every sequence element with checked addition.
const source = @import("horos").source;

pub fn build(b: *source.Builder) !source.Module {
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const sequence = try b.schema(.{ .seq = integer });
    const pair = try b.schema(.{ .product = &.{ integer, sequence } });
    const optional = try b.schema(.{ .sum = &.{ unit, pair } });
    const entry = try b.declare(&.{ sequence, integer }, integer, &.{}, &.{});
    const items = try b.reference(b.parameter(entry, 0));
    const sum = try b.reference(b.parameter(entry, 1));
    const empty = try b.variable(unit);
    const present = try b.variable(pair);
    const head = try b.variable(integer);
    const tail = try b.variable(sequence);
    const accumulated = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ sum, try b.reference(head) },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
    const next = try b.term(.{ .unpack_product = .{
        .value = try b.reference(present),
        .variables = &.{ head, tail },
        .body = try b.term(.{ .call = .{ .function = entry, .arguments = &.{
            try b.reference(tail), accumulated,
        } } }),
    } });
    try b.define(entry, try b.term(.{ .match_sum = .{
        .value = try b.primitive(optional, .sequence_pop, &.{items}, 0),
        .cases = &.{ .{ .variable = empty, .body = try b.pure(sum) }, .{
            .variable = present,
            .body = next,
        } },
    } }));
    return b.module(entry, unit);
}
