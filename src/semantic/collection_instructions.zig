//! Guest collection operations built from logical ranges and explicit values.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const values = @import("values.zig");
const aggregates = @import("aggregate.zig");
const collections = @import("collections.zig");
const codecs = @import("codec.zig");
const access = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const p = data.program;
const g = data.graph;
const field = access.field;

pub const Definition = struct { evaluate: Id, result: Id };
const Generator = struct {
    e: Author,
    m: machines.Definition,
    v: values.Definition,
    aggregate: aggregates.Definition,
    collection: collections.Definition,
    input: Id,
    program: Id,
    shapes: Id,
    result: Id,
    outcome: Id,
    segments: Id,
    fields: Id,
    fn success(c: Generator, machine: Id, value: Id) Error!Id {
        return c.e.b.pure(try c.e.tuple(c.result, &.{
            machine, try c.e.variant(c.outcome, 0, value),
        }));
    }
    fn fault(c: Generator, machine: Id, kind: p.Fault) Error!Id {
        return c.e.b.pure(try c.e.tuple(c.result, &.{ machine, try c.e.variant(
            c.outcome,
            1,
            try c.e.literal(p.Fault, kind),
        ) }));
    }
    fn finish(c: Generator, term: Id) Error!Id {
        const variable = try c.e.b.variable(c.v.result);
        const pair = try c.e.b.reference(variable);
        return c.e.b.bind(variable, term, try c.success(
            try c.e.field(pair, 0),
            try c.e.field(pair, 1),
        ));
    }
    fn singleton(c: Generator, element: Id, value: Id) Error!Id {
        const storage = c.e.b.schemas.items[@intCast(c.collection.schema)].product[2];
        return c.e.tuple(c.collection.schema, &.{ element, c.e.one, try c.e.variant(
            storage,
            1,
            try c.e.b.primitive(c.fields, .sequence, &.{value}, 0),
        ) });
    }
    fn rebuild(c: Generator, machine: Id, schema: Id, count: Id, segments: []const Id) Error!Id {
        return c.e.call(c.collection.rebuild, &.{
            machine, schema, count, try c.e.b.primitive(c.segments, .sequence, segments, 0),
        });
    }
    fn is(c: Generator, opcode: Id, expected: p.Opcode) Error!Id {
        const tag = try c.e.b.primitive(try c.e.b.scalar(u32), .enum_tag, &.{opcode}, 0);
        return c.e.binary(.equal, tag, try c.e.b.constant(u32, @backingInt(expected)));
    }
    fn make(c: Generator, machine: Id, schema: Id, tag: Id, fields: []const Id) Error!Id {
        return c.e.call(c.aggregate.construct, &.{
            machine, schema, tag, try c.e.b.primitive(c.fields, .sequence, fields, 0),
        });
    }
};

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(
        Definition,
        "kosmos.semantic.collection_instructions/1",
        m.schema,
    );
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const v = try values.define(b, m);
    const aggregate = try aggregates.define(b, m);
    const collection = try collections.define(b, m);
    const codec = try codecs.define(b, m);
    const outcome = try projection.schema(values.Outcome, b);
    const result = try b.schema(.{ .product = &.{ m.schema, outcome } });
    const d: Definition = .{ .evaluate = try b.declare(&.{
        m.schema, m.frames.schema, try projection.schema(data.activation.Instruction, b), e.integer,
    }, result, &.{}, &.{}), .result = result };
    const input = try e.param(d.evaluate, 0);
    const frame = try e.param(d.evaluate, 1);
    const instruction = try e.param(d.evaluate, 2);
    const result_schema = try e.param(d.evaluate, 3);
    const program = try m.field(e, input, .program);
    const shapes = try field(e, try access.code(e, program), data.activation.Program, "schemas");
    const c: Generator = .{
        .e = e,
        .m = m,
        .v = v,
        .aggregate = aggregate,
        .collection = collection,
        .input = input,
        .program = program,
        .shapes = shapes,
        .result = result,
        .outcome = outcome,
        .segments = try projection.schema([]const collections.Collection, b),
        .fields = try projection.schema([]const g.Value, b),
    };
    try emitEvaluation(c, d, codec, frame, instruction, result_schema);
    return cache.finish(b, d);
}

fn defineWithin(
    e: Author,
    count: Id,
    right_count: Id,
    max_value: Id,
    overflow: Id,
    finish: anytype,
) Error!Id {
    return try e.when(
        try e.binary(.less, max_value, count),
        overflow,
        try e.when(
            try e.binary(.less, try e.binary(.integer_sub, max_value, count), right_count),
            overflow,
            finish,
        ),
    );
}

