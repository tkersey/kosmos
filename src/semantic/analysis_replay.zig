const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const edges = @import("edges.zig");
const equality = @import("record_equal.zig");
const Author = @import("author.zig").Author;
const Observation = @import("observe.zig").Observation;
const Id = data.program.Id;
const Error = source.Error;

pub const ReplayStart = union(enum) { arguments: []const u8, checkpoint: []const u8 };
pub const ReplayBinding = struct {
    guest: [32]u8,
    origin: union(enum) { arguments: [32]u8, checkpoint: [32]u8 },
};
pub const ReplayCapture = struct { observation: bool = false, snapshot: bool = false };
pub const ReplayExchange = struct {
    expected_request: @FieldType(Observation, "requested"),
    response: []const u8,
};
pub const ReplayEnding = union(enum) { prefix, terminal: Observation };
pub const ReplayTranscript = struct {
    binding: ReplayBinding,
    exchanges: []const ReplayExchange,
    ending: ReplayEnding,
};
pub const ReplayInput = struct { transcript: ReplayTranscript, guest_quantum: u64 };
pub const ReplayStop = union(enum) {
    terminal_matched,
    terminal_observed,
    prefix_exhausted,
    missing_exchange,
    yielded,
    guest_quantum,
    unused_exchanges: u64,
    effect_mismatch: struct { index: u64, expected: Id, actual: Id },
    payload_mismatch: struct {
        index: u64,
        expected_length: u64,
        actual_length: u64,
        first_difference: u64,
    },
    terminal_mismatch,
};
pub const ReplayOutput = struct {
    binding: ReplayBinding,
    matched_exchanges: u64,
    guest_steps: u64,
    boundary: data.process_state.Status,
    stopping: ReplayStop,
    observation: ?Observation,
    snapshot: ?projection.State,
};
pub const ReplayProgram = struct { module: source.ast.Module, binding: ReplayBinding };

pub fn encodeReplayInput(a: std.mem.Allocator, input: ReplayInput) projection.Error![]u8 {
    return projection.encode(ReplayInput, a, input);
}

pub fn decodeReplayOutput(
    a: std.mem.Allocator,
    bytes: []const u8,
) projection.Error!projection.Owned(ReplayOutput) {
    return projection.decode(ReplayOutput, a, bytes);
}

const Definition = struct {
    entry: Id,
    advance: Id,
    difference: Id,
    machine: machines.Definition,
    lifecycle: @import("lifecycle.zig").Definition,
    step: @import("step.zig").Definition,
    observe: Id,
    admit: @import("analysis_values.zig").Definition,
    graph: @import("graph.zig").Definition,
    output: Id,
    binding: ReplayBinding,
    capture: ReplayCapture,
};
const Cursor = struct { input: Id, machine: Id, matched: Id, remaining: Id };

pub fn replay(
    b: *source.Builder,
    guest: *const data.program_image.Admitted,
    start: ReplayStart,
    capture: ReplayCapture,
) !ReplayProgram {
    var checkpoint: ?data.state_image.Owned = null;
    defer if (checkpoint) |*owned| owned.deinit();
    const origin: @FieldType(ReplayBinding, "origin") = switch (start) {
        .arguments => |bytes| admitted: {
            try admitArguments(b.allocator(), guest, bytes);
            break :admitted .{ .arguments = @import("artifact.zig").digest(bytes) };
        },
        .checkpoint => |bytes| admitted: {
            checkpoint = try data.state_image.decodeGraph(b.allocator(), bytes);
            try data.state_admission.validateAdmitted(b.allocator(), guest, checkpoint.?.state);
            const canonical = try data.state_image.emit(b.allocator(), checkpoint.?.state);
            defer b.allocator().free(canonical);
            if (!std.mem.eql(u8, bytes, canonical)) return error.InvalidValue;
            break :admitted .{ .checkpoint = @import("artifact.zig").digest(bytes) };
        },
    };
    const binding: ReplayBinding = .{ .guest = guest.identity(), .origin = origin };
    const encoded = try projection.programBytes(b.allocator(), guest);
    defer b.allocator().free(encoded);
    var projected = try projection.decode(projection.Program, b.allocator(), encoded);
    defer projected.deinit();
    const e = try Author.init(b);
    const d = try declare(e, binding, capture);
    try defineDifference(e, d.difference);
    try defineAdvance(e, d);
    try defineEntry(e, d, projected.value, start, if (checkpoint) |s| s.state else null);
    return .{ .module = b.module(d.entry, e.unit), .binding = binding };
}

