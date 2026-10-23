const data = @import("horos_data");
const source = @import("horos").source;
const maps = @import("map.zig");
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;

pub const Kind = enum(u64) { field, payload, element };
pub const Definition = struct { entries: maps.Definition, entry: Id, schema: Id, range: Id };
pub const Range = struct { schema: u64, start: u64, end: u64 };
pub const Predecessor = struct { index: u64, range: Range };
const Functions = struct { lookup: Id, remember: Id, optional: Id, result: Id };

pub fn define(b: *source.Builder) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.projection-cache/1", 0);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const range = try projection.schema(Range, b);
    const entry = try b.schema(.{ .product = &.{
        e.integer, e.integer, e.integer, e.integer, range,
    } });
    const entries = try maps.define(b, entry);
    return cache.finish(b, .{
        .entries = entries,
        .entry = entry,
        .schema = entries.tree,
        .range = range,
    });
}

pub fn read(
    e: Author,
    m: machines.Definition,
    input: Id,
    value: Id,
    index: Id,
    kind: Kind,
    miss: Id,
) Error!Id {
    const d = try functions(e, m);
    const found = try e.b.variable(d.optional);
    const computed = try e.b.variable(m.cache.range);
    const updated = try e.b.variable(m.schema);
    const absent = try e.b.variable(e.unit);
    const present = try e.b.variable(m.cache.range);
    const range = try e.b.reference(computed);
    const operation = try e.b.constant(u64, @backingInt(kind));
    const remember = try e.b.bind(computed, miss, try e.b.bind(updated, try e.call(
        d.remember,
        &.{ input, value, index, operation, range },
    ), try materialize(e, m, try e.b.reference(updated), value, range)));
    return e.b.bind(found, try e.call(d.lookup, &.{ input, value, index, operation }), try e.b.term(
        .{ .match_sum = .{ .value = try e.b.reference(found), .cases = &.{
            .{ .variable = absent, .body = remember },
            .{ .variable = present, .body = try materialize(
                e,
                m,
                input,
                value,
                try e.b.reference(present),
            ) },
        } } },
    ));
}

fn materialize(e: Author, m: machines.Definition, input: Id, value: Id, range: Id) Error!Id {
    const v = try @import("values.zig").define(e.b, m);
    const encoded = try e.b.variable(try e.b.schema(.bytes));
    const literal = try e.tuple(try projection.schema(data.program.Literal, e.b), &.{
        try e.field(range, 0),
        try e.slice(try e.b.reference(encoded), try e.field(range, 1), try e.field(range, 2)),
    });
    return e.b.bind(encoded, try e.call(v.bytes, &.{ input, value }), try e.call(
        v.literal,
        &.{ input, literal },
    ));
}

pub fn lookup(e: Author, m: machines.Definition, input: Id, value: Id, index: Id) Error!Id {
    const d = try functions(e, m);
    return e.call(d.lookup, &.{
        input, value, index, try e.b.constant(u64, @backingInt(Kind.element)),
    });
}

pub fn predecessor(e: Author, m: machines.Definition, input: Id, value: Id, index: Id) Error!Id {
    const b = e.b;
    const cache = try b.specialization(
        Id,
        "kosmos.semantic.projection-cache-predecessor/1",
        m.schema,
    );
    if (cache.cached) |saved| return e.call(saved, &.{ input, value, index });
    const point = try projection.schema(Predecessor, b);
    const optional = try b.schema(.{ .sum = &.{ e.unit, point } });
    const graph_value = try projection.schema(data.graph.Value, b);
    const entry = try b.declare(&.{ m.schema, graph_value, e.integer }, optional, &.{}, &.{});
    const search = try b.declare(&.{
        m.cache.schema, e.integer, e.integer, e.integer, optional,
    }, optional, &.{}, &.{});
    try emitPredecessor(e, m, point, optional, search);
    const machine = try e.param(entry, 0);
    const source_value = try e.param(entry, 1);
    const absent = try e.variant(optional, 0, e.unit_value);
    const found = try e.call(search, &.{
        try m.field(e, machine, .cache), try blob(e, source_value),
        try e.field(source_value, 0),    try e.param(entry, 2),
        absent,
    });
    try b.define(entry, try eligible(e, m, machine, source_value, found, try b.pure(absent)));
    return e.call(try cache.finish(b, entry), &.{ input, value, index });
}

