const std = @import("std");
const data = @import("horos_data");
const heap = @import("store.zig");
const testing = std.testing;

test "intern equality preserves schemas and bytes across hash collisions" {
    const Index = @FieldType(heap.Store, "interned");
    const Key = @FieldType(Index.KV, "key");
    const Context = @typeInfo(@TypeOf(Index.getContext)).@"fn".param_types[2].?;
    var index: Index = .empty;
    defer index.deinit(testing.allocator);
    const keys = [_]Key{
        .{ .blob = .{ .schema = 0, .bytes = "first" }, .hash = 7 },
        .{ .blob = .{ .schema = 0, .bytes = "second" }, .hash = 7 },
        .{ .blob = .{ .schema = 1, .bytes = "first" }, .hash = 7 },
    };
    for (keys, 0..) |key, id| try index.put(testing.allocator, key, id);
    try testing.expectEqual(keys.len, index.count());
    index.rehash(Context{});
    for (keys, 0..) |key, id| try testing.expectEqual(id, index.get(key).?);
    try testing.expect(index.remove(keys[1]));
    index.rehash(Context{});
    try testing.expectEqual(0, index.get(keys[0]).?);
    try testing.expectEqual(2, index.get(keys[2]).?);
    try testing.expect(index.get(keys[1]) == null);
}

test "blob retirement visits each intern entry and preserves free order and rollback" {
    var store: heap.Store = .{ .allocator = testing.allocator };
    defer store.deinit();
    var statistics: heap.Statistics = .{};
    store.statistics = &statistics;
    var values: [128]data.graph.Value = undefined;
    var retained: [64]data.graph.Value = undefined;
    for (&values, 0..) |*item, index| {
        var encoded: [5]u8 = undefined;
        encoded[0] = 4;
        std.mem.writeInt(u32, encoded[1..5], @intCast(index), .little);
        item.* = try store.literal(&.{.bytes}, .{ .schema = 0, .bytes = &encoded });
        if (index % 2 == 1) retained[index / 2] = item.*;
    }
    const root = try store.add(.{ .environment = .{ .values = &retained, .tail = null } });
    const roots: data.graph.Roots = .{ .current = root };
    try store.begin();
    try store.collect(roots);
    try testing.expectEqual(@as(usize, 64), store.interned.count());
    try testing.expectEqual(@as(u64, 128), statistics.retirement_table_entries);
    try testing.expectEqual(@as(u64, 64), statistics.blob_retirements);
    for (store.free_blobs.items, 0..) |id, index| try testing.expectEqual(index * 2, id);
    for (store.blob_alive.items, 0..) |alive, index| try testing.expectEqual(index % 2 == 1, alive);
    store.rollback();
    try testing.expectEqual(@as(usize, 128), store.interned.count());
    for (values, 0..) |value, index| {
        var encoded: [5]u8 = undefined;
        encoded[0] = 4;
        std.mem.writeInt(u32, encoded[1..5], @intCast(index), .little);
        const restored = try store.literal(&.{.bytes}, .{ .schema = 0, .bytes = &encoded });
        try testing.expectEqual(value.body.blob.id, restored.body.blob.id);
    }
    try store.replace(root, .{ .environment = .{ .values = &.{}, .tail = null } });
    try store.collect(roots);
    try testing.expectEqual(@as(usize, 0), store.interned.count());
    try testing.expectEqual(@as(usize, 128), store.free_blobs.items.len);
    for (store.free_blobs.items, 0..) |id, index| try testing.expectEqual(index, id);
    const replacement = try store.literal(&.{.bytes}, .{ .schema = 0, .bytes = &.{ 1, 99 } });
    try testing.expectEqual(@as(u64, 127), replacement.body.blob.id);
}

fn encodedCursorFailure(allocator: std.mem.Allocator) !void {
    var store: heap.Store = .{ .allocator = allocator };
    defer store.deinit();
    const schemas = [_]data.program.Schema{ .u64, .{ .seq = 0 } };
    const original = try store.literal(&schemas, .{ .schema = 1, .bytes = &.{
        2, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,
    } });
    const cursor = try store.encodedSequence(1, .{
        .backing = original.body.blob,
        .start = 9,
        .length = 8,
        .count = 1,
    });
    const root = try store.add(.{ .environment = .{
        .values = &.{.{ .schema = 1, .body = .{ .reference = cursor } }},
        .tail = null,
    } });
    const roots: data.graph.Roots = .{ .current = root };
    try store.collect(roots);
    try testing.expect(store.blob_alive.items[@intCast(original.body.blob.id)]);
    try store.begin();
    try store.replace(root, .{ .environment = .{ .values = &.{}, .tail = null } });
    try store.collect(roots);
    _ = try store.literal(&schemas, .{ .schema = 1, .bytes = &.{0} });
    _ = try store.add(.{ .environment = .{ .values = &.{}, .tail = null } });
    store.rollback();
    try testing.expectEqual(@as(u64, 1), store.encoded_sequences.get(@intCast(cursor.id)).?.count);
    const encoded = try @import("value_encoding.zig").encode(allocator, &schemas, &store, .{
        .schema = 1,
        .body = .{ .reference = cursor },
    });
    defer allocator.free(encoded);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 0, 0, 0, 0, 0, 0, 0 }, encoded);
}

