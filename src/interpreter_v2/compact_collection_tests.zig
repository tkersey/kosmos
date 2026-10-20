const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const g = data.graph;
const Values = @import("values.zig").Values;
const Store = @import("store.zig").Store;
const maximum = std.math.maxInt(u64);

test "encoded sequence cursors avoid rebuilding progressively shorter tails" {
    const schemas = [_]p.Schema{
        .unit,         .u64,
        .{ .seq = 1 },
        .{ .product = &.{
            1,
            2,
        } },
        .{ .sum = &.{
            0,
            3,
        } },
    };
    for ([_]usize{ 16, 64, 256, 1024 }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const encoded = try a.alloc(u8, count * 8 + 10);
        var writer: data.wire.Writer = .{ .output = encoded };
        try writer.natural(count);
        for (0..count) |i| try writer.fixed(u64, i);
        var statistics: @import("store.zig").Statistics = .{};
        var store: Store = .{ .allocator = std.testing.allocator, .statistics = &statistics };
        defer store.deinit();
        var values: Values = .{ .allocator = a, .schemas = &schemas, .store = &store };
        var queue = try store.literal(&schemas, .{
            .schema = 2,
            .bytes = encoded[0..writer.position],
        });
        const root = try store.add(.{ .environment = .{ .values = &.{queue}, .tail = null } });
        for (0..count) |i| {
            const slots: []const g.Value = &.{queue};
            const result = try values.evaluate(.{
                .opcode = .sequence_pop,
                .destination = 0,
                .operands = &.{0},
            }, 4, slots);
            const optional = try values.split(result);
            try std.testing.expectEqual(1, optional.tag);
            const pair = try values.split(optional.fields[0]);
            try std.testing.expectEqual(i, std.mem.readInt(
                u64,
                pair.fields[0].body.scalar[0..8],
                .little,
            ));
            queue = pair.fields[1];
            try store.replace(root, .{ .environment = .{ .values = &.{queue}, .tail = null } });
            try store.collect(.{ .current = root });
            var retained: usize = 0;
            for (store.blobs.items, store.blob_alive.items) |blob, alive| if (alive) {
                retained += blob.bytes.len;
            };
            try std.testing.expect(retained <= 4 * ((count - i - 1) * 8 + 10));
        }
        try std.testing.expectEqualSlices(u8, &.{0}, try values.bytes(&queue));
        try std.testing.expect(statistics.owned_blob_bytes <= 32 * count);
        std.debug.print("encoded queue elements={d} constructed_bytes={d}\n", .{
            count, statistics.owned_blob_bytes,
        });
    }
}

test "consuming structured queues preserves order and measures descriptor copying" {
    const schemas = [_]p.Schema{ .unit, .u64, .{
        .internal = .{ .abstract_resource = 0 },
    }, .{ .seq = 2 }, .{ .product = &.{ 2, 3 } }, .{ .sum = &.{ 0, 4 } } };
    for ([_]usize{ 16, 64, 256 }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var statistics: @import("store.zig").Statistics = .{};
        var store: Store = .{ .allocator = std.testing.allocator, .statistics = &statistics };
        defer store.deinit();
        var values: Values = .{ .allocator = a, .schemas = &schemas, .store = &store };
        const fields = try a.alloc(g.Value, count);
        for (fields, 0..) |*value, index| {
            const ref = try store.add(.{ .resource = .{
                .schema = 2,
                .value = Values.natural(1, index),
            } });
            value.* = .{ .schema = 2, .body = .{ .owned = .{ .node = ref } } };
        }
        var queue = try values.aggregate(3, .{ .fields = fields });
        const root = try store.add(.{ .environment = .{ .values = &.{queue}, .tail = null } });
        for (0..count) |index| {
            const slots: []const g.Value = &.{queue};
            const popped = try values.evaluate(.{
                .opcode = .sequence_pop,
                .destination = 0,
                .operands = &.{0},
            }, 5, slots);
            const optional = try values.split(popped);
            try std.testing.expectEqual(1, optional.tag);
            const pair = try values.split(optional.fields[0]);
            const resource = (try store.get(pair.fields[0].body.owned.node)).resource;
            try std.testing.expectEqual(index, std.mem.readInt(
                u64,
                resource.value.body.scalar[0..8],
                .little,
            ));
            queue = pair.fields[1];
            try store.replace(root, .{ .environment = .{ .values = &.{queue}, .tail = null } });
            try store.collect(.{ .current = root });
            try std.testing.expect(store.shared_field_values <= 4 * (count - index - 1));
        }
        try std.testing.expect(statistics.aggregate_field_copies <= 6 * count);
        try std.testing.expectEqual(0, store.shared_field_values);
        try std.testing.expectEqual(0, (try values.split(queue)).fields.len);
        std.debug.print("queue elements={d} field_copies={d}\n", .{
            count, statistics.aggregate_field_copies,
        });
    }
}

