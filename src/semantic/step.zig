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

pub const Definition = struct { instruction: Id, instruction_at: Id, control: Id, active: Id, result: Id };

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
        // The descriptor, layout, live row, and copy facts can be static while
        // the machine remains dynamic. Both realizations call this same rule.
        .instruction_at = try b.declare(&.{ machine.schema, e.integer, instruction_schema, ids, e.integer, ids, flags, e.boolean }, result, &.{}, &.{}),
        .control = try b.declare(&.{machine.schema}, result, &.{}, &.{}),
        .active = try b.declare(&.{machine.schema}, result, &.{}, &.{}),
        .result = result,
    };
    const controls = try @import("control.zig").define(b, machine);
    const input = try e.param(d.instruction_at, 0);
    const header = try machine.field(e, input, .header);
    const roots = try e.field(header, machines.index(machines.Header, "roots"));
    const current = try e.payload(try e.field(roots, machines.index(data.graph.Roots, "current")), 1);
    const current_id = try e.field(current, 0);
    const node_var = try b.variable(machine.nodes.optional);
    const node = try e.payload(try b.reference(node_var), 1);
    const frame = try e.payload(try e.field(node, 1), 1);
    const program = try machine.field(e, input, .program);
    const code = try e.field(program, machines.index(projection.Program, "code"));
    const position = try e.param(d.instruction_at, 1);
    const instruction = try e.param(d.instruction_at, 2);
    const layout = try e.param(d.instruction_at, 3);
    const result_schema = try e.param(d.instruction_at, 4);
    const live = try e.param(d.instruction_at, 5);
    const copy_facts = try e.param(d.instruction_at, 6);
    const virtualize = try e.param(d.instruction_at, 7);
    const destination = try e.field(instruction, machines.index(data.activation.Instruction, "destination"));
    const evaluated = try b.variable(evaluate.result);
    const computed = try b.reference(evaluated);
    const changed_machine = try e.field(computed, 0);
    const value = try b.variable(try projection.schema(data.graph.Value, b));
    const fault = try b.variable(fault_type);
    const raw = try b.variable(try projection.schema(@import("frames.zig").Scalar, b));
    const cleared = try b.variable(machine.frames.schema);
    const written = try b.variable(machine.frames.schema);
    const pruned = try b.variable(machine.frames.schema);
    const nodes = try b.variable(machine.nodes.table);
    const next_position = try e.binary(.integer_add, position, e.one);
    const updated_frame = try e.replace(try b.reference(pruned), 0, next_position);
    const optional_frame = b.schemas.items[@intCast(machine.nodes.element)].product[1];
    const updated_node = try e.replace(node, 1, try e.variant(optional_frame, 1, updated_frame));
    var advanced = try e.replace(changed_machine, @backingInt(machines.Field.nodes), try b.reference(nodes));
    advanced = try e.replace(advanced, @backingInt(machines.Field.work), try e.binary(.integer_add, try machine.field(e, input, .work), e.one));
    var success = try b.bind(nodes, try e.call(machine.nodes.set, &.{ try machine.field(e, changed_machine, .nodes), current_id, updated_node }), try b.pure(try e.variant(result, 0, advanced)));
    success = try b.bind(pruned, try e.call(machine.frames.prune, &.{ try b.reference(written), live }), success);
    var raw_success = try b.bind(written, try e.call(machine.frames.write_raw, &.{ try b.reference(cleared), destination, try b.reference(raw) }), success);
    success = try b.bind(written, try e.call(machine.frames.write, &.{ try b.reference(cleared), destination, try b.reference(value) }), success);
    const consume = try emitConsume(e, machine);
    const opcode = try e.field(instruction, machines.index(data.activation.Instruction, "opcode"));
    var consume_term = try e.call(consume, &.{ frame, try e.field(instruction, machines.index(data.activation.Instruction, "operands")), layout, copy_facts });
    inline for (.{ data.program.Opcode.variant_tag, .sequence_length, .sequence_get }) |borrowed|
        consume_term = try e.when(try instructions.is(e, opcode, borrowed), try b.pure(frame), consume_term);
    success = try b.bind(cleared, consume_term, success);
    raw_success = try b.bind(cleared, consume_term, raw_success);
    const failure_list = try projection.schema([]const data.program.InstructionFailure, b);
    const find_failure = try b.declare(&.{ failure_list, fault_type, e.integer }, e.integer, &.{}, &.{});
    {
        const list = try e.param(find_failure, 0);
        const wanted = try e.param(find_failure, 1);
        const at = try e.param(find_failure, 2);
        const candidate = try e.required(list, at);
        const same = try e.binary(.equal, try b.primitive(try b.scalar(u32), .enum_tag, &.{try e.field(candidate, 0)}, 0), try b.primitive(try b.scalar(u32), .enum_tag, &.{wanted}, 0));
        try b.define(find_failure, try e.when(same, try b.pure(try e.field(candidate, 1)), try e.call(find_failure, &.{ list, wanted, try e.binary(.integer_add, at, e.one) })));
    }
    const literal_id = try b.variable(e.integer);
    const value_ops = try @import("values.zig").define(b, machine);
    const literal_value = try b.variable(value_ops.result);
    const fault_unwound = try b.variable(machine.schema);
    const counted_failure = try e.replace(try b.reference(fault_unwound), @backingInt(machines.Field.work), try e.binary(.integer_add, try machine.field(e, input, .work), e.one));
    var failure_body = try b.bind(fault_unwound, try e.call(controls.unwind.fail_current, &.{ try e.field(try b.reference(literal_value), 0), try e.field(try b.reference(literal_value), 1) }), try b.pure(try e.variant(result, 0, counted_failure)));
    failure_body = try b.bind(literal_value, try e.call(value_ops.literal, &.{ changed_machine, try e.required(try e.field(code, machines.index(data.activation.Program, "constants")), try b.reference(literal_id)) }), failure_body);
    failure_body = try b.bind(literal_id, try e.call(find_failure, &.{ try e.field(instruction, machines.index(data.activation.Instruction, "failures")), try b.reference(fault), e.zero }), failure_body);
    const dispatch = try b.term(.{ .match_sum = .{ .value = try e.field(computed, 1), .cases = &.{
        .{ .variable = value, .body = success },
        .{ .variable = fault, .body = failure_body },
        .{ .variable = raw, .body = raw_success },
    } } });
    try b.define(d.instruction_at, try b.bind(node_var, try e.call(machine.nodes.get, &.{ try machine.field(e, input, .nodes), current_id }), try b.bind(evaluated, try e.call(evaluate.evaluate, &.{ input, frame, instruction, result_schema, layout, virtualize }), dispatch)));
    {
        const state = try e.param(d.instruction, 0);
        const selected_program = try machine.field(e, state, .program);
        const selected_code = try e.field(selected_program, machines.index(projection.Program, "code"));
        const root = try @import("control.zig").roots(e, machine, state);
        const id = try e.field(try e.payload(try e.field(root, machines.index(data.graph.Roots, "current")), 1), 0);
        const selected = try b.variable(machine.nodes.optional);
        const record = try e.payload(try b.reference(selected), 1);
        const active_control = try e.payload(try e.field(record, 0), 0);
        const active_frame = try e.payload(try e.field(record, 1), 1);
        const address = try e.field(active_control, machines.index(data.graph.Control, "block"));
        const at = try e.field(active_frame, 0);
        const block = try e.required(try e.field(selected_code, machines.index(data.activation.Program, "blocks")), address);
        const function = try e.required(try e.field(selected_code, machines.index(data.activation.Program, "functions")), try e.field(block, machines.index(data.activation.Block, "function")));
        const slots = try e.field(try e.field(function, machines.index(data.activation.Function, "layout")), 0);
        const descriptor = try e.required(try e.field(block, machines.index(data.activation.Block, "instructions")), at);
        const destination_type = try e.required(slots, try e.field(descriptor, machines.index(data.activation.Instruction, "destination")));
        const live_row = try e.required(try e.required(try e.field(selected_program, machines.index(projection.Program, "live")), address), try e.binary(.integer_add, at, e.one));
        const copies = try e.field(try e.field(selected_program, machines.index(projection.Program, "uses")), machines.index(data.traits.Facts, "copy"));
        try b.define(d.instruction, try b.bind(selected, try e.call(machine.nodes.get, &.{ try machine.field(e, state, .nodes), id }), try e.call(d.instruction_at, &.{ state, at, descriptor, slots, destination_type, live_row, copies, try b.constant(bool, false) })));
    }
    {
        const state = try e.param(d.control, 0);
        const changed = try b.variable(machine.schema);
        const counted = try e.replace(try b.reference(changed), @backingInt(machines.Field.work), try e.binary(.integer_add, try machine.field(e, state, .work), e.one));
        try b.define(d.control, try b.bind(changed, try e.call(controls.execute, &.{state}), try b.pure(try e.variant(result, 0, counted))));
    }
    {
        const state = try e.param(d.active, 0);
        const root = try @import("control.zig").roots(e, machine, state);
        const id = try e.field(try e.payload(try e.field(root, machines.index(data.graph.Roots, "current")), 1), 0);
        const selected = try b.variable(machine.nodes.optional);
        const record = try e.payload(try b.reference(selected), 1);
        const active_control = try e.payload(try e.field(record, 0), 0);
        const active_frame = try e.payload(try e.field(record, 1), 1);
        const active_block = try @import("edges.zig").block(e, try machine.field(e, state, .program), try e.field(active_control, 0));
        const count = try b.primitive(e.integer, .sequence_length, &.{try e.field(active_block, machines.index(data.activation.Block, "instructions"))}, 0);
        const active = try b.bind(selected, try e.call(machine.nodes.get, &.{ try machine.field(e, state, .nodes), id }), try e.when(try e.binary(.less, try e.field(active_frame, 0), count), try e.call(d.instruction, &.{state}), try e.call(d.control, &.{state})));
        const unwound = try b.variable(machine.schema);
        const counted = try e.replace(try b.reference(unwound), @backingInt(machines.Field.work), try e.binary(.integer_add, try machine.field(e, state, .work), e.one));
        const unwind = try b.bind(unwound, try e.call(controls.unwind.step, &.{state}), try b.pure(try e.variant(result, 0, counted)));
        const status = try e.field(try machine.field(e, state, .header), machines.index(machines.Header, "status"));
        try b.define(d.active, try e.when(try e.binary(.equal, try b.primitive(try b.scalar(u32), .enum_tag, &.{status}, 0), try b.constant(u32, @backingInt(data.process_state.Status.unwinding))), unwind, active));
    }
    return cache.finish(b, d);
}

fn emitConsume(e: Author, machine: machines.Definition) Error!Id {
    const b = e.b;
    const ids = try projection.schema([]const Id, b);
    const flags = try projection.schema([]const bool, b);
    const entry = try b.declare(&.{ machine.frames.schema, ids, ids, flags }, machine.frames.schema, &.{}, &.{});
    const loop = try b.declare(&.{ machine.frames.schema, ids, ids, flags, e.integer }, machine.frames.schema, &.{}, &.{});
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
    const clear = try b.bind(cleared, try e.call(machine.frames.clear, &.{ frame, slot }), try e.call(loop, &.{ try b.reference(cleared), operands, layout, copy, next }));
    try b.define(loop, try e.when(try e.binary(.less, index, try b.primitive(e.integer, .sequence_length, &.{operands}, 0)), try e.when(try e.required(copy, schema), keep, clear), try b.pure(frame)));
    try b.define(entry, try e.call(loop, &.{ try e.param(entry, 0), try e.param(entry, 1), try e.param(entry, 2), try e.param(entry, 3), e.zero }));
    return entry;
}
