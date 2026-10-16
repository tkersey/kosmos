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
pub const Field = enum(usize) { position, scope, bindings, owners, scalars };
pub const Scalar = struct { schema: Id, bits: u64 };

pub const Definition = struct {
    schema: Id,
    public: Id,
    slots: maps.Definition,
    scalars: maps.Definition,
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
    const slots = try maps.define(b, value);
    const scalar = try projection.schema(Scalar, b);
    const scalars = try maps.define(b, scalar);
    const public = try projection.schema(data.process_state.Activation, b);
    const owners = try projection.schema([]const data.process_state.Owner, b);
    const schema = try b.schema(.{ .product = &.{ e.integer, e.integer, slots.tree, owners, scalars.tree } });
    const scopes = try projection.schema([]const data.activation.CustodyScope, b);
    const live = try projection.schema([]const Id, b);
    const keys = try @import("sets.zig").define(b);
    const d: Definition = .{
        .schema = schema,
        .public = public,
        .slots = slots,
        .scalars = scalars,
        .read_raw = try b.declare(&.{ schema, e.integer }, e.integer, &.{}, &.{}),
        .write_raw = try b.declare(&.{ schema, e.integer, scalar }, schema, &.{}, &.{}),
        .valid = try b.declare(&.{schema}, e.boolean, &.{}, &.{}),
        .from_public = try b.declare(&.{public}, schema, &.{}, &.{}),
        .to_public = try b.declare(&.{schema}, public, &.{}, &.{}),
        .read = try b.declare(&.{ schema, e.integer }, value, &.{}, &.{}),
        .write = try b.declare(&.{ schema, e.integer, value }, schema, &.{}, &.{}),
        .clear = try b.declare(&.{ schema, e.integer }, schema, &.{}, &.{}),
        .scope = try b.declare(&.{ schema, scopes, e.integer }, schema, &.{}, &.{}),
        .prune = try b.declare(&.{ schema, live }, schema, &.{}, &.{}),
        .retain = try b.declare(&.{ schema, keys.map.tree }, schema, &.{}, &.{}),
        .discards = try b.declare(&.{schema}, try projection.schema([]const data.graph.Value, b), &.{}, &.{}),
    };
    const scalar_ops = try @import("scalar.zig").define(b);
    const materialize = try emitScalars(e, d, scalar_ops);
    {
        const input = try e.param(d.from_public, 0);
        const bindings = try b.variable(slots.tree);
        try b.define(d.from_public, try b.bind(bindings, try e.call(slots.from_sequence, &.{try e.field(input, 2)}), try b.pure(try e.tuple(schema, &.{ try e.field(input, 0), try e.field(input, 1), try b.reference(bindings), try e.field(input, 3), try scalars.empty(e) }))));
        const hydrated = try e.param(d.to_public, 0);
        const merged = try b.variable(slots.tree);
        const published = try b.variable(slots.entries);
        try b.define(d.to_public, try b.bind(merged, try e.call(materialize, &.{ try e.field(hydrated, 4), try e.field(hydrated, 2) }), try b.bind(published, try e.call(slots.to_sequence, &.{try b.reference(merged)}), try b.pure(try e.tuple(public, &.{ try e.field(hydrated, 0), try e.field(hydrated, 1), try b.reference(published), try e.field(hydrated, 3) })))));
    }
    const without = try ownerWalk(e, slots, .remove);
    const rescope = try ownerWalk(e, slots, .scope);
    const retained = try ownerWalk(e, slots, .prune);
    const establish = try emitEstablish(e);
    inline for (.{ true, false }) |writing| {
        const function = if (writing) d.write else d.clear;
        const input = try e.param(function, 0);
        const slot = try e.param(function, 1);
        const changed_slots = try b.variable(slots.tree);
        const changed_owners = try b.variable(owners);
        const changed_scalars = try b.variable(scalars.tree);
        const established = try b.variable(owners);
        const old_owners = try e.field(input, 3);
        const new_slots = try b.reference(changed_slots);
        const new_owners = try b.reference(changed_owners);
        const result = try e.replace(try e.replace(input, 2, new_slots), 4, try b.reference(changed_scalars));
        const plain = try b.pure(try e.replace(result, 3, new_owners));
        var finish = plain;
        if (writing) {
            const written = try e.param(function, 2);
            const tag = try b.primitive(e.integer, .variant_tag, &.{try e.field(written, 1)}, 0);
            finish = try e.when(try e.binary(.equal, tag, try b.constant(u64, 3)), try b.bind(established, try e.call(establish, &.{ new_owners, try e.field(input, 1), slot }), try b.pure(try e.replace(result, 3, try b.reference(established)))), plain);
        }
        finish = try b.bind(changed_owners, try e.call(without, &.{ old_owners, slot }), finish);
        const updated = if (writing) try e.call(slots.set, &.{ try e.field(input, 2), slot, try e.param(function, 2) }) else try e.call(slots.remove, &.{ try e.field(input, 2), slot });
        try b.define(function, try b.bind(changed_scalars, try e.call(scalars.remove, &.{ try e.field(input, 4), slot }), try b.bind(changed_slots, updated, finish)));
    }
    {
        const common = try b.declare(&.{ scopes, e.integer, e.integer }, e.integer, &.{}, &.{});
        const definitions = try e.param(common, 0);
        const old = try e.param(common, 1);
        const target = try e.param(common, 2);
        const old_parent = try e.payload(try e.field(try e.required(definitions, old), 0), 1);
        const new_parent = try e.payload(try e.field(try e.required(definitions, target), 0), 1);
        try b.define(common, try e.when(try e.binary(.equal, old, target), try b.pure(old), try e.when(try e.binary(.less, old, target), try e.call(common, &.{ definitions, old, new_parent }), try e.call(common, &.{ definitions, old_parent, target }))));
        const input = try e.param(d.scope, 0);
        const destination = try e.param(d.scope, 2);
        const ancestor = try b.variable(e.integer);
        const changed = try b.variable(owners);
        try b.define(d.scope, try b.bind(ancestor, try e.call(common, &.{ try e.param(d.scope, 1), try e.field(input, 1), destination }), try b.bind(changed, try e.call(rescope, &.{ try e.field(input, 3), try b.reference(ancestor) }), try b.pure(try e.replace(try e.replace(input, 1, destination), 3, try b.reference(changed))))));
    }
    try emitPrune(e, d, retained);
    {
        const output = try table.define(b, value);
        const loop = try b.declare(&.{ schema, owners, output.table }, output.table, &.{}, &.{});
        const frame = try e.param(loop, 0);
        const prior = try e.param(loop, 2);
        const pair_type = try b.schema(.{ .product = &.{ try projection.schema(data.process_state.Owner, b), owners } });
        const popped = try b.schema(.{ .sum = &.{ e.unit, pair_type } });
        const nil = try b.variable(e.unit);
        const pair_var = try b.variable(pair_type);
        const pair = try b.reference(pair_var);
        const selected = try b.variable(value);
        const appended = try b.variable(output.table);
        try b.define(loop, try b.term(.{ .match_sum = .{ .value = try b.primitive(popped, .sequence_pop, &.{try e.param(loop, 1)}, 0), .cases = &.{
            .{ .variable = nil, .body = try b.pure(prior) },
            .{ .variable = pair_var, .body = try b.bind(selected, try e.call(d.read, &.{ frame, try e.field(try e.field(pair, 0), 1) }), try b.bind(appended, try e.call(output.append, &.{ prior, try b.reference(selected) }), try e.call(loop, &.{ frame, try e.field(pair, 1), try b.reference(appended) }))) },
        } } }));
        const collected = try b.variable(output.table);
        const input = try e.param(d.discards, 0);
        try b.define(d.discards, try b.bind(collected, try e.call(loop, &.{ input, try e.field(input, 3), try output.empty(b) }), try e.call(output.to_sequence, &.{try b.reference(collected)})));
    }
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
    const append = try b.bind(next, try e.call(output.append, &.{ prior, head }), try e.call(loop, &.{ tail, argument, try b.reference(next) }));
    const visit = switch (kind) {
        .remove => try e.when(try e.binary(.equal, try e.field(head, 1), argument), skip, append),
        .scope => blk: {
            const rewritten = try e.replace(head, 0, argument);
            const change = try b.bind(next, try e.call(output.append, &.{ prior, rewritten }), try e.call(loop, &.{ tail, argument, try b.reference(next) }));
            break :blk try e.when(try e.binary(.less, argument, try e.field(head, 0)), change, append);
        },
        .prune => blk: {
            const found = try b.variable(slots.optional);
            const tag = try b.primitive(e.integer, .variant_tag, &.{try b.reference(found)}, 0);
            break :blk try b.bind(found, try e.call(slots.get, &.{ argument, try e.field(head, 1) }), try e.when(try e.binary(.equal, tag, e.zero), skip, append));
        },
    };
    try b.define(loop, try b.term(.{ .match_sum = .{
        .value = try b.primitive(popped, .sequence_pop, &.{try e.param(loop, 0)}, 0),
        .cases = &.{ .{ .variable = nil, .body = try b.pure(prior) }, .{ .variable = pair_var, .body = visit } },
    } }));
    const collected = try b.variable(output.table);
    try b.define(entry, try b.bind(collected, try e.call(loop, &.{ try e.param(entry, 0), try e.param(entry, 1), try output.empty(b) }), try e.call(output.to_sequence, &.{try b.reference(collected)})));
    return entry;
}

