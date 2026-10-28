const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const clones = @import("clone.zig");
const references = @import("references.zig");
const Author = @import("author.zig").Author;
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");
const g = data.graph;
const Binding = struct { id: u64, replacement: g.NodeRef };
const Input = struct {
    state: data.process_state.State,
    mapping: []const Binding,
    originals: []const g.NodeRef,
    cursor: u64,
    tasks: []const clones.Task,
    context: bool,
    malformed_frame: bool = false,
};

fn prepare(comptime mixed: bool) !base.Prepared {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const m = try machines.define(&b);
    const clone = try clones.define(&b, m);
    const validation = try @import("clone_validation.zig").define(&b, m, clone);
    const refs = try references.define(g.Node, &b);
    const tasks = try @import("table.zig").define(&b, try projection.schema(clones.Task, &b));
    const set = try @import("sets.zig").define(&b);
    const lists = try @import("map.zig").define(&b, refs.refs.table);
    const entry = try b.declare(&.{
        m.program, try projection.schema(Input, &b),
    }, e.boolean, &.{}, &.{});
    const input = try e.param(entry, 1);
    const machine = try b.variable(m.schema);
    const mapping = try b.variable(refs.map.tree);
    const originals = try b.variable(refs.refs.table);
    const queued = try b.variable(tasks.table);
    const ctx = try e.tuple(clone.context, &.{
        try b.reference(machine),
        try b.reference(mapping),
        try b.reference(originals),
        try set.map.empty(e),
        try set.map.empty(e),
        try lists.empty(e),
        try lists.empty(e),
        try b.reference(queued),
    });
    const check = try e.when(try e.field(input, 5), try e.call(
        validation.context,
        &.{ ctx, try e.field(input, 3) },
    ), try e.call(validation.rebase, &.{
        try b.reference(machine),
        try b.reference(mapping),
        try b.reference(originals),
        try e.field(input, 3),
    }));
    const load = try loadMachine(e, m, input, try e.param(entry, 0), mixed);
    try b.define(entry, try b.bind(machine, load, try b.bind(mapping, try e.call(
        refs.map.from_sequence,
        &.{try e.field(input, 1)},
    ), try b.bind(originals, try e.call(
        refs.refs.from_sequence,
        &.{try e.field(input, 2)},
    ), try b.bind(queued, try e.call(
        tasks.from_sequence,
        &.{try e.field(input, 4)},
    ), check)))));
    return support.prepare(b.module(entry, e.unit));
}

test "clone phase validation checks submitted mapping records cursors and work lists" {
    var core = try prepare(false);
    defer core.deinit();
    const owner = try core.acquire();
    defer owner.release();
    const program = try projection.programBytes(a, owner.admitted());
    defer a.free(program);
    for (0..11) |case| {
        const cursor: u64 = switch (case) {
            0 => 0,
            1 => 1,
            2 => 2,
            6 => 3,
            8, 9, 10 => 0,
            else => 1,
        };
        const old0: [2]g.Value = @splat(.{ .schema = 0, .body = .{ .reference = .{ .id = 1 } } });
        const old1 = [_]g.Value{.{ .schema = 0, .body = .{ .reference = .{ .id = 0 } } }};
        var new0 = old0;
        var new1 = old1;
        if (cursor > 0) {
            for (&new0) |*v| v.body.reference.id = 3;
        }
        if (cursor > 1) new1[0].body.reference.id = 2;
        if (case == 3) new0[1].body.reference.id = 2; // breaks one alias
        if (case == 7) new0[0].body.reference.id = 4; // outside the node table
        const nodes = [_]data.process_state.Node{
            .{ .record = .{ .environment = .{ .values = &old0, .tail = null } } },
            .{ .record = .{ .environment = .{ .values = &old1, .tail = null } } },
            .{ .record = .{ .environment = .{ .values = &new0, .tail = null } } },
            .{ .record = .{ .environment = .{ .values = &new1, .tail = null } } },
        };
        var mapping = [_]Binding{ .{
            .id = 0,
            .replacement = .{ .id = 2 },
        }, .{ .id = 1, .replacement = .{ .id = 3 } } };
        if (case == 4) mapping[1].replacement.id = 2;
        const arguments = try projection.encode(Input, a, .{
            .state = .{
                .program_identity = owner.admitted().identity(),
                .status = .active,
                .roots = .{},
                .nodes = &nodes,
                .blobs = &.{},
            },
            .mapping = if (case == 5) mapping[0..1] else &mapping,
            .originals = &.{ .{ .id = 0 }, .{ .id = 1 } },
            .cursor = cursor,
            .tasks = &.{.{
                .kind = if (case == 9) 2 else 0,
                .reference = .{ .id = if (case == 10) 2 else 0 },
            }},
            .context = case >= 8,
        });
        defer a.free(arguments);
        const input = try std.mem.concat(a, u8, &.{ program, arguments });
        defer a.free(input);
        var session = try base.Session.start(a, &core, input, .{});
        defer session.deinit();
        const outcome = try session.run(null);
        try std.testing.expect(outcome == .completed);
        var valid = try projection.decode(bool, a, try session.bytes(&outcome.completed));
        defer valid.deinit();
        try std.testing.expectEqual(case <= 2 or case == 8, valid.value);
    }
}

const mixed_bits: u64 = 0xfedcba9876543210;

