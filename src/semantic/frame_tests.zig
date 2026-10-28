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

const references = @import("references.zig");
const Id = data.program.Id;
const SlotEntry = struct { key: u64, value: frames.Slot };
const MappingEntry = struct { key: u64, value: data.graph.NodeRef };
const ReferenceInput = struct {
    slots: []const SlotEntry,
    mapping: []const MappingEntry,
    prefix: []const data.graph.NodeRef,
    owners: []const data.process_state.Owner,
};
const ReferenceOutput = struct {
    walked: []const data.graph.NodeRef,
    changed: Activation,
    original: Activation,
    slots: []const SlotEntry,
    original_slots: []const SlotEntry,
};
const ReferenceDriver = struct {
    e: Author,
    d: frames.Definition,
    refs: references.Definition,
    entry: Id,
    input: Id,
    saved: Id,
    mapping: Id,
    prefix: Id,
    walked: Id,
    rebased: Id,
};

const ReferencePrepared = struct {
    core: base.Prepared,
    conversions: []Id,

    fn deinit(self: *ReferencePrepared) void {
        self.core.deinit();
        a.free(self.conversions);
    }
};

fn prepareReferenceFrames(comptime direct: bool) !ReferencePrepared {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const d = try frames.define(&b);
    const refs = try references.define(Activation, &b);
    const output = try projection.schema(ReferenceOutput, &b);
    const entry = try b.declare(&.{try projection.schema(ReferenceInput, &b)}, output, &.{}, &.{});
    const c: ReferenceDriver = .{
        .e = e,
        .d = d,
        .refs = refs,
        .entry = entry,
        .input = try e.param(entry, 0),
        .saved = try b.variable(d.schema),
        .mapping = try b.variable(refs.map.tree),
        .prefix = try b.variable(refs.refs.table),
        .walked = try b.variable(refs.refs.table),
        .rebased = try b.variable(d.schema),
    };
    var body = try referenceObservations(c, output);
    body = try b.term(.{ .yield_then = body });
    body = try b.bind(c.rebased, try referenceRebase(c, direct), body);
    body = try b.term(.{ .yield_then = body });
    body = try b.bind(c.walked, try referenceWalk(c, direct), body);
    body = try b.term(.{ .yield_then = body });
    body = try referenceConstruction(c, body);
    try b.define(entry, body);
    return prepareReferenceDriver(c);
}

fn prepareReferenceDriver(c: ReferenceDriver) !ReferencePrepared {
    const b = c.e.b;
    const scalar = try @import("scalar.zig").define(b);
    var compiled = try source.lowerObserved(a, b.module(c.entry, c.e.unit), .{ .recovery = true });
    defer compiled.deinit();
    var conversions: std.ArrayList(Id) = .empty;
    defer conversions.deinit(a);
    const functions = [_]Id{ c.d.to_public, c.d.from_public, scalar.encode };
    for (compiled.parameters) |binding| {
        if (std.mem.indexOfScalar(Id, &functions, binding.source_function) == null) continue;
        if (std.mem.indexOfScalar(Id, conversions.items, binding.function) != null) continue;
        try conversions.append(a, binding.function);
    }
    const image = try support.encodeCompiled(&compiled);
    defer a.free(image);
    var core = try base.Prepared.init(a, image);
    errdefer core.deinit();
    return .{ .core = core, .conversions = try conversions.toOwnedSlice(a) };
}

fn referenceConstruction(c: ReferenceDriver, tail: Id) !Id {
    const e = c.e;
    const b = e.b;
    const slots = try b.variable(c.d.slots.tree);
    const frame = try e.tuple(c.d.schema, &.{
        try b.constant(u64, 7), try b.constant(u64, 7),
        try b.reference(slots), try e.field(c.input, 3),
    });
    var body = try b.bind(c.saved, try b.pure(frame), tail);
    body = try b.bind(slots, try e.call(c.d.slots.from_sequence, &.{
        try e.field(c.input, 0),
    }), body);
    body = try b.bind(c.mapping, try e.call(c.refs.map.from_sequence, &.{
        try e.field(c.input, 1),
    }), body);
    return b.bind(c.prefix, try e.call(c.refs.refs.from_sequence, &.{
        try e.field(c.input, 2),
    }), body);
}

fn referenceWalk(c: ReferenceDriver, comptime direct: bool) !Id {
    const e = c.e;
    const b = e.b;
    if (direct) return e.call(c.d.walk_references, &.{
        try b.reference(c.saved), try b.reference(c.prefix),
    });
    const public = try b.variable(c.d.public);
    const projected = try e.call(c.d.to_public, &.{try b.reference(c.saved)});
    const walked = try e.call(c.refs.walk, &.{
        try b.reference(public), try b.reference(c.prefix),
    });
    return b.bind(public, projected, walked);
}

