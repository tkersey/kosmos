//! Staged instruction transitions. A successful result commits one guest work
//! unit; a fault leaves failure/unwind selection to the enclosing guest rule.
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const instructions = @import("instructions.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;

pub const Definition = struct {
    instruction: Id,
    instruction_at: Id,
    control: Id,
    active: Id,
    result: Id,
};

pub fn define(b: *source.Builder, machine: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.step/1", machine.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const evaluate = try instructions.define(b, machine);
    const fault_type = try projection.schema(data.program.Fault, b);
    const failed = try b.schema(.{ .product = &.{ machine.schema, fault_type } });
    const result = try b.schema(.{ .sum = &.{ machine.schema, failed } });
    const ids = try projection.schema([]const Id, b);
    const flags = try projection.schema([]const bool, b);
    const instruction_schema = try projection.schema(data.activation.Instruction, b);
    const d: Definition = .{
        .instruction = try b.declare(&.{machine.schema}, result, &.{}, &.{}),
        .instruction_at = try b.declare(&.{
            machine.schema, e.integer, instruction_schema, ids, e.integer, ids, flags, e.boolean,
        }, result, &.{}, &.{}),
        .control = try b.declare(&.{machine.schema}, result, &.{}, &.{}),
        .active = try b.declare(&.{machine.schema}, result, &.{}, &.{}),
        .result = result,
    };
    const controls = try @import("control.zig").define(b, machine);
    var emission: TransitionBuilder = .{
        .e = e,
        .evaluate = evaluate,
        .fault_type = fault_type,
        .result = result,
        .d = d,
        .controls = controls,
        .b = b,
        .machine = machine,
    };
    try emission.emitInstructionInput();
    try emission.emitFrameAdvance();
    try emission.emitRetainedSuccess();
    try emission.emitOperandConsumption();
    try emission.emitFailureRule();
    try emission.emitFailureLiteral();
    try emission.emitDispatch();
    return cache.finish(b, d);
}

fn emitBlobRetention(e: Author, machine: machines.Definition) Error!Id {
    const b = e.b;
    const slots = machine.frames.slots;
    const aliases = try b.declare(&.{ slots.tree, e.integer }, e.boolean, &.{}, &.{});
    try emitAliases(e, slots, aliases);
    const entry = try b.declare(&.{
        machine.schema, machine.frames.schema, machine.frames.schema, e.integer, machine.schema,
    }, machine.schema, &.{}, &.{});
    const before = try e.param(entry, 0);
    const next = try e.param(entry, 4);
    const value = try b.variable(try projection.schema(data.graph.Value, b));
    const blob_id = try e.field(try e.payload(
        try e.field(try b.reference(value), 1),
        @backingInt(data.graph.ValueTag.blob),
    ), 0);
    const blob = try b.variable(machine.blobs.optional);
    const bytes = try e.field(
        try e.payload(try b.reference(blob), 1),
        machines.index(data.graph.Blob, "bytes"),
    );
    const length = try b.primitive(e.integer, .blob_length, &.{bytes}, 0);
    const live = try b.variable(e.boolean);
    const collector = try @import("collect.zig").define(b, machine);
    const retain = try b.pure(next);
    const collect = try emitBlobRetentionCollect(
        e,

        aliases,
        entry,
        next,
        blob_id,
        live,
        collector,
        retain,
    );
    const choose = try e.when(try e.binary(
        .less,
        length,
        try b.constant(u64, 64 << 10),
    ), retain, collect);
    try b.define(entry, try b.bind(value, try e.call(machine.frames.read, &.{
        try e.param(entry, 1), try e.param(entry, 3),
    }), try b.bind(blob, try e.call(machine.blobs.get, &.{
        try machine.field(e, before, .blobs), blob_id,
    }), choose)));
    return entry;
}

fn emitConsume(e: Author, machine: machines.Definition) Error!Id {
    const b = e.b;
    const ids = try projection.schema([]const Id, b);
    const flags = try projection.schema([]const bool, b);
    const entry = try b.declare(&.{
        machine.frames.schema, ids, ids, flags,
    }, machine.frames.schema, &.{}, &.{});
    const loop = try b.declare(&.{
        machine.frames.schema, ids, ids, flags, e.integer,
    }, machine.frames.schema, &.{}, &.{});
    const frame = try e.param(loop, 0);
    const operands = try e.param(loop, 1);
    const layout = try e.param(loop, 2);
    const copy = try e.param(loop, 3);
    const index = try e.param(loop, 4);
    const next = try e.binary(.integer_add, index, e.one);
    const slot = try e.required(operands, index);
    const schema = try e.required(layout, slot);
    const cleared = try b.variable(machine.frames.schema);
    const keep = try e.call(loop, &.{ frame, operands, layout, copy, next });
    const clear = try b.bind(cleared, try e.call(
        machine.frames.clear,
        &.{ frame, slot },
    ), try e.call(loop, &.{ try b.reference(cleared), operands, layout, copy, next }));
    try b.define(loop, try e.when(try e.binary(.less, index, try b.primitive(
        e.integer,
        .sequence_length,
        &.{operands},
        0,
    )), try e.when(try e.required(copy, schema), keep, clear), try b.pure(frame)));
    try b.define(entry, try e.call(loop, &.{
        try e.param(entry, 0),
        try e.param(entry, 1),
        try e.param(entry, 2),
        try e.param(entry, 3),
        e.zero,
    }));
    return entry;
}

fn emitFindFailure(e: Author, find_failure: Id) Error!void {
    const list = try e.param(find_failure, 0);
    const wanted = try e.param(find_failure, 1);
    const at = try e.param(find_failure, 2);
    const candidate = try e.required(list, at);
    const same = try e.binary(.equal, try e.b.primitive(
        try e.b.scalar(u32),
        .enum_tag,
        &.{try e.field(candidate, 0)},
        0,
    ), try e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{wanted}, 0));
    try e.b.define(
        find_failure,
        try e.when(
            same,
            try e.b.pure(try e.field(
                candidate,
                1,
            )),
            try e.call(find_failure, &.{ list, wanted, try e.binary(.integer_add, at, e.one) }),
        ),
    );
}