fn emitPredecessor(
    e: Author,
    m: machines.Definition,
    point: Id,
    optional: Id,
    search: Id,
) Error!void {
    const b = e.b;
    const tree = try e.param(search, 0);
    const source_blob = try e.param(search, 1);
    const schema = try e.param(search, 2);
    const target = try e.param(search, 3);
    const best = try e.param(search, 4);
    const nil = try b.variable(e.unit);
    const leaf = try b.variable(m.cache.entries.entry);
    const fork = try b.variable(m.cache.entries.branch);
    const entry = try e.field(try b.reference(leaf), 1);
    const index = try e.field(entry, 2);
    const keep = try b.pure(best);
    const candidate = try b.pure(try e.variant(optional, 1, try e.tuple(point, &.{
        index, try e.field(entry, 4),
    })));
    const absent = try b.variable(e.unit);
    const present = try b.variable(point);
    var choose = try b.term(.{ .match_sum = .{ .value = best, .cases = &.{
        .{ .variable = absent, .body = candidate },
        .{ .variable = present, .body = try e.when(
            try e.binary(.less, try e.field(try b.reference(present), 0), index),
            candidate,
            keep,
        ) },
    } } });
    choose = try e.when(try e.binary(.less, index, target), choose, keep);
    const keys = [_]Id{ source_blob, schema, try b.constant(u64, @backingInt(Kind.element)) };
    const fields = [_]usize{ 0, 1, 3 };
    for (keys, fields) |key, field_index| choose = try e.when(
        try e.binary(.equal, try e.field(entry, field_index), key),
        choose,
        keep,
    );
    const node = try b.reference(fork);
    const left = try b.variable(optional);
    const branch = try b.bind(left, try e.call(search, &.{
        try e.field(node, 1), source_blob, schema, target, best,
    }), try e.call(search, &.{
        try e.field(node, 2), source_blob, schema, target, try b.reference(left),
    }));
    try b.define(search, try b.term(.{ .match_sum = .{ .value = tree, .cases = &.{
        .{ .variable = nil, .body = keep },
        .{ .variable = leaf, .body = choose },
        .{ .variable = fork, .body = branch },
    } } }));
}

fn functions(e: Author, m: machines.Definition) Error!Functions {
    const b = e.b;
    const cache = try b.specialization(
        Functions,
        "kosmos.semantic.projection-cache-ops/1",
        m.schema,
    );
    if (cache.cached) |saved| return saved;
    const value = try projection.schema(data.graph.Value, b);
    const optional = try b.schema(.{ .sum = &.{ e.unit, m.cache.range } });
    const d: Functions = .{
        .lookup = try b.declare(&.{ m.schema, value, e.integer, e.integer }, optional, &.{}, &.{}),
        .remember = try b.declare(&.{
            m.schema, value, e.integer, e.integer, m.cache.range,
        }, m.schema, &.{}, &.{}),
        .optional = optional,
        .result = try b.schema(.{ .product = &.{ m.schema, value } }),
    };
    try emitLookup(e, m, d);
    try emitRemember(e, m, d);
    return cache.finish(b, d);
}

fn blob(e: Author, value: Id) Error!Id {
    return e.field(try e.payload(try e.field(value, 1), @backingInt(data.graph.ValueTag.blob)), 0);
}

fn slot(e: Author, value: Id, index: Id, kind: Id) Error!Id {
    return slotId(e, try blob(e, value), index, kind);
}

fn slotId(e: Author, source_blob: Id, index: Id, kind: Id) Error!Id {
    return e.binary(.integer_bit_and, try e.binary(
        .integer_bit_xor,
        source_blob,
        try e.binary(.integer_bit_xor, index, kind),
    ), try e.b.constant(u64, 255));
}

