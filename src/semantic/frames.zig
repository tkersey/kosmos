//! Guest activation operations over ordinary persistent slot maps. Wire slot
//! order and lexical owner order are recovered only when projecting the frame.
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const maps = @import("map.zig");
const table = @import("table.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
pub const Field = enum(usize) { position, scope, bindings, owners };
pub const Scalar = struct { schema: Id, bits: u64 };
pub const Slot = union(enum) { value: data.graph.Value, scalar: Scalar };

pub const Definition = struct {
    schema: Id,
    public: Id,
    slot: Id,
    slots: maps.Definition,
    read_raw: Id,
    write_raw: Id,
    valid: Id,
    from_public: Id,
    to_public: Id,
    read: Id,
    write: Id,
    clear: Id,
    scope: Id,
    prune: Id,
    retain: Id,
    discards: Id,
};

pub fn define(b: *source.Builder) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.frames/1", 0);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const value = try projection.schema(data.graph.Value, b);
    const slot_type = try projection.schema(Slot, b);
    const slots = try maps.define(b, slot_type);
    const scalar = try projection.schema(Scalar, b);
    const public = try projection.schema(data.process_state.Activation, b);
    const owners = try projection.schema([]const data.process_state.Owner, b);
    const schema = try b.schema(.{ .product = &.{ e.integer, e.integer, slots.tree, owners } });
    const scopes = try projection.schema([]const data.activation.CustodyScope, b);
    const live = try projection.schema([]const Id, b);
    const keys = try @import("sets.zig").define(b);
    const d: Definition = try defineD(
        e,
        value,
        slot_type,
        slots,
        scalar,
        public,
        schema,
        scopes,
        live,
        keys,
    );
    const scalar_ops = try @import("scalar.zig").define(b);
    const materialize = try emitScalars(e, d, scalar_ops);
    try emitProjection(e, d, materialize);
    const without = try ownerWalk(e, slots, .remove);
    const rescope = try ownerWalk(e, slots, .scope);
    const retained = try ownerWalk(e, slots, .prune);
    const establish = try emitEstablish(e);
    try emitSlotUpdates(e, d, slot_type, slots, owners, without, establish);
    try emitCommon(e, owners, scopes, d, rescope);
    try emitPrune(e, d, retained);
    try emitLoop(e, value, owners, schema, d);
    return cache.finish(b, d);
}

const Walk = enum { remove, scope, prune };

fn ownerWalk(e: Author, slots: maps.Definition, comptime kind: Walk) Error!Id {
    const b = e.b;
    const owner = try projection.schema(data.process_state.Owner, b);
    const owners = try projection.schema([]const data.process_state.Owner, b);
    const output = try table.define(b, owner);
    const argument_type = if (kind == .prune) slots.tree else e.integer;
    const entry = try b.declare(&.{ owners, argument_type }, owners, &.{}, &.{});
    const loop = try b.declare(&.{ owners, argument_type, output.table }, output.table, &.{}, &.{});
    const parts = try b.schema(.{ .product = &.{ owner, owners } });
    const popped = try b.schema(.{ .sum = &.{ e.unit, parts } });
    const nil = try b.variable(e.unit);
    const pair_var = try b.variable(parts);
    const pair = try b.reference(pair_var);
    const head = try e.field(pair, 0);
    const tail = try e.field(pair, 1);
    const argument = try e.param(loop, 1);
    const prior = try e.param(loop, 2);
    const next = try b.variable(output.table);
    const skip = try e.call(loop, &.{ tail, argument, prior });
    const append = try b.bind(
        next,
        try e.call(output.append, &.{
            prior,
            head,
        }),
        try e.call(loop, &.{
            tail,
            argument,
            try b.reference(next),
        }),
    );
    const visit = switch (kind) {
        .remove => try e.when(try e.binary(.equal, try e.field(head, 1), argument), skip, append),
        .scope => blk: {
            const rewritten = try e.replace(head, 0, argument);
            const change = try b.bind(next, try e.call(
                output.append,
                &.{ prior, rewritten },
            ), try e.call(loop, &.{ tail, argument, try b.reference(next) }));
            break :blk try e.when(try e.binary(
                .less,
                argument,
                try e.field(head, 0),
            ), change, append);
        },
        .prune => blk: {
            const found = try b.variable(slots.optional);
            const tag = try b.primitive(e.integer, .variant_tag, &.{try b.reference(found)}, 0);
            break :blk try b.bind(found, try e.call(
                slots.get,
                &.{ argument, try e.field(head, 1) },
            ), try e.when(try e.binary(.equal, tag, e.zero), skip, append));
        },
    };
    try b.define(loop, try b.term(.{ .match_sum = .{
        .value = try b.primitive(popped, .sequence_pop, &.{try e.param(loop, 0)}, 0),
        .cases = &.{ .{ .variable = nil, .body = try b.pure(prior) }, .{
            .variable = pair_var,
            .body = visit,
        } },
    } }));
    const collected = try b.variable(output.table);
    try b.define(entry, try b.bind(collected, try e.call(loop, &.{
        try e.param(entry, 0), try e.param(entry, 1), try output.empty(b),
    }), try e.call(output.to_sequence, &.{try b.reference(collected)})));
    return entry;
}

