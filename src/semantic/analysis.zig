const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const edges = @import("edges.zig");
const Id = data.program.Id;
const Author = @import("author.zig").Author;
const ReplyBoundary = enum { pending_request, guest_quantum };

pub const Input = struct { arguments: []const u8, assumed_reply: []const u8, guest_quantum: u64 };
pub const Output = struct {
    interpretation: enum { hypothetical_first_reply },
    guest: [32]u8,
    assumed_reply: []const u8,
    assumption_applied: bool,
    guest_work: u64,
    observation: @import("observe.zig").Observation,
};
pub const InterpretationInput = struct {
    arguments: []const u8,
    assumptions: []const []const u8,
    guest_quantum: u64,
};
pub const Stop = enum { terminal, missing_assumption, quantum, yielded };
pub const AssumedRequest = struct {
    guest_work: u64,
    request: @FieldType(@import("observe.zig").Observation, "requested"),
};
pub const InterpretationOutput = struct {
    guest: [32]u8,
    assumptions: []const []const u8,
    applied: u64,
    guest_work: u64,
    stopping: Stop,
    observation: @import("observe.zig").Observation,
    state: projection.State,
    requests: []const AssumedRequest,
};
pub const Definition = struct {
    entry: Id,
    advance: Id,
    machine: machines.Definition,
    lifecycle: @import("lifecycle.zig").Definition,
    step: @import("step.zig").Definition,
    observe: Id,
    admit: @import("analysis_values.zig").Definition,
    graph: @import("graph.zig").Definition,
    input: Id,
    output: Id,
    guest: [32]u8,
};

pub fn interpretation(
    b: *source.Builder,
    guest: *const data.program_image.Admitted,
    snapshot: ?projection.State,
) !source.ast.Module {
    const d = try define(b, guest, snapshot);
    return b.module(d.entry, try b.scalar(void));
}

pub fn define(
    b: *source.Builder,
    guest: *const data.program_image.Admitted,
    snapshot: ?projection.State,
) !Definition {
    return defineWithReplyBoundary(b, guest, snapshot, .pending_request);
}

fn defineWithReplyBoundary(
    b: *source.Builder,
    guest: *const data.program_image.Admitted,
    snapshot: ?projection.State,
    reply_boundary: ReplyBoundary,
) !Definition {
    var admitted_snapshot: ?data.state_image.Owned = null;
    defer if (admitted_snapshot) |*owned| owned.deinit();
    if (snapshot) |state| {
        admitted_snapshot = try data.state_image.canonicalize(b.allocator(), state);
        try data.state_admission.validateAdmitted(b.allocator(), guest, admitted_snapshot.?.state);
    }
    const encoded = try projection.programBytes(b.allocator(), guest);
    defer b.allocator().free(encoded);
    var projected = try projection.decode(projection.Program, b.allocator(), encoded);
    defer projected.deinit();
    const e = try Author.init(b);
    const m = try machines.define(b);
    const input = try projection.schema(InterpretationInput, b);
    const output = try projection.schema(InterpretationOutput, b);
    const d: Definition = .{
        .entry = try b.declare(&.{input}, output, &.{}, &.{}),
        .advance = try b.declare(&.{
            input,                                            m.schema, e.integer, e.integer,
            try projection.schema([]const AssumedRequest, b),
        }, output, &.{}, &.{}),
        .machine = m,
        .lifecycle = try @import("lifecycle.zig").define(b, m),
        .step = try @import("step.zig").define(b, m),
        .observe = try @import("observe.zig").define(b, m),
        .admit = try @import("analysis_values.zig").define(b, m),
        .graph = try @import("graph.zig").define(b, m),
        .input = input,
        .output = output,
        .guest = guest.identity(),
    };
    try defineAdvance(e, d, reply_boundary);
    const initial_state = if (admitted_snapshot) |owned| owned.state else null;
    try defineEntry(e, d, projected.value, initial_state);
    return d;
}

