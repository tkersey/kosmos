const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const analysis = @import("analysis.zig");
const projection = @import("projection.zig");
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");

test "hypothetical reply interpretation runs ordinary source without consuming a live request" {
    var guest_builder = source.Builder.init(a);
    defer guest_builder.deinit();
    const image = try support.encode(try analysis.exampleGuest(&guest_builder));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    const arguments = [_]u8{ 10, 0, 0, 0, 0, 0, 0, 0 };
    var live = try @import("native_baseline").Session.initImage(a, image, &arguments);
    defer live.deinit();
    try std.testing.expect(try live.run(null) == .requested);
    const before = try live.checkpoint(a);
    defer a.free(before);
    var pending = try live.pendingRequest(a);
    defer pending.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    var diagnostic: source.Diagnostic = .{};
    const module = try analysis.example(&builder);
    var compiled = source.lowerObserved(a, module, .{ .diagnostic = &diagnostic }) catch |err| {
        std.debug.print("interpretation lowering: {any}\n", .{diagnostic});
        return err;
    };
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.program.effects.len);
    const code = try support.encodeCompiled(&compiled);
    defer a.free(code);
    for ([_]u64{ 0, 1, 2, 3, 8 }) |quantum| {
        for ([_][]const u8{ &.{}, &encodedInteger(5) }) |reply|
            try expectBudgetedHypothetical(code, image, &arguments, quantum, reply);
    }
    try expectHypotheticalReplies(code, guest, &arguments, &live);
    try expectMalformedReplies(code, guest, &arguments);
    const after = try live.checkpoint(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    const actual_reply = [_]u8{ 7, 0, 0, 0, 0, 0, 0, 0 };
    const response = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = pending.request.request_identity,
        .value = &actual_reply,
    });
    defer a.free(response);
    try live.answer(response);
    const result = try live.run(null);
    try std.testing.expect(result == .completed);
    try std.testing.expectEqual(@as(u64, 17), std.mem.readInt(
        u64,
        (try live.bytes(&result.completed))[0..8],
        .little,
    ));
}

test "hypothetical analysis admits both arguments and the actual pending reply schema" {
    var guest_builder = source.Builder.init(a);
    defer guest_builder.deinit();
    const image = try support.encode(try booleanGuest(&guest_builder));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    var compiled = try source.lower(a, try analysis.hypotheticalReply(&builder, guest));
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.program.effects.len);
    const code = try support.encodeCompiled(&compiled);
    defer a.free(code);
    const Case = struct { arguments: []const u8, reply: []const u8, expected: ?u8 };
    for ([_]Case{
        .{ .arguments = &.{1}, .reply = &.{1}, .expected = 1 },
        .{ .arguments = &.{0}, .reply = &.{1}, .expected = 0 },
        .{ .arguments = &.{1}, .reply = &.{2}, .expected = null },
        .{ .arguments = &.{2}, .reply = &.{1}, .expected = null },
        .{ .arguments = &.{1}, .reply = &.{ 1, 0 }, .expected = null },
        .{ .arguments = &.{ 1, 0 }, .reply = &.{1}, .expected = null },
        .{ .arguments = &.{}, .reply = &.{1}, .expected = null },
        .{ .arguments = &.{1}, .reply = &.{}, .expected = null },
    }) |case| {
        const input = try projection.encode(analysis.Input, a, .{
            .arguments = case.arguments,
            .assumed_reply = case.reply,
            .guest_quantum = 100,
        });
        defer a.free(input);
        var experiment = try base.Session.initImage(a, code, input, .{});
        defer experiment.deinit();
        const outcome = try experiment.run(null);
        if (case.expected) |expected| {
            try std.testing.expect(outcome == .completed);
            var result = try projection.decode(
                analysis.Output,
                a,
                try experiment.bytes(&outcome.completed),
            );
            defer result.deinit();
            try std.testing.expect(result.value.assumption_applied);
            try std.testing.expect(result.value.observation == .completed);
            try std.testing.expectEqualSlices(u8, &.{expected}, result.value.observation.completed);
        } else try std.testing.expect(outcome == .failed);
    }
}