fn emitEstablish(e: Author) Error!Id {
    const b = e.b;
    const owner = try projection.schema(data.process_state.Owner, b);
    const owners = try projection.schema([]const data.process_state.Owner, b);
    const output = try table.define(b, owner);
    const entry = try b.declare(&.{ owners, e.integer, e.integer }, owners, &.{}, &.{});
    const loop = try b.declare(&.{ owners, owner, e.boolean, output.table }, output.table, &.{}, &.{});
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
    const append_head = try b.bind(next, try e.call(output.append, &.{ prior, head }), try e.call(loop, &.{ tail, new, pending, try b.reference(next) }));
    const insert_first = try b.bind(inserted, try e.call(output.append, &.{ prior, new }), try b.bind(next, try e.call(output.append, &.{ try b.reference(inserted), head }), try e.call(loop, &.{ tail, new, try b.constant(bool, false), try b.reference(next) })));
    try b.define(loop, try b.term(.{ .match_sum = .{
        .value = try b.primitive(popped, .sequence_pop, &.{try e.param(loop, 0)}, 0),
        .cases = &.{
            .{ .variable = nil, .body = try e.when(pending, try e.call(output.append, &.{ prior, new }), try b.pure(prior)) },
            .{ .variable = pair_var, .body = try e.when(pending, try e.when(try e.binary(.equal, try e.field(head, 0), try e.field(new, 0)), append_head, insert_first), append_head) },
        },
    } }));
    const collected = try b.variable(output.table);
    try b.define(entry, try b.bind(collected, try e.call(loop, &.{ try e.param(entry, 0), try e.tuple(owner, &.{ try e.param(entry, 1), try e.param(entry, 2) }), try b.constant(bool, true), try output.empty(b) }), try e.call(output.to_sequence, &.{try b.reference(collected)})));
    return entry;
}

