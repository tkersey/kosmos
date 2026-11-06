const std = @import("std");
const horos = @import("horos");
const source = horos.source;
const data = horos.data;

pub const hidden = "owner-only retained diagnostic blob";
pub const answer = hidden.len + 12;

pub fn integer(value: u64) [8]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return bytes;
}

pub fn arguments(a: std.mem.Allocator) ![]u8 {
    var measure: data.wire.Writer = .{};
    try data.record.write([]const u8, hidden, &measure);
    const bytes = try a.alloc(u8, measure.position);
    errdefer a.free(bytes);
    var output: data.wire.Writer = .{ .output = bytes };
    try data.record.write([]const u8, hidden, &output);
    return bytes;
}

pub fn guest(b: *source.Builder) !source.ast.Module {
    const integer_type = try b.scalar(u64);
    const bytes = try b.schema(.bytes);
    const unit = try b.scalar(void);
    const effect = try b.effect(.{
        .identity = "diagnostic/example-lookup",
        .payload = integer_type,
        .result = integer_type,
    });
    const entry = try b.declare(&.{bytes}, integer_type, &.{effect}, &.{});
    const first = try b.variable(integer_type);
    const second = try b.variable(integer_type);
    const retained_length = try b.primitive(integer_type, .blob_length, &.{
        try b.reference(b.parameter(entry, 0)),
    }, 0);
    const sum = try add(b, try b.reference(first), try b.reference(second));
    const result = try b.pure(try add(b, sum, retained_length));
    const last = try b.bind(second, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.constant(u64, 22),
    } }), result);
    try b.define(entry, try b.bind(first, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.constant(u64, 11),
    } }), last));
    return b.module(entry, unit);
}

fn add(b: *source.Builder, left: data.program.Id, right: data.program.Id) !data.program.Id {
    return b.value(.{ .schema = try b.scalar(u64), .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ left, right },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
}