fn expectBudgetedHypothetical(
    code: []const u8,
    image: []const u8,
    arguments: []const u8,
    quantum: u64,
    reply: []const u8,
) !void {
    var reference = try @import("native_baseline").Session.initImage(a, image, arguments);
    defer reference.deinit();
    var expected = try reference.run(quantum);
    const applied = expected == .requested and reference.transitions < quantum;
    if (applied and reply.len != 0) {
        var pending = try reference.pendingRequest(a);
        defer pending.deinit();
        const response = try data.invocation.encodeOwned(data.invocation.Result, a, .{
            .request_identity = pending.request.request_identity,
            .value = reply,
        });
        defer a.free(response);
        try reference.answer(response);
        expected = try reference.run(quantum - reference.transitions);
    }
    const input = try projection.encode(analysis.Input, a, .{
        .arguments = arguments,
        .assumed_reply = reply,
        .guest_quantum = quantum,
    });
    defer a.free(input);
    var experiment = try base.Session.initImage(a, code, input, .{});
    defer experiment.deinit();
    const outcome = try experiment.run(null);
    if (applied and reply.len == 0) {
        try std.testing.expect(outcome == .failed);
        return;
    }
    try std.testing.expect(outcome == .completed);
    var result = try projection.decode(
        analysis.Output,
        a,
        try experiment.bytes(&outcome.completed),
    );
    defer result.deinit();
    try std.testing.expectEqual(applied, result.value.assumption_applied);
    try std.testing.expectEqual(reference.transitions, result.value.guest_work);
    try std.testing.expectEqualStrings(@tagName(expected), @tagName(result.value.observation));
    switch (expected) {
        .requested => |request| {
            try std.testing.expectEqual(request.effect, result.value.observation.requested.effect);
            try std.testing.expectEqualSlices(
                u8,
                try reference.bytes(&request.payload),
                result.value.observation.requested.payload,
            );
        },
        .completed => |value| try std.testing.expectEqualSlices(
            u8,
            try reference.bytes(&value),
            result.value.observation.completed,
        ),
        else => {},
    }
}

fn expectHypotheticalReplies(
    code: []const u8,
    guest: *const data.program_image.Admitted,
    arguments: []const u8,
    live: *@import("native_baseline").Session,
) !void {
    for ([_]u8{ 5, 99 }) |assumed| {
        const reply = [_]u8{ assumed, 0, 0, 0, 0, 0, 0, 0 };
        const input = try projection.encode(analysis.Input, a, .{
            .arguments = arguments,
            .assumed_reply = &reply,
            .guest_quantum = 100,
        });
        defer a.free(input);
        var experiment = try base.Session.initImage(a, code, input, .{});
        defer experiment.deinit();
        const completed = try experiment.run(null);
        try std.testing.expect(completed == .completed);
        var result = try projection.decode(
            analysis.Output,
            a,
            try experiment.bytes(&completed.completed),
        );
        defer result.deinit();
        try std.testing.expectEqual(.hypothetical_first_reply, result.value.interpretation);
        try std.testing.expectEqualDeep(guest.identity(), result.value.guest);
        try std.testing.expectEqualSlices(u8, &reply, result.value.assumed_reply);
        try std.testing.expect(result.value.assumption_applied);
        try std.testing.expect(result.value.observation == .completed);
        try std.testing.expectEqual(@as(u64, 10 + @as(u64, assumed)), std.mem.readInt(
            u64,
            result.value.observation.completed[0..8],
            .little,
        ));
        try std.testing.expectError(error.InvalidFamily, live.answer(
            try experiment.bytes(&completed.completed),
        ));
    }
}

fn expectMalformedReplies(
    code: []const u8,
    guest: *const data.program_image.Admitted,
    arguments: []const u8,
) !void {
    for ([_][]const u8{ &.{}, &.{5}, &.{ 5, 0, 0, 0, 0, 0, 0, 0, 99 } }) |malformed| {
        try std.testing.expectError(
            if (malformed.len > 8) error.NonCanonical else error.InvalidValue,
            data.admission.value(
                a,
                guest.program().schemas,
                guest.schemaFacts(),
                .{ .schema = guest.program().effects[0].result, .bytes = malformed },
            ),
        );
        const input = try projection.encode(analysis.Input, a, .{
            .arguments = arguments,
            .assumed_reply = malformed,
            .guest_quantum = 100,
        });
        defer a.free(input);
        var experiment = try base.Session.initImage(a, code, input, .{});
        defer experiment.deinit();
        try std.testing.expect(try experiment.run(null) == .failed);
    }
}

