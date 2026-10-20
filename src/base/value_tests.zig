const std = @import("std");
const data = @import("horos_data");
const Store = @import("../interpreter_v2/store.zig");
const Values = @import("../interpreter_v2/values.zig").Values;

test "admitted aggregate tails preserve exact recursive field and payload bytes" {
    const a = std.testing.allocator;
    const schemas: []const data.program.Schema = &.{
        .unit, .u64, .{ .sum = &.{ 0, 3 } }, .{ .product = &.{ 1, 2 } },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const facts = try data.admission.schemas(scratch, schemas);
    var store: Store.Store = .{ .allocator = a };
    defer store.deinit();
    var values: Values = .{
        .allocator = scratch,
        .schemas = schemas,
        .facts = facts,
        .store = &store,
        .aggregate_storage = .structured,
    };
    var encoded: [300 * 9 + 1]u8 = undefined;
    var writer: data.wire.Writer = .{ .output = &encoded };
    for (0..300) |i| {
        try writer.natural(1);
        try writer.fixed(u64, i);
    }
    try writer.natural(0);
    try data.admission.value(scratch, schemas, facts, .{ .schema = 2, .bytes = &encoded });
    var current = try store.literal(schemas, .{ .schema = 2, .bytes = &encoded });
    for (0..300) |i| {
        const variant = try values.split(current);
        try std.testing.expectEqual(1, variant.tag);
        const product = variant.fields[0];
        try std.testing.expectEqualSlices(u8, encoded[i * 9 + 1 ..], try values.bytes(&product));
        const fields = try values.split(product);
        try std.testing.expectEqualDeep(Values.natural(1, i), fields.fields[0]);
        current = try values.evaluate(.{
            .opcode = .field,
            .destination = 1,
            .immediate = 1,
            .operands = &.{0},
        }, 2, @as([]const data.graph.Value, &.{product}));
        try std.testing.expectEqualSlices(u8, encoded[(i + 1) * 9 ..], try values.bytes(&current));
        try std.testing.expectEqualDeep(fields.fields[1], current);
    }
    const terminal = try values.split(current);
    try std.testing.expectEqual(0, terminal.tag);
    try std.testing.expectEqualSlices(u8, &.{}, try values.bytes(&terminal.fields[0]));
    // Tail extraction is downstream of complete admission; malformed unused
    // data and trailing bytes never acquire this boundary guarantee.
    try std.testing.expectError(error.InvalidValue, data.admission.value(
        scratch,
        schemas,
        facts,
        .{ .schema = 2, .bytes = &.{2} },
    ));
    try std.testing.expectError(error.NonCanonical, data.admission.value(
        scratch,
        schemas,
        facts,
        .{ .schema = 2, .bytes = &.{ 0, 1 } },
    ));
}

test "immutable field memoization follows live source data and rejects rollback ID reuse" {
    const a = std.testing.allocator;
    const schemas: []const data.program.Schema = &.{ .u64, .{ .product = &.{ 0, 0 } } };
    var statistics: Store.Statistics = .{};
    var store: Store.Store = .{ .allocator = a, .statistics = &statistics };
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var values: Values = .{
        .allocator = arena.allocator(),
        .schemas = schemas,
        .store = &store,
        .aggregate_storage = .structured,
    };
    const instruction: data.activation.Instruction = .{
        .opcode = .field,
        .destination = 1,
        .immediate = 1,
        .operands = &.{0},
    };
    const original = try store.literal(schemas, .{
        .schema = 1,
        .bytes = &(std.mem.toBytes(@as(u64, 7)) ++ std.mem.toBytes(@as(u64, 41))),
    });
    const projected = try values.evaluate(instruction, 0, @as(
        []const data.graph.Value,
        &.{original},
    ));
    try std.testing.expectEqualDeep(Values.natural(0, 41), projected);
    try std.testing.expectEqualDeep(projected, try values.evaluate(instruction, 0, @as(
        []const data.graph.Value,
        &.{original},
    )));
    try std.testing.expectEqual(1, statistics.field_projection_hits);
    try std.testing.expectEqual(1, statistics.field_projection_scans);
    const root = try store.add(.{ .environment = .{ .values = &.{original}, .tail = null } });
    try store.collect(.{ .current = root });
    try std.testing.expectEqual(1, store.data_projections.count());
    try std.testing.expectEqualDeep(projected, try values.evaluate(instruction, 0, @as(
        []const data.graph.Value,
        &.{original},
    )));
    try checkProjectionReuse(&store, &values, instruction, original, projected);
}

fn checkProjectionReuse(
    store: *Store.Store,
    values: *Values,
    instruction: data.activation.Instruction,
    original: data.graph.Value,
    projected: data.graph.Value,
) !void {
    const schemas = values.schemas;
    try store.begin();
    try store.collect(.{});
    try std.testing.expectEqual(0, store.data_projections.count());
    const changed = try store.literal(schemas, .{
        .schema = 1,
        .bytes = &(std.mem.toBytes(@as(u64, 7)) ++ std.mem.toBytes(@as(u64, 99))),
    });
    try std.testing.expectEqual(original.body.blob.id, changed.body.blob.id);
    try std.testing.expectEqualDeep(Values.natural(0, 99), try values.evaluate(instruction, 0, @as(
        []const data.graph.Value,
        &.{changed},
    )));
    store.rollback();
    try std.testing.expectEqual(0, store.data_projections.count());
    try std.testing.expectEqualDeep(projected, try values.evaluate(instruction, 0, @as(
        []const data.graph.Value,
        &.{original},
    )));
    try store.collect(.{});
    const replaced = try store.literal(schemas, .{
        .schema = 1,
        .bytes = &(std.mem.toBytes(@as(u64, 7)) ++ std.mem.toBytes(@as(u64, 12))),
    });
    try std.testing.expectEqual(original.body.blob.id, replaced.body.blob.id);
    try std.testing.expectEqualDeep(Values.natural(0, 12), try values.evaluate(instruction, 0, @as(
        []const data.graph.Value,
        &.{replaced},
    )));
}

test "recursive aggregate storage shares construction and preserves materialized bytes" {
    const a = std.testing.allocator;
    const schemas: []const data.program.Schema = &.{
        .u64, .{ .sum = &.{ 0, 2 } }, .{ .product = &.{ 1, 1 } },
    };
    for ([_]usize{ 4, 8, 12 }) |depth| {
        var baseline: ?[]u8 = null;
        defer if (baseline) |bytes| a.free(bytes);
        inline for (.{ .encoded, .structured }) |storage| {
            var statistics: Store.Statistics = .{};
            var store: Store.Store = .{ .allocator = a, .statistics = &statistics };
            defer store.deinit();
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            var values: Values = .{
                .allocator = scratch.allocator(),
                .schemas = schemas,
                .store = &store,
                .aggregate_storage = storage,
            };
            var root = try values.aggregate(1, .{ .tag = 0, .fields = &.{Values.natural(0, 7)} });
            for (0..depth) |_| {
                const pair = try values.aggregate(2, .{ .fields = &.{ root, root } });
                root = try values.aggregate(1, .{ .tag = 1, .fields = &.{pair} });
            }
            const constructed = statistics;
            if (storage == .structured) {
                try std.testing.expectEqual(@as(u64, 0), constructed.owned_blob_bytes);
                try std.testing.expectEqual(
                    @as(u64, 1 + 3 * depth),
                    constructed.aggregate_field_copies,
                );
                try std.testing.expectEqual(@as(u64, 1 + 2 * depth), constructed.added_nodes);
            }
            const encoded = try values.bytes(&root);
            try std.testing.expectEqual(
                @as(usize, 10) * std.math.pow(usize, 2, depth) - 1,
                encoded.len,
            );
            if (storage == .encoded) {
                baseline = try a.dupe(u8, encoded);
            } else try std.testing.expectEqualSlices(u8, baseline.?, encoded);
            std.debug.print(
                "recursive aggregate {s} depth={d} constructed_blob_bytes={d} fie" ++
                    "ld_copies={d} final_bytes={d}\n",
                .{
                    @tagName(storage),
                    depth,
                    constructed.owned_blob_bytes,
                    constructed.aggregate_field_copies,
                    encoded.len,
                },
            );
        }
    }
}

fn retainedField(a: std.mem.Allocator) !void {
    const schemas: []const data.program.Schema = &.{
        .u64, .{ .product = &.{ 0, 0 } }, .{ .product = &.{ 1, 0 } },
    };
    var store: Store.Store = .{ .allocator = a };
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var values: Values = .{
        .allocator = arena.allocator(),
        .schemas = schemas,
        .store = &store,
        .aggregate_storage = .structured,
    };
    const bytes = std.mem.toBytes(@as(u64, 7)) ++
        std.mem.toBytes(@as(u64, 41)) ++ std.mem.toBytes(@as(u64, 99));
    const original = try store.literal(schemas, .{ .schema = 2, .bytes = &bytes });
    const projected = try values.evaluate(.{
        .opcode = .field,
        .destination = 1,
        .immediate = 0,
        .operands = &.{0},
    }, 1, @as([]const data.graph.Value, &.{original}));
    const leaf = try values.evaluate(.{
        .opcode = .field,
        .destination = 1,
        .immediate = 1,
        .operands = &.{0},
    }, 0, @as([]const data.graph.Value, &.{projected}));
    try std.testing.expectEqualDeep(Values.natural(0, 41), leaf);
    const root = try store.add(.{ .environment = .{ .values = &.{original}, .tail = null } });
    try store.collect(.{ .current = root });
    try std.testing.expectEqual(2, store.data_projections.count());
    try std.testing.expectEqualSlices(u8, bytes[0..16], try values.bytes(&projected));
    try store.collect(.{});
    try std.testing.expectEqual(0, store.data_projections.count());
    try std.testing.expectEqual(0, store.projection_heads.count());
    for (store.blob_alive.items) |alive| try std.testing.expect(!alive);
}

test "derived field chains retain only reachable source data under allocation faults" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, retainedField, .{});
}

