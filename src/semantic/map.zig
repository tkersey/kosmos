//! Persistent sparse numeric maps authored in Horos. Branches split at the
//! highest differing key bit; their bits strictly decrease toward leaves.
//! Missing bindings consume no dense slot array. No native map callback exists.
const data = @import("horos_data");
const source = @import("horos").source;
const Author = @import("author.zig").Author;
const table = @import("table.zig");
const Id = data.program.Id;
const Error = source.Error;
const Case = @import("std").meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));

pub const Definition = struct {
    tree: Id,
    entry: Id,
    branch: Id,
    optional: Id,
    entries: Id,
    get: Id,
    set: Id,
    remove: Id,
    from_sequence: Id,
    to_sequence: Id,
    valid: Id,

    pub fn empty(d: Definition, e: Author) Error!Id {
        return e.variant(d.tree, 0, e.unit_value);
    }
};

pub fn define(b: *source.Builder, element: Id) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.map/1", element);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const tree = try b.reserveSchema();
    const entry = try b.schema(.{ .product = &.{ e.integer, element } });
    const branch = try b.schema(.{ .product = &.{ e.integer, tree, tree } });
    try b.defineSchema(tree, .{ .sum = &.{ e.unit, entry, branch } });
    const optional = try b.schema(.{ .sum = &.{ e.unit, element } });
    const entries = try b.schema(.{ .seq = entry });
    const d: Definition = .{
        .tree = tree,
        .entry = entry,
        .branch = branch,
        .optional = optional,
        .entries = entries,
        .get = try b.declare(&.{ tree, e.integer }, optional, &.{}, &.{}),
        .set = try b.declare(&.{ tree, e.integer, element }, tree, &.{}, &.{}),
        .remove = try b.declare(&.{ tree, e.integer }, tree, &.{}, &.{}),
        .from_sequence = try b.declare(&.{entries}, tree, &.{}, &.{}),
        .to_sequence = try b.declare(&.{tree}, entries, &.{}, &.{}),
        .valid = try b.declare(&.{tree}, e.boolean, &.{}, &.{}),
    };
    const highest = try b.declare(&.{e.integer}, e.integer, &.{}, &.{});
    const highest_loop = try b.declare(&.{ e.integer, e.integer }, e.integer, &.{}, &.{});
    {
        const x = try e.param(highest_loop, 0);
        const bit = try e.param(highest_loop, 1);
        const two = try b.constant(u64, 2);
        try b.define(highest_loop, try e.when(try e.binary(.less, e.one, x), try e.call(highest_loop, &.{ try e.binary(.integer_div, x, two), try e.binary(.integer_mul, bit, two) }), try b.pure(bit)));
        const input = try e.param(highest, 0);
        try b.define(highest, try e.when(try e.binary(.equal, input, e.zero), try b.pure(e.zero), try e.call(highest_loop, &.{ input, e.one })));
    }
    {
        const nil = try b.variable(e.unit);
        const leaf = try b.variable(entry);
        const fork = try b.variable(branch);
        const key = try e.param(d.get, 1);
        const pair = try b.reference(leaf);
        const node = try b.reference(fork);
        const absent = try b.pure(try e.variant(optional, 0, e.unit_value));
        try b.define(d.get, try match(e, try e.param(d.get, 0), &.{
            .{ .variable = nil, .body = absent },
            .{ .variable = leaf, .body = try e.when(try e.binary(.equal, key, try e.field(pair, 0)), try b.pure(try e.variant(optional, 1, try e.field(pair, 1))), absent) },
            .{ .variable = fork, .body = try e.when(try left(e, key, try e.field(node, 0)), try e.call(d.get, &.{ try e.field(node, 1), key }), try e.call(d.get, &.{ try e.field(node, 2), key })) },
        }));
    }
    const representative = try b.declare(&.{ tree, e.integer }, e.integer, &.{}, &.{});
    {
        const nil = try b.variable(e.unit);
        const leaf = try b.variable(entry);
        const fork = try b.variable(branch);
        const key = try e.param(representative, 1);
        const node = try b.reference(fork);
        try b.define(representative, try match(e, try e.param(representative, 0), &.{
            .{ .variable = nil, .body = try e.fail() },
            .{ .variable = leaf, .body = try b.pure(try e.field(try b.reference(leaf), 0)) },
            .{ .variable = fork, .body = try e.when(try left(e, key, try e.field(node, 0)), try e.call(representative, &.{ try e.field(node, 1), key }), try e.call(representative, &.{ try e.field(node, 2), key })) },
        }));
    }
    const insert = try b.declare(&.{ tree, entry, e.integer }, tree, &.{}, &.{});
    {
        const original = try e.param(insert, 0);
        const pair = try e.param(insert, 1);
        const bit = try e.param(insert, 2);
        const key = try e.field(pair, 0);
        const new_leaf = try e.variant(tree, 1, pair);
        const combined = try e.when(try left(e, key, bit), try b.pure(try e.variant(tree, 2, try e.tuple(branch, &.{ bit, new_leaf, original }))), try b.pure(try e.variant(tree, 2, try e.tuple(branch, &.{ bit, original, new_leaf }))));
        const nil = try b.variable(e.unit);
        const leaf = try b.variable(entry);
        const fork = try b.variable(branch);
        const node = try b.reference(fork);
        const changed = try b.variable(tree);
        const change_left = try b.bind(changed, try e.call(insert, &.{ try e.field(node, 1), pair, bit }), try b.pure(try e.variant(tree, 2, try e.replace(node, 1, try b.reference(changed)))));
        const change_right = try b.bind(changed, try e.call(insert, &.{ try e.field(node, 2), pair, bit }), try b.pure(try e.variant(tree, 2, try e.replace(node, 2, try b.reference(changed)))));
        try b.define(insert, try match(e, original, &.{
            .{ .variable = nil, .body = try b.pure(new_leaf) },
            .{ .variable = leaf, .body = try e.when(try e.binary(.equal, bit, e.zero), try b.pure(new_leaf), combined) },
            .{ .variable = fork, .body = try e.when(try e.binary(.less, bit, try e.field(node, 0)), try e.when(try left(e, key, try e.field(node, 0)), change_left, change_right), combined) },
        }));
        const input = try e.param(d.set, 0);
        const new_key = try e.param(d.set, 1);
        const new_pair = try e.tuple(entry, &.{ new_key, try e.param(d.set, 2) });
        const existing = try b.variable(e.integer);
        const difference = try b.variable(e.integer);
        const update = try b.bind(existing, try e.call(representative, &.{ input, new_key }), try b.bind(difference, try e.call(highest, &.{try e.binary(.integer_bit_xor, new_key, try b.reference(existing))}), try e.call(insert, &.{ input, new_pair, try b.reference(difference) })));
        try b.define(d.set, try e.when(try empty(e, input), try b.pure(try e.variant(tree, 1, new_pair)), update));
    }
    {
        const original = try e.param(d.remove, 0);
        const key = try e.param(d.remove, 1);
        const nil = try b.variable(e.unit);
        const leaf = try b.variable(entry);
        const fork = try b.variable(branch);
        const node = try b.reference(fork);
        const changed = try b.variable(tree);
        const changed_ref = try b.reference(changed);
        const change_left = try b.bind(changed, try e.call(d.remove, &.{ try e.field(node, 1), key }), try e.when(try empty(e, changed_ref), try b.pure(try e.field(node, 2)), try b.pure(try e.variant(tree, 2, try e.replace(node, 1, changed_ref)))));
        const change_right = try b.bind(changed, try e.call(d.remove, &.{ try e.field(node, 2), key }), try e.when(try empty(e, changed_ref), try b.pure(try e.field(node, 1)), try b.pure(try e.variant(tree, 2, try e.replace(node, 2, changed_ref)))));
        try b.define(d.remove, try match(e, original, &.{
            .{ .variable = nil, .body = try b.pure(original) },
            .{ .variable = leaf, .body = try e.when(try e.binary(.equal, key, try e.field(try b.reference(leaf), 0)), try b.pure(try d.empty(e)), try b.pure(original)) },
            .{ .variable = fork, .body = try e.when(try left(e, key, try e.field(node, 0)), change_left, change_right) },
        }));
    }
    try emitProjection(e, d);
    try emitValidation(e, d, highest);
    return cache.finish(b, d);
}