fn admitArguments(
    a: std.mem.Allocator,
    guest: *const data.program_image.Admitted,
    bytes: []const u8,
) !void {
    const program = guest.program();
    const entry = program.functions[@intCast(program.roots.entry)];
    var reader: data.wire.Reader = .{ .input = bytes };
    for (entry.inputs) |slot| {
        _ = try data.admission.readValue(
            a,
            program.schemas,
            guest.schemaFacts(),
            entry.layout.slots[@intCast(slot)],
            &reader,
        );
    }
    try reader.finish();
}

fn declare(e: Author, binding: ReplayBinding, capture: ReplayCapture) Error!Definition {
    const b = e.b;
    const m = try machines.define(b);
    const input = try projection.schema(ReplayInput, b);
    const output = try projection.schema(ReplayOutput, b);
    const bytes = try b.schema(.bytes);
    return .{
        .entry = try b.declare(&.{input}, output, &.{}, &.{}),
        .advance = try b.declare(&.{ input, m.schema, e.integer, e.integer }, output, &.{}, &.{}),
        .difference = try b.declare(&.{ bytes, bytes, e.integer }, e.integer, &.{}, &.{}),
        .machine = m,
        .lifecycle = try @import("lifecycle.zig").define(b, m),
        .step = try @import("step.zig").define(b, m),
        .observe = try @import("observe.zig").define(b, m),
        .admit = try @import("analysis_values.zig").define(b, m),
        .graph = try @import("graph.zig").define(b, m),
        .output = output,
        .binding = binding,
        .capture = capture,
    };
}

fn defineEntry(
    e: Author,
    d: Definition,
    program: projection.Program,
    start: ReplayStart,
    checkpoint: ?projection.State,
) Error!void {
    const b = e.b;
    const input = try e.param(d.entry, 0);
    const transcript = try e.field(input, 0);
    const projected = try e.literal(projection.Program, program);
    const machine = try b.variable(d.machine.schema);
    const initial = if (checkpoint) |state| try e.call(d.machine.hydrate, &.{
        projected, try e.literal(projection.State, state),
    }) else try e.call(d.lifecycle.initialize, &.{
        projected, try e.literal([]const u8, start.arguments),
    });
    const execute = try b.bind(machine, initial, try e.call(d.advance, &.{
        input, try b.reference(machine), e.zero, try e.field(input, 1),
    }));
    const valid_ending = try validateEnding(e, try e.field(transcript, 2), execute);
    const same = try b.variable(e.boolean);
    try b.define(d.entry, try b.bind(same, try e.call(try equality.define(ReplayBinding, b), &.{
        try e.field(transcript, 0), try e.literal(ReplayBinding, d.binding),
    }), try e.when(try b.reference(same), valid_ending, try e.fail())));
}

fn tag(e: Author, value: Id) Error!Id {
    return e.b.primitive(e.integer, .variant_tag, &.{value}, 0);
}

fn validateEnding(e: Author, selected_ending: Id, body: Id) Error!Id {
    const observed_tag = try tag(e, try e.payload(selected_ending, 1));
    var terminal_branch = try e.fail();
    inline for (.{ "completed", "failed", "cancelled" }) |name| {
        terminal_branch = try e.when(try e.binary(.equal, observed_tag, try e.b.constant(
            u64,
            machines.index(Observation, name),
        )), body, terminal_branch);
    }
    return e.when(try e.binary(.equal, try tag(e, selected_ending), e.zero), body, terminal_branch);
}

fn status(e: Author, d: Definition, machine: Id) Error!Id {
    return edges.field(e, try d.machine.field(e, machine, .header), machines.Header, "status");
}

fn stop(e: Author, comptime name: []const u8, payload: Id) Error!Id {
    return e.variant(
        try projection.schema(ReplayStop, e.b),
        machines.index(ReplayStop, name),
        payload,
    );
}

fn finish(e: Author, d: Definition, c: Cursor, stopping: Id, observed: ?Id) Error!Id {
    const b = e.b;
    const observation = try b.variable(try projection.schema(Observation, b));
    const snapshot = try b.variable(d.machine.state);
    const output = try b.pure(try e.tuple(d.output, &.{
        try e.literal(ReplayBinding, d.binding),
        c.matched,
        try e.binary(.integer_sub, try e.field(c.input, 1), c.remaining),
        try status(e, d, c.machine),
        stopping,
        if (d.capture.observation) try e.variant(
            try projection.schema(?Observation, b),
            1,
            observed orelse try b.reference(observation),
        ) else try e.literal(?Observation, null),
        if (d.capture.snapshot) try e.variant(
            try projection.schema(?projection.State, b),
            1,
            try b.reference(snapshot),
        ) else try e.literal(?projection.State, null),
    }));
    const projected = if (d.capture.snapshot) try b.bind(
        snapshot,
        try e.call(d.machine.project, &.{c.machine}),
        output,
    ) else output;
    return if (d.capture.observation and observed == null) b.bind(
        observation,
        try e.call(d.observe, &.{c.machine}),
        projected,
    ) else projected;
}

