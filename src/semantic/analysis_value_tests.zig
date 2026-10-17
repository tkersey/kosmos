const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const admission = @import("analysis_values.zig");
const Author = @import("author.zig").Author;
const base = @import("../base/session.zig");
const support = @import("test_support.zig");
const a = std.testing.allocator;
const Input = struct { program: projection.Program, schema: u64, bytes: []const u8 };

fn prepare() !base.Prepared {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const m = try machines.define(&b);
    const values = try admission.define(&b, m);
    const entry = try b.declare(&.{try projection.schema(Input, &b)}, e.unit, &.{}, &.{});
    const input = try e.param(entry, 0);
    const bytes = try e.field(input, 2);
    const end = try b.variable(e.integer);
    try b.define(entry, try b.bind(end, try e.call(values.value, &.{ try e.field(input, 0), try e.field(input, 1), bytes, e.zero }), try e.when(try e.binary(.equal, try b.reference(end), try b.primitive(e.integer, .blob_length, &.{bytes}, 0)), try b.pure(e.unit_value), try e.fail())));
    return support.prepare(b.module(entry, e.unit));
}

fn expectAgreement(core: *base.Prepared, program: projection.Program, schema: u64, bytes: []const u8) !void {
    const valid = if (data.admission.value(a, program.code.schemas, program.schemas, .{ .schema = schema, .bytes = bytes })) true else |_| false;
    const input = try projection.encode(Input, a, .{ .program = program, .schema = schema, .bytes = bytes });
    defer a.free(input);
    var session = try base.Session.start(a, core, input, .{});
    defer session.deinit();
    const result = try session.run(null);
    if ((result == .completed) != valid or (result != .completed and result != .failed))
        std.debug.print("analysis admission schema={d} bytes={any} native={any} source={s}\n", .{ schema, bytes, valid, @tagName(result) });
    try std.testing.expect(result == .completed or result == .failed);
    try std.testing.expectEqual(valid, result == .completed);
}