fn emitEstablish(e: Author) Error!Id {
    const b = e.b;
    const owner = try projection.schema(data.process_state.Owner, b);
    const owners = try projection.schema([]const data.process_state.Owner, b);
    const output = try table.define(b, owner);
    const entry = try b.declare(&.{ owners, e.integer, e.integer }, owners, &.{}, &.{});
    const loop = try b.declare(&.{
        owners, owner, e.boolean, output.table,
    }, output.table, &.{}, &.{});
    const parts = try b.schema(.{ .product = &.{ owner, owners } });
    const popped = try b.schema(.{ .sum = &.{ e.unit, parts } });
    const nil = try b.variable(e.unit);
    const pair_var = try b.variable(parts);
    const pair = try b.reference(pair_var);
    const head = try e.field(pair, 0);
    const tail = try e.field(pair, 1);
    const new = try e.param(loop, 1);
    const pending = try e.param(loop, 2);
    const prior = try e.param(loop, 3);
    const next = try b.variable(output.table);
    const inserted = try b.variable(output.table);
    const append_head = try b.bind(
        next,
        try e.call(output.append, &.{
            prior,
            head,
        }),
        try e.call(loop, &.{
            tail,
            new,
            pending,
            try b.reference(next),
        }),
    );
    const insert_first = try emitEstablishInsertFirst(
        e,

        output,
        loop,
        head,
        tail,
        new,
        prior,
        next,
        inserted,
    );
    try emitEstablishLoopDefinition(
        e,

        output,
        loop,
        popped,
        nil,
        pair_var,
        head,
        new,
        pending,
        prior,
        append_head,
        insert_first,
    );
    const collected = try b.variable(output.table);
    try emitEstablishEntryDefinition(e, owner, output, entry, loop, collected);
    return entry;
}

fn emitPrune(e: Author, d: Definition, retained_owners: Id) Error!void {
    const b = e.b;
    const sets = try @import("sets.zig").define(b);
    const keys = sets.map;
    const retain = try emitRetain(e, d.slots, keys);
    const frame = try e.param(d.retain, 0);
    const mask = try b.variable(keys.tree);
    const changed = try b.variable(d.slots.tree);
    const owners = try b.variable(try projection.schema([]const data.process_state.Owner, b));
    try b.define(d.retain, try b.bind(changed, try e.call(retain, &.{
        try e.field(frame, 2), try e.param(d.retain, 1),
    }), try b.bind(owners, try e.call(retained_owners, &.{
        try e.field(frame, 3), try b.reference(changed),
    }), try b.pure(try e.replace(
        try e.replace(frame, 2, try b.reference(changed)),
        3,
        try b.reference(owners),
    )))));
    try b.define(d.prune, try b.bind(mask, try e.call(
        sets.from_sequence,
        &.{try e.param(d.prune, 1)},
    ), try e.call(d.retain, &.{ try e.param(d.prune, 0), try b.reference(mask) })));
}

fn isEmpty(e: Author, value: Id) Error!Id {
    return e.binary(.equal, try e.b.primitive(e.integer, .variant_tag, &.{value}, 0), e.zero);
}

