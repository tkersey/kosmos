//! Independent inspection of submitted clone storage. This never runs discovery
//! to manufacture an expected map: the map, append order and cursor are checked
//! against actual source and destination records.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const clones = @import("clone.zig");
const references = @import("references.zig");
const projection = @import("projection.zig");
const maps = @import("map.zig");
const tables = @import("table.zig");
const recovery = @import("recovery.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;

pub const Definition = struct { context: Id, rebase: Id };

pub fn define(b: *source.Builder, m: machines.Definition, clone: clones.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.clone-validation/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const refs = try references.define(data.process_state.Node, b);
    const list = refs.refs;
    const d: Definition = .{
        .context = try b.declare(&.{ clone.context, e.integer }, e.boolean, &.{}, &.{}),
        .rebase = try b.declare(&.{ m.schema, refs.map.tree, list.table, e.integer }, e.boolean, &.{}, &.{}),
    };
    const no = try b.pure(try b.constant(bool, false));
    const yes = try b.pure(try b.constant(bool, true));
    // The map cardinality equals the ordered originals list. Each original is
    // below the append boundary and maps to its own unique appended index.
    const walk = try b.declare(&.{ m.schema, refs.map.tree, list.table, e.integer, e.integer, e.integer }, e.boolean, &.{}, &.{});
    {
        const machine = try e.param(walk, 0);
        const mapping = try e.param(walk, 1);
        const originals = try e.param(walk, 2);
        const cursor = try e.param(walk, 3);
        const base = try e.param(walk, 4);
        const index = try e.param(walk, 5);
        const original = try b.variable(list.optional);
        const old_id = try e.field(try e.payload(try b.reference(original), 1), 0);
        const found = try b.variable(refs.map.optional);
        const expected_id = try e.binary(.integer_add, base, index);
        const old = try b.variable(m.nodes.optional);
        const new = try b.variable(m.nodes.optional);
        const old_public = try b.variable(try projection.schema(data.process_state.Node, b));
        const new_public = try b.variable(try projection.schema(data.process_state.Node, b));
        const expected = try b.variable(try projection.schema(data.process_state.Node, b));
        const equal = try b.variable(e.boolean);
        const next = try e.call(walk, &.{ machine, mapping, originals, cursor, base, try e.binary(.integer_add, index, e.one) });
        var inspect = try b.bind(equal, try e.call(try @import("record_equal.zig").define(data.process_state.Node, b), &.{ try b.reference(expected), try b.reference(new_public) }), try e.when(try b.reference(equal), next, no));
        inspect = try b.bind(expected, try e.when(try e.binary(.less, index, cursor), try e.call(refs.rebase, &.{ try b.reference(old_public), mapping }), try b.pure(try b.reference(old_public))), inspect);
        inspect = try b.bind(new_public, try e.call(m.node_to_public, &.{try e.payload(try b.reference(new), 1)}), inspect);
        inspect = try b.bind(old_public, try e.call(m.node_to_public, &.{try e.payload(try b.reference(old), 1)}), inspect);
        inspect = try b.bind(new, try e.call(m.nodes.get, &.{ try m.field(e, machine, .nodes), expected_id }), inspect);
        inspect = try b.bind(old, try e.call(m.nodes.get, &.{ try m.field(e, machine, .nodes), old_id }), inspect);
        inspect = try e.when(try e.binary(.equal, try e.field(try e.payload(try b.reference(found), 1), 0), expected_id), inspect, no);
        inspect = try b.bind(found, try e.call(refs.map.get, &.{ mapping, old_id }), try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{try b.reference(found)}, 0), e.one), inspect, no));
        inspect = try b.bind(original, try e.call(list.get, &.{ originals, index }), try e.when(try e.binary(.less, old_id, base), inspect, no));
        try b.define(walk, try e.when(try e.binary(.less, index, try e.field(originals, 0)), inspect, yes));
    }
    {
        const machine = try e.param(d.rebase, 0);
        const mapping = try e.param(d.rebase, 1);
        const originals = try e.param(d.rebase, 2);
        const cursor = try e.param(d.rebase, 3);
        const count = try e.field(originals, 0);
        const total = try e.field(try m.field(e, machine, .nodes), 0);
        const entries = try b.variable(refs.map.entries);
        var checked = try e.call(walk, &.{ machine, mapping, originals, cursor, try e.binary(.integer_sub, total, count), e.zero });
        checked = try e.when(try e.binary(.less, total, count), no, checked);
        checked = try e.when(try e.binary(.less, count, cursor), no, checked);
        checked = try b.bind(entries, try e.call(refs.map.to_sequence, &.{mapping}), try e.when(try e.binary(.equal, try b.primitive(e.integer, .sequence_length, &.{try b.reference(entries)}, 0), count), checked, no));
        checked = try guard(e, refs.map.valid, &.{mapping}, checked, no);
        checked = try guard(e, list.valid, &.{originals}, checked, no);
        checked = try guard(e, try recovery.storage(b, m), &.{machine}, checked, no);
        try b.define(d.rebase, checked);
    }
    {
        const ctx = try e.param(d.context, 0);
        const cursor = try e.param(d.context, 1);
        const machine = try e.field(ctx, @backingInt(clones.Field.machine));
        const mapping = try e.field(ctx, @backingInt(clones.Field.mapping));
        const originals = try e.field(ctx, @backingInt(clones.Field.originals));
        const total = try e.field(try m.field(e, machine, .nodes), 0);
        const count = try e.field(originals, 0);
        const limit = try e.binary(.integer_sub, total, count);
        const tasks = try tables.define(b, try projection.schema(clones.Task, b));
        const task_list = try e.field(ctx, @backingInt(clones.Field.tasks));
        const task_walk = try b.declare(&.{ tasks.table, e.integer, e.integer }, e.boolean, &.{}, &.{});
        const task_input = try e.param(task_walk, 0);
        const task_limit = try e.param(task_walk, 1);
        const index = try e.param(task_walk, 2);
        const found = try b.variable(tasks.optional);
        const task = try e.payload(try b.reference(found), 1);
        const next = try e.call(task_walk, &.{ task_input, task_limit, try e.binary(.integer_add, index, e.one) });
        const visit = try b.bind(found, try e.call(tasks.get, &.{ task_input, index }), try e.when(try e.binary(.less, try e.field(task, 0), try b.constant(u64, 2)), try e.when(try e.binary(.less, try e.field(try e.field(task, 1), 0), task_limit), next, no), no));
        try b.define(task_walk, try e.when(try e.binary(.less, index, try e.field(task_input, 0)), visit, yes));
        var checked = try e.call(task_walk, &.{ task_list, limit, e.zero });
        checked = try e.when(try e.binary(.less, try e.field(task_list, 0), cursor), no, checked);
        checked = try guard(e, tasks.valid, &.{task_list}, checked, no);
        inline for (.{ clones.Field.discovered, clones.Field.considered, clones.Field.dependents, clones.Field.waiting }) |field| {
            const has_lists = field == .dependents or field == .waiting;
            const map = try maps.define(b, if (has_lists) list.table else e.unit);
            const value = try e.field(ctx, @backingInt(field));
            checked = try guard(e, try boundedMap(e, map, if (has_lists) list else null), &.{ value, limit }, checked, no);
            checked = try guard(e, map.valid, &.{value}, checked, no);
        }
        try b.define(d.context, try guard(e, d.rebase, &.{ machine, mapping, originals, e.zero }, checked, no));
    }
    return cache.finish(b, d);
}