test "encoded element memoization preserves bounds and avoids zero-width history" {
    const a = std.testing.allocator;
    const schemas: []const data.program.Schema = &.{
        .unit,         .u64, .text,
        .{ .seq = 2 },
        .{ .sum = &.{
            0,
            2,
        } },
        .{ .seq = 0 },
        .{ .sum = &.{
            0,
            0,
        } },
    };
    var statistics: Store.Statistics = .{};
    var store: Store.Store = .{ .allocator = a, .statistics = &statistics };
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var values: Values = .{
        .allocator = arena.allocator(),
        .schemas = schemas,
        .store = &store,
        .aggregate_storage = .structured,
    };
    const instruction: data.activation.Instruction = .{
        .opcode = .sequence_get,
        .destination = 2,
        .operands = &.{ 0, 1 },
    };
    const original = try store.literal(schemas, .{
        .schema = 3,
        .bytes = &.{ 3, 1, 'a', 2, 'b', 'c', 1, 'd' },
    });
    for (0..2) |_| {
        const found = try values.evaluate(instruction, 4, @as(
            []const data.graph.Value,
            &.{ original, Values.natural(1, 1) },
        ));
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 'b', 'c' }, try values.bytes(&found));
    }
    try std.testing.expectEqual(1, statistics.element_projection_hits);
    const absent = try values.evaluate(instruction, 4, @as(
        []const data.graph.Value,
        &.{ original, Values.natural(1, 3) },
    ));
    try std.testing.expectEqualSlices(u8, &.{0}, try values.bytes(&absent));
    const count = store.data_projections.count();
    var encoded: [10]u8 = undefined;
    var writer: data.wire.Writer = .{ .output = &encoded };
    try writer.natural(std.math.maxInt(u64));
    const empty_items = try store.literal(schemas, .{
        .schema = 5,
        .bytes = encoded[0..writer.position],
    });
    for ([_]u64{ 0, 17, std.math.maxInt(u64) - 1 }) |index| {
        const found = try values.evaluate(instruction, 6, @as([]const data.graph.Value, &.{
            empty_items, Values.natural(1, index),
        }));
        try std.testing.expectEqualSlices(u8, &.{1}, try values.bytes(&found));
    }
    try std.testing.expectEqual(count, store.data_projections.count());
}
