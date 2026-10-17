const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const scalar = @import("scalar.zig");
const projection = @import("projection.zig");
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");

fn prepare(comptime unary: bool) !base.Prepared {
    var b = source.Builder.init(a);
    defer b.deinit();
    const d = try scalar.define(&b);
    return support.prepare(b.module(if (unary) d.unary else d.binary, try b.scalar(void)));
}

fn evaluate(prepared: *const base.Prepared, input: anytype) !data.scalar.Result {
    const arguments = try projection.encode(@TypeOf(input), a, input);
    defer a.free(arguments);
    var session = try base.Session.start(a, prepared, arguments, .{});
    defer session.deinit();
    const result = try session.run(null);
    try std.testing.expect(result == .completed);
    var decoded = try projection.decode(data.scalar.Result, a, try session.bytes(&result.completed));
    defer decoded.deinit();
    return decoded.value;
}

const Binary = struct { op: data.program.Opcode, schema: data.program.Schema, left: [8]u8, right: [8]u8 };
const Unary = struct { op: data.program.Opcode, from: data.program.Schema, to: data.program.Schema, value: [8]u8 };
const shapes = [_]data.program.Schema{ .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 };

fn limits(shape: data.program.Schema) struct { min: i128, max: i128 } {
    const width: u7 = @intCast(data.scalar.width(shape).? * 8);
    const signed = switch (shape) {
        .i8, .i16, .i32, .i64 => true,
        else => false,
    };
    const bits = width - @intFromBool(signed);
    return .{ .min = if (signed) -(@as(i128, 1) << bits) else 0, .max = (@as(i128, 1) << bits) - 1 };
}

test "portable scalar binary rules preserve all widths and guest arithmetic faults" {
    var prepared = try prepare(false);
    defer prepared.deinit();
    for (shapes) |shape| {
        const range = limits(shape);
        const values = [_]i128{ range.min, range.min + 1, 0, 1, range.max - 1, range.max };
        for (values) |left| for (values) |right| {
            const input_left = data.scalar.fromInteger(shape, left).?;
            const input_right = data.scalar.fromInteger(shape, right).?;
            for ([_]data.program.Opcode{ .integer_add, .integer_sub, .integer_mul, .integer_div, .integer_rem, .equal, .less, .integer_bit_and, .integer_bit_or, .integer_bit_xor }) |op| {
                const actual = try evaluate(&prepared, Binary{ .op = op, .schema = shape, .left = input_left, .right = input_right });
                const expected = try data.scalar.binary(op, shape, input_left, input_right);
                if (!std.meta.eql(expected, actual)) std.debug.print("scalar {s} {s} {d} {d}: expected={any}, actual={any}\n", .{ @tagName(shape), @tagName(op), left, right, expected, actual });
                try std.testing.expectEqualDeep(expected, actual);
            }
        };
        if (range.min < 0) {
            const minimum = data.scalar.fromInteger(shape, range.min).?;
            const negative_one = data.scalar.fromInteger(shape, -1).?;
            for ([_]data.program.Opcode{ .integer_div, .integer_rem }) |op|
                try std.testing.expectEqualDeep(data.scalar.Result{ .fault = .arithmetic_overflow }, try evaluate(&prepared, Binary{ .op = op, .schema = shape, .left = minimum, .right = negative_one }));
        }
    }
    for ([_]u8{ 0, 1 }) |left| for ([_]u8{ 0, 1 }) |right| {
        var l = @as([8]u8, @splat(0));
        var r = l;
        l[0] = left;
        r[0] = right;
        try std.testing.expectEqualDeep(try data.scalar.binary(.equal, .boolean, l, r), try evaluate(&prepared, Binary{ .op = .equal, .schema = .boolean, .left = l, .right = r }));
    };
}

test "portable scalar conversion and unary rules preserve signed minima and unsigned maxima" {
    var prepared = try prepare(true);
    defer prepared.deinit();
    for (shapes) |from| {
        const range = limits(from);
        for ([_]i128{ range.min, range.min + 1, 0, 1, range.max - 1, range.max }) |value| {
            const bytes = data.scalar.fromInteger(from, value).?;
            for (shapes) |to|
                try std.testing.expectEqualDeep(try data.scalar.unary(.integer_convert, from, to, bytes), try evaluate(&prepared, Unary{ .op = .integer_convert, .from = from, .to = to, .value = bytes }));
            try std.testing.expectEqualDeep(try data.scalar.unary(.integer_bit_not, from, from, bytes), try evaluate(&prepared, Unary{ .op = .integer_bit_not, .from = from, .to = from, .value = bytes }));
        }
    }
    for ([_]u8{ 0, 1 }) |value| {
        var bytes = @as([8]u8, @splat(0));
        bytes[0] = value;
        var expected = bytes;
        expected[0] = 1 - value;
        try std.testing.expectEqualDeep(data.scalar.Result{ .value = expected }, try evaluate(&prepared, Unary{ .op = .boolean_not, .from = .boolean, .to = .boolean, .value = bytes }));
    }
    const bytes = [_]u8{ 255, 255, 255, 255, 0, 0, 0, 0 };
    try std.testing.expectEqualDeep(data.scalar.Result{ .value = bytes }, try evaluate(&prepared, Unary{ .op = .enum_tag, .from = .{ .enumeration = &.{std.math.maxInt(u32)} }, .to = .u32, .value = bytes }));
}
