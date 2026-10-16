const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const kosmos = @import("../../test_oracle.zig");
const Author = @import("author.zig").Author;
const table = @import("table.zig");
const projection = @import("projection.zig");
const profile = @import("../base/profile.zig");
const a = std.testing.allocator;

const Input = struct { values: []const u64, index: u64, replacement: u64 };
const Result = struct { count: u64, original: ?u64, updated: ?u64, unchanged: ?u64 };

fn fixture(b: *source.Builder) !source.Module {
    const e = try Author.init(b);
    const d = try table.define(b, e.integer);
    const sequence = try b.schema(.{ .seq = e.integer });
    const output = try projection.schema(Result, b);
    const fill = try b.declare(&.{ sequence, e.integer, d.table }, d.table, &.{}, &.{});
    const main = try b.declare(&.{ sequence, e.integer, e.integer }, output, &.{}, &.{});
    {
        const values = try e.param(fill, 0);
        const offset = try e.param(fill, 1);
        const prior = try e.param(fill, 2);
        const missing = try b.variable(e.unit);
        const element = try b.variable(e.integer);
        const next = try b.variable(d.table);
        try b.define(fill, try b.term(.{ .match_sum = .{
            .value = try b.primitive(d.optional, .sequence_get, &.{ values, offset }, 0),
            .cases = &.{
                .{ .variable = missing, .body = try b.pure(prior) },
                .{ .variable = element, .body = try b.bind(next, try e.call(d.append, &.{ prior, try b.reference(element) }), try e.call(fill, &.{ values, try e.binary(.integer_add, offset, e.one), try b.reference(next) })) },
            },
        } }));
    }
    const original = try b.variable(d.table);
    const changed = try b.variable(d.table);
    const before = try b.variable(d.optional);
    const after = try b.variable(d.optional);
    const unchanged = try b.variable(d.optional);
    const original_ref = try b.reference(original);
    const index = try e.param(main, 1);
    const result = try b.pure(try e.tuple(output, &.{ try e.field(original_ref, 0), try b.reference(before), try b.reference(after), try b.reference(unchanged) }));
    const read_original_again = try b.bind(unchanged, try e.call(d.get, &.{ original_ref, index }), result);
    const read_changed = try b.bind(after, try e.call(d.get, &.{ try b.reference(changed), index }), read_original_again);
    const update = try b.bind(changed, try e.call(d.set, &.{ original_ref, index, try e.param(main, 2) }), read_changed);
    // Empty/out-of-range lookup is legitimate; no update is attempted there.
    const missing = try b.variable(e.unit);
    const found = try b.variable(e.integer);
    const missing_result = try b.pure(try e.tuple(output, &.{ try e.field(original_ref, 0), try b.reference(before), try b.reference(before), try b.reference(before) }));
    const inspect = try b.bind(before, try e.call(d.get, &.{ original_ref, index }), try b.term(.{ .match_sum = .{
        .value = try b.reference(before),
        .cases = &.{ .{ .variable = missing, .body = missing_result }, .{ .variable = found, .body = update } },
    } }));
    const valid = try b.variable(e.boolean);
    const validated = try b.bind(valid, try e.call(d.valid, &.{original_ref}), try e.when(try b.reference(valid), inspect, try e.fail()));
    try b.define(main, try b.bind(original, try e.call(fill, &.{ try e.param(main, 0), e.zero, try d.empty(b) }), try b.term(.{ .yield_then = validated })));
    return b.module(main, e.unit);
}

test "authored table validator rejects well-typed forged sizes and forest order" {
    try forged(kosmos.Session);
    try forged(Base);
}
fn forged(comptime Engine: type) !void {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const d = try table.define(&b, e.integer);
    var compiled = try source.lower(a, b.module(d.valid, e.unit));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    _ = try profile.check(admitted, .{});
    const Leaf = union(enum) { leaf: u64 };
    const Tree = union(enum) { leaf: u64, branch: struct { left: Leaf, right: Leaf, size: u64 } };
    const Nil = union(enum) { nil: void };
    const Value = struct { count: u64, forest: union(enum) { nil: void, cons: struct { head: Tree, tail: Nil } } };
    for ([_]u64{ 0, 1, 2, 3, 4, std.math.maxInt(u64) }) |count| {
        for ([_]u64{ 0, 1, 2, 3, 4, std.math.maxInt(u64) }) |size| {
            const bytes = try projection.encode(Value, a, .{ .count = count, .forest = .{ .cons = .{
                .head = .{ .branch = .{ .left = .{ .leaf = 10 }, .right = .{ .leaf = 20 }, .size = size } },
                .tail = .nil,
            } } });
            defer a.free(bytes);
            var session = try Engine.initImage(a, image, bytes);
            defer session.deinit();
            const result = try session.run(null);
            try std.testing.expect(result == .completed);
            try std.testing.expectEqualSlices(u8, &.{@intFromBool(count == 2 and size == 2)}, try session.bytes(&result.completed));
        }
    }
    // Correct total cardinality cannot justify duplicate adjacent chunk sizes.
    var buffer: [32]u8 = undefined;
    var writer: data.wire.Writer = .{ .output = &buffer };
    try writer.fixed(u64, 2);
    for ([_]u64{ 10, 20 }) |value| {
        try writer.natural(1); // cons
        try writer.natural(0); // leaf
        try writer.fixed(u64, value);
    }
    try writer.natural(0); // nil
    var session = try Engine.initImage(a, image, buffer[0..writer.position]);
    defer session.deinit();
    const result = try session.run(null);
    try std.testing.expect(result == .completed);
    try std.testing.expectEqualSlices(u8, &.{0}, try session.bytes(&result.completed));
}