fn loadMachine(
    e: Author,
    m: machines.Definition,
    input: data.program.Id,
    program: data.program.Id,
    comptime mixed: bool,
) !data.program.Id {
    const hydrate = try e.call(m.hydrate, &.{ program, try e.field(input, 0) });
    if (!mixed) return hydrate;
    const hydrated = try e.b.variable(m.schema);
    const first = try e.b.variable(m.schema);
    return e.b.bind(hydrated, hydrate, try e.b.bind(first, try rawFrameNode(
        e,
        m,
        try e.b.reference(hydrated),
        0,
        try e.b.constant(bool, false),
    ), try rawFrameNode(e, m, try e.b.reference(first), 2, try e.field(input, 6))));
}

fn rawFrameNode(
    e: Author,
    m: machines.Definition,
    machine: data.program.Id,
    index: u64,
    malformed: data.program.Id,
) !data.program.Id {
    const b = e.b;
    const found = try b.variable(m.nodes.optional);
    const node = try e.payload(try b.reference(found), 1);
    const frame = try e.payload(try e.field(node, 1), 1);
    const written = try b.variable(m.frames.schema);
    const changed = try b.variable(m.frames.schema);
    const nodes = try b.variable(m.nodes.table);
    const optional = b.schemas.items[@intCast(m.nodes.element)].product[1];
    const raw = try e.literal(@import("frames.zig").Scalar, .{ .schema = 0, .bits = mixed_bits });
    const slot = try e.variant(m.frames.slot, 1, raw);
    const leaf = try e.variant(m.frames.slots.tree, 1, try e.tuple(m.frames.slots.entry, &.{
        e.one, slot,
    }));
    const duplicate = try e.variant(m.frames.slots.tree, 2, try e.tuple(m.frames.slots.branch, &.{
        e.one, leaf, leaf,
    }));
    const edited = try e.replace(node, 1, try e.variant(optional, 1, try b.reference(changed)));
    const install = try b.bind(nodes, try e.call(m.nodes.set, &.{
        try m.field(e, machine, .nodes), try b.constant(u64, index), edited,
    }), try b.pure(try e.replace(
        machine,
        @backingInt(machines.Field.nodes),
        try b.reference(nodes),
    )));
    const choose = try b.bind(changed, try e.when(malformed, try b.pure(try e.replace(
        try b.reference(written),
        2,
        duplicate,
    )), try b.pure(try b.reference(written))), install);
    const retained = try b.variable(m.frames.slots.optional);
    const observed = try e.payload(try e.payload(try b.reference(retained), 1), 1);
    const checked = try b.bind(retained, try e.call(m.frames.slots.get, &.{
        try e.field(try b.reference(written), 2), e.one,
    }), try e.when(
        try e.binary(.equal, try e.field(observed, 1), try b.constant(u64, mixed_bits)),
        choose,
        try e.fail(),
    ));
    return b.bind(found, try e.call(m.nodes.get, &.{
        try m.field(e, machine, .nodes), try b.constant(u64, index),
    }), try b.bind(written, try e.call(m.frames.write_raw, &.{ frame, e.one, raw }), checked));
}

fn mixedCloneInput(identity: [32]u8, cursor: u64, malformed: bool) ![]u8 {
    const scalar: data.process_state.Binding = .{
        .slot = 1,
        .value = .{ .schema = 0, .body = .{ .scalar = std.mem.toBytes(mixed_bits) } },
    };
    const old = [_]data.process_state.Binding{ scalar, .{
        .slot = 9,
        .value = .{ .schema = 0, .body = .{ .reference = .{ .id = 1 } } },
    } };
    var next = old;
    if (cursor > 0) next[1].value.body.reference.id = 3;
    const nodes = [_]data.process_state.Node{
        .{ .record = .{ .control = .{ .block = 0 } }, .activation = .{
            .position = 0,
            .scope = 0,
            .bindings = &old,
            .owners = &.{},
        } },
        .{ .record = .{ .environment = .{ .values = &.{}, .tail = .{ .id = 0 } } } },
        .{ .record = .{ .control = .{ .block = 0 } }, .activation = .{
            .position = 0,
            .scope = 0,
            .bindings = &next,
            .owners = &.{},
        } },
        .{ .record = .{ .environment = .{
            .values = &.{},
            .tail = .{ .id = if (cursor > 1) 2 else 0 },
        } } },
    };
    return projection.encode(Input, a, .{
        .state = .{
            .program_identity = identity,
            .status = .active,
            .roots = .{},
            .nodes = &nodes,
        },
        .mapping = &.{ .{ .id = 0, .replacement = .{ .id = 2 } }, .{
            .id = 1,
            .replacement = .{ .id = 3 },
        } },
        .originals = &.{ .{ .id = 0 }, .{ .id = 1 } },
        .cursor = cursor,
        .tasks = &.{},
        .context = false,
        .malformed_frame = malformed,
    });
}

test "clone validation preserves mixed raw frames across the rebase cursor" {
    var core = try prepare(true);
    defer core.deinit();
    const owner = try core.acquire();
    defer owner.release();
    const program = try projection.programBytes(a, owner.admitted());
    defer a.free(program);
    for (0..3) |cursor| for ([_]bool{ false, true }) |malformed| {
        const arguments = try mixedCloneInput(owner.admitted().identity(), cursor, malformed);
        defer a.free(arguments);
        const input = try std.mem.concat(a, u8, &.{ program, arguments });
        defer a.free(input);
        var session = try base.Session.start(a, &core, input, .{});
        defer session.deinit();
        const outcome = try session.run(null);
        try std.testing.expect(outcome == .completed);
        var valid = try projection.decode(bool, a, try session.bytes(&outcome.completed));
        defer valid.deinit();
        try std.testing.expectEqual(!malformed, valid.value);
    };
}