fn emitInstruction(machine: machines.Definition, e: Author, d: Definition) Error!void {
    const state = try e.param(d.instruction, 0);
    const selected_program = try machine.field(e, state, .program);
    const selected_code = try e.field(
        selected_program,
        machines.index(projection.Program, "code"),
    );
    const root = try @import("control.zig").roots(e, machine, state);
    const id = try e.field(try e.payload(try e.field(
        root,
        machines.index(data.graph.Roots, "current"),
    ), 1), 0);
    const selected = try e.b.variable(machine.nodes.optional);
    const record = try e.payload(try e.b.reference(selected), 1);
    const active_control = try e.payload(try e.field(record, 0), 0);
    const active_frame = try e.payload(try e.field(record, 1), 1);
    const address = try e.field(active_control, machines.index(data.graph.Control, "block"));
    const at = try e.field(active_frame, 0);
    const block = try e.required(try e.field(
        selected_code,
        machines.index(data.activation.Program, "blocks"),
    ), address);
    const function = try e.required(try e.field(selected_code, machines.index(
        data.activation.Program,
        "functions",
    )), try e.field(block, machines.index(data.activation.Block, "function")));
    const slots = try e.field(try e.field(
        function,
        machines.index(data.activation.Function, "layout"),
    ), 0);
    const descriptor = try e.required(try e.field(block, machines.index(
        data.activation.Block,
        "instructions",
    )), at);
    const destination_type = try e.required(slots, try e.field(descriptor, machines.index(
        data.activation.Instruction,
        "destination",
    )));
    const live_row = try e.required(try e.required(try e.field(
        selected_program,
        machines.index(projection.Program, "live"),
    ), address), try e.binary(.integer_add, at, e.one));
    const copies = try e.field(try e.field(
        selected_program,
        machines.index(projection.Program, "uses"),
    ), machines.index(data.traits.Facts, "copy"));
    try e.b.define(d.instruction, try e.b.bind(selected, try e.call(machine.nodes.get, &.{
        try machine.field(e, state, .nodes), id,
    }), try e.call(d.instruction_at, &.{
        state,                         at, descriptor, slots, destination_type, live_row, copies,
        try e.b.constant(bool, false),
    })));
}

fn emitControl(
    machine: machines.Definition,
    e: Author,
    result: Id,
    d: Definition,
    controls: anytype,
) Error!void {
    const state = try e.param(d.control, 0);
    const changed = try e.b.variable(machine.schema);
    const counted = try e.replace(
        try e.b.reference(changed),
        @backingInt(machines.Field.work),
        try e.binary(.integer_add, try machine.field(e, state, .work), e.one),
    );
    try e.b.define(d.control, try e.b.bind(
        changed,
        try e.call(controls.execute, &.{state}),
        try e.b.pure(try e.variant(result, 0, counted)),
    ));
}

