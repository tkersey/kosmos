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
pub const Field = enum(usize) {
    machine,
    mapping,
    originals,
    discovered,
    considered,
    dependents,
    waiting,
    tasks,
};
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
    const ctx = try b.schema(.{ .product = &.{
        m.schema,
        node_refs.map.tree,
        list.table,
        set.map.tree,
        set.map.tree,
        lists.tree,
        lists.tree,
        tasks.table,
    } });
    const capture = try projection.schema(g.Capture, b);
    const result = try b.schema(.{ .product = &.{ m.schema, capture } });
    const d: Definition = .{
        .instantiate = try b.declare(&.{ m.schema, capture }, result, &.{}, &.{}),
        .result = result,
        .context = ctx,
        .run = try b.declare(&.{ ctx, e.integer }, ctx, &.{}, &.{}),
        .rebase = try b.declare(&.{
            m.schema, node_refs.map.tree, list.table, e.integer,
        }, m.schema, &.{}, &.{}),
    };
    const c: Generator = try defineC(
        m,
        e,
        node_refs,
        ref,
        list,
        lists,
        set,
        tasks,
        ctx,
        capture,
        d,
    );
    try c.emitMaps();
    try c.emitCapture();
    try c.emitTemplate();
    try c.emitScan();
    try c.emitRun();
    try emitInstantiation(e, m, d, c, node_refs, list, lists, set, tasks, ctx, capture, result, b);
    return cache.finish(b, d);
}

