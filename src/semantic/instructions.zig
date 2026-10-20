//! Guest instruction evaluation. The evolving machine and guest fault are
//! explicit ordinary values; native guest execution is never called here.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const values = @import("values.zig");
const scalar = @import("scalar.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;

pub const Outcome = values.Outcome;
pub const Definition = struct { evaluate: Id, result: Id, outcome: Id };

pub fn define(b: *source.Builder, machine: machines.Definition) Error!Definition {
    const cache = try b.specialization(
        Definition,
        "kosmos.semantic.instructions/1",
        machine.schema,
    );
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const ordinary = try values.define(b, machine);
    const scalars = try scalar.define(b);
    const aggregate = try @import("aggregate.zig").define(b, machine);
    const edges = try @import("edges.zig").define(b, machine);
    const collection = try @import("collection_instructions.zig").define(b, machine);
    const memory = try @import("memory_instructions.zig").define(b, machine);
    const blobs = try @import("blob_instructions.zig").define(b, machine);
    const instruction = try projection.schema(data.activation.Instruction, b);
    const outcome = try projection.schema(Outcome, b);
    const result = try b.schema(.{ .product = &.{ machine.schema, outcome } });
    const d: Definition = .{
        .evaluate = try b.declare(&.{
            machine.schema,                       machine.frames.schema, instruction, e.integer,
            try projection.schema([]const Id, b), e.boolean,
        }, result, &.{}, &.{}),
        .result = result,
        .outcome = outcome,
    };

    var emission: EvaluationBuilder = .{
        .e = e,
        .ordinary = ordinary,
        .scalars = scalars,
        .aggregate = aggregate,
        .edges = edges,
        .collection = collection,
        .memory = memory,
        .blobs = blobs,
        .outcome = outcome,
        .result = result,
        .d = d,
        .b = b,
        .machine = machine,
    };
    try emission.emitOperands();
    try emission.emitScalarResult();
    try emission.emitScalarOperations();
    try emission.emitRawOperations();
    try emission.emitScalarDispatch();
    try emission.emitLiteralDispatch();
    try emission.emitAggregateDispatch();
    try emission.emitVariantDispatch();
    try emission.emitSelectionDispatch();
    try emission.emitCollectionDispatch();
    try emission.emitMemoryDispatch();
    try emission.emitBlobDispatch();
    return cache.finish(b, d);
}

pub fn is(e: Author, opcode: Id, expected: data.program.Opcode) Error!Id {
    const tag = try e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{opcode}, 0);
    return e.binary(.equal, tag, try e.b.constant(u32, @backingInt(expected)));
}

fn defineBinary(
    e: Author,
    scalars: anytype,
    opcode: Id,
    left: Id,
    right: Id,
    scalar_result: Id,
    finish_scalar: Id,
    left_schema: Id,
    left_bytes: Id,
    right_bytes: Id,
    read_left: Id,
    read_right: Id,
) Error!Id {
    return try e.b.bind(
        left,
        read_left,
        try e.b.bind(
            right,
            read_right,
            try e.b.bind(
                scalar_result,
                try e.call(scalars.binary, &.{
                    opcode,
                    left_schema,
                    left_bytes,
                    right_bytes,
                }),
                finish_scalar,
            ),
        ),
    );
}

fn defineRawFinish(
    e: Author,
    outcome: Id,
    result: Id,
    input: Id,
    result_type: Id,
    fault: Id,
    raw_result: Id,
    raw_bits: Id,
    raw_scalar: Id,
) Error!Id {
    return try e.b.term(
        .{
            .match_sum = .{
                .value = try e.b.reference(raw_result),
                .cases = &.{
                    .{
                        .variable = raw_bits,
                        .body = try e.b.pure(
                            try e.tuple(
                                result,
                                &.{
                                    input,
                                    try e.variant(
                                        outcome,
                                        2,
                                        try e.tuple(
                                            raw_scalar,
                                            &.{ result_type, try e.b.reference(raw_bits) },
                                        ),
                                    ),
                                },
                            ),
                        ),
                    },
                    .{ .variable = fault, .body = try e.b.pure(try e.tuple(result, &.{
                        input, try e.variant(outcome, 1, try e.b.reference(fault)),
                    })) },
                },
            },
        },
    );
}

