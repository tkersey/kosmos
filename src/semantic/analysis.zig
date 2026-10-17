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
    const parked = try e.when(applied, finish, answer);
    var body = finish;
    inline for (.{ data.process_state.Status.active, data.process_state.Status.unwinding, data.process_state.Status.parked }) |selected| {
        body = try e.when(try e.binary(.equal, status, try b.constant(u32, @backingInt(selected))), if (selected == .parked) parked else advance, body);
    }
    try b.define(loop, try e.when(try e.binary(.less, try m.field(e, machine, .work), try e.field(input, 2)), body, finish));
    const initial = try b.variable(m.schema);
    const argument = try e.param(entry, 0);
    try b.define(entry, try b.bind(initial, try e.call(lifecycle.initialize, &.{ try e.literal(projection.Program, projected.value), try e.field(argument, 0) }), try e.call(loop, &.{ argument, try b.reference(initial), try b.constant(bool, false) })));
    return b.module(entry, e.unit);
}

// Preserve the public example entry points for existing native consumers.
pub const exampleGuest = @import("../semantic_examples.zig").exampleGuest;
pub const example = @import("../semantic_examples.zig").example;
