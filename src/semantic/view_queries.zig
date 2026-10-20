//! Reusable ordinary Horos queries over immutable, scoped guest descriptions.
const source = @import("horos").source;
const data = @import("horos_data");
const views = @import("views.zig");
const projection = @import("projection.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;

pub const RetentionInput = struct { view: views.GuestView, target: u64 };
pub const RetentionResult = struct {
    binding: views.Binding,
    conclusion: enum { reachable, absent_complete, unknown_partial },
    root: ?views.Root,
    path: []const views.Edge,
};
const Item = struct { root: views.Root, node: u64, path: []const views.Edge };

/// Breadth-first search. Each described node enters the queue at most once;
/// retained paths are witnesses, including explicit owned versus plain edges.
/// The first discovery fixes the ordered BFS witness. Check every root before
/// expanding edges so a later root still wins over an earlier root's child.
pub fn retention(b: *source.Builder) Error!source.ast.Module {
    const e = try Author.init(b);
    const input_schema = try projection.schema(RetentionInput, b);
    const view_schema = try projection.schema(views.GuestView, b);
    const item_schema = try projection.schema(Item, b);
    const result_schema = try projection.schema(RetentionResult, b);
    const path_schema = try projection.schema([]const views.Edge, b);
    const optional_root = try projection.schema(?views.Root, b);
    const queue = try @import("table.zig").define(b, item_schema);
    const visited = try @import("map.zig").define(b, e.boolean);
    const pair = try b.schema(.{ .product = &.{ queue.table, visited.tree } });
    const progress = try b.schema(.{ .sum = &.{ pair, item_schema } });
    const seed = try b.declare(&.{ input_schema, e.integer, pair }, progress, &.{}, &.{});
    const expand = try b.declare(&.{
        input_schema, item_schema, e.integer, pair,
    }, progress, &.{}, &.{});
    const finish = try b.declare(&.{ view_schema, item_schema }, result_schema, &.{}, &.{});
    const search = try b.declare(&.{ input_schema, pair, e.integer }, result_schema, &.{}, &.{});
    const entry = try b.declare(&.{input_schema}, result_schema, &.{}, &.{});
    const empty_path = try b.primitive(path_schema, .sequence, &.{}, 0);
    try emitSeed(e, item_schema, queue, visited, pair, progress, seed, empty_path);
    try emitExpand(e, item_schema, path_schema, queue, visited, pair, progress, expand);
    try emitFinish(e, result_schema, optional_root, finish);
    try emitSearch(
        e,
        result_schema,
        optional_root,
        queue,
        progress,
        expand,
        finish,
        search,
        empty_path,
    );
    const input = try e.param(entry, 0);
    const seeded = try b.variable(progress);
    const initial = try e.tuple(pair, &.{ try queue.empty(b), try visited.empty(e) });
    const success = try e.call(finish, &.{
        try e.field(input, 0), try e.payload(try b.reference(seeded), 1),
    });
    const search_seeded = try e.call(search, &.{
        input, try e.payload(try b.reference(seeded), 0), e.zero,
    });
    try retentionEntryDefinition(e, seed, entry, input, seeded, initial, success, search_seeded);
    return b.module(entry, e.unit);
}

pub const Observation = struct { revision: u64, control: [32]u8, bytes: []const u8 };
pub const Trace = struct {
    binding: views.Binding,
    complete: bool,
    observations: []const Observation,
};
pub const DivergenceInput = struct { left: Trace, right: Trace };
pub const DivergenceResult = struct {
    left: views.Binding,
    right: views.Binding,
    compared: u64,
    conclusion: enum { divergence, observed_agreement, incomparable },
    revision: ?u64,
    left_complete: bool,
    right_complete: bool,
};

/// Compare aligned, finite observations only. Equal prefixes establish no
/// universal equivalence; different controls/revisions are incomparable.
pub fn divergence(b: *source.Builder) Error!source.ast.Module {
    const e = try Author.init(b);
    const input_schema = try projection.schema(DivergenceInput, b);
    const result_schema = try projection.schema(DivergenceResult, b);
    const optional_revision = try projection.schema(?u64, b);
    const equal_digest = try @import("record_equal.zig").define([32]u8, b);
    const equal_bytes = try @import("record_equal.zig").define([]const u8, b);
    const loop = try b.declare(&.{ input_schema, e.integer }, result_schema, &.{}, &.{});
    const entry = try b.declare(&.{input_schema}, result_schema, &.{}, &.{});
    const none = try defineDivergenceLoop(
        e,
        loop,
        result_schema,
        optional_revision,
        equal_digest,
        equal_bytes,
    );
    try defineDivergenceEntry(e, entry, loop, result_schema, equal_digest, none);
    return b.module(entry, e.unit);
}

fn retentionPath(e: Author, path_schema: Id, item: Id, edge: Id) Error!Id {
    return try e.b.primitive(
        path_schema,
        .sequence_concat,
        &.{ try e.field(
            item,
            2,
        ), try e.b.primitive(
            path_schema,
            .sequence,
            &.{edge},
            0,
        ) },
        0,
    );
}

fn retentionAbsent(
    e: Author,
    result_schema: Id,
    optional_root: Id,
    empty_path: Id,
    view: Id,
) Error!Id {
    return try e.b.pure(
        try e.tuple(
            result_schema,
            &.{
                try e.field(view, 0),
                try e.literal(@FieldType(RetentionResult, "conclusion"), .absent_complete),
                try e.variant(optional_root, 0, e.unit_value),
                empty_path,
            },
        ),
    );
}

fn retentionPartial(
    e: Author,
    result_schema: Id,
    optional_root: Id,
    empty_path: Id,
    view: Id,
) Error!Id {
    return try e.b.pure(
        try e.tuple(
            result_schema,
            &.{
                try e.field(view, 0),
                try e.literal(@FieldType(RetentionResult, "conclusion"), .unknown_partial),
                try e.variant(optional_root, 0, e.unit_value),
                empty_path,
            },
        ),
    );
}

fn emitSeed(
    e: Author,
    item_schema: Id,
    queue: anytype,
    visited: anytype,
    pair: Id,
    progress: Id,
    seed: Id,
    empty_path: Id,
) Error!void {
    const input = try e.param(seed, 0);
    const view = try e.field(input, 0);
    const index = try e.param(seed, 1);
    const state = try e.param(seed, 2);
    const roots = try e.field(view, 3);
    const root = try e.required(roots, index);
    const node = try e.field(root, 0);
    const item = try e.tuple(item_schema, &.{ root, node, empty_path });
    const found = try e.b.variable(visited.optional);
    const changed_queue = try e.b.variable(queue.table);
    const changed_seen = try e.b.variable(visited.tree);
    const next = try e.binary(.integer_add, index, e.one);
    const keep = try e.call(seed, &.{ input, next, state });
    const changed = try e.tuple(pair, &.{
        try e.b.reference(changed_queue), try e.b.reference(changed_seen),
    });
    const append = try e.b.bind(changed_queue, try e.call(
        queue.append,
        &.{ try e.field(state, 0), item },
    ), try e.b.bind(changed_seen, try e.call(visited.set, &.{
        try e.field(state, 1), node, try e.b.constant(bool, true),
    }), try e.call(seed, &.{ input, next, changed })));
    const step = try e.b.bind(found, try e.call(
        visited.get,
        &.{ try e.field(state, 1), node },
    ), try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{try e.b.reference(found)},
        0,
    ), e.one), keep, append));
    const found_root = try e.b.pure(try e.variant(progress, 1, item));
    const checked = try e.when(try e.binary(.equal, node, try e.field(input, 1)), found_root, step);
    try e.b.define(seed, try e.when(try e.binary(.less, index, try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{roots},
        0,
    )), checked, try e.b.pure(try e.variant(progress, 0, state))));
}

