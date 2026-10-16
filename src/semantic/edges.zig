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

pub const Definition = struct { assign: Id, retained: Id, tail: Id, next: Id, collect: Id, write: Id };

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
    return e.required(try e.required(try field(e, program, projection.Program, "live"), id), e.zero);
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
        return .{ .expression = try b.primitive(optional, .sequence_pop, &.{input}, 0), .nil = try b.variable(e.unit), .pair = pair, .head = try e.field(try b.reference(pair), 0), .rest = try e.field(try b.reference(pair), 1) };
    }
    fn match(c: Cursor, e: Author, empty: Id, present: Id) Error!Id {
        return e.b.term(.{ .match_sum = .{ .value = c.expression, .cases = &.{ .{ .variable = c.nil, .body = empty }, .{ .variable = c.pair, .body = present } } } });
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
        .assign = try b.declare(&.{ m.program, m.frames.schema, edge, maybe_value }, m.frames.schema, &.{}, &.{}),
        .retained = try b.declare(&.{ m.program, edge }, set.map.tree, &.{}, &.{}),
        .tail = try b.declare(&.{ m.program, edge }, e.boolean, &.{}, &.{}),
        .next = try b.declare(&.{try projection.schema(ir.Terminator, b)}, edge, &.{}, &.{}),
        .collect = try b.declare(&.{ m.frames.schema, ids }, values, &.{}, &.{}),
        .write = try b.declare(&.{ m.frames.schema, ids, values }, m.frames.schema, &.{}, &.{}),
    };
    // Gather all live writes from the predecessor before clearing any source.
    const gather = try b.declare(&.{ m.frames.schema, assignments, set.map.tree, maybe_value, bindings.table }, bindings.table, &.{}, &.{});
    {
        const frame = try e.param(gather, 0);
        const cursor = try Cursor.init(e, try e.param(gather, 1));
        const mask = try e.param(gather, 2);
        const returned = try e.param(gather, 3);
        const prior = try e.param(gather, 4);
        const destination = try e.field(cursor.head, 0);
        const source_value = try e.field(cursor.head, 1);
        const contains = try b.variable(e.boolean);
        const selected = try b.variable(value);
        const next = try b.variable(bindings.table);
        const slot = try b.variable(e.integer);
        const unit = try b.variable(e.unit);
        const select = try b.term(.{ .match_sum = .{ .value = source_value, .cases = &.{
            .{ .variable = slot, .body = try e.call(m.frames.read, &.{ frame, try b.reference(slot) }) },
            .{ .variable = unit, .body = try b.pure(try e.payload(returned, 1)) },
        } } });
        const append = try b.bind(selected, select, try b.bind(next, try e.call(bindings.append, &.{ prior, try e.tuple(binding, &.{ destination, try b.reference(selected) }) }), try e.call(gather, &.{ frame, cursor.rest, mask, returned, try b.reference(next) })));
        try b.define(gather, try cursor.match(e, try b.pure(prior), try b.bind(contains, try e.call(set.contains, &.{ mask, destination }), try e.when(try b.reference(contains), append, try e.call(gather, &.{ frame, cursor.rest, mask, returned, prior })))));
    }
    const clear = try b.declare(&.{ m.program, m.frames.schema, assignments, ids }, m.frames.schema, &.{}, &.{});
    {
        const program = try e.param(clear, 0);
        const frame = try e.param(clear, 1);
        const cursor = try Cursor.init(e, try e.param(clear, 2));
        const layout = try e.param(clear, 3);
        const slot_var = try b.variable(e.integer);
        const slot = try b.reference(slot_var);
        const unit = try b.variable(e.unit);
        const changed = try b.variable(m.frames.schema);
        const copy = try field(e, try field(e, program, projection.Program, "uses"), data.traits.Facts, "copy");
        const skip = try e.call(clear, &.{ program, frame, cursor.rest, layout });
        const remove = try b.bind(changed, try e.call(m.frames.clear, &.{ frame, slot }), try e.call(clear, &.{ program, try b.reference(changed), cursor.rest, layout }));
        try b.define(clear, try cursor.match(e, try b.pure(frame), try b.term(.{ .match_sum = .{ .value = try e.field(cursor.head, 1), .cases = &.{
            .{ .variable = slot_var, .body = try e.when(try e.required(copy, try e.required(layout, slot)), skip, remove) },
            .{ .variable = unit, .body = skip },
        } } })));
    }
    const write_bindings = try b.declare(&.{ m.frames.schema, bindings.sequence }, m.frames.schema, &.{}, &.{});
    {
        const frame = try e.param(write_bindings, 0);
        const cursor = try Cursor.init(e, try e.param(write_bindings, 1));
        const changed = try b.variable(m.frames.schema);
        try b.define(write_bindings, try cursor.match(e, try b.pure(frame), try b.bind(changed, try e.call(m.frames.write, &.{ frame, try e.field(cursor.head, 0), try e.field(cursor.head, 1) }), try e.call(write_bindings, &.{ try b.reference(changed), cursor.rest }))));
    }
    {
        const program = try e.param(d.assign, 0);
        const frame = try e.param(d.assign, 1);
        const transfer = try e.param(d.assign, 2);
        const target_id = try e.field(transfer, 0);
        const target = try block(e, program, target_id);
        const fn_code = try function(e, program, try field(e, target, ir.Block, "function"));
        const mask = try b.variable(set.map.tree);
        const collected = try b.variable(bindings.table);
        const materialized = try b.variable(bindings.sequence);
        const cleared = try b.variable(m.frames.schema);
        const scoped = try b.variable(m.frames.schema);
        const written = try b.variable(m.frames.schema);
        const pruned = try b.variable(m.frames.schema);
        var body = try b.bind(pruned, try e.call(m.frames.retain, &.{ try b.reference(written), try b.reference(mask) }), try b.pure(try e.replace(try b.reference(pruned), 0, e.zero)));
        body = try b.bind(written, try e.call(write_bindings, &.{ try b.reference(scoped), try b.reference(materialized) }), body);
        body = try b.bind(scoped, try e.call(m.frames.scope, &.{ try b.reference(cleared), try field(e, fn_code, ir.Function, "custody"), try field(e, target, ir.Block, "custody") }), body);
        body = try b.bind(cleared, try e.call(clear, &.{ program, frame, try e.field(transfer, 1), try e.field(try field(e, fn_code, ir.Function, "layout"), 0) }), body);
        body = try b.bind(materialized, try e.call(bindings.to_sequence, &.{try b.reference(collected)}), body);
        body = try b.bind(collected, try e.call(gather, &.{ frame, try e.field(transfer, 1), try b.reference(mask), try e.param(d.assign, 3), try bindings.empty(b) }), body);
        try b.define(d.assign, try b.bind(mask, try e.call(set.from_sequence, &.{try live(e, program, target_id)}), body));
    }
    // R = (live(target) minus destinations) union live assignment sources.
    var remove_destinations: Id = undefined;
    var add_sources: Id = undefined;
    inline for (.{ false, true }) |adding| {
        const loop = try b.declare(&.{ assignments, set.map.tree, set.map.tree }, set.map.tree, &.{}, &.{});
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
            const insert = try b.bind(changed, try e.call(set.map.set, &.{ prior, try b.reference(slot), e.unit_value }), recurse);
            const choose = try b.term(.{ .match_sum = .{ .value = try e.field(cursor.head, 1), .cases = &.{ .{ .variable = slot, .body = insert }, .{ .variable = unit, .body = skip } } } });
            visit = try b.bind(contains, try e.call(set.contains, &.{ live_mask, destination }), try e.when(try b.reference(contains), choose, skip));
        } else visit = try b.bind(changed, try e.call(set.map.remove, &.{ prior, destination }), recurse);
        try b.define(loop, try cursor.match(e, try b.pure(prior), visit));
    }
    {
        const program = try e.param(d.retained, 0);
        const transfer = try e.param(d.retained, 1);
        const mask = try b.variable(set.map.tree);
        const stripped = try b.variable(set.map.tree);
        try b.define(d.retained, try b.bind(mask, try e.call(set.from_sequence, &.{try live(e, program, try e.field(transfer, 0))}), try b.bind(stripped, try e.call(remove_destinations, &.{ try e.field(transfer, 1), try b.reference(mask), try b.reference(mask) }), try e.call(add_sources, &.{ try e.field(transfer, 1), try b.reference(mask), try b.reference(stripped) }))));
    }
    {
        const transfer = try e.param(d.tail, 1);
        const target = try block(e, try e.param(d.tail, 0), try e.field(transfer, 0));
        const term = try field(e, target, ir.Block, "terminator");
        const assignment = try e.required(try e.field(transfer, 1), e.zero);
        const no = try b.pure(try b.constant(bool, false));
        var yes = try b.pure(try e.binary(.equal, try e.field(assignment, 0), try e.payload(term, 0)));
        yes = try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{try e.field(assignment, 1)}, 0), e.one), yes, no);
        yes = try e.when(try e.binary(.equal, try b.primitive(e.integer, .sequence_length, &.{try e.field(transfer, 1)}, 0), e.one), yes, no);
        yes = try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{term}, 0), e.zero), yes, no);
        try b.define(d.tail, try e.when(try e.binary(.equal, try b.primitive(e.integer, .sequence_length, &.{try field(e, target, ir.Block, "instructions")}, 0), e.zero), yes, no));
    }
    {
        const term_type = try projection.schema(ir.Terminator, b);
        const variants = b.schemas.items[@intCast(term_type)].sum;
        const Case = @import("std").meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
        const info = @typeInfo(ir.Terminator).@"union";
        var cases: [info.field_names.len]Case = undefined;
        inline for (info.field_names, 0..) |name, i| {
            const variable = try b.variable(variants[i]);
            const T = @FieldType(ir.Terminator, name);
            cases[i] = .{ .variable = variable, .body = if (@typeInfo(T) == .@"struct" and @hasField(T, "next")) try b.pure(try field(e, try b.reference(variable), T, "next")) else try e.fail() };
        }
        try b.define(d.next, try b.term(.{ .match_sum = .{ .value = try e.param(d.next, 0), .cases = &cases } }));
    }
    {
        const output = try tables.define(b, value);
        const loop = try b.declare(&.{ m.frames.schema, ids, output.table }, output.table, &.{}, &.{});
        const frame = try e.param(loop, 0);
        const cursor = try Cursor.init(e, try e.param(loop, 1));
        const prior = try e.param(loop, 2);
        const selected = try b.variable(value);
        const appended = try b.variable(output.table);
        try b.define(loop, try cursor.match(e, try b.pure(prior), try b.bind(selected, try e.call(m.frames.read, &.{ frame, cursor.head }), try b.bind(appended, try e.call(output.append, &.{ prior, try b.reference(selected) }), try e.call(loop, &.{ frame, cursor.rest, try b.reference(appended) })))));
        const collected = try b.variable(output.table);
        try b.define(d.collect, try b.bind(collected, try e.call(loop, &.{ try e.param(d.collect, 0), try e.param(d.collect, 1), try output.empty(b) }), try e.call(output.to_sequence, &.{try b.reference(collected)})));
    }
    {
        const frame = try e.param(d.write, 0);
        const slots = try Cursor.init(e, try e.param(d.write, 1));
        const args = try Cursor.init(e, try e.param(d.write, 2));
        const changed = try b.variable(m.frames.schema);
        try b.define(d.write, try slots.match(e, try b.pure(frame), try args.match(e, try e.fail(), try b.bind(changed, try e.call(m.frames.write, &.{ frame, slots.head, args.head }), try e.call(d.write, &.{ try b.reference(changed), slots.rest, args.rest })))));
    }
    return cache.finish(b, d);
}