const Generator = struct {
    e: Author,
    m: machines.Definition,
    ctx: Id,
    graph: graphs.Definition,
    refs: references.Definition,
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
        return c.e.binary(.equal, try c.e.b.primitive(
            c.e.integer,
            .variant_tag,
            &.{found},
            0,
        ), c.e.one);
    }
    fn is(c: Generator, record: Id, tag: g.NodeTag) Error!Id {
        return c.e.binary(.equal, try c.e.b.primitive(
            c.e.integer,
            .variant_tag,
            &.{record},
            0,
        ), try c.e.b.constant(u64, @backingInt(tag)));
    }

    fn emitMaps(c: Generator) Error!void {
        const e = c.e;
        const b = e.b;
        try emitEnqueue(c, e);
        try emitDiscover(c, e);
        try emitInclude(c, e);
        {
            const found = try b.variable(c.lists.optional);
            const nil = try b.variable(e.unit);
            const present = try b.variable(c.list.table);
            try b.define(c.lookup_list, try b.bind(found, try e.call(c.lists.get, &.{
                try e.param(c.lookup_list, 0), try e.field(try e.param(c.lookup_list, 1), 0),
            }), try b.term(.{ .match_sum = .{ .value = try b.reference(found), .cases = &.{ .{
                .variable = nil,
                .body = try b.pure(try c.list.empty(b)),
            }, .{ .variable = present, .body = try b.pure(try b.reference(present)) } } } })));
        }
        inline for (.{ Field.dependents, Field.waiting }) |which| {
            const entry = if (which == .dependents) c.add_dependency else c.add_waiting;
            const input = try e.param(entry, 0);
            const owner = try e.param(entry, 1);
            const value = try e.param(entry, 2);
            const prior = try b.variable(c.list.table);
            const appended = try b.variable(c.list.table);
            const map = try b.variable(c.lists.tree);
            try b.define(entry, try b.bind(prior, try e.call(
                c.lookup_list,
                &.{ try c.get(input, which), owner },
            ), try b.bind(appended, try e.call(
                c.list.append,
                &.{ try b.reference(prior), value },
            ), try b.bind(map, try e.call(c.lists.set, &.{
                try c.get(input, which), try e.field(owner, 0), try b.reference(appended),
            }), try b.pure(try c.put(input, which, try b.reference(map)))))));
        }
        try emitDependency(c, e);
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
        const done = try e.when(include_handler, try e.call(c.include, &.{
            current, try e.field(attachment, 0),
        }), try b.pure(current));
        const next = try captureSuccessor(
            c,
            e,
            b,
            record,
            next_ctx,
            current,
            saved,
            include_handler,
        );
        try b.define(c.capture_loop, try b.bind(record_var, try e.call(
            c.graph.record,
            &.{ try c.get(input, .machine), ref },
        ), try b.bind(included, try e.call(c.include, &.{ input, ref }), try e.when(try e.binary(
            .equal,
            try e.field(ref, 0),
            try e.field(delimiter, 0),
        ), done, next))));
        const capture_value = try e.param(c.capture, 1);
        try b.define(
            c.capture,
            try e.call(
                c.capture_loop,
                &.{
                    try e.param(c.capture, 0),
                    capture_value,
                    try e.param(c.capture, 2),
                    try e.field(capture_value, machines.index(g.Capture, "capture")),
                },
            ),
        );
    }

    fn emitTemplate(c: Generator) Error!void {
        const e = c.e;
        const b = e.b;
        try emitMappedOptional(c, e);
        const input = try e.param(c.template, 0);
        const ref = try e.param(c.template, 1);
        const found = try b.variable(c.refs.map.optional);
        const record = try b.variable(try projection.schema(g.Node, b));
        const delimiter = try b.variable(try projection.schema(g.Node, b));
        const handler = try b.variable(try projection.schema(g.Node, b));
        const saved = try e.payload(try b.reference(record), @backingInt(g.NodeTag.multi_template));
        const attachment = try e.payload(
            try b.reference(delimiter),
            @backingInt(g.NodeTag.attachment),
        );
        const activation = try e.payload(try b.reference(handler), @backingInt(g.NodeTag.handler));
        const outer = try e.field(attachment, 1);
        const region = try e.field(activation, 3);
        const outer_changed = try b.variable(e.boolean);
        const region_changed = try b.variable(e.boolean);
        const included = try b.variable(c.ctx);
        const copy = try b.bind(
            included,
            try e.call(c.include, &.{
                input,
                ref,
            }),
            try e.call(
                c.capture,
                &.{ try b.reference(included), saved, try b.constant(bool, true) },
            ),
        );
        const considered = try b.variable(e.boolean);
        const marked = try b.variable(c.set.map.tree);
        const waited = try b.variable(c.ctx);
        var wait = try b.bind(marked, try e.call(c.set.map.set, &.{
            try c.get(input, .considered), try e.field(ref, 0), e.unit_value,
        }), try b.bind(waited, try e.call(c.wait_optional, &.{ try c.put(
            input,
            .considered,
            try b.reference(marked),
        ), outer, ref }), try e.call(c.wait_optional, &.{ try b.reference(waited), region, ref })));
        wait = try b.bind(considered, try e.call(c.set.contains, &.{
            try c.get(input, .considered), try e.field(ref, 0),
        }), try e.when(try b.reference(considered), try b.pure(input), wait));
        var inspect = try b.bind(outer_changed, try e.call(
            c.mapped_optional,
            &.{ input, outer },
        ), try e.when(try b.reference(outer_changed), copy, try b.bind(region_changed, try e.call(
            c.mapped_optional,
            &.{ input, region },
        ), try e.when(try b.reference(region_changed), copy, wait))));
        inspect = try b.bind(handler, try e.call(c.graph.record, &.{
            try c.get(input, .machine), try e.field(attachment, 0),
        }), inspect);
        inspect = try b.bind(delimiter, try e.call(c.graph.record, &.{
            try c.get(input, .machine), try e.field(saved, 2),
        }), inspect);
        inspect = try b.bind(record, try e.call(
            c.graph.record,
            &.{ try c.get(input, .machine), ref },
        ), inspect);
        try b.define(c.template, try b.bind(found, try e.call(c.refs.map.get, &.{
            try c.get(input, .mapping), try e.field(ref, 0),
        }), try e.when(try c.mapped(try b.reference(found)), try b.pure(input), inspect)));
    }

    fn emitScan(c: Generator) Error!void {
        const e = c.e;
        const b = e.b;
        try emitScanScan(c, e);
        try emitScanRefs(c, e);
        inline for (.{ false, true }) |templates| {
            const entry = if (templates) c.template_list else c.include_list;
            const input = try e.param(entry, 0);
            const list = try e.param(entry, 1);
            const index = try e.param(entry, 2);
            const found = try b.variable(c.list.optional);
            const changed = try b.variable(c.ctx);
            const visit = try emitScanVisit(
                templates,
                c,
                e,
                input,
                list,
                index,
                found,
                changed,
                entry,
            );
            try b.define(entry, try e.when(
                try e.binary(.less, index, try e.field(list, 0)),
                visit,
                try b.pure(input),
            ));
        }
        try emitPropagate(c, e);
    }

    fn emitRun(c: Generator) Error!void {
        const e = c.e;
        try emitRunRun(c, e);
        try emitRebase(c, e);
    }
};