fn booleanGuest(guest_builder: *source.Builder) !source.Module {
    const Author = @import("author.zig").Author;
    const e = try Author.init(guest_builder);
    const effect = try guest_builder.effect(.{
        .identity = "analysis/boolean",
        .payload = e.unit,
        .result = e.boolean,
    });
    const entry = try guest_builder.declare(&.{e.boolean}, e.boolean, &.{effect}, &.{});
    const answer = try guest_builder.variable(e.boolean);
    try guest_builder.define(
        entry,
        try guest_builder.bind(
            answer,
            try guest_builder.term(
                .{ .perform = .{
                    .effect = effect,
                    .payload = e.unit_value,
                } },
            ),
            try guest_builder.pure(try e.binary(
                .equal,
                try e.param(entry, 0),
                try guest_builder.reference(answer),
            )),
        ),
    );
    return guest_builder.module(entry, e.unit);
}

test "constructed interpretation retains alternatives and resumes missing assumptions as data" {
    var guest_builder = source.Builder.init(a);
    defer guest_builder.deinit();
    const image = try support.encode(try branchGuest(&guest_builder));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const program = try analysis.interpretation(&builder, guest, null);
    var compiled = try source.lower(a, program);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.program.effects.len);
    const code = try support.encodeCompiled(&compiled);
    defer a.free(code);
    const zero = encodedInteger(0);
    const one = encodedInteger(1);
    const seven = encodedInteger(7);
    const eleven = encodedInteger(11);
    var first = try runInterpretation(code, &.{ &zero, &seven }, 100);
    defer first.deinit();
    try std.testing.expectEqual(.terminal, first.value.stopping);
    try expectInterpretationValue(first.value, 7);
    var other = try runInterpretation(code, &.{ &one, &eleven }, 100);
    defer other.deinit();
    try std.testing.expectEqual(.missing_assumption, other.value.stopping);
    try std.testing.expectEqual(@as(u64, 2), other.value.applied);
    try std.testing.expectEqual(@as(usize, 2), other.value.requests.len);
    try std.testing.expectEqualSlices(u8, &zero, other.value.requests[0].request.payload);
    try std.testing.expectEqualSlices(u8, &one, other.value.requests[1].request.payload);
    try std.testing.expectEqualSlices(u8, &one, other.value.assumptions[0]);
    try std.testing.expect(other.value.observation == .requested);
    try std.testing.expectEqualSlices(u8, &eleven, other.value.observation.requested.payload);
    try expectResumedAlternative(guest, other.value.state);
    var unfinished = try runInterpretation(code, &.{ &zero, &seven }, 1);
    defer unfinished.deinit();
    try std.testing.expectEqual(.quantum, unfinished.value.stopping);
    try std.testing.expectEqual(@as(u64, 0), unfinished.value.applied);
    try expectSnapshotBinding(guest, unfinished.value.state);
}

test "constructed interpretation resumes retained yields and stops at subsequent yields" {
    var guest_builder = source.Builder.init(a);
    defer guest_builder.deinit();
    const entry = try guest_builder.declare(&.{}, try guest_builder.scalar(u64), &.{}, &.{});
    const completed = try guest_builder.pure(try guest_builder.constant(u64, 42));
    const second = try guest_builder.term(.{ .yield_then = completed });
    try guest_builder.define(entry, try guest_builder.term(.{ .yield_then = second }));
    const image = try support.encode(guest_builder.module(entry, try guest_builder.scalar(void)));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var first = try interpretSnapshot(guest, null);
    defer first.deinit();
    try expectYieldedInterpretation(first.value);
    var second_result = try interpretSnapshot(guest, first.value.state);
    defer second_result.deinit();
    try expectYieldedInterpretation(second_result.value);
    var final_result = try interpretSnapshot(guest, second_result.value.state);
    defer final_result.deinit();
    try std.testing.expectEqual(.terminal, final_result.value.stopping);
    try std.testing.expect(final_result.value.guest_work > 0);
    try std.testing.expectEqual(@as(u64, 0), final_result.value.applied);
    try std.testing.expectEqual(@as(usize, 0), final_result.value.requests.len);
    try expectInterpretationValue(final_result.value, 42);
    var repeated = try interpretSnapshot(guest, first.value.state);
    defer repeated.deinit();
    try expectYieldedInterpretation(repeated.value);
    const second_bytes = try data.state_image.emit(a, second_result.value.state);
    defer a.free(second_bytes);
    const repeated_bytes = try data.state_image.emit(a, repeated.value.state);
    defer a.free(repeated_bytes);
    try std.testing.expectEqualSlices(u8, second_bytes, repeated_bytes);
}