fn referenceRebase(c: ReferenceDriver, comptime direct: bool) !Id {
    const e = c.e;
    const b = e.b;
    if (direct) return e.call(c.d.rebase_references, &.{
        try b.reference(c.saved), try b.reference(c.mapping),
    });
    const public = try b.variable(c.d.public);
    const changed = try b.variable(c.d.public);
    const projected = try e.call(c.d.to_public, &.{try b.reference(c.saved)});
    const rebased = try e.call(c.refs.rebase, &.{
        try b.reference(public), try b.reference(c.mapping),
    });
    const hydrated = try e.call(c.d.from_public, &.{try b.reference(changed)});
    return b.bind(public, projected, try b.bind(changed, rebased, hydrated));
}

fn referenceObservations(c: ReferenceDriver, output: Id) !Id {
    const e = c.e;
    const b = e.b;
    const walked = try b.variable(c.refs.refs.sequence);
    const changed = try b.variable(c.d.public);
    const original = try b.variable(c.d.public);
    const slots = try b.variable(c.d.slots.entries);
    const original_slots = try b.variable(c.d.slots.entries);
    var body = try b.pure(try e.tuple(output, &.{
        try b.reference(walked), try b.reference(changed),        try b.reference(original),
        try b.reference(slots),  try b.reference(original_slots),
    }));
    body = try b.bind(original_slots, try e.call(c.d.slots.to_sequence, &.{
        try e.field(try b.reference(c.saved), 2),
    }), body);
    body = try b.bind(slots, try e.call(c.d.slots.to_sequence, &.{
        try e.field(try b.reference(c.rebased), 2),
    }), body);
    body = try b.bind(original, try e.call(c.d.to_public, &.{try b.reference(c.saved)}), body);
    body = try b.bind(changed, try e.call(c.d.to_public, &.{try b.reference(c.rebased)}), body);
    return b.bind(walked, try e.call(c.refs.refs.to_sequence, &.{
        try b.reference(c.walked),
    }), body);
}

const ReferenceRun = struct {
    decoded: projection.Owned(ReferenceOutput),
    walk_steps: usize,
    rebase_steps: usize,
    walk_conversions: u64,
    rebase_conversions: u64,
};

fn runReferenceFrames(prepared: *ReferencePrepared, input: ReferenceInput) !ReferenceRun {
    const bytes = try projection.encode(ReferenceInput, a, input);
    defer a.free(bytes);
    var session = try base.Session.start(a, &prepared.core, bytes, .{});
    defer session.deinit();
    try std.testing.expect(try session.run(null) == .yielded);
    const constructed = session.transitions;
    var conversions: u64 = 0;
    session.entry_counter = .{ .functions = prepared.conversions, .count = &conversions };
    try session.resumeYield();
    try std.testing.expect(try session.run(null) == .yielded);
    const walked = session.transitions;
    const walk_conversions = conversions;
    conversions = 0;
    try session.resumeYield();
    try std.testing.expect(try session.run(null) == .yielded);
    const rebased = session.transitions;
    const rebase_conversions = conversions;
    session.entry_counter = null;
    try session.resumeYield();
    const result = try session.run(null);
    try std.testing.expect(result == .completed);
    return .{
        .decoded = try projection.decode(ReferenceOutput, a, try session.bytes(&result.completed)),
        .walk_steps = walked - constructed,
        .rebase_steps = rebased - walked,
        .walk_conversions = walk_conversions,
        .rebase_conversions = rebase_conversions,
    };
}

const raw_reference_slots = [_]SlotEntry{
    .{ .key = 0, .value = .{ .scalar = .{ .schema = 7, .bits = 0 } } },
    .{ .key = 1 << 63, .value = .{ .scalar = .{ .schema = 7, .bits = 0xfedcba9876543210 } } },
    .{ .key = std.math.maxInt(u64), .value = .{ .scalar = .{
        .schema = 7,
        .bits = std.math.maxInt(u64),
    } } },
};
const mixed_reference_slots = [_]SlotEntry{
    .{ .key = 0, .value = .{ .value = frame_scalar } },
    .{ .key = 2, .value = .{ .scalar = .{ .schema = 7, .bits = 7 } } },
    .{ .key = 3, .value = .{ .value = .{ .schema = 7, .body = .{ .blob = .{ .id = 7 } } } } },
    .{ .key = 5, .value = .{ .value = .{ .schema = 7, .body = .{ .reference = .{ .id = 7 } } } } },
    .{ .key = 7, .value = .{ .value = owned(8) } },
    .{ .key = 9, .value = .{ .value = owned(9) } },
    .{ .key = 1 << 63, .value = .{ .value = .{
        .schema = 7,
        .body = .{ .reference = .{ .id = 7 } },
    } } },
    raw_reference_slots[2],
};
const reference_mapping = [_][]const MappingEntry{
    &.{},
    &.{.{ .key = 99, .value = .{ .id = 100 } }},
    &.{.{ .key = 7, .value = .{ .id = 7 } }},
    &.{ .{ .key = 7, .value = .{ .id = 8 } }, .{ .key = 8, .value = .{ .id = 9 } } },
    &.{ .{ .key = 8, .value = .{ .id = 70 } }, .{ .key = 9, .value = .{ .id = 80 } } },
};