test "authored persistent table preserves numeric IDs and old roots through restore" {
    try persistence(kosmos.Session);
    try persistence(Base);
}
fn persistence(comptime Engine: type) !void {
    var b = source.Builder.init(a);
    defer b.deinit();
    var diagnostic: source.Diagnostic = .{};
    var compiled = source.lowerObserved(a, try fixture(&b), .{ .diagnostic = &diagnostic }) catch |err| {
        std.debug.print("table compilation: {any}\n", .{diagnostic});
        return err;
    };
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(bytes);
    const image = try compiled.encode(a, bytes);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const report = try profile.check(admitted, .{});
    try std.testing.expect(report.opcodes.contains(.variant));
    try std.testing.expect(report.terminators.contains(.call));
    var values: [65]u64 = undefined;
    for (&values, 0..) |*value, index| value.* = index * 17 + 9;
    // Every index in two nontrivial forests, including both sides of every
    // tree/forest boundary, and genuine empty/out-of-range lookups.
    for ([_]usize{ 0, 1, 2, 3, 7, 8, 9, 31, 32, 33, 64, 65 }) |count| {
        const indices = if (count == 33 or count == 65) count + 1 else @min(count + 1, 3);
        for (0..indices) |index| {
            const input = try projection.encode(Input, a, .{ .values = values[0..count], .index = index, .replacement = 987654321 });
            defer a.free(input);
            var session = try Engine.initImage(a, image, input);
            defer session.deinit();
            try std.testing.expect(try session.run(null) == .yielded);
            const checkpoint = try session.checkpoint(a);
            defer a.free(checkpoint);
            var restored = try Engine.restoreImage(a, image, checkpoint);
            defer restored.deinit();
            try restored.resumeYield();
            const outcome = try restored.run(null);
            try std.testing.expect(outcome == .completed);
            var result = try projection.decode(Result, a, try restored.bytes(&outcome.completed));
            defer result.deinit();
            const expected: ?u64 = if (index < count) values[index] else null;
            try std.testing.expectEqualDeep(Result{
                .count = count,
                .original = expected,
                .updated = if (expected != null) 987654321 else null,
                .unchanged = expected,
            }, result.value);
        }
    }
}

const Base = struct {
    const Session = @import("../base/session.zig").Session;
    fn initImage(allocator: std.mem.Allocator, image: []const u8, input: []const u8) !Session {
        return Session.initImage(allocator, image, input, .{});
    }
    fn restoreImage(allocator: std.mem.Allocator, image: []const u8, checkpoint: []const u8) !Session {
        return Session.restoreImage(allocator, image, checkpoint, .{});
    }
};

test "base table update copies a logarithmic path without encoding the table" {
    const Session = @import("../base/session.zig").Session;
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const d = try table.define(&b, e.integer);
    const main = try b.declare(&.{d.sequence}, d.table, &.{}, &.{});
    const saved = try b.variable(d.table);
    try b.define(main, try b.bind(saved, try e.call(d.from_sequence, &.{try e.param(main, 0)}), try b.term(.{ .yield_then = try e.call(d.set, &.{ try b.reference(saved), e.zero, try b.constant(u64, 12345) }) })));
    var compiled = try source.lower(a, b.module(main, e.unit));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    var inputs: [1024]u64 = undefined;
    for (&inputs, 0..) |*value, i| value.* = i;
    for ([_]usize{ 64, 256, 1024 }) |count| {
        const input = try projection.encode([]const u64, a, inputs[0..count]);
        defer a.free(input);
        var session = try Session.initImage(a, image, input, .{});
        defer session.deinit();
        try std.testing.expect(try session.run(null) == .yielded);
        var stats: @import("../interpreter_v2/store.zig").Statistics = .{};
        session.store.statistics = &stats;
        try session.resumeYield();
        try std.testing.expect(try session.run(null) == .completed);
        try std.testing.expectEqual(@as(u64, 0), stats.owned_blob_bytes);
        try std.testing.expect(stats.aggregate_field_copies <= 8 * @as(usize, std.math.log2_int(usize, count)) + 16);
        std.debug.print("base authored table count={d} update_field_copies={d} encoded_bytes={d}\n", .{ count, stats.aggregate_field_copies, stats.owned_blob_bytes });
    }
}