fn interpretSnapshot(
    guest: *const data.program_image.Admitted,
    state: ?projection.State,
) !projection.Owned(analysis.InterpretationOutput) {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const code = try support.encode(try analysis.interpretation(&builder, guest, state));
    defer a.free(code);
    return runInterpretation(code, &.{}, 100);
}

fn expectYieldedInterpretation(result: analysis.InterpretationOutput) !void {
    try std.testing.expectEqual(.yielded, result.stopping);
    try std.testing.expectEqual(.yielded, result.state.status);
    try std.testing.expect(result.guest_work > 0);
    try std.testing.expectEqual(@as(u64, 0), result.applied);
    try std.testing.expectEqual(@as(usize, 0), result.requests.len);
}

fn encodedInteger(value: u64) [8]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return bytes;
}

fn runInterpretation(
    code: []const u8,
    assumptions: []const []const u8,
    quantum: u64,
) !projection.Owned(analysis.InterpretationOutput) {
    const input = try projection.encode(analysis.InterpretationInput, a, .{
        .arguments = &.{},
        .assumptions = assumptions,
        .guest_quantum = quantum,
    });
    defer a.free(input);
    var experiment = try base.Session.initImage(a, code, input, .{});
    defer experiment.deinit();
    try std.testing.expect(try experiment.run(1) == .progressed);
    const checkpoint = try experiment.checkpoint(a);
    defer a.free(checkpoint);
    var resumed = try base.Session.restoreImage(a, code, checkpoint, .{});
    defer resumed.deinit();
    const outcome = try resumed.run(null);
    try std.testing.expect(outcome == .completed);
    const bytes = try resumed.bytes(&outcome.completed);
    return projection.decode(analysis.InterpretationOutput, a, bytes);
}

fn expectInterpretationValue(result: analysis.InterpretationOutput, expected: u64) !void {
    try std.testing.expect(result.observation == .completed);
    const actual = std.mem.readInt(u64, result.observation.completed[0..8], .little);
    try std.testing.expectEqual(expected, actual);
}

fn expectResumedAlternative(
    guest: *const data.program_image.Admitted,
    state: projection.State,
) !void {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const code = try support.encode(try analysis.interpretation(&builder, guest, state));
    defer a.free(code);
    const five = encodedInteger(5);
    const nine = encodedInteger(9);
    var stopped = try runInterpretation(code, &.{&five}, 0);
    defer stopped.deinit();
    try std.testing.expectEqual(.quantum, stopped.value.stopping);
    try std.testing.expectEqual(@as(u64, 1), stopped.value.applied);
    try std.testing.expectEqual(@as(u64, 0), stopped.value.guest_work);
    try std.testing.expectEqual(@as(usize, 1), stopped.value.requests.len);
    try std.testing.expect(stopped.value.observation == .progressed);
    for ([_][]const u8{ &five, &nine }, [_]u64{ 16, 20 }) |reply, expected| {
        var result = try runInterpretation(code, &.{reply}, 100);
        defer result.deinit();
        try std.testing.expectEqual(.terminal, result.value.stopping);
        try std.testing.expectEqual(@as(u64, 1), result.value.applied);
        try expectInterpretationValue(result.value, expected);
    }
}

