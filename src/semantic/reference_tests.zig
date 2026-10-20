const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const references = @import("references.zig");
const Author = @import("author.zig").Author;
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");
const g = data.graph;
const Binding = struct { id: u64, replacement: g.NodeRef };
const Input = struct { node: g.Node, mapping: []const Binding };
const Output = struct { node: g.Node, references: []const g.NodeRef };

fn prepare() !base.Prepared {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const graph = try references.define(g.Node, &b);
    const entry = try b.declare(
        &.{try projection.schema(Input, &b)},
        try projection.schema(Output, &b),
        &.{},
        &.{},
    );
    const input = try e.param(entry, 0);
    const map = try b.variable(graph.map.tree);
    const changed = try b.variable(try projection.schema(g.Node, &b));
    const refs = try b.variable(graph.refs.table);
    const listed = try b.variable(graph.refs.sequence);
    try b.define(entry, try b.bind(map, try e.call(
        graph.map.from_sequence,
        &.{try e.field(input, 1)},
    ), try b.bind(changed, try e.call(graph.rebase, &.{
        try e.field(input, 0), try b.reference(map),
    }), try b.bind(refs, try e.call(
        graph.references,
        &.{try b.reference(changed)},
    ), try b.bind(listed, try e.call(
        graph.refs.to_sequence,
        &.{try b.reference(refs)},
    ), try b.pure(try e.tuple(try projection.schema(Output, &b), &.{
        try b.reference(changed), try b.reference(listed),
    })))))));
    return support.prepare(b.module(entry, e.unit));
}

test "authored reference traversal preserves aliases and separates blob identity" {
    var core = try prepare();
    defer core.deinit();

    for (reference_cases) |case| {
        const input = try projection.encode(Input, a, .{ .node = case.before, .mapping = &.{ .{
            .id = 1,
            .replacement = .{ .id = 101 },
        }, .{
            .id = 3,
            .replacement = .{ .id = 103 },
        }, .{ .id = 5, .replacement = .{ .id = 105 } } } });
        defer a.free(input);
        var session = try base.Session.start(a, &core, input, .{});
        defer session.deinit();
        const outcome = try session.run(null);
        try std.testing.expect(outcome == .completed);
        var output = try projection.decode(Output, a, try session.bytes(&outcome.completed));
        defer output.deinit();
        const expected = try projection.encode(g.Node, a, case.after);
        defer a.free(expected);
        const actual = try projection.encode(g.Node, a, output.value.node);
        defer a.free(actual);
        try std.testing.expectEqualSlices(u8, expected, actual);
        try std.testing.expectEqualSlices(g.NodeRef, case.refs, output.value.references);
    }
}

const reference_cases = [_]struct { before: g.Node, after: g.Node, refs: []const g.NodeRef }{
    .{ .before = .{ .control = .{
        .block = 1,
        .parent = .{ .id = 1 },
        .evidence = .{ .id = 2 },
        .region = .{ .id = 1 },
    } }, .after = .{ .control = .{
        .block = 1,
        .parent = .{ .id = 101 },
        .evidence = .{ .id = 2 },
        .region = .{ .id = 101 },
    } }, .refs = &.{ .{ .id = 101 }, .{ .id = 2 }, .{ .id = 101 } } },
    .{ .before = .{ .environment = .{ .values = &.{ .{
        .schema = 1,
        .body = .{ .reference = .{ .id = 1 } },
    }, .{ .schema = 2, .body = .{ .blob = .{ .id = 3 } } }, .{ .schema = 3, .body = .{
        .owned = .{ .node = .{ .id = 3 } },
    } } }, .tail = null } }, .after = .{ .environment = .{ .values = &.{ .{
        .schema = 1,
        .body = .{ .reference = .{ .id = 101 } },
    }, .{ .schema = 2, .body = .{ .blob = .{ .id = 3 } } }, .{ .schema = 3, .body = .{
        .owned = .{ .node = .{ .id = 103 } },
    } } }, .tail = null } }, .refs = &.{ .{ .id = 101 }, .{ .id = 103 } } },
    .{
        .before = .{
            .multi_template = .{
                .schema = 1,
                .capture = .{ .id = 3 },
                .delimiter = .{ .id = 5 },
                .evidence = .{ .id = 5 },
                .use_site_capabilities = &.{
                    .{ .schema = 1, .body = .{ .reference = .{ .id = 1 } } },
                    .{ .schema = 1, .body = .{ .reference = .{ .id = 1 } } },
                },
            },
        },
        .after = .{
            .multi_template = .{
                .schema = 1,
                .capture = .{ .id = 103 },
                .delimiter = .{ .id = 105 },
                .evidence = .{ .id = 105 },
                .use_site_capabilities = &.{
                    .{ .schema = 1, .body = .{ .reference = .{ .id = 101 } } },
                    .{ .schema = 1, .body = .{ .reference = .{ .id = 101 } } },
                },
            },
        },
        .refs = &.{
            .{ .id = 103 }, .{ .id = 105 }, .{ .id = 105 }, .{ .id = 101 }, .{ .id = 101 },
        },
    },
};