fn guard(e: Author, entry: Id, arguments: []const Id, yes: Id, no: Id) Error!Id {
    const valid = try e.b.variable(e.boolean);
    return e.b.bind(valid, try e.call(entry, arguments), try e.when(try e.b.reference(valid), yes, no));
}

fn boundedMap(e: Author, map: maps.Definition, lists: ?tables.Definition) Error!Id {
    const b = e.b;
    const entry = try b.declare(&.{ map.tree, e.integer }, e.boolean, &.{}, &.{});
    const input = try e.param(entry, 0);
    const limit = try e.param(entry, 1);
    const nil = try b.variable(e.unit);
    const leaf = try b.variable(map.entry);
    const fork = try b.variable(map.branch);
    const no = try b.pure(try b.constant(bool, false));
    const yes = try b.pure(try b.constant(bool, true));
    const pair = try b.reference(leaf);
    var valid_leaf = yes;
    if (lists) |list| {
        const value = try e.field(pair, 1);
        valid_leaf = try guard(e, list.valid, &.{value}, try e.call(try recovery.bounds(e, list), &.{ value, limit, e.zero }), no);
    }
    const branch = try b.reference(fork);
    try b.define(entry, try b.term(.{ .match_sum = .{ .value = input, .cases = &.{
        .{ .variable = nil, .body = yes },
        .{ .variable = leaf, .body = try e.when(try e.binary(.less, try e.field(pair, 0), limit), valid_leaf, no) },
        .{ .variable = fork, .body = try guard(e, entry, &.{ try e.field(branch, 1), limit }, try e.call(entry, &.{ try e.field(branch, 2), limit }), no) },
    } } }));
    return entry;
}
