//! Simultaneous edge assignment and continuation retention, authored in Horos.
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const sets = @import("sets.zig");
const tables = @import("table.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const ir = data.activation;
const g = data.graph;

pub const Definition = struct {
    assign: Id,
    retained: Id,
    tail: Id,
    next: Id,
    collect: Id,
    write: Id,
};

pub fn field(e: Author, value: Id, comptime T: type, comptime name: []const u8) Error!Id {
    return e.field(value, machines.index(T, name));
}
pub fn code(e: Author, program: Id) Error!Id {
    return field(e, program, projection.Program, "code");
}
pub fn block(e: Author, program: Id, id: Id) Error!Id {
    return e.required(try field(e, try code(e, program), ir.Program, "blocks"), id);
}
pub fn function(e: Author, program: Id, id: Id) Error!Id {
    return e.required(try field(e, try code(e, program), ir.Program, "functions"), id);
}
pub fn live(e: Author, program: Id, id: Id) Error!Id {
    return e.required(try e.required(try field(
        e,
        program,
        projection.Program,
        "live",
    ), id), e.zero);
}

// A sequence cursor is ordinary source data, not a native traversal callback.
const Cursor = struct {
    expression: Id,
    nil: Id,
    pair: Id,
    head: Id,
    rest: Id,
    fn init(e: Author, input: Id) Error!Cursor {
        const b = e.b;
        const schema = b.values.items[@intCast(input)].schema;
        const element = b.schemas.items[@intCast(schema)].seq;
        const parts = try b.schema(.{ .product = &.{ element, schema } });
        const optional = try b.schema(.{ .sum = &.{ e.unit, parts } });
        const pair = try b.variable(parts);
        return .{ .expression = try b.primitive(
            optional,
            .sequence_pop,
            &.{input},
            0,
        ), .nil = try b.variable(e.unit), .pair = pair, .head = try e.field(try b.reference(
            pair,
        ), 0), .rest = try e.field(try b.reference(
            pair,
        ), 1) };
    }
    fn match(c: Cursor, e: Author, empty: Id, present: Id) Error!Id {
        return e.b.term(
            .{
                .match_sum = .{
                    .value = c.expression,
                    .cases = &.{
                        .{ .variable = c.nil, .body = empty },
                        .{ .variable = c.pair, .body = present },
                    },
                },
            },
        );
    }
};

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.edges/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const set = try sets.define(b);
    const edge = try projection.schema(ir.Edge, b);
    const value = try projection.schema(g.Value, b);
    const maybe_value = try projection.schema(?g.Value, b);
    const ids = try projection.schema([]const Id, b);
    const values = try projection.schema([]const g.Value, b);
    const assignments = try projection.schema([]const ir.Assignment, b);
    const binding = try projection.schema(data.process_state.Binding, b);
    const bindings = try tables.define(b, binding);
    const d: Definition = .{
        .assign = try b.declare(&.{
            m.program, m.frames.schema, edge, maybe_value,
        }, m.frames.schema, &.{}, &.{}),
        .retained = try b.declare(&.{ m.program, edge }, set.map.tree, &.{}, &.{}),
        .tail = try b.declare(&.{ m.program, edge }, e.boolean, &.{}, &.{}),
        .next = try b.declare(&.{try projection.schema(ir.Terminator, b)}, edge, &.{}, &.{}),
        .collect = try b.declare(&.{ m.frames.schema, ids }, values, &.{}, &.{}),
        .write = try b.declare(&.{ m.frames.schema, ids, values }, m.frames.schema, &.{}, &.{}),
    };
    // Gather all live writes from the predecessor before clearing any source.
    const gather = try b.declare(&.{
        m.frames.schema, assignments, set.map.tree, maybe_value, bindings.table,
    }, bindings.table, &.{}, &.{});
    try emitGather(m, e, set, value, binding, bindings, gather);
    const clear = try b.declare(&.{
        m.program, m.frames.schema, assignments, ids,
    }, m.frames.schema, &.{}, &.{});
    try emitClear(m, e, clear);
    const write_bindings = try b.declare(&.{
        m.frames.schema, bindings.sequence,
    }, m.frames.schema, &.{}, &.{});
    try emitWriteBindings(m, e, write_bindings);
    try emitAssign(m, e, set, bindings, d, gather, clear, write_bindings);
    // R = (live(target) minus destinations) union live assignment sources.
    try emitRetention(e, set, assignments, d);
    try emitTail(e, d);
    try emitNext(e, d);
    try emitLoop(m, e, value, ids, d);
    try emitWrite(m, e, d);
    return cache.finish(b, d);
}

