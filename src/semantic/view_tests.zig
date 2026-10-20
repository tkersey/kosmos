const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const views = @import("views.zig");
const queries = @import("view_queries.zig");
const projection = @import("projection.zig");
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");
const binding: views.Binding = .{
    .guest = @splat(1),
    .core = @splat(2),
    .realization = @splat(3),
    .checkpoint = @splat(4),
    .execution = @splat(5),
    .guest_revision = 6,
    .realization_revision = 7,
    .disclosure = @splat(8),
};

test "guest view retention preserves ordered roots and first shortest path" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try support.encode(try queries.retention(&b));
    defer a.free(image);
    const roots = [_]views.Root{
        .{ .node = 0, .owned = false, .field = "first" },
        .{ .node = 4, .owned = true, .field = "later" },
        .{ .node = 4, .owned = false, .field = "duplicate" },
    };
    const edges = [_]views.Edge{
        .{ .from = 0, .to = 4, .owned = false, .field = "root-child" },
        .{ .from = 0, .to = 1, .owned = true, .field = "first-child" },
        .{ .from = 0, .to = 2, .owned = false, .field = "second-child" },
        .{ .from = 4, .to = 1, .owned = false, .field = "later-root-child" },
        .{ .from = 2, .to = 3, .owned = false, .field = "earlier-edge" },
        .{ .from = 1, .to = 3, .owned = true, .field = "first-path" },
        .{ .from = 1, .to = 3, .owned = false, .field = "duplicate-edge" },
    };
    for ([_]u64{ 4, 1, 3 }) |target| {
        const input = try projection.encode(queries.RetentionInput, a, .{ .view = .{
            .binding = binding,
            .complete_graph = true,
            .nodes = &.{},
            .roots = &roots,
            .edges = &edges,
        }, .target = target });
        defer a.free(input);
        var session = try base.Session.initImage(a, image, input, .{});
        defer session.deinit();
        const result = try session.run(null);
        try std.testing.expect(result == .completed);
        var decoded = try projection.decode(
            queries.RetentionResult,
            a,
            try session.bytes(&result.completed),
        );
        defer decoded.deinit();
        try std.testing.expectEqual(.reachable, decoded.value.conclusion);
        try std.testing.expectEqualDeep(binding, decoded.value.binding);
        try std.testing.expectEqualDeep(
            roots[if (target == 4) @as(usize, 1) else 0],
            decoded.value.root.?,
        );
        const expected: []const views.Edge = switch (target) {
            4 => &.{},
            1 => &.{edges[1]},
            3 => &.{ edges[1], edges[5] },
            else => unreachable,
        };
        try std.testing.expectEqualDeep(expected, decoded.value.path);
    }
}

test "guest view retention stops after the decisive edge" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try support.encode(try queries.retention(&b));
    defer a.free(image);
    var edges: [424]views.Edge = undefined;
    for (&edges, 0..) |*edge, i| edge.* = .{
        .from = 0,
        .to = i + 1,
        .owned = true,
        .field = "child",
    };
    var first_transitions: ?usize = null;
    for ([_]usize{ 1, edges.len }) |count| {
        const root: views.Root = .{ .node = 0, .owned = false, .field = "current" };
        const input = try projection.encode(queries.RetentionInput, a, .{ .view = .{
            .binding = binding,
            .complete_graph = true,
            .nodes = &.{},
            .roots = &.{root},
            .edges = edges[0..count],
        }, .target = 1 });
        defer a.free(input);
        var session = try base.Session.initImage(a, image, input, .{});
        defer session.deinit();
        const result = try session.run(null);
        try std.testing.expect(result == .completed);
        var decoded = try projection.decode(
            queries.RetentionResult,
            a,
            try session.bytes(&result.completed),
        );
        defer decoded.deinit();
        try std.testing.expectEqualDeep(@as(queries.RetentionResult, .{
            .binding = binding,
            .conclusion = .reachable,
            .root = root,
            .path = edges[0..1],
        }), decoded.value);
        if (first_transitions) |steps| {
            try std.testing.expectEqual(steps, session.transitions);
        } else first_transitions = session.transitions;
    }
}

