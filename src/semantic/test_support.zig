//! Shared test setup and fixed inputs. Test cases stay in their owning suites.
//! Expected transitions come from the frozen evaluator, never the portable core.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const steps = @import("step.zig");
const Author = @import("author.zig").Author;
const base = @import("../base/session.zig");
const native = @import("native_baseline");
const service = @import("service.zig");
const a = std.testing.allocator;
pub const Output = struct { state: data.process_state.State, work: u64 };

pub fn encode(module: source.Module) ![]u8 {
    var diagnostic: source.Diagnostic = .{};
    var compiled = source.lowerObserved(a, module, .{ .diagnostic = &diagnostic }) catch |err| {
        std.debug.print("test source lowering: {any}\n", .{diagnostic});
        return err;
    };
    defer compiled.deinit();
    return encodeCompiled(&compiled);
}

pub fn encodeCompiled(compiled: *const source.Compiled) ![]u8 {
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    return bytes;
}

pub fn prepare(module: source.Module) !base.Prepared {
    const image = try encode(module);
    defer a.free(image);
    return base.Prepared.init(a, image);
}

pub fn prepareCore() !base.Prepared {
    return prepareCoreWithCollection(false);
}

pub fn prepareCoreWithCollection(comptime collecting: bool) !base.Prepared {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const machine = try machines.define(&b);
    const step = try steps.define(&b, machine);
    const output = try projection.schema(Output, &b);
    const entry = try b.declare(&.{ machine.program, machine.state }, output, &.{}, &.{});
    const hydrated = try b.variable(machine.schema);
    const advanced = try b.variable(step.result);
    const projected = try b.variable(machine.state);
    const result = try e.payload(try b.reference(advanced), 0);
    const collected = try b.variable(machine.schema);
    const committed = if (collecting) try b.reference(collected) else result;
    var body = try b.bind(
        projected,
        try e.call(machine.project, &.{
            committed,
        }),
        try b.pure(
            try e.tuple(
                output,
                &.{ try b.reference(projected), try machine.field(e, committed, .work) },
            ),
        ),
    );
    if (collecting) body = try b.bind(collected, try e.call(
        (try @import("collect.zig").define(&b, machine)).run,
        &.{result},
    ), body);
    try b.define(entry, try b.bind(hydrated, try e.call(machine.hydrate, &.{
        try e.param(entry, 0), try e.param(entry, 1),
    }), try b.bind(advanced, try e.call(
        step.active,
        &.{try b.reference(hydrated)},
    ), body)));
    return prepare(b.module(entry, e.unit));
}

pub fn guestImage() ![]u8 {
    const p = data.program;
    const program: data.activation.Program = .{
        .roots = .{ .entry = 0, .result = 1, .failure = 0 },
        .schemas = &.{ .unit, .u64, .boolean, .bytes },
        .constants = &.{ .{
            .schema = 1,
            .bytes = &std.mem.toBytes(@as(u64, 7)),
        }, .{ .schema = 0, .bytes = &.{} }, .{
            .schema = 3,
            .bytes = &.{ 3, 1, 2, 3 },
        } },
        .effects = &.{},
        .functions = &.{.{ .entry = 0, .inputs = &.{0}, .layout = .{
            .slots = &.{ 1, 1, 1, 1, 2, 3, 1 },
        }, .result = 1 }},
        .blocks = &.{.{ .function = 0, .instructions = &.{
            .{ .destination = 1, .opcode = .constant, .immediate = 0 },
            .{ .destination = 2, .opcode = .integer_add, .operands = &.{ 0, 1 }, .failures = &.{
                p.InstructionFailure{ .kind = .arithmetic_overflow, .value = 1 },
            } },
            .{ .destination = 3, .opcode = .integer_bit_xor, .operands = &.{ 2, 1 } },
            .{ .destination = 4, .opcode = .less, .operands = &.{ 3, 2 } },
            .{ .destination = 5, .opcode = .constant, .immediate = 2 },
            .{ .destination = 6, .opcode = .move, .operands = &.{3} },
        }, .terminator = .{ .return_value = 6 } }},
    };
    const image = try a.alloc(u8, try data.program_image.encodedLength(program));
    errdefer a.free(image);
    _ = try data.program_image.encode(a, program, image);
    return image;
}