fn emitGather(
    m: machines.Definition,
    e: Author,
    set: sets.Definition,
    value: Id,
    binding: Id,
    bindings: tables.Definition,
    gather: Id,
) Error!void {
    const frame = try e.param(gather, 0);
    const cursor = try Cursor.init(e, try e.param(gather, 1));
    const mask = try e.param(gather, 2);
    const returned = try e.param(gather, 3);
    const prior = try e.param(gather, 4);
    const destination = try e.field(cursor.head, 0);
    const source_value = try e.field(cursor.head, 1);
    const contains = try e.b.variable(e.boolean);
    const selected = try e.b.variable(value);
    const next = try e.b.variable(bindings.table);
    const slot = try e.b.variable(e.integer);
    const unit = try e.b.variable(e.unit);
    const select = try e.b.term(.{ .match_sum = .{ .value = source_value, .cases = &.{
        .{ .variable = slot, .body = try e.call(
            m.frames.read,
            &.{ frame, try e.b.reference(slot) },
        ) },
        .{ .variable = unit, .body = try e.b.pure(try e.payload(returned, 1)) },
    } } });
    const append = try e.b.bind(
        selected,
        select,
        try e.b.bind(
            next,
            try e.call(
                bindings.append,
                &.{ prior, try e.tuple(binding, &.{
                    destination,
                    try e.b.reference(selected),
                }) },
            ),
            try e.call(gather, &.{ frame, cursor.rest, mask, returned, try e.b.reference(next) }),
        ),
    );
    const accepted = try e.call(
        set.contains,
        &.{ mask, destination },
    );
    const choice = try e.when(try e.b.reference(contains), append, try e.call(gather, &.{
        frame, cursor.rest, mask, returned, prior,
    }));
    const checked = try e.b.bind(contains, accepted, choice);
    try e.b.define(gather, try cursor.match(e, try e.b.pure(prior), checked));
}

fn emitClear(m: machines.Definition, e: Author, clear: Id) Error!void {
    const program = try e.param(clear, 0);
    const frame = try e.param(clear, 1);
    const cursor = try Cursor.init(e, try e.param(clear, 2));
    const layout = try e.param(clear, 3);
    const slot_var = try e.b.variable(e.integer);
    const slot = try e.b.reference(slot_var);
    const unit = try e.b.variable(e.unit);
    const changed = try e.b.variable(m.frames.schema);
    const copy = try field(e, try field(
        e,
        program,
        projection.Program,
        "uses",
    ), data.traits.Facts, "copy");
    const skip = try e.call(clear, &.{ program, frame, cursor.rest, layout });
    const remove = try e.b.bind(
        changed,
        try e.call(m.frames.clear, &.{
            frame,
            slot,
        }),
        try e.call(clear, &.{
            program,
            try e.b.reference(changed),
            cursor.rest,
            layout,
        }),
    );
    try e.b.define(
        clear,
        try cursor.match(
            e,
            try e.b.pure(frame),
            try e.b.term(
                .{
                    .match_sum = .{
                        .value = try e.field(cursor.head, 1),
                        .cases = &.{
                            .{ .variable = slot_var, .body = try e.when(
                                try e.required(copy, try e.required(layout, slot)),
                                skip,
                                remove,
                            ) },
                            .{ .variable = unit, .body = skip },
                        },
                    },
                },
            ),
        ),
    );
}

fn emitWriteBindings(m: machines.Definition, e: Author, write_bindings: Id) Error!void {
    const frame = try e.param(write_bindings, 0);
    const cursor = try Cursor.init(e, try e.param(write_bindings, 1));
    const changed = try e.b.variable(m.frames.schema);
    try e.b.define(
        write_bindings,
        try cursor.match(
            e,
            try e.b.pure(frame),
            try e.b.bind(
                changed,
                try e.call(
                    m.frames.write,
                    &.{ frame, try e.field(cursor.head, 0), try e.field(cursor.head, 1) },
                ),
                try e.call(write_bindings, &.{
                    try e.b.reference(changed),
                    cursor.rest,
                }),
            ),
        ),
    );
}

