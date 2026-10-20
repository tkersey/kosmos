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