fn emitActive(
    machine: machines.Definition,
    e: Author,
    result: Id,
    d: Definition,
    controls: anytype,
) Error!void {
    const state = try e.param(d.active, 0);
    const root = try @import("control.zig").roots(e, machine, state);
    const id = try e.field(try e.payload(try e.field(
        root,
        machines.index(data.graph.Roots, "current"),
    ), 1), 0);
    const selected = try e.b.variable(machine.nodes.optional);
    const record = try e.payload(try e.b.reference(selected), 1);
    const active_control = try e.payload(try e.field(record, 0), 0);
    const active_frame = try e.payload(try e.field(record, 1), 1);
    const active_block = try @import("edges.zig").block(
        e,
        try machine.field(e, state, .program),
        try e.field(active_control, 0),
    );
    const count = try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{try e.field(active_block, machines.index(
            data.activation.Block,
            "instructions",
        ))},
        0,
    );
    const active = try e.b.bind(selected, try e.call(machine.nodes.get, &.{
        try machine.field(e, state, .nodes), id,
    }), try e.when(try e.binary(
        .less,
        try e.field(active_frame, 0),
        count,
    ), try e.call(d.instruction, &.{state}), try e.call(d.control, &.{state})));
    const unwound = try e.b.variable(machine.schema);
    const counted = try e.replace(
        try e.b.reference(unwound),
        @backingInt(machines.Field.work),
        try e.binary(.integer_add, try machine.field(e, state, .work), e.one),
    );
    const unwind = try e.b.bind(
        unwound,
        try e.call(controls.unwind.step, &.{state}),
        try e.b.pure(try e.variant(result, 0, counted)),
    );
    const status = try e.field(
        try machine.field(e, state, .header),
        machines.index(machines.Header, "status"),
    );
    try e.b.define(d.active, try e.when(try e.binary(.equal, try e.b.primitive(
        try e.b.scalar(u32),
        .enum_tag,
        &.{status},
        0,
    ), try e.b.constant(u32, @backingInt(
        data.process_state.Status.unwinding,
    ))), unwind, active));
}

fn defineFailureBody(
    e: Author,
    result: Id,
    controls: anytype,
    literal_value: Id,
    fault_unwound: Id,
    counted_failure: Id,
) Error!Id {
    return try e.b.bind(fault_unwound, try e.call(controls.unwind.fail_current, &.{
        try e.field(try e.b.reference(
            literal_value,
        ), 0),
        try e.field(try e.b.reference(
            literal_value,
        ), 1),
    }), try e.b.pure(try e.variant(result, 0, counted_failure)));
}

fn emitBlobRetentionCollect(
    e: Author,
    aliases: Id,
    entry: Id,
    next: Id,
    blob_id: Id,
    live: Id,
    collector: anytype,
    retain: Id,
) Error!Id {
    return try e.b.bind(
        live,
        try e.call(
            aliases,
            &.{
                try e.field(
                    try e.param(entry, 2),
                    @backingInt(@import("frames.zig").Field.bindings),
                ),
                blob_id,
            },
        ),
        try e.when(try e.b.reference(live), retain, try e.call(collector.run, &.{next})),
    );
}

fn emitAliases(e: Author, slots: anytype, aliases: Id) Error!void {
    const input = try e.param(aliases, 0);
    const wanted = try e.param(aliases, 1);
    const nil = try e.b.variable(e.unit);
    const leaf = try e.b.variable(slots.entry);
    const fork = try e.b.variable(slots.branch);
    const slot = try e.field(try e.b.reference(leaf), 1);
    const body = try e.field(try e.payload(slot, 0), 1);
    const absent = try e.b.pure(try e.b.constant(bool, false));
    const is_value = try @import("unwind.zig").is(e, slot, 0);
    const is_blob = try @import("unwind.zig").is(
        e,
        body,
        @backingInt(data.graph.ValueTag.blob),
    );
    const same = try e.b.pure(try e.binary(.equal, try e.field(try e.payload(
        body,
        @backingInt(data.graph.ValueTag.blob),
    ), 0), wanted));
    const left = try e.b.variable(e.boolean);
    const branch = try e.b.reference(fork);
    const search = try e.b.bind(left, try e.call(
        aliases,
        &.{ try e.field(branch, 1), wanted },
    ), try e.when(try e.b.reference(left), try e.b.pure(try e.b.reference(left)), try e.call(
        aliases,
        &.{ try e.field(branch, 2), wanted },
    )));
    try e.b.define(aliases, try e.b.term(.{ .match_sum = .{ .value = input, .cases = &.{
        .{ .variable = nil, .body = absent },
        .{ .variable = leaf, .body = try e.when(
            is_value,
            try e.when(is_blob, same, absent),
            absent,
        ) },
        .{ .variable = fork, .body = search },
    } } }));
}