// A slot contains one tagged representation. Replacing it cannot leave a
// second value in another map. Generic reads materialize only a selected scalar.
fn emitScalars(e: Author, d: Definition, scalar: @import("scalar.zig").Definition) Error!Id {
    const b = e.b;
    const value = try projection.schema(data.graph.Value, b);
    const raw_type = try projection.schema(Scalar, b);
    const body_schema = b.schemas.items[@intCast(value)].product[1];
    const pack = try b.declare(&.{raw_type}, value, &.{}, &.{});
    const bytes = try b.variable(try projection.schema([8]u8, b));
    const raw = try e.param(pack, 0);
    try b.define(pack, try b.bind(bytes, try e.call(
        scalar.encode,
        &.{try e.field(raw, 1)},
    ), try b.pure(try e.tuple(value, &.{ try e.field(raw, 0), try e.variant(
        body_schema,
        0,
        try b.reference(bytes),
    ) }))));
    const materialize = try b.declare(&.{d.slot}, value, &.{}, &.{});
    inline for (.{ materialize, d.read, d.read_raw }, 0..) |function, kind| {
        const generic = try b.variable(value);
        const retained = try b.variable(raw_type);
        const ordinary = if (kind == 2)
            try e.call(scalar.decode, &.{try e.payload(
                try e.field(try b.reference(generic), 1),
                0,
            )})
        else
            try b.pure(try b.reference(generic));
        const direct = if (kind == 2) try b.pure(
            try e.field(try b.reference(retained), 1),
        ) else try e.call(
            pack,
            &.{try b.reference(retained)},
        );
        const found = try b.variable(d.slots.optional);
        const selected = if (kind == 0) try e.param(function, 0) else try e.payload(try b.reference(
            found,
        ), 1);
        var body = try b.term(.{ .match_sum = .{ .value = selected, .cases = &.{
            .{ .variable = generic, .body = ordinary },
            .{ .variable = retained, .body = direct },
        } } });
        if (kind != 0) body = try b.bind(found, try e.call(d.slots.get, &.{
            try e.field(try e.param(function, 0), 2), try e.param(function, 1),
        }), body);
        try b.define(function, body);
    }
    try b.define(d.valid, try e.call(d.slots.valid, &.{try e.field(try e.param(d.valid, 0), 2)}));
    return materialize;
}

fn emitProjection(e: Author, d: Definition, materialize: Id) Error!void {
    const b = e.b;
    const binding = try projection.schema(data.process_state.Binding, b);
    const bindings = try projection.schema([]const data.process_state.Binding, b);
    const output = try table.define(b, binding);
    const fill = try b.declare(&.{ bindings, d.slots.tree }, d.slots.tree, &.{}, &.{});
    try emitFill(e, d, binding, bindings, fill);
    const collect = try b.declare(&.{ d.slots.tree, output.table }, output.table, &.{}, &.{});
    try emitCollect(e, d, materialize, binding, bindings, output, collect);
}

fn emitRetain(e: Author, slots: maps.Definition, keys: maps.Definition) Error!Id {
    const b = e.b;
    const retain = try b.declare(&.{ slots.tree, keys.tree }, slots.tree, &.{}, &.{});
    const input = try e.param(retain, 0);
    const allowed = try e.param(retain, 1);
    const nil = try b.variable(e.unit);
    const leaf = try b.variable(slots.entry);
    const fork = try b.variable(slots.branch);
    const node = try b.reference(fork);
    const found = try b.variable(keys.optional);
    const left_var = try b.variable(slots.tree);
    const right_var = try b.variable(slots.tree);
    const l = try b.reference(left_var);
    const r = try b.reference(right_var);
    const empty_tree = try slots.empty(e);
    const retained = try b.bind(left_var, try e.call(
        retain,
        &.{ try e.field(node, 1), allowed },
    ), try b.bind(right_var, try e.call(retain, &.{ try e.field(node, 2), allowed }), try e.when(
        try isEmpty(e, l),
        try b.pure(r),
        try e.when(
            try isEmpty(e, r),
            try b.pure(l),
            try b.pure(
                try e.variant(
                    slots.tree,
                    2,
                    try e.tuple(slots.branch, &.{ try e.field(node, 0), l, r }),
                ),
            ),
        ),
    )));
    try b.define(retain, try b.term(.{ .match_sum = .{ .value = input, .cases = &.{
        .{ .variable = nil, .body = try b.pure(input) },
        .{ .variable = leaf, .body = try b.bind(found, try e.call(keys.get, &.{
            allowed, try e.field(try b.reference(leaf), 0),
        }), try e.when(
            try isEmpty(e, try b.reference(found)),
            try b.pure(empty_tree),
            try b.pure(input),
        )) },
        .{ .variable = fork, .body = retained },
    } } }));
    return retain;
}

