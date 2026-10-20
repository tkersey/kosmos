const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const frames = @import("frames.zig");
const Author = @import("author.zig").Author;
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");
const Activation = data.process_state.Activation;
const Input = struct {
    frame: Activation,
    scopes: []const data.activation.CustodyScope,
    target: u64,
    slot: u64,
    value: data.graph.Value,
    clear: u64,
    live: []const u64,
};
const Result = struct { changed: Activation, original: Activation };

fn owned(id: u64) data.graph.Value {
    return .{ .schema = 7, .body = .{ .owned = .{ .node = .{ .id = id } } } };
}

test "portable frames preserve sparse bindings and lexical owner order" {
    var prepared = try prepareSparseFrames();
    defer prepared.deinit();

    for (sparse_cases) |case| {
        const input_value: Input = .{ .frame = sparse_initial, .scopes = &.{
            .{}, .{ .parent = 0 }, .{ .parent = 1 }, .{ .parent = 0 }, .{ .parent = 3 },
        }, .target = case.target, .slot = 5, .value = case.value, .clear = 3, .live = &.{
            1, 5, 9, 7777,
        } };
        const bytes = try projection.encode(Input, a, input_value);
        defer a.free(bytes);
        var session = try base.Session.start(a, &prepared, bytes, .{});
        defer session.deinit();
        try std.testing.expect(try session.run(null) == .yielded);
        const snapshot = try session.checkpoint(a);
        defer a.free(snapshot);
        var restored = try base.Session.restore(a, &prepared, snapshot, .{});
        defer restored.deinit();
        try restored.resumeYield();
        const outcome = try restored.run(null);
        try std.testing.expect(outcome == .completed);
        var result = try projection.decode(Result, a, try restored.bytes(&outcome.completed));
        defer result.deinit();
        try std.testing.expectEqualDeep(sparse_initial, result.value.original);
        const expected: Activation = .{ .position = 17, .scope = case.target, .bindings = &.{
            .{ .slot = 1, .value = owned(
                1,
            ) },
            .{ .slot = 5, .value = case.value },
            .{ .slot = 9, .value = frame_scalar },
        }, .owners = case.owners };
        try std.testing.expectEqualDeep(expected, result.value.changed);
    }
}

test "portable scalar frames reconstruct retained bits with one representation per key" {
    var prepared = try prepareScalarFrames();
    defer prepared.deinit();
    const initial: Activation = .{
        .position = 17,
        .scope = 2,
        .bindings = &.{
            .{ .slot = 1, .value = owned(
                1,
            ) },
            .{ .slot = 5, .value = owned(
                5,
            ) },
            .{ .slot = 9, .value = owned(
                9,
            ) },
        },
        .owners = &.{
            .{ .scope = 2, .slot = 9 }, .{ .scope = 1, .slot = 5 }, .{ .scope = 0, .slot = 1 },
        },
    };
    for ([_]u64{ 0, 173, std.math.maxInt(u64) }) |input| {
        const args = try projection.encode(
            struct { frame: Activation, bits: u64 },
            a,
            .{ .frame = initial, .bits = input },
        );
        defer a.free(args);
        var session = try base.Session.start(a, &prepared, args, .{});
        defer session.deinit();
        try std.testing.expect(try session.run(null) == .yielded);
        const checkpoint = try session.checkpoint(a);
        defer a.free(checkpoint);
        var restored = try base.Session.restore(a, &prepared, checkpoint, .{});
        defer restored.deinit();
        try restored.resumeYield();
        const result = try restored.run(null);
        try std.testing.expect(result == .completed);
        var decoded = try projection.decode(Output, a, try restored.bytes(&result.completed));
        defer decoded.deinit();
        try std.testing.expect(decoded.value.valid and !decoded.value.duplicate_valid);
        try std.testing.expectEqual(input, decoded.value.bits);
        try std.testing.expectEqualDeep(initial, decoded.value.original);
        const expected: Activation = .{
            .position = 17,
            .scope = 2,
            .bindings = &.{
                .{ .slot = 1, .value = owned(
                    1,
                ) },
                .{
                    .slot = 5,
                    .value = .{ .schema = 1, .body = .{ .scalar = std.mem.toBytes(input) } },
                },
            },
            .owners = &.{.{ .scope = 0, .slot = 1 }},
        };
        try std.testing.expectEqualDeep(expected, decoded.value.changed);
        try std.testing.expectEqualDeep(
            data.graph.Value{ .schema = 1, .body = .{ .scalar = @splat(0) } },
            decoded.value.overwritten.bindings[1].value,
        );
    }
}

fn prepareSparseFrames() !base.Prepared {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const d = try frames.define(&b);
    const input_type = try projection.schema(Input, &b);
    const output = try projection.schema(Result, &b);
    const entry = try b.declare(&.{input_type}, output, &.{}, &.{});
    const input = try e.param(entry, 0);
    const saved = try b.variable(d.schema);
    const moved = try b.variable(d.schema);
    const written = try b.variable(d.schema);
    const cleared = try b.variable(d.schema);
    const pruned = try b.variable(d.schema);
    const original = try b.variable(d.public);
    const projected = try b.variable(d.public);
    var body = try b.pure(try e.tuple(output, &.{
        try b.reference(projected), try b.reference(original),
    }));
    body = try b.bind(original, try e.call(d.to_public, &.{try b.reference(saved)}), body);
    body = try b.bind(projected, try e.call(d.to_public, &.{try b.reference(pruned)}), body);
    body = try b.bind(pruned, try e.call(d.prune, &.{
        try b.reference(cleared), try e.field(input, 6),
    }), body);
    body = try b.bind(cleared, try e.call(d.clear, &.{
        try b.reference(written), try e.field(input, 5),
    }), body);
    body = try b.bind(written, try e.call(d.write, &.{
        try b.reference(moved), try e.field(input, 3), try e.field(input, 4),
    }), body);
    body = try b.bind(moved, try e.call(d.scope, &.{
        try b.reference(saved), try e.field(input, 1), try e.field(input, 2),
    }), body);
    body = try b.bind(saved, try e.call(
        d.from_public,
        &.{try e.field(input, 0)},
    ), try b.term(.{ .yield_then = body }));
    try b.define(entry, body);
    const image = try support.encode(b.module(entry, e.unit));
    defer a.free(image);
    return base.Prepared.init(a, image);
}