pub fn hypotheticalReply(
    b: *source.Builder,
    guest: *const data.program_image.Admitted,
) !source.ast.Module {
    const d = try defineWithReplyBoundary(b, guest, null, .guest_quantum);
    const e = try Author.init(b);
    const output_schema = try projection.schema(Output, b);
    const entry = try b.declare(&.{try projection.schema(Input, b)}, output_schema, &.{}, &.{});
    const input = try e.param(entry, 0);
    const result = try b.variable(d.output);
    const value = try b.reference(result);
    const assumption_schema = try projection.schema([]const []const u8, b);
    const assumptions = try b.primitive(assumption_schema, .sequence, &.{try e.field(input, 1)}, 0);
    const arguments = try e.tuple(d.input, &.{
        try e.field(input, 0), assumptions, try e.field(input, 2),
    });
    const output = try b.pure(try e.tuple(output_schema, &.{
        try e.literal(@FieldType(Output, "interpretation"), .hypothetical_first_reply),
        try e.field(value, 0),
        try e.field(input, 1),
        try e.binary(.less, e.zero, try e.field(value, 2)),
        try e.field(value, 3),
        try e.field(value, 5),
    }));
    try b.define(entry, try b.bind(result, try e.call(d.entry, &.{arguments}), output));
    return b.module(entry, e.unit);
}

pub const exampleGuest = @import("../semantic_examples.zig").exampleGuest;
pub const example = @import("../semantic_examples.zig").example;

fn defineEntry(
    e: Author,
    d: Definition,
    program: projection.Program,
    snapshot: ?projection.State,
) !void {
    const b = e.b;
    const input = try e.param(d.entry, 0);
    const projected = try e.literal(projection.Program, program);
    const machine = try b.variable(d.machine.schema);
    const initial = if (snapshot) |state| retained: {
        const hydrate = try e.call(d.machine.hydrate, &.{
            projected, try e.literal(projection.State, state),
        });
        if (state.status != .yielded) break :retained hydrate;
        const yielded = try b.variable(d.machine.schema);
        break :retained try b.bind(yielded, hydrate, try e.call(d.lifecycle.resume_yield, &.{
            try b.reference(yielded),
        }));
    } else try e.call(d.lifecycle.initialize, &.{ projected, try e.field(input, 0) });
    const start = try b.bind(machine, initial, try e.call(d.advance, &.{
        input,
        try b.reference(machine),
        e.zero,
        try e.field(input, 2),
        try e.literal([]const AssumedRequest, &.{}),
    }));
    if (snapshot != null) return b.define(d.entry, start);
    const guest_entry = program.code.functions[@intCast(program.code.roots.entry)];
    const types = try b.allocator().alloc(Id, guest_entry.inputs.len);
    for (types, guest_entry.inputs) |*shape, slot|
        shape.* = guest_entry.layout.slots[@intCast(slot)];
    const argument_bytes = try e.field(input, 0);
    const end = try b.variable(e.integer);
    const length = try b.primitive(e.integer, .blob_length, &.{argument_bytes}, 0);
    try b.define(d.entry, try b.bind(end, try e.call(d.admit.fields, &.{
        projected, try e.literal([]const Id, types), argument_bytes, e.zero,
    }), try e.when(try e.binary(.equal, try b.reference(end), length), start, try e.fail())));
}

fn finish(e: Author, d: Definition, stopping: Stop) !Id {
    const b = e.b;
    const input = try e.param(d.advance, 0);
    const machine = try e.param(d.advance, 1);
    const observed = try b.variable(try projection.schema(@import("observe.zig").Observation, b));
    const state = try b.variable(d.machine.state);
    const output = try b.pure(try e.tuple(d.output, &.{
        try e.literal([32]u8, d.guest),
        try e.field(input, 1),
        try e.param(d.advance, 2),
        try d.machine.field(e, machine, .work),
        try e.literal(Stop, stopping),
        try b.reference(observed),
        try b.reference(state),
        try e.param(d.advance, 4),
    }));
    const projected = try b.bind(state, try e.call(d.machine.project, &.{machine}), output);
    return b.bind(observed, try e.call(d.observe, &.{machine}), projected);
}