fn emitExpand(
    e: Author,
    item_schema: Id,
    path_schema: Id,
    queue: anytype,
    visited: anytype,
    pair: Id,
    progress: Id,
    expand: Id,
) Error!void {
    const input = try e.param(expand, 0);
    const view = try e.field(input, 0);
    const item = try e.param(expand, 1);
    const index = try e.param(expand, 2);
    const state = try e.param(expand, 3);
    const edges = try e.field(view, 4);
    const edge = try e.required(edges, index);
    const node = try e.field(edge, 1);
    const next = try e.binary(.integer_add, index, e.one);
    const keep = try e.call(expand, &.{ input, item, next, state });
    const found = try e.b.variable(visited.optional);
    const changed_queue = try e.b.variable(queue.table);
    const changed_seen = try e.b.variable(visited.tree);
    const path = try retentionPath(e, path_schema, item, edge);
    const appended = try e.tuple(item_schema, &.{ try e.field(item, 0), node, path });
    const changed = try e.tuple(pair, &.{
        try e.b.reference(changed_queue), try e.b.reference(changed_seen),
    });
    const append = try e.b.bind(changed_queue, try e.call(
        queue.append,
        &.{ try e.field(state, 0), appended },
    ), try e.b.bind(changed_seen, try e.call(visited.set, &.{
        try e.field(state, 1), node, try e.b.constant(bool, true),
    }), try e.call(expand, &.{ input, item, next, changed })));
    const discovered = try e.when(try e.binary(
        .equal,
        node,
        try e.field(input, 1),
    ), try e.b.pure(try e.variant(progress, 1, appended)), append);
    const unseen = try e.b.bind(found, try e.call(
        visited.get,
        &.{ try e.field(state, 1), node },
    ), try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{try e.b.reference(found)},
        0,
    ), e.one), keep, discovered));
    const step = try e.when(try e.binary(
        .equal,
        try e.field(edge, 0),
        try e.field(item, 1),
    ), unseen, keep);
    try e.b.define(expand, try e.when(try e.binary(.less, index, try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{edges},
        0,
    )), step, try e.b.pure(try e.variant(progress, 0, state))));
}

