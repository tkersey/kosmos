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
    const discovered = try b.schema(.{ .product = &.{
        nodes.map.tree, live.table, blobs.refs.table,
    } });
    const mark = try b.declare(&.{
        m.schema, nodes.refs.table, e.integer, nodes.map.tree, live.table, blobs.refs.table,
    }, discovered, &.{}, &.{});
    try emitMark(m, e, nodes, blobs, reference, public_node, live, discovered, mark);
    const blob_result = try b.schema(.{ .product = &.{ blobs.map.tree, m.blobs.table } });
    const mark_blobs = try b.declare(&.{
        m.schema, blobs.refs.table, e.integer, blobs.map.tree, m.blobs.table,
    }, blob_result, &.{}, &.{});
    try emitMarkBlobs(m, e, blobs, blob_result, mark_blobs);
    const rebase = try b.declare(&.{
        live.table, e.integer, nodes.map.tree, blobs.map.tree, m.nodes.table,
    }, m.nodes.table, &.{}, &.{});
    try emitRebase(m, e, nodes, blobs, public_node, live, rebase);
    const d: Definition = .{ .run = try b.declare(&.{m.schema}, m.schema, &.{}, &.{}) };
    try emitRun(
        m,
        e,
        roots,
        nodes,
        blobs,
        live,
        discovered,
        mark,
        blob_result,
        mark_blobs,
        rebase,
        d,
    );
    return cache.finish(b, d);
}

fn emitMark(
    m: machines.Definition,
    e: Author,
    nodes: references.Definition,
    blobs: anytype,
    reference: Id,
    public_node: Id,
    live: tables.Definition,
    discovered: Id,
    mark: Id,
) Error!void {
    const input = try e.param(mark, 0);
    const queue = try e.param(mark, 1);
    const cursor = try e.param(mark, 2);
    const mapping = try e.param(mark, 3);
    const ordered = try e.param(mark, 4);
    const blob_queue = try e.param(mark, 5);
    const next = try e.binary(.integer_add, cursor, e.one);
    const selected_ref = try e.b.variable(nodes.refs.optional);
    const id = try e.field(try e.payload(try e.b.reference(selected_ref), 1), 0);
    const found = try e.b.variable(nodes.map.optional);
    const element = try e.b.variable(m.nodes.optional);
    const node = try e.b.variable(public_node);
    const new_map = try e.b.variable(nodes.map.tree);
    const new_live = try e.b.variable(live.table);
    const new_queue = try e.b.variable(nodes.refs.table);
    const new_blob_queue = try e.b.variable(blobs.refs.table);
    const allocated = try e.tuple(reference, &.{try e.field(ordered, 0)});
    var visit = try e.call(mark, &.{
        input,
        try e.b.reference(new_queue),
        next,
        try e.b.reference(new_map),
        try e.b.reference(new_live),
        try e.b.reference(new_blob_queue),
    });
    visit = try e.b.bind(new_blob_queue, try e.call(blobs.walk, &.{
        try e.b.reference(node), blob_queue,
    }), visit);
    visit = try e.b.bind(new_queue, try e.call(
        nodes.walk,
        &.{ try e.b.reference(node), queue },
    ), visit);
    visit = try e.b.bind(new_live, try e.call(
        live.append,
        &.{ ordered, try e.b.reference(node) },
    ), visit);
    visit = try e.b.bind(new_map, try e.call(nodes.map.set, &.{ mapping, id, allocated }), visit);
    const internal = try e.payload(try e.b.reference(element), 1);
    visit = try e.b.bind(node, try e.call(m.node_to_public, &.{internal}), visit);
    const saved_nodes = try m.field(e, input, .nodes);
    visit = try e.b.bind(element, try e.call(m.nodes.get, &.{ saved_nodes, id }), visit);
    try emitMarkSelection(
        e,
        nodes,
        discovered,
        mark,
        input,
        queue,
        next,
        mapping,
        ordered,
        blob_queue,
        found,
        visit,
        selected_ref,
        cursor,
        id,
    );
}