fn defineTake(
    e: Author,
    collection: anytype,
    input: Id,
    result_schema: Id,
    program: anytype,
    c: Generator,
    right_var: Id,
    view: Id,
    count: Id,
    index_var: Id,
    index: Id,
    read_right: Id,
    read_index: Id,
    length: Id,
    range: Id,
) Error!Id {
    return try e.b.bind(
        right_var,
        read_right,
        try e.b.bind(
            index_var,
            read_index,
            try e.b.bind(
                length,
                try e.when(
                    try e.binary(.less, index, count),
                    try e.b.pure(index),
                    try e.b.pure(count),
                ),
                try e.b.bind(range, try e.call(collection.range, &.{
                    program, view, e.zero, try e.b.reference(length),
                }), try c.finish(try c.rebuild(
                    input,
                    result_schema,
                    try e.b.reference(length),
                    &.{try e.b.reference(range)},
                ))),
            ),
        ),
    );
}

fn emitSequenceGet(o: Operands, body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var body = body_initial;

    const item = try e.b.variable(c.v.result);
    const absent = try e.b.variable(c.v.value);
    const sum_types = try e.payload(o.shape, @backingInt(p.SchemaTag.sum));
    const no = try e.b.bind(absent, try e.call(c.v.natural, &.{
        try e.required(sum_types, e.zero), e.zero,
    }), try c.finish(try c.make(c.input, o.result_schema, e.zero, &.{try e.b.reference(absent)})));
    const selected = try e.call(
        c.collection.cached_item,
        &.{ c.input, o.left, o.view, o.index },
    );
    const present = try c.make(try e.field(try e.b.reference(item), 0), o.result_schema, e.one, &.{
        try e.field(try e.b.reference(item), 1),
    });
    const yes = try e.b.bind(item, selected, try c.finish(present));
    const get = try e.b.bind(o.right_var, o.read_right, try e.b.bind(
        o.index_var,
        o.read_index,
        try e.when(
            try e.binary(.less, o.index, o.count),
            yes,
            no,
        ),
    ));
    body = try e.when(try c.is(o.opcode, .sequence_get), get, body);

    return body;
}

fn emitSequenceTake(o: Operands, body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var body = body_initial;

    const length = try e.b.variable(e.integer);
    const range = try e.b.variable(c.collection.schema);
    const take = try defineTake(
        e,
        c.collection,
        c.input,
        o.result_schema,
        c.program,
        c,
        o.right_var,
        o.view,
        o.count,
        o.index_var,
        o.index,
        o.read_right,
        o.read_index,
        length,
        range,
    );
    body = try e.when(try c.is(o.opcode, .sequence_take), take, body);

    return body;
}

fn emitSequenceSet(o: Operands, body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var body = body_initial;

    const replacement = try e.b.variable(c.v.value);
    const prefix = try e.b.variable(c.collection.schema);
    const suffix = try e.b.variable(c.collection.schema);
    const next = try e.binary(.integer_add, o.index, e.one);
    var set = try c.finish(
        try c.rebuild(
            c.input,
            o.result_schema,
            o.count,
            &.{
                try e.b.reference(prefix),
                try c.singleton(o.element, try e.b.reference(replacement)),
                try e.b.reference(suffix),
            },
        ),
    );
    set = try e.b.bind(suffix, try e.call(c.collection.range, &.{
        c.program, o.view, next, try e.binary(.integer_sub, o.count, next),
    }), set);
    set = try e.b.bind(prefix, try e.call(
        c.collection.range,
        &.{ c.program, o.view, e.zero, o.index },
    ), set);
    set = try e.b.bind(replacement, try e.call(c.m.frames.read, &.{
        o.frame, try e.required(o.operands, try e.b.constant(u64, 2)),
    }), set);
    set = try e.b.bind(o.right_var, o.read_right, try e.b.bind(
        o.index_var,
        o.read_index,
        try e.when(
            try e.binary(.less, o.index, o.count),
            set,
            try c.fault(c.input, .invalid_index),
        ),
    ));
    body = try e.when(try c.is(o.opcode, .sequence_set), set, body);

    return body;
}