test "immutable construction measures the second output copy" {
    const schemas = [_]p.Schema{ .bytes, .u64, .{ .product = &.{ 0, 1 } } };
    for ([_]usize{ 0, 1024, 1 << 20 }) |size| {
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const input = try a.alloc(u8, size + 16);
        var writer: data.wire.Writer = .{ .output = input };
        try writer.natural(size);
        const payload = try a.alloc(u8, size);
        @memset(payload, 0xa7);
        try writer.put(payload);
        var store: Store = .{ .allocator = std.testing.allocator };
        defer store.deinit();
        const value = try store.literal(&schemas, .{
            .schema = 0,
            .bytes = input[0..writer.position],
        });
        var statistics: @import("store.zig").Statistics = .{};
        store.statistics = &statistics;
        var values: Values = .{ .allocator = a, .schemas = &schemas, .store = &store };
        var result = try values.aggregate(2, .{ .fields = &.{ value, Values.natural(1, 42) } });
        const encoded = try values.bytes(&result);
        try std.testing.expectEqualSlices(
            u8,
            input[0..writer.position],
            encoded[0..writer.position],
        );
        try std.testing.expectEqual(42, std.mem.readInt(
            u64,
            encoded[writer.position..][0..8],
            .little,
        ));
        try std.testing.expectEqual(0, statistics.copied_blob_bytes);
        std.debug.print("aggregate payload={d} second_copy={d}\n", .{
            size, statistics.copied_blob_bytes,
        });
    }
}

test "admitted tag and field probes measure unrelated payload materialization" {
    const schemas = [_]p.Schema{
        .u64, .bytes, .unit,
        .{ .product = &.{
            0,
            1,
        } },
        .{ .product = &.{
            1,
            0,
        } },
        .{ .sum = &.{
            1,
            2,
        } },
    };
    for ([_]usize{ 0, 1024, 1 << 20 }) |size| {
        const payload = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(payload);
        @memset(payload, 0xa7);
        var copies: [4]u64 = undefined;
        for (0..4) |mode| {
            copies[mode] = try measureAdmittedProbe(&schemas, payload, mode);
        }
        std.debug.print("projection payload={d} copied={any}\n", .{ size, copies });
    }
}