fn eligible(e: Author, m: machines.Definition, input: Id, value: Id, yes: Id, no: Id) Error!Id {
    const found = try e.b.variable(m.blobs.optional);
    const bytes = try e.field(try e.payload(try e.b.reference(found), 1), 1);
    const length = try e.b.primitive(e.integer, .blob_length, &.{bytes}, 0);
    const inspect = try e.b.bind(found, try e.call(m.blobs.get, &.{
        try m.field(e, input, .blobs), try blob(e, value),
    }), try e.when(try e.binary(.less, length, try e.b.constant(u64, 4096)), no, yes));
    return e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{try e.field(value, 1)},
        0,
    ), try e.b.constant(u64, @backingInt(data.graph.ValueTag.blob))), inspect, no);
}

fn emitLookup(e: Author, m: machines.Definition, d: Functions) Error!void {
    const input = try e.param(d.lookup, 0);
    const value = try e.param(d.lookup, 1);
    const index = try e.param(d.lookup, 2);
    const kind = try e.param(d.lookup, 3);
    const found = try e.b.variable(m.cache.entries.optional);
    const absent = try e.b.variable(e.unit);
    const present = try e.b.variable(m.cache.entry);
    const entry = try e.b.reference(present);
    const no = try e.b.pure(try e.variant(d.optional, 0, e.unit_value));
    var yes = try e.b.pure(try e.variant(d.optional, 1, try e.field(entry, 4)));
    const keys = [_]Id{ try blob(e, value), try e.field(value, 0), index, kind };
    for (keys, 0..) |key, i| yes = try e.when(
        try e.binary(.equal, try e.field(entry, i), key),
        yes,
        no,
    );
    const find = try e.b.bind(found, try e.call(m.cache.entries.get, &.{
        try m.field(e, input, .cache), try slot(e, value, index, kind),
    }), try e.b.term(.{ .match_sum = .{ .value = try e.b.reference(found), .cases = &.{
        .{ .variable = absent, .body = no }, .{ .variable = present, .body = yes },
    } } }));
    try e.b.define(d.lookup, try eligible(e, m, input, value, find, no));
}

fn emitRemember(e: Author, m: machines.Definition, d: Functions) Error!void {
    const input = try e.param(d.remember, 0);
    const value = try e.param(d.remember, 1);
    const index = try e.param(d.remember, 2);
    const kind = try e.param(d.remember, 3);
    const entry = try e.tuple(m.cache.entry, &.{
        try blob(e, value), try e.field(value, 0), index, kind, try e.param(d.remember, 4),
    });
    const updated = try e.b.variable(m.cache.schema);
    const remember = try e.b.bind(updated, try e.call(m.cache.entries.set, &.{
        try m.field(e, input, .cache), try slot(e, value, index, kind), entry,
    }), try e.b.pure(try e.replace(
        input,
        @backingInt(machines.Field.cache),
        try e.b.reference(updated),
    )));
    try e.b.define(d.remember, try eligible(e, m, input, value, remember, try e.b.pure(input)));
}

pub fn rebase(e: Author, m: machines.Definition, mapping: maps.Definition) Error!Id {
    const b = e.b;
    const cache = try b.specialization(Id, "kosmos.semantic.projection-cache-rebase/1", m.schema);
    if (cache.cached) |saved| return saved;
    const entry = try b.declare(&.{ m.cache.schema, mapping.tree }, m.cache.schema, &.{}, &.{});
    const loop = try b.declare(&.{
        m.cache.entries.entries, mapping.tree, m.cache.schema, e.integer,
    }, m.cache.schema, &.{}, &.{});
    try emitRebase(e, m, mapping, loop);
    const entries = try b.variable(m.cache.entries.entries);
    try b.define(entry, try b.bind(entries, try e.call(m.cache.entries.to_sequence, &.{
        try e.param(entry, 0),
    }), try e.call(loop, &.{
        try b.reference(entries), try e.param(entry, 1), try m.cache.entries.empty(e), e.zero,
    })));
    return cache.finish(b, entry);
}