const TransitionBuilder = struct {
    e: Author,
    evaluate: instructions.Definition,
    fault_type: Id,
    result: Id,
    d: Definition,
    controls: @import("control.zig").Definition,
    b: *source.Builder,
    machine: machines.Definition,
    input: Id = undefined,
    current_id: Id = undefined,
    node_var: Id = undefined,
    node: Id = undefined,
    frame: Id = undefined,
    code: Id = undefined,
    position: Id = undefined,
    instruction: Id = undefined,
    layout: Id = undefined,
    result_schema: Id = undefined,
    live: Id = undefined,
    copy_facts: Id = undefined,
    virtualize: Id = undefined,
    opcode: Id = undefined,
    destination: Id = undefined,
    evaluated: Id = undefined,
    computed: Id = undefined,
    changed_machine: Id = undefined,
    value: Id = undefined,
    fault: Id = undefined,
    raw: Id = undefined,
    cleared: Id = undefined,
    written: Id = undefined,
    pruned: Id = undefined,
    nodes: Id = undefined,
    updated_node: Id = undefined,
    advanced: Id = undefined,
    success: Id = undefined,
    raw_success: Id = undefined,
    find_failure: Id = undefined,
    literal_id: Id = undefined,
    value_ops: @import("values.zig").Definition = undefined,
    literal_value: Id = undefined,
    failure_body: Id = undefined,

    fn emitInstructionInput(self: *TransitionBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        self.input = try e.param(self.d.instruction_at, 0);
        const header = try self.machine.field(e, self.input, .header);
        const roots = try e.field(header, machines.index(machines.Header, "roots"));
        const current = try e.payload(try e.field(
            roots,
            machines.index(data.graph.Roots, "current"),
        ), 1);
        self.current_id = try e.field(current, 0);
        self.node_var = try b.variable(self.machine.nodes.optional);
        self.node = try e.payload(try b.reference(self.node_var), 1);
        self.frame = try e.payload(try e.field(self.node, 1), 1);
        const program = try self.machine.field(e, self.input, .program);
        self.code = try e.field(program, machines.index(projection.Program, "code"));
        self.position = try e.param(self.d.instruction_at, 1);
        self.instruction = try e.param(self.d.instruction_at, 2);
        self.layout = try e.param(self.d.instruction_at, 3);
        self.result_schema = try e.param(self.d.instruction_at, 4);
        self.live = try e.param(self.d.instruction_at, 5);
        self.copy_facts = try e.param(self.d.instruction_at, 6);
        self.virtualize = try e.param(self.d.instruction_at, 7);
        self.opcode = try e.field(self.instruction, machines.index(
            data.activation.Instruction,
            "opcode",
        ));
        self.destination = try e.field(self.instruction, machines.index(
            data.activation.Instruction,
            "destination",
        ));
    }

    fn emitFrameAdvance(self: *TransitionBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        self.evaluated = try b.variable(self.evaluate.result);
        self.computed = try b.reference(self.evaluated);
        self.changed_machine = try e.field(self.computed, 0);
        self.value = try b.variable(try projection.schema(data.graph.Value, b));
        self.fault = try b.variable(self.fault_type);
        self.raw = try b.variable(try projection.schema(@import("frames.zig").Scalar, b));
        self.cleared = try b.variable(self.machine.frames.schema);
        self.written = try b.variable(self.machine.frames.schema);
        self.pruned = try b.variable(self.machine.frames.schema);
        self.nodes = try b.variable(self.machine.nodes.table);
        const next_position = try e.binary(.integer_add, self.position, e.one);
        const updated_frame = try e.replace(try b.reference(self.pruned), 0, next_position);
        const optional_frame = b.schemas.items[@intCast(self.machine.nodes.element)].product[1];
        self.updated_node = try e.replace(
            self.node,
            1,
            try e.variant(optional_frame, 1, updated_frame),
        );
        self.advanced = try e.replace(
            self.changed_machine,
            @backingInt(machines.Field.nodes),
            try b.reference(self.nodes),
        );
        self.advanced = try e.replace(self.advanced, @backingInt(machines.Field.work), try e.binary(
            .integer_add,
            try self.machine.field(e, self.input, .work),
            e.one,
        ));
    }

    fn emitRetainedSuccess(self: *TransitionBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        const retained = try b.variable(self.machine.schema);
        const blob_retention = try emitBlobRetention(e, self.machine);
        const operand = try e.required(try e.field(self.instruction, machines.index(
            data.activation.Instruction,
            "operands",
        )), e.zero);
        const finish = try e.when(
            try instructions.is(e, self.opcode, .blob_length),
            try e.call(
                blob_retention,
                &.{ self.input, self.frame, try b.reference(self.pruned), operand, self.advanced },
            ),
            try b.pure(self.advanced),
        );
        self.success = try b.bind(self.nodes, try e.call(self.machine.nodes.set, &.{
            try self.machine.field(e, self.changed_machine, .nodes),
            self.current_id,
            self.updated_node,
        }), try b.bind(retained, finish, try b.pure(try e.variant(
            self.result,
            0,
            try b.reference(retained),
        ))));
        self.success = try b.bind(self.pruned, try e.call(
            self.machine.frames.prune,
            &.{ try b.reference(self.written), self.live },
        ), self.success);
        self.raw_success = try b.bind(self.written, try e.call(self.machine.frames.write_raw, &.{
            try b.reference(self.cleared), self.destination, try b.reference(self.raw),
        }), self.success);
        self.success = try b.bind(self.written, try e.call(self.machine.frames.write, &.{
            try b.reference(self.cleared), self.destination, try b.reference(self.value),
        }), self.success);
    }

    fn emitOperandConsumption(self: *TransitionBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        const consume = try emitConsume(e, self.machine);
        var consume_term = try e.call(consume, &.{
            self.frame,
            try e.field(self.instruction, machines.index(
                data.activation.Instruction,
                "operands",
            )),
            self.layout,
            self.copy_facts,
        });
        inline for (.{
            data.program.Opcode.variant_tag, .sequence_length, .sequence_get,
        }) |borrowed|
            consume_term = try e.when(
                try instructions.is(e, self.opcode, borrowed),
                try b.pure(self.frame),
                consume_term,
            );
        self.success = try b.bind(self.cleared, consume_term, self.success);
        self.raw_success = try b.bind(self.cleared, consume_term, self.raw_success);
    }

    fn emitFailureRule(self: *TransitionBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        const failure_list = try projection.schema([]const data.program.InstructionFailure, b);
        self.find_failure = try b.declare(&.{
            failure_list, self.fault_type, e.integer,
        }, e.integer, &.{}, &.{});
        try emitFindFailure(e, self.find_failure);
        self.literal_id = try b.variable(e.integer);
        self.value_ops = try @import("values.zig").define(b, self.machine);
        self.literal_value = try b.variable(self.value_ops.result);
        const fault_unwound = try b.variable(self.machine.schema);
        const counted_failure = try e.replace(
            try b.reference(fault_unwound),
            @backingInt(machines.Field.work),
            try e.binary(.integer_add, try self.machine.field(e, self.input, .work), e.one),
        );
        self.failure_body = try defineFailureBody(
            e,
            self.result,
            self.controls,
            self.literal_value,
            fault_unwound,
            counted_failure,
        );
    }

    fn emitFailureLiteral(self: *TransitionBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        self.failure_body = try b.bind(
            self.literal_value,
            try e.call(
                self.value_ops.literal,
                &.{
                    self.changed_machine,
                    try e.required(
                        try e.field(self.code, machines.index(
                            data.activation.Program,
                            "constants",
                        )),
                        try b.reference(self.literal_id),
                    ),
                },
            ),
            self.failure_body,
        );
        self.failure_body = try b.bind(
            self.literal_id,
            try e.call(
                self.find_failure,
                &.{
                    try e.field(
                        self.instruction,
                        machines.index(data.activation.Instruction, "failures"),
                    ),
                    try b.reference(self.fault),
                    e.zero,
                },
            ),
            self.failure_body,
        );
    }

    fn emitDispatch(self: *TransitionBuilder) Error!void {
        const b = self.b;
        const e = self.e;
        const dispatch = try b.term(.{ .match_sum = .{
            .value = try e.field(self.computed, 1),
            .cases = &.{
                .{ .variable = self.value, .body = self.success },
                .{ .variable = self.fault, .body = self.failure_body },
                .{ .variable = self.raw, .body = self.raw_success },
            },
        } });
        try b.define(self.d.instruction_at, try b.bind(
            self.node_var,
            try e.call(self.machine.nodes.get, &.{
                try self.machine.field(e, self.input, .nodes), self.current_id,
            }),
            try b.bind(self.evaluated, try e.call(self.evaluate.evaluate, &.{
                self.input,         self.frame,  self.instruction,
                self.result_schema, self.layout, self.virtualize,
            }), dispatch),
        ));
        try emitInstruction(self.machine, e, self.d);
        try emitControl(self.machine, e, self.result, self.d, self.controls);
        try emitActive(self.machine, e, self.result, self.d, self.controls);
    }
};