test "a projected blob survives collection of its containing product" {
    const schemas = [_]p.Schema{ .bytes, .{ .product = &.{ 0, 0 } } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store: Store = .{ .allocator = std.testing.allocator };
    defer store.deinit();
    const facts = try data.admission.schemas(a, &schemas);
    const literal: p.Literal = .{ .schema = 1, .bytes = &.{
        3, 'a', 'b', 'c', 4, 'd', 'e', 'f', 'g',
    } };
    try data.admission.value(a, &schemas, facts, literal);
    const parent = try store.literal(&schemas, literal);
    var values: Values = .{ .allocator = a, .schemas = &schemas, .store = &store, .facts = facts };
    const slots: []const g.Value = &.{parent};
    var selected = try values.evaluate(.{
        .opcode = .field,
        .destination = 0,
        .operands = &.{0},
        .immediate = 1,
    }, 0, slots);
    const holder = try store.add(.{ .environment = .{ .values = &.{selected}, .tail = null } });
    try store.collect(.{ .current = holder });
    try std.testing.expect(!store.blob_alive.items[@intCast(parent.body.blob.id)]);
    try std.testing.expectEqualSlices(u8, &.{ 4, 'd', 'e', 'f', 'g' }, try values.bytes(&selected));
}

fn evaluate(v: *Values, opcode: p.Opcode, result: p.Id, args: []const g.Value) !g.Value {
    var operands: [3]p.Id = undefined;
    for (args, 0..) |_, index| operands[index] = index;
    const value = try v.evaluate(.{
        .opcode = opcode,
        .destination = 0,
        .operands = operands[0..args.len],
    }, result, args);
    const facts = try data.admission.schemas(v.allocator, v.schemas);
    try data.admission.value(v.allocator, v.schemas, facts, .{
        .schema = result,
        .bytes = try v.bytes(&value),
    });
    return value;
}

fn expectCount(v: *Values, value: g.Value, count: u64) !void {
    var expected: [10]u8 = undefined;
    var writer: data.wire.Writer = .{ .output = &expected };
    if (v.schemas[@intCast(value.schema)] != .array) try writer.natural(count);
    try std.testing.expectEqualSlices(u8, expected[0..writer.position], try v.bytes(&value));
}

fn checkCollection(v: *Values, count: u64) !void {
    var buffer: [10]u8 = undefined;
    var writer: data.wire.Writer = .{ .output = &buffer };
    const array = v.schemas[1] == .array;
    if (!array) try writer.natural(count);
    const literal: p.Literal = .{ .schema = 1, .bytes = buffer[0..writer.position] };
    const facts = try data.admission.schemas(v.allocator, v.schemas);
    try data.admission.value(v.allocator, v.schemas, facts, literal);
    const items = try v.store.literal(v.schemas, literal);
    const unit = try v.store.literal(v.schemas, .{ .schema = 0, .bytes = &.{} });
    const length = try evaluate(v, .sequence_length, 3, &.{items});
    try std.testing.expectEqual(count, std.mem.readInt(u64, length.body.scalar[0..8], .little));
    const absent = try evaluate(v, .sequence_get, 4, &.{ items, Values.natural(3, count) });
    try std.testing.expectEqualSlices(u8, &.{0}, try v.bytes(&absent));
    if (count != 0) {
        const index = Values.natural(3, count - 1);
        const found = try evaluate(v, .sequence_get, 4, &.{ items, index });
        try std.testing.expectEqualSlices(u8, &.{1}, try v.bytes(&found));
        try expectCount(v, try evaluate(v, .sequence_set, 1, &.{ items, index, unit }), count);
    }
    try std.testing.expectError(error.ElementIndex, evaluate(v, .sequence_set, 1, &.{
        items, Values.natural(3, count), unit,
    }));
    if (array) return;
    try expectCount(v, try evaluate(
        v,
        .sequence_take,
        1,
        &.{ items, Values.natural(3, 3) },
    ), @min(count, 3));
    const empty = try v.store.literal(v.schemas, .{ .schema = 1, .bytes = &.{0} });
    try expectCount(v, try evaluate(v, .sequence_concat, 1, &.{ items, empty }), count);
    if (count == maximum) {
        const err = if (v.schemas[1] == .vector)
            error.CollectionCapacity
        else
            error.InvalidLength;
        try std.testing.expectError(err, evaluate(v, .sequence_append, 1, &.{ items, unit }));
    } else try expectCount(v, try evaluate(v, .sequence_append, 1, &.{ items, unit }), count + 1);
    const popped = try evaluate(v, .sequence_pop, 6, &.{items});
    const selected = try v.split(popped);
    try std.testing.expectEqual(@as(u64, @intFromBool(count != 0)), selected.tag);
    if (count != 0) try expectCount(v, (try v.split(selected.fields[0])).fields[1], count - 1);
    const last = try v.split(try evaluate(v, .sequence_pop_last, 7, &.{items}));
    try expectCount(v, last.fields[0], if (count == 0) 0 else count - 1);
    try std.testing.expectEqualSlices(
        u8,
        &.{@intFromBool(count != 0)},
        try v.bytes(&last.fields[1]),
    );
}

test "zero-width collection operations preserve full cardinality in fixed storage" {
    for ([_]u64{ 0, 1, 1 << 32, 768614336404564650, maximum }) |count| {
        for (0..3) |kind| for (0..3) |element| {
            var buffer: [65536]u8 = undefined;
            var fixed = std.heap.FixedBufferAllocator.init(&buffer);
            var arena = std.heap.ArenaAllocator.init(fixed.allocator());
            defer arena.deinit();
            const allocator = arena.allocator();
            const schemas = [_]p.Schema{
                switch (element) {
                    0 => .unit,
                    1 => .{ .product = &.{ 2, 2 } },
                    else => .{ .array = .{ .element = 2, .length = 17 } },
                },
                switch (kind) {
                    0 => .{ .seq = 0 },
                    1 => .{ .vector = .{ .element = 0, .maximum = maximum } },
                    else => .{ .array = .{ .element = 0, .length = count } },
                },
                .unit,
                .u64,
                .{ .sum = &.{ 2, 0 } },
                .{ .product = &.{ 0, 1 } },
                .{ .sum = &.{ 2, 5 } },
                .{ .product = &.{ 1, 4 } },
            };

            var store: Store = .{ .allocator = allocator };
            defer store.deinit();
            var values: Values = .{ .allocator = allocator, .schemas = &schemas, .store = &store };
            try checkCollection(&values, count);
        };
    }
}

test "encoded collection slices preserve variable-width elements and their order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schemas: []const p.Schema = &.{
        .bytes, .{ .seq = 0 }, .unit, .u64,
        .{ .sum = &.{
            2,
            0,
        } },
        .{ .product = &.{
            0,
            1,
        } },
        .{ .sum = &.{
            2,
            5,
        } },
        .{ .product = &.{
            1,
            4,
        } },
    };
    var store: Store = .{ .allocator = allocator };
    defer store.deinit();
    var v: Values = .{ .allocator = allocator, .schemas = schemas, .store = &store };
    const items = try store.literal(schemas, .{
        .schema = 1,
        .bytes = &.{ 3, 1, 'a', 0, 2, 'b', 'c' },
    });
    const other = try store.literal(schemas, .{ .schema = 1, .bytes = &.{ 1, 1, 'x' } });
    const replacement = try store.literal(schemas, .{ .schema = 0, .bytes = &.{ 2, 'd', 'e' } });
    const index = Values.natural(3, 1);
    const got = try evaluate(&v, .sequence_get, 4, &.{ items, index });
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, try v.bytes(&got));
    const set = try evaluate(&v, .sequence_set, 1, &.{ items, index, replacement });
    try std.testing.expectEqualSlices(u8, &.{
        3, 1, 'a', 2, 'd', 'e', 2, 'b', 'c',
    }, try v.bytes(&set));
    const joined = try evaluate(&v, .sequence_concat, 1, &.{ items, other });
    try std.testing.expectEqualSlices(u8, &.{
        4, 1, 'a', 0, 2, 'b', 'c', 1, 'x',
    }, try v.bytes(&joined));
    const prefix = try evaluate(&v, .sequence_take, 1, &.{ items, Values.natural(3, 2) });
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 'a', 0 }, try v.bytes(&prefix));
    const front = try evaluate(&v, .sequence_pop, 6, &.{items});
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 'a', 2, 0, 2, 'b', 'c' }, try v.bytes(&front));
    const back = try evaluate(&v, .sequence_pop_last, 7, &.{items});
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 'a', 0, 1, 2, 'b', 'c' }, try v.bytes(&back));
}

