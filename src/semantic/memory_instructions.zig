//! Computation environments, cells, packages and resources are guest graph data.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const values = @import("values.zig");
const graphs = @import("graph.zig");
const access = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const p = data.program;
const field = access.field;

pub const Definition = struct { evaluate: Id, result: Id };
pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(
        Definition,
        "kosmos.semantic.memory_instructions/1",
        m.schema,
    );
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const edge = try access.define(b, m);
    const v = try values.define(b, m);
    const captures = try @import("captures.zig").define(b, m);
    const outcome = try projection.schema(values.Outcome, b);
    const result = try b.schema(.{ .product = &.{ m.schema, outcome } });
    const d: Definition = .{ .evaluate = try b.declare(&.{
        m.schema, m.frames.schema, try projection.schema(data.activation.Instruction, b), e.integer,
    }, result, &.{}, &.{}), .result = result };
    var emission: MemoryBuilder = .{
        .e = e,
        .graph = graph,
        .edge = edge,
        .v = v,
        .captures = captures,
        .outcome = outcome,
        .result = result,
        .d = d,
        .b = b,
        .m = m,
    };
    try emission.emitInputs();
    try emission.emitCreationResult();
    try emission.emitCloneDispatch();
    try emission.emitPackageDispatch();
    try emission.emitComputationDispatch();
    try emission.emitCellCreationDispatch();
    try emission.emitReadDispatch();
    try emission.emitCellWriteDispatch();
    return cache.finish(b, d);
}
fn is(e: Author, opcode: Id, expected: p.Opcode) Error!Id {
    const tag = try e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{opcode}, 0);
    return e.binary(.equal, tag, try e.b.constant(u32, @backingInt(expected)));
}

fn defineBody(
    e: Author,
    graph: anytype,
    captures: anytype,
    input: Id,
    left_var: Id,
    left: Id,
    created: Id,
    finish_created: Id,
    left_read: Id,
    taken: Id,
    token: Id,
) Error!Id {
    return try e.b.bind(
        left_var,
        left_read,
        try e.b.bind(
            taken,
            try e.call(captures.take, &.{
                input,
                left,
            }),
            try e.b.bind(
                created,
                try e.call(graph.template, &.{ try e.field(try e.b.reference(taken), 0), token }),
                finish_created,
            ),
        ),
    );
}