fn defineC(
    m: machines.Definition,
    e: Author,
    node_refs: anytype,
    ref: Id,
    list: anytype,
    lists: anytype,
    set: anytype,
    tasks: anytype,
    ctx: Id,
    capture: Id,
    d: Definition,
) Error!Generator {
    return .{
        .e = e,
        .m = m,
        .ctx = ctx,
        .graph = try graphs.define(e.b, m),
        .refs = node_refs,
        .capture_refs = try references.define(g.Capture, e.b),
        .list = list,
        .lists = lists,
        .set = set,
        .tasks = tasks,
        .enqueue = try e.b.declare(&.{ ctx, e.integer, ref }, ctx, &.{}, &.{}),
        .discover = try e.b.declare(&.{ ctx, ref }, ctx, &.{}, &.{}),
        .include = try e.b.declare(&.{ ctx, ref }, ctx, &.{}, &.{}),
        .dependency = try e.b.declare(&.{ ctx, ref, ref }, ctx, &.{}, &.{}),
        .add_dependency = try e.b.declare(&.{ ctx, ref, ref }, ctx, &.{}, &.{}),
        .add_waiting = try e.b.declare(&.{ ctx, ref, ref }, ctx, &.{}, &.{}),
        .lookup_list = try e.b.declare(&.{ lists.tree, ref }, list.table, &.{}, &.{}),
        .capture = try e.b.declare(&.{ ctx, capture, e.boolean }, ctx, &.{}, &.{}),
        .capture_loop = try e.b.declare(&.{
            ctx, capture, e.boolean, try projection.schema(?g.NodeRef, e.b),
        }, ctx, &.{}, &.{}),
        .template = try e.b.declare(&.{ ctx, ref }, ctx, &.{}, &.{}),
        .mapped_optional = try e.b.declare(&.{
            ctx, try projection.schema(?g.NodeRef, e.b),
        }, e.boolean, &.{}, &.{}),
        .wait_optional = try e.b.declare(&.{
            ctx, try projection.schema(?g.NodeRef, e.b), ref,
        }, ctx, &.{}, &.{}),
        .scan = try e.b.declare(&.{ ctx, ref }, ctx, &.{}, &.{}),
        .scan_refs = try e.b.declare(&.{
            ctx, list.table, e.integer, ref, e.boolean,
        }, ctx, &.{}, &.{}),
        .include_list = try e.b.declare(&.{ ctx, list.table, e.integer }, ctx, &.{}, &.{}),
        .template_list = try e.b.declare(&.{ ctx, list.table, e.integer }, ctx, &.{}, &.{}),
        .propagate = try e.b.declare(&.{ ctx, ref }, ctx, &.{}, &.{}),
        .run = d.run,
        .rebase = d.rebase,
    };
}

fn defineInitial(
    e: Author,
    node_refs: anytype,
    list: anytype,
    lists: anytype,
    set: anytype,
    tasks: anytype,
    ctx: Id,
    input: Id,
) Error!Id {
    return try e.tuple(ctx, &.{
        input,
        try node_refs.map.empty(e),
        try list.empty(e.b),
        try set.map.empty(e),
        try set.map.empty(e),
        try lists.empty(e),
        try lists.empty(e),
        try tasks.empty(e.b),
    });
}