fn emitSequencePop(o: Operands, body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var body = body_initial;

    const sum_types = try e.payload(o.shape, @backingInt(p.SchemaTag.sum));
    const pair_type = try e.required(sum_types, e.one);
    const range = try e.b.variable(c.collection.schema);
    const remainder = try e.b.variable(c.v.result);
    const first = try e.b.variable(c.v.result);
    const pair = try e.b.variable(c.v.result);
    const absent = try e.b.variable(c.v.value);
    const length = try e.binary(.integer_sub, o.count, e.one);
    var present = try c.finish(
        try c.make(
            try e.field(try e.b.reference(
                pair,
            ), 0),
            o.result_schema,
            e.one,
            &.{try e.field(try e.b.reference(pair), 1)},
        ),
    );
    present = try emitSequencePopPresent(e, c, pair_type, remainder, first, pair, present);
    present = try e.b.bind(first, try e.call(c.collection.item, &.{
        try e.field(try e.b.reference(remainder), 0), o.view, e.zero,
    }), present);
    present = try e.b.bind(remainder, try c.rebuild(
        c.input,
        try e.field(o.left, 0),
        length,
        &.{try e.b.reference(range)},
    ), present);
    present = try e.b.bind(range, try e.call(
        c.collection.range,
        &.{ c.program, o.view, e.one, length },
    ), present);
    const empty = try e.b.bind(absent, try e.call(c.v.natural, &.{
        try e.required(sum_types, e.zero), e.zero,
    }), try c.finish(try c.make(c.input, o.result_schema, e.zero, &.{try e.b.reference(absent)})));
    body = try e.when(try c.is(o.opcode, .sequence_pop), try e.when(
        try e.binary(.equal, o.count, e.zero),
        empty,
        present,
    ), body);

    return body;
}

fn emitSequencePopLast(o: Operands, body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    var body = body_initial;

    const product_types = try e.payload(o.shape, @backingInt(p.SchemaTag.product));
    const optional_type = try e.required(product_types, e.one);
    const optional_types = try e.payload(
        try e.required(c.shapes, optional_type),
        @backingInt(p.SchemaTag.sum),
    );
    const length = try e.b.variable(e.integer);
    const tag = try e.b.variable(e.integer);
    const range = try e.b.variable(c.collection.schema);
    const remainder = try e.b.variable(c.v.result);
    const item = try e.b.variable(c.v.result);
    const optional = try e.b.variable(c.v.result);
    const absent = try e.b.variable(c.v.value);
    const remaining_machine = try e.field(try e.b.reference(remainder), 0);
    const none = try e.b.bind(absent, try e.call(c.v.natural, &.{
        try e.required(optional_types, e.zero), e.zero,
    }), try e.b.pure(try e.tuple(c.v.result, &.{
        remaining_machine,
        try e.b.reference(absent),
    })));
    const some = try e.call(c.collection.item, &.{
        remaining_machine, o.view, try e.b.reference(length),
    });
    var pop = try popLastPair(e, c, optional, remainder, o.result_schema);
    pop = try emitSequencePopLastPop(e, c, optional_type, tag, item, optional, pop);
    pop = try e.b.bind(item, try e.when(try e.binary(.equal, o.count, e.zero), none, some), pop);
    pop = try e.b.bind(remainder, try c.rebuild(
        c.input,
        try e.field(o.left, 0),
        try e.b.reference(length),
        &.{try e.b.reference(range)},
    ), pop);
    pop = try e.b.bind(range, try e.call(c.collection.range, &.{
        c.program, o.view, e.zero, try e.b.reference(length),
    }), pop);
    pop = try e.b.bind(tag, try e.when(
        try e.binary(.equal, o.count, e.zero),
        try e.b.pure(e.zero),
        try e.b.pure(e.one),
    ), pop);
    pop = try e.b.bind(
        length,
        try e.when(
            try e.binary(.equal, o.count, e.zero),
            try e.b.pure(e.zero),
            try e.b.pure(try e.binary(.integer_sub, o.count, e.one)),
        ),
        pop,
    );
    body = try e.when(try c.is(o.opcode, .sequence_pop_last), pop, body);

    return body;
}

fn emitSequencePopPresent(
    e: Author,
    c: Generator,
    pair_type: Id,
    remainder: Id,
    first: Id,
    pair: Id,
    present: anytype,
) Error!Id {
    return try e.b.bind(
        pair,
        try c.make(
            try e.field(try e.b.reference(
                first,
            ), 0),
            pair_type,
            e.zero,
            &.{
                try e.field(try e.b.reference(
                    first,
                ), 1),
                try e.field(try e.b.reference(
                    remainder,
                ), 1),
            },
        ),
        present,
    );
}

fn emitSequencePopLastPop(
    e: Author,
    c: Generator,
    optional_type: Id,
    tag: Id,
    item: Id,
    optional: Id,
    pop: anytype,
) Error!Id {
    return try e.b.bind(
        optional,
        try c.make(
            try e.field(try e.b.reference(
                item,
            ), 0),
            optional_type,
            try e.b.reference(tag),
            &.{try e.field(try e.b.reference(item), 1)},
        ),
        pop,
    );
}

