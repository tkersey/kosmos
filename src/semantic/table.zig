//! Persistent numeric tables, implemented entirely as first-order Horos code.
//! The forest holds complete binary trees, newest chunk first, in increasing
//! size order. Carry merges equal chunks with the older tree on the left.
//! Lookup/update count backward from the newest entry; public IDs stay stable.
//! Append touches at most one path through the forest; update copies only its
//! forest prefix and tree path. Retained roots share every unchanged subtree.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;

pub const Definition = struct {
    element: Id,
    tree: Id,
    branch: Id,
    forest: Id,
    cons: Id,
    table: Id,
    optional: Id,
    sequence: Id,
    size: Id,
    carry: Id,
    get_tree: Id,
    get_forest: Id,
    set_tree: Id,
    set_forest: Id,
    append: Id,
    get: Id,
    set: Id,
    from_sequence: Id,
    to_sequence: Id,
    valid: Id,

    pub fn empty(self: Definition, b: *source.Builder) Error!Id {
        const e = try Author.init(b);
        return e.tuple(self.table, &.{ e.zero, try e.variant(self.forest, 0, e.unit_value) });
    }
};

pub fn define(b: *source.Builder, element: Id) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.table/1", element);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const tree = try b.reserveSchema();
    const branch = try b.schema(.{ .product = &.{ tree, tree, e.integer } });
    try b.defineSchema(tree, .{ .sum = &.{ element, branch } });
    const forest = try b.reserveSchema();
    const cons = try b.schema(.{ .product = &.{ tree, forest } });
    try b.defineSchema(forest, .{ .sum = &.{ e.unit, cons } });
    const table = try b.schema(.{ .product = &.{ e.integer, forest } });
    const optional = try b.schema(.{ .sum = &.{ e.unit, element } });
    const sequence = try b.schema(.{ .seq = element });
    const d: Definition = .{
        .element = element,
        .tree = tree,
        .branch = branch,
        .forest = forest,
        .cons = cons,
        .table = table,
        .optional = optional,
        .sequence = sequence,
        .size = try b.declare(&.{tree}, e.integer, &.{}, &.{}),
        .carry = try b.declare(&.{ tree, forest }, forest, &.{}, &.{}),
        .get_tree = try b.declare(&.{ tree, e.integer }, element, &.{}, &.{}),
        .get_forest = try b.declare(&.{ forest, e.integer }, element, &.{}, &.{}),
        .set_tree = try b.declare(&.{ tree, e.integer, element }, tree, &.{}, &.{}),
        .set_forest = try b.declare(&.{ forest, e.integer, element }, forest, &.{}, &.{}),
        .append = try b.declare(&.{ table, element }, table, &.{}, &.{}),
        .get = try b.declare(&.{ table, e.integer }, optional, &.{}, &.{}),
        .set = try b.declare(&.{ table, e.integer, element }, table, &.{}, &.{}),
        .from_sequence = try b.declare(&.{sequence}, table, &.{}, &.{}),
        .to_sequence = try b.declare(&.{table}, sequence, &.{}, &.{}),
        .valid = try b.declare(&.{table}, e.boolean, &.{}, &.{}),
    };
    try emitSize(e, d);
    try emitCarry(e, d);
    try emitTreeAccess(e, d, false);
    try emitTreeAccess(e, d, true);
    try emitForestAccess(e, d, false);
    try emitForestAccess(e, d, true);
    try emitPublic(e, d);
    try emitProjections(e, d);
    try emitValidation(e, d);
    return cache.finish(b, d);
}