fn emitRebase(e: Author, m: machines.Definition, mapping: maps.Definition, loop: Id) Error!void {
    const b = e.b;
    const entries = try e.param(loop, 0);
    const rebindings = try e.param(loop, 1);
    const output = try e.param(loop, 2);
    const index = try e.param(loop, 3);
    const next = try e.binary(.integer_add, index, e.one);
    const selected = try e.field(try e.required(entries, index), 1);
    const found = try b.variable(mapping.optional);
    const absent = try b.variable(e.unit);
    const present = try b.variable(b.schemas.items[@intCast(mapping.optional)].sum[1]);
    const source_blob = try e.field(try b.reference(present), 0);
    const updated = try b.variable(m.cache.schema);
    const retained = try e.replace(selected, 0, source_blob);
    const continue_loop = try e.call(loop, &.{ entries, rebindings, output, next });
    const keep = try b.bind(updated, try e.call(m.cache.entries.set, &.{
        output,
        try slotId(e, source_blob, try e.field(selected, 2), try e.field(selected, 3)),
        retained,
    }), try e.call(loop, &.{ entries, rebindings, try b.reference(updated), next }));
    const visit = try b.bind(found, try e.call(mapping.get, &.{
        rebindings, try e.field(selected, 0),
    }), try b.term(.{ .match_sum = .{ .value = try b.reference(found), .cases = &.{
        .{ .variable = absent, .body = continue_loop }, .{ .variable = present, .body = keep },
    } } }));
    try b.define(loop, try e.when(try e.binary(.less, index, try b.primitive(
        e.integer,
        .sequence_length,
        &.{entries},
        0,
    )), visit, try b.pure(output)));
}