fn defineAdvance(e: Author, d: Definition, reply_boundary: ReplyBoundary) !void {
    const b = e.b;
    const input = try e.param(d.advance, 0);
    const machine = try e.param(d.advance, 1);
    const applied = try e.param(d.advance, 2);
    const remaining = try e.param(d.advance, 3);
    const status = try b.primitive(try b.scalar(u32), .enum_tag, &.{try edges.field(
        e,
        try d.machine.field(e, machine, .header),
        machines.Header,
        "status",
    )}, 0);
    const stepped = try b.variable(d.step.result);
    const continue_step = try e.call(d.advance, &.{
        input,
        try e.payload(try b.reference(stepped), 0),
        applied,
        try e.binary(.integer_sub, remaining, e.one),
        try e.param(d.advance, 4),
    });
    const advance = try b.bind(stepped, try e.call(d.step.active, &.{machine}), continue_step);
    const assumptions = try e.field(input, 1);
    const count = try b.primitive(e.integer, .sequence_length, &.{assumptions}, 0);
    const unavailable = try finish(e, d, .missing_assumption);
    const reply = try e.when(try e.binary(.less, applied, count), try assume(e, d), unavailable);
    const parked = switch (reply_boundary) {
        .pending_request => reply,
        .guest_quantum => try e.when(
            try e.binary(.less, e.zero, remaining),
            reply,
            try finish(e, d, .quantum),
        ),
    };
    var body = try finish(e, d, .terminal);
    inline for ([_]data.process_state.Status{ .active, .unwinding, .parked, .yielded }) |selected| {
        const next = switch (selected) {
            .parked => parked,
            .yielded => try finish(e, d, .yielded),
            else => try e.when(
                try e.binary(.less, e.zero, remaining),
                advance,
                try finish(e, d, .quantum),
            ),
        };
        const matches = try e.binary(.equal, status, try b.constant(u32, @backingInt(selected)));
        body = try e.when(matches, next, body);
    }
    try b.define(d.advance, body);
}

fn assume(e: Author, d: Definition) !Id {
    const b = e.b;
    const input = try e.param(d.advance, 0);
    const machine = try e.param(d.advance, 1);
    const applied = try e.param(d.advance, 2);
    const reply = try e.required(try e.field(input, 1), applied);
    const changed = try b.variable(d.machine.schema);
    const observed = try b.variable(try projection.schema(@import("observe.zig").Observation, b));
    const requests = try appendRequest(e, d, machine, try b.reference(observed));
    const continue_reply = try e.call(d.advance, &.{
        input,
        try b.reference(changed),
        try e.binary(.integer_add, applied, e.one),
        try e.param(d.advance, 3),
        requests,
    });
    const respond = try e.call(d.lifecycle.respond, &.{ machine, reply });
    const answer = try b.bind(
        observed,
        try e.call(d.observe, &.{machine}),
        try b.bind(changed, respond, continue_reply),
    );
    const program = try d.machine.field(e, machine, .program);
    const header = try d.machine.field(e, machine, .header);
    const roots = try edges.field(e, header, machines.Header, "roots");
    const pending = try e.payload(try edges.field(e, roots, data.graph.Roots, "pending"), 1);
    const node = try b.variable(try projection.schema(data.graph.Node, b));
    const request = try e.payload(try b.reference(node), @backingInt(data.graph.NodeTag.pending));
    const code = try edges.code(e, program);
    const effects = try edges.field(e, code, data.activation.Program, "effects");
    const effect = try e.required(effects, try e.field(request, 0));
    const reply_type = try edges.field(e, effect, data.program.Effect, "result");
    const end = try b.variable(e.integer);
    const length = try b.primitive(e.integer, .blob_length, &.{reply}, 0);
    const valid = try e.when(
        try e.binary(.equal, try b.reference(end), length),
        answer,
        try e.fail(),
    );
    const check = try e.call(d.admit.value, &.{ program, reply_type, reply, e.zero });
    const admitted = try b.bind(end, check, valid);
    return b.bind(node, try e.call(d.graph.record, &.{ machine, pending }), admitted);
}

fn appendRequest(e: Author, d: Definition, machine: Id, observed: Id) !Id {
    const point = try e.tuple(try projection.schema(AssumedRequest, e.b), &.{
        try d.machine.field(e, machine, .work),
        try e.payload(observed, machines.index(@import("observe.zig").Observation, "requested")),
    });
    return e.b.primitive(
        try projection.schema([]const AssumedRequest, e.b),
        .sequence_append,
        &.{ try e.param(d.advance, 4), point },
        0,
    );
}