fn emitSequenceGrowth(o: Operands, body_initial: Id) Error!Id {
    const c = o.c;
    const e = c.e;
    const b = e.b;
    var body = body_initial;
    inline for (.{ p.Opcode.sequence_append, .sequence_concat }) |opcode_kind| {
        const second_var = try b.variable(c.collection.schema);
        const second = try b.reference(second_var);
        const right_count = try e.field(second, 1);
        const total = try e.binary(.integer_add, o.count, right_count);
        const maximum = try b.variable(e.integer);
        const max_value = try b.reference(maximum);
        const vector = try e.binary(.equal, try b.primitive(
            e.integer,
            .variant_tag,
            &.{o.shape},
            0,
        ), try b.constant(u64, @backingInt(p.SchemaTag.vector)));
        const overflow = try e.when(vector, try c.fault(c.input, .capacity_exceeded), try e.fail());
        const finish = try c.finish(try c.rebuild(
            c.input,
            o.result_schema,
            total,
            &.{ o.view, second },
        ));
        const within = try defineWithin(e, o.count, right_count, max_value, overflow, finish);
        const choose_max = try e.when(vector, try b.pure(try e.field(try e.payload(
            o.shape,
            @backingInt(p.SchemaTag.vector),
        ), 1)), try b.pure(try b.constant(
            u64,
            @import("std").math.maxInt(u64),
        )));
        const choose_second = if (opcode_kind == .sequence_concat) try e.call(
            c.collection.view,
            &.{ c.input, o.right },
        ) else try b.pure(try c.singleton(o.element, o.right));
        const operation = try b.bind(o.right_var, o.read_right, try b.bind(
            second_var,
            choose_second,
            try b.bind(maximum, choose_max, within),
        ));
        body = try e.when(try c.is(o.opcode, opcode_kind), operation, body);
    }
    return body;
}

const Operands = struct {
    c: Generator,
    frame: Id,
    result_schema: Id,
    opcode: Id,
    operands: Id,
    left: Id,
    right_var: Id,
    right: Id,
    view: Id,
    count: Id,
    element: Id,
    shape: Id,
    index_var: Id,
    index: Id,
    read_right: Id,
    read_index: Id,
};

fn emitEvaluation(
    c: Generator,
    d: Definition,
    codec: codecs.Definition,
    frame: Id,
    instruction: Id,
    result_schema: Id,
) Error!void {
    const e = c.e;
    const b = e.b;
    const opcode = try field(e, instruction, data.activation.Instruction, "opcode");
    const operands = try field(e, instruction, data.activation.Instruction, "operands");
    const left_var = try b.variable(c.v.value);
    const left = try b.reference(left_var);
    const right_var = try b.variable(c.v.value);
    const right = try b.reference(right_var);
    const view_var = try b.variable(c.collection.schema);
    const view = try b.reference(view_var);
    const count = try e.field(view, 1);
    const element = try e.field(view, 0);
    const shape = try e.required(c.shapes, result_schema);
    const index_var = try b.variable(e.integer);
    const index = try b.reference(index_var);
    const read_right = try e.call(c.m.frames.read, &.{ frame, try e.required(operands, e.one) });
    const read_index = try e.call(codec.fixed, &.{try e.payload(try e.field(right, 1), 0)});
    const o: Operands = .{
        .c = c,
        .frame = frame,
        .result_schema = result_schema,
        .opcode = opcode,
        .operands = operands,
        .left = left,
        .right_var = right_var,
        .right = right,
        .view = view,
        .count = count,
        .element = element,
        .shape = shape,
        .index_var = index_var,
        .index = index,
        .read_right = read_right,
        .read_index = read_index,
    };
    var body = try e.fail();
    {
        const natural = try b.variable(c.v.value);
        const length = try b.bind(natural, try e.call(
            c.v.natural,
            &.{ result_schema, count },
        ), try c.success(c.input, try b.reference(natural)));
        body = try e.when(try c.is(opcode, .sequence_length), length, body);
    }
    body = try emitSequenceGet(o, body);
    body = try emitSequenceGrowth(o, body);
    body = try emitSequenceTake(o, body);
    body = try emitSequenceSet(o, body);
    body = try emitSequencePop(o, body);
    body = try emitSequencePopLast(o, body);
    try b.define(d.evaluate, try b.bind(left_var, try e.call(c.m.frames.read, &.{
        frame, try e.required(operands, e.zero),
    }), try b.bind(view_var, try e.call(c.collection.view, &.{ c.input, left }), body)));
}

fn popLastPair(e: Author, c: Generator, optional: Id, remainder: Id, result_schema: Id) Error!Id {
    return c.finish(
        try c.make(
            try e.field(try e.b.reference(
                optional,
            ), 0),
            result_schema,
            e.zero,
            &.{
                try e.field(try e.b.reference(
                    remainder,
                ), 1),
                try e.field(try e.b.reference(
                    optional,
                ), 1),
            },
        ),
    );
}