fn mappedReference(id: u64, mapping: []const MappingEntry) u64 {
    for (mapping) |entry| if (entry.key == id) return entry.value.id;
    return id;
}

fn expectedReferenceSlot(slot: frames.Slot, mapping: []const MappingEntry) frames.Slot {
    var result = slot;
    switch (result) {
        .scalar => {},
        .value => |*value| switch (value.body) {
            .scalar, .blob => {},
            .reference => |*node| node.id = mappedReference(node.id, mapping),
            .owned => |*owner| owner.node.id = mappedReference(owner.node.id, mapping),
        },
    }
    return result;
}

fn expectReferenceLaws(
    input: ReferenceInput,
    actual: ReferenceOutput,
    public: ReferenceOutput,
) !void {
    try std.testing.expectEqualDeep(public.walked, actual.walked);
    try std.testing.expectEqualDeep(public.changed, actual.changed);
    try std.testing.expectEqualDeep(public.original, actual.original);
    try std.testing.expectEqualDeep(input.slots, actual.original_slots);
    try std.testing.expectEqualDeep(input.owners, actual.changed.owners);
    try std.testing.expectEqual(@as(u64, 7), actual.changed.scope);
    try std.testing.expectEqual(@as(u64, 7), actual.changed.position);
    try std.testing.expectEqual(input.slots.len, actual.slots.len);
    for (input.slots, actual.slots) |before, after| {
        try std.testing.expectEqual(before.key, after.key);
        try std.testing.expectEqualDeep(
            expectedReferenceSlot(before.value, input.mapping),
            after.value,
        );
    }
}

test "direct frame references preserve occurrence order raw slots and predecessor versions" {
    var direct = try prepareReferenceFrames(true);
    defer direct.deinit();
    var public = try prepareReferenceFrames(false);
    defer public.deinit();
    const prefix = [_]data.graph.NodeRef{ .{ .id = 91 }, .{ .id = 7 } };
    for ([_][]const SlotEntry{ &.{}, &raw_reference_slots, &mixed_reference_slots }) |slots| {
        const owners: []const data.process_state.Owner = if (slots.len == mixed_reference_slots.len)
            &.{ .{ .scope = 7, .slot = 9 }, .{ .scope = 7, .slot = 7 } }
        else
            &.{};
        for (reference_mapping) |mapping| {
            const input: ReferenceInput = .{
                .slots = slots,
                .mapping = mapping,
                .prefix = &prefix,
                .owners = owners,
            };
            var actual = try runReferenceFrames(&direct, input);
            defer actual.decoded.deinit();
            var expected = try runReferenceFrames(&public, input);
            defer expected.decoded.deinit();
            try expectReferenceLaws(input, actual.decoded.value, expected.decoded.value);
            const occurrences: []const data.graph.NodeRef = if (owners.len != 0)
                &.{
                    .{ .id = 91 }, .{ .id = 7 }, .{ .id = 7 },
                    .{ .id = 8 },  .{ .id = 9 }, .{ .id = 7 },
                }
            else
                &prefix;
            try std.testing.expectEqualDeep(occurrences, actual.decoded.value.walked);
        }
    }
}

const ValueChange = union(enum) { unchanged: void, changed: data.graph.Value };
const ValueInput = struct { value: data.graph.Value, mapping: []const MappingEntry };
const ValueOutput = struct { change: ValueChange, expected: data.graph.Value };

fn prepareValueRebase() !base.Prepared {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const d = try references.defineValueRebase(&b);
    const generic = try references.define(data.graph.Value, &b);
    const output = try projection.schema(ValueOutput, &b);
    const entry = try b.declare(&.{try projection.schema(ValueInput, &b)}, output, &.{}, &.{});
    const input = try e.param(entry, 0);
    const mapping = try b.variable(d.map.tree);
    const changed = try b.variable(d.result);
    const expected = try b.variable(try projection.schema(data.graph.Value, &b));
    var body = try b.pure(try e.tuple(output, &.{
        try b.reference(changed), try b.reference(expected),
    }));
    body = try b.bind(expected, try e.call(generic.rebase, &.{
        try e.field(input, 0), try b.reference(mapping),
    }), body);
    body = try b.bind(changed, try e.call(d.rebase, &.{
        try e.field(input, 0), try b.reference(mapping),
    }), body);
    body = try b.bind(mapping, try e.call(d.map.from_sequence, &.{try e.field(input, 1)}), body);
    try b.define(entry, body);
    return support.prepare(b.module(entry, e.unit));
}