fn expectSnapshotBinding(guest: *const data.program_image.Admitted, state: projection.State) !void {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    var foreign = state;
    foreign.program_identity[0] ^= 1;
    if (analysis.interpretation(&builder, guest, foreign)) |_| {
        return error.ForeignSnapshotAccepted;
    } else |_| {}
    var incomplete = state;
    incomplete.nodes = &.{};
    if (analysis.interpretation(&builder, guest, incomplete)) |_| {
        return error.IncompleteSnapshotAccepted;
    } else |_| {}
}

fn branchGuest(b: *source.Builder) !source.Module {
    const Author = @import("author.zig").Author;
    const e = try Author.init(b);
    const effect = try b.effect(.{
        .identity = "analysis/branch-input",
        .payload = e.integer,
        .result = e.integer,
    });
    const entry = try b.declare(&.{}, e.integer, &.{effect}, &.{});
    const first = try b.variable(e.integer);
    const second = try b.variable(e.integer);
    const third = try b.variable(e.integer);
    const additional = try b.bind(third, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.reference(second),
    } }), try b.pure(try e.binary(.integer_add, try b.reference(second), try b.reference(third))));
    const finish = try e.when(
        try e.binary(.equal, try b.reference(first), e.zero),
        try b.pure(try b.reference(second)),
        additional,
    );
    try b.define(entry, try b.bind(first, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = e.zero,
    } }), try b.bind(second, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.reference(first),
    } }), finish)));
    return b.module(entry, e.unit);
}

const DisclosedInput = struct {
    program: projection.Program,
    state: projection.State,
    branch: bool,
    first_assumption: u64 = 0,
    replies_max: u64 = 3,
};
const DisclosedOutput = struct {
    observation: @import("observe.zig").Observation,
    assumptions: []const []const u8,
    steps: u64,
    state: projection.State,
    stopping: analysis.Stop,
};
const Disclosed = struct {
    hydrate: source.Id,
    respond: source.Id,
    observe: source.Id,
    step: source.Id,
    project: source.Id,
    advance: source.Id,
    output: source.Id,
};