fn finishTag(e: Author, d: Definition, c: Cursor, comptime name: []const u8) Error!Id {
    return finish(e, d, c, try stop(e, name, e.unit_value), null);
}

fn defineAdvance(e: Author, d: Definition) Error!void {
    const b = e.b;
    const c: Cursor = .{
        .input = try e.param(d.advance, 0),
        .machine = try e.param(d.advance, 1),
        .matched = try e.param(d.advance, 2),
        .remaining = try e.param(d.advance, 3),
    };
    const current = try b.primitive(try b.scalar(u32), .enum_tag, &.{
        try status(e, d, c.machine),
    }, 0);
    const stepped = try b.variable(d.step.result);
    const advance = try b.bind(stepped, try e.call(d.step.active, &.{c.machine}), try e.call(
        d.advance,
        &.{ c.input, try e.payload(try b.reference(stepped), 0), c.matched, try e.binary(
            .integer_sub,
            c.remaining,
            e.one,
        ) },
    ));
    const needs_step = try e.when(
        try e.binary(.less, e.zero, c.remaining),
        advance,
        try finishTag(e, d, c, "guest_quantum"),
    );
    var body = try terminal(e, d, c);
    inline for ([_]data.process_state.Status{ .active, .unwinding, .parked, .yielded }) |selected| {
        const branch = switch (selected) {
            .parked => try pending(e, d, c),
            .yielded => try finishTag(e, d, c, "yielded"),
            else => needs_step,
        };
        body = try e.when(try e.binary(.equal, current, try b.constant(
            u32,
            @backingInt(selected),
        )), branch, body);
    }
    try b.define(d.advance, body);
}

fn exchanges(e: Author, c: Cursor) Error!Id {
    return e.field(try e.field(c.input, 0), 1);
}

fn ending(e: Author, c: Cursor) Error!Id {
    return e.field(try e.field(c.input, 0), 2);
}

fn hasExchange(e: Author, c: Cursor) Error!Id {
    return e.binary(.less, c.matched, try e.b.primitive(
        e.integer,
        .sequence_length,
        &.{try exchanges(e, c)},
        0,
    ));
}

fn terminal(e: Author, d: Definition, c: Cursor) Error!Id {
    const b = e.b;
    const observed = try b.variable(try projection.schema(Observation, b));
    const actual = try b.reference(observed);
    const same = try b.variable(e.boolean);
    const comparison = try b.bind(same, try e.call(try equality.define(Observation, b), &.{
        actual, try e.payload(try ending(e, c), 1),
    }), try e.when(
        try b.reference(same),
        try finish(e, d, c, try stop(e, "terminal_matched", e.unit_value), actual),
        try finish(e, d, c, try stop(e, "terminal_mismatch", e.unit_value), actual),
    ));
    const checked = try b.bind(observed, try e.call(d.observe, &.{c.machine}), comparison);
    return e.when(
        try hasExchange(e, c),
        try finish(e, d, c, try stop(e, "unused_exchanges", c.matched), null),
        try e.when(
            try e.binary(.equal, try tag(e, try ending(e, c)), e.zero),
            try finishTag(e, d, c, "terminal_observed"),
            checked,
        ),
    );
}

fn pending(e: Author, d: Definition, c: Cursor) Error!Id {
    const absent = try e.when(
        try e.binary(.equal, try tag(e, try ending(e, c)), e.zero),
        try finishTag(e, d, c, "prefix_exhausted"),
        try finishTag(e, d, c, "missing_exchange"),
    );
    const node = try e.b.variable(try projection.schema(data.graph.Node, e.b));
    const request = try e.payload(try e.b.reference(node), @backingInt(data.graph.NodeTag.pending));
    const header = try d.machine.field(e, c.machine, .header);
    const roots = try edges.field(e, header, machines.Header, "roots");
    const id = try e.payload(try edges.field(e, roots, data.graph.Roots, "pending"), 1);
    const exchange = try e.required(try exchanges(e, c), c.matched);
    const expected = try e.field(exchange, 0);
    const actual_effect = try e.field(request, 0);
    const expected_effect = try e.field(expected, 0);
    const mismatch = try e.tuple(try projection.schema(
        @FieldType(ReplayStop, "effect_mismatch"),
        e.b,
    ), &.{ c.matched, expected_effect, actual_effect });
    const matched = try e.when(
        try e.binary(.equal, expected_effect, actual_effect),
        try comparePayload(e, d, c, exchange, actual_effect),
        try finish(e, d, c, try stop(e, "effect_mismatch", mismatch), null),
    );
    const inspect = try e.b.bind(node, try e.call(d.graph.record, &.{ c.machine, id }), matched);
    return e.when(try hasExchange(e, c), inspect, absent);
}