fn emitCommon(e: Author, owners: Id, scopes: Id, d: Definition, rescope: anytype) Error!void {
    const common = try e.b.declare(&.{ scopes, e.integer, e.integer }, e.integer, &.{}, &.{});
    const definitions = try e.param(common, 0);
    const old = try e.param(common, 1);
    const target = try e.param(common, 2);
    const old_parent = try e.payload(try e.field(try e.required(definitions, old), 0), 1);
    const new_parent = try e.payload(try e.field(try e.required(definitions, target), 0), 1);
    try e.b.define(
        common,
        try e.when(
            try e.binary(.equal, old, target),
            try e.b.pure(old),
            try e.when(
                try e.binary(.less, old, target),
                try e.call(common, &.{ definitions, old, new_parent }),
                try e.call(common, &.{ definitions, old_parent, target }),
            ),
        ),
    );
    const input = try e.param(d.scope, 0);
    const destination = try e.param(d.scope, 2);
    const ancestor = try e.b.variable(e.integer);
    const changed = try e.b.variable(owners);
    try e.b.define(d.scope, try e.b.bind(ancestor, try e.call(common, &.{
        try e.param(d.scope, 1), try e.field(input, 1), destination,
    }), try e.b.bind(changed, try e.call(rescope, &.{
        try e.field(input, 3), try e.b.reference(ancestor),
    }), try e.b.pure(try e.replace(
        try e.replace(input, 1, destination),
        3,
        try e.b.reference(changed),
    )))));
}

fn emitLoop(e: Author, value: Id, owners: Id, schema: Id, d: Definition) Error!void {
    const output = try table.define(e.b, value);
    const loop = try e.b.declare(&.{ schema, owners, output.table }, output.table, &.{}, &.{});
    const frame = try e.param(loop, 0);
    const prior = try e.param(loop, 2);
    const pair_type = try e.b.schema(.{ .product = &.{
        try projection.schema(data.process_state.Owner, e.b), owners,
    } });
    const popped = try e.b.schema(.{ .sum = &.{ e.unit, pair_type } });
    const nil = try e.b.variable(e.unit);
    const pair_var = try e.b.variable(pair_type);
    const pair = try e.b.reference(pair_var);
    const selected = try e.b.variable(value);
    const appended = try e.b.variable(output.table);
    try e.b.define(loop, try e.b.term(.{ .match_sum = .{ .value = try e.b.primitive(
        popped,
        .sequence_pop,
        &.{try e.param(loop, 1)},
        0,
    ), .cases = &.{
        .{ .variable = nil, .body = try e.b.pure(prior) },
        .{ .variable = pair_var, .body = try e.b.bind(selected, try e.call(d.read, &.{
            frame, try e.field(try e.field(pair, 0), 1),
        }), try e.b.bind(appended, try e.call(
            output.append,
            &.{ prior, try e.b.reference(selected) },
        ), try e.call(loop, &.{ frame, try e.field(pair, 1), try e.b.reference(appended) }))) },
    } } }));
    const collected = try e.b.variable(output.table);
    const input = try e.param(d.discards, 0);
    try e.b.define(d.discards, try e.b.bind(collected, try e.call(loop, &.{
        input, try e.field(input, 3), try output.empty(e.b),
    }), try e.call(output.to_sequence, &.{try e.b.reference(collected)})));
}

fn defineD(
    e: Author,
    value: Id,
    slot_type: Id,
    slots: anytype,
    scalar: Id,
    public: Id,
    schema: Id,
    scopes: Id,
    live: Id,
    keys: anytype,
) Error!Definition {
    return .{
        .schema = schema,
        .public = public,
        .slot = slot_type,
        .slots = slots,
        .read_raw = try e.b.declare(&.{ schema, e.integer }, e.integer, &.{}, &.{}),
        .write_raw = try e.b.declare(&.{ schema, e.integer, scalar }, schema, &.{}, &.{}),
        .valid = try e.b.declare(&.{schema}, e.boolean, &.{}, &.{}),
        .from_public = try e.b.declare(&.{public}, schema, &.{}, &.{}),
        .to_public = try e.b.declare(&.{schema}, public, &.{}, &.{}),
        .read = try e.b.declare(&.{ schema, e.integer }, value, &.{}, &.{}),
        .write = try e.b.declare(&.{ schema, e.integer, value }, schema, &.{}, &.{}),
        .clear = try e.b.declare(&.{ schema, e.integer }, schema, &.{}, &.{}),
        .scope = try e.b.declare(&.{ schema, scopes, e.integer }, schema, &.{}, &.{}),
        .prune = try e.b.declare(&.{ schema, live }, schema, &.{}, &.{}),
        .retain = try e.b.declare(&.{ schema, keys.map.tree }, schema, &.{}, &.{}),
        .discards = try e.b.declare(
            &.{schema},
            try projection.schema([]const data.graph.Value, e.b),
            &.{},
            &.{},
        ),
    };
}

