//! Pure, explicitly hypothetical interpretation. This program has no bridge or
//! production receipt: a simulated request and its answer are ordinary data.
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const edges = @import("edges.zig");
const Author = @import("author.zig").Author;

pub const Input = struct { arguments: []const u8, assumed_reply: []const u8, guest_quantum: u64 };
pub const Output = struct {
    interpretation: enum { hypothetical_first_reply },
    guest: [32]u8,
    assumed_reply: []const u8,
    assumption_applied: bool,
    guest_work: u64,
    observation: @import("observe.zig").Observation,
};

/// Embed the model of an admitted guest; dynamic arguments and one assumed
/// external response remain inputs. Nothing grants the analysis guest's effects
/// to this program. A second request, yield or finite budget ends the analysis.
/// Malformed guest arguments or an applied reply fail the analysis itself.
pub fn hypotheticalReply(b: *source.Builder, guest: *const data.program_image.Admitted) !source.ast.Module {
    const encoded = try projection.programBytes(b.allocator(), guest);
    defer b.allocator().free(encoded);
    var projected = try projection.decode(projection.Program, b.allocator(), encoded);
    defer projected.deinit();
    const e = try Author.init(b);
    const m = try machines.define(b);
    const lifecycle = try @import("lifecycle.zig").define(b, m);
    const step = try @import("step.zig").define(b, m);
    const observe = try @import("observe.zig").define(b, m);
    const admitted_values = try @import("analysis_values.zig").define(b, m);
    const graph = try @import("graph.zig").define(b, m);
    const input_schema = try projection.schema(Input, b);
    const output_schema = try projection.schema(Output, b);
    const observation_schema = try projection.schema(@import("observe.zig").Observation, b);
    const entry = try b.declare(&.{input_schema}, output_schema, &.{}, &.{});
    const loop = try b.declare(&.{ input_schema, m.schema, e.boolean }, output_schema, &.{}, &.{});
    const input = try e.param(loop, 0);
    const machine = try e.param(loop, 1);
    const applied = try e.param(loop, 2);
    const status = try b.primitive(try b.scalar(u32), .enum_tag, &.{try edges.field(e, try m.field(e, machine, .header), machines.Header, "status")}, 0);
    const observed = try b.variable(observation_schema);
    const finish = try b.bind(observed, try e.call(observe, &.{machine}), try b.pure(try e.tuple(output_schema, &.{
        try e.literal(@FieldType(Output, "interpretation"), .hypothetical_first_reply),
        try e.literal([32]u8, guest.identity()),
        try e.field(input, 1),
        applied,
        try m.field(e, machine, .work),
        try b.reference(observed),
    })));
    const stepped = try b.variable(step.result);
    const advance = try b.bind(stepped, try e.call(step.active, &.{machine}), try e.call(loop, &.{ input, try e.payload(try b.reference(stepped), 0), applied }));
    const changed = try b.variable(m.schema);
    const answer = try b.bind(changed, try e.call(lifecycle.respond, &.{ machine, try e.field(input, 1) }), try e.call(loop, &.{ input, try b.reference(changed), try b.constant(bool, true) }));
    const guest_program = try m.field(e, machine, .program);
    const roots = try edges.field(e, try m.field(e, machine, .header), machines.Header, "roots");
    const pending = try e.payload(try edges.field(e, roots, data.graph.Roots, "pending"), 1);
    const pending_node = try b.variable(try projection.schema(data.graph.Node, b));
    const request = try e.payload(try b.reference(pending_node), @backingInt(data.graph.NodeTag.pending));
    const effect = try e.required(try edges.field(e, try edges.code(e, guest_program), data.activation.Program, "effects"), try e.field(request, 0));
    const reply_type = try edges.field(e, effect, data.program.Effect, "result");
    const reply_end = try b.variable(e.integer);
    const reply = try e.field(input, 1);
    const admit_answer = try b.bind(pending_node, try e.call(graph.record, &.{ machine, pending }), try b.bind(reply_end, try e.call(admitted_values.value, &.{ guest_program, reply_type, reply, e.zero }), try e.when(try e.binary(.equal, try b.reference(reply_end), try b.primitive(e.integer, .blob_length, &.{reply}, 0)), answer, try e.fail())));
    const parked = try e.when(applied, finish, admit_answer);
    var body = finish;
    inline for (.{ data.process_state.Status.active, data.process_state.Status.unwinding, data.process_state.Status.parked }) |selected| {
        body = try e.when(try e.binary(.equal, status, try b.constant(u32, @backingInt(selected))), if (selected == .parked) parked else advance, body);
    }
    try b.define(loop, try e.when(try e.binary(.less, try m.field(e, machine, .work), try e.field(input, 2)), body, finish));
    const initial = try b.variable(m.schema);
    const argument = try e.param(entry, 0);
    const program = try e.literal(projection.Program, projected.value);
    const guest_entry = projected.value.code.functions[@intCast(projected.value.code.roots.entry)];
    const input_types = try b.allocator().alloc(data.program.Id, guest_entry.inputs.len);
    for (input_types, guest_entry.inputs) |*shape, slot| shape.* = guest_entry.layout.slots[@intCast(slot)];
    const argument_bytes = try e.field(argument, 0);
    const argument_end = try b.variable(e.integer);
    const start = try b.bind(initial, try e.call(lifecycle.initialize, &.{ program, argument_bytes }), try e.call(loop, &.{ argument, try b.reference(initial), try b.constant(bool, false) }));
    try b.define(entry, try b.bind(argument_end, try e.call(admitted_values.fields, &.{ program, try e.literal([]const data.program.Id, input_types), argument_bytes, e.zero }), try e.when(try e.binary(.equal, try b.reference(argument_end), try b.primitive(e.integer, .blob_length, &.{argument_bytes}, 0)), start, try e.fail())));
    return b.module(entry, e.unit);
}

// Preserve the public example entry points for existing native consumers.
pub const exampleGuest = @import("../semantic_examples.zig").exampleGuest;
pub const example = @import("../semantic_examples.zig").example;