fn emitMarkBlobs(
    m: machines.Definition,
    e: Author,
    blobs: anytype,
    blob_result: Id,
    mark_blobs: Id,
) Error!void {
    const input = try e.param(mark_blobs, 0);
    const queue = try e.param(mark_blobs, 1);
    const cursor = try e.param(mark_blobs, 2);
    const mapping = try e.param(mark_blobs, 3);
    const ordered = try e.param(mark_blobs, 4);
    const next = try e.binary(.integer_add, cursor, e.one);
    const selected_ref = try e.b.variable(blobs.refs.optional);
    const id = try e.field(try e.payload(try e.b.reference(selected_ref), 1), 0);
    const found = try e.b.variable(blobs.map.optional);
    const selected = try e.b.variable(m.blobs.optional);
    const new_map = try e.b.variable(blobs.map.tree);
    const new_table = try e.b.variable(m.blobs.table);
    const allocated = try e.tuple(
        try projection.schema(g.BlobRef, e.b),
        &.{try e.field(ordered, 0)},
    );
    var visit = try e.call(mark_blobs, &.{
        input, queue, next, try e.b.reference(new_map), try e.b.reference(new_table),
    });
    visit = try e.b.bind(new_table, try e.call(m.blobs.append, &.{
        ordered, try e.payload(try e.b.reference(selected), 1),
    }), visit);
    visit = try e.b.bind(new_map, try e.call(blobs.map.set, &.{ mapping, id, allocated }), visit);
    visit = try e.b.bind(selected, try e.call(m.blobs.get, &.{
        try m.field(e, input, .blobs), id,
    }), visit);
    const skip = try e.call(mark_blobs, &.{ input, queue, next, mapping, ordered });
    const choose = try e.when(
        try @import("unwind.zig").is(e, try e.b.reference(found), 0),
        visit,
        skip,
    );
    const more = try e.b.bind(selected_ref, try e.call(
        blobs.refs.get,
        &.{ queue, cursor },
    ), try e.b.bind(found, try e.call(blobs.map.get, &.{ mapping, id }), choose));
    try e.b.define(mark_blobs, try e.when(try e.binary(
        .less,
        cursor,
        try e.field(queue, 0),
    ), more, try e.b.pure(try e.tuple(
        blob_result,
        &.{ mapping, ordered },
    ))));
}

fn emitRebase(
    m: machines.Definition,
    e: Author,
    nodes: references.Definition,
    blobs: anytype,
    public_node: Id,
    live: tables.Definition,
    rebase: Id,
) Error!void {
    const input = try e.param(rebase, 0);
    const cursor = try e.param(rebase, 1);
    const node_map = try e.param(rebase, 2);
    const blob_map = try e.param(rebase, 3);
    const output = try e.param(rebase, 4);
    const selected = try e.b.variable(live.optional);
    const moved_nodes = try e.b.variable(public_node);
    const moved_blobs = try e.b.variable(public_node);
    const internal = try e.b.variable(m.nodes.element);
    const appended = try e.b.variable(m.nodes.table);
    var more = try e.call(rebase, &.{
        input,
        try e.binary(.integer_add, cursor, e.one),
        node_map,
        blob_map,
        try e.b.reference(appended),
    });
    more = try e.b.bind(appended, try e.call(m.nodes.append, &.{
        output, try e.b.reference(internal),
    }), more);
    more = try e.b.bind(internal, try e.call(
        m.node_from_public,
        &.{try e.b.reference(moved_blobs)},
    ), more);
    more = try e.b.bind(moved_blobs, try e.call(blobs.rebase, &.{
        try e.b.reference(moved_nodes), blob_map,
    }), more);
    more = try e.b.bind(moved_nodes, try e.call(nodes.rebase, &.{
        try e.payload(try e.b.reference(selected), 1), node_map,
    }), more);
    more = try e.b.bind(selected, try e.call(live.get, &.{ input, cursor }), more);
    try e.b.define(rebase, try e.when(try e.binary(
        .less,
        cursor,
        try e.field(input, 0),
    ), more, try e.b.pure(output)));
}