fn emitEstablishInsertFirst(
    e: Author,
    output: anytype,
    loop: Id,
    head: Id,
    tail: Id,
    new: Id,
    prior: Id,
    next: Id,
    inserted: Id,
) Error!Id {
    return try e.b.bind(
        inserted,
        try e.call(output.append, &.{
            prior,
            new,
        }),
        try e.b.bind(
            next,
            try e.call(output.append, &.{ try e.b.reference(inserted), head }),
            try e.call(loop, &.{
                tail, new, try e.b.constant(bool, false), try e.b.reference(next),
            }),
        ),
    );
}

fn emitFill(e: Author, d: Definition, binding: Id, bindings: Id, fill: Id) Error!void {
    const parts = try e.b.schema(.{ .product = &.{ binding, bindings } });
    const popped = try e.b.schema(.{ .sum = &.{ e.unit, parts } });
    const nil = try e.b.variable(e.unit);
    const pair_var = try e.b.variable(parts);
    const pair = try e.b.reference(pair_var);
    const entry = try e.field(pair, 0);
    const next = try e.b.variable(d.slots.tree);
    try e.b.define(fill, try e.b.term(.{ .match_sum = .{
        .value = try e.b.primitive(popped, .sequence_pop, &.{try e.param(fill, 0)}, 0),
        .cases = &.{
            .{ .variable = nil, .body = try e.b.pure(try e.param(fill, 1)) },
            .{ .variable = pair_var, .body = try e.b.bind(next, try e.call(d.slots.set, &.{
                try e.param(fill, 1),
                try e.field(entry, 0),
                try e.variant(d.slot, 0, try e.field(
                    entry,
                    1,
                )),
            }), try e.call(fill, &.{
                try e.field(pair, 1),
                try e.b.reference(next),
            })) },
        },
    } }));
    const input = try e.param(d.from_public, 0);
    const filled = try e.b.variable(d.slots.tree);
    try e.b.define(d.from_public, try e.b.bind(filled, try e.call(fill, &.{
        try e.field(input, 2), try d.slots.empty(e),
    }), try e.b.pure(try e.tuple(d.schema, &.{
        try e.field(input, 0),
        try e.field(input, 1),
        try e.b.reference(filled),
        try e.field(input, 3),
    }))));
}

fn emitCollect(
    e: Author,
    d: Definition,
    materialize: Id,
    binding: Id,
    bindings: Id,
    output: anytype,
    collect: Id,
) Error!void {
    const nil = try e.b.variable(e.unit);
    const leaf = try e.b.variable(d.slots.entry);
    const fork = try e.b.variable(d.slots.branch);
    const node = try e.b.reference(fork);
    const entry = try e.b.reference(leaf);
    const prior = try e.param(collect, 1);
    const converted = try e.b.variable(try projection.schema(data.graph.Value, e.b));
    const left = try e.b.variable(output.table);
    try e.b.define(
        collect,
        try e.b.term(
            .{
                .match_sum = .{
                    .value = try e.param(collect, 0),
                    .cases = &.{
                        .{ .variable = nil, .body = try e.b.pure(prior) },
                        .{ .variable = leaf, .body = try e.b.bind(converted, try e.call(
                            materialize,
                            &.{try e.field(entry, 1)},
                        ), try e.call(output.append, &.{ prior, try e.tuple(binding, &.{
                            try e.field(entry, 0), try e.b.reference(converted),
                        }) })) },
                        .{ .variable = fork, .body = try e.b.bind(left, try e.call(
                            collect,
                            &.{ try e.field(node, 1), prior },
                        ), try e.call(collect, &.{
                            try e.field(node, 2), try e.b.reference(left),
                        })) },
                    },
                },
            },
        ),
    );
    const input = try e.param(d.to_public, 0);
    const collected = try e.b.variable(output.table);
    const published = try e.b.variable(bindings);
    try e.b.define(d.to_public, try e.b.bind(collected, try e.call(collect, &.{
        try e.field(input, 2), try output.empty(e.b),
    }), try e.b.bind(published, try e.call(
        output.to_sequence,
        &.{try e.b.reference(collected)},
    ), try e.b.pure(try e.tuple(d.public, &.{
        try e.field(input, 0),
        try e.field(input, 1),
        try e.b.reference(published),
        try e.field(input, 3),
    })))));
}