fn emitPrune(e: Author, d: Definition, retained_owners: Id) Error!void {
    const b = e.b;
    const sets = try @import("sets.zig").define(b);
    const keys = sets.map;
    const retain = try emitRetain(e, d.slots, keys);
    const retain_scalars = try emitRetain(e, d.scalars, keys);
    const frame = try e.param(d.retain, 0);
    const mask = try b.variable(keys.tree);
    const changed = try b.variable(d.slots.tree);
    const changed_scalars = try b.variable(d.scalars.tree);
    const owners = try b.variable(try projection.schema([]const data.process_state.Owner, b));
    try b.define(d.retain, try b.bind(changed_scalars, try e.call(retain_scalars, &.{ try e.field(frame, 4), try e.param(d.retain, 1) }), try b.bind(changed, try e.call(retain, &.{ try e.field(frame, 2), try e.param(d.retain, 1) }), try b.bind(owners, try e.call(retained_owners, &.{ try e.field(frame, 3), try b.reference(changed) }), try b.pure(try e.replace(try e.replace(try e.replace(frame, 2, try b.reference(changed)), 3, try b.reference(owners)), 4, try b.reference(changed_scalars)))))));
    try b.define(d.prune, try b.bind(mask, try e.call(sets.from_sequence, &.{try e.param(d.prune, 1)}), try e.call(d.retain, &.{ try e.param(d.prune, 0), try b.reference(mask) })));
}

fn isEmpty(e: Author, value: Id) Error!Id {
    return e.binary(.equal, try e.b.primitive(e.integer, .variant_tag, &.{value}, 0), e.zero);
}

