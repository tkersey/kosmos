//! Demanded reconstruction in ordinary source. Storage checks also apply to
//! partial transition machines; only a complete anchor may become a guest cut.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const references = @import("references.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;

pub fn define(b: *source.Builder, machine: machines.Definition) source.Error!Id {
    const cache = try b.specialization(Id, "kosmos.semantic.recovery/1", machine.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const entry = try b.declare(&.{machine.schema}, machine.state, &.{}, &.{});
    const valid = try b.variable(e.boolean);
    const input = try e.param(entry, 0);
    try b.define(
        entry,
        try b.bind(
            valid,
            try e.call(try storage(
                b,
                machine,
            ), &.{
                input,
            }),
            try e.when(
                try b.reference(valid),
                try e.call(machine.project, &.{input}),
                try e.fail(),
            ),
        ),
    );
    return cache.finish(b, entry);
}

/// Checks representation bounds without pretending that an unfinished delta
/// satisfies the complete guest ownership/control laws. Exact guest admission
/// remains mandatory after projecting a committed anchor.
pub fn storage(b: *source.Builder, machine: machines.Definition) source.Error!Id {
    const cache = try b.specialization(Id, "kosmos.semantic.storage-valid/1", machine.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const entry = try b.declare(&.{machine.schema}, e.boolean, &.{}, &.{});
    const walk = try b.declare(&.{
        machine.nodes.sequence, e.integer, e.integer,
    }, e.boolean, &.{}, &.{});
    const node_refs = try references.define(data.process_state.Node, b);
    const blob_refs = try references.defineBlobs(data.process_state.Node, b);
    const root_refs = try references.define(data.graph.Roots, b);
    const bounded_nodes = try bounds(e, node_refs.refs);
    const bounded_blobs = try bounds(e, blob_refs.refs);
    const invalid = try b.pure(try b.constant(bool, false));
    try emitWalk(machine, e, walk, node_refs, blob_refs, bounded_nodes, bounded_blobs, invalid);
    const input = try e.param(entry, 0);
    const header = try machine.field(e, input, .header);
    const valid_nodes = try b.variable(e.boolean);
    const valid_blobs = try b.variable(e.boolean);
    const valid_roots = try b.variable(e.boolean);
    const roots = try b.variable(root_refs.refs.table);
    const nodes = try machine.field(e, input, .nodes);
    const blob_count = try e.field(try machine.field(e, input, .blobs), 0);
    const node_list = try b.variable(machine.nodes.sequence);
    const visit = try b.bind(node_list, try e.call(
        machine.nodes.to_sequence,
        &.{nodes},
    ), try e.call(walk, &.{ try b.reference(node_list), try e.field(nodes, 0), blob_count }));
    var checked = try b.bind(valid_roots, try e.call(bounded_nodes, &.{
        try b.reference(roots), try e.field(nodes, 0), e.zero,
    }), try e.when(try b.reference(valid_roots), visit, invalid));
    checked = try b.bind(roots, try e.call(root_refs.references, &.{try e.field(
        header,
        machines.index(machines.Header, "roots"),
    )}), checked);
    const program_identity = try e.field(
        try machine.field(e, input, .program),
        machines.index(projection.Program, "identity"),
    );
    const state_identity = try e.field(header, machines.index(machines.Header, "program_identity"));
    for (0..32) |i| checked = try e.when(try e.binary(.equal, try e.required(
        program_identity,
        try b.constant(u64, i),
    ), try e.required(state_identity, try b.constant(u64, i))), checked, invalid);
    const valid_cache = try b.variable(e.boolean);
    checked = try b.bind(valid_cache, try e.call(
        try @import("projection_cache.zig").valid(b, machine),
        &.{input},
    ), try e.when(try b.reference(valid_cache), checked, invalid));
    checked = try b.bind(valid_blobs, try e.call(machine.blobs.valid, &.{
        try machine.field(e, input, .blobs),
    }), try e.when(try b.reference(valid_blobs), checked, invalid));
    try b.define(entry, try b.bind(valid_nodes, try e.call(machine.nodes.valid, &.{
        try machine.field(e, input, .nodes),
    }), try e.when(try b.reference(valid_nodes), checked, invalid)));
    return cache.finish(b, entry);
}

pub fn bounds(e: Author, refs: @import("table.zig").Definition) source.Error!Id {
    const cache = try e.b.specialization(Id, "kosmos.semantic.reference-bounds/1", refs.table);
    if (cache.cached) |saved| return saved;
    const b = e.b;
    const entry = try b.declare(&.{ refs.table, e.integer, e.integer }, e.boolean, &.{}, &.{});
    const list = try e.param(entry, 0);
    const maximum = try e.param(entry, 1);
    const index = try e.param(entry, 2);
    const found = try b.variable(refs.optional);
    const reference = try e.payload(try b.reference(found), 1);
    const next = try e.call(entry, &.{ list, maximum, try e.binary(.integer_add, index, e.one) });
    const visit = try b.bind(
        found,
        try e.call(refs.get, &.{
            list,
            index,
        }),
        try e.when(
            try e.binary(.less, try e.field(reference, 0), maximum),
            next,
            try b.pure(try b.constant(bool, false)),
        ),
    );
    try b.define(entry, try e.when(
        try e.binary(.less, index, try e.field(list, 0)),
        visit,
        try b.pure(try b.constant(bool, true)),
    ));
    return cache.finish(b, entry);
}

fn emitWalk(
    machine: machines.Definition,
    e: Author,
    walk: Id,
    node_refs: references.Definition,
    blob_refs: references.Definition,
    bounded_nodes: Id,
    bounded_blobs: Id,
    invalid: Id,
) source.Error!void {
    const input = try e.param(walk, 0);
    const node_count = try e.param(walk, 1);
    const blob_count = try e.param(walk, 2);
    const pair_schema = try e.b.schema(.{ .product = &.{
        machine.nodes.element, machine.nodes.sequence,
    } });
    const popped_schema = try e.b.schema(.{ .sum = &.{ e.unit, pair_schema } });
    const missing = try e.b.variable(e.unit);
    const found = try e.b.variable(pair_schema);
    const pair = try e.b.reference(found);
    const node = try e.field(pair, 0);
    const frame = try e.field(node, 1);
    const valid_frame = try e.b.variable(e.boolean);
    const public = try e.b.variable(try projection.schema(data.process_state.Node, e.b));
    const refs = try e.b.variable(node_refs.refs.table);
    const blob_list = try e.b.variable(blob_refs.refs.table);
    const valid_nodes = try e.b.variable(e.boolean);
    const valid_blobs = try e.b.variable(e.boolean);
    const next = try e.call(walk, &.{ try e.field(pair, 1), node_count, blob_count });
    var inspect = try e.b.bind(valid_blobs, try e.call(bounded_blobs, &.{
        try e.b.reference(blob_list), blob_count, e.zero,
    }), try e.when(try e.b.reference(valid_blobs), next, invalid));
    inspect = try e.b.bind(blob_list, try e.call(
        blob_refs.references,
        &.{try e.b.reference(public)},
    ), inspect);
    inspect = try e.b.bind(valid_nodes, try e.call(bounded_nodes, &.{
        try e.b.reference(refs), node_count, e.zero,
    }), try e.when(try e.b.reference(valid_nodes), inspect, invalid));
    inspect = try e.b.bind(refs, try e.call(
        node_refs.references,
        &.{try e.b.reference(public)},
    ), inspect);
    inspect = try e.b.bind(public, try e.call(machine.node_to_public, &.{node}), inspect);
    const checked = try e.b.bind(valid_frame, try e.call(
        machine.frames.valid,
        &.{try e.payload(frame, 1)},
    ), try e.when(try e.b.reference(valid_frame), inspect, invalid));
    const select = try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{frame},
        0,
    ), e.zero), inspect, checked);
    try e.b.define(walk, try e.b.term(.{ .match_sum = .{
        .value = try e.b.primitive(popped_schema, .sequence_pop, &.{input}, 0),
        .cases = &.{
            .{ .variable = missing, .body = try e.b.pure(try e.b.constant(bool, true)) },
            .{ .variable = found, .body = select },
        },
    } }));
}
