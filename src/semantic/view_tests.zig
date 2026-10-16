const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const views = @import("views.zig");
const queries = @import("view_queries.zig");
const projection = @import("projection.zig");
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const binding: views.Binding = .{ .guest = @splat(1), .core = @splat(2), .realization = @splat(3), .checkpoint = @splat(4), .execution = @splat(5), .guest_revision = 6, .realization_revision = 7, .disclosure = @splat(8) };

test "guest view retention query traverses cycles and distinguishes incomplete absence" {
    var b = source.Builder.init(a);
    defer b.deinit();
    var compiled = try source.lower(a, try queries.retention(&b));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const edges = [_]views.Edge{
        .{ .from = 0, .to = 1, .owned = false, .field = "parent" },
        .{ .from = 1, .to = 0, .owned = false, .field = "cycle" },
        .{ .from = 1, .to = 2, .owned = true, .field = "obligation" },
    };
    for ([_]bool{ true, false }) |complete| {
        for ([_]u64{ 0, 2, 9 }) |target| {
            const input: queries.RetentionInput = .{ .view = .{ .binding = binding, .complete_graph = complete, .nodes = &.{}, .roots = &.{.{ .node = 0, .owned = false, .field = "current" }}, .edges = &edges }, .target = target };
            const bytes = try projection.encode(queries.RetentionInput, a, input);
            defer a.free(bytes);
            var session = try base.Session.initImage(a, image, bytes, .{});
            defer session.deinit();
            const result = try session.run(null);
            try std.testing.expect(result == .completed);
            var decoded = try projection.decode(queries.RetentionResult, a, try session.bytes(&result.completed));
            defer decoded.deinit();
            try std.testing.expectEqualDeep(binding, decoded.value.binding);
            if (target == 9) {
                try std.testing.expectEqual(@as(@FieldType(queries.RetentionResult, "conclusion"), if (complete) .absent_complete else .unknown_partial), decoded.value.conclusion);
                try std.testing.expect(decoded.value.root == null);
            } else {
                try std.testing.expectEqual(.reachable, decoded.value.conclusion);
                try std.testing.expectEqual(@as(u64, 0), decoded.value.root.?.node);
                try std.testing.expectEqual(if (target == 0) @as(usize, 0) else 2, decoded.value.path.len);
                if (target == 2) {
                    try std.testing.expectEqualDeep(edges[0], decoded.value.path[0]);
                    try std.testing.expectEqualDeep(edges[2], decoded.value.path[1]);
                }
            }
        }
    }
}

test "guest view capture derives reference paths from an admitted immutable cut" {
    var b = source.Builder.init(a);
    defer b.deinit();
    var compiled = try source.lower(a, try source.examples.cloned(&b));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var oracle = try @import("../../test_oracle.zig").Session.initImage(a, image, &.{});
    defer oracle.deinit();
    _ = try oracle.run(6);
    const checkpoint = try oracle.checkpoint(a);
    defer a.free(checkpoint);
    var bound = binding;
    bound.guest = guest.identity();
    bound.checkpoint = @import("artifact.zig").digest(checkpoint);
    var whole = try views.capture(a, guest, checkpoint, bound, null);
    defer whole.deinit();
    try std.testing.expect(whole.value.complete_graph);
    try std.testing.expect(whole.value.nodes.len > 0 and whole.value.roots.len > 0);
    {
        var query_builder = source.Builder.init(a);
        defer query_builder.deinit();
        var query = try source.lower(a, try queries.retention(&query_builder));
        defer query.deinit();
        const query_image = try a.alloc(u8, try data.program_image.encodedLength(query.program));
        defer a.free(query_image);
        _ = try query.encode(a, query_image);
        const input = try projection.encode(queries.RetentionInput, a, .{ .view = whole.value, .target = whole.value.nodes[whole.value.nodes.len - 1].id });
        defer a.free(input);
        var session = try base.Session.initImage(a, query_image, input, .{});
        defer session.deinit();
        const result = try session.run(null);
        try std.testing.expect(result == .completed);
        var decoded = try projection.decode(queries.RetentionResult, a, try session.bytes(&result.completed));
        defer decoded.deinit();
        try std.testing.expectEqual(.reachable, decoded.value.conclusion);
        try std.testing.expectEqualDeep(bound, decoded.value.binding);
        const schema = try views.schemaBytes(a);
        defer a.free(schema);
        var descriptor = try data.schema.decode(a, schema);
        defer descriptor.deinit();
        const view_bytes = try views.encode(a, whole.value);
        defer a.free(view_bytes);
        try data.schema.validateValue(a, descriptor.descriptor, view_bytes);
    }
    const mask = try a.alloc(bool, whole.value.nodes.len);
    defer a.free(mask);
    @memset(mask, false);
    var hidden = try views.capture(a, guest, checkpoint, bound, mask);
    defer hidden.deinit();
    try std.testing.expect(!hidden.value.complete_graph);
    try std.testing.expectEqual(@as(usize, 0), hidden.value.nodes.len + hidden.value.edges.len + hidden.value.roots.len);
    const unchanged = try oracle.checkpoint(a);
    defer a.free(unchanged);
    try std.testing.expectEqualSlices(u8, checkpoint, unchanged);
    bound.checkpoint[0] ^= 1;
    try std.testing.expectError(error.InvalidViewBinding, views.capture(a, guest, checkpoint, bound, null));
}

test "guest view divergence query reports only aligned finite observation evidence" {
    var b = source.Builder.init(a);
    defer b.deinit();
    var compiled = try source.lower(a, try queries.divergence(&b));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    const left = [_]queries.Observation{
        .{ .revision = 6, .control = @splat(0), .bytes = "yielded" },
        .{ .revision = 7, .control = @splat(1), .bytes = "completed:42" },
    };
    for (0..6) |scenario| {
        var right = left;
        var input: queries.DivergenceInput = .{
            .left = .{ .binding = binding, .complete = true, .observations = &left },
            .right = .{ .binding = binding, .complete = scenario != 2, .observations = &right },
        };
        switch (scenario) {
            0 => {},
            1 => right[1].bytes = "completed:43",
            2 => input.right.observations = right[0..1],
            3 => right[1].control[0] ^= 1,
            4 => right[1].revision = 6,
            5 => input.right.binding.guest[0] ^= 1,
            else => unreachable,
        }
        const bytes = try projection.encode(queries.DivergenceInput, a, input);
        defer a.free(bytes);
        var session = try base.Session.initImage(a, image, bytes, .{});
        defer session.deinit();
        const observed = try session.run(null);
        try std.testing.expect(observed == .completed);
        var result = try projection.decode(queries.DivergenceResult, a, try session.bytes(&observed.completed));
        defer result.deinit();
        try std.testing.expectEqualDeep(input.left.binding, result.value.left);
        try std.testing.expectEqualDeep(input.right.binding, result.value.right);
        try std.testing.expectEqual(input.right.complete, result.value.right_complete);
        switch (scenario) {
            0, 2 => {
                try std.testing.expectEqual(.observed_agreement, result.value.conclusion);
                try std.testing.expectEqual(@as(u64, if (scenario == 0) 2 else 1), result.value.compared);
                try std.testing.expect(result.value.revision == null);
            },
            1 => {
                try std.testing.expectEqual(.divergence, result.value.conclusion);
                try std.testing.expectEqual(@as(?u64, 7), result.value.revision);
                try std.testing.expectEqual(@as(u64, 1), result.value.compared);
            },
            else => try std.testing.expectEqual(.incomparable, result.value.conclusion),
        }
    }
}