test "sequence get consumes one exact-view bounds proof without rechecking its slice" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const schemas = [_]p.Schema{ .unit, .{
        .vector = .{ .element = 2, .maximum = 16 },
    }, .u64, .{ .sum = &.{ 0, 2 } } };
    var statistics: @import("store.zig").Statistics = .{};
    var store: Store = .{ .allocator = allocator, .statistics = &statistics };
    defer store.deinit();
    var values: Values = .{ .allocator = arena.allocator(), .schemas = &schemas, .store = &store };
    const items = try store.literal(&schemas, .{ .schema = 1, .bytes = &.{
        2, 7, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0,
    } });
    for ([_]u64{ 0, 1, 2, 15, maximum }) |index| {
        const before_index = statistics.collection_index_checks;
        const before_range = statistics.collection_range_checks;
        const result = try evaluate(
            &values,
            .sequence_get,
            3,
            &.{ items, Values.natural(2, index) },
        );
        const bytes = try values.bytes(&result);
        try std.testing.expectEqual(@as(u8, if (index < 2) 1 else 0), bytes[0]);
        if (index < 2) try std.testing.expectEqual(
            @as(u64, if (index == 0) 7 else 9),
            std.mem.readInt(u64, bytes[1..9], .little),
        );
        try std.testing.expectEqual(before_index + 1, statistics.collection_index_checks);
        try std.testing.expectEqual(before_range, statistics.collection_range_checks);
    }
}

test "checked element proof handles maximum zero-width cardinality and actual length" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const schemas = [_]p.Schema{ .unit, .{ .seq = 0 }, .u64, .{ .sum = &.{ 0, 0 } } };
    var statistics: @import("store.zig").Statistics = .{};
    var store: Store = .{ .allocator = allocator, .statistics = &statistics };
    defer store.deinit();
    var values: Values = .{ .allocator = arena.allocator(), .schemas = &schemas, .store = &store };
    var encoded: [10]u8 = undefined;
    var writer: data.wire.Writer = .{ .output = &encoded };
    try writer.natural(maximum);
    const items = try store.literal(&schemas, .{
        .schema = 1,
        .bytes = encoded[0..writer.position],
    });
    const found = try evaluate(&values, .sequence_get, 3, &.{
        items, Values.natural(2, maximum - 1),
    });
    try std.testing.expectEqualSlices(u8, &.{1}, try values.bytes(&found));
    const absent = try evaluate(&values, .sequence_get, 3, &.{ items, Values.natural(2, maximum) });
    try std.testing.expectEqualSlices(u8, &.{0}, try values.bytes(&absent));
    try std.testing.expectEqual(@as(u64, 2), statistics.collection_index_checks);
    try std.testing.expectEqual(@as(u64, 0), statistics.collection_range_checks);
}