pub fn expectNativeCuts(
    core: *base.Prepared,
    image: []const u8,
    input: []const u8,
    max_steps: usize,
) !void {
    return expectNativeCutsWithReplies(core, image, input, max_steps, null);
}

/// Admit the proposed portable state, then independently advance the oracle.
pub fn expectNativeSuccessor(
    guest: *native.Session,
    admitted: *const data.program_image.Admitted,
    successor: data.process_state.State,
) !void {
    var canonical = try data.state_image.canonicalize(a, successor);
    defer canonical.deinit();
    try data.state_admission.validateAdmitted(a, admitted, canonical.state);
    const actual = try data.state_image.emit(a, canonical.state);
    defer a.free(actual);
    try guest.step();
    const expected = try guest.checkpoint(a);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

pub fn expectNativeCutsWithReplies(
    core: *base.Prepared,
    image: []const u8,
    input: []const u8,
    max_steps: usize,
    responder: ?*const fn (*native.Session, data.program.Schema) anyerror!void,
) !void {
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    var guest = try native.Session.initImage(a, image, input);
    defer guest.deinit();
    for (0..max_steps + 1) |cut| {
        const before = try guest.checkpoint(a);
        defer a.free(before);
        var decoded = try data.state_image.decodeGraph(a, before);
        defer decoded.deinit();
        if (decoded.state.status == .completed or
            decoded.state.status == .failed or decoded.state.status == .cancelled) return;
        if (decoded.state.status == .parked) {
            const reply = responder orelse return error.MissingTestResponse;
            const pending = decoded.state.nodes[
                @intCast(decoded.state.roots.pending.?.id)
            ].record.pending;
            try reply(&guest, admitted.program().schemas[
                @intCast(admitted.program().effects[@intCast(pending.effect)].result)
            ]);
            continue;
        }
        if (decoded.state.status == .yielded) {
            try guest.resumeYield();
            continue;
        }
        try std.testing.expect(cut < max_steps);
        const state = try projection.stateBytes(a, admitted, decoded.state);
        defer a.free(state);
        const arguments = try std.mem.concat(a, u8, &.{ program, state });
        defer a.free(arguments);
        var portable = try base.Session.start(a, core, arguments, .{});
        defer portable.deinit();
        const outcome = try portable.run(null);
        if (outcome != .completed) std.debug.print(
            "portable cut {d}: {s}\n",
            .{ cut, @tagName(outcome) },
        );
        try std.testing.expect(outcome == .completed);
        var result = try projection.decode(Output, a, try portable.bytes(&outcome.completed));
        defer result.deinit();
        try std.testing.expectEqual(@as(u64, 1), result.value.work);
        try expectNativeSuccessor(&guest, admitted, result.value.state);
    }
    return error.TestUnexpectedResult;
}

// A host response is a fixture input. Every guest transition before and after
// it is independently executed by the authored core and compared as PST3.
pub fn respond(guest: *native.Session, shape: data.program.Schema) !void {
    var pending = try guest.pendingRequest(a);
    defer pending.deinit();
    const number = std.mem.toBytes(@as(u64, 41));
    const bytes: []const u8 = switch (shape) {
        .unit => &.{},
        .u64 => &number,
        else => return error.UnsupportedTestResponse,
    };
    const wire = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = pending.request.request_identity,
        .value = bytes,
    });
    defer a.free(wire);
    try guest.answer(wire);
}

pub fn send(session: *base.Session, command: service.Command) !void {
    var pending = try session.pendingBinding(a, false);
    defer pending.deinit();
    const value = try projection.encode(service.Command, a, command);
    defer a.free(value);
    const response = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = pending.request.request_identity,
        .value = value,
    });
    defer a.free(response);
    try session.answer(response);
}
pub fn event(session: *base.Session) !projection.Owned(service.Event) {
    const result = try session.run(null);
    if (result != .requested) std.debug.print(
        "service event unexpectedly {s}\n",
        .{@tagName(result)},
    );
    try std.testing.expect(result == .requested);
    return projection.decode(service.Event, a, try session.bytes(&result.requested.payload));
}
