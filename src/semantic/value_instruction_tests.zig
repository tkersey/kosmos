const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const Author = @import("author.zig").Author;
const a = std.testing.allocator;
const support = @import("test_support.zig");

test "authored lexical closures and bounded data preserve every native cut" {
    var core = try support.prepareCore();
    defer core.deinit();
    inline for (.{ source.examples.lexical, source.examples.boundedValues }, 0..) |build, i| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const image = try support.encode(try build(&b));
        defer a.free(image);
        try support.expectNativeCuts(&core, image, if (i == 0) &std.mem.toBytes(@as(u64, 41)) else &.{}, 40);
    }
}

test "authored cell updates preserve alias identity inside a guest region" {
    var core = try support.prepareCore();
    defer core.deinit();
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const r = b.region();
    const region = try b.schema(.{ .internal = .{ .region = r } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{ .region = r, .element = e.integer } } });
    const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{region}, .result = e.integer, .regions = &.{r} } } });
    const body = try b.declare(&.{region}, e.integer, &.{}, &.{r});
    const allocated = try b.variable(cell);
    const alias = try b.variable(cell);
    const changed = try b.variable(e.unit);
    const allocation = try b.primitive(cell, .cell_new, &.{ try e.param(body, 0), try b.constant(u64, 17) }, 0);
    const update = try b.primitive(e.unit, .cell_set, &.{ try b.reference(allocated), try b.constant(u64, 29) }, 0);
    const read = try b.primitive(e.integer, .cell_get, &.{try b.reference(alias)}, 0);
    try b.define(body, try b.bind(allocated, try b.pure(allocation), try b.bind(alias, try b.pure(try b.primitive(cell, .move, &.{try b.reference(allocated)}, 0)), try b.bind(changed, try b.pure(update), try b.pure(read)))));
    const main = try b.declare(&.{}, e.integer, &.{}, &.{});
    try b.define(main, try b.term(.{ .with_region = .{ .region = r, .body = try b.lambda(body, body_type) } }));
    const image = try support.encode(b.module(main, e.unit));
    defer a.free(image);
    try support.expectNativeCuts(&core, image, &.{}, 40);
}

test "authored owned aggregate extraction preserves a resource identity" {
    var core = try support.prepareCore();
    defer core.deinit();
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const resource = try b.resource(e.integer);
    const pair = try b.schema(.{ .product = &.{ resource, e.integer } });
    const main = try b.declare(&.{e.integer}, e.integer, &.{}, &.{});
    try b.resourceAuthority(resource, &.{main}, &.{main});
    const owned = try b.primitive(resource, .resource_pack, &.{try e.param(main, 0)}, 0);
    const product = try e.tuple(pair, &.{ owned, try b.constant(u64, 3) });
    const projected = try e.field(product, 0);
    try b.define(main, try b.pure(try b.primitive(e.integer, .resource_unpack, &.{projected}, 0)));
    const image = try support.encode(b.module(main, e.unit));
    defer a.free(image);
    try support.expectNativeCuts(&core, image, &std.mem.toBytes(@as(u64, 53)), 30);
}

test "authored bytes and text rules match native instruction cuts" {
    var core = try support.prepareCore();
    defer core.deinit();
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const bytes = try b.schema(.bytes);
    const text = try b.schema(.text);
    const signed = try b.scalar(i64);
    const codepoint = try b.scalar(u32);
    const byte = try b.scalar(u8);
    const optional = try b.schema(.{ .sum = &.{ e.unit, byte } });
    const comparison = try b.scalar(i8);
    const output = try b.schema(.{ .product = &.{ e.integer, bytes, bytes, comparison, optional, text, text, bytes } });
    const main = try b.declare(&.{ bytes, e.integer, signed, codepoint }, output, &.{}, &.{});
    const input = try e.param(main, 0);
    const index = try e.param(main, 1);
    const length = try b.primitive(e.integer, .blob_length, &.{input}, 0);
    const concat = try e.concat(input, try e.literal([]const u8, &.{ 0, 128, 255 }));
    const slice = try e.slice(input, e.zero, try b.constant(u64, 2));
    const compare = try b.primitive(comparison, .blob_compare, &.{ input, try e.literal([]const u8, &.{ 42, 0, 11 }) }, 0);
    const get = try b.primitive(optional, .blob_byte, &.{ input, index }, 0);
    const integer_text = try b.primitive(text, .text_integer, &.{try e.param(main, 2)}, 0);
    const scalar_text = try e.checked(text, .text_scalar, &.{try e.param(main, 3)}, &.{.invalid_utf8});
    const one = try b.primitive(bytes, .blob_from_byte, &.{try b.constant(u8, 251)}, 0);
    try b.define(main, try b.pure(try e.tuple(output, &.{ length, concat, slice, compare, get, integer_text, scalar_text, one })));
    const image = try support.encode(b.module(main, e.unit));
    defer a.free(image);
    const Input = struct { bytes: []const u8, index: u64, integer: i64, codepoint: u32 };
    const cases = [_]Input{
        .{ .bytes = &.{ 0, 0, 2 }, .index = 0, .integer = std.math.minInt(i64), .codepoint = 0x10ffff },
        .{ .bytes = &.{ 42, 0, 11 }, .index = 1, .integer = -1, .codepoint = 0xe9 },
        .{ .bytes = &.{ 43, 0, 9 }, .index = 2, .integer = 0, .codepoint = 0x20ac },
        .{ .bytes = &.{ 255, 1, 8 }, .index = std.math.maxInt(u64), .integer = std.math.maxInt(i64), .codepoint = 65 },
    };
    for (cases) |case| {
        const input_bytes = try projection.encode(Input, a, case);
        defer a.free(input_bytes);
        try support.expectNativeCuts(&core, image, input_bytes, 60);
    }
}
