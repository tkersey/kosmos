const std = @import("std");
const data = @import("horos_data");
const Store = @import("../interpreter_v2/store.zig");
const Values = @import("../interpreter_v2/values.zig").Values;

test "recursive aggregate storage shares construction and preserves materialized bytes" {
    const a = std.testing.allocator;
    const schemas: []const data.program.Schema = &.{ .u64, .{ .sum = &.{ 0, 2 } }, .{ .product = &.{ 1, 1 } } };
    for ([_]usize{ 4, 8, 12 }) |depth| {
        var baseline: ?[]u8 = null;
        defer if (baseline) |bytes| a.free(bytes);
        inline for (.{ .encoded, .structured }) |storage| {
            var statistics: Store.Statistics = .{};
            var store: Store.Store = .{ .allocator = a, .statistics = &statistics };
            defer store.deinit();
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            var values: Values = .{ .allocator = scratch.allocator(), .schemas = schemas, .store = &store, .aggregate_storage = storage };
            var root = try values.aggregate(1, .{ .tag = 0, .fields = &.{Values.natural(0, 7)} });
            for (0..depth) |_| {
                const pair = try values.aggregate(2, .{ .fields = &.{ root, root } });
                root = try values.aggregate(1, .{ .tag = 1, .fields = &.{pair} });
            }
            const constructed = statistics;
            if (storage == .structured) {
                try std.testing.expectEqual(@as(u64, 0), constructed.owned_blob_bytes);
                try std.testing.expectEqual(@as(u64, 1 + 3 * depth), constructed.aggregate_field_copies);
                try std.testing.expectEqual(@as(u64, 1 + 2 * depth), constructed.added_nodes);
            }
            const encoded = try values.bytes(&root);
            try std.testing.expectEqual(@as(usize, 10) * std.math.pow(usize, 2, depth) - 1, encoded.len);
            if (storage == .encoded) baseline = try a.dupe(u8, encoded) else try std.testing.expectEqualSlices(u8, baseline.?, encoded);
            std.debug.print("recursive aggregate {s} depth={d} constructed_blob_bytes={d} field_copies={d} final_bytes={d}\n", .{ @tagName(storage), depth, constructed.owned_blob_bytes, constructed.aggregate_field_copies, encoded.len });
        }
    }
}
