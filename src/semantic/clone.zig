//! Multi-shot instantiation as a monotone work list in Horos. A single map
//! preserves aliases; immutable containers are copied only when a child changes.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const graphs = @import("graph.zig");
const references = @import("references.zig");
const maps = @import("map.zig");
const tables = @import("table.zig");
const sets = @import("sets.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
pub const Field = enum(usize) { machine, mapping, originals, discovered, considered, dependents, waiting, tasks };
pub const Task = struct { kind: u64, reference: g.NodeRef };
pub const Definition = struct { instantiate: Id, result: Id, context: Id, run: Id, rebase: Id };

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.clone/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const node_refs = try references.define(g.Node, b);
    const ref = try projection.schema(g.NodeRef, b);
    const list = node_refs.refs;
    const lists = try maps.define(b, list.table);
    const set = try sets.define(b);
    const tasks = try tables.define(b, try projection.schema(Task, b));
    const ctx = try b.schema(.{ .product = &.{ m.schema, node_refs.map.tree, list.table, set.map.tree, set.map.tree, lists.tree, lists.tree, tasks.table } });
    const capture = try projection.schema(g.Capture, b);
    const result = try b.schema(.{ .product = &.{ m.schema, capture } });
    const d: Definition = .{
        .instantiate = try b.declare(&.{ m.schema, capture }, result, &.{}, &.{}),
        .result = result,
        .context = ctx,
        .run = try b.declare(&.{ ctx, e.integer }, ctx, &.{}, &.{}),
        .rebase = try b.declare(&.{ m.schema, node_refs.map.tree, list.table, e.integer }, m.schema, &.{}, &.{}),
    };
    const c: Generator = .{
        .e = e,
        .m = m,
        .ctx = ctx,
        .graph = try graphs.define(b, m),
        .refs = node_refs,
        .frame_refs = try references.define(data.process_state.Activation, b),
        .capture_refs = try references.define(g.Capture, b),
        .list = list,
        .lists = lists,
        .set = set,
        .tasks = tasks,
        .enqueue = try b.declare(&.{ ctx, e.integer, ref }, ctx, &.{}, &.{}),
        .discover = try b.declare(&.{ ctx, ref }, ctx, &.{}, &.{}),
        .include = try b.declare(&.{ ctx, ref }, ctx, &.{}, &.{}),
        .dependency = try b.declare(&.{ ctx, ref, ref }, ctx, &.{}, &.{}),
        .add_dependency = try b.declare(&.{ ctx, ref, ref }, ctx, &.{}, &.{}),
        .add_waiting = try b.declare(&.{ ctx, ref, ref }, ctx, &.{}, &.{}),
        .lookup_list = try b.declare(&.{ lists.tree, ref }, list.table, &.{}, &.{}),
        .capture = try b.declare(&.{ ctx, capture, e.boolean }, ctx, &.{}, &.{}),
        .capture_loop = try b.declare(&.{ ctx, capture, e.boolean, try projection.schema(?g.NodeRef, b) }, ctx, &.{}, &.{}),
        .template = try b.declare(&.{ ctx, ref }, ctx, &.{}, &.{}),
        .mapped_optional = try b.declare(&.{ ctx, try projection.schema(?g.NodeRef, b) }, e.boolean, &.{}, &.{}),
        .wait_optional = try b.declare(&.{ ctx, try projection.schema(?g.NodeRef, b), ref }, ctx, &.{}, &.{}),
        .scan = try b.declare(&.{ ctx, ref }, ctx, &.{}, &.{}),
        .scan_refs = try b.declare(&.{ ctx, list.table, e.integer, ref, e.boolean }, ctx, &.{}, &.{}),
        .include_list = try b.declare(&.{ ctx, list.table, e.integer }, ctx, &.{}, &.{}),
        .template_list = try b.declare(&.{ ctx, list.table, e.integer }, ctx, &.{}, &.{}),
        .propagate = try b.declare(&.{ ctx, ref }, ctx, &.{}, &.{}),
        .run = d.run,
        .rebase = d.rebase,
    };
    try c.emitMaps();
    try c.emitCapture();
    try c.emitTemplate();
    try c.emitScan();
    try c.emitRun();
    const input = try e.param(d.instantiate, 0);
    const template = try e.param(d.instantiate, 1);
    const initial = try e.tuple(ctx, &.{ input, try node_refs.map.empty(e), try list.empty(b), try set.map.empty(e), try set.map.empty(e), try lists.empty(e), try lists.empty(e), try tasks.empty(b) });
    const seeded = try b.variable(ctx);
    const closed = try b.variable(ctx);
    const rebased = try b.variable(m.schema);
    const captured = try b.variable(capture);
    const finished = try b.reference(closed);
    try b.define(d.instantiate, try b.bind(seeded, try e.call(c.capture, &.{ initial, template, try b.constant(bool, false) }), try b.bind(closed, try e.call(c.run, &.{ try b.reference(seeded), e.zero }), try b.bind(rebased, try e.call(c.rebase, &.{ try c.get(finished, .machine), try c.get(finished, .mapping), try c.get(finished, .originals), e.zero }), try b.bind(captured, try e.call(c.capture_refs.rebase, &.{ template, try c.get(finished, .mapping) }), try b.pure(try e.tuple(result, &.{ try b.reference(rebased), try b.reference(captured) })))))));
    return cache.finish(b, d);
}