fn emitEstablishLoopDefinition(
    e: Author,
    output: anytype,
    loop: Id,
    popped: Id,
    nil: Id,
    pair_var: Id,
    head: Id,
    new: Id,
    pending: Id,
    prior: Id,
    append_head: Id,
    insert_first: anytype,
) Error!void {
    try e.b.define(loop, try e.b.term(.{ .match_sum = .{
        .value = try e.b.primitive(popped, .sequence_pop, &.{try e.param(loop, 0)}, 0),
        .cases = &.{
            .{ .variable = nil, .body = try e.when(
                pending,
                try e.call(output.append, &.{ prior, new }),
                try e.b.pure(prior),
            ) },
            .{ .variable = pair_var, .body = try e.when(pending, try e.when(try e.binary(
                .equal,
                try e.field(head, 0),
                try e.field(new, 0),
            ), append_head, insert_first), append_head) },
        },
    } }));
}

fn emitEstablishEntryDefinition(
    e: Author,
    owner: Id,
    output: anytype,
    entry: Id,
    loop: Id,
    collected: Id,
) Error!void {
    try e.b.define(
        entry,
        try e.b.bind(
            collected,
            try e.call(
                loop,
                &.{
                    try e.param(entry, 0),
                    try e.tuple(owner, &.{
                        try e.param(entry, 1),
                        try e.param(entry, 2),
                    }),
                    try e.b.constant(bool, true),
                    try output.empty(e.b),
                },
            ),
            try e.call(output.to_sequence, &.{try e.b.reference(collected)}),
        ),
    );
}

fn defineFinish(
    e: Author,
    establish: anytype,
    input: Id,
    slot: Id,
    established: Id,
    new_owners: Id,
    result: Id,
    plain: Id,
    tag: Id,
) Error!Id {
    return try e.when(try e.binary(
        .equal,
        tag,
        try e.b.constant(u64, 3),
    ), try e.b.bind(established, try e.call(establish, &.{
        new_owners, try e.field(input, 1), slot,
    }), try e.b.pure(try e.replace(
        result,
        3,
        try e.b.reference(established),
    ))), plain);
}

fn emitSlotUpdates(
    e: Author,
    d: Definition,
    slot_type: Id,
    slots: maps.Definition,
    owners: Id,
    without: Id,
    establish: Id,
) Error!void {
    const b = e.b;
    inline for (.{ d.write, d.write_raw, d.clear }, 0..) |function, kind| {
        const input = try e.param(function, 0);
        const slot = try e.param(function, 1);
        const changed_slots = try b.variable(slots.tree);
        const changed_owners = try b.variable(owners);
        const established = try b.variable(owners);
        const old_owners = try e.field(input, 3);
        const new_slots = try b.reference(changed_slots);
        const new_owners = try b.reference(changed_owners);
        const result = try e.replace(input, 2, new_slots);
        const plain = try b.pure(try e.replace(result, 3, new_owners));
        var finish = plain;
        if (kind == 0) {
            const written = try e.param(function, 2);
            const tag = try b.primitive(e.integer, .variant_tag, &.{try e.field(written, 1)}, 0);
            finish = try defineFinish(
                e,
                establish,
                input,
                slot,
                established,
                new_owners,
                result,
                plain,
                tag,
            );
        }
        finish = try b.bind(changed_owners, try e.call(without, &.{ old_owners, slot }), finish);
        const updated = if (kind != 2) try e.call(
            slots.set,
            &.{
                try e.field(input, 2),
                slot,
                try e.variant(slot_type, kind, try e.param(function, 2)),
            },
        ) else try e.call(slots.remove, &.{ try e.field(input, 2), slot });
        try b.define(function, try b.bind(changed_slots, updated, finish));
    }
}