pub fn valid(b: *source.Builder, m: machines.Definition) Error!Id {
    const cache = try b.specialization(Id, "kosmos.semantic.projection-cache-valid/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const entry = try b.declare(&.{m.schema}, e.boolean, &.{}, &.{});
    const walk = try validationWalk(e, m);
    const order = try validationOrder(e, m);
    const machine = try e.param(entry, 0);
    const tree = try m.field(e, machine, .cache);
    const structural = try b.variable(e.boolean);
    const listed = try b.variable(m.cache.entries.entries);
    const ordered = try b.variable(m.cache.entries.entries);
    const no = try b.pure(try b.constant(bool, false));
    const shadow = try e.replace(
        machine,
        @backingInt(machines.Field.cache),
        try m.cache.entries.empty(e),
    );
    const count = try b.primitive(e.integer, .sequence_length, &.{try b.reference(listed)}, 0);
    const checked = try b.bind(
        ordered,
        try e.call(order, &.{try b.reference(listed)}),
        try e.call(walk, &.{ shadow, try b.reference(ordered), e.zero }),
    );
    const bounded = try e.when(try e.binary(.less, try b.constant(u64, 256), count), no, checked);
    const inspect = try b.bind(listed, try e.call(m.cache.entries.to_sequence, &.{tree}), bounded);
    try b.define(entry, try b.bind(
        structural,
        try e.call(m.cache.entries.valid, &.{tree}),
        try e.when(try b.reference(structural), inspect, no),
    ));
    return cache.finish(b, entry);
}

fn validationWalk(e: Author, m: machines.Definition) Error!Id {
    const b = e.b;
    const walk = try b.declare(&.{
        m.schema, m.cache.entries.entries, e.integer,
    }, e.boolean, &.{}, &.{});
    const check = try validationEntry(e, m);
    const input = try e.param(walk, 0);
    const entries = try e.param(walk, 1);
    const index = try e.param(walk, 2);
    const pair = try e.required(entries, index);
    const accepted = try b.variable(e.boolean);
    const retained = try b.variable(m.cache.schema);
    const no = try b.pure(try b.constant(bool, false));
    const next = try b.bind(retained, try e.call(m.cache.entries.set, &.{
        try m.field(e, input, .cache), try e.field(pair, 0), try e.field(pair, 1),
    }), try e.call(walk, &.{
        try e.replace(input, @backingInt(machines.Field.cache), try b.reference(retained)),
        entries,
        try e.binary(.integer_add, index, e.one),
    }));
    const visit = try b.bind(
        accepted,
        try e.call(check, &.{ input, pair }),
        try e.when(try b.reference(accepted), next, no),
    );
    try b.define(walk, try e.when(try e.binary(.less, index, try b.primitive(
        e.integer,
        .sequence_length,
        &.{entries},
        0,
    )), visit, try b.pure(try b.constant(bool, true))));
    return walk;
}

fn validationOrder(e: Author, m: machines.Definition) Error!Id {
    const b = e.b;
    const buckets = try maps.define(b, m.cache.entries.entries);
    const collect = try validationBuckets(e, m, buckets);
    const flatten = try validationFlatten(e, m, buckets);
    const entry = try b.declare(&.{m.cache.entries.entries}, m.cache.entries.entries, &.{}, &.{});
    const grouped = try b.variable(buckets.tree);
    const listed = try b.variable(buckets.entries);
    const flattened = try e.call(flatten, &.{
        try b.reference(listed),
        e.zero,
        try b.primitive(m.cache.entries.entries, .sequence, &.{}, 0),
    });
    const ordered = try b.bind(
        listed,
        try e.call(buckets.to_sequence, &.{try b.reference(grouped)}),
        flattened,
    );
    try b.define(entry, try b.bind(grouped, try e.call(collect, &.{
        try e.param(entry, 0), e.zero, try buckets.empty(e),
    }), ordered));
    return entry;
}

fn validationBuckets(e: Author, m: machines.Definition, buckets: maps.Definition) Error!Id {
    const b = e.b;
    const loop = try b.declare(&.{
        m.cache.entries.entries, e.integer, buckets.tree,
    }, buckets.tree, &.{}, &.{});
    const entries = try e.param(loop, 0);
    const index = try e.param(loop, 1);
    const output = try e.param(loop, 2);
    const pair = try e.required(entries, index);
    const coordinate = try e.field(try e.field(pair, 1), 2);
    const found = try b.variable(buckets.optional);
    const absent = try b.variable(e.unit);
    const present = try b.variable(m.cache.entries.entries);
    const bucket = try b.variable(m.cache.entries.entries);
    const updated = try b.variable(buckets.tree);
    const selected = try b.term(.{ .match_sum = .{ .value = try b.reference(found), .cases = &.{
        .{ .variable = absent, .body = try b.pure(try b.primitive(
            m.cache.entries.entries,
            .sequence,
            &.{pair},
            0,
        )) },
        .{ .variable = present, .body = try b.pure(try b.primitive(
            m.cache.entries.entries,
            .sequence_append,
            &.{ try b.reference(present), pair },
            0,
        )) },
    } } });
    const next = try b.bind(updated, try e.call(buckets.set, &.{
        output, coordinate, try b.reference(bucket),
    }), try e.call(loop, &.{
        entries, try e.binary(.integer_add, index, e.one), try b.reference(updated),
    }));
    const visit = try b.bind(
        found,
        try e.call(buckets.get, &.{ output, coordinate }),
        try b.bind(bucket, selected, next),
    );
    try b.define(loop, try e.when(try e.binary(.less, index, try b.primitive(
        e.integer,
        .sequence_length,
        &.{entries},
        0,
    )), visit, try b.pure(output)));
    return loop;
}

fn validationFlatten(e: Author, m: machines.Definition, buckets: maps.Definition) Error!Id {
    const b = e.b;
    const loop = try b.declare(&.{
        buckets.entries, e.integer, m.cache.entries.entries,
    }, m.cache.entries.entries, &.{}, &.{});
    const entries = try e.param(loop, 0);
    const index = try e.param(loop, 1);
    const output = try e.param(loop, 2);
    const next = try e.call(loop, &.{
        entries, try e.binary(.integer_add, index, e.one),
        try b.primitive(m.cache.entries.entries, .sequence_concat, &.{
            output, try e.field(try e.required(entries, index), 1),
        }, 0),
    });
    try b.define(loop, try e.when(try e.binary(.less, index, try b.primitive(
        e.integer,
        .sequence_length,
        &.{entries},
        0,
    )), next, try b.pure(output)));
    return loop;
}

fn validationEntry(e: Author, m: machines.Definition) Error!Id {
    const b = e.b;
    const entry = try b.declare(&.{ m.schema, m.cache.entries.entry }, e.boolean, &.{}, &.{});
    const machine = try e.param(entry, 0);
    const pair = try e.param(entry, 1);
    const saved = try e.field(pair, 1);
    const source_blob = try e.field(saved, 0);
    const schema = try e.field(saved, 1);
    const index = try e.field(saved, 2);
    const kind = try e.field(saved, 3);
    const actual = try e.field(saved, 4);
    const found = try b.variable(m.blobs.optional);
    const absent = try b.variable(e.unit);
    const present = try b.variable(m.blobs.element);
    const backing = try b.reference(present);
    const bytes = try e.field(backing, 1);
    const length = try b.primitive(e.integer, .blob_length, &.{bytes}, 0);
    const expected = try b.variable(m.cache.range);
    const no = try b.pure(try b.constant(bool, false));
    var same = try b.pure(try b.constant(bool, true));
    for (0..3) |i| same = try e.when(try e.binary(
        .equal,
        try e.field(actual, i),
        try e.field(try b.reference(expected), i),
    ), same, no);
    const body = try e.variant(
        try projection.schema(@FieldType(data.graph.Value, "body"), b),
        @backingInt(data.graph.ValueTag.blob),
        try e.tuple(try projection.schema(data.graph.BlobRef, b), &.{source_blob}),
    );
    const value = try e.tuple(try projection.schema(data.graph.Value, b), &.{
        schema, body,
    });
    var checked = try b.bind(
        expected,
        try validationRange(e, m, machine, value, index, kind),
        same,
    );
    checked = try e.when(try e.binary(.less, length, try e.field(actual, 2)), no, checked);
    checked = try e.when(try e.binary(.less, length, try b.constant(u64, 4096)), no, checked);
    checked = try e.when(try e.binary(.equal, try e.field(backing, 0), schema), checked, no);
    const inspect = try b.bind(found, try e.call(m.blobs.get, &.{
        try m.field(e, machine, .blobs), source_blob,
    }), try b.term(.{ .match_sum = .{ .value = try b.reference(found), .cases = &.{
        .{ .variable = absent, .body = no }, .{ .variable = present, .body = checked },
    } } }));
    try b.define(entry, try e.when(try e.binary(
        .equal,
        try e.field(pair, 0),
        try slotId(e, source_blob, index, kind),
    ), inspect, no));
    return entry;
}

fn validationRange(
    e: Author,
    m: machines.Definition,
    input: Id,
    value: Id,
    index: Id,
    kind: Id,
) Error!Id {
    const aggregate = @import("aggregate.zig");
    var select = try e.fail();
    select = try e.when(try e.binary(.equal, kind, try e.b.constant(
        u64,
        @backingInt(Kind.element),
    )), try collectionRange(e, m, input, value, index), select);
    const payload = try e.when(
        try e.binary(.equal, index, e.zero),
        try aggregate.encodedRange(e, m, input, value, index, true),
        try e.fail(),
    );
    select = try e.when(try e.binary(.equal, kind, try e.b.constant(
        u64,
        @backingInt(Kind.payload),
    )), payload, select);
    return e.when(try e.binary(.equal, kind, try e.b.constant(
        u64,
        @backingInt(Kind.field),
    )), try aggregate.encodedRange(e, m, input, value, index, false), select);
}

fn collectionRange(e: Author, m: machines.Definition, input: Id, value: Id, index: Id) Error!Id {
    const b = e.b;
    const collection = try @import("collections.zig").define(b, m);
    const whole = try b.variable(collection.schema);
    const view = try b.reference(whole);
    const selected_range = try @import("collections.zig").encodedRange(
        m,
        e,
        try @import("codec.zig").define(b, m),
        input,
        value,
        view,
        index,
        try e.payload(try e.field(view, 2), 0),
    );
    return b.bind(whole, try e.call(collection.view, &.{ input, value }), try e.when(
        try e.binary(.less, index, try e.field(try b.reference(whole), 1)),
        selected_range,
        try e.fail(),
    ));
}
