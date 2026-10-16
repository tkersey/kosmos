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
    try b.define(entry, try b.bind(valid, try e.call(try storage(b, machine), &.{input}), try e.when(try b.reference(valid), try e.call(machine.project, &.{input}), try e.fail())));
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
    const walk = try b.declare(&.{ machine.schema, e.integer }, e.boolean, &.{}, &.{});
    const node_refs = try references.define(data.process_state.Node, b);
    const blob_refs = try references.defineBlobs(data.process_state.Node, b);
    const root_refs = try references.define(data.graph.Roots, b);
    const bounded_nodes = try bounds(e, node_refs.refs);
    const bounded_blobs = try bounds(e, blob_refs.refs);
    const invalid = try b.pure(try b.constant(bool, false));
    {
        const input = try e.param(walk, 0);
        const nodes = try machine.field(e, input, .nodes);
        const blobs = try machine.field(e, input, .blobs);
        const index = try e.param(walk, 1);
        const found = try b.variable(machine.nodes.optional);
        const node = try e.payload(try b.reference(found), 1);
        const frame = try e.field(node, 1);
        const valid_frame = try b.variable(e.boolean);
        const public = try b.variable(try projection.schema(data.process_state.Node, b));
        const refs = try b.variable(node_refs.refs.table);
        const blob_list = try b.variable(blob_refs.refs.table);
        const valid_nodes = try b.variable(e.boolean);
        const valid_blobs = try b.variable(e.boolean);
        const next = try e.call(walk, &.{ input, try e.binary(.integer_add, index, e.one) });
        var inspect = try b.bind(valid_blobs, try e.call(bounded_blobs, &.{ try b.reference(blob_list), try e.field(blobs, 0), e.zero }), try e.when(try b.reference(valid_blobs), next, invalid));
        inspect = try b.bind(blob_list, try e.call(blob_refs.references, &.{try b.reference(public)}), inspect);
        inspect = try b.bind(valid_nodes, try e.call(bounded_nodes, &.{ try b.reference(refs), try e.field(nodes, 0), e.zero }), try e.when(try b.reference(valid_nodes), inspect, invalid));
        inspect = try b.bind(refs, try e.call(node_refs.references, &.{try b.reference(public)}), inspect);
        inspect = try b.bind(public, try e.call(machine.node_to_public, &.{node}), inspect);
        const checked = try b.bind(valid_frame, try e.call(machine.frames.valid, &.{try e.payload(frame, 1)}), try e.when(try b.reference(valid_frame), inspect, invalid));
        const select = try b.bind(found, try e.call(machine.nodes.get, &.{ nodes, index }), try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{frame}, 0), e.zero), inspect, checked));
        try b.define(walk, try e.when(try e.binary(.less, index, try e.field(nodes, 0)), select, try b.pure(try b.constant(bool, true))));
    }
    const input = try e.param(entry, 0);
    const header = try machine.field(e, input, .header);
    const valid_nodes = try b.variable(e.boolean);
    const valid_blobs = try b.variable(e.boolean);
    const valid_roots = try b.variable(e.boolean);
    const roots = try b.variable(root_refs.refs.table);
    var checked = try b.bind(valid_roots, try e.call(bounded_nodes, &.{ try b.reference(roots), try e.field(try machine.field(e, input, .nodes), 0), e.zero }), try e.when(try b.reference(valid_roots), try e.call(walk, &.{ input, e.zero }), invalid));
    checked = try b.bind(roots, try e.call(root_refs.references, &.{try e.field(header, machines.index(machines.Header, "roots"))}), checked);
    const program_identity = try e.field(try machine.field(e, input, .program), machines.index(projection.Program, "identity"));
    const state_identity = try e.field(header, machines.index(machines.Header, "program_identity"));
    for (0..32) |i| checked = try e.when(try e.binary(.equal, try e.required(program_identity, try b.constant(u64, i)), try e.required(state_identity, try b.constant(u64, i))), checked, invalid);
    checked = try b.bind(valid_blobs, try e.call(machine.blobs.valid, &.{try machine.field(e, input, .blobs)}), try e.when(try b.reference(valid_blobs), checked, invalid));
    try b.define(entry, try b.bind(valid_nodes, try e.call(machine.nodes.valid, &.{try machine.field(e, input, .nodes)}), try e.when(try b.reference(valid_nodes), checked, invalid)));
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
    const visit = try b.bind(found, try e.call(refs.get, &.{ list, index }), try e.when(try e.binary(.less, try e.field(reference, 0), maximum), next, try b.pure(try b.constant(bool, false))));
    try b.define(entry, try e.when(try e.binary(.less, index, try e.field(list, 0)), visit, try b.pure(try b.constant(bool, true))));
    return cache.finish(b, entry);
}