test "encoded cursor backing participates in collection rollback and allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, encodedCursorFailure, .{});
}

fn sharedFieldsFailure(allocator: std.mem.Allocator) !void {
    var store: heap.Store = .{ .allocator = allocator };
    defer store.deinit();
    var fields: [32]data.graph.Value = undefined;
    for (&fields, 0..) |*value, i| value.* = @import("values.zig").Values.natural(0, i);
    const base = try store.add(.{ .aggregate = .{ .schema = 1, .tag = 0, .fields = &fields } });
    const first = try store.aggregateSlice(1, base, 0, fields.len);
    const root = try store.add(.{ .environment = .{
        .values = &.{.{ .schema = 1, .body = .{ .reference = first } }},
        .tail = null,
    } });
    const roots: data.graph.Roots = .{ .current = root };
    try store.collect(roots);
    const before = try bytes(&store, roots);
    defer testing.allocator.free(before);
    try store.begin();
    const tail = try store.aggregateSlice(1, first, 1, 31);
    try store.replace(root, .{ .environment = .{
        .values = &.{.{ .schema = 1, .body = .{ .reference = tail } }},
        .tail = null,
    } });
    try store.collect(roots);
    const short = try store.aggregateSlice(1, tail, 27, 4);
    try store.replace(root, .{ .environment = .{
        .values = &.{.{ .schema = 1, .body = .{ .reference = short } }},
        .tail = null,
    } });
    try store.collect(roots);
    store.rollback();
    const restored = try bytes(&store, roots);
    defer testing.allocator.free(restored);
    try testing.expectEqualSlices(u8, before, restored);
    try testing.expectEqual(32, store.shared_field_values);
    try store.begin();
    const last = try store.aggregateSlice(1, first, 31, 1);
    try store.replace(root, .{ .environment = .{
        .values = &.{.{ .schema = 1, .body = .{ .reference = last } }},
        .tail = null,
    } });
    try store.collect(roots);
    store.commit();
    try testing.expectEqual(1, store.shared_field_values);
    try testing.expectEqual(31, (try store.get(last)).aggregate.fields[0].body.scalar[0]);
}

test "shared sequence backing survives rollback collection and every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, sharedFieldsFailure, .{});
}

fn ownedLiteral(
    allocator: std.mem.Allocator,
    store: *heap.Store,
    schema: data.program.Id,
    contents: []const u8,
) !data.graph.Value {
    const buffer = try allocator.dupe(u8, contents);
    errdefer allocator.free(buffer);
    return store.literalOwned(&.{ .bytes, .u64 }, schema, buffer);
}

fn ownedConstruction(allocator: std.mem.Allocator) !void {
    var store: heap.Store = .{ .allocator = allocator };
    defer store.deinit();
    const buffer = try allocator.dupe(u8, &.{ 3, 'o', 'n', 'e' });
    var transferred = false;
    defer if (!transferred) allocator.free(buffer);
    const first = try store.literalOwned(&.{ .bytes, .u64 }, 0, buffer);
    transferred = true;
    try testing.expect(store.blobs.items[@intCast(first.body.blob.id)].bytes.ptr == buffer.ptr);
    const duplicate = try ownedLiteral(allocator, &store, 0, &.{ 3, 'o', 'n', 'e' });
    try testing.expectEqual(first.body.blob.id, duplicate.body.blob.id);
    const scalar = try ownedLiteral(allocator, &store, 1, &.{ 42, 0, 0, 0, 0, 0, 0, 0 });
    try testing.expectEqual(42, scalar.body.scalar[0]);
    const root = try store.add(.{ .environment = .{ .values = &.{first}, .tail = null } });
    const roots: data.graph.Roots = .{ .current = root };
    try store.begin();
    try store.replace(root, .{ .environment = .{ .values = &.{}, .tail = null } });
    try store.collect(roots);
    const replacement = try ownedLiteral(allocator, &store, 0, &.{ 3, 't', 'w', 'o' });
    try testing.expectEqual(first.body.blob.id, replacement.body.blob.id);
    store.rollback();
    const restored = (try store.get(root)).environment.values[0];
    try testing.expectEqualSlices(
        u8,
        &.{ 3, 'o', 'n', 'e' },
        store.blobs.items[@intCast(restored.body.blob.id)].bytes,
    );
}