// Disjoint scalar storage is a representation of guest slots, not a second
// execution. Generic accesses materialize one value; raw accesses retain bits.
fn emitScalars(e: Author, d: Definition, scalar: @import("scalar.zig").Definition) Error!Id {
    const b = e.b;
    const value = try projection.schema(data.graph.Value, b);
    const body_schema = b.schemas.items[@intCast(value)].product[1];
    const pack = try b.declare(&.{try projection.schema(Scalar, b)}, value, &.{}, &.{});
    const bytes = try b.variable(try projection.schema([8]u8, b));
    const raw = try e.param(pack, 0);
    try b.define(pack, try b.bind(bytes, try e.call(scalar.encode, &.{try e.field(raw, 1)}), try b.pure(try e.tuple(value, &.{ try e.field(raw, 0), try e.variant(body_schema, 0, try b.reference(bytes)) }))));
    inline for (.{ false, true }) |raw_access| {
        const function = if (raw_access) d.read_raw else d.read;
        const input = try e.param(function, 0);
        const slot = try e.param(function, 1);
        const found = try b.variable(d.scalars.optional);
        const generic = try b.variable(d.slots.optional);
        const selected = try e.payload(try b.reference(generic), 1);
        const ordinary = if (raw_access)
            try e.call(scalar.decode, &.{try e.payload(try e.field(selected, 1), 0)})
        else
            try b.pure(selected);
        const fallback = try b.bind(generic, try e.call(d.slots.get, &.{ try e.field(input, 2), slot }), ordinary);
        const retained = try e.payload(try b.reference(found), 1);
        const direct = if (raw_access) try b.pure(try e.field(retained, 1)) else try e.call(pack, &.{retained});
        try b.define(function, try b.bind(found, try e.call(d.scalars.get, &.{ try e.field(input, 4), slot }), try e.when(try isEmpty(e, try b.reference(found)), fallback, direct)));
    }
    {
        const input = try e.param(d.write_raw, 0);
        const slot = try e.param(d.write_raw, 1);
        const cleared = try b.variable(d.schema);
        const changed = try b.variable(d.scalars.tree);
        // Clear removes old ownership as well as either old representation.
        try b.define(d.write_raw, try b.bind(cleared, try e.call(d.clear, &.{ input, slot }), try b.bind(changed, try e.call(d.scalars.set, &.{ try e.field(try b.reference(cleared), 4), slot, try e.param(d.write_raw, 2) }), try b.pure(try e.replace(try b.reference(cleared), 4, try b.reference(changed))))));
    }
    const materialize = try b.declare(&.{ d.scalars.tree, d.slots.tree }, d.slots.tree, &.{}, &.{});
    const disjoint = try b.declare(&.{ d.scalars.tree, d.slots.tree }, e.boolean, &.{}, &.{});
    inline for (.{ false, true }) |checking| {
        const function = if (checking) disjoint else materialize;
        const input = try e.param(function, 0);
        const generic = try e.param(function, 1);
        const nil = try b.variable(e.unit);
        const leaf = try b.variable(d.scalars.entry);
        const fork = try b.variable(d.scalars.branch);
        const node = try b.reference(fork);
        const entry = try b.reference(leaf);
        const converted = try b.variable(value);
        const found = try b.variable(d.slots.optional);
        const left = try b.variable(if (checking) e.boolean else d.slots.tree);
        const leaf_body = if (checking)
            try b.bind(found, try e.call(d.slots.get, &.{ generic, try e.field(entry, 0) }), try b.pure(try isEmpty(e, try b.reference(found))))
        else
            try b.bind(converted, try e.call(pack, &.{try e.field(entry, 1)}), try e.call(d.slots.set, &.{ generic, try e.field(entry, 0), try b.reference(converted) }));
        const right = try e.call(function, &.{ try e.field(node, 2), if (checking) generic else try b.reference(left) });
        const branch = try b.bind(left, try e.call(function, &.{ try e.field(node, 1), generic }), if (checking) try e.when(try b.reference(left), right, try b.pure(try b.constant(bool, false))) else right);
        try b.define(function, try b.term(.{ .match_sum = .{ .value = input, .cases = &.{
            .{ .variable = nil, .body = try b.pure(if (checking) try b.constant(bool, true) else generic) },
            .{ .variable = leaf, .body = leaf_body },
            .{ .variable = fork, .body = branch },
        } } }));
    }
    const input = try e.param(d.valid, 0);
    const generic_valid = try b.variable(e.boolean);
    const scalar_valid = try b.variable(e.boolean);
    const invalid = try b.pure(try b.constant(bool, false));
    const check_disjoint = try e.call(disjoint, &.{ try e.field(input, 4), try e.field(input, 2) });
    const check_scalars = try b.bind(scalar_valid, try e.call(d.scalars.valid, &.{try e.field(input, 4)}), try e.when(try b.reference(scalar_valid), check_disjoint, invalid));
    try b.define(d.valid, try b.bind(generic_valid, try e.call(d.slots.valid, &.{try e.field(input, 2)}), try e.when(try b.reference(generic_valid), check_scalars, invalid)));
    return materialize;
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
    const retained = try b.bind(left_var, try e.call(retain, &.{ try e.field(node, 1), allowed }), try b.bind(right_var, try e.call(retain, &.{ try e.field(node, 2), allowed }), try e.when(try isEmpty(e, l), try b.pure(r), try e.when(try isEmpty(e, r), try b.pure(l), try b.pure(try e.variant(slots.tree, 2, try e.tuple(slots.branch, &.{ try e.field(node, 0), l, r })))))));
    try b.define(retain, try b.term(.{ .match_sum = .{ .value = input, .cases = &.{
        .{ .variable = nil, .body = try b.pure(input) },
        .{ .variable = leaf, .body = try b.bind(found, try e.call(keys.get, &.{ allowed, try e.field(try b.reference(leaf), 0) }), try e.when(try isEmpty(e, try b.reference(found)), try b.pure(empty_tree), try b.pure(input))) },
        .{ .variable = fork, .body = retained },
    } } }));
    return retain;
}