test "guest view retention query traverses cycles and distinguishes incomplete absence" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try support.encode(try queries.retention(&b));
    defer a.free(image);
    const edges = [_]views.Edge{
        .{ .from = 0, .to = 1, .owned = false, .field = "parent" },
        .{ .from = 1, .to = 0, .owned = false, .field = "cycle" },
        .{ .from = 1, .to = 2, .owned = true, .field = "obligation" },
    };
    for ([_]bool{ true, false }) |complete| {
        for ([_]u64{ 0, 2, 9 }) |target| {
            const input: queries.RetentionInput = .{
                .view = .{
                    .binding = binding,
                    .complete_graph = complete,
                    .nodes = &.{},
                    .roots = &.{.{
                        .node = 0,
                        .owned = false,
                        .field = "current",
                    }},
                    .edges = &edges,
                },
                .target = target,
            };
            const bytes = try projection.encode(queries.RetentionInput, a, input);
            defer a.free(bytes);
            var session = try base.Session.initImage(a, image, bytes, .{});
            defer session.deinit();
            const result = try session.run(null);
            try std.testing.expect(result == .completed);
            var decoded = try projection.decode(
                queries.RetentionResult,
                a,
                try session.bytes(&result.completed),
            );
            defer decoded.deinit();
            try std.testing.expectEqualDeep(binding, decoded.value.binding);
            if (target == 9) {
                try std.testing.expectEqual(@as(@FieldType(
                    queries.RetentionResult,
                    "conclusion",
                ), if (complete) .absent_complete else .unknown_partial), decoded.value.conclusion);
                try std.testing.expect(decoded.value.root == null);
            } else {
                try std.testing.expectEqual(.reachable, decoded.value.conclusion);
                try std.testing.expectEqual(@as(u64, 0), decoded.value.root.?.node);
                try std.testing.expectEqual(
                    if (target == 0) @as(usize, 0) else 2,
                    decoded.value.path.len,
                );
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
    const image = try support.encode(try source.examples.cloned(&b));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var oracle = try @import("native_baseline").Session.initImage(a, image, &.{});
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
        const query_image = try support.encode(try queries.retention(&query_builder));
        defer a.free(query_image);
        const input = try projection.encode(queries.RetentionInput, a, .{
            .view = whole.value,
            .target = whole.value.nodes[whole.value.nodes.len - 1].id,
        });
        defer a.free(input);
        var session = try base.Session.initImage(a, query_image, input, .{});
        defer session.deinit();
        const result = try session.run(null);
        try std.testing.expect(result == .completed);
        var decoded = try projection.decode(
            queries.RetentionResult,
            a,
            try session.bytes(&result.completed),
        );
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
    try std.testing.expectEqual(
        @as(usize, 0),
        hidden.value.nodes.len + hidden.value.edges.len + hidden.value.roots.len,
    );
    const unchanged = try oracle.checkpoint(a);
    defer a.free(unchanged);
    try std.testing.expectEqualSlices(u8, checkpoint, unchanged);
    bound.checkpoint[0] ^= 1;
    try std.testing.expectError(
        error.InvalidViewBinding,
        views.capture(a, guest, checkpoint, bound, null),
    );
}

test "guest view divergence query reports only aligned finite observation evidence" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try support.encode(try queries.divergence(&b));
    defer a.free(image);
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
        var result = try projection.decode(
            queries.DivergenceResult,
            a,
            try session.bytes(&observed.completed),
        );
        defer result.deinit();
        try std.testing.expectEqualDeep(input.left.binding, result.value.left);
        try std.testing.expectEqualDeep(input.right.binding, result.value.right);
        try std.testing.expectEqual(input.right.complete, result.value.right_complete);
        switch (scenario) {
            0, 2 => {
                try std.testing.expectEqual(.observed_agreement, result.value.conclusion);
                try std.testing.expectEqual(
                    @as(u64, if (scenario == 0) 2 else 1),
                    result.value.compared,
                );
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

const ViewInput = struct { number: u64, bytes: []const u8 };

fn typedViewGuest(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const input = try projection.schema(ViewInput, b);
    const entry = try b.declare(&.{
        try b.scalar(u64), try projection.schema([]const u8, b),
    }, input, &.{}, &.{});
    const number = try b.reference(b.parameter(entry, 0));
    const bytes = try b.reference(b.parameter(entry, 1));
    const aggregate = try b.primitive(input, .product, &.{ number, bytes }, 0);
    const returned = try b.pure(aggregate);
    try b.define(entry, try b.term(.{ .yield_then = returned }));
    return b.module(entry, unit);
}

fn typedViewBinding(guest: *const data.program_image.Admitted, checkpoint: []const u8) views.Binding {
    var bound = binding;
    bound.guest = guest.identity();
    bound.checkpoint = @import("artifact.zig").digest(checkpoint);
    return bound;
}

test "typed guest views disclose selected scalars schemas and bounded blob slices" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try support.encode(try typedViewGuest(&b));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    const input = try projection.encode(ViewInput, a, .{ .number = 42, .bytes = "secret-payload" });
    defer a.free(input);
    var oracle = try @import("native_baseline").Session.initImage(a, image, input);
    defer oracle.deinit();
    _ = try oracle.run(null);
    const checkpoint = try oracle.checkpoint(a);
    defer a.free(checkpoint);
    const bound = typedViewBinding(guest, checkpoint);
    var metadata = try views.captureDetailed(a, guest, checkpoint, bound, .{});
    defer metadata.deinit();
    try std.testing.expectEqual(.not_requested, metadata.value.value_coverage);
    try std.testing.expectEqual(@as(usize, 0), metadata.value.values.len);
    const mask = try a.alloc(bool, metadata.value.metadata.nodes.len);
    defer a.free(mask);
    @memset(mask, true);
    var values = try views.captureDetailed(a, guest, checkpoint, bound, .{
        .values = .{ .nodes = mask },
    });
    defer values.deinit();
    try std.testing.expectEqual(.complete, values.value.value_coverage);
    try std.testing.expect(values.value.schemas.len > 0);
    try std.testing.expectEqual(@as(usize, 0), values.value.blobs.len);
    try checkTypedDisclosure(guest, checkpoint, bound, values.value);
    const unchanged = try oracle.checkpoint(a);
    defer a.free(unchanged);
    try std.testing.expectEqualSlices(u8, checkpoint, unchanged);
}

fn checkTypedDisclosure(
    guest: *const data.program_image.Admitted,
    checkpoint: []const u8,
    bound: views.Binding,
    whole: views.DetailedView,
) !void {
    var scalar: ?views.TypedValue = null;
    var blob: ?views.TypedValue = null;
    for (whole.values) |value| switch (value.value.body) {
        .scalar => if (std.mem.readInt(u64, &value.value.body.scalar, .little) == 42) {
            scalar = value;
        },
        .blob => blob = value,
        else => {},
    };
    try std.testing.expect(scalar != null and blob != null);
    const selected = scalar.?;
    const fields = [_]views.FieldSelection{.{ .node = selected.node, .field = selected.field }};
    var partial = try views.captureDetailed(a, guest, checkpoint, bound, .{
        .values = .{ .fields = &fields },
    });
    defer partial.deinit();
    try std.testing.expectEqual(.partial, partial.value.value_coverage);
    try std.testing.expectEqual(@as(usize, 1), partial.value.values.len);
    try std.testing.expectEqualDeep(selected, partial.value.values[0]);
    const range: views.BlobRange = .{ .blob = blob.?.value.body.blob.id, .offset = 1, .length = 6 };
    try std.testing.expectError(error.InvalidDisclosure, views.captureDetailed(
        a,
        guest,
        checkpoint,
        bound,
        .{ .values = .{ .fields = &fields }, .blobs = &.{range} },
    ));
    try checkBlobDisclosure(guest, checkpoint, bound, blob.?, range);
}

fn checkBlobDisclosure(
    guest: *const data.program_image.Admitted,
    checkpoint: []const u8,
    bound: views.Binding,
    blob: views.TypedValue,
    range: views.BlobRange,
) !void {
    const fields = [_]views.FieldSelection{.{ .node = blob.node, .field = blob.field }};
    var selected = try views.captureDetailed(a, guest, checkpoint, bound, .{
        .values = .{ .fields = &fields },
        .blobs = &.{range},
    });
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.value.blobs.len);
    try std.testing.expectEqualSlices(u8, "secret", selected.value.blobs[0].bytes);
    const bytes = try projection.encode(views.DetailedView, a, selected.value);
    defer a.free(bytes);
    var b = source.Builder.init(a);
    defer b.deinit();
    const root = try projection.schema(views.DetailedView, &b);
    const schema = try data.schema.encodeOwned(a, b.schemas.items, root);
    defer a.free(schema);
    var descriptor = try data.schema.decode(a, schema);
    defer descriptor.deinit();
    try data.schema.validateValue(a, descriptor.descriptor, bytes);
    var invalid = range;
    invalid.length = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidDisclosure, views.captureDetailed(
        a,
        guest,
        checkpoint,
        bound,
        .{ .values = .{ .fields = &fields }, .blobs = &.{invalid} },
    ));
}