fn comparePayload(e: Author, d: Definition, c: Cursor, exchange: Id, effect: Id) Error!Id {
    const b = e.b;
    const observed = try b.variable(try projection.schema(Observation, b));
    const actual = try e.payload(
        try b.reference(observed),
        machines.index(Observation, "requested"),
    );
    const expected_bytes = try e.field(try e.field(exchange, 0), 1);
    const actual_bytes = try e.field(actual, 1);
    const comparison = try b.primitive(try b.scalar(i8), .blob_compare, &.{
        expected_bytes, actual_bytes,
    }, 0);
    const mismatched = try payloadMismatch(e, d, c, .{
        .expected = expected_bytes,
        .actual = actual_bytes,
        .observed = try b.reference(observed),
    });
    const body = try e.when(
        try e.binary(.equal, comparison, try b.constant(i8, 0)),
        try respond(e, d, c, try e.field(exchange, 1), effect),
        mismatched,
    );
    return b.bind(observed, try e.call(d.observe, &.{c.machine}), body);
}

const Payloads = struct { expected: Id, actual: Id, observed: Id };

fn payloadMismatch(e: Author, d: Definition, c: Cursor, bytes: Payloads) Error!Id {
    const difference = try e.b.variable(e.integer);
    const witness = try e.tuple(try projection.schema(
        @FieldType(ReplayStop, "payload_mismatch"),
        e.b,
    ), &.{
        c.matched,
        try e.b.primitive(e.integer, .blob_length, &.{bytes.expected}, 0),
        try e.b.primitive(e.integer, .blob_length, &.{bytes.actual}, 0),
        try e.b.reference(difference),
    });
    return e.b.bind(difference, try e.call(d.difference, &.{
        bytes.expected, bytes.actual, e.zero,
    }), try finish(e, d, c, try stop(e, "payload_mismatch", witness), bytes.observed));
}

fn respond(e: Author, d: Definition, c: Cursor, reply: Id, effect: Id) Error!Id {
    const b = e.b;
    const changed = try b.variable(d.machine.schema);
    const answer = try b.bind(changed, try e.call(d.lifecycle.respond, &.{
        c.machine, reply,
    }), try e.call(d.advance, &.{
        c.input,
        try b.reference(changed),
        try e.binary(.integer_add, c.matched, e.one),
        c.remaining,
    }));
    const program = try d.machine.field(e, c.machine, .program);
    const code = try edges.code(e, program);
    const effects = try edges.field(e, code, data.activation.Program, "effects");
    const actual_effect = try e.required(effects, effect);
    const schema = try edges.field(e, actual_effect, data.program.Effect, "result");
    const end = try b.variable(e.integer);
    const length = try b.primitive(e.integer, .blob_length, &.{reply}, 0);
    return b.bind(end, try e.call(d.admit.value, &.{ program, schema, reply, e.zero }), try e.when(
        try e.binary(.equal, try b.reference(end), length),
        answer,
        try e.fail(),
    ));
}

fn defineDifference(e: Author, f: Id) Error!void {
    const b = e.b;
    const left = try e.param(f, 0);
    const right = try e.param(f, 1);
    const at = try e.param(f, 2);
    const left_length = try b.primitive(e.integer, .blob_length, &.{left}, 0);
    const right_length = try b.primitive(e.integer, .blob_length, &.{right}, 0);
    const option = try projection.schema(?u8, b);
    const left_byte = try e.payload(try b.primitive(option, .blob_byte, &.{ left, at }, 0), 1);
    const right_byte = try e.payload(try b.primitive(option, .blob_byte, &.{ right, at }, 0), 1);
    const done = try b.pure(at);
    const more = try e.when(
        try e.binary(.equal, left_byte, right_byte),
        try e.call(f, &.{ left, right, try e.binary(.integer_add, at, e.one) }),
        done,
    );
    try b.define(f, try e.when(try e.binary(.less, at, left_length), try e.when(
        try e.binary(.less, at, right_length),
        more,
        done,
    ), done));
}