const MemoryBuilder = struct {
    e: Author,
    graph: graphs.Definition,
    edge: access.Definition,
    v: values.Definition,
    captures: @import("captures.zig").Definition,
    outcome: Id,
    result: Id,
    d: Definition,
    b: *source.Builder,
    m: machines.Definition,
    input: Id = undefined,
    frame: Id = undefined,
    instruction: Id = undefined,
    result_schema: Id = undefined,
    program: Id = undefined,
    operands: Id = undefined,
    opcode: Id = undefined,
    left_var: Id = undefined,
    right_var: Id = undefined,
    left: Id = undefined,
    right: Id = undefined,
    reference: Id = undefined,
    ref: Id = undefined,
    saved_var: Id = undefined,
    saved: Id = undefined,
    created: Id = undefined,
    new_ref: Id = undefined,
    produced: Id = undefined,
    finish: Id = undefined,
    finish_created: Id = undefined,
    left_read: Id = undefined,
    right_read: Id = undefined,
    dispatch: Id = undefined,

    fn emitInputs(self: *MemoryBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        self.input = try e.param(self.d.evaluate, 0);
        self.frame = try e.param(self.d.evaluate, 1);
        self.instruction = try e.param(self.d.evaluate, 2);
        self.result_schema = try e.param(self.d.evaluate, 3);
        self.program = try self.m.field(e, self.input, .program);
        self.operands = try field(e, self.instruction, data.activation.Instruction, "operands");
        self.opcode = try field(e, self.instruction, data.activation.Instruction, "opcode");
        self.left_var = try b.variable(self.v.value);
        self.right_var = try b.variable(self.v.value);
        self.left = try b.reference(self.left_var);
        self.right = try b.reference(self.right_var);
        self.reference = try b.variable(try projection.schema(g.NodeRef, b));
        self.ref = try b.reference(self.reference);
        self.saved_var = try b.variable(try projection.schema(g.Node, b));
        self.saved = try b.reference(self.saved_var);
        self.created = try b.variable(self.graph.appended);
        const changed = try e.field(try b.reference(self.created), 0);
        self.new_ref = try e.field(try b.reference(self.created), 1);
        self.produced = try b.variable(self.v.value);
        self.finish = try b.pure(try e.tuple(self.result, &.{ changed, try e.variant(
            self.outcome,
            0,
            try b.reference(self.produced),
        ) }));
    }

    fn emitCreationResult(self: *MemoryBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        const copy = try e.required(try field(e, try field(
            e,
            self.program,
            projection.Program,
            "uses",
        ), data.traits.Facts, "copy"), self.result_schema);
        const wrap = try e.when(copy, try b.pure(
            try graphs.value(e, self.result_schema, self.new_ref, false),
        ), try b.pure(try graphs.value(e, self.result_schema, self.new_ref, true)));
        self.finish_created = try b.bind(self.produced, wrap, self.finish);
        self.left_read = try e.call(self.m.frames.read, &.{
            self.frame, try e.required(self.operands, e.zero),
        });
        self.right_read = try e.call(self.m.frames.read, &.{
            self.frame, try e.required(self.operands, e.one),
        });
        self.dispatch = try e.fail();
    }

    fn emitCloneDispatch(self: *MemoryBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        {
            const taken = try b.variable(self.captures.taken);
            const token = try e.replace(
                try e.field(try b.reference(taken), 1),
                machines.index(g.Capture, "schema"),
                self.result_schema,
            );
            const body = try defineBody(
                e,
                self.graph,
                self.captures,
                self.input,
                self.left_var,
                self.left,
                self.created,
                self.finish_created,
                self.left_read,
                taken,
                token,
            );
            self.dispatch = try e.when(
                try is(e, self.opcode, .clone_resumption),
                body,
                self.dispatch,
            );
        }
    }

    fn emitPackageDispatch(self: *MemoryBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        inline for ([_]p.Opcode{ .package, .resource_pack }) |kind| {
            const record = try graphs.record(
                e,
                if (kind == .package) .package else .resource,
                &.{ self.result_schema, self.left },
            );
            const body = try b.bind(self.left_var, self.left_read, try b.bind(
                self.created,
                try e.call(self.graph.append, &.{ self.input, record }),
                self.finish_created,
            ));
            self.dispatch = try e.when(try is(e, self.opcode, kind), body, self.dispatch);
        }
    }

    fn emitComputationDispatch(self: *MemoryBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        {
            const fields = try b.variable(try projection.schema([]const g.Value, b));
            const environment = try b.variable(self.graph.appended);
            const environment_record = try graphs.record(e, .environment, &.{
                try b.reference(fields), try e.literal(?g.NodeRef, null),
            });
            const closure = try graphs.record(e, .computation, &.{ try field(
                e,
                self.instruction,
                data.activation.Instruction,
                "immediate",
            ), try e.field(try b.reference(environment), 1) });
            const body = try b.bind(fields, try e.call(
                self.edge.collect,
                &.{ self.frame, self.operands },
            ), try b.bind(environment, try e.call(
                self.graph.append,
                &.{ self.input, environment_record },
            ), try b.bind(self.created, try e.call(self.graph.append, &.{
                try e.field(try b.reference(environment), 0), closure,
            }), self.finish_created)));
            self.dispatch = try e.when(try is(e, self.opcode, .computation), body, self.dispatch);
        }
    }

    fn emitCellCreationDispatch(self: *MemoryBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        {
            const record = try graphs.record(e, .cell, &.{
                self.result_schema, self.ref,
                try e.variant(
                    try projection.schema(?g.Value, b),
                    1,
                    self.right,
                ),
            });
            const body = try b.bind(
                self.left_var,
                self.left_read,
                try b.bind(
                    self.right_var,
                    self.right_read,
                    try b.bind(
                        self.reference,
                        try e.call(self.graph.value_ref, &.{
                            self.left,
                        }),
                        try b.bind(
                            self.created,
                            try e.call(self.graph.append, &.{ self.input, record }),
                            self.finish_created,
                        ),
                    ),
                ),
            );
            self.dispatch = try e.when(try is(e, self.opcode, .cell_new), body, self.dispatch);
        }
    }

    fn emitReadDispatch(self: *MemoryBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        inline for ([_]p.Opcode{ .cell_get, .unpack, .resource_unpack }) |kind| {
            var returned: Id = undefined;
            if (kind == .resource_unpack) {
                const resource = try b.variable(try projection.schema(g.Node, b));
                const indirect = try e.call(self.graph.record, &.{
                    self.input,
                    try e.field(try e.payload(
                        self.saved,
                        @backingInt(g.NodeTag.borrow),
                    ), 1),
                });
                const select = try e.when(try e.binary(.equal, try b.primitive(
                    e.integer,
                    .variant_tag,
                    &.{self.saved},
                    0,
                ), try b.constant(u64, @backingInt(g.NodeTag.borrow))), indirect, try b.pure(
                    self.saved,
                ));
                const value = try e.field(try e.payload(
                    try b.reference(resource),
                    @backingInt(g.NodeTag.resource),
                ), 1);
                returned = try b.bind(resource, select, try b.pure(try e.tuple(self.result, &.{
                    self.input, try e.variant(self.outcome, 0, value),
                })));
            } else {
                const value = if (kind == .cell_get) try e.payload(try e.field(
                    try e.payload(self.saved, @backingInt(g.NodeTag.cell)),
                    2,
                ), 1) else try e.field(try e.payload(
                    self.saved,
                    @backingInt(g.NodeTag.package),
                ), 1);
                returned = try b.pure(try e.tuple(self.result, &.{
                    self.input, try e.variant(self.outcome, 0, value),
                }));
            }
            const body = try b.bind(
                self.left_var,
                self.left_read,
                try b.bind(
                    self.reference,
                    try e.call(self.graph.value_ref, &.{
                        self.left,
                    }),
                    try b.bind(
                        self.saved_var,
                        try e.call(self.graph.record, &.{ self.input, self.ref }),
                        returned,
                    ),
                ),
            );
            self.dispatch = try e.when(try is(e, self.opcode, kind), body, self.dispatch);
        }
    }

    fn emitCellWriteDispatch(self: *MemoryBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        {
            const machine = try b.variable(self.m.schema);
            const unit = try b.variable(self.v.value);
            const cell = try e.replace(
                try e.payload(self.saved, @backingInt(
                    g.NodeTag.cell,
                )),
                2,
                try e.variant(try projection.schema(?g.Value, b), 1, self.right),
            );
            const record_type = try projection.schema(g.Node, b);
            const updated = try e.variant(record_type, @backingInt(g.NodeTag.cell), cell);
            const finish_set = try b.bind(machine, try e.call(
                self.graph.replace,
                &.{ self.input, self.ref, updated },
            ), try b.bind(unit, try e.call(
                self.v.natural,
                &.{ self.result_schema, e.zero },
            ), try b.pure(try e.tuple(self.result, &.{
                try b.reference(machine), try e.variant(self.outcome, 0, try b.reference(unit)),
            }))));
            const body = try b.bind(
                self.left_var,
                self.left_read,
                try b.bind(
                    self.right_var,
                    self.right_read,
                    try b.bind(
                        self.reference,
                        try e.call(self.graph.value_ref, &.{
                            self.left,
                        }),
                        try b.bind(
                            self.saved_var,
                            try e.call(self.graph.record, &.{ self.input, self.ref }),
                            finish_set,
                        ),
                    ),
                ),
            );
            self.dispatch = try e.when(try is(e, self.opcode, .cell_set), body, self.dispatch);
        }
        try b.define(self.d.evaluate, self.dispatch);
    }
};