fn defineRawBinary(
    machine: machines.Definition,
    e: Author,
    scalars: anytype,
    frame: Id,
    opcode: Id,
    operands: Id,
    left_schema: Id,
    raw_left: Id,
    raw_right: Id,
    raw_result: Id,
    raw_finish: Id,
    raw_read_left: Id,
) Error!Id {
    return try e.b.bind(
        raw_left,
        raw_read_left,
        try e.b.bind(
            raw_right,
            try e.call(machine.frames.read_raw, &.{
                frame,
                try e.required(operands, e.one),
            }),
            try e.b.bind(raw_result, try e.call(scalars.binary_raw, &.{
                opcode, left_schema, try e.b.reference(raw_left), try e.b.reference(raw_right),
            }), raw_finish),
        ),
    );
}

fn defineRawUnary(
    e: Author,
    scalars: anytype,
    result_type: Id,
    opcode: Id,
    schemas: Id,
    left_schema: Id,
    raw_left: Id,
    raw_result: Id,
    raw_finish: Id,
    raw_read_left: Id,
) Error!Id {
    return try e.b.bind(
        raw_left,
        raw_read_left,
        try e.b.bind(
            raw_result,
            try e.call(
                scalars.unary_raw,
                &.{
                    opcode,                               left_schema,
                    try e.required(schemas, result_type), try e.b.reference(raw_left),
                },
            ),
            raw_finish,
        ),
    );
}

fn defineLiteral(
    e: Author,
    ordinary: anytype,
    outcome: Id,
    result: Id,
    input: Id,
    literal_result: Id,
    constant: Id,
) Error!Id {
    return try e.b.bind(literal_result, try e.call(
        ordinary.literal,
        &.{ input, constant },
    ), try e.b.pure(
        try e.tuple(
            result,
            &.{
                try e.field(try e.b.reference(
                    literal_result,
                ), 0),
                try e.variant(outcome, 0, try e.field(try e.b.reference(literal_result), 1)),
            },
        ),
    ));
}

fn defineSuccess(e: Author, outcome: Id, result: Id, produced_value: Id) Error!Id {
    return try e.b.pure(
        try e.tuple(
            result,
            &.{
                try e.field(produced_value, 0),
                try e.variant(outcome, 0, try e.field(produced_value, 1)),
            },
        ),
    );
}

fn defineVariantTag(
    e: Author,
    ordinary: anytype,
    outcome: Id,
    result: Id,
    input: Id,
    result_type: Id,
    left: Id,
    read_left: Id,
    tag: Id,
    tag_result: Id,
    read_tag: Id,
) Error!Id {
    return try e.b.bind(
        left,
        read_left,
        try e.b.bind(
            tag,
            read_tag,
            try e.b.bind(
                tag_result,
                try e.call(ordinary.natural, &.{
                    result_type,
                    try e.b.reference(tag),
                }),
                try e.b.pure(try e.tuple(result, &.{ input, try e.variant(
                    outcome,
                    0,
                    try e.b.reference(tag_result),
                ) })),
            ),
        ),
    );
}

fn defineMismatch(e: Author, outcome: Id, result: Id, input: Id) Error!Id {
    return try e.b.pure(
        try e.tuple(
            result,
            &.{
                input,
                try e.variant(outcome, 1, try e.literal(data.program.Fault, .invalid_variant)),
            },
        ),
    );
}

fn defineSelected(
    machine: machines.Definition,
    e: Author,
    outcome: Id,
    result: Id,
    input: Id,
    frame: Id,
    operands: Id,
    left: Id,
    right: Id,
    r: Id,
    read_left: Id,
    selected_slot: Id,
    condition: Id,
) Error!Id {
    return try e.b.bind(
        left,
        read_left,
        try e.b.bind(
            selected_slot,
            try e.when(
                condition,
                try e.b.pure(try e.required(
                    operands,
                    e.one,
                )),
                try e.b.pure(try e.required(operands, try e.b.constant(u64, 2))),
            ),
            try e.b.bind(right, try e.call(machine.frames.read, &.{
                frame, try e.b.reference(selected_slot),
            }), try e.b.pure(try e.tuple(result, &.{
                input,
                try e.variant(outcome, 0, r),
            }))),
        ),
    );
}