fn emitScanVisit(
    comptime templates: bool,
    c: Generator,
    e: anytype,
    input: Id,
    list: Id,
    index: Id,
    found: Id,
    changed: Id,
    entry: anytype,
) Error!Id {
    return try e.b.bind(
        found,
        try e.call(c.list.get, &.{
            list,
            index,
        }),
        try e.b.bind(
            changed,
            try e.call(
                if (templates) c.template else c.include,
                &.{ input, try e.payload(try e.b.reference(found), 1) },
            ),
            try e.call(entry, &.{
                try e.b.reference(changed), list, try e.binary(.integer_add, index, e.one),
            }),
        ),
    );
}

fn emitRunStep(
    c: Generator,
    e: anytype,
    index: Id,
    tasks: anytype,
    found: Id,
    changed: Id,
    invoke: Id,
) Error!Id {
    return try e.b.bind(
        found,
        try e.call(c.tasks.get, &.{
            tasks,
            index,
        }),
        try e.b.bind(
            changed,
            invoke,
            try e.call(
                c.run,
                &.{ try e.b.reference(changed), try e.binary(.integer_add, index, e.one) },
            ),
        ),
    );
}

fn emitRunFrame(
    c: Generator,
    e: anytype,
    mapping: Id,
    element: Id,
    optional_frame: anytype,
    nil: Id,
    present: Id,
    rebased: Id,
) Error!Id {
    return try e.b.term(
        .{
            .match_sum = .{
                .value = try e.field(try e.b.reference(element), 1),
                .cases = &.{
                    .{ .variable = nil, .body = try e.b.pure(
                        try e.variant(optional_frame, 0, e.unit_value),
                    ) },
                    .{ .variable = present, .body = try e.b.bind(rebased, try e.call(
                        c.m.frames.rebase_references,
                        &.{ try e.b.reference(present), mapping },
                    ), try e.b.pure(try e.variant(
                        optional_frame,
                        1,
                        try e.b.reference(rebased),
                    ))) },
                },
            },
        },
    );
}

fn emitEnqueue(c: Generator, e: anytype) Error!void {
    const input = try e.param(c.enqueue, 0);
    const table = try e.b.variable(c.tasks.table);
    const task = try e.tuple(c.tasks.element, &.{
        try e.param(c.enqueue, 1), try e.param(c.enqueue, 2),
    });
    try e.b.define(c.enqueue, try e.b.bind(table, try e.call(
        c.tasks.append,
        &.{ try c.get(input, .tasks), task },
    ), try e.b.pure(try c.put(
        input,
        .tasks,
        try e.b.reference(table),
    ))));
}

fn emitDiscover(c: Generator, e: anytype) Error!void {
    const input = try e.param(c.discover, 0);
    const ref = try e.param(c.discover, 1);
    const seen = try e.b.variable(e.boolean);
    const updated = try e.b.variable(c.set.map.tree);
    const mark = try e.b.bind(updated, try e.call(c.set.map.set, &.{
        try c.get(input, .discovered), try e.field(ref, 0), e.unit_value,
    }), try e.call(c.enqueue, &.{ try c.put(
        input,
        .discovered,
        try e.b.reference(updated),
    ), e.zero, ref }));
    try e.b.define(c.discover, try e.b.bind(seen, try e.call(c.set.contains, &.{
        try c.get(input, .discovered), try e.field(ref, 0),
    }), try e.when(try e.b.reference(seen), try e.b.pure(input), mark)));
}