fn emitValidation(e: Author, d: Definition) Error!void {
    const b = e.b;
    const yes = try b.pure(try b.constant(bool, true));
    const no = try b.pure(try b.constant(bool, false));
    const two = try b.constant(u64, 2);
    const tree_valid = try b.declare(&.{ d.tree, e.integer }, e.boolean, &.{}, &.{});
    const forest_valid = try b.declare(&.{ d.forest, e.integer, e.integer }, e.boolean, &.{}, &.{});
    {
        const expected = try e.param(tree_valid, 1);
        const leaf = try b.variable(d.element);
        const branch = try b.variable(d.branch);
        const pair = try b.reference(branch);
        const half = try e.binary(.integer_div, expected, two);
        const left = try b.variable(e.boolean);
        const descend = try b.bind(left, try e.call(tree_valid, &.{ try e.field(pair, 0), half }), try e.when(try b.reference(left), try e.call(tree_valid, &.{ try e.field(pair, 1), half }), no));
        const branch_body = try e.when(try e.binary(.less, e.one, expected), try e.when(try e.binary(.equal, try e.field(pair, 2), expected), try e.when(try e.binary(.equal, try e.binary(.integer_rem, expected, two), e.zero), descend, no), no), no);
        try b.define(tree_valid, try b.term(.{ .match_sum = .{
            .value = try e.param(tree_valid, 0),
            .cases = &.{
                .{ .variable = leaf, .body = try e.when(try e.binary(.equal, expected, e.one), yes, no) },
                .{ .variable = branch, .body = branch_body },
            },
        } }));
    }
    {
        const previous = try e.param(forest_valid, 1);
        const remaining = try e.param(forest_valid, 2);
        const nil = try b.variable(e.unit);
        const cons = try b.variable(d.cons);
        const pair = try b.reference(cons);
        const head = try e.field(pair, 0);
        const size = try b.variable(e.integer);
        const size_ref = try b.reference(size);
        const checked = try b.variable(e.boolean);
        const descend = try b.bind(checked, try e.call(tree_valid, &.{ head, size_ref }), try e.when(try b.reference(checked), try e.call(forest_valid, &.{ try e.field(pair, 1), size_ref, try e.binary(.integer_sub, remaining, size_ref) }), no));
        const body = try b.bind(size, try e.call(d.size, &.{head}), try e.when(try e.binary(.less, previous, size_ref), try e.when(try e.binary(.less, remaining, size_ref), no, descend), no));
        try b.define(forest_valid, try b.term(.{ .match_sum = .{
            .value = try e.param(forest_valid, 0),
            .cases = &.{
                .{ .variable = nil, .body = try e.when(try e.binary(.equal, remaining, e.zero), yes, no) },
                .{ .variable = cons, .body = body },
            },
        } }));
    }
    const table_value = try e.param(d.valid, 0);
    try b.define(d.valid, try e.call(forest_valid, &.{ try e.field(table_value, 1), e.zero, try e.field(table_value, 0) }));
}

fn emitProjections(e: Author, d: Definition) Error!void {
    const b = e.b;
    const popped = try b.schema(.{ .product = &.{ d.element, d.sequence } });
    const optional = try b.schema(.{ .sum = &.{ e.unit, popped } });
    const fill = try b.declare(&.{ d.sequence, d.table }, d.table, &.{}, &.{});
    {
        const values = try e.param(fill, 0);
        const prior = try e.param(fill, 1);
        const missing = try b.variable(e.unit);
        const parts = try b.variable(popped);
        const next = try b.variable(d.table);
        const pair = try b.reference(parts);
        try b.define(fill, try b.term(.{ .match_sum = .{
            .value = try b.primitive(optional, .sequence_pop, &.{values}, 0),
            .cases = &.{
                .{ .variable = missing, .body = try b.pure(prior) },
                .{ .variable = parts, .body = try b.bind(next, try e.call(d.append, &.{ prior, try e.field(pair, 0) }), try e.call(fill, &.{ try e.field(pair, 1), try b.reference(next) })) },
            },
        } }));
    }
    try b.define(d.from_sequence, try e.call(fill, &.{ try e.param(d.from_sequence, 0), try d.empty(b) }));

    // Projection follows tree structure, so concatenation copies at most one
    // level per element. It does not grow a flat output one element at a time.
    const tree_sequence = try b.declare(&.{d.tree}, d.sequence, &.{}, &.{});
    const forest_sequence = try b.declare(&.{d.forest}, d.sequence, &.{}, &.{});
    {
        const leaf = try b.variable(d.element);
        const branch = try b.variable(d.branch);
        const left = try b.variable(d.sequence);
        const right = try b.variable(d.sequence);
        const pair = try b.reference(branch);
        const combine = try b.bind(left, try e.call(tree_sequence, &.{try e.field(pair, 0)}), try b.bind(right, try e.call(tree_sequence, &.{try e.field(pair, 1)}), try b.pure(try b.primitive(d.sequence, .sequence_concat, &.{ try b.reference(left), try b.reference(right) }, 0))));
        try b.define(tree_sequence, try b.term(.{ .match_sum = .{
            .value = try e.param(tree_sequence, 0),
            .cases = &.{
                .{ .variable = leaf, .body = try b.pure(try b.primitive(d.sequence, .sequence, &.{try b.reference(leaf)}, 0)) },
                .{ .variable = branch, .body = combine },
            },
        } }));
    }
    {
        const nil = try b.variable(e.unit);
        const cons = try b.variable(d.cons);
        const head = try b.variable(d.sequence);
        const tail = try b.variable(d.sequence);
        const pair = try b.reference(cons);
        const combine = try b.bind(head, try e.call(tree_sequence, &.{try e.field(pair, 0)}), try b.bind(tail, try e.call(forest_sequence, &.{try e.field(pair, 1)}), try b.pure(try b.primitive(d.sequence, .sequence_concat, &.{ try b.reference(tail), try b.reference(head) }, 0))));
        try b.define(forest_sequence, try b.term(.{ .match_sum = .{
            .value = try e.param(forest_sequence, 0),
            .cases = &.{
                .{ .variable = nil, .body = try b.pure(try b.primitive(d.sequence, .sequence, &.{}, 0)) },
                .{ .variable = cons, .body = combine },
            },
        } }));
    }
    try b.define(d.to_sequence, try e.call(forest_sequence, &.{try e.field(try e.param(d.to_sequence, 0), 1)}));
}