const EvaluationBuilder = struct {
    e: Author,
    ordinary: values.Definition,
    scalars: scalar.Definition,
    aggregate: @import("aggregate.zig").Definition,
    edges: @import("edges.zig").Definition,
    collection: @import("collection_instructions.zig").Definition,
    memory: @import("memory_instructions.zig").Definition,
    blobs: @import("blob_instructions.zig").Definition,
    outcome: Id,
    result: Id,
    d: Definition,
    b: *source.Builder,
    machine: machines.Definition,
    input: Id = undefined,
    frame: Id = undefined,
    code: Id = undefined,
    result_type: Id = undefined,
    layout: Id = undefined,
    virtualize: Id = undefined,
    opcode: Id = undefined,
    operands: Id = undefined,
    schemas: Id = undefined,
    literals: Id = undefined,
    left: Id = undefined,
    right: Id = undefined,
    l: Id = undefined,
    r: Id = undefined,
    scalar_result: Id = undefined,
    fault: Id = undefined,
    finish_scalar: Id = undefined,
    left_schema: Id = undefined,
    left_bytes: Id = undefined,
    right_bytes: Id = undefined,
    read_left: Id = undefined,
    read_right: Id = undefined,
    binary: Id = undefined,
    unary: Id = undefined,
    raw_binary: Id = undefined,
    raw_unary: Id = undefined,
    body: Id = undefined,
    produced: Id = undefined,
    success: Id = undefined,
    immediate: Id = undefined,

    fn emitOperands(self: *EvaluationBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        self.input = try e.param(self.d.evaluate, 0);
        self.frame = try e.param(self.d.evaluate, 1);
        self.code = try e.param(self.d.evaluate, 2);
        self.result_type = try e.param(self.d.evaluate, 3);
        self.layout = try e.param(self.d.evaluate, 4);
        self.virtualize = try e.param(self.d.evaluate, 5);
        self.opcode = try e.field(self.code, machines.index(data.activation.Instruction, "opcode"));
        self.operands = try e.field(self.code, machines.index(
            data.activation.Instruction,
            "operands",
        ));
        const program = try e.field(
            try self.machine.field(e, self.input, .program),
            machines.index(projection.Program, "code"),
        );
        self.schemas = try e.field(program, machines.index(data.activation.Program, "schemas"));
        self.literals = try e.field(program, machines.index(data.activation.Program, "constants"));
        self.left = try b.variable(self.ordinary.value);
        self.right = try b.variable(self.ordinary.value);
        self.l = try b.reference(self.left);
        self.r = try b.reference(self.right);
    }

    fn emitScalarResult(self: *EvaluationBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        self.scalar_result = try b.variable(self.scalars.result);
        const scalar_bytes = try b.variable(try projection.schema([8]u8, b));
        self.fault = try b.variable(try projection.schema(data.program.Fault, b));
        const body_type = b.schemas.items[@intCast(self.ordinary.value)].product[1];
        const wrapped_scalar = try e.tuple(self.ordinary.value, &.{ self.result_type, try e.variant(
            body_type,
            0,
            try b.reference(scalar_bytes),
        ) });
        self.finish_scalar = try b.term(.{ .match_sum = .{
            .value = try b.reference(self.scalar_result),
            .cases = &.{
                .{ .variable = scalar_bytes, .body = try b.pure(try e.tuple(self.result, &.{
                    self.input, try e.variant(self.outcome, 0, wrapped_scalar),
                })) },
                .{ .variable = self.fault, .body = try b.pure(try e.tuple(self.result, &.{
                    self.input, try e.variant(self.outcome, 1, try b.reference(self.fault)),
                })) },
            },
        } });
        self.left_schema = try e.required(self.schemas, try e.required(
            self.layout,
            try e.required(self.operands, e.zero),
        ));
        self.left_bytes = try e.payload(try e.field(self.l, 1), 0);
        self.right_bytes = try e.payload(try e.field(self.r, 1), 0);
        self.read_left = try e.call(self.machine.frames.read, &.{
            self.frame, try e.required(self.operands, e.zero),
        });
        self.read_right = try e.call(self.machine.frames.read, &.{
            self.frame, try e.required(self.operands, e.one),
        });
    }

    fn emitScalarOperations(self: *EvaluationBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        self.binary = try defineBinary(
            e,
            self.scalars,
            self.opcode,
            self.left,
            self.right,
            self.scalar_result,
            self.finish_scalar,
            self.left_schema,
            self.left_bytes,
            self.right_bytes,
            self.read_left,
            self.read_right,
        );
        self.unary = try b.bind(
            self.left,
            self.read_left,
            try b.bind(
                self.scalar_result,
                try e.call(
                    self.scalars.unary,
                    &.{
                        self.opcode,                                    self.left_schema,
                        try e.required(self.schemas, self.result_type), self.left_bytes,
                    },
                ),
                self.finish_scalar,
            ),
        );
    }

    fn emitRawOperations(self: *EvaluationBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        const raw_left = try b.variable(e.integer);
        const raw_right = try b.variable(e.integer);
        const raw_result = try b.variable(self.scalars.raw_result);
        const raw_bits = try b.variable(e.integer);
        const raw_scalar = try projection.schema(@import("frames.zig").Scalar, b);
        const raw_finish = try defineRawFinish(
            e,
            self.outcome,
            self.result,
            self.input,
            self.result_type,
            self.fault,
            raw_result,
            raw_bits,
            raw_scalar,
        );
        const raw_read_left = try e.call(self.machine.frames.read_raw, &.{
            self.frame, try e.required(self.operands, e.zero),
        });
        self.raw_binary = try defineRawBinary(
            self.machine,
            e,
            self.scalars,
            self.frame,
            self.opcode,
            self.operands,
            self.left_schema,
            raw_left,
            raw_right,
            raw_result,
            raw_finish,
            raw_read_left,
        );
        self.raw_unary = try defineRawUnary(
            e,
            self.scalars,
            self.result_type,
            self.opcode,
            self.schemas,
            self.left_schema,
            raw_left,
            raw_result,
            raw_finish,
            raw_read_left,
        );
    }

    fn emitScalarDispatch(self: *EvaluationBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        self.body = try e.fail();
        inline for (.{
            data.program.Opcode.integer_add,
            .integer_sub,
            .integer_mul,
            .integer_div,
            .integer_rem,
            .integer_bit_and,
            .integer_bit_or,
            .integer_bit_xor,
            .equal,
            .less,
        }) |kind|
            self.body = try e.when(
                try is(e, self.opcode, kind),
                try e.when(self.virtualize, self.raw_binary, self.binary),
                self.body,
            );
        inline for (.{
            data.program.Opcode.integer_bit_not, .integer_convert, .enum_tag, .boolean_not,
        }) |kind|
            self.body = try e.when(
                try is(e, self.opcode, kind),
                try e.when(self.virtualize, self.raw_unary, self.unary),
                self.body,
            );
        const moved = try b.bind(self.left, self.read_left, try b.pure(try e.tuple(self.result, &.{
            self.input, try e.variant(self.outcome, 0, self.l),
        })));
        self.body = try e.when(try is(e, self.opcode, .move), moved, self.body);
    }

    fn emitLiteralDispatch(self: *EvaluationBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        const literal_result = try b.variable(self.ordinary.result);
        const constant = try e.required(self.literals, try e.field(self.code, machines.index(
            data.activation.Instruction,
            "immediate",
        )));
        const literal = try defineLiteral(
            e,
            self.ordinary,
            self.outcome,
            self.result,
            self.input,
            literal_result,
            constant,
        );
        self.body = try e.when(try is(e, self.opcode, .constant), literal, self.body);
    }

    fn emitAggregateDispatch(self: *EvaluationBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        self.produced = try b.variable(self.ordinary.result);
        const produced_value = try b.reference(self.produced);
        self.success = try defineSuccess(e, self.outcome, self.result, produced_value);
        self.immediate = try e.field(self.code, machines.index(
            data.activation.Instruction,
            "immediate",
        ));
        const children = try b.variable(try projection.schema([]const data.graph.Value, b));
        const construct = try b.bind(children, try e.call(
            self.edges.collect,
            &.{ self.frame, self.operands },
        ), try b.bind(self.produced, try e.call(self.aggregate.construct, &.{
            self.input, self.result_type, self.immediate, try b.reference(children),
        }), self.success));
        inline for (.{ data.program.Opcode.product, .variant, .sequence }) |kind|
            self.body = try e.when(try is(e, self.opcode, kind), construct, self.body);
        const project_field = try b.bind(
            self.left,
            self.read_left,
            try b.bind(self.produced, try e.call(
                self.aggregate.field,
                &.{ self.input, self.l, self.immediate },
            ), self.success),
        );
        self.body = try e.when(try is(e, self.opcode, .field), project_field, self.body);
    }

    fn emitVariantDispatch(self: *EvaluationBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        const tag = try b.variable(e.integer);
        const tag_result = try b.variable(self.ordinary.value);
        const read_tag = try e.call(self.aggregate.tag, &.{ self.input, self.l });
        const variant_tag = try defineVariantTag(
            e,
            self.ordinary,
            self.outcome,
            self.result,
            self.input,
            self.result_type,
            self.left,
            self.read_left,
            tag,
            tag_result,
            read_tag,
        );
        self.body = try e.when(try is(e, self.opcode, .variant_tag), variant_tag, self.body);
        const mismatch = try defineMismatch(e, self.outcome, self.result, self.input);
        const payload = try b.bind(
            self.left,
            self.read_left,
            try b.bind(tag, read_tag, try e.when(try e.binary(
                .equal,
                try b.reference(tag),
                self.immediate,
            ), try b.bind(
                self.produced,
                try e.call(self.aggregate.payload, &.{ self.input, self.l }),
                self.success,
            ), mismatch)),
        );
        self.body = try e.when(try is(e, self.opcode, .variant_payload), payload, self.body);
    }

    fn emitSelectionDispatch(self: *EvaluationBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        const selected_slot = try b.variable(e.integer);
        const condition = try e.binary(
            .equal,
            try e.required(self.left_bytes, e.zero),
            try b.constant(u8, 1),
        );
        const selected = try defineSelected(
            self.machine,
            e,
            self.outcome,
            self.result,
            self.input,
            self.frame,
            self.operands,
            self.left,
            self.right,
            self.r,
            self.read_left,
            selected_slot,
            condition,
        );
        self.body = try e.when(try is(e, self.opcode, .select), selected, self.body);
    }

    fn emitCollectionDispatch(self: *EvaluationBuilder) Error!void {
        const e = self.e;
        inline for (.{
            data.program.Opcode.sequence_length,
            .sequence_get,
            .sequence_append,
            .sequence_concat,
            .sequence_pop,
            .sequence_set,
            .sequence_take,
            .sequence_pop_last,
        }) |kind|
            self.body = try e.when(try is(e, self.opcode, kind), try e.call(
                self.collection.evaluate,
                &.{ self.input, self.frame, self.code, self.result_type },
            ), self.body);
    }

    fn emitMemoryDispatch(self: *EvaluationBuilder) Error!void {
        const e = self.e;
        inline for (.{
            data.program.Opcode.computation,
            .cell_new,
            .cell_get,
            .cell_set,
            .package,
            .unpack,
            .resource_pack,
            .resource_unpack,
            .clone_resumption,
        }) |kind|
            self.body = try e.when(try is(e, self.opcode, kind), try e.call(
                self.memory.evaluate,
                &.{ self.input, self.frame, self.code, self.result_type },
            ), self.body);
    }

    fn emitBlobDispatch(self: *EvaluationBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        inline for (.{
            data.program.Opcode.blob_length,
            .blob_concat,
            .blob_slice,
            .blob_compare,
            .blob_byte,
            .text_scalar,
            .text_integer,
            .blob_from_byte,
        }) |kind|
            self.body = try e.when(try is(e, self.opcode, kind), try e.call(
                self.blobs.evaluate,
                &.{ self.input, self.frame, self.code, self.result_type },
            ), self.body);
        try b.define(self.d.evaluate, self.body);
    }
};
