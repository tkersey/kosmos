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

pub fn define(
    b: *source.Builder,
    m: machines.Definition,
    clone: clones.Definition,
) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.clone-validation/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const refs = try references.define(data.process_state.Node, b);
    const list = refs.refs;
    const d: Definition = .{
        .context = try b.declare(&.{ clone.context, e.integer }, e.boolean, &.{}, &.{}),
        .rebase = try b.declare(&.{
            m.schema, refs.map.tree, list.table, e.integer,
        }, e.boolean, &.{}, &.{}),
    };
    const no = try b.pure(try b.constant(bool, false));
    const yes = try b.pure(try b.constant(bool, true));
    // The map cardinality equals the ordered originals list. Each original is
    // below the append boundary and maps to its own unique appended index.
    const walk = try b.declare(&.{
        m.schema, refs.map.tree, list.table, e.integer, e.integer, e.integer,
    }, e.boolean, &.{}, &.{});
    try emitWalk(m, e, refs, list, no, yes, walk);
    try emitRebase(m, e, refs, list, d, no, walk);
    try emitContext(m, e, list, d, no, yes);
    return cache.finish(b, d);
}

fn guard(e: Author, entry: Id, arguments: []const Id, yes: Id, no: Id) Error!Id {
    const valid = try e.b.variable(e.boolean);
    return e.b.bind(
        valid,
        try e.call(entry, arguments),
        try e.when(try e.b.reference(valid), yes, no),
    );
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
        valid_leaf = try guard(e, list.valid, &.{value}, try e.call(
            try recovery.bounds(e, list),
            &.{ value, limit, e.zero },
        ), no);
    }
    const branch = try b.reference(fork);
    try b.define(entry, try b.term(.{ .match_sum = .{ .value = input, .cases = &.{
        .{ .variable = nil, .body = yes },
        .{ .variable = leaf, .body = try e.when(
            try e.binary(.less, try e.field(pair, 0), limit),
            valid_leaf,
            no,
        ) },
        .{
            .variable = fork,
            .body = try guard(
                e,
                entry,
                &.{ try e.field(branch, 1), limit },
                try e.call(entry, &.{ try e.field(branch, 2), limit }),
                no,
            ),
        },
    } } }));
    return entry;
}

fn defineVisit(
    e: Author,
    no: Id,
    index: Id,
    found: Id,
    next: Id,
    tasks: anytype,
    task_input: Id,
    task_limit: Id,
    task: Id,
) Error!Id {
    return try e.b.bind(
        found,
        try e.call(tasks.get, &.{
            task_input,
            index,
        }),
        try e.when(
            try e.binary(.less, try e.field(task, 0), try e.b.constant(u64, 2)),
            try e.when(try e.binary(
                .less,
                try e.field(try e.field(task, 1), 0),
                task_limit,
            ), next, no),
            no,
        ),
    );
}

fn emitWalk(
    m: machines.Definition,
    e: Author,
    refs: anytype,
    list: anytype,
    no: Id,
    yes: Id,
    walk: Id,
) Error!void {
    const machine = try e.param(walk, 0);
    const mapping = try e.param(walk, 1);
    const originals = try e.param(walk, 2);
    const cursor = try e.param(walk, 3);
    const base = try e.param(walk, 4);
    const index = try e.param(walk, 5);
    const original = try e.b.variable(list.optional);
    const old_id = try e.field(try e.payload(try e.b.reference(original), 1), 0);
    const found = try e.b.variable(refs.map.optional);
    const expected_id = try e.binary(.integer_add, base, index);
    const old = try e.b.variable(m.nodes.optional);
    const new = try e.b.variable(m.nodes.optional);
    const old_public = try e.b.variable(try projection.schema(data.process_state.Node, e.b));
    const new_public = try e.b.variable(try projection.schema(data.process_state.Node, e.b));
    const expected = try e.b.variable(try projection.schema(data.process_state.Node, e.b));
    const equal = try e.b.variable(e.boolean);
    const next = try e.call(walk, &.{
        machine, mapping, originals, cursor, base, try e.binary(.integer_add, index, e.one),
    });
    var inspect = try e.b.bind(
        equal,
        try e.call(
            try @import("record_equal.zig").define(data.process_state.Node, e.b),
            &.{ try e.b.reference(expected), try e.b.reference(new_public) },
        ),
        try e.when(try e.b.reference(equal), next, no),
    );
    inspect = try emitWalkInspect(e, refs, mapping, cursor, index, old_public, expected, inspect);
    inspect = try bindWalkRecords(
        m,
        e,
        refs,
        list,
        mapping,
        originals,
        index,
        base,
        old_id,
        expected_id,
        found,
        original,
        new_public,
        old_public,
        new,
        old,
        machine,
        no,
        inspect,
    );
    try e.b.define(walk, try e.when(try e.binary(
        .less,
        index,
        try e.field(originals, 0),
    ), inspect, yes));
}