fn emitSize(e: Author, d: Definition) Error!void {
    const leaf = try e.b.variable(d.element);
    const branch = try e.b.variable(d.branch);
    try e.b.define(d.size, try e.b.term(.{ .match_sum = .{
        .value = try e.param(d.size, 0),
        .cases = &.{
            .{ .variable = leaf, .body = try e.b.pure(e.one) },
            .{ .variable = branch, .body = try e.b.pure(try e.field(try e.b.reference(branch), 2)) },
        },
    } }));
}

fn emitCarry(e: Author, d: Definition) Error!void {
    const b = e.b;
    const tree = try e.param(d.carry, 0);
    const forest = try e.param(d.carry, 1);
    const nil = try b.variable(e.unit);
    const pair = try b.variable(d.cons);
    const head = try e.field(try b.reference(pair), 0);
    const tail = try e.field(try b.reference(pair), 1);
    const size = try b.variable(e.integer);
    const head_size = try b.variable(e.integer);
    const size_ref = try b.reference(size);
    const head_size_ref = try b.reference(head_size);
    const prepend = try b.pure(try e.variant(d.forest, 1, try e.tuple(d.cons, &.{ tree, forest })));
    const merged = try e.variant(d.tree, 1, try e.tuple(d.branch, &.{ head, tree, try e.binary(.integer_add, size_ref, head_size_ref) }));
    const carry = try b.bind(size, try e.call(d.size, &.{tree}), try b.bind(head_size, try e.call(d.size, &.{head}), try e.when(try e.binary(.equal, size_ref, head_size_ref), try e.call(d.carry, &.{ merged, tail }), prepend)));
    try b.define(d.carry, try b.term(.{ .match_sum = .{ .value = forest, .cases = &.{
        .{ .variable = nil, .body = prepend },
        .{ .variable = pair, .body = carry },
    } } }));
}

fn emitTreeAccess(e: Author, d: Definition, comptime update: bool) Error!void {
    const b = e.b;
    const function = if (update) d.set_tree else d.get_tree;
    const tree = try e.param(function, 0);
    const offset = try e.param(function, 1);
    const replacement = if (update) try e.param(function, 2) else undefined;
    const leaf = try b.variable(d.element);
    const branch = try b.variable(d.branch);
    const node = try b.reference(branch);
    const left = try e.field(node, 0);
    const right = try e.field(node, 1);
    const right_size = try b.variable(e.integer);
    const size = try b.reference(right_size);
    const changed = if (update) try b.variable(d.tree) else undefined;
    const right_call = try e.call(function, if (update) &.{ right, offset, replacement } else &.{ right, offset });
    const left_offset = try e.binary(.integer_sub, offset, size);
    const left_call = try e.call(function, if (update) &.{ left, left_offset, replacement } else &.{ left, left_offset });
    const in_right = if (update) try b.bind(changed, right_call, try b.pure(try e.variant(d.tree, 1, try e.tuple(d.branch, &.{ left, try b.reference(changed), try e.field(node, 2) })))) else right_call;
    const in_left = if (update) try b.bind(changed, left_call, try b.pure(try e.variant(d.tree, 1, try e.tuple(d.branch, &.{ try b.reference(changed), right, try e.field(node, 2) })))) else left_call;
    const descend = try b.bind(right_size, try e.call(d.size, &.{right}), try e.when(try e.binary(.less, offset, size), in_right, in_left));
    try b.define(function, try b.term(.{ .match_sum = .{ .value = tree, .cases = &.{
        .{ .variable = leaf, .body = try e.when(try e.binary(.equal, offset, e.zero), try b.pure(if (update) try e.variant(d.tree, 0, replacement) else try b.reference(leaf)), try e.fail()) },
        .{ .variable = branch, .body = descend },
    } } }));
}