fn emitAssign(
    m: machines.Definition,
    e: Author,
    set: sets.Definition,
    bindings: tables.Definition,
    d: Definition,
    gather: Id,
    clear: Id,
    write_bindings: Id,
) Error!void {
    const program = try e.param(d.assign, 0);
    const frame = try e.param(d.assign, 1);
    const transfer = try e.param(d.assign, 2);
    const target_id = try e.field(transfer, 0);
    const target = try block(e, program, target_id);
    const fn_code = try function(e, program, try field(e, target, ir.Block, "function"));
    const mask = try e.b.variable(set.map.tree);
    const collected = try e.b.variable(bindings.table);
    const materialized = try e.b.variable(bindings.sequence);
    const cleared = try e.b.variable(m.frames.schema);
    const scoped = try e.b.variable(m.frames.schema);
    const written = try e.b.variable(m.frames.schema);
    const pruned = try e.b.variable(m.frames.schema);
    var body = try e.b.bind(pruned, try e.call(m.frames.retain, &.{
        try e.b.reference(written), try e.b.reference(mask),
    }), try e.b.pure(try e.replace(try e.b.reference(pruned), 0, e.zero)));
    body = try e.b.bind(written, try e.call(write_bindings, &.{
        try e.b.reference(scoped), try e.b.reference(materialized),
    }), body);
    body = try e.b.bind(scoped, try e.call(m.frames.scope, &.{
        try e.b.reference(cleared),
        try field(e, fn_code, ir.Function, "custody"),
        try field(e, target, ir.Block, "custody"),
    }), body);
    body = try emitAssignBody(e, clear, program, frame, transfer, fn_code, cleared, body);
    body = try e.b.bind(materialized, try e.call(
        bindings.to_sequence,
        &.{try e.b.reference(collected)},
    ), body);
    body = try e.b.bind(collected, try e.call(gather, &.{
        frame,
        try e.field(transfer, 1),
        try e.b.reference(mask),
        try e.param(d.assign, 3),
        try bindings.empty(e.b),
    }), body);
    try e.b.define(d.assign, try e.b.bind(mask, try e.call(
        set.from_sequence,
        &.{try live(e, program, target_id)},
    ), body));
}

fn emitRetained(
    e: Author,
    set: sets.Definition,
    d: Definition,
    remove_destinations: Id,
    add_sources: Id,
) Error!void {
    const program = try e.param(d.retained, 0);
    const transfer = try e.param(d.retained, 1);
    const mask = try e.b.variable(set.map.tree);
    const stripped = try e.b.variable(set.map.tree);
    try e.b.define(d.retained, try e.b.bind(mask, try e.call(set.from_sequence, &.{try live(
        e,
        program,
        try e.field(transfer, 0),
    )}), try e.b.bind(stripped, try e.call(remove_destinations, &.{
        try e.field(transfer, 1), try e.b.reference(mask), try e.b.reference(mask),
    }), try e.call(add_sources, &.{
        try e.field(transfer, 1), try e.b.reference(mask), try e.b.reference(stripped),
    }))));
}

fn emitTail(e: Author, d: Definition) Error!void {
    const transfer = try e.param(d.tail, 1);
    const target = try block(e, try e.param(d.tail, 0), try e.field(transfer, 0));
    const term = try field(e, target, ir.Block, "terminator");
    const assignment = try e.required(try e.field(transfer, 1), e.zero);
    const no = try e.b.pure(try e.b.constant(bool, false));
    var yes = try e.b.pure(try e.binary(
        .equal,
        try e.field(assignment, 0),
        try e.payload(term, 0),
    ));
    yes = try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{try e.field(assignment, 1)},
        0,
    ), e.one), yes, no);
    yes = try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{try e.field(transfer, 1)},
        0,
    ), e.one), yes, no);
    yes = try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{term},
        0,
    ), e.zero), yes, no);
    try e.b.define(
        d.tail,
        try e.when(
            try e.binary(
                .equal,
                try e.b.primitive(
                    e.integer,
                    .sequence_length,
                    &.{try field(
                        e,
                        target,
                        ir.Block,
                        "instructions",
                    )},
                    0,
                ),
                e.zero,
            ),
            yes,
            no,
        ),
    );
}

fn emitNext(e: Author, d: Definition) Error!void {
    const term_type = try projection.schema(ir.Terminator, e.b);
    const variants = e.b.schemas.items[@intCast(term_type)].sum;
    const Case = @import("std").meta.Elem(@FieldType(
        @FieldType(source.ast.Term, "match_sum"),
        "cases",
    ));
    const info = @typeInfo(ir.Terminator).@"union";
    var cases: [info.field_names.len]Case = undefined;
    inline for (info.field_names, 0..) |name, i| {
        const variable = try e.b.variable(variants[i]);
        const T = @FieldType(ir.Terminator, name);
        cases[i] = .{ .variable = variable, .body = if (@typeInfo(T) == .@"struct" and
            @hasField(T, "next")) try e.b.pure(try field(
            e,
            try e.b.reference(variable),
            T,
            "next",
        )) else try e.fail() };
    }
    try e.b.define(d.next, try e.b.term(.{ .match_sum = .{
        .value = try e.param(d.next, 0),
        .cases = &cases,
    } }));
}