fn emitRebase(
    m: machines.Definition,
    e: Author,
    refs: anytype,
    list: anytype,
    d: Definition,
    no: Id,
    walk: Id,
) Error!void {
    const machine = try e.param(d.rebase, 0);
    const mapping = try e.param(d.rebase, 1);
    const originals = try e.param(d.rebase, 2);
    const cursor = try e.param(d.rebase, 3);
    const count = try e.field(originals, 0);
    const total = try e.field(try m.field(e, machine, .nodes), 0);
    const entries = try e.b.variable(refs.map.entries);
    var checked = try e.call(walk, &.{
        machine, mapping, originals, cursor, try e.binary(.integer_sub, total, count), e.zero,
    });
    checked = try e.when(try e.binary(.less, total, count), no, checked);
    checked = try e.when(try e.binary(.less, count, cursor), no, checked);
    checked = try e.b.bind(
        entries,
        try e.call(refs.map.to_sequence, &.{
            mapping,
        }),
        try e.when(
            try e.binary(
                .equal,
                try e.b.primitive(
                    e.integer,
                    .sequence_length,
                    &.{try e.b.reference(entries)},
                    0,
                ),
                count,
            ),
            checked,
            no,
        ),
    );
    checked = try guard(e, refs.map.valid, &.{mapping}, checked, no);
    checked = try guard(e, list.valid, &.{originals}, checked, no);
    checked = try guard(e, try recovery.storage(e.b, m), &.{machine}, checked, no);
    try e.b.define(d.rebase, checked);
}

fn emitContext(
    m: machines.Definition,
    e: Author,
    list: anytype,
    d: Definition,
    no: Id,
    yes: Id,
) Error!void {
    const ctx = try e.param(d.context, 0);
    const cursor = try e.param(d.context, 1);
    const machine = try e.field(ctx, @backingInt(clones.Field.machine));
    const mapping = try e.field(ctx, @backingInt(clones.Field.mapping));
    const originals = try e.field(ctx, @backingInt(clones.Field.originals));
    const total = try e.field(try m.field(e, machine, .nodes), 0);
    const count = try e.field(originals, 0);
    const limit = try e.binary(.integer_sub, total, count);
    const tasks = try tables.define(e.b, try projection.schema(clones.Task, e.b));
    const task_list = try e.field(ctx, @backingInt(clones.Field.tasks));
    const task_walk = try e.b.declare(&.{
        tasks.table, e.integer, e.integer,
    }, e.boolean, &.{}, &.{});
    const task_input = try e.param(task_walk, 0);
    const task_limit = try e.param(task_walk, 1);
    const index = try e.param(task_walk, 2);
    const found = try e.b.variable(tasks.optional);
    const task = try e.payload(try e.b.reference(found), 1);
    const next = try e.call(task_walk, &.{
        task_input, task_limit, try e.binary(.integer_add, index, e.one),
    });
    const visit = try defineVisit(e, no, index, found, next, tasks, task_input, task_limit, task);
    try e.b.define(task_walk, try e.when(try e.binary(
        .less,
        index,
        try e.field(task_input, 0),
    ), visit, yes));
    var checked = try e.call(task_walk, &.{ task_list, limit, e.zero });
    checked = try e.when(try e.binary(.less, try e.field(task_list, 0), cursor), no, checked);
    checked = try guard(e, tasks.valid, &.{task_list}, checked, no);
    inline for (.{
        clones.Field.discovered,
        clones.Field.considered,
        clones.Field.dependents,
        clones.Field.waiting,
    }) |field| {
        const has_lists = field == .dependents or field == .waiting;
        const map = try maps.define(e.b, if (has_lists) list.table else e.unit);
        const value = try e.field(ctx, @backingInt(field));
        checked = try guard(e, try boundedMap(
            e,
            map,
            if (has_lists) list else null,
        ), &.{ value, limit }, checked, no);
        checked = try guard(e, map.valid, &.{value}, checked, no);
    }
    try e.b.define(d.context, try guard(e, d.rebase, &.{
        machine, mapping, originals, e.zero,
    }, checked, no));
}

fn emitWalkInspect(
    e: Author,
    refs: anytype,
    mapping: Id,
    cursor: Id,
    index: Id,
    old_public: Id,
    expected: Id,
    inspect: Id,
) Error!Id {
    return try e.b.bind(
        expected,
        try e.when(
            try e.binary(.less, index, cursor),
            try e.call(refs.rebase, &.{
                try e.b.reference(old_public),
                mapping,
            }),
            try e.b.pure(try e.b.reference(old_public)),
        ),
        inspect,
    );
}

fn bindWalkRecords(
    m: machines.Definition,
    e: Author,
    refs: references.Definition,
    list: tables.Definition,
    mapping: Id,
    originals: Id,
    index: Id,
    base: Id,
    old_id: Id,
    expected_id: Id,
    found: Id,
    original: Id,
    new_public: Id,
    old_public: Id,
    new: Id,
    old: Id,
    machine: Id,
    no: Id,
    inspect: Id,
) Error!Id {
    var inspect_result = inspect;
    inspect_result = try e.b.bind(new_public, try e.call(m.node_to_public, &.{
        try e.payload(try e.b.reference(new), 1),
    }), inspect_result);
    inspect_result = try e.b.bind(old_public, try e.call(m.node_to_public, &.{
        try e.payload(try e.b.reference(old), 1),
    }), inspect_result);
    inspect_result = try e.b.bind(new, try e.call(m.nodes.get, &.{
        try m.field(e, machine, .nodes), expected_id,
    }), inspect_result);
    inspect_result = try e.b.bind(old, try e.call(m.nodes.get, &.{
        try m.field(e, machine, .nodes), old_id,
    }), inspect_result);
    inspect_result = try e.when(try e.binary(.equal, try e.field(
        try e.payload(try e.b.reference(found), 1),
        0,
    ), expected_id), inspect_result, no);
    inspect_result = try e.b.bind(found, try e.call(
        refs.map.get,
        &.{ mapping, old_id },
    ), try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{try e.b.reference(found)},
        0,
    ), e.one), inspect_result, no));
    inspect_result = try e.b.bind(
        original,
        try e.call(list.get, &.{ originals, index }),
        try e.when(
            try e.binary(.less, old_id, base),
            inspect_result,
            no,
        ),
    );
    return inspect_result;
}
