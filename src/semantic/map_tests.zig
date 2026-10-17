const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const maps = @import("map.zig");
const Author = @import("author.zig").Author;
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");
const Entry = struct { key: u64, value: u64 };
const Input = struct { entries: []const Entry, key: u64, value: u64, remove: u64 };
const Result = struct { prior: ?u64, updated: ?u64, original: ?u64, entries: []const Entry, valid: bool };

fn prepare(b: *source.Builder, entry: data.program.Id) !base.Prepared {
    return support.prepare(b.module(entry, try b.scalar(void)));
}

test "portable sparse map updates preserve all numeric key bits and old versions" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const d = try maps.define(&b, e.integer);
    const output = try projection.schema(Result, &b);
    const entry = try b.declare(&.{ d.entries, e.integer, e.integer, e.integer }, output, &.{}, &.{});
    const old = try b.variable(d.tree);
    const changed = try b.variable(d.tree);
    const removed = try b.variable(d.tree);
    const prior = try b.variable(d.optional);
    const updated = try b.variable(d.optional);
    const original = try b.variable(d.optional);
    const entries = try b.variable(d.entries);
    const valid = try b.variable(e.boolean);
    const key = try e.param(entry, 1);
    var body = try b.pure(try e.tuple(output, &.{ try b.reference(prior), try b.reference(updated), try b.reference(original), try b.reference(entries), try b.reference(valid) }));
    body = try b.bind(valid, try e.call(d.valid, &.{try b.reference(removed)}), body);
    body = try b.bind(entries, try e.call(d.to_sequence, &.{try b.reference(removed)}), body);
    body = try b.bind(original, try e.call(d.get, &.{ try b.reference(old), key }), body);
    body = try b.bind(updated, try e.call(d.get, &.{ try b.reference(changed), key }), body);
    body = try b.bind(prior, try e.call(d.get, &.{ try b.reference(old), key }), body);
    body = try b.bind(removed, try e.call(d.remove, &.{ try b.reference(changed), try e.param(entry, 3) }), body);
    body = try b.bind(changed, try e.call(d.set, &.{ try b.reference(old), key, try e.param(entry, 2) }), body);
    body = try b.bind(old, try e.call(d.from_sequence, &.{try e.param(entry, 0)}), try b.term(.{ .yield_then = body }));
    try b.define(entry, body);
    var prepared = try prepare(&b, entry);
    defer prepared.deinit();
    const keys = [_]u64{ 0, 1, 2, 3, 7, 8, 15, 16, 63, 64, 1 << 32, 1 << 63, std.math.maxInt(u64) };
    var input_entries: [keys.len]Entry = undefined;
    for (0..keys.len + 1) |count| for (keys, 0..) |key_value, round| {
        for (input_entries[0..count], 0..) |*value, i| {
            value.* = .{ .key = keys[(i * 5 + round) % keys.len], .value = i + 19 };
        }
        const remove = keys[(round * 3) % keys.len];
        const input: Input = .{ .entries = input_entries[0..count], .key = key_value, .value = 999, .remove = remove };
        const bytes = try projection.encode(Input, a, input);
        defer a.free(bytes);
        var session = try base.Session.start(a, &prepared, bytes, .{});
        defer session.deinit();
        try std.testing.expect(try session.run(null) == .yielded);
        const checkpoint = try session.checkpoint(a);
        defer a.free(checkpoint);
        var restored = try base.Session.restore(a, &prepared, checkpoint, .{});
        defer restored.deinit();
        try restored.resumeYield();
        const outcome = try restored.run(null);
        try std.testing.expect(outcome == .completed);
        var result = try projection.decode(Result, a, try restored.bytes(&outcome.completed));
        defer result.deinit();
        var expected: std.AutoHashMap(u64, u64) = .init(a);
        defer expected.deinit();
        for (input.entries) |value| try expected.put(value.key, value.value);
        try std.testing.expectEqual(expected.get(key_value), result.value.prior);
        try std.testing.expectEqual(result.value.prior, result.value.original);
        try std.testing.expectEqual(@as(?u64, 999), result.value.updated);
        try expected.put(key_value, 999);
        _ = expected.remove(remove);
        try std.testing.expectEqual(expected.count(), result.value.entries.len);
        var previous: ?u64 = null;
        for (result.value.entries) |value| {
            if (previous) |last| try std.testing.expect(last < value.key);
            try std.testing.expectEqual(expected.get(value.key), @as(?u64, value.value));
            previous = value.key;
        }
        try std.testing.expect(result.value.valid);
    };
}

test "portable sparse map rejects forged branch routing and prefixes" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const d = try maps.define(&b, try b.scalar(u64));
    var prepared = try prepare(&b, d.valid);
    defer prepared.deinit();
    const Leaf = union(enum) { nil: void, leaf: Entry };
    const Tree = union(enum) { nil: void, leaf: Entry, branch: struct { bit: u64, left: Leaf, right: Leaf } };
    const cases = .{
        .{ @as(u64, 1), @as(u64, 0), @as(u64, 1), true },
        .{ @as(u64, 1), @as(u64, 0), @as(u64, 5), false },
        .{ @as(u64, 2), @as(u64, 0), @as(u64, 1), false },
        .{ @as(u64, 3), @as(u64, 0), @as(u64, 3), false },
        .{ @as(u64, 1), @as(u64, 1), @as(u64, 0), false },
        .{ @as(u64, 1 << 63), @as(u64, 0), std.math.maxInt(u64), true },
    };
    inline for (cases) |case| {
        const input: Tree = .{ .branch = .{ .bit = case[0], .left = .{ .leaf = .{ .key = case[1], .value = 10 } }, .right = .{ .leaf = .{ .key = case[2], .value = 20 } } } };
        const bytes = try projection.encode(Tree, a, input);
        defer a.free(bytes);
        var session = try base.Session.start(a, &prepared, bytes, .{});
        defer session.deinit();
        const outcome = try session.run(null);
        try std.testing.expect(outcome == .completed);
        try std.testing.expectEqualSlices(u8, &.{@intFromBool(case[3])}, try session.bytes(&outcome.completed));
    }
}