pub fn expectDisclosedAnalysis(bundle: @import("compiler.zig").SourceBundle) !void {
    var builder = try disclosedBuilder(bundle.generic.module);
    defer builder.deinit();
    const entry = try disclosedEntry(&builder, bundle);
    const composed = builder.module(entry, bundle.generic.module.failure);
    var sliced = try source.slice.extract(a, composed, .{
        .entry = entry,
        .require_pure = true,
    });
    defer sliced.deinit();
    for (bundle.generic_pure_entries) |pure| switch (pure.role) {
        .hydrate, .respond, .step, .observe, .project => {
            try std.testing.expect(sliced.maps.functions[pure.function] != null);
        },
        else => {},
    };
    var prepared = try support.prepare(sliced.module());
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), sliced.module().effects.len);
    var guest_builder = source.Builder.init(a);
    defer guest_builder.deinit();
    const image = try support.encode(try branchGuest(&guest_builder));
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var live = try @import("native_baseline").Session.initImage(a, image, &.{});
    defer live.deinit();
    try std.testing.expect(try live.run(null) == .requested);
    const before = try live.checkpoint(a);
    defer a.free(before);
    var snapshot = try data.state_image.decodeGraph(a, before);
    defer snapshot.deinit();
    const projected = try projection.programBytes(a, guest);
    defer a.free(projected);
    var program = try projection.decode(projection.Program, a, projected);
    defer program.deinit();
    for ([_]bool{ false, true }, [_]u64{ 7, 20 }) |branch, expected| {
        try expectDisclosedBranch(&prepared, .{
            .program = program.value,
            .state = snapshot.state,
            .branch = branch,
        }, expected);
    }
    try expectDisclosedResume(&prepared, guest, program.value, snapshot.state);
    const after = try live.checkpoint(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

fn disclosedBuilder(module: source.Module) !source.Builder {
    var b = source.Builder.init(a);
    errdefer b.deinit();
    const owned = try source.own(source.Module, b.allocator(), module);
    inline for (.{
        "schemas", "constants", "effects",   "handlers", "resources", "variables",
        "values",  "terms",     "functions",
    }) |name| try @field(b, name).appendSlice(b.allocator(), @field(owned, name));
    b.region_count = owned.region_count;
    return b;
}

fn disclosedEntry(b: *source.Builder, bundle: @import("compiler.zig").SourceBundle) !source.Id {
    const e = try @import("author.zig").Author.init(b);
    var d: Disclosed = undefined;
    for (bundle.generic_pure_entries) |pure| switch (pure.role) {
        .hydrate => d.hydrate = pure.function,
        .respond => d.respond = pure.function,
        .observe => d.observe = pure.function,
        .step => d.step = pure.function,
        .project => d.project = pure.function,
        else => {},
    };
    const machine = b.functions.items[d.hydrate].result;
    const trace = try projection.schema([]const []const u8, b);
    d.output = try projection.schema(DisclosedOutput, b);
    d.advance = try b.declare(&.{
        machine, e.boolean, trace, e.integer, e.integer, e.integer,
    }, d.output, &.{}, &.{});
    try disclosedAdvance(e, d);
    const entry = try b.declare(&.{try projection.schema(DisclosedInput, b)}, d.output, &.{}, &.{});
    const input = try e.param(entry, 0);
    const hydrated = try b.variable(machine);
    try b.define(entry, try b.bind(hydrated, try e.call(d.hydrate, &.{
        try e.field(input, 0), try e.field(input, 1),
    }), try e.call(d.advance, &.{
        try b.reference(hydrated),
        try e.field(input, 2),
        try e.literal([]const []const u8, &.{}),
        try b.constant(u64, 100),
        try e.field(input, 3),
        try e.field(input, 4),
    })));
    return entry;
}

fn disclosedAdvance(e: @import("author.zig").Author, d: Disclosed) !void {
    const b = e.b;
    const machine = try e.param(d.advance, 0);
    const branch = try e.param(d.advance, 1);
    const trace = try e.param(d.advance, 2);
    const remaining = try e.param(d.advance, 3);
    const observed = try b.variable(b.functions.items[d.observe].result);
    const value = try b.reference(observed);
    const tag = try b.primitive(e.integer, .variant_tag, &.{value}, 0);
    const finish = try disclosedFinish(e, d, value, .terminal);
    const stepped = try b.variable(b.functions.items[d.step].result);
    const step = try b.bind(stepped, try e.call(d.step, &.{machine}), try e.call(d.advance, &.{
        try e.payload(try b.reference(stepped), 0),
        branch,
        trace,
        try e.binary(.integer_sub, remaining, e.one),
        try e.param(d.advance, 4),
        try e.param(d.advance, 5),
    }));
    const progress = try e.when(
        try e.binary(.less, e.zero, remaining),
        step,
        try disclosedFinish(e, d, value, .quantum),
    );
    const count = try b.primitive(e.integer, .sequence_length, &.{trace}, 0);
    const respond = try e.when(
        try e.binary(.less, count, try e.param(d.advance, 5)),
        try disclosedRespond(e, d),
        try disclosedFinish(e, d, value, .missing_assumption),
    );
    const next = try e.when(try e.binary(.equal, tag, try b.constant(u64, 2)), respond, finish);
    try b.define(d.advance, try b.bind(observed, try e.call(d.observe, &.{machine}), try e.when(
        try e.binary(.equal, tag, e.zero),
        progress,
        next,
    )));
}

fn disclosedRespond(e: @import("author.zig").Author, d: Disclosed) !source.Id {
    const b = e.b;
    const machine = try e.param(d.advance, 0);
    const branch = try e.param(d.advance, 1);
    const trace = try e.param(d.advance, 2);
    const count = try e.binary(
        .integer_add,
        try b.primitive(e.integer, .sequence_length, &.{trace}, 0),
        try e.param(d.advance, 4),
    );
    const bytes = try b.schema(.bytes);
    const zero = encodedInteger(0);
    const one = encodedInteger(1);
    const seven = encodedInteger(7);
    const eleven = encodedInteger(11);
    const nine = encodedInteger(9);
    const first = try b.primitive(bytes, .select, &.{
        branch, try e.literal([]const u8, &one), try e.literal([]const u8, &zero),
    }, 0);
    const second = try b.primitive(bytes, .select, &.{
        branch, try e.literal([]const u8, &eleven), try e.literal([]const u8, &seven),
    }, 0);
    const later = try b.primitive(bytes, .select, &.{
        try e.binary(.equal, count, e.one), second, try e.literal([]const u8, &nine),
    }, 0);
    const reply = try b.primitive(bytes, .select, &.{
        try e.binary(.equal, count, e.zero), first, later,
    }, 0);
    const trace_schema = try projection.schema([]const []const u8, b);
    const appended = try b.primitive(trace_schema, .sequence_append, &.{ trace, reply }, 0);
    const changed = try b.variable(b.functions.items[d.respond].result);
    return b.bind(changed, try e.call(d.respond, &.{ machine, reply }), try e.call(d.advance, &.{
        try b.reference(changed),  branch,                    appended, try e.param(d.advance, 3),
        try e.param(d.advance, 4), try e.param(d.advance, 5),
    }));
}

fn disclosedFinish(
    e: @import("author.zig").Author,
    d: Disclosed,
    observed: source.Id,
    stopping: analysis.Stop,
) !source.Id {
    const b = e.b;
    const state = try b.variable(b.functions.items[d.project].result);
    const work = try e.binary(.integer_sub, try b.constant(u64, 100), try e.param(d.advance, 3));
    return b.bind(state, try e.call(d.project, &.{try e.param(d.advance, 0)}), try b.pure(
        try e.tuple(d.output, &.{
            observed,
            try e.param(d.advance, 2),
            work,
            try b.reference(state),
            try e.literal(analysis.Stop, stopping),
        }),
    ));
}

fn expectDisclosedBranch(
    prepared: *const base.Prepared,
    input: DisclosedInput,
    expected: u64,
) !void {
    var result = try runDisclosed(prepared, input);
    defer result.deinit();
    try std.testing.expectEqual(.terminal, result.value.stopping);
    try std.testing.expect(result.value.observation == .completed);
    try std.testing.expectEqual(expected, std.mem.readInt(
        u64,
        result.value.observation.completed[0..8],
        .little,
    ));
    const assumptions: []const u64 = if (input.first_assumption == 2)
        &.{9}
    else if (input.branch) &.{ 1, 11, 9 } else &.{ 0, 7 };
    try std.testing.expectEqual(assumptions.len, result.value.assumptions.len);
    for (assumptions, result.value.assumptions) |assumed, actual|
        try std.testing.expectEqualSlices(u8, &encodedInteger(assumed), actual);
    try std.testing.expect(result.value.steps > 0 and result.value.steps < 100);
}

fn runDisclosed(
    prepared: *const base.Prepared,
    input: DisclosedInput,
) !projection.Owned(DisclosedOutput) {
    const arguments = try projection.encode(DisclosedInput, a, input);
    defer a.free(arguments);
    var experiment = try base.Session.start(a, prepared, arguments, .{});
    defer experiment.deinit();
    const outcome = try experiment.run(null);
    try std.testing.expect(outcome == .completed);
    return projection.decode(DisclosedOutput, a, try experiment.bytes(&outcome.completed));
}

fn expectDisclosedResume(
    prepared: *const base.Prepared,
    guest: *const data.program_image.Admitted,
    program: projection.Program,
    state: projection.State,
) !void {
    var unfinished = try runDisclosed(prepared, .{
        .program = program,
        .state = state,
        .branch = true,
        .replies_max = 2,
    });
    defer unfinished.deinit();
    try std.testing.expectEqual(.missing_assumption, unfinished.value.stopping);
    try std.testing.expectEqual(@as(usize, 2), unfinished.value.assumptions.len);
    try std.testing.expectEqualSlices(u8, &encodedInteger(1), unfinished.value.assumptions[0]);
    try std.testing.expectEqualSlices(u8, &encodedInteger(11), unfinished.value.assumptions[1]);
    try std.testing.expect(unfinished.value.observation == .requested);
    try std.testing.expectEqualSlices(
        u8,
        &encodedInteger(11),
        unfinished.value.observation.requested.payload,
    );
    var canonical = try data.state_image.canonicalize(a, unfinished.value.state);
    defer canonical.deinit();
    try data.state_admission.validateAdmitted(a, guest, canonical.state);
    try expectDisclosedBranch(prepared, .{
        .program = program,
        .state = canonical.state,
        .branch = true,
        .first_assumption = 2,
        .replies_max = 1,
    }, 20);
}