fn emitLoop(m: machines.Definition, e: Author, value: Id, ids: Id, d: Definition) Error!void {
    const output = try tables.define(e.b, value);
    const loop = try e.b.declare(&.{
        m.frames.schema, ids, output.table,
    }, output.table, &.{}, &.{});
    const frame = try e.param(loop, 0);
    const cursor = try Cursor.init(e, try e.param(loop, 1));
    const prior = try e.param(loop, 2);
    const selected = try e.b.variable(value);
    const appended = try e.b.variable(output.table);
    try e.b.define(loop, try cursor.match(e, try e.b.pure(prior), try e.b.bind(selected, try e.call(
        m.frames.read,
        &.{ frame, cursor.head },
    ), try e.b.bind(appended, try e.call(
        output.append,
        &.{ prior, try e.b.reference(selected) },
    ), try e.call(loop, &.{
        frame,
        cursor.rest,
        try e.b.reference(appended),
    })))));
    const collected = try e.b.variable(output.table);
    try e.b.define(d.collect, try e.b.bind(collected, try e.call(loop, &.{
        try e.param(d.collect, 0), try e.param(d.collect, 1), try output.empty(e.b),
    }), try e.call(output.to_sequence, &.{try e.b.reference(collected)})));
}

fn emitWrite(m: machines.Definition, e: Author, d: Definition) Error!void {
    const frame = try e.param(d.write, 0);
    const slots = try Cursor.init(e, try e.param(d.write, 1));
    const args = try Cursor.init(e, try e.param(d.write, 2));
    const changed = try e.b.variable(m.frames.schema);
    try e.b.define(
        d.write,
        try slots.match(
            e,
            try e.b.pure(frame),
            try args.match(
                e,
                try e.fail(),
                try e.b.bind(
                    changed,
                    try e.call(m.frames.write, &.{ frame, slots.head, args.head }),
                    try e.call(d.write, &.{ try e.b.reference(changed), slots.rest, args.rest }),
                ),
            ),
        ),
    );
}

fn defineChoose(e: Author, cursor: anytype, slot: Id, unit: Id, skip: Id, insert: Id) Error!Id {
    return try e.b.term(
        .{
            .match_sum = .{
                .value = try e.field(cursor.head, 1),
                .cases = &.{
                    .{ .variable = slot, .body = insert },
                    .{ .variable = unit, .body = skip },
                },
            },
        },
    );
}

fn emitAssignBody(
    e: Author,
    clear: Id,
    program: Id,
    frame: Id,
    transfer: Id,
    fn_code: anytype,
    cleared: Id,
    body: Id,
) Error!Id {
    return try e.b.bind(
        cleared,
        try e.call(
            clear,
            &.{
                program,                  frame,
                try e.field(transfer, 1),
                try e.field(
                    try field(e, fn_code, ir.Function, "layout"),
                    0,
                ),
            },
        ),
        body,
    );
}

fn emitRetention(
    e: Author,
    set: sets.Definition,
    assignments: Id,
    d: Definition,
) Error!void {
    const b = e.b;
    var remove_destinations: Id = undefined;
    var add_sources: Id = undefined;
    inline for (.{ false, true }) |adding| {
        const loop = try b.declare(&.{
            assignments, set.map.tree, set.map.tree,
        }, set.map.tree, &.{}, &.{});
        if (adding) add_sources = loop else remove_destinations = loop;
        const cursor = try Cursor.init(e, try e.param(loop, 0));
        const live_mask = try e.param(loop, 1);
        const prior = try e.param(loop, 2);
        const changed = try b.variable(set.map.tree);
        const recurse = try e.call(loop, &.{ cursor.rest, live_mask, try b.reference(changed) });
        const destination = try e.field(cursor.head, 0);
        var visit: Id = undefined;
        if (adding) {
            const contains = try b.variable(e.boolean);
            const slot = try b.variable(e.integer);
            const unit = try b.variable(e.unit);
            const skip = try e.call(loop, &.{ cursor.rest, live_mask, prior });
            const insert = try b.bind(changed, try e.call(set.map.set, &.{
                prior, try b.reference(slot), e.unit_value,
            }), recurse);
            const choose = try defineChoose(e, cursor, slot, unit, skip, insert);
            visit = try b.bind(contains, try e.call(
                set.contains,
                &.{ live_mask, destination },
            ), try e.when(
                try b.reference(contains),
                choose,
                skip,
            ));
        } else visit = try b.bind(changed, try e.call(
            set.map.remove,
            &.{ prior, destination },
        ), recurse);
        try b.define(loop, try cursor.match(e, try b.pure(prior), visit));
    }
    try emitRetained(e, set, d, remove_destinations, add_sources);
}