fn emitInclude(c: Generator, e: anytype) Error!void {
    const input = try e.param(c.include, 0);
    const ref = try e.param(c.include, 1);
    const machine = try c.get(input, .machine);
    const old_table = try c.m.field(e, machine, .nodes);
    const new_ref = try e.tuple(
        try projection.schema(g.NodeRef, e.b),
        &.{try e.field(old_table, 0)},
    );
    const found = try e.b.variable(c.refs.map.optional);
    const element = try e.b.variable(c.m.nodes.element);
    const nodes = try e.b.variable(c.m.nodes.table);
    const map = try e.b.variable(c.refs.map.tree);
    const originals = try e.b.variable(c.list.table);
    const queued = try e.b.variable(c.ctx);
    var changed = try c.put(input, .machine, try e.replace(
        machine,
        @backingInt(machines.Field.nodes),
        try e.b.reference(nodes),
    ));
    changed = try c.put(changed, .mapping, try e.b.reference(map));
    changed = try c.put(changed, .originals, try e.b.reference(originals));
    var add = try e.b.bind(
        queued,
        try e.call(c.discover, &.{
            changed,
            ref,
        }),
        try e.call(c.enqueue, &.{
            try e.b.reference(queued),
            e.one,
            ref,
        }),
    );
    add = try e.b.bind(originals, try e.call(c.list.append, &.{
        try c.get(input, .originals), ref,
    }), add);
    add = try e.b.bind(map, try e.call(c.refs.map.set, &.{
        try c.get(input, .mapping), try e.field(ref, 0), new_ref,
    }), add);
    add = try e.b.bind(nodes, try e.call(c.m.nodes.append, &.{
        old_table, try e.b.reference(element),
    }), add);
    add = try e.b.bind(element, try e.call(c.graph.element, &.{ machine, ref }), add);
    try e.b.define(c.include, try e.b.bind(found, try e.call(c.refs.map.get, &.{
        try c.get(input, .mapping), try e.field(ref, 0),
    }), try e.when(try c.mapped(try e.b.reference(found)), try e.b.pure(input), add)));
}

fn emitDependency(c: Generator, e: anytype) Error!void {
    const input = try e.param(c.dependency, 0);
    const child = try e.param(c.dependency, 1);
    const parent = try e.param(c.dependency, 2);
    const recorded = try e.b.variable(c.ctx);
    const found = try e.b.variable(c.refs.map.optional);
    try e.b.define(c.dependency, try e.b.bind(recorded, try e.call(
        c.add_dependency,
        &.{ input, child, parent },
    ), try e.b.bind(found, try e.call(c.refs.map.get, &.{
        try c.get(input, .mapping), try e.field(child, 0),
    }), try e.when(try c.mapped(try e.b.reference(found)), try e.call(c.include, &.{
        try e.b.reference(recorded), parent,
    }), try e.b.pure(try e.b.reference(recorded))))));
}

fn emitMappedOptional(c: Generator, e: anytype) Error!void {
    const input = try e.param(c.mapped_optional, 0);
    const nil = try e.b.variable(e.unit);
    const present = try e.b.variable(try projection.schema(g.NodeRef, e.b));
    const found = try e.b.variable(c.refs.map.optional);
    try emitMappedOptionalMappedOptionalDefinition(c, e, input, nil, present, found);
    try emitMappedOptionalWaitOptionalDefinition(c, e, nil, present);
}

fn emitScanScan(c: Generator, e: anytype) Error!void {
    const input = try e.param(c.scan, 0);
    const ref = try e.param(c.scan, 1);
    const element = try e.b.variable(c.m.nodes.element);
    const record = try e.field(try e.b.reference(element), 0);
    const frame = try e.field(try e.b.reference(element), 1);
    const initial = try e.b.variable(c.list.table);
    const collected = try e.b.variable(c.list.table);
    const nil = try e.b.variable(e.unit);
    const present = try e.b.variable(c.m.frames.schema);
    const frames = try e.b.term(.{ .match_sum = .{ .value = frame, .cases = &.{
        .{ .variable = nil, .body = try e.b.pure(try e.b.reference(initial)) },
        .{ .variable = present, .body = try e.call(c.m.frames.walk_references, &.{
            try e.b.reference(present), try e.b.reference(initial),
        }) },
    } } });
    const immutable = try e.b.variable(e.boolean);
    var choose = try e.b.pure(try e.b.constant(bool, false));
    inline for ([_]g.NodeTag{
        .environment,
        .aggregate,
        .computation,
    }) |tag| choose = try e.when(
        try c.is(record, tag),
        try e.b.pure(try e.b.constant(bool, true)),
        choose,
    );
    try emitScanScanScanDefinition(
        c,
        e,
        input,
        ref,
        element,
        record,
        initial,
        collected,
        frames,
        immutable,
        choose,
    );
}