fn prepareScalarFrames() !base.Prepared {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const d = try frames.define(&b);
    const output = try projection.schema(Output, &b);
    const scalar = try projection.schema(frames.Scalar, &b);
    const entry = try b.declare(&.{ d.public, e.integer }, output, &.{}, &.{});
    const original = try b.variable(d.schema);
    const written = try b.variable(d.schema);
    const pruned = try b.variable(d.schema);
    const generic = try b.variable(d.schema);
    const bits = try b.variable(e.integer);
    const valid = try b.variable(e.boolean);
    const duplicate_valid = try b.variable(e.boolean);
    const duplicate = try b.variable(d.slots.tree);
    const projected = try b.variable(d.public);
    const overwritten = try b.variable(d.public);
    const saved = try b.variable(d.public);
    const slot = try b.constant(u64, 5);
    const scalar_value = try e.tuple(scalar, &.{ try b.constant(u64, 1), try e.param(entry, 1) });
    const generic_value = try e.literal(data.graph.Value, .{
        .schema = 1,
        .body = .{ .scalar = @splat(0) },
    });
    var body = try b.pure(try e.tuple(output, &.{
        try b.reference(projected),
        try b.reference(overwritten),
        try b.reference(saved),
        try b.reference(bits),
        try b.reference(valid),
        try b.reference(duplicate_valid),
    }));
    body = try b.bind(saved, try e.call(d.to_public, &.{try b.reference(original)}), body);
    body = try b.bind(overwritten, try e.call(d.to_public, &.{try b.reference(generic)}), body);
    body = try b.bind(projected, try e.call(d.to_public, &.{try b.reference(pruned)}), body);
    body = try b.bind(generic, try e.call(d.write, &.{
        try b.reference(pruned), slot, generic_value,
    }), body);
    body = try b.bind(duplicate_valid, try e.call(d.valid, &.{try e.replace(
        try b.reference(pruned),
        2,
        try b.reference(duplicate),
    )}), body);
    body = try b.bind(duplicate, try b.pure(try duplicateSlots(
        e,
        d,
        slot,
        generic_value,
        scalar_value,
    )), body);
    body = try b.bind(valid, try e.call(d.valid, &.{try b.reference(pruned)}), body);
    body = try b.bind(bits, try e.call(d.read_raw, &.{ try b.reference(pruned), slot }), body);
    body = try b.bind(pruned, try e.call(d.prune, &.{
        try b.reference(written), try e.literal([]const u64, &.{ 1, 5 }),
    }), try b.term(.{ .yield_then = body }));
    body = try b.bind(written, try e.call(d.write_raw, &.{
        try b.reference(original), slot, scalar_value,
    }), body);
    try b.define(entry, try b.bind(original, try e.call(
        d.from_public,
        &.{try e.param(entry, 0)},
    ), body));
    const image = try support.encode(b.module(entry, e.unit));
    defer a.free(image);
    return base.Prepared.init(a, image);
}

const Output = struct {
    changed: Activation,
    overwritten: Activation,
    original: Activation,
    bits: u64,
    valid: bool,
    duplicate_valid: bool,
};

const frame_scalar: data.graph.Value = .{ .schema = 1, .body = .{ .scalar = @splat(0) } };

const sparse_initial: Activation = .{
    .position = 17,
    .scope = 2,
    .bindings = &.{
        .{ .slot = 1, .value = owned(
            1,
        ) },
        .{ .slot = 3, .value = owned(
            3,
        ) },
        .{ .slot = 5, .value = owned(
            5,
        ) },
        .{ .slot = 8, .value = owned(
            8,
        ) },
        .{ .slot = 9, .value = frame_scalar },
    },
    .owners = &.{
        .{ .scope = 2, .slot = 8 },
        .{ .scope = 2, .slot = 3 },
        .{ .scope = 1, .slot = 5 },
        .{ .scope = 0, .slot = 1 },
    },
};

const sparse_cases = [_]struct {
    target: u64,
    value: data.graph.Value,
    owners: []const data.process_state.Owner,
}{
    .{ .target = 4, .value = owned(55), .owners = &.{
        .{ .scope = 4, .slot = 5 }, .{ .scope = 0, .slot = 1 },
    } },
    .{ .target = 1, .value = owned(55), .owners = &.{
        .{ .scope = 1, .slot = 5 }, .{ .scope = 0, .slot = 1 },
    } },
    .{ .target = 2, .value = frame_scalar, .owners = &.{.{ .scope = 0, .slot = 1 }} },
};

fn duplicateSlots(
    e: Author,
    d: frames.Definition,
    slot: data.program.Id,
    generic_value: data.program.Id,
    scalar_value: data.program.Id,
) !data.program.Id {
    const leaf = try e.variant(d.slots.tree, 1, try e.tuple(d.slots.entry, &.{
        slot, try e.variant(d.slot, 0, generic_value),
    }));
    const raw = try e.variant(d.slots.tree, 1, try e.tuple(d.slots.entry, &.{
        slot, try e.variant(d.slot, 1, scalar_value),
    }));
    return e.variant(d.slots.tree, 2, try e.tuple(d.slots.branch, &.{ e.one, leaf, raw }));
}