fn match(e: Author, value: Id, cases: []const Case) Error!Id {
    return e.b.term(.{ .match_sum = .{ .value = value, .cases = cases } });
}
fn empty(e: Author, value: Id) Error!Id {
    return e.binary(.equal, try e.b.primitive(e.integer, .variant_tag, &.{value}, 0), e.zero);
}
fn left(e: Author, key: Id, bit: Id) Error!Id {
    return e.binary(.equal, try e.binary(.integer_bit_and, key, bit), e.zero);
}

fn emitProjection(e: Author, d: Definition) Error!void {
    const b = e.b;
    const output = try table.define(b, d.entry);
    const collect = try b.declare(&.{ d.tree, output.table }, output.table, &.{}, &.{});
    {
        const nil = try b.variable(e.unit);
        const leaf = try b.variable(d.entry);
        const fork = try b.variable(d.branch);
        const node = try b.reference(fork);
        const prior = try e.param(collect, 1);
        const done_left = try b.variable(output.table);
        try b.define(collect, try match(e, try e.param(collect, 0), &.{
            .{ .variable = nil, .body = try b.pure(prior) },
            .{ .variable = leaf, .body = try e.call(output.append, &.{ prior, try b.reference(leaf) }) },
            .{ .variable = fork, .body = try b.bind(done_left, try e.call(collect, &.{ try e.field(node, 1), prior }), try e.call(collect, &.{ try e.field(node, 2), try b.reference(done_left) })) },
        }));
        const collected = try b.variable(output.table);
        try b.define(d.to_sequence, try b.bind(collected, try e.call(collect, &.{ try e.param(d.to_sequence, 0), try output.empty(b) }), try e.call(output.to_sequence, &.{try b.reference(collected)})));
    }
    const parts = try b.schema(.{ .product = &.{ d.entry, d.entries } });
    const popped = try b.schema(.{ .sum = &.{ e.unit, parts } });
    const fill = try b.declare(&.{ d.entries, d.tree }, d.tree, &.{}, &.{});
    const nil = try b.variable(e.unit);
    const pair_var = try b.variable(parts);
    const pair = try b.reference(pair_var);
    const entry = try e.field(pair, 0);
    const next = try b.variable(d.tree);
    try b.define(fill, try match(e, try b.primitive(popped, .sequence_pop, &.{try e.param(fill, 0)}, 0), &.{
        .{ .variable = nil, .body = try b.pure(try e.param(fill, 1)) },
        .{ .variable = pair_var, .body = try b.bind(next, try e.call(d.set, &.{ try e.param(fill, 1), try e.field(entry, 0), try e.field(entry, 1) }), try e.call(fill, &.{ try e.field(pair, 1), try b.reference(next) })) },
    }));
    try b.define(d.from_sequence, try e.call(fill, &.{ try e.param(d.from_sequence, 0), try d.empty(e) }));
}

