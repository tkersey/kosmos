//! Ordinary source dispatch with static interval bounds. Partial evaluation can
//! remove descriptor lookup while the guest address and machine stay dynamic.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const steps = @import("step.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;

pub fn define(b: *source.Builder, machine: machines.Definition, step: steps.Definition) source.Error!Id {
    const cache = try b.specialization(Id, "kosmos.semantic.staged/1", machine.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const entry = try b.declare(&.{machine.schema}, step.result, &.{}, &.{});
    // Both searches are balanced. Empty intervals retain the ordinary rule,
    // including its treatment of invalid addresses and terminal instructions.
    const blocks = try b.declare(&.{ machine.schema, e.integer, e.integer, e.integer, e.integer }, step.result, &.{}, &.{});
    const positions = try b.declare(&.{ machine.schema, e.integer, e.integer, e.integer, e.integer }, step.result, &.{}, &.{});
    inline for (.{ false, true }) |instruction_search| {
        const function = if (instruction_search) positions else blocks;
        const state = try e.param(function, 0);
        const address = try e.param(function, 1);
        const position = try e.param(function, 2);
        const low = try e.param(function, 3);
        const high = try e.param(function, 4);
        const program = try machine.field(e, state, .program);
        const code = try e.field(program, machines.index(projection.Program, "code"));
        const code_blocks = try e.field(code, machines.index(data.activation.Program, "blocks"));
        const selected = try e.required(code_blocks, if (instruction_search) address else low);
        const instructions = try e.field(selected, machines.index(data.activation.Block, "instructions"));
        const count = try b.primitive(e.integer, .sequence_length, &.{instructions}, 0);
        const span = try e.binary(.integer_sub, high, low);
        const middle = try e.binary(.integer_add, low, try e.binary(.integer_div, span, try b.constant(u64, 2)));
        const target = if (instruction_search) position else address;
        const divide = try e.when(try e.binary(.less, target, middle), try e.call(function, &.{ state, address, position, low, middle }), try e.call(function, &.{ state, address, position, middle, high }));
        const leaf = if (instruction_search) leaf: {
            const descriptor = try e.required(instructions, low);
            const owner = try e.required(try e.field(code, machines.index(data.activation.Program, "functions")), try e.field(selected, machines.index(data.activation.Block, "function")));
            const layout = try e.field(try e.field(owner, machines.index(data.activation.Function, "layout")), 0);
            const result = try e.required(layout, try e.field(descriptor, machines.index(data.activation.Instruction, "destination")));
            const live = try e.required(try e.required(try e.field(program, machines.index(projection.Program, "live")), address), try e.binary(.integer_add, low, e.one));
            const copies = try e.field(try e.field(program, machines.index(projection.Program, "uses")), machines.index(data.traits.Facts, "copy"));
            break :leaf try e.call(step.instruction_at, &.{ state, low, descriptor, layout, result, live, copies, try b.constant(bool, true) });
        } else try e.when(try e.binary(.less, position, count), try e.call(positions, &.{ state, low, position, e.zero, count }), try e.call(step.control, &.{state}));
        try b.define(function, try e.when(try e.binary(.equal, span, e.zero), try e.call(step.active, &.{state}), try e.when(try e.binary(.equal, span, e.one), leaf, divide)));
    }
    const state = try e.param(entry, 0);
    const root = try @import("control.zig").roots(e, machine, state);
    const id = try e.field(try e.payload(try e.field(root, machines.index(data.graph.Roots, "current")), 1), 0);
    const selected = try b.variable(machine.nodes.optional);
    const record = try e.payload(try b.reference(selected), 1);
    const control = try e.payload(try e.field(record, 0), 0);
    const frame = try e.payload(try e.field(record, 1), 1);
    const address = try e.field(control, machines.index(data.graph.Control, "block"));
    const program = try machine.field(e, state, .program);
    const code = try e.field(program, machines.index(projection.Program, "code"));
    const count = try b.primitive(e.integer, .sequence_length, &.{try e.field(code, machines.index(data.activation.Program, "blocks"))}, 0);
    const active = try b.bind(selected, try e.call(machine.nodes.get, &.{ try machine.field(e, state, .nodes), id }), try e.when(try e.binary(.less, address, count), try e.call(blocks, &.{ state, address, try e.field(frame, 0), e.zero, count }), try e.call(step.active, &.{state})));
    const status = try e.field(try machine.field(e, state, .header), machines.index(machines.Header, "status"));
    try b.define(entry, try e.when(try e.binary(.equal, try b.primitive(try b.scalar(u32), .enum_tag, &.{status}, 0), try b.constant(u32, @backingInt(data.process_state.Status.unwinding))), try e.call(step.active, &.{state}), active));
    return cache.finish(b, entry);
}