fn emitScanRefs(c: Generator, e: anytype) Error!void {
    const input = try e.param(c.scan_refs, 0);
    const list = try e.param(c.scan_refs, 1);
    const index = try e.param(c.scan_refs, 2);
    const original = try e.param(c.scan_refs, 3);
    const immutable = try e.param(c.scan_refs, 4);
    const found = try e.b.variable(c.list.optional);
    const ref = try e.payload(try e.b.reference(found), 1);
    const record_var = try e.b.variable(try projection.schema(g.Node, e.b));
    const record = try e.b.reference(record_var);
    const dependent = try e.b.variable(c.ctx);
    const current = try e.b.reference(dependent);
    const changed = try e.b.variable(c.ctx);
    var inspect = try e.b.pure(current);
    inline for ([_]g.NodeTag{
        .environment,
        .aggregate,
        .computation,
    }) |tag| inspect = try e.when(
        try c.is(record, tag),
        try e.call(c.discover, &.{ current, ref }),
        inspect,
    );
    inspect = try emitScanRefsCell(c, e, ref, record, current, inspect);
    inspect = try e.when(
        try c.is(record, .multi_template),
        try e.call(c.template, &.{ current, ref }),
        inspect,
    );
    var visit = try e.b.bind(changed, inspect, try e.call(c.scan_refs, &.{
        try e.b.reference(changed),
        list,
        try e.binary(.integer_add, index, e.one),
        original,
        immutable,
    }));
    visit = try e.b.bind(record_var, try e.call(c.graph.record, &.{
        try c.get(current, .machine), ref,
    }), visit);
    visit = try e.b.bind(dependent, try e.when(immutable, try e.call(
        c.dependency,
        &.{ input, ref, original },
    ), try e.b.pure(input)), visit);
    visit = try e.b.bind(found, try e.call(c.list.get, &.{ list, index }), visit);
    try e.b.define(c.scan_refs, try e.when(
        try e.binary(.less, index, try e.field(list, 0)),
        visit,
        try e.b.pure(input),
    ));
}

fn emitPropagate(c: Generator, e: anytype) Error!void {
    const input = try e.param(c.propagate, 0);
    const ref = try e.param(c.propagate, 1);
    const parents = try e.b.variable(c.list.table);
    const waiting = try e.b.variable(c.list.table);
    const changed = try e.b.variable(c.ctx);
    try e.b.define(c.propagate, try e.b.bind(parents, try e.call(c.lookup_list, &.{
        try c.get(input, .dependents), ref,
    }), try e.b.bind(changed, try e.call(c.include_list, &.{
        input, try e.b.reference(parents), e.zero,
    }), try e.b.bind(waiting, try e.call(c.lookup_list, &.{
        try c.get(try e.b.reference(changed), .waiting), ref,
    }), try e.call(c.template_list, &.{
        try e.b.reference(changed), try e.b.reference(waiting), e.zero,
    })))));
}

fn emitRunRun(c: Generator, e: anytype) Error!void {
    const input = try e.param(c.run, 0);
    const index = try e.param(c.run, 1);
    const tasks = try c.get(input, .tasks);
    const found = try e.b.variable(c.tasks.optional);
    const task = try e.payload(try e.b.reference(found), 1);
    const changed = try e.b.variable(c.ctx);
    const invoke = try e.when(try e.binary(
        .equal,
        try e.field(task, 0),
        e.zero,
    ), try e.call(
        c.scan,
        &.{ input, try e.field(task, 1) },
    ), try e.call(c.propagate, &.{ input, try e.field(task, 1) }));
    const step = try emitRunStep(c, e, index, tasks, found, changed, invoke);
    try e.b.define(c.run, try e.when(try e.binary(
        .less,
        index,
        try e.field(tasks, 0),
    ), step, try e.b.pure(input)));
}