fn emitFinish(e: Author, result_schema: Id, optional_root: Id, finish: Id) Error!void {
    const view = try e.param(finish, 0);
    const item = try e.param(finish, 1);
    try e.b.define(
        finish,
        try e.b.pure(
            try e.tuple(
                result_schema,
                &.{
                    try e.field(view, 0),
                    try e.literal(@FieldType(RetentionResult, "conclusion"), .reachable),
                    try e.variant(optional_root, 1, try e.field(item, 0)),
                    try e.field(item, 2),
                },
            ),
        ),
    );
}

fn emitSearch(
    e: Author,
    result_schema: Id,
    optional_root: Id,
    queue: anytype,
    progress: Id,
    expand: Id,
    finish: Id,
    search: Id,
    empty_path: Id,
) Error!void {
    const input = try e.param(search, 0);
    const view = try e.field(input, 0);
    const state = try e.param(search, 1);
    const index = try e.param(search, 2);
    const found = try e.b.variable(queue.optional);
    const item = try e.payload(try e.b.reference(found), 1);
    const expanded = try e.b.variable(progress);
    const again = try e.call(search, &.{
        input,
        try e.payload(try e.b.reference(
            expanded,
        ), 0),
        try e.binary(.integer_add, index, e.one),
    });
    const success = try e.call(finish, &.{ view, try e.payload(try e.b.reference(expanded), 1) });
    const step = try e.b.bind(found, try e.call(
        queue.get,
        &.{ try e.field(state, 0), index },
    ), try e.b.bind(expanded, try e.call(
        expand,
        &.{ input, item, e.zero, state },
    ), try e.when(try e.binary(.equal, try e.b.primitive(
        e.integer,
        .variant_tag,
        &.{try e.b.reference(expanded)},
        0,
    ), e.one), success, again)));
    const absent = try retentionAbsent(e, result_schema, optional_root, empty_path, view);
    const partial = try retentionPartial(e, result_schema, optional_root, empty_path, view);
    try e.b.define(search, try e.when(try e.binary(
        .less,
        index,
        try e.field(try e.field(state, 0), 0),
    ), step, try e.when(try e.field(view, 1), absent, partial)));
}

fn retentionEntryDefinition(
    e: Author,
    seed: Id,
    entry: Id,
    input: Id,
    seeded: Id,
    initial: Id,
    success: Id,
    search_seeded: Id,
) Error!void {
    try e.b.define(
        entry,
        try e.b.bind(
            seeded,
            try e.call(seed, &.{
                input,
                e.zero,
                initial,
            }),
            try e.when(
                try e.binary(
                    .equal,
                    try e.b.primitive(e.integer, .variant_tag, &.{try e.b.reference(seeded)}, 0),
                    e.one,
                ),
                success,
                search_seeded,
            ),
        ),
    );
}

fn traceResult(
    author: Author,
    schema: Id,
    ltrace: Id,
    rtrace: Id,
    count: Id,
    comptime conclusion: @FieldType(DivergenceResult, "conclusion"),
    revision: Id,
) Error!Id {
    return author.b.pure(
        try author.tuple(
            schema,
            &.{
                try author.field(ltrace, 0),
                try author.field(rtrace, 0),
                count,
                try author.literal(
                    @FieldType(DivergenceResult, "conclusion"),
                    conclusion,
                ),
                revision,
                try author.field(ltrace, 1),
                try author.field(rtrace, 1),
            },
        ),
    );
}

