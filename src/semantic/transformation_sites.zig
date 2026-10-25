const source = @import("horos").source;
const projection = @import("projection.zig");
const Author = @import("author.zig").Author;
const index = @import("source_references.zig");
const Id = source.Id;
pub const Sites = struct { values: []const Id, terms: []const Id };
const Kind = source.relation.Relocation.Kind;
const Definition = struct { entry: Id, roots: Id, users: Id };

pub fn define(b: *source.Builder) !Id {
    const e = try Author.init(b);
    const refs = try projection.schema([]const index.Reference, b);
    const tables = try projection.schema([]const []const []const index.Reference, b);
    const sites = try projection.schema(Sites, b);
    const d: Definition = .{
        .entry = try b.declare(&.{ tables, e.integer }, sites, &.{}, &.{}),
        .roots = try b.declare(&.{ tables, refs, e.integer, sites }, sites, &.{}, &.{}),
        .users = try b.declare(&.{ refs, e.integer, sites }, sites, &.{}, &.{}),
    };
    try defineUsers(e, d);
    try defineRoots(e, d);
    const users = try e.param(d.entry, 0);
    const selected = try e.param(d.entry, 1);
    const schemas = try e.b.constant(u64, @backingInt(Kind.schema));
    const roots = try e.required(try e.required(users, schemas), selected);
    try b.define(d.entry, try e.call(d.roots, &.{
        users, roots, e.zero, try e.literal(Sites, .{ .values = &.{}, .terms = &.{} }),
    }));
    return d.entry;
}

fn next(e: Author, cursor: Id) !Id {
    return e.binary(.integer_add, cursor, e.one);
}

fn kindIs(e: Author, ref: Id, kind: Kind) !Id {
    const tag = try e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{try e.field(ref, 0)}, 0);
    return e.binary(.equal, tag, try e.b.constant(u32, @backingInt(kind)));
}

fn append(e: Author, ids: Id, wanted: Id) !Id {
    return e.b.pure(try e.b.primitive(
        e.b.values.items[@intCast(ids)].schema,
        .sequence_append,
        &.{ ids, wanted },
        0,
    ));
}

fn defineUsers(e: Author, d: Definition) !void {
    const refs = try e.param(d.users, 0);
    const cursor = try e.param(d.users, 1);
    const sites = try e.param(d.users, 2);
    const ref = try e.required(refs, cursor);
    const id = try e.field(ref, 1);
    const updated = try e.b.variable(try projection.schema([]const Id, e.b));
    const unchanged = try e.call(d.users, &.{ refs, try next(e, cursor), sites });
    var cases: [2]Id = undefined;
    for (&cases, 0..) |*body, position| {
        const fields = [2]Id{
            if (position == 0) try e.b.reference(updated) else try e.field(sites, 0),
            if (position == 1) try e.b.reference(updated) else try e.field(sites, 1),
        };
        const changed = try e.tuple(try projection.schema(Sites, e.b), &fields);
        const added = try append(e, try e.field(sites, position), id);
        body.* = try e.b.bind(updated, added, try e.call(d.users, &.{
            refs, try next(e, cursor), changed,
        }));
    }
    const selected = try e.when(
        try kindIs(e, ref, .value),
        cases[0],
        try e.when(try kindIs(e, ref, .term), cases[1], unchanged),
    );
    const len = try e.b.primitive(e.integer, .sequence_length, &.{refs}, 0);
    const finished = try e.b.pure(sites);
    try e.b.define(d.users, try e.when(try e.binary(.less, cursor, len), selected, finished));
}

fn defineRoots(e: Author, d: Definition) !void {
    const tables = try e.param(d.roots, 0);
    const roots = try e.param(d.roots, 1);
    const cursor = try e.param(d.roots, 2);
    const sites = try e.param(d.roots, 3);
    const ref = try e.required(roots, cursor);
    const id = try e.field(ref, 1);
    const values = try e.b.constant(u64, @backingInt(Kind.value));
    const refs = try e.required(try e.required(tables, values), id);
    const added = try e.b.variable(try projection.schema([]const Id, e.b));
    const updated = try e.b.variable(try projection.schema(Sites, e.b));
    const initial = try e.tuple(try projection.schema(Sites, e.b), &.{
        try e.b.reference(added), try e.field(sites, 1),
    });
    const recurse = try e.call(d.roots, &.{
        tables, roots, try next(e, cursor), try e.b.reference(updated),
    });
    const insert = try append(e, try e.field(sites, 0), id);
    const collect = try e.b.bind(added, insert, try e.b.bind(
        updated,
        try e.call(d.users, &.{ refs, e.zero, initial }),
        recurse,
    ));
    const unchanged = try e.call(d.roots, &.{ tables, roots, try next(e, cursor), sites });
    const len = try e.b.primitive(e.integer, .sequence_length, &.{roots}, 0);
    try e.b.define(d.roots, try e.when(
        try e.binary(.less, cursor, len),
        try e.when(try kindIs(e, ref, .value), collect, unchanged),
        try e.b.pure(sites),
    ));
}