test "pure analysis value admission agrees with Horos across canonical grammar" {
    var core = try prepare();
    defer core.deinit();
    const program: data.activation.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{
            .unit,                          .boolean,                                       .i8,                      .i16,                                           .i32,                                                                      .i64,                                         .u8,                     .u16,                   .u32,                                       .u64,          .bytes,                                                          .text,
            .{ .product = &.{ 1, 9, 10 } }, .{ .sum = &.{ 0, 1, 12 } },                     .{ .seq = 1 },            .{ .vector = .{ .element = 1, .maximum = 2 } }, .{ .internal = .{ .computation = .{ .parameters = &.{}, .result = 0 } } }, .{ .array = .{ .element = 1, .length = 2 } }, .{ .bounded_bytes = 2 }, .{ .bounded_text = 4 }, .{ .enumeration = &.{ 0, 7, 0xfffffffe } }, .{ .seq = 0 }, .{ .array = .{ .element = 0, .length = std.math.maxInt(u64) } }, .{ .product = &.{} },
            .{ .sum = &.{ 0, 24 } },        .{ .vector = .{ .element = 0, .maximum = 2 } }, .{ .enumeration = &.{} }, .{ .seq = 16 },                                 .{ .array = .{ .element = 16, .length = 0 } },                             .{ .product = &.{16} },
        },
        .constants = &.{.{ .schema = 0, .bytes = &.{} }},
        .effects = &.{},
        .functions = &.{.{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 }},
        .blocks = &.{.{ .function = 0, .instructions = &.{.{ .destination = 0, .opcode = .constant }}, .terminator = .{ .return_value = 0 } }},
    };
    const image = try a.alloc(u8, try data.program_image.encodedLength(program));
    defer a.free(image);
    _ = try data.program_image.encode(a, program, image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    const encoded = try projection.programBytes(a, guest);
    defer a.free(encoded);
    var projected = try projection.decode(projection.Program, a, encoded);
    defer projected.deinit();
    const Case = struct { schema: u64, bytes: []const u8 };
    const valid = [_]Case{
        .{ .schema = 0, .bytes = &.{} },                                                  .{ .schema = 1, .bytes = &.{1} },
        .{ .schema = 2, .bytes = &.{255} },                                               .{ .schema = 3, .bytes = &.{ 255, 255 } },
        .{ .schema = 4, .bytes = &.{ 255, 255, 255, 255 } },                              .{ .schema = 5, .bytes = &std.mem.toBytes(@as(i64, std.math.minInt(i64))) },
        .{ .schema = 6, .bytes = &.{255} },                                               .{ .schema = 7, .bytes = &.{ 255, 255 } },
        .{ .schema = 8, .bytes = &.{ 255, 255, 255, 255 } },                              .{ .schema = 9, .bytes = &std.mem.toBytes(@as(u64, std.math.maxInt(u64))) },
        .{ .schema = 10, .bytes = &.{ 2, 0, 255 } },                                      .{ .schema = 11, .bytes = &.{ 2, 0xc3, 0xa9 } },
        .{ .schema = 12, .bytes = &.{ 1, 5, 0, 0, 0, 0, 0, 0, 0, 2, 9, 8 } },             .{ .schema = 13, .bytes = &.{ 1, 0 } },
        .{ .schema = 14, .bytes = &.{ 2, 0, 1 } },                                        .{ .schema = 15, .bytes = &.{ 2, 1, 0 } },
        .{ .schema = 17, .bytes = &.{ 0, 1 } },                                           .{ .schema = 18, .bytes = &.{ 2, 0, 255 } },
        .{ .schema = 19, .bytes = &.{ 4, 0xf4, 0x8f, 0xbf, 0xbf } },                      .{ .schema = 20, .bytes = &.{ 0xfe, 0xff, 0xff, 0xff } },
        .{ .schema = 21, .bytes = &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 1 } }, .{ .schema = 22, .bytes = &.{} },
        .{ .schema = 23, .bytes = &.{} },                                                 .{ .schema = 24, .bytes = &.{ 1, 1, 1, 1, 0 } },
        .{ .schema = 25, .bytes = &.{2} },
    };
    for (valid) |case| {
        try data.admission.value(a, program.schemas, guest.schemaFacts(), .{ .schema = case.schema, .bytes = case.bytes });
        try expectAgreement(&core, projected.value, case.schema, case.bytes);
        for (0..case.bytes.len) |end| try expectAgreement(&core, projected.value, case.schema, case.bytes[0..end]);
        const trailing = try std.mem.concat(a, u8, &.{ case.bytes, &.{0} });
        defer a.free(trailing);
        try expectAgreement(&core, projected.value, case.schema, trailing);
    }
    const malformed = [_]Case{
        .{ .schema = 9, .bytes = &.{ 5, 0, 0, 0, 0, 0, 0, 0, 99 } },
        .{ .schema = 10, .bytes = &.{ 0x80, 0 } },
        .{ .schema = 10, .bytes = &.{ 0x81, 0, 7 } },
        .{ .schema = 10, .bytes = &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 2 } },
        .{ .schema = 10, .bytes = &.{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 0 } },
        .{ .schema = 12, .bytes = &.{ 2, 5, 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 13, .bytes = &.{3} },
        .{ .schema = 13, .bytes = &.{ 1, 2 } },
        .{ .schema = 14, .bytes = &.{ 2, 0, 2 } },
        .{ .schema = 14, .bytes = &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 1 } },
        .{ .schema = 15, .bytes = &.{ 3, 0, 1, 0 } },
        .{ .schema = 17, .bytes = &.{ 0, 2 } },
        .{ .schema = 18, .bytes = &.{ 3, 1, 2, 3 } },
        .{ .schema = 19, .bytes = &.{ 5, 65, 65, 65, 65, 65 } },
        .{ .schema = 20, .bytes = &.{ 1, 0, 0, 0 } },
        .{ .schema = 21, .bytes = &.{ 0x80, 0 } },
        .{ .schema = 24, .bytes = &.{ 1, 2 } },
        .{ .schema = 25, .bytes = &.{3} },
        .{ .schema = 26, .bytes = &.{ 0, 0, 0, 0 } },
        .{ .schema = 16, .bytes = &.{} },
        .{ .schema = 27, .bytes = &.{0} },
        .{ .schema = 28, .bytes = &.{} },
        .{ .schema = 29, .bytes = &.{} },
    };
    for (malformed) |case| {
        if (data.admission.value(a, program.schemas, guest.schemaFacts(), .{ .schema = case.schema, .bytes = case.bytes })) return error.TestUnexpectedResult else |_| {}
        try expectAgreement(&core, projected.value, case.schema, case.bytes);
    }
    // Exhaust every Boolean octet and every one-byte text payload. Additional
    // strings cover each UTF-8 lead/second-byte restriction and truncation.
    for (0..256) |octet| {
        try expectAgreement(&core, projected.value, 1, &.{@intCast(octet)});
        try expectAgreement(&core, projected.value, 11, &.{ 1, @intCast(octet) });
    }
    for ([_][]const u8{ "", "Aé€𐍈", &.{ 0xc0, 0x80 }, &.{ 0xc2, 0x7f }, &.{ 0xe0, 0x9f, 0xbf }, &.{ 0xed, 0xa0, 0x80 }, &.{ 0xef, 0xbf, 0xbf }, &.{ 0xf0, 0x8f, 0xbf, 0xbf }, &.{ 0xf4, 0x90, 0x80, 0x80 }, &.{ 0xf5, 0x80, 0x80, 0x80 }, &.{ 0xe2, 0x82 }, &.{ 0xf0, 0x90, 0x80 }, &.{ 0xe2, 0x82, 0x41 } }) |text| {
        const value = try projection.encode([]const u8, a, text);
        defer a.free(value);
        try expectAgreement(&core, projected.value, 11, value);
        try expectAgreement(&core, projected.value, 19, value);
    }
}