fn emitValidation(e: Author, d: Definition, highest: Id) Error!void {
    const b = e.b;
    const bounds = try b.schema(.{ .product = &.{ e.integer, e.integer, e.integer } });
    const optional = try b.schema(.{ .sum = &.{ e.unit, bounds } });
    const inspect = try b.declare(&.{d.tree}, optional, &.{}, &.{});
    const invalid = try b.pure(try e.variant(optional, 0, e.unit_value));
    const nil = try b.variable(e.unit);
    const leaf = try b.variable(d.entry);
    const fork = try b.variable(d.branch);
    const node = try b.reference(fork);
    const bit = try e.field(node, 0);
    const left_var = try b.variable(optional);
    const right_var = try b.variable(optional);
    const left_result = try b.reference(left_var);
    const right_result = try b.reference(right_var);
    const l = try e.payload(left_result, 1);
    const r = try e.payload(right_result, 1);
    const top = try b.variable(e.integer);
    const valid = try b.pure(try e.variant(optional, 1, try e.tuple(bounds, &.{ try e.field(l, 0), try e.field(r, 1), bit })));
    var checked = try b.bind(top, try e.call(highest, &.{try e.binary(.integer_bit_xor, try e.field(l, 0), try e.field(r, 1))}), try e.when(try e.binary(.equal, try b.reference(top), bit), valid, invalid));
    checked = try e.when(try left(e, try e.field(r, 0), bit), invalid, checked);
    checked = try e.when(try left(e, try e.field(l, 1), bit), checked, invalid);
    checked = try e.when(try e.binary(.less, try e.field(r, 2), bit), checked, invalid);
    checked = try e.when(try e.binary(.less, try e.field(l, 2), bit), checked, invalid);
    checked = try e.when(try empty(e, right_result), invalid, checked);
    checked = try b.bind(right_var, try e.call(inspect, &.{try e.field(node, 2)}), checked);
    checked = try e.when(try empty(e, left_result), invalid, checked);
    checked = try b.bind(left_var, try e.call(inspect, &.{try e.field(node, 1)}), checked);
    checked = try e.when(try e.binary(.equal, try e.binary(.integer_bit_and, bit, try e.binary(.integer_sub, bit, e.one)), e.zero), checked, invalid);
    checked = try e.when(try e.binary(.equal, bit, e.zero), invalid, checked);
    const key = try e.field(try b.reference(leaf), 0);
    try b.define(inspect, try match(e, try e.param(inspect, 0), &.{
        .{ .variable = nil, .body = invalid },
        .{ .variable = leaf, .body = try b.pure(try e.variant(optional, 1, try e.tuple(bounds, &.{ key, key, e.zero }))) },
        .{ .variable = fork, .body = checked },
    }));
    const result = try b.variable(optional);
    const input = try e.param(d.valid, 0);
    try b.define(d.valid, try e.when(try empty(e, input), try b.pure(try b.constant(bool, true)), try b.bind(result, try e.call(inspect, &.{input}), try b.pure(try b.primitive(e.boolean, .boolean_not, &.{try empty(e, try b.reference(result))}, 0)))));
}