fn emitForestAccess(e: Author, d: Definition, comptime update: bool) Error!void {
    const b = e.b;
    const function = if (update) d.set_forest else d.get_forest;
    const tree_function = if (update) d.set_tree else d.get_tree;
    const forest = try e.param(function, 0);
    const offset = try e.param(function, 1);
    const replacement = if (update) try e.param(function, 2) else undefined;
    const nil = try b.variable(e.unit);
    const pair = try b.variable(d.cons);
    const head = try e.field(try b.reference(pair), 0);
    const tail = try e.field(try b.reference(pair), 1);
    const head_size = try b.variable(e.integer);
    const size = try b.reference(head_size);
    const next_offset = try e.binary(.integer_sub, offset, size);
    const here = try e.call(tree_function, if (update) &.{ head, offset, replacement } else &.{ head, offset });
    const rest = try e.call(function, if (update) &.{ tail, next_offset, replacement } else &.{ tail, next_offset });
    const changed_tree = if (update) try b.variable(d.tree) else undefined;
    const changed_tail = if (update) try b.variable(d.forest) else undefined;
    const here_body = if (update) try b.bind(changed_tree, here, try b.pure(try e.variant(d.forest, 1, try e.tuple(d.cons, &.{ try b.reference(changed_tree), tail })))) else here;
    const rest_body = if (update) try b.bind(changed_tail, rest, try b.pure(try e.variant(d.forest, 1, try e.tuple(d.cons, &.{ head, try b.reference(changed_tail) })))) else rest;
    const descend = try b.bind(head_size, try e.call(d.size, &.{head}), try e.when(try e.binary(.less, offset, size), here_body, rest_body));
    try b.define(function, try b.term(.{ .match_sum = .{ .value = forest, .cases = &.{
        .{ .variable = nil, .body = try e.fail() },
        .{ .variable = pair, .body = descend },
    } } }));
}

fn emitPublic(e: Author, d: Definition) Error!void {
    const b = e.b;
    {
        const table = try e.param(d.append, 0);
        const value = try e.param(d.append, 1);
        const count = try e.field(table, 0);
        const forest = try b.variable(d.forest);
        const appended = try b.bind(forest, try e.call(d.carry, &.{ try e.variant(d.tree, 0, value), try e.field(table, 1) }), try b.pure(try e.tuple(d.table, &.{ try e.binary(.integer_add, count, e.one), try b.reference(forest) })));
        // u64 exhaustion is representation exhaustion, never an arbitrary quota.
        try b.define(d.append, try e.when(try e.binary(.less, count, try b.constant(u64, std.math.maxInt(u64))), appended, try e.fail()));
    }
    inline for (.{ false, true }) |update| {
        const function = if (update) d.set else d.get;
        const table = try e.param(function, 0);
        const index = try e.param(function, 1);
        const count = try e.field(table, 0);
        const offset = try e.binary(.integer_sub, try e.binary(.integer_sub, count, e.one), index);
        const result = try b.variable(if (update) d.forest else d.element);
        const call = if (update) try e.call(d.set_forest, &.{ try e.field(table, 1), offset, try e.param(function, 2) }) else try e.call(d.get_forest, &.{ try e.field(table, 1), offset });
        const returned = if (update) try e.tuple(d.table, &.{ count, try b.reference(result) }) else try e.variant(d.optional, 1, try b.reference(result));
        const body = try b.bind(result, call, try b.pure(returned));
        const missing = if (update) try e.fail() else try b.pure(try e.variant(d.optional, 0, e.unit_value));
        try b.define(function, try e.when(try e.binary(.less, index, count), body, missing));
    }
}