test "a shorter vector written through a cell alias invalidates the previous access bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schemas = [_]p.Schema{ .unit, .{
        .vector = .{ .element = 0, .maximum = 16 },
    }, .u64, .{ .sum = &.{ 0, 0 } } };
    var statistics: @import("store.zig").Statistics = .{};
    var store: Store = .{ .allocator = std.testing.allocator, .statistics = &statistics };
    defer store.deinit();
    var values: Values = .{ .allocator = arena.allocator(), .schemas = &schemas, .store = &store };
    const longer = try store.literal(&schemas, .{ .schema = 1, .bytes = &.{2} });
    const shorter = try store.literal(&schemas, .{ .schema = 1, .bytes = &.{1} });
    const region = try store.add(.{ .region = .{
        .descriptor = 0,
        .outer = null,
        .obligations = &.{},
    } });
    const cell = try store.add(.{ .cell = .{ .schema = 1, .region = region, .value = longer } });
    const alias = cell;
    const snapshot = (try store.get(cell)).cell.value.?;
    const index = Values.natural(2, 1);
    const before = try evaluate(&values, .sequence_get, 3, &.{ snapshot, index });
    try std.testing.expectEqualSlices(u8, &.{1}, try values.bytes(&before));
    var changed = (try store.get(alias)).cell;
    changed.value = shorter;
    try store.replace(alias, .{ .cell = changed });
    const current = (try store.get(cell)).cell.value.?;
    const after = try evaluate(&values, .sequence_get, 3, &.{ current, index });
    try std.testing.expectEqualSlices(u8, &.{0}, try values.bytes(&after));
    const retained = try evaluate(&values, .sequence_get, 3, &.{ snapshot, index });
    try std.testing.expectEqualSlices(u8, &.{1}, try values.bytes(&retained));
    try std.testing.expectEqual(@as(u64, 3), statistics.collection_index_checks);
    try std.testing.expectEqual(@as(u64, 0), statistics.collection_range_checks);
}

fn measureAdmittedProbe(schemas: []const p.Schema, payload: []const u8, mode: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store: Store = .{ .allocator = std.testing.allocator };
    defer store.deinit();
    const facts = try data.admission.schemas(a, schemas);
    const encoded = try a.alloc(u8, payload.len + 32);
    var writer: data.wire.Writer = .{ .output = encoded };
    if (mode >= 2) try writer.natural(0);
    if (mode == 0) try writer.fixed(u64, 42);
    try writer.natural(payload.len);
    try writer.put(payload);
    if (mode == 1) try writer.fixed(u64, 42);
    const literal: p.Literal = .{
        .schema = if (mode < 2) 3 + mode else 5,
        .bytes = encoded[0..writer.position],
    };
    try data.admission.value(a, schemas, facts, literal);
    const value = try store.literal(schemas, literal);
    var statistics: @import("store.zig").Statistics = .{};
    store.statistics = &statistics;
    var values: Values = .{
        .allocator = a,
        .schemas = schemas,
        .store = &store,
        .facts = facts,
    };
    const result_type: p.Id = if (mode == 3) 2 else 0;
    const instruction: data.activation.Instruction = .{
        .opcode = if (mode < 2) .field else if (mode == 2)
            .variant_tag
        else
            .variant_payload,
        .destination = 0,
        .operands = &.{0},
        .immediate = if (mode == 1 or mode == 3) 1 else 0,
    };
    const slots: []const g.Value = &.{value};
    if (mode == 3) {
        try std.testing.expectError(
            error.WrongVariant,
            values.evaluate(instruction, result_type, slots),
        );
    } else {
        const result = try values.evaluate(instruction, result_type, slots);
        try std.testing.expectEqual(@as(u64, if (mode < 2) 42 else 0), std.mem.readInt(
            u64,
            result.body.scalar[0..8],
            .little,
        ));
    }
    try std.testing.expectEqual(0, statistics.copied_blob_bytes);
    return statistics.copied_blob_bytes;
}