fn defineDivergenceEntry(
    e: Author,
    entry: Id,
    loop: Id,
    result_schema: Id,
    equal_digest: Id,
    none: Id,
) Error!void {
    const b = e.b;
    const original = try e.param(entry, 0);
    const left_trace = try e.field(original, 0);
    const right_trace = try e.field(original, 1);
    const left_binding = try e.field(left_trace, 0);
    const right_binding = try e.field(right_trace, 0);
    const same_guest = try b.variable(e.boolean);
    const same_origin = try b.variable(e.boolean);
    const denied = try traceResult(
        e,
        result_schema,
        left_trace,
        right_trace,
        e.zero,
        .incomparable,
        none,
    );
    const allowed = try b.bind(same_origin, try e.call(equal_digest, &.{
        try e.field(left_binding, 3), try e.field(right_binding, 3),
    }), try e.when(try b.reference(same_origin), try e.call(loop, &.{ original, e.zero }), denied));
    try b.define(entry, try b.bind(same_guest, try e.call(equal_digest, &.{
        try e.field(left_binding, 0), try e.field(right_binding, 0),
    }), try e.when(try b.reference(same_guest), allowed, denied)));
}

fn defineDivergenceLoop(
    e: Author,
    loop: Id,
    result_schema: Id,
    optional_revision: Id,
    equal_digest: Id,
    equal_bytes: Id,
) Error!Id {
    const b = e.b;
    const input = try e.param(loop, 0);
    const index = try e.param(loop, 1);
    const left = try e.field(input, 0);
    const right = try e.field(input, 1);
    const left_list = try e.field(left, 2);
    const right_list = try e.field(right, 2);
    const l = try e.required(left_list, index);
    const r = try e.required(right_list, index);
    const none = try e.variant(optional_revision, 0, e.unit_value);
    const incompatible = try traceResult(e, result_schema, left, right, index, .incomparable, none);
    const agree = try traceResult(e, result_schema, left, right, index, .observed_agreement, none);
    const difference = try traceResult(
        e,
        result_schema,
        left,
        right,
        index,
        .divergence,
        try e.variant(optional_revision, 1, try e.field(l, 0)),
    );
    const step = try compareObservations(
        e,
        equal_digest,
        equal_bytes,
        loop,
        input,
        index,
        l,
        r,
        difference,
        incompatible,
    );
    const checked = try orderedDivergence(
        e,
        index,
        left_list,
        right_list,
        l,
        r,
        step,
        incompatible,
    );
    const right_available = try e.binary(.less, index, try b.primitive(
        e.integer,
        .sequence_length,
        &.{right_list},
        0,
    ));
    try b.define(loop, try e.when(try e.binary(.less, index, try b.primitive(
        e.integer,
        .sequence_length,
        &.{left_list},
        0,
    )), try e.when(right_available, checked, agree), agree));
    return none;
}

fn orderedDivergence(
    e: Author,
    index: Id,
    left_list: Id,
    right_list: Id,
    l: Id,
    r: Id,
    step: Id,
    incompatible: Id,
) Error!Id {
    const previous = try e.binary(.integer_sub, index, e.one);
    const ordered = try e.when(try e.binary(.less, try e.field(
        try e.required(left_list, previous),
        0,
    ), try e.field(l, 0)), try e.when(try e.binary(.less, try e.field(
        try e.required(right_list, previous),
        0,
    ), try e.field(r, 0)), step, incompatible), incompatible);
    return try e.when(try e.binary(.equal, index, e.zero), step, ordered);
}

fn compareObservations(
    e: Author,
    equal_digest: Id,
    equal_bytes: Id,
    loop: Id,
    input: Id,
    index: Id,
    l: Id,
    r: Id,
    difference: Id,
    incompatible: Id,
) Error!Id {
    const b = e.b;
    const controls = try b.variable(e.boolean);
    const observation = try b.variable(e.boolean);
    const compare = try b.bind(observation, try e.call(equal_bytes, &.{
        try e.field(l, 2), try e.field(r, 2),
    }), try e.when(try b.reference(observation), try e.call(loop, &.{
        input, try e.binary(.integer_add, index, e.one),
    }), difference));
    return try e.when(try e.binary(
        .equal,
        try e.field(l, 0),
        try e.field(r, 0),
    ), try b.bind(controls, try e.call(equal_digest, &.{
        try e.field(l, 1), try e.field(r, 1),
    }), try e.when(try b.reference(controls), compare, incompatible)), incompatible);
}
