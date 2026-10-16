//! Guest reachability collection in ordinary Horos. Maps are established before
//! rebasing, preserving cycles and identity. Canonical byte interning belongs to
//! publication; collection only removes unreachable records and blob entries.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const references = @import("references.zig");
const tables = @import("table.zig");
const control = @import("control.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
pub const Definition = struct { run: Id };

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.collect/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const roots = try references.define(g.Roots, b);
    const nodes = try references.define(data.process_state.Node, b);
    const blobs = try references.defineBlobs(data.process_state.Node, b);
    const reference = try projection.schema(g.NodeRef, b);
    const public_node = try projection.schema(data.process_state.Node, b);
    const live = try tables.define(b, public_node);
    const discovered = try b.schema(.{ .product = &.{ nodes.map.tree, live.table, blobs.refs.table } });
    const mark = try b.declare(&.{ m.schema, nodes.refs.table, e.integer, nodes.map.tree, live.table, blobs.refs.table }, discovered, &.{}, &.{});
    {
        const input = try e.param(mark, 0);
        const queue = try e.param(mark, 1);
        const cursor = try e.param(mark, 2);
        const mapping = try e.param(mark, 3);
        const ordered = try e.param(mark, 4);
        const blob_queue = try e.param(mark, 5);
        const next = try e.binary(.integer_add, cursor, e.one);
        const selected_ref = try b.variable(nodes.refs.optional);
        const original = try e.payload(try b.reference(selected_ref), 1);
        const id = try e.field(original, 0);
        const found = try b.variable(nodes.map.optional);
        const element = try b.variable(m.nodes.optional);
        const node = try b.variable(public_node);
        const new_map = try b.variable(nodes.map.tree);
        const new_live = try b.variable(live.table);
        const new_queue = try b.variable(nodes.refs.table);
        const new_blob_queue = try b.variable(blobs.refs.table);
        const allocated = try e.tuple(reference, &.{try e.field(ordered, 0)});
        var visit = try e.call(mark, &.{ input, try b.reference(new_queue), next, try b.reference(new_map), try b.reference(new_live), try b.reference(new_blob_queue) });
        visit = try b.bind(new_blob_queue, try e.call(blobs.walk, &.{ try b.reference(node), blob_queue }), visit);
        visit = try b.bind(new_queue, try e.call(nodes.walk, &.{ try b.reference(node), queue }), visit);
        visit = try b.bind(new_live, try e.call(live.append, &.{ ordered, try b.reference(node) }), visit);
        visit = try b.bind(new_map, try e.call(nodes.map.set, &.{ mapping, id, allocated }), visit);
        visit = try b.bind(node, try e.call(m.node_to_public, &.{try e.payload(try b.reference(element), 1)}), visit);
        visit = try b.bind(element, try e.call(m.nodes.get, &.{ try m.field(e, input, .nodes), id }), visit);
        const skip = try e.call(mark, &.{ input, queue, next, mapping, ordered, blob_queue });
        const choose = try e.when(try @import("unwind.zig").is(e, try b.reference(found), 0), visit, skip);
        const more = try b.bind(selected_ref, try e.call(nodes.refs.get, &.{ queue, cursor }), try b.bind(found, try e.call(nodes.map.get, &.{ mapping, id }), choose));
        try b.define(mark, try e.when(try e.binary(.less, cursor, try e.field(queue, 0)), more, try b.pure(try e.tuple(discovered, &.{ mapping, ordered, blob_queue }))));
    }
    const blob_result = try b.schema(.{ .product = &.{ blobs.map.tree, m.blobs.table } });
    const mark_blobs = try b.declare(&.{ m.schema, blobs.refs.table, e.integer, blobs.map.tree, m.blobs.table }, blob_result, &.{}, &.{});
    {
        const input = try e.param(mark_blobs, 0);
        const queue = try e.param(mark_blobs, 1);
        const cursor = try e.param(mark_blobs, 2);
        const mapping = try e.param(mark_blobs, 3);
        const ordered = try e.param(mark_blobs, 4);
        const next = try e.binary(.integer_add, cursor, e.one);
        const selected_ref = try b.variable(blobs.refs.optional);
        const id = try e.field(try e.payload(try b.reference(selected_ref), 1), 0);
        const found = try b.variable(blobs.map.optional);
        const selected = try b.variable(m.blobs.optional);
        const new_map = try b.variable(blobs.map.tree);
        const new_table = try b.variable(m.blobs.table);
        const allocated = try e.tuple(try projection.schema(g.BlobRef, b), &.{try e.field(ordered, 0)});
        var visit = try e.call(mark_blobs, &.{ input, queue, next, try b.reference(new_map), try b.reference(new_table) });
        visit = try b.bind(new_table, try e.call(m.blobs.append, &.{ ordered, try e.payload(try b.reference(selected), 1) }), visit);
        visit = try b.bind(new_map, try e.call(blobs.map.set, &.{ mapping, id, allocated }), visit);
        visit = try b.bind(selected, try e.call(m.blobs.get, &.{ try m.field(e, input, .blobs), id }), visit);
        const skip = try e.call(mark_blobs, &.{ input, queue, next, mapping, ordered });
        const choose = try e.when(try @import("unwind.zig").is(e, try b.reference(found), 0), visit, skip);
        const more = try b.bind(selected_ref, try e.call(blobs.refs.get, &.{ queue, cursor }), try b.bind(found, try e.call(blobs.map.get, &.{ mapping, id }), choose));
        try b.define(mark_blobs, try e.when(try e.binary(.less, cursor, try e.field(queue, 0)), more, try b.pure(try e.tuple(blob_result, &.{ mapping, ordered }))));
    }
    const rebase = try b.declare(&.{ live.table, e.integer, nodes.map.tree, blobs.map.tree, m.nodes.table }, m.nodes.table, &.{}, &.{});
    {
        const input = try e.param(rebase, 0);
        const cursor = try e.param(rebase, 1);
        const node_map = try e.param(rebase, 2);
        const blob_map = try e.param(rebase, 3);
        const output = try e.param(rebase, 4);
        const selected = try b.variable(live.optional);
        const moved_nodes = try b.variable(public_node);
        const moved_blobs = try b.variable(public_node);
        const internal = try b.variable(m.nodes.element);
        const appended = try b.variable(m.nodes.table);
        var more = try e.call(rebase, &.{ input, try e.binary(.integer_add, cursor, e.one), node_map, blob_map, try b.reference(appended) });
        more = try b.bind(appended, try e.call(m.nodes.append, &.{ output, try b.reference(internal) }), more);
        more = try b.bind(internal, try e.call(m.node_from_public, &.{try b.reference(moved_blobs)}), more);
        more = try b.bind(moved_blobs, try e.call(blobs.rebase, &.{ try b.reference(moved_nodes), blob_map }), more);
        more = try b.bind(moved_nodes, try e.call(nodes.rebase, &.{ try e.payload(try b.reference(selected), 1), node_map }), more);
        more = try b.bind(selected, try e.call(live.get, &.{ input, cursor }), more);
        try b.define(rebase, try e.when(try e.binary(.less, cursor, try e.field(input, 0)), more, try b.pure(output)));
    }
    const d: Definition = .{ .run = try b.declare(&.{m.schema}, m.schema, &.{}, &.{}) };
    {
        const input = try e.param(d.run, 0);
        const initial = try b.variable(nodes.refs.table);
        const marked = try b.variable(discovered);
        const marked_blobs = try b.variable(blob_result);
        const new_nodes = try b.variable(m.nodes.table);
        const new_roots = try b.variable(try projection.schema(g.Roots, b));
        var result = try e.replace(input, @backingInt(machines.Field.nodes), try b.reference(new_nodes));
        result = try e.replace(result, @backingInt(machines.Field.blobs), try e.field(try b.reference(marked_blobs), 1));
        result = try control.withRoots(e, result, try b.reference(new_roots));
        var body = try b.bind(new_roots, try e.call(roots.rebase, &.{ try control.roots(e, m, input), try e.field(try b.reference(marked), 0) }), try b.pure(result));
        body = try b.bind(new_nodes, try e.call(rebase, &.{ try e.field(try b.reference(marked), 1), e.zero, try e.field(try b.reference(marked), 0), try e.field(try b.reference(marked_blobs), 0), try m.nodes.empty(b) }), body);
        body = try b.bind(marked_blobs, try e.call(mark_blobs, &.{ input, try e.field(try b.reference(marked), 2), e.zero, try blobs.map.empty(e), try m.blobs.empty(b) }), body);
        body = try b.bind(marked, try e.call(mark, &.{ input, try b.reference(initial), e.zero, try nodes.map.empty(e), try live.empty(b), try blobs.refs.empty(b) }), body);
        try b.define(d.run, try b.bind(initial, try e.call(roots.references, &.{try control.roots(e, m, input)}), body));
    }
    return cache.finish(b, d);
}
