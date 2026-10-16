const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const steps = @import("step.zig");
const Author = @import("author.zig").Author;
const base = @import("../base/session.zig");
const native = @import("../../test_oracle.zig");
const a = std.testing.allocator;
const Output = struct { state: data.process_state.State, work: u64 };

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
    var body = try b.bind(projected, try e.call(machine.project, &.{committed}), try b.pure(try e.tuple(output, &.{ try b.reference(projected), try machine.field(e, committed, .work) })));
    if (collecting) body = try b.bind(collected, try e.call((try @import("collect.zig").define(&b, machine)).run, &.{result}), body);
    try b.define(entry, try b.bind(hydrated, try e.call(machine.hydrate, &.{ try e.param(entry, 0), try e.param(entry, 1) }), try b.bind(advanced, try e.call(step.active, &.{try b.reference(hydrated)}), body)));
    var diagnostic: source.Diagnostic = .{};
    var compiled = source.lowerObserved(a, b.module(entry, e.unit), .{ .diagnostic = &diagnostic }) catch |err| {
        std.debug.print("step lowering: {any}\n", .{diagnostic});
        std.debug.print("collections: {any}; operations: {any}\n", .{ try @import("collections.zig").define(&b, machine), try @import("collection_instructions.zig").define(&b, machine) });
        if (diagnostic.function) |id| std.debug.print("source function: {any}\n", .{b.functions.items[@intCast(id)]});
        return err;
    };
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    return base.Prepared.init(a, image);
}