fn emitRebase(c: Generator, e: anytype) Error!void {
    const machine = try e.param(c.rebase, 0);
    const mapping = try e.param(c.rebase, 1);
    const originals = try e.param(c.rebase, 2);
    const index = try e.param(c.rebase, 3);
    const found = try e.b.variable(c.list.optional);
    const ref = try e.payload(try e.b.reference(found), 1);
    const element = try e.b.variable(c.m.nodes.element);
    const rebased_record = try e.b.variable(try projection.schema(g.Node, e.b));
    const rebased_frame = try e.b.variable(
        e.b.schemas.items[@intCast(c.m.nodes.element)].product[1],
    );
    const optional_frame = e.b.schemas.items[@intCast(c.m.nodes.element)].product[1];
    const nil = try e.b.variable(e.unit);
    const present = try e.b.variable(c.m.frames.schema);
    const rebased = try e.b.variable(c.m.frames.schema);
    const frame = try emitRunFrame(
        c,
        e,
        mapping,
        element,
        optional_frame,
        nil,
        present,
        rebased,
    );
    const target = try e.b.variable(c.refs.map.optional);
    const nodes = try e.b.variable(c.m.nodes.table);
    const replacement = try e.tuple(c.m.nodes.element, &.{
        try e.b.reference(rebased_record), try e.b.reference(rebased_frame),
    });
    var step = try e.b.bind(
        nodes,
        try e.call(
            c.m.nodes.set,
            &.{
                try c.m.field(e, machine, .nodes),
                try e.field(try e.payload(try e.b.reference(target), 1), 0),
                replacement,
            },
        ),
        try e.call(c.rebase, &.{ try e.replace(
            machine,
            @backingInt(machines.Field.nodes),
            try e.b.reference(nodes),
        ), mapping, originals, try e.binary(.integer_add, index, e.one) }),
    );
    step = try e.b.bind(target, try e.call(
        c.refs.map.get,
        &.{ mapping, try e.field(ref, 0) },
    ), step);
    step = try e.b.bind(rebased_frame, frame, step);
    step = try e.b.bind(rebased_record, try e.call(c.refs.rebase, &.{
        try e.field(try e.b.reference(element), 0), mapping,
    }), step);
    step = try e.b.bind(element, try e.call(c.graph.element, &.{ machine, ref }), step);
    step = try e.b.bind(found, try e.call(c.list.get, &.{ originals, index }), step);
    try e.b.define(c.rebase, try e.when(try e.binary(
        .less,
        index,
        try e.field(originals, 0),
    ), step, try e.b.pure(machine)));
}

fn defineInstantiateDefinition(
    e: Author,
    result: Id,
    d: Definition,
    c: Generator,
    template: Id,
    initial: anytype,
    seeded: Id,
    closed: Id,
    rebased: Id,
    captured: Id,
    finished: Id,
) Error!void {
    try e.b.define(d.instantiate, try e.b.bind(seeded, try e.call(c.capture, &.{
        initial, template, try e.b.constant(bool, false),
    }), try e.b.bind(closed, try e.call(c.run, &.{
        try e.b.reference(seeded), e.zero,
    }), try e.b.bind(rebased, try e.call(c.rebase, &.{
        try c.get(finished, .machine),
        try c.get(finished, .mapping),
        try c.get(finished, .originals),
        e.zero,
    }), try e.b.bind(captured, try e.call(c.capture_refs.rebase, &.{
        template, try c.get(finished, .mapping),
    }), try e.b.pure(try e.tuple(result, &.{
        try e.b.reference(rebased), try e.b.reference(captured),
    })))))));
}

fn emitMappedOptionalMappedOptionalDefinition(
    c: Generator,
    e: anytype,
    input: Id,
    nil: Id,
    present: Id,
    found: Id,
) Error!void {
    try e.b.define(
        c.mapped_optional,
        try e.b.term(
            .{
                .match_sum = .{
                    .value = try e.param(c.mapped_optional, 1),
                    .cases = &.{
                        .{
                            .variable = nil,
                            .body = try e.b.pure(try e.b.constant(bool, false)),
                        },
                        .{
                            .variable = present,
                            .body = try e.b.bind(
                                found,
                                try e.call(
                                    c.refs.map.get,
                                    &.{
                                        try c.get(input, .mapping),
                                        try e.field(try e.b.reference(present), 0),
                                    },
                                ),
                                try e.b.pure(try c.mapped(try e.b.reference(found))),
                            ),
                        },
                    },
                },
            },
        ),
    );
}

