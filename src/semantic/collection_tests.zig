const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const Author = @import("author.zig").Author;
const a = std.testing.allocator;
const support = @import("test_support.zig");

fn image(comptime zero_width: bool) ![]u8 {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const element = if (zero_width) e.unit else e.integer;
    const sequence = try b.schema(.{ .seq = element });
    const optional = try b.schema(.{ .sum = &.{ e.unit, element } });
    const popped_pair = try b.schema(.{ .product = &.{ element, sequence } });
    const popped = try b.schema(.{ .sum = &.{ e.unit, popped_pair } });
    const last = try b.schema(.{ .product = &.{ sequence, optional } });
    const output = if (zero_width) try b.schema(.{ .product = &.{
        e.integer, optional, sequence, popped, last,
    } }) else try b.schema(.{ .product = &.{
        e.integer, optional, sequence, sequence, sequence, sequence, popped, last,
    } });
    const entry = try b.declare(&.{ sequence, e.integer }, output, &.{}, &.{});
    const input = try e.param(entry, 0);
    const index = try e.param(entry, 1);
    const length = try b.primitive(e.integer, .sequence_length, &.{input}, 0);
    const get = try b.primitive(optional, .sequence_get, &.{ input, index }, 0);
    const pop = try b.primitive(popped, .sequence_pop, &.{input}, 0);
    const pop_last = try b.primitive(last, .sequence_pop_last, &.{input}, 0);
    if (zero_width) {
        const take = try b.primitive(sequence, .sequence_take, &.{ input, index }, 0);
        try b.define(entry, try b.pure(try e.tuple(
            output,
            &.{ length, get, take, pop, pop_last },
        )));
    } else {
        const append = try b.primitive(
            sequence,
            .sequence_append,
            &.{ input, try b.constant(u64, 99) },
            0,
        );
        const concat = try b.primitive(sequence, .sequence_concat, &.{ append, input }, 0);
        const set = try e.checked(sequence, .sequence_set, &.{
            concat, e.zero, try b.constant(u64, 41),
        }, &.{.invalid_index});
        const take = try b.primitive(sequence, .sequence_take, &.{ set, index }, 0);
        try b.define(entry, try b.pure(try e.tuple(output, &.{
            length, get, append, concat, set, take, pop, pop_last,
        })));
    }
    return support.encode(b.module(entry, e.unit));
}

test "authored collection operations match native cuts for empty present and missing elements" {
    var core = try support.prepareCore();
    defer core.deinit();
    const guest = try image(false);
    defer a.free(guest);
    const Input = struct { values: []const u64, index: u64 };
    for ([_][]const u64{ &.{}, &.{7}, &.{ 3, 5, 8 } }) |values| {
        for ([_]u64{ 0, 1, std.math.maxInt(u64) }) |index| {
            const input = try projection.encode(Input, a, .{ .values = values, .index = index });
            defer a.free(input);
            try support.expectNativeCuts(&core, guest, input, 40);
        }
    }
}

test "authored collection operations retain maximum logical zero width cardinality" {
    var core = try support.prepareCore();
    defer core.deinit();
    const guest = try image(true);
    defer a.free(guest);
    for ([_]u64{ 0, 1, std.math.maxInt(u64) - 1, std.math.maxInt(u64) }) |index| {
        var input: [18]u8 = undefined;
        var writer: data.wire.Writer = .{ .output = &input };
        try writer.natural(std.math.maxInt(u64));
        try writer.fixed(u64, index);
        try support.expectNativeCuts(&core, guest, input[0..writer.position], 30);
    }
}