const Generator = struct {
    e: Author,
    m: machines.Definition,
    ctx: Id,
    graph: graphs.Definition,
    refs: references.Definition,
    frame_refs: references.Definition,
    capture_refs: references.Definition,
    list: tables.Definition,
    lists: maps.Definition,
    set: sets.Definition,
    tasks: tables.Definition,
    enqueue: Id,
    discover: Id,
    include: Id,
    dependency: Id,
    add_dependency: Id,
    add_waiting: Id,
    lookup_list: Id,
    capture: Id,
    capture_loop: Id,
    template: Id,
    mapped_optional: Id,
    wait_optional: Id,
    scan: Id,
    scan_refs: Id,
    include_list: Id,
    template_list: Id,
    propagate: Id,
    run: Id,
    rebase: Id,

    fn get(c: Generator, value: Id, which: Field) Error!Id {
        return c.e.field(value, @backingInt(which));
    }
    fn put(c: Generator, value: Id, which: Field, replacement: Id) Error!Id {
        return c.e.replace(value, @backingInt(which), replacement);
    }
    fn mapped(c: Generator, found: Id) Error!Id {
        return c.e.binary(.equal, try c.e.b.primitive(c.e.integer, .variant_tag, &.{found}, 0), c.e.one);
    }
    fn is(c: Generator, record: Id, tag: g.NodeTag) Error!Id {
        return c.e.binary(.equal, try c.e.b.primitive(c.e.integer, .variant_tag, &.{record}, 0), try c.e.b.constant(u64, @backingInt(tag)));
    }

    fn emitMaps(c: Generator) Error!void {
        const e = c.e;
        const b = e.b;
        {
            const input = try e.param(c.enqueue, 0);
            const table = try b.variable(c.tasks.table);
            const task = try e.tuple(c.tasks.element, &.{ try e.param(c.enqueue, 1), try e.param(c.enqueue, 2) });
            try b.define(c.enqueue, try b.bind(table, try e.call(c.tasks.append, &.{ try c.get(input, .tasks), task }), try b.pure(try c.put(input, .tasks, try b.reference(table)))));
        }
        {
            const input = try e.param(c.discover, 0);
            const ref = try e.param(c.discover, 1);
            const seen = try b.variable(e.boolean);
            const updated = try b.variable(c.set.map.tree);
            const mark = try b.bind(updated, try e.call(c.set.map.set, &.{ try c.get(input, .discovered), try e.field(ref, 0), e.unit_value }), try e.call(c.enqueue, &.{ try c.put(input, .discovered, try b.reference(updated)), e.zero, ref }));
            try b.define(c.discover, try b.bind(seen, try e.call(c.set.contains, &.{ try c.get(input, .discovered), try e.field(ref, 0) }), try e.when(try b.reference(seen), try b.pure(input), mark)));
        }
        {
            const input = try e.param(c.include, 0);
            const ref = try e.param(c.include, 1);
            const machine = try c.get(input, .machine);
            const old_table = try c.m.field(e, machine, .nodes);
            const new_ref = try e.tuple(try projection.schema(g.NodeRef, b), &.{try e.field(old_table, 0)});
            const found = try b.variable(c.refs.map.optional);
            const element = try b.variable(c.m.nodes.element);
            const nodes = try b.variable(c.m.nodes.table);
            const map = try b.variable(c.refs.map.tree);
            const originals = try b.variable(c.list.table);
            const queued = try b.variable(c.ctx);
            var changed = try c.put(input, .machine, try e.replace(machine, @backingInt(machines.Field.nodes), try b.reference(nodes)));
            changed = try c.put(changed, .mapping, try b.reference(map));
            changed = try c.put(changed, .originals, try b.reference(originals));
            var add = try b.bind(queued, try e.call(c.discover, &.{ changed, ref }), try e.call(c.enqueue, &.{ try b.reference(queued), e.one, ref }));
            add = try b.bind(originals, try e.call(c.list.append, &.{ try c.get(input, .originals), ref }), add);
            add = try b.bind(map, try e.call(c.refs.map.set, &.{ try c.get(input, .mapping), try e.field(ref, 0), new_ref }), add);
            add = try b.bind(nodes, try e.call(c.m.nodes.append, &.{ old_table, try b.reference(element) }), add);
            add = try b.bind(element, try e.call(c.graph.element, &.{ machine, ref }), add);
            try b.define(c.include, try b.bind(found, try e.call(c.refs.map.get, &.{ try c.get(input, .mapping), try e.field(ref, 0) }), try e.when(try c.mapped(try b.reference(found)), try b.pure(input), add)));
        }
        {
            const found = try b.variable(c.lists.optional);
            const nil = try b.variable(e.unit);
            const present = try b.variable(c.list.table);
            try b.define(c.lookup_list, try b.bind(found, try e.call(c.lists.get, &.{ try e.param(c.lookup_list, 0), try e.field(try e.param(c.lookup_list, 1), 0) }), try b.term(.{ .match_sum = .{ .value = try b.reference(found), .cases = &.{ .{ .variable = nil, .body = try b.pure(try c.list.empty(b)) }, .{ .variable = present, .body = try b.pure(try b.reference(present)) } } } })));
        }
        inline for (.{ Field.dependents, Field.waiting }) |which| {
            const entry = if (which == .dependents) c.add_dependency else c.add_waiting;
            const input = try e.param(entry, 0);
            const owner = try e.param(entry, 1);
            const value = try e.param(entry, 2);
            const prior = try b.variable(c.list.table);
            const appended = try b.variable(c.list.table);
            const map = try b.variable(c.lists.tree);
            try b.define(entry, try b.bind(prior, try e.call(c.lookup_list, &.{ try c.get(input, which), owner }), try b.bind(appended, try e.call(c.list.append, &.{ try b.reference(prior), value }), try b.bind(map, try e.call(c.lists.set, &.{ try c.get(input, which), try e.field(owner, 0), try b.reference(appended) }), try b.pure(try c.put(input, which, try b.reference(map)))))));
        }
        {
            const input = try e.param(c.dependency, 0);
            const child = try e.param(c.dependency, 1);
            const parent = try e.param(c.dependency, 2);
            const recorded = try b.variable(c.ctx);
            const found = try b.variable(c.refs.map.optional);
            try b.define(c.dependency, try b.bind(recorded, try e.call(c.add_dependency, &.{ input, child, parent }), try b.bind(found, try e.call(c.refs.map.get, &.{ try c.get(input, .mapping), try e.field(child, 0) }), try e.when(try c.mapped(try b.reference(found)), try e.call(c.include, &.{ try b.reference(recorded), parent }), try b.pure(try b.reference(recorded))))));
        }
    }

    fn emitCapture(c: Generator) Error!void {
        const e = c.e;
        const b = e.b;
        const input = try e.param(c.capture_loop, 0);
        const saved = try e.param(c.capture_loop, 1);
        const include_handler = try e.param(c.capture_loop, 2);
        const ref = try e.payload(try e.param(c.capture_loop, 3), 1);
        const record_var = try b.variable(try projection.schema(g.Node, b));
        const record = try b.reference(record_var);
        const included = try b.variable(c.ctx);
        const current = try b.reference(included);
        const next_ctx = try b.variable(c.ctx);
        const delimiter = try e.field(saved, machines.index(g.Capture, "delimiter"));
        const attachment = try e.payload(record, @backingInt(g.NodeTag.attachment));
        const done = try e.when(include_handler, try e.call(c.include, &.{ current, try e.field(attachment, 0) }), try b.pure(current));
        var next = try e.fail();
        inline for ([_]g.NodeTag{ .continuation, .attachment, .region_scope, .injection }) |tag| {
            const payload = try e.payload(record, @backingInt(tag));
            const parent = switch (tag) {
                .continuation => try e.field(payload, 1),
                .attachment, .region_scope => try e.field(payload, 2),
                .injection => try e.variant(try projection.schema(?g.NodeRef, b), 1, try e.field(payload, 0)),
                else => unreachable,
            };
            const recurse = try e.call(c.capture_loop, &.{ if (tag == .attachment or tag == .region_scope) try b.reference(next_ctx) else current, saved, include_handler, parent });
            const follow = if (tag == .attachment or tag == .region_scope) try b.bind(next_ctx, try e.call(c.include, &.{ current, try e.field(payload, if (tag == .attachment) 0 else 1) }), recurse) else recurse;
            next = try e.when(try c.is(record, tag), follow, next);
        }
        try b.define(c.capture_loop, try b.bind(record_var, try e.call(c.graph.record, &.{ try c.get(input, .machine), ref }), try b.bind(included, try e.call(c.include, &.{ input, ref }), try e.when(try e.binary(.equal, try e.field(ref, 0), try e.field(delimiter, 0)), done, next))));
        const capture_value = try e.param(c.capture, 1);
        try b.define(c.capture, try e.call(c.capture_loop, &.{ try e.param(c.capture, 0), capture_value, try e.param(c.capture, 2), try e.field(capture_value, machines.index(g.Capture, "capture")) }));
    }

    fn emitTemplate(c: Generator) Error!void {
        const e = c.e;
        const b = e.b;
        {
            const input = try e.param(c.mapped_optional, 0);
            const nil = try b.variable(e.unit);
            const present = try b.variable(try projection.schema(g.NodeRef, b));
            const found = try b.variable(c.refs.map.optional);
            try b.define(c.mapped_optional, try b.term(.{ .match_sum = .{ .value = try e.param(c.mapped_optional, 1), .cases = &.{
                .{ .variable = nil, .body = try b.pure(try b.constant(bool, false)) },
                .{ .variable = present, .body = try b.bind(found, try e.call(c.refs.map.get, &.{ try c.get(input, .mapping), try e.field(try b.reference(present), 0) }), try b.pure(try c.mapped(try b.reference(found)))) },
            } } }));
            try b.define(c.wait_optional, try b.term(.{ .match_sum = .{ .value = try e.param(c.wait_optional, 1), .cases = &.{
                .{ .variable = nil, .body = try b.pure(try e.param(c.wait_optional, 0)) },
                .{ .variable = present, .body = try e.call(c.add_waiting, &.{ try e.param(c.wait_optional, 0), try b.reference(present), try e.param(c.wait_optional, 2) }) },
            } } }));
        }
        const input = try e.param(c.template, 0);
        const ref = try e.param(c.template, 1);
        const found = try b.variable(c.refs.map.optional);
        const record = try b.variable(try projection.schema(g.Node, b));
        const delimiter = try b.variable(try projection.schema(g.Node, b));
        const handler = try b.variable(try projection.schema(g.Node, b));
        const saved = try e.payload(try b.reference(record), @backingInt(g.NodeTag.multi_template));
        const attachment = try e.payload(try b.reference(delimiter), @backingInt(g.NodeTag.attachment));
        const activation = try e.payload(try b.reference(handler), @backingInt(g.NodeTag.handler));
        const outer = try e.field(attachment, 1);
        const region = try e.field(activation, 3);
        const outer_changed = try b.variable(e.boolean);
        const region_changed = try b.variable(e.boolean);
        const included = try b.variable(c.ctx);
        const copy = try b.bind(included, try e.call(c.include, &.{ input, ref }), try e.call(c.capture, &.{ try b.reference(included), saved, try b.constant(bool, true) }));
        const considered = try b.variable(e.boolean);
        const marked = try b.variable(c.set.map.tree);
        const waited = try b.variable(c.ctx);
        var wait = try b.bind(marked, try e.call(c.set.map.set, &.{ try c.get(input, .considered), try e.field(ref, 0), e.unit_value }), try b.bind(waited, try e.call(c.wait_optional, &.{ try c.put(input, .considered, try b.reference(marked)), outer, ref }), try e.call(c.wait_optional, &.{ try b.reference(waited), region, ref })));
        wait = try b.bind(considered, try e.call(c.set.contains, &.{ try c.get(input, .considered), try e.field(ref, 0) }), try e.when(try b.reference(considered), try b.pure(input), wait));
        var inspect = try b.bind(outer_changed, try e.call(c.mapped_optional, &.{ input, outer }), try e.when(try b.reference(outer_changed), copy, try b.bind(region_changed, try e.call(c.mapped_optional, &.{ input, region }), try e.when(try b.reference(region_changed), copy, wait))));
        inspect = try b.bind(handler, try e.call(c.graph.record, &.{ try c.get(input, .machine), try e.field(attachment, 0) }), inspect);
        inspect = try b.bind(delimiter, try e.call(c.graph.record, &.{ try c.get(input, .machine), try e.field(saved, 2) }), inspect);
        inspect = try b.bind(record, try e.call(c.graph.record, &.{ try c.get(input, .machine), ref }), inspect);
        try b.define(c.template, try b.bind(found, try e.call(c.refs.map.get, &.{ try c.get(input, .mapping), try e.field(ref, 0) }), try e.when(try c.mapped(try b.reference(found)), try b.pure(input), inspect)));
    }

    fn emitScan(c: Generator) Error!void {
        const e = c.e;
        const b = e.b;
        {
            const input = try e.param(c.scan, 0);
            const ref = try e.param(c.scan, 1);
            const element = try b.variable(c.m.nodes.element);
            const record = try e.field(try b.reference(element), 0);
            const frame = try e.field(try b.reference(element), 1);
            const initial = try b.variable(c.list.table);
            const collected = try b.variable(c.list.table);
            const public_frame = try b.variable(c.m.frames.public);
            const nil = try b.variable(e.unit);
            const present = try b.variable(c.m.frames.schema);
            const frames = try b.term(.{ .match_sum = .{ .value = frame, .cases = &.{
                .{ .variable = nil, .body = try b.pure(try b.reference(initial)) },
                .{ .variable = present, .body = try b.bind(public_frame, try e.call(c.m.frames.to_public, &.{try b.reference(present)}), try e.call(c.frame_refs.walk, &.{ try b.reference(public_frame), try b.reference(initial) })) },
            } } });
            const immutable = try b.variable(e.boolean);
            var choose = try b.pure(try b.constant(bool, false));
            inline for ([_]g.NodeTag{ .environment, .aggregate, .computation }) |tag| choose = try e.when(try c.is(record, tag), try b.pure(try b.constant(bool, true)), choose);
            try b.define(c.scan, try b.bind(element, try e.call(c.graph.element, &.{ try c.get(input, .machine), ref }), try b.bind(initial, try e.call(c.refs.references, &.{record}), try b.bind(collected, frames, try b.bind(immutable, choose, try e.call(c.scan_refs, &.{ input, try b.reference(collected), e.zero, ref, try b.reference(immutable) }))))));
        }
        {
            const input = try e.param(c.scan_refs, 0);
            const list = try e.param(c.scan_refs, 1);
            const index = try e.param(c.scan_refs, 2);
            const original = try e.param(c.scan_refs, 3);
            const immutable = try e.param(c.scan_refs, 4);
            const found = try b.variable(c.list.optional);
            const ref = try e.payload(try b.reference(found), 1);
            const record_var = try b.variable(try projection.schema(g.Node, b));
            const record = try b.reference(record_var);
            const dependent = try b.variable(c.ctx);
            const current = try b.reference(dependent);
            const changed = try b.variable(c.ctx);
            var inspect = try b.pure(current);
            inline for ([_]g.NodeTag{ .environment, .aggregate, .computation }) |tag| inspect = try e.when(try c.is(record, tag), try e.call(c.discover, &.{ current, ref }), inspect);
            inspect = try e.when(try c.is(record, .cell), try e.call(c.dependency, &.{ current, try e.field(try e.payload(record, @backingInt(g.NodeTag.cell)), 1), ref }), inspect);
            inspect = try e.when(try c.is(record, .multi_template), try e.call(c.template, &.{ current, ref }), inspect);
            var visit = try b.bind(changed, inspect, try e.call(c.scan_refs, &.{ try b.reference(changed), list, try e.binary(.integer_add, index, e.one), original, immutable }));
            visit = try b.bind(record_var, try e.call(c.graph.record, &.{ try c.get(current, .machine), ref }), visit);
            visit = try b.bind(dependent, try e.when(immutable, try e.call(c.dependency, &.{ input, ref, original }), try b.pure(input)), visit);
            visit = try b.bind(found, try e.call(c.list.get, &.{ list, index }), visit);
            try b.define(c.scan_refs, try e.when(try e.binary(.less, index, try e.field(list, 0)), visit, try b.pure(input)));
        }
        inline for (.{ false, true }) |templates| {
            const entry = if (templates) c.template_list else c.include_list;
            const input = try e.param(entry, 0);
            const list = try e.param(entry, 1);
            const index = try e.param(entry, 2);
            const found = try b.variable(c.list.optional);
            const changed = try b.variable(c.ctx);
            const visit = try b.bind(found, try e.call(c.list.get, &.{ list, index }), try b.bind(changed, try e.call(if (templates) c.template else c.include, &.{ input, try e.payload(try b.reference(found), 1) }), try e.call(entry, &.{ try b.reference(changed), list, try e.binary(.integer_add, index, e.one) })));
            try b.define(entry, try e.when(try e.binary(.less, index, try e.field(list, 0)), visit, try b.pure(input)));
        }
        {
            const input = try e.param(c.propagate, 0);
            const ref = try e.param(c.propagate, 1);
            const parents = try b.variable(c.list.table);
            const waiting = try b.variable(c.list.table);
            const changed = try b.variable(c.ctx);
            try b.define(c.propagate, try b.bind(parents, try e.call(c.lookup_list, &.{ try c.get(input, .dependents), ref }), try b.bind(changed, try e.call(c.include_list, &.{ input, try b.reference(parents), e.zero }), try b.bind(waiting, try e.call(c.lookup_list, &.{ try c.get(try b.reference(changed), .waiting), ref }), try e.call(c.template_list, &.{ try b.reference(changed), try b.reference(waiting), e.zero })))));
        }
    }

    fn emitRun(c: Generator) Error!void {
        const e = c.e;
        const b = e.b;
        {
            const input = try e.param(c.run, 0);
            const index = try e.param(c.run, 1);
            const tasks = try c.get(input, .tasks);
            const found = try b.variable(c.tasks.optional);
            const task = try e.payload(try b.reference(found), 1);
            const changed = try b.variable(c.ctx);
            const invoke = try e.when(try e.binary(.equal, try e.field(task, 0), e.zero), try e.call(c.scan, &.{ input, try e.field(task, 1) }), try e.call(c.propagate, &.{ input, try e.field(task, 1) }));
            const step = try b.bind(found, try e.call(c.tasks.get, &.{ tasks, index }), try b.bind(changed, invoke, try e.call(c.run, &.{ try b.reference(changed), try e.binary(.integer_add, index, e.one) })));
            try b.define(c.run, try e.when(try e.binary(.less, index, try e.field(tasks, 0)), step, try b.pure(input)));
        }
        {
            const machine = try e.param(c.rebase, 0);
            const mapping = try e.param(c.rebase, 1);
            const originals = try e.param(c.rebase, 2);
            const index = try e.param(c.rebase, 3);
            const found = try b.variable(c.list.optional);
            const ref = try e.payload(try b.reference(found), 1);
            const element = try b.variable(c.m.nodes.element);
            const rebased_record = try b.variable(try projection.schema(g.Node, b));
            const rebased_frame = try b.variable(e.b.schemas.items[@intCast(c.m.nodes.element)].product[1]);
            const optional_frame = b.schemas.items[@intCast(c.m.nodes.element)].product[1];
            const nil = try b.variable(e.unit);
            const present = try b.variable(c.m.frames.schema);
            const public = try b.variable(c.m.frames.public);
            const mapped_public = try b.variable(c.m.frames.public);
            const hydrated = try b.variable(c.m.frames.schema);
            const frame = try b.term(.{ .match_sum = .{ .value = try e.field(try b.reference(element), 1), .cases = &.{
                .{ .variable = nil, .body = try b.pure(try e.variant(optional_frame, 0, e.unit_value)) },
                .{ .variable = present, .body = try b.bind(public, try e.call(c.m.frames.to_public, &.{try b.reference(present)}), try b.bind(mapped_public, try e.call(c.frame_refs.rebase, &.{ try b.reference(public), mapping }), try b.bind(hydrated, try e.call(c.m.frames.from_public, &.{try b.reference(mapped_public)}), try b.pure(try e.variant(optional_frame, 1, try b.reference(hydrated)))))) },
            } } });
            const target = try b.variable(c.refs.map.optional);
            const nodes = try b.variable(c.m.nodes.table);
            const replacement = try e.tuple(c.m.nodes.element, &.{ try b.reference(rebased_record), try b.reference(rebased_frame) });
            var step = try b.bind(nodes, try e.call(c.m.nodes.set, &.{ try c.m.field(e, machine, .nodes), try e.field(try e.payload(try b.reference(target), 1), 0), replacement }), try e.call(c.rebase, &.{ try e.replace(machine, @backingInt(machines.Field.nodes), try b.reference(nodes)), mapping, originals, try e.binary(.integer_add, index, e.one) }));
            step = try b.bind(target, try e.call(c.refs.map.get, &.{ mapping, try e.field(ref, 0) }), step);
            step = try b.bind(rebased_frame, frame, step);
            step = try b.bind(rebased_record, try e.call(c.refs.rebase, &.{ try e.field(try b.reference(element), 0), mapping }), step);
            step = try b.bind(element, try e.call(c.graph.element, &.{ machine, ref }), step);
            step = try b.bind(found, try e.call(c.list.get, &.{ originals, index }), step);
            try b.define(c.rebase, try e.when(try e.binary(.less, index, try e.field(originals, 0)), step, try b.pure(machine)));
        }
    }
};