fn emitRun(
    m: machines.Definition,
    e: Author,
    roots: references.Definition,
    nodes: references.Definition,
    blobs: anytype,
    live: tables.Definition,
    discovered: Id,
    mark: Id,
    blob_result: Id,
    mark_blobs: Id,
    rebase: Id,
    d: Definition,
) Error!void {
    const input = try e.param(d.run, 0);
    const initial = try e.b.variable(nodes.refs.table);
    const marked = try e.b.variable(discovered);
    const marked_blobs = try e.b.variable(blob_result);
    const new_nodes = try e.b.variable(m.nodes.table);
    const new_roots = try e.b.variable(try projection.schema(g.Roots, e.b));
    var result = try e.replace(
        input,
        @backingInt(machines.Field.nodes),
        try e.b.reference(new_nodes),
    );
    result = try e.replace(
        result,
        @backingInt(machines.Field.blobs),
        try e.field(try e.b.reference(marked_blobs), 1),
    );
    result = try control.withRoots(e, result, try e.b.reference(new_roots));
    var body = try e.b.bind(new_roots, try e.call(roots.rebase, &.{
        try control.roots(e, m, input), try e.field(try e.b.reference(marked), 0),
    }), try e.b.pure(result));
    body = try emitRunBody(m, e, rebase, marked, marked_blobs, new_nodes, body);
    body = try e.b.bind(marked_blobs, try e.call(mark_blobs, &.{
        input,
        try e.field(try e.b.reference(
            marked,
        ), 2),
        e.zero,
        try blobs.map.empty(e),
        try m.blobs.empty(e.b),
    }), body);
    body = try e.b.bind(marked, try e.call(mark, &.{
        input,
        try e.b.reference(initial),
        e.zero,
        try nodes.map.empty(e),
        try live.empty(e.b),
        try blobs.refs.empty(e.b),
    }), body);
    try e.b.define(d.run, try e.b.bind(initial, try e.call(
        roots.references,
        &.{try control.roots(e, m, input)},
    ), body));
}

fn emitRunBody(
    m: machines.Definition,
    e: Author,
    rebase: Id,
    marked: Id,
    marked_blobs: Id,
    new_nodes: Id,
    body: Id,
) Error!Id {
    return try e.b.bind(new_nodes, try e.call(rebase, &.{
        try e.field(try e.b.reference(
            marked,
        ), 1),
        e.zero,
        try e.field(try e.b.reference(
            marked,
        ), 0),
        try e.field(try e.b.reference(
            marked_blobs,
        ), 0),
        try m.nodes.empty(e.b),
    }), body);
}

fn emitMarkSelection(
    e: Author,
    nodes: references.Definition,
    discovered: Id,
    mark: Id,
    input: Id,
    queue: Id,
    next: Id,
    mapping: Id,
    ordered: Id,
    blob_queue: Id,
    found: Id,
    visit: Id,
    selected_ref: Id,
    cursor: Id,
    id: Id,
) Error!void {
    const skip = try e.call(mark, &.{ input, queue, next, mapping, ordered, blob_queue });
    const choose = try e.when(
        try @import("unwind.zig").is(e, try e.b.reference(found), 0),
        visit,
        skip,
    );
    const more = try e.b.bind(selected_ref, try e.call(
        nodes.refs.get,
        &.{ queue, cursor },
    ), try e.b.bind(found, try e.call(nodes.map.get, &.{ mapping, id }), choose));
    try e.b.define(mark, try e.when(try e.binary(
        .less,
        cursor,
        try e.field(queue, 0),
    ), more, try e.b.pure(try e.tuple(discovered, &.{ mapping, ordered, blob_queue }))));
}