fn emitMappedOptionalWaitOptionalDefinition(
    c: Generator,
    e: anytype,
    nil: Id,
    present: Id,
) Error!void {
    try e.b.define(
        c.wait_optional,
        try e.b.term(
            .{
                .match_sum = .{
                    .value = try e.param(c.wait_optional, 1),
                    .cases = &.{
                        .{
                            .variable = nil,
                            .body = try e.b.pure(try e.param(c.wait_optional, 0)),
                        },
                        .{ .variable = present, .body = try e.call(c.add_waiting, &.{
                            try e.param(c.wait_optional, 0),
                            try e.b.reference(present),
                            try e.param(c.wait_optional, 2),
                        }) },
                    },
                },
            },
        ),
    );
}

fn emitScanScanScanDefinition(
    c: Generator,
    e: anytype,
    input: Id,
    ref: Id,
    element: Id,
    record: Id,
    initial: Id,
    collected: Id,
    frames: Id,
    immutable: Id,
    choose: Id,
) Error!void {
    try e.b.define(c.scan, try e.b.bind(element, try e.call(
        c.graph.element,
        &.{ try c.get(input, .machine), ref },
    ), try e.b.bind(
        initial,
        try e.call(c.refs.references, &.{
            record,
        }),
        try e.b.bind(
            collected,
            frames,
            try e.b.bind(
                immutable,
                choose,
                try e.call(
                    c.scan_refs,
                    &.{
                        input,
                        try e.b.reference(collected),
                        e.zero,
                        ref,
                        try e.b.reference(immutable),
                    },
                ),
            ),
        ),
    )));
}

fn emitScanRefsCell(
    c: Generator,
    e: anytype,
    ref: Id,
    record: Id,
    current: Id,
    inspect: Id,
) Error!Id {
    return try e.when(
        try c.is(record, .cell),
        try e.call(
            c.dependency,
            &.{
                current,
                try e.field(try e.payload(
                    record,
                    @backingInt(g.NodeTag.cell),
                ), 1),
                ref,
            },
        ),
        inspect,
    );
}

fn emitInstantiation(
    e: Author,
    m: machines.Definition,
    d: Definition,
    c: Generator,
    node_refs: references.Definition,
    list: tables.Definition,
    lists: maps.Definition,
    set: sets.Definition,
    tasks: tables.Definition,
    ctx: Id,
    capture: Id,
    result: Id,
    b: *source.Builder,
) Error!void {
    const input = try e.param(d.instantiate, 0);
    const template = try e.param(d.instantiate, 1);
    const initial = try defineInitial(e, node_refs, list, lists, set, tasks, ctx, input);
    const seeded = try b.variable(ctx);
    const closed = try b.variable(ctx);
    const rebased = try b.variable(m.schema);
    const captured = try b.variable(capture);
    const finished = try b.reference(closed);
    try defineInstantiateDefinition(
        e,
        result,
        d,
        c,
        template,
        initial,
        seeded,
        closed,
        rebased,
        captured,
        finished,
    );
}

fn captureSuccessor(
    c: Generator,
    e: Author,
    b: *source.Builder,
    record: Id,
    next_ctx: Id,
    current: Id,
    saved: Id,
    include_handler: Id,
) Error!Id {
    var next = try e.fail();
    inline for ([_]g.NodeTag{ .continuation, .attachment, .region_scope, .injection }) |tag| {
        const payload = try e.payload(record, @backingInt(tag));
        const parent = switch (tag) {
            .continuation => try e.field(payload, 1),
            .attachment, .region_scope => try e.field(payload, 2),
            .injection => try e.variant(
                try projection.schema(?g.NodeRef, b),
                1,
                try e.field(payload, 0),
            ),
            else => unreachable,
        };
        const recurse = try e.call(c.capture_loop, &.{
            if (tag == .attachment or
                tag == .region_scope) try b.reference(next_ctx) else current,
            saved,
            include_handler,
            parent,
        });
        const follow = if (tag == .attachment or tag == .region_scope) try b.bind(
            next_ctx,
            try e.call(
                c.include,
                &.{ current, try e.field(
                    payload,
                    if (tag == .attachment) 0 else 1,
                ) },
            ),
            recurse,
        ) else recurse;
        next = try e.when(try c.is(record, tag), follow, next);
    }
    return next;
}
