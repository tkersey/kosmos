const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const codecs = @import("codec.zig");
const Author = @import("author.zig").Author;
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");
const NaturalOutput = struct {
    read: codecs.Read,
    bytes: []const u8,
    fixed: u64,
    fixed_bytes: [8]u8,
};
const SkipInput = struct {
    program: projection.Program,
    schema: u64,
    bytes: []const u8,
    offset: u64,
};

fn prepare(comptime natural: bool) !base.Prepared {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const m = try machines.define(&b);
    const codec = try codecs.define(&b, m);
    const input = if (natural) e.integer else try projection.schema(SkipInput, &b);
    const output = if (natural) try projection.schema(NaturalOutput, &b) else e.integer;
    const entry = try b.declare(&.{input}, output, &.{}, &.{});
    const argument = try e.param(entry, 0);
    if (natural) {
        const encoded = try b.variable(try b.schema(.bytes));
        const decoded = try b.variable(try projection.schema(codecs.Read, &b));
        const fixed_bytes = try b.variable(try projection.schema([8]u8, &b));
        const fixed = try b.variable(e.integer);
        try b.define(
            entry,
            try b.bind(
                encoded,
                try e.call(codec.natural, &.{
                    argument,
                }),
                try b.bind(
                    decoded,
                    try e.call(codec.read, &.{ try b.reference(encoded), e.zero }),
                    try b.bind(
                        fixed_bytes,
                        try e.call(codec.fixed_bytes, &.{
                            argument,
                        }),
                        try b.bind(
                            fixed,
                            try e.call(codec.fixed, &.{try b.reference(fixed_bytes)}),
                            try b.pure(try e.tuple(output, &.{
                                try b.reference(decoded),
                                try b.reference(encoded),
                                try b.reference(fixed),
                                try b.reference(fixed_bytes),
                            })),
                        ),
                    ),
                ),
            ),
        );
    } else try b.define(entry, try e.call(codec.skip, &.{
        try e.field(argument, 0),
        try e.field(argument, 1),
        try e.field(argument, 2),
        try e.field(argument, 3),
    }));
    return support.prepare(b.module(entry, e.unit));
}

test "authored canonical naturals and fixed integers include u64 maximum" {
    var core = try prepare(true);
    defer core.deinit();
    for ([_]u64{ 0, 1, 127, 128, 255, 256, 16383, 16384, 0x100000000, std.math.maxInt(u64) }) |n| {
        var session = try base.Session.start(a, &core, &std.mem.toBytes(n), .{});
        defer session.deinit();
        const outcome = try session.run(null);
        try std.testing.expect(outcome == .completed);
        var actual = try projection.decode(NaturalOutput, a, try session.bytes(&outcome.completed));
        defer actual.deinit();
        var buffer: [10]u8 = undefined;
        var expected: data.wire.Writer = .{ .output = &buffer };
        try expected.natural(n);
        try std.testing.expectEqualSlices(u8, buffer[0..expected.position], actual.value.bytes);
        try std.testing.expectEqual(n, actual.value.read.value);
        try std.testing.expectEqual(expected.position, actual.value.read.next);
        try std.testing.expectEqual(n, actual.value.fixed);
        try std.testing.expectEqualSlices(u8, &std.mem.toBytes(n), &actual.value.fixed_bytes);
    }
}

test "authored schema traversal handles recursion and enormous zero width cardinality" {
    var core = try prepare(false);
    defer core.deinit();

    const image = try a.alloc(u8, try data.program_image.encodedLength(traversal_program));
    defer a.free(image);
    _ = try data.program_image.encode(a, traversal_program, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const projection_bytes = try projection.programBytes(a, admitted);
    defer a.free(projection_bytes);
    var program_value = try projection.decode(projection.Program, a, projection_bytes);
    defer program_value.deinit();
    const Case = struct { schema: u64, bytes: []const u8 };
    const cases = [_]Case{
        .{ .schema = 0, .bytes = &.{} },
        .{ .schema = 1, .bytes = &std.mem.toBytes(@as(u64, 981)) },
        .{ .schema = 2, .bytes = &.{ 3, 4, 5, 6 } },
        .{ .schema = 3, .bytes = &.{ 6, 0, 0, 0, 0, 0, 0, 0, 2, 51, 52 } },
        .{ .schema = 4, .bytes = &.{0} },
        .{ .schema = 5, .bytes = &.{ 3, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 2, 9, 8, 0 } },
        .{ .schema = 6, .bytes = &.{} },
        .{ .schema = 7, .bytes = &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 1 } },
        .{ .schema = 8, .bytes = &.{ 1, 1, 1, 1, 1, 1, 0 } },
    };
    for (cases) |case| {
        try data.admission.value(a, traversal_program.schemas, admitted.schemaFacts(), .{
            .schema = case.schema,
            .bytes = case.bytes,
        });
        const padded = try std.mem.concat(a, u8, &.{ &.{ 99, 98 }, case.bytes, &.{97} });
        defer a.free(padded);
        const input = try projection.encode(SkipInput, a, .{
            .program = program_value.value,
            .schema = case.schema,
            .bytes = padded,
            .offset = 2,
        });
        defer a.free(input);
        var session = try base.Session.start(a, &core, input, .{});
        defer session.deinit();
        const outcome = try session.run(null);
        try std.testing.expect(outcome == .completed);
        try std.testing.expectEqual(2 + case.bytes.len, std.mem.readInt(
            u64,
            (try session.bytes(&outcome.completed))[0..8],
            .little,
        ));
    }
}

const traversal_program: data.activation.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 0 },
    .schemas = &.{
        .unit,                  .u64, .bytes,
        .{ .product = &.{
            1,
            2,
        } },
        .{ .sum = &.{
            0,
            3,
        } },
        .{ .seq = 4 },
        .{ .array = .{
            .element = 0,
            .length = std.math.maxInt(u64),
        } },
        .{ .vector = .{
            .element = 0,
            .maximum = std.math.maxInt(u64),
        } },
        .{ .sum = &.{ 0, 8 } },
    },
    .constants = &.{.{ .schema = 0, .bytes = &.{} }},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{},
        .layout = .{ .slots = &.{0} },
        .result = 0,
    }},
    .blocks = &.{.{ .function = 0, .instructions = &.{.{
        .destination = 0,
        .opcode = .constant,
    }}, .terminator = .{ .return_value = 0 } }},
};