pub fn guestImage() ![]u8 {
    const p = data.program;
    const program: data.activation.Program = .{
        .roots = .{ .entry = 0, .result = 1, .failure = 0 },
        .schemas = &.{ .unit, .u64, .boolean, .bytes },
        .constants = &.{ .{ .schema = 1, .bytes = &std.mem.toBytes(@as(u64, 7)) }, .{ .schema = 0, .bytes = &.{} }, .{ .schema = 3, .bytes = &.{ 3, 1, 2, 3 } } },
        .effects = &.{},
        .functions = &.{.{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 1, 1, 1, 1, 2, 3, 1 } }, .result = 1 }},
        .blocks = &.{.{ .function = 0, .instructions = &.{
            .{ .destination = 1, .opcode = .constant, .immediate = 0 },
            .{ .destination = 2, .opcode = .integer_add, .operands = &.{ 0, 1 }, .failures = &.{p.InstructionFailure{ .kind = .arithmetic_overflow, .value = 1 }} },
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

test "authored guest scalar instruction cuts equal native canonical PST3" {
    var core = try prepareCore();
    defer core.deinit();
    const image = try guestImage();
    defer a.free(image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    for ([_]u64{ 0, 17, std.math.maxInt(u64) - 7 }) |input| {
        var guest = try native.Session.initImage(a, image, &std.mem.toBytes(input));
        defer guest.deinit();
        for (0..7) |instruction| {
            const before = try guest.checkpoint(a);
            defer a.free(before);
            var decoded = try data.state_image.decodeGraph(a, before);
            defer decoded.deinit();
            const state = try projection.stateBytes(a, admitted, decoded.state);
            defer a.free(state);
            const arguments = try std.mem.concat(a, u8, &.{ program, state });
            defer a.free(arguments);
            var portable = try base.Session.start(a, &core, arguments, .{});
            defer portable.deinit();
            const outcome = try portable.run(null);
            if (outcome != .completed) std.debug.print("portable instruction {d}: {s}\n", .{ instruction, @tagName(outcome) });
            try std.testing.expect(outcome == .completed);
            var result = try projection.decode(Output, a, try portable.bytes(&outcome.completed));
            defer result.deinit();
            try std.testing.expectEqual(@as(u64, 1), result.value.work);
            var canonical = try data.state_image.canonicalize(a, result.value.state);
            defer canonical.deinit();
            try data.state_admission.validateAdmitted(a, admitted, canonical.state);
            const actual = try data.state_image.emit(a, canonical.state);
            defer a.free(actual);
            try guest.step();
            const expected = try guest.checkpoint(a);
            defer a.free(expected);
            try std.testing.expectEqualSlices(u8, expected, actual);
        }
    }
}

test "authored instruction faults enter guest failure unwinding at the same native cut" {
    var core = try prepareCore();
    defer core.deinit();
    const image = try guestImage();
    defer a.free(image);
    for ([_]u64{ std.math.maxInt(u64) - 6, std.math.maxInt(u64) }) |input|
        try expectNativeCuts(&core, image, &std.mem.toBytes(input), 40);
}

fn controlImage() ![]u8 {
    const continuation: data.activation.Edge = .{ .block = 4, .assignments = &.{
        .{ .destination = 3, .source = .returned },
        .{ .destination = 4, .source = .{ .slot = 0 } },
    } };
    const program: data.activation.Program = .{
        .roots = .{ .entry = 0, .result = 1, .failure = 0 },
        .schemas = &.{ .unit, .u64, .boolean },
        .constants = &.{},
        .effects = &.{},
        .functions = &.{
            .{ .entry = 0, .inputs = &.{ 0, 1, 2 }, .layout = .{ .slots = &.{ 1, 1, 2, 1, 1, 1 } }, .result = 1 },
            .{ .entry = 5, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 1, 1, 1 } }, .result = 1 },
            .{ .entry = 6, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 1, 1, 1 } }, .result = 1 },
        },
        .blocks = &.{
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 1, .assignments = &.{
                .{ .destination = 0, .source = .{ .slot = 1 } },
                .{ .destination = 1, .source = .{ .slot = 0 } },
            } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .branch = .{ .condition = 2, .when_true = .{ .block = 2 }, .when_false = .{ .block = 3 } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .call = .{ .function = 1, .arguments = &.{ 0, 1 }, .next = continuation } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .call = .{ .function = 2, .arguments = &.{ 0, 1 }, .next = continuation } } },
            .{ .function = 0, .instructions = &.{.{ .destination = 5, .opcode = .integer_bit_xor, .operands = &.{ 3, 4 } }}, .terminator = .{ .return_value = 5 } },
            .{ .function = 1, .instructions = &.{.{ .destination = 2, .opcode = .integer_bit_xor, .operands = &.{ 0, 1 } }}, .terminator = .{ .return_value = 2 } },
            .{ .function = 2, .instructions = &.{}, .terminator = .{ .call = .{ .function = 1, .arguments = &.{ 1, 0 }, .next = .{ .block = 7, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } },
            .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        },
    };
    const image = try a.alloc(u8, try data.program_image.encodedLength(program));
    errdefer a.free(image);
    _ = try data.program_image.encode(a, program, image);
    return image;
}

test "authored simultaneous edges branches calls and returns equal every native cut" {
    var core = try prepareCore();
    defer core.deinit();
    const image = try controlImage();
    defer a.free(image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    for ([_]bool{ false, true }) |condition| {
        const input = try std.mem.concat(a, u8, &.{ &std.mem.toBytes(@as(u64, 39)), &std.mem.toBytes(@as(u64, 11)), &.{@intFromBool(condition)} });
        defer a.free(input);
        var guest = try native.Session.initImage(a, image, input);
        defer guest.deinit();
        for (0..16) |cut| {
            const before = try guest.checkpoint(a);
            defer a.free(before);
            var decoded = try data.state_image.decodeGraph(a, before);
            defer decoded.deinit();
            if (decoded.state.status == .completed) break;
            try std.testing.expect(cut < 15);
            const state = try projection.stateBytes(a, admitted, decoded.state);
            defer a.free(state);
            const arguments = try std.mem.concat(a, u8, &.{ program, state });
            defer a.free(arguments);
            var portable = try base.Session.start(a, &core, arguments, .{});
            defer portable.deinit();
            const outcome = try portable.run(null);
            if (outcome != .completed) std.debug.print("control cut {d}: {s}\n", .{ cut, @tagName(outcome) });
            try std.testing.expect(outcome == .completed);
            var result = try projection.decode(Output, a, try portable.bytes(&outcome.completed));
            defer result.deinit();
            try std.testing.expectEqual(@as(u64, 1), result.value.work);
            var canonical = try data.state_image.canonicalize(a, result.value.state);
            defer canonical.deinit();
            try data.state_admission.validateAdmitted(a, admitted, canonical.state);
            const actual = try data.state_image.emit(a, canonical.state);
            defer a.free(actual);
            try guest.step();
            const expected = try guest.checkpoint(a);
            defer a.free(expected);
            if (!std.mem.eql(u8, expected, actual)) std.debug.print("control divergence condition={any} cut={d}\n", .{ condition, cut });
            try std.testing.expectEqualSlices(u8, expected, actual);
        }
    }
}

pub fn expectNativeCuts(core: *base.Prepared, image: []const u8, input: []const u8, max_steps: usize) !void {
    return expectNativeCutsWithReplies(core, image, input, max_steps, null);
}

pub fn expectNativeCutsWithReplies(core: *base.Prepared, image: []const u8, input: []const u8, max_steps: usize, responder: ?*const fn (*native.Session, data.program.Schema) anyerror!void) !void {
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
        if (decoded.state.status == .completed or decoded.state.status == .failed or decoded.state.status == .cancelled) return;
        if (decoded.state.status == .parked) {
            const reply = responder orelse return error.MissingTestResponse;
            const pending = decoded.state.nodes[@intCast(decoded.state.roots.pending.?.id)].record.pending;
            try reply(&guest, admitted.program().schemas[@intCast(admitted.program().effects[@intCast(pending.effect)].result)]);
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
        if (outcome != .completed) std.debug.print("portable cut {d}: {s}\n", .{ cut, @tagName(outcome) });
        try std.testing.expect(outcome == .completed);
        var result = try projection.decode(Output, a, try portable.bytes(&outcome.completed));
        defer result.deinit();
        try std.testing.expectEqual(@as(u64, 1), result.value.work);
        var canonical = try data.state_image.canonicalize(a, result.value.state);
        defer canonical.deinit();
        try data.state_admission.validateAdmitted(a, admitted, canonical.state);
        const actual = try data.state_image.emit(a, canonical.state);
        defer a.free(actual);
        try guest.step();
        const expected = try guest.checkpoint(a);
        defer a.free(expected);
        if (!std.mem.eql(u8, expected, actual)) std.debug.print("portable divergence cut={d}\n", .{cut});
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
    return error.TestUnexpectedResult;
}

test "authored products variants projections selection and aggregate control match native cuts" {
    var core = try prepareCore();
    defer core.deinit();
    const program: data.activation.Program = .{
        .roots = .{ .entry = 0, .result = 1, .failure = 0 },
        .schemas = &.{ .unit, .u64, .bytes, .{ .product = &.{ 1, 2 } }, .{ .sum = &.{ 0, 3 } }, .boolean },
        .constants = &.{ .{ .schema = 0, .bytes = &.{} }, .{ .schema = 2, .bytes = &.{ 3, 4, 5, 6 } } },
        .effects = &.{},
        .functions = &.{.{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 1, 2, 3, 4, 1, 3, 1, 5, 3, 1, 2 } }, .result = 1 }},
        .blocks = &.{
            .{ .function = 0, .instructions = &.{
                .{ .destination = 1, .opcode = .constant, .immediate = 1 },
                .{ .destination = 2, .opcode = .product, .operands = &.{ 0, 1 } },
                .{ .destination = 3, .opcode = .variant, .operands = &.{2}, .immediate = 1 },
                .{ .destination = 4, .opcode = .variant_tag, .operands = &.{3} },
                .{ .destination = 5, .opcode = .variant_payload, .operands = &.{3}, .immediate = 1, .failures = &.{.{ .kind = .invalid_variant, .value = 0 }} },
                .{ .destination = 6, .opcode = .field, .operands = &.{5}, .immediate = 0 },
                .{ .destination = 7, .opcode = .less, .operands = &.{ 6, 4 } },
                .{ .destination = 8, .opcode = .select, .operands = &.{ 7, 2, 5 } },
            }, .terminator = .{ .switch_variant = .{ .value = 3, .cases = &.{ .{ .block = 2 }, .{ .block = 1, .assignments = &.{.{ .destination = 8, .source = .returned }} } } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .unpack_product = .{ .value = 8, .destinations = &.{ 9, 10 }, .next = .{ .block = 3 } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 9 } },
        },
    };
    const image = try a.alloc(u8, try data.program_image.encodedLength(program));
    defer a.free(image);
    _ = try data.program_image.encode(a, program, image);
    for ([_]u64{ 0, 1, std.math.maxInt(u64) }) |input| try expectNativeCuts(&core, image, &std.mem.toBytes(input), 20);
}
