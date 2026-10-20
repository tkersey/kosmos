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
};

fn prepare() !base.Prepared {
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
    try b.define(entry, try b.bind(machine, try e.call(m.hydrate, &.{
        try e.param(entry, 0), try e.field(input, 0),
    }), try b.bind(mapping, try e.call(
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
    var core = try prepare();
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