fn expectValueChange(prepared: *base.Prepared, input: ValueInput) !void {
    const bytes = try projection.encode(ValueInput, a, input);
    defer a.free(bytes);
    var session = try base.Session.start(a, prepared, bytes, .{});
    defer session.deinit();
    const outcome = try session.run(null);
    try std.testing.expect(outcome == .completed);
    var result = try projection.decode(ValueOutput, a, try session.bytes(&outcome.completed));
    defer result.deinit();
    const expected = expectedReferenceSlot(.{ .value = input.value }, input.mapping).value;
    const actual = switch (result.value.change) {
        .unchanged => input.value,
        .changed => |value| value,
    };
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectEqualDeep(result.value.expected, actual);
    const differs = switch (input.value.body) {
        .scalar, .blob => false,
        .reference => |node| node.id != mappedReference(node.id, input.mapping),
        .owned => |owner| owner.node.id != mappedReference(owner.node.id, input.mapping),
    };
    try std.testing.expectEqual(differs, result.value.change == .changed);
}

test "value rebase changes exactly mapped node ids in each graph value variant" {
    var prepared = try prepareValueRebase();
    defer prepared.deinit();
    const values = [_]data.graph.Value{
        frame_scalar,
        .{ .schema = 7, .body = .{ .blob = .{ .id = 7 } } },
        .{ .schema = 7, .body = .{ .reference = .{ .id = 7 } } },
        owned(7),
    };
    for (values) |value| for (reference_mapping) |mapping| {
        try expectValueChange(&prepared, .{ .value = value, .mapping = mapping });
    };
}

fn measuredReferenceSlots(width: usize, reference_count: usize) ![]SlotEntry {
    const slots = try a.alloc(SlotEntry, width);
    for (slots, 0..) |*slot, i| slot.* = .{
        .key = @as(u64, @intCast(i)) * 1024,
        .value = if (i < reference_count)
            .{ .value = .{ .schema = 7, .body = .{ .reference = .{
                .id = 7 + @as(u64, @intCast(i % 2)),
            } } } }
        else
            .{ .scalar = .{ .schema = 7, .bits = 0xfedcba9876543210 + @as(u64, @intCast(i)) } },
    };
    return slots;
}

test "direct frame traversal reduces base work across scalar widths and reference density" {
    var direct = try prepareReferenceFrames(true);
    defer direct.deinit();
    var public = try prepareReferenceFrames(false);
    defer public.deinit();
    const Case = struct { width: usize, refs: usize, mapping: usize = 3 };
    const cases = [_]Case{
        .{ .width = 8, .refs = 2 },
        .{ .width = 64, .refs = 2 },
        .{ .width = 256, .refs = 2 },
        .{ .width = 16, .refs = 16 },
        .{ .width = 64, .refs = 2, .mapping = 1 },
        .{ .width = 64, .refs = 0 },
    };
    for (cases) |case| {
        const slots = try measuredReferenceSlots(case.width, case.refs);
        defer a.free(slots);
        const input: ReferenceInput = .{
            .slots = slots,
            .mapping = reference_mapping[case.mapping],
            .prefix = &.{.{ .id = 91 }},
            .owners = &.{},
        };
        var actual = try runReferenceFrames(&direct, input);
        defer actual.decoded.deinit();
        var expected = try runReferenceFrames(&public, input);
        defer expected.decoded.deinit();
        try expectReferenceLaws(input, actual.decoded.value, expected.decoded.value);
        try std.testing.expect(actual.walk_steps < expected.walk_steps);
        try std.testing.expect(actual.rebase_steps < expected.rebase_steps);
        try std.testing.expectEqual(@as(u64, 0), actual.walk_conversions);
        try std.testing.expectEqual(@as(u64, 0), actual.rebase_conversions);
        try std.testing.expect(expected.walk_conversions > 0);
        try std.testing.expect(expected.rebase_conversions > 0);
        std.debug.print(
            "frame references width={d} refs={d} mapping={d}: walk={d}/{d} rebase={d}/{d}\n",
            .{
                case.width,          case.refs,         case.mapping,
                expected.walk_steps, actual.walk_steps, expected.rebase_steps,
                actual.rebase_steps,
            },
        );
    }
}