test "owned blob construction transfers only on success and survives journal reuse" {
    try testing.checkAllAllocationFailures(testing.allocator, ownedConstruction, .{});
}

fn bytes(store: *heap.Store, roots: data.graph.Roots) ![]u8 {
    const nodes = try testing.allocator.alloc(data.process_state.Node, store.nodes.items.len);
    defer testing.allocator.free(nodes);
    for (nodes, store.nodes.items) |*target, source| target.* = .{ .record = source };
    return data.state_image.emit(testing.allocator, .{
        .program_identity = @as([32]u8, @splat(0)),
        .status = .active,
        .roots = roots,
        .nodes = nodes,
        .blobs = store.blobs.items,
    });
}

test "journal retains one entry version across repeated changes, collection and ID reuse" {
    var store: heap.Store = .{ .allocator = testing.allocator };
    defer store.deinit();
    const old = try store.literal(&.{.bytes}, .{ .schema = 0, .bytes = &.{ 3, 'o', 'l', 'd' } });
    const root = try store.add(.{ .environment = .{ .values = &.{old}, .tail = null } });
    const roots: data.graph.Roots = .{ .current = root };
    const before = try bytes(&store, roots);
    defer testing.allocator.free(before);
    const old_fields = (try store.get(root)).environment.values.ptr;
    const old_payload = store.blobs.items[0].bytes.ptr;
    try store.begin();
    for (0..64) |index| {
        const value = try store.literal(&.{.bytes}, .{
            .schema = 0,
            .bytes = &.{ 1, @intCast(index) },
        });
        try store.replace(root, .{ .environment = .{ .values = &.{value}, .tail = null } });
        try store.collect(roots);
    }
    try testing.expectEqual(1, store.journal.?.nodes.count());
    try testing.expectEqual(1, store.journal.?.blobs.count());
    try testing.expect(old_fields == store.journal.?.nodes.get(0).?.value.environment.values.ptr);
    try testing.expect(old_payload == store.journal.?.blobs.get(0).?.value.bytes.ptr);
    store.rollback();
    const after = try bytes(&store, roots);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
    try testing.expectEqual(0, (try store.literal(&.{.bytes}, .{
        .schema = 0,
        .bytes = &.{ 3, 'o', 'l', 'd' },
    })).body.blob.id);
    try store.begin();
    const value = try store.literal(&.{.bytes}, .{ .schema = 0, .bytes = &.{ 1, 99 } });
    try store.replace(root, .{ .environment = .{ .values = &.{value}, .tail = null } });
    try store.collect(roots);
    store.commit();
    try testing.expectEqualSlices(
        u8,
        &.{ 1, 99 },
        store.blobs.items[@intCast(value.body.blob.id)].bytes,
    );
}

test "journal rollback retains imported bytes after collection and replacement" {
    const state: data.process_state.State = .{
        .program_identity = @as([32]u8, @splat(0)),
        .status = .active,
        .roots = .{ .current = .{ .id = 0 } },
        .nodes = &.{.{ .record = .{ .environment = .{ .values = &.{.{
            .schema = 0,
            .body = .{ .blob = .{ .id = 0 } },
        }}, .tail = null } } }},
        .blobs = &.{.{ .schema = 0, .bytes = &.{ 3, 'o', 'l', 'd' } }},
    };
    const encoded = try data.state_image.emit(testing.allocator, state);
    defer testing.allocator.free(encoded);
    var owner = try data.state_image.decodeGraph(testing.allocator, encoded);
    var moved = false;
    defer if (!moved) owner.deinit();
    var store: heap.Store = .{ .allocator = testing.allocator };
    defer store.deinit();
    try store.importOwned(&owner);
    moved = true;
    try store.begin();
    try store.replace(.{ .id = 0 }, .{ .environment = .{ .values = &.{}, .tail = null } });
    try store.collect(state.roots);
    try testing.expect(store.imported != null);
    store.rollback();
    const restored = try bytes(&store, state.roots);
    defer testing.allocator.free(restored);
    try testing.expectEqualSlices(u8, encoded, restored);
}
