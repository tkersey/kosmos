const std = @import("std");
const horos = @import("horos");
const source = horos.source;
const Session = @import("kosmos").Session;
const testing = std.testing;
const Resident = @import("kosmos").Resident;

test {
    _ = @import("source_regressions.zig");
}

test "ownership: encoded cursors export canonical immutable checkpoints and restore as values" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const sequence = try builder.schema(.{ .seq = integer });
    const pair = try builder.schema(.{ .product = &.{ integer, sequence } });
    const optional = try builder.schema(.{ .sum = &.{ unit, pair } });
    const entry = try builder.declare(&.{sequence}, sequence, &.{}, &.{});
    const popped = try builder.primitive(optional, .sequence_pop, &.{
        try builder.reference(builder.parameter(entry, 0)),
    }, 0);
    const empty = try builder.variable(unit);
    const present = try builder.variable(pair);
    const head = try builder.variable(integer);
    const tail = try builder.variable(sequence);
    const unpack = try builder.term(.{ .unpack_product = .{
        .value = try builder.reference(present),
        .variables = &.{ head, tail },
        .body = try builder.term(.{ .yield_then = try builder.pure(try builder.reference(tail)) }),
    } });
    try builder.define(entry, try builder.term(.{ .match_sum = .{
        .value = popped,
        .cases = &.{
            .{ .variable = empty, .body = try builder.pure(
                try builder.primitive(sequence, .sequence, &.{}, 0),
            ) },
            .{ .variable = present, .body = unpack },
        },
    } }));
    var compiled = try source.lower(testing.allocator, builder.module(entry, unit));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var input: [513]u8 = undefined;
    input[0] = 64;
    for (0..64) |i| std.mem.writeInt(u64, input[1 + i * 8 ..][0..8], i, .little);
    var session = try Session.initImage(testing.allocator, image, &input);
    defer session.deinit();
    const initial = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(initial);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    for ([_]bool{ false, true }) |checkpoint_mode|
        try residentFailureSweep(&prepared, .{ .checkpoint = initial }, .none, checkpoint_mode);
    try testing.expect(try drive(&session, null) == .yielded);
    const state = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(state);
    const again = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, state, again);
    var restored = try Session.restoreImage(testing.allocator, image, state);
    defer restored.deinit();
    try restored.resumeYield();
    const result = try drive(&restored, null);
    try testing.expect(result == .completed);
    var expected: [505]u8 = undefined;
    expected[0] = 63;
    @memcpy(expected[1..], input[9..]);
    try testing.expectEqualSlices(u8, &expected, try restored.bytes(&result.completed));
}

test "behavior: owned FIFO package queues preserve scheduling through instruction checkpoints" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.schedulerFifo(&builder));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    try testing.expect(try drive(&session, null) == .yielded);
    const checkpoint = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    var graph = try horos.data.state_image.decodeGraph(testing.allocator, checkpoint);
    defer graph.deinit();
    var packages: usize = 0;
    for (graph.state.nodes) |node| if (node.record == .package) {
        packages += 1;
    };
    try testing.expectEqual(2, packages);
    try session.resumeYield();
    for (0..1024) |_| {
        const outcome = try drive(&session, 1);
        if (outcome == .progressed) continue;
        try testing.expect(outcome == .completed);
        try testing.expectEqualSlices(u8, &.{
            30,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            4,
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            2,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            3,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            4,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        }, try session.bytes(&outcome.completed));
        return;
    }
    return error.TestUnexpectedResult;
}

test "behavior: fast projections still reject malformed unselected input payloads" {
    for (0..3) |mode| {
        const variant = mode != 0;
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const integer = try builder.scalar(u64);
        const bytes = try builder.schema(if (mode == 2) .text else .bytes);
        const unit = try builder.scalar(void);
        const input = try builder.schema(if (variant)
            .{ .sum = &.{ bytes, unit } }
        else
            .{ .product = &.{ integer, bytes } });
        const entry = try builder.declare(&.{input}, integer, &.{}, &.{});
        const projected = try builder.primitive(integer, if (variant) .variant_tag else .field, &.{
            try builder.reference(builder.parameter(entry, 0)),
        }, 0);
        try builder.define(entry, try builder.pure(projected));
        var compiled = try source.lower(testing.allocator, builder.module(entry, unit));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer testing.allocator.free(image);
        const truncated: []const u8 = if (variant)
            &.{ 0, 16 }
        else
            &.{ 42, 0, 0, 0, 0, 0, 0, 0, 16 };
        try testing.expectError(error.Truncated, Session.initImage(
            testing.allocator,
            image,
            truncated,
        ));
        if (mode == 2) try testing.expectError(error.InvalidUtf8, Session.initImage(
            testing.allocator,
            image,
            &.{ 0, 1, 0xff },
        ));
        const valid: []const u8 = if (variant) &.{ 0, 0 } else &.{ 42, 0, 0, 0, 0, 0, 0, 0, 0 };
        var session = try Session.initImage(testing.allocator, image, valid);
        defer session.deinit();
        const result = try session.run(null);
        try testing.expect(result == .completed);
        try testing.expectEqual(
            @as(u8, if (variant) 0 else 42),
            (try session.bytes(&result.completed))[0],
        );
    }
}

test "behavior: higher-order scoped bodies retain definition and use capabilities with cleanup" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.retainedScope(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    for ([_]bool{ false, true }) |cancel| {
        var session = try Session.initImage(testing.allocator, image, &.{});
        var alive = true;
        defer if (alive) session.deinit();
        try testing.expect(try session.run(null) == .yielded);
        try roundTrip(&session);
        var retained = false;
        var snapshot = try guestState(&session);
        defer snapshot.deinit();
        for (snapshot.state.nodes) |item| {
            const node = item.record;
            if (node != .computation) continue;
            const captures = snapshot.state.nodes[
                @intCast(node.computation.environment.id)
            ].record.environment.values;
            if (captures.len != 2) continue;
            if (captures[0].schema != captures[1].schema) continue;
            const schema = session.program.schemas[@intCast(captures[0].schema)];
            if (schema != .internal or schema.internal != .capability) continue;
            try testing.expect(captures[0].body.reference.id != captures[1].body.reference.id);
            retained = true;
        }
        try testing.expect(retained);
        const state = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(state);
        session.deinit();
        alive = false;
        var restored = try Session.restoreImage(testing.allocator, image, state);
        defer restored.deinit();
        if (cancel) try restored.cancel(.{ .text = "stop" }) else try restored.resumeYield();
        const cleanup = try restored.run(null);
        try testing.expect(cleanup == .requested);
        try testing.expectEqualStrings(
            "retained-scope/release",
            restored.program.effects[@intCast(cleanup.requested.effect)].identity,
        );
        try testing.expectEqual(77, (try restored.bytes(&cleanup.requested.payload))[0]);
        const cleaning = try restored.checkpoint(testing.allocator);
        defer testing.allocator.free(cleaning);
        var finished = try Session.restoreImage(testing.allocator, image, cleaning);
        defer finished.deinit();
        try answerWithValue(&finished, &.{});
        const result = try finished.run(null);
        if (cancel) {
            try testing.expect(result == .cancelled);
        } else {
            try testing.expect(result == .completed);
            try testing.expectEqualSlices(u8, &.{
                0x61, 4, 0, 0, 0, 0, 0, 0, 99, 0, 0, 0, 0, 0, 0, 0,
            }, try finished.bytes(&result.completed));
        }
    }
}

fn compileDeclarations(module: source.Module) !source.Compiled {
    return (try source.component.compile(
        testing.allocator,
        module,
        .{ .exports = &.{} },
    )).construction;
}

test "behavior: retained scoped interaction agrees at every quantum with general resumptions" {
    for ([_]bool{ false, true }) |general| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const module = try source.examples.retainedScope(&builder);
        var compiled = if (general)
            try compileDeclarations(module)
        else
            try source.lower(testing.allocator, module);
        defer compiled.deinit();
        var scratch = std.heap.ArenaAllocator.init(testing.allocator);
        defer scratch.deinit();
        var program = compiled.program;
        if (general) {
            const ir = horos.data.activation;
            const handlers = try scratch.allocator().dupe(ir.Handler, program.handlers);
            for (handlers, builder.handlers.items) |*handler, original| {
                const clauses = try scratch.allocator().dupe(ir.Clause, handler.clauses);
                for (clauses, original.clauses) |*clause, source_clause| {
                    clause.strategy = .general;
                    clause.function = source_clause.function;
                }
                handler.clauses = clauses;
            }
            program.handlers = handlers;
        }
        var session = try initFromImage(testing.allocator, program, &.{});
        defer session.deinit();
        var yields: usize = 0;
        var releases: usize = 0;
        var completed = false;
        for (0..256) |_| {
            const outcome = try drive(&session, 1);
            switch (outcome) {
                .progressed => {},
                .yielded => {
                    yields += 1;
                    try session.resumeYield();
                },
                .requested => |request| {
                    try testing.expectEqualStrings(
                        "retained-scope/release",
                        session.program.effects[@intCast(request.effect)].identity,
                    );
                    try testing.expectEqual(77, (try session.bytes(&request.payload))[0]);
                    releases += 1;
                    try answerWithValue(&session, &.{});
                },
                .completed => |value| {
                    var result = value;
                    try testing.expectEqualSlices(u8, &.{
                        0x61, 4, 0, 0, 0, 0, 0, 0, 99, 0, 0, 0, 0, 0, 0, 0,
                    }, try session.bytes(&result));
                    completed = true;
                    break;
                },
                else => return error.TestUnexpectedResult,
            }
        }
        try testing.expect(completed);
        try testing.expectEqual(1, yields);
        try testing.expectEqual(1, releases);
    }
}

test "behavior: branching tail handlers preserve results through every instruction checkpoint" {
    for ([_]bool{ false, true }) |selected| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const module = try source.examples.branchingTail(&builder);
        var compiled = if (selected)
            try source.lower(testing.allocator, module)
        else
            try compileDeclarations(module);
        defer compiled.deinit();
        const clause = compiled.program.handlers[0].clauses[0];
        const clauses = try testing.allocator.dupe(
            horos.data.activation.Clause,
            compiled.program.handlers[0].clauses,
        );
        defer testing.allocator.free(clauses);
        var handlers = [_]horos.data.activation.Handler{compiled.program.handlers[0]};
        handlers[0].clauses = clauses;
        var program = compiled.program;
        program.handlers = &handlers;
        if (!selected) {
            clauses[0].strategy = .general;
            clauses[0].function = builder.handlers.items[0].clauses[0].function;
        }
        const image = try programBytes(program);
        defer testing.allocator.free(image);
        for ([_]u8{ 0, 1 }) |input| {
            var session = try Session.initImage(testing.allocator, image, &.{input});
            defer session.deinit();
            var stats: std.meta.Child(
                @typeInfo(@FieldType(Session, "statistics")).optional.child,
            ) = .{};
            session.setStatistics(&stats);
            const result = try session.run(null);
            try testing.expect(result == .completed);
            try testing.expectEqual(@as(u64, if (input == 1) 60 else 100), std.mem.readInt(
                u64,
                (try session.bytes(&result.completed))[0..8],
                .little,
            ));
            try checkpointTail(image, input, clause.function, selected);
        }
    }
}

fn checkpointTail(image: []const u8, input: u8, function: u64, selected: bool) !void {
    var session = try Session.initImage(testing.allocator, image, &.{input});
    defer session.deinit();
    var saw_tail = false;
    var steps: usize = 0;
    var outcome = try session.run(1);
    while (outcome == .progressed) {
        steps += 1;
        try testing.expect(steps < 128);
        var snapshot = try guestState(&session);
        defer snapshot.deinit();
        if (snapshot.state.roots.current) |current| {
            const control = snapshot.state.nodes[@intCast(current.id)].record.control;
            if (session.program.blocks[
                @intCast(
                    control.block,
                )
            ].function == function) saw_tail = true;
        }
        const checkpoint = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(checkpoint);
        const restored = try Session.restoreImage(testing.allocator, image, checkpoint);
        session.deinit();
        session = restored;
        outcome = try session.run(1);
    }
    try testing.expectEqual(selected, saw_tail);
    try testing.expect(outcome == .completed);
    try testing.expectEqual(@as(u64, if (input == 1) 60 else 100), std.mem.readInt(
        u64,
        (try session.bytes(&outcome.completed))[0..8],
        .little,
    ));
}

test "behavior: tail clause checkpoints retain body cleanup on cancellation" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.branchingTailProtected(&builder),
    );
    defer compiled.deinit();
    const selected = compiled.program.handlers[0].clauses[0];
    try testing.expect(selected.strategy == .tail);
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var session = try Session.initImage(testing.allocator, image, &.{1});
    defer session.deinit();
    var cancellation_points: usize = 0;
    for (0..128) |_| {
        const outcome = try session.run(1);
        if (outcome == .requested) {
            try testing.expectEqualStrings(
                "example/tail-cleanup",
                session.program.effects[@intCast(outcome.requested.effect)].identity,
            );
            try answerWithValue(&session, &.{});
            const completed = try session.run(null);
            try testing.expect(completed == .completed);
            try testing.expectEqual(60, (try session.bytes(&completed.completed))[0]);
            break;
        }
        try testing.expect(outcome == .progressed);
        var snapshot = try guestState(&session);
        defer snapshot.deinit();
        const current = snapshot.state.roots.current.?;
        const record = snapshot.state.nodes[@intCast(current.id)].record;
        if (record != .control) continue;
        const control = record.control;
        if (session.program.blocks[@intCast(control.block)].function != selected.function) continue;
        const checkpoint = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(checkpoint);
        var cancelled = try Session.restoreImage(testing.allocator, image, checkpoint);
        defer cancelled.deinit();
        try cancelled.cancel(.{ .text = "stop" });
        const cleanup = try cancelled.run(null);
        try testing.expect(cleanup == .requested);
        try testing.expectEqualStrings(
            "example/tail-cleanup",
            cancelled.program.effects[@intCast(cleanup.requested.effect)].identity,
        );
        try answerWithValue(&cancelled, &.{});
        try testing.expect(try cancelled.run(null) == .cancelled);
        cancellation_points += 1;
    }
    try testing.expect(cancellation_points >= 3);
    try testing.expect(session.isTerminal());
}

test "behavior: immediate lexical calls preserve checked results and retained captures" {
    for ([_]bool{ false, true }) |immediate| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const original = try source.examples.lexical(&builder);
        if (immediate) {
            const main = &builder.functions.items[@intCast(original.entry)];
            const binding = builder.terms.items[@intCast(main.body.?)].bind;
            var application = builder.terms.items[@intCast(binding.next)].apply;
            application.computation = builder.terms.items[@intCast(binding.value)].value;
            main.body = try builder.term(.{ .apply = application });
        }
        var compiled = try source.lower(
            testing.allocator,
            builder.module(original.entry, original.failure),
        );
        defer compiled.deinit();
        var session = try initFromImage(
            testing.allocator,
            compiled.program,
            &.{ 40, 0, 0, 0, 0, 0, 0, 0 },
        );
        defer session.deinit();
        const result = try session.run(null);
        try testing.expect(result == .completed);
        try testing.expectEqualSlices(
            u8,
            &.{ 42, 0, 0, 0, 0, 0, 0, 0 },
            try session.bytes(&result.completed),
        );
        var overflow = try initFromImage(
            testing.allocator,
            compiled.program,
            &(@as([8]u8, @splat(0xff))),
        );
        defer overflow.deinit();
        const failed = try overflow.run(null);
        try testing.expect(failed == .failed);
        try testing.expectEqual(0, (try overflow.bytes(&failed.failed)).len);

        try expectLexicalCapture(&builder, original);
    }
}

fn releaseResident(resident: *Resident) void {
    resident.close() catch |err| switch (err) {
        error.UnfinishedSession => {
            const bytes = resident.takeCheckpoint(testing.allocator) catch |checkpoint_error|
                std.debug.panic("{s}", .{@errorName(checkpoint_error)});
            testing.allocator.free(bytes);
        },
        error.InvalidState => {},
        else => unreachable,
    };
}

fn residentBeforeOwnedUnwind(
    allocator: std.mem.Allocator,
    prepared: *const @import("kosmos").Prepared,
) !Resident {
    var resident = try Resident.start(allocator, prepared, &.{});
    errdefer releaseResident(&resident);
    var yielded = try resident.drive(allocator, .none, .{});
    defer yielded.deinit();
    try testing.expect(yielded.record == .yielded);
    var cancelling = try resident.drive(allocator, .{
        .cancel = .{ .text = "live-owned-unwind" },
    }, .{ .quantum = 0 });
    defer cancelling.deinit();
    return resident;
}

test "ownership: live owned unwind preserves physical ownership and retry under OOM" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.ownership(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    var reference = try residentBeforeOwnedUnwind(counting.allocator(), &prepared);
    defer releaseResident(&reference);
    const reference_entry = try reference.checkpoint(testing.allocator);
    defer testing.allocator.free(reference_entry);
    const allocation_start = counting.alloc_index;
    counting.resize_fail_index = counting.resize_index;
    var expected = try reference.drive(counting.allocator(), .none, .{ .quantum = 1 });
    defer expected.deinit();
    const allocation_count = counting.alloc_index - allocation_start;
    for (0..allocation_count + 1) |index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var resident = try residentBeforeOwnedUnwind(failing.allocator(), &prepared);
        defer releaseResident(&resident);
        const entry = try resident.checkpoint(testing.allocator);
        defer testing.allocator.free(entry);
        failing.fail_index = failing.alloc_index + index;
        failing.resize_fail_index = failing.resize_index;
        var output = resident.drive(failing.allocator(), .none, .{ .quantum = 1 }) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, err);
            const actual = try resident.checkpoint(testing.allocator);
            defer testing.allocator.free(actual);
            try testing.expectEqualSlices(u8, entry, actual);
            var retry = try resident.drive(failing.allocator(), .none, .{ .quantum = 1 });
            defer retry.deinit();
            try testing.expectEqualDeep(expected.record, retry.record);
            continue;
        };
        defer output.deinit();
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try testing.expectEqualDeep(expected.record, output.record);
        try testing.expect(index != 0);
        return;
    }
    return error.MissingAllocationSweepSuccess;
}

const ResidentFixture = struct {
    checkpoint: []const u8,
    prefix_steps: u64 = 0,

    fn restore(
        self: ResidentFixture,
        allocator: std.mem.Allocator,
        prepared: *const @import("kosmos").Prepared,
    ) !Resident {
        var resident = try Resident.restore(allocator, prepared, self.checkpoint);
        errdefer releaseResident(&resident);
        if (self.prefix_steps != 0) {
            var prefix = try resident.drive(allocator, .none, .{ .quantum = self.prefix_steps });
            defer prefix.deinit();
            try testing.expect(prefix.record == .progressed);
        }
        return resident;
    }
};

fn residentFailureSweep(
    prepared: *const @import("kosmos").Prepared,
    fixture: ResidentFixture,
    control: horos.data.invocation.Control,
    checkpoint_mode: bool,
) !void {
    var reference = try fixture.restore(testing.allocator, prepared);
    defer releaseResident(&reference);
    const reconstructed = if (fixture.prefix_steps == 0) null else try reference.checkpoint(
        testing.allocator,
    );
    defer if (reconstructed) |bytes| testing.allocator.free(bytes);
    const checkpoint = reconstructed orelse fixture.checkpoint;
    var expected = try reference.drive(testing.allocator, control, .{
        .quantum = 1,
        .checkpoint = checkpoint_mode,
    });
    defer expected.deinit();
    const allocation_count = try residentTransitionAllocations(
        prepared,
        fixture,
        control,
        checkpoint_mode,
    );
    var failed_after_mutation = false;
    for (0..allocation_count + 1) |failures| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
        var resident = try fixture.restore(failing.allocator(), prepared);
        defer releaseResident(&resident);
        var statistics: std.meta.Child(
            @typeInfo(@FieldType(Session, "statistics")).optional.child,
        ) = .{};
        try resident.setStatistics(&statistics);
        const collection_cursors = (try resident.diagnostics()).collection_cursors;
        failing.fail_index = failing.alloc_index + failures;
        failing.resize_fail_index = failing.resize_index;
        var output = resident.drive(failing.allocator(), control, .{
            .quantum = 1,
            .checkpoint = checkpoint_mode,
        }) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(
                collection_cursors,
                (try resident.diagnostics()).collection_cursors,
            );
            failed_after_mutation = failed_after_mutation or
                statistics.transitions != 0 or
                statistics.storage.added_nodes != 0 or statistics.storage.journal_nodes != 0;
            const unchanged = try resident.checkpoint(testing.allocator);
            defer testing.allocator.free(unchanged);
            try testing.expectEqualSlices(u8, checkpoint, unchanged);
            var retried = try resident.drive(testing.allocator, control, .{
                .quantum = 1,
                .checkpoint = checkpoint_mode,
            });
            defer retried.deinit();
            try testing.expectEqualDeep(expected.record, retried.record);
            continue;
        };
        defer output.deinit();
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try testing.expectEqualDeep(expected.record, output.record);
        try testing.expect(failures != 0 and failed_after_mutation);
        return;
    }
    return error.MissingAllocationSweepSuccess;
}

fn residentPublicationFailure(
    prepared: *const @import("kosmos").Prepared,
    fixture: ResidentFixture,
    control: horos.data.invocation.Control,
    checkpoint_mode: bool,
) !void {
    var reference = try fixture.restore(testing.allocator, prepared);
    defer releaseResident(&reference);
    const reconstructed = if (fixture.prefix_steps == 0) null else try reference.checkpoint(
        testing.allocator,
    );
    defer if (reconstructed) |bytes| testing.allocator.free(bytes);
    const checkpoint = reconstructed orelse fixture.checkpoint;
    var expected = try reference.drive(testing.allocator, control, .{
        .quantum = 1,
        .checkpoint = checkpoint_mode,
    });
    defer expected.deinit();
    var resident = try fixture.restore(testing.allocator, prepared);
    defer releaseResident(&resident);
    var statistics: std.meta.Child(
        @typeInfo(@FieldType(Session, "statistics")).optional.child,
    ) = .{};
    try resident.setStatistics(&statistics);
    const cursors = (try resident.diagnostics()).collection_cursors;
    var empty: [0]u8 = .{};
    var output = std.heap.FixedBufferAllocator.init(&empty);
    try testing.expectError(error.OutOfMemory, resident.driveEncoded(output.allocator(), control, .{
        .quantum = 1,
        .checkpoint = checkpoint_mode,
    }));
    try testing.expect(
        statistics.transitions != 0 or
            statistics.storage.added_nodes != 0 or statistics.storage.journal_nodes != 0,
    );
    try testing.expectEqual(cursors, (try resident.diagnostics()).collection_cursors);
    const unchanged = try resident.checkpoint(testing.allocator);
    defer testing.allocator.free(unchanged);
    try testing.expectEqualSlices(u8, checkpoint, unchanged);
    var retried = try resident.drive(testing.allocator, control, .{
        .quantum = 1,
        .checkpoint = checkpoint_mode,
    });
    defer retried.deinit();
    try testing.expectEqualDeep(expected.record, retried.record);
}

test "ownership: rollback preserves replies cleanup and reentry on publication failure" {
    const protocol = horos.data.invocation;
    inline for (.{
        retainedInputExample,
        source.examples.unwind,
        source.examples.reentrant,
        source.examples.cloned,
    }, 0..) |example, index| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(testing.allocator, try example(&builder));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer testing.allocator.free(image);
        var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
        defer prepared.deinit();
        const arguments: []const u8 = switch (index) {
            0 => &.{ 42, 0, 0, 0, 0, 0, 0, 0 },
            1 => &.{0},
            else => &.{},
        };
        var session = try Session.start(testing.allocator, &prepared, arguments);
        defer session.deinit();
        if (index == 3) try expectClonePublicationFailure(&session, &prepared);
        const observation = try session.run(null);
        const checkpoint = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(checkpoint);
        if (index >= 2) {
            try testing.expect(observation == .yielded);
            for ([_]bool{ false, true }) |with_checkpoint| try residentPublicationFailure(
                &prepared,
                .{ .checkpoint = checkpoint },
                .resume_yield,
                with_checkpoint,
            );
        } else {
            try testing.expect(observation == .requested);
            var pending = try session.pendingRequest(testing.allocator);
            defer pending.deinit();
            const reply = try protocol.encodeOwned(protocol.Result, testing.allocator, .{
                .request_identity = pending.request.request_identity,
                .value = &.{},
            });
            defer testing.allocator.free(reply);
            for ([_]bool{ false, true }) |with_checkpoint| try residentPublicationFailure(
                &prepared,
                .{ .checkpoint = checkpoint },
                .{ .reply = reply },
                with_checkpoint,
            );
            if (index == 0) try residentFailureSweep(
                &prepared,
                .{ .checkpoint = checkpoint },
                .{ .reply = reply },
                true,
            );
            if (index == 1) for ([_]bool{
                false,
                true,
            }) |with_checkpoint| try residentPublicationFailure(
                &prepared,
                .{ .checkpoint = checkpoint },
                .{ .cancel = .{ .text = "stop" } },
                with_checkpoint,
            );
        }
    }
}

test "behavior: resident output capacity and checkpoint transfer preserve custody on failure" {
    const protocol = horos.data.invocation;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try retainedInputExample(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var resident = try Resident.start(testing.allocator, &prepared, &.{ 42, 0, 0, 0, 0, 0, 0, 0 });
    defer releaseResident(&resident);
    try testing.expectError(error.UnfinishedSession, resident.close());
    var pending = try resident.drive(testing.allocator, .none, .{ .checkpoint = true });
    defer pending.deinit();
    try expectResidentTransactionCopies(&prepared, pending.record.requested.state.?);
    var request = try protocol.decode(
        protocol.Request,
        testing.allocator,
        pending.record.requested.request,
    );
    defer request.deinit();
    const reply = try protocol.encodeOwned(protocol.Result, testing.allocator, .{
        .request_identity = request.value.request_identity,
        .value = &.{},
    });
    defer testing.allocator.free(reply);
    var output = @as([512]u8, @splat(0xa5));
    try testing.expectError(error.Capacity, resident.driveInto(
        .{ .reply = reply },
        .{ .checkpoint = true },
        output[0..1],
    ));
    for (output) |byte| try testing.expectEqual(0xa5, byte);
    const unchanged = try resident.checkpoint(testing.allocator);
    defer testing.allocator.free(unchanged);
    try testing.expectEqualSlices(u8, pending.record.requested.state.?, unchanged);
    var empty: [0]u8 = .{};
    var failed_output = std.heap.FixedBufferAllocator.init(&empty);
    try testing.expectError(error.OutOfMemory, resident.takeCheckpoint(failed_output.allocator()));
    const transferred = try resident.takeCheckpoint(testing.allocator);
    defer testing.allocator.free(transferred);
    try testing.expectEqualSlices(u8, unchanged, transferred);
    try testing.expectError(error.InvalidState, resident.checkpoint(testing.allocator));
    var restored = try Resident.restore(testing.allocator, &prepared, transferred);
    defer releaseResident(&restored);
    const bytes = try restored.driveInto(.{ .reply = reply }, .{ .checkpoint = true }, &output);
    var decoded = try protocol.decode(protocol.Outcome, testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, decoded.value.completed);
    try restored.close();
    try testing.expectError(error.InvalidState, restored.close());
    try testing.expectError(error.InvalidState, restored.drive(
        testing.allocator,
        .none,
        .{ .quantum = 0 },
    ));
}

test "ownership: shallow resumption preserves every resident boundary after failed publication" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.shallowResumptions(&builder),
    );
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var resident = try Resident.start(testing.allocator, &prepared, &.{});
    defer releaseResident(&resident);
    var swept = false;
    for (0..4096) |_| {
        const before = try resident.checkpoint(testing.allocator);
        defer testing.allocator.free(before);
        if (!swept) {
            var portable = try horos.data.state_image.decodeGraph(testing.allocator, before);
            defer portable.deinit();
            const current = portable.state.nodes[@intCast(portable.state.roots.current.?.id)];
            const block = compiled.program.blocks[@intCast(current.record.control.block)];
            const resuming = current.activation.?.position == block.instructions.len and
                (block.terminator == .resume_value or block.terminator == .resume_computation);
            for (portable.state.nodes) |entry| {
                const node = entry.record;
                if (!resuming or node != .one_shot) continue;
                const signature = compiled.program.schemas[
                    @intCast(node.one_shot.schema)
                ].internal.resumption;
                if (signature.mode != .shallow) continue;
                for ([_]bool{ false, true }) |checkpoint_mode|
                    try residentPublicationFailure(
                        &prepared,
                        .{ .checkpoint = before },
                        .none,
                        checkpoint_mode,
                    );
                swept = true;
                break;
            }
        }
        try expectResidentOutputFailures(&resident, before);
        var succeeded = try resident.drive(
            testing.allocator,
            .none,
            .{ .quantum = 1, .checkpoint = true },
        );
        defer succeeded.deinit();
        if (succeeded.record == .completed) {
            try testing.expect(swept);
            var expected: [64]u8 = undefined;
            for ([_]u64{ 99, 99, 99, 99, 42, 42, 42, 42 }, 0..) |value, i|
                std.mem.writeInt(u64, expected[i * 8 ..][0..8], value, .little);
            try testing.expectEqualSlices(u8, &expected, succeeded.record.completed);
            return;
        }
        try testing.expect(succeeded.record == .progressed);
    }
    return error.TestUnexpectedResult;
}

fn expectResidentCheckpoint(resident: *Resident, expected: []const u8) !void {
    const actual = try resident.checkpoint(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, expected, actual);
}

test "behavior: independent native residents release shared preparation exactly once" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.installations(&builder, 1),
    );
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var memory: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer if (memory.deinit() != .ok) @panic("shared preparation leaked");
    const allocator = memory.allocator();
    for (0..8) |_| {
        var prepared = try @import("kosmos").Prepared.init(allocator, image);
        defer prepared.deinit();
        var ready: std.atomic.Value(usize) = .init(0);
        var start: std.atomic.Value(bool) = .init(false);
        var jobs: [8]ResidentJob = undefined;
        var initialized: usize = 0;
        defer for (jobs[0..initialized]) |*job| job.prepared.deinit();
        for (&jobs) |*job| {
            job.* = .{
                .prepared = try prepared.clone(),
                .allocator = allocator,
                .ready = &ready,
                .start = &start,
            };
            initialized += 1;
        }
        prepared.deinit();
        var threads: [8]std.Thread = undefined;
        var started: usize = 0;
        defer {
            start.store(true, .release);
            for (threads[0..started]) |thread| thread.join();
        }
        for (&jobs) |*job| {
            threads[started] = try std.Thread.spawn(.{}, ResidentJob.run, .{job});
            started += 1;
        }
        while (ready.load(.acquire) != jobs.len) std.atomic.spinLoopHint(); // tiger: event-loop
        start.store(true, .release);
        for (threads) |thread| thread.join();
        started = 0;
        for (jobs) |job| if (job.failure) |err| return err;
    }
}

test "behavior: resident progress defers checkpoint publication until explicitly requested" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try retainedInputExample(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var resident = try Resident.start(testing.allocator, &prepared, &.{ 42, 0, 0, 0, 0, 0, 0, 0 });
    defer releaseResident(&resident);
    var empty: [0]u8 = .{};
    var output = std.heap.FixedBufferAllocator.init(&empty);
    var progress = try resident.drive(output.allocator(), .none, .{ .quantum = 1 });
    defer progress.deinit();
    try testing.expect(progress.record == .progressed and progress.record.progressed == null);
    var pending = try resident.drive(testing.allocator, .none, .{});
    defer pending.deinit();
    try testing.expect(pending.record == .requested and pending.record.requested.state == null);
    const checkpoint = try resident.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    var restored = try Resident.restore(testing.allocator, &prepared, checkpoint);
    defer releaseResident(&restored);
    var polled = try restored.drive(testing.allocator, .none, .{});
    defer polled.deinit();
    try testing.expectEqualDeep(pending.record, polled.record);
}

test "behavior: resident gate rejects reentrant observation during allocator callbacks" {
    const Callback = struct {
        child: std.mem.Allocator,
        resident: ?*Resident = null,
        attempted: bool = false,
        observed: ?anyerror = null,
        fn alloc(pointer: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            if (self.resident != null and !self.attempted) {
                self.attempted = true;
                if (self.resident.?.checkpoint(self.child)) |bytes| {
                    self.child.free(bytes);
                    self.observed = error.AcceptedReentrancy;
                } else |err| self.observed = err;
            }
            return self.child.rawAlloc(len, alignment, ra);
        }
        fn free(pointer: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.child.rawFree(bytes, alignment, ra);
        }
    };
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try retainedInputExample(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var callback: Callback = .{ .child = testing.allocator };
    const allocator: std.mem.Allocator = .{ .ptr = &callback, .vtable = &.{
        .alloc = Callback.alloc,
        .free = Callback.free,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
    } };
    var resident = try Resident.start(allocator, &prepared, &.{ 42, 0, 0, 0, 0, 0, 0, 0 });
    defer releaseResident(&resident);
    callback.resident = &resident;
    var result = try resident.drive(testing.allocator, .none, .{ .quantum = 1 });
    defer result.deinit();
    try testing.expect(callback.attempted);
    try testing.expectEqual(error.Busy, callback.observed.?);
}

fn answerWithValue(subject: *Session, value: []const u8) !void {
    const protocol = horos.data.invocation;
    var pending = try subject.pendingRequest(testing.allocator);
    defer pending.deinit();
    const response = try protocol.encodeOwned(protocol.Result, testing.allocator, .{
        .request_identity = pending.request.request_identity,
        .value = value,
    });
    defer testing.allocator.free(response);
    try subject.answer(response);
}

fn checkedCheckpoint(subject: *Session) !void {
    const bytes = try subject.checkpoint(testing.allocator);
    defer testing.allocator.free(bytes);
    var decoded = try horos.data.state_image.decodeGraph(testing.allocator, bytes);
    defer decoded.deinit();
    try horos.data.state_admission.validateStable(
        testing.allocator,
        subject.program,
        decoded.state,
    );
    const reencoded = try horos.data.state_image.emit(testing.allocator, decoded.state);
    defer testing.allocator.free(reencoded);
    try testing.expectEqualSlices(u8, bytes, reencoded);
    const repeated = try subject.checkpoint(testing.allocator);
    defer testing.allocator.free(repeated);
    try testing.expectEqualSlices(u8, bytes, repeated);
    try testing.expectEqual(subject.program_identity, decoded.state.program_identity);
}

fn retainedPreparation(subject: *Session) !@import("kosmos").Prepared {
    const core = subject.driver.selected;
    const borrowed: @import("kosmos").Prepared = .{
        .guest = .{ .core = subject.prepared },
        .runtime = .{
            .core = core,
            .content = core.content,
            .program = core.program,
            .helpers = core.helpers,
            .identity = core.identity,
        },
    };
    return borrowed.clone();
}

fn drive(subject: *Session, quantum: ?usize) !@typeInfo(
    @typeInfo(@TypeOf(Session.observe)).@"fn".return_type.?,
).error_union.payload {
    const before = try subject.checkpoint(testing.allocator);
    defer testing.allocator.free(before);
    var prepared = try retainedPreparation(subject);
    defer prepared.deinit();
    var invocation_session = try Session.restore(testing.allocator, &prepared, before);
    defer invocation_session.deinit();
    var resident = try Resident.restore(testing.allocator, &prepared, before);
    defer releaseResident(&resident);
    @memset(before, 0xff);
    const result = try subject.run(quantum);
    _ = try @import("kosmos").invocation.advance(&invocation_session, .none, quantum);
    var fresh = try @import("kosmos").invocation.finish(
        testing.allocator,
        &invocation_session,
        true,
    );
    defer fresh.deinit();
    var committed = try resident.drive(testing.allocator, .none, .{
        .quantum = quantum,
        .checkpoint = true,
    });
    defer committed.deinit();
    try testing.expectEqualDeep(fresh.record, committed.record);
    const expected = try subject.checkpoint(testing.allocator);
    defer testing.allocator.free(expected);
    const actual = try invocation_session.checkpoint(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, expected, actual);
    try expectInvocationObservation(subject, result, expected, fresh.record);
    try checkedCheckpoint(subject);
    return result;
}

fn expectCleanupFailures(subject: *Session, bytes: []const u8) !void {
    var reader: horos.data.wire.Reader = .{ .input = bytes };
    const failures = (try subject.terminalExit()).cleanup_failures;
    try testing.expectEqual(failures.len, try reader.count());
    for (failures) |value| try testing.expectEqualSlices(
        u8,
        try subject.bytes(&value),
        try reader.bytes(),
    );
    try reader.finish();
}

fn checkpointFailure(allocator: std.mem.Allocator, subject: *Session, before: []const u8) !void {
    const bytes = subject.checkpoint(allocator) catch |err| {
        const after = try subject.checkpoint(testing.allocator);
        defer testing.allocator.free(after);
        try testing.expectEqualSlices(u8, before, after);
        return err;
    };
    defer allocator.free(bytes);
    try testing.expectEqualSlices(u8, before, bytes);
}

test "ownership: failed PST3 export retains exactly the same resident instruction boundary" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.installations(&builder, 1),
    );
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    try testing.expect(try session.run(1) == .progressed);
    const before = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(before);
    try @import("allocation_testing.zig").check(
        testing.allocator,
        checkpointFailure,
        .{ &session, before },
    );
    const result = try drive(&session, null);
    try testing.expect(result == .completed);
    try testing.expectEqual(1, (try session.bytes(&result.completed))[0]);
}

fn initFromImage(
    allocator: std.mem.Allocator,
    program: horos.data.activation.Program,
    arguments: []const u8,
) !Session {
    const codec = horos.data.program_image;
    const image = try allocator.alloc(u8, try codec.encodedLength(program));
    defer allocator.free(image);
    _ = try codec.encode(allocator, program, image);
    const result = try Session.initImage(allocator, image, arguments);
    @memset(image, 0xff);
    return result;
}

fn programBytes(program: horos.data.activation.Program) ![]u8 {
    const codec = horos.data.program_image;
    const bytes = try testing.allocator.alloc(u8, try codec.encodedLength(program));
    errdefer testing.allocator.free(bytes);
    _ = try codec.encode(testing.allocator, program, bytes);
    return bytes;
}

test "behavior: prepared Programs reuse immutable code and facts across sequential Sessions" {
    const Prepared = @import("kosmos").Prepared;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try retainedInputExample(&builder));
    defer compiled.deinit();
    const bytes = try programBytes(compiled.program);
    defer testing.allocator.free(bytes);
    var prepared = try Prepared.init(testing.allocator, bytes);
    defer prepared.deinit();
    @memset(bytes, 0xff);
    const retained = try prepared.storageBytes();
    var shared_code: ?[*]const horos.data.activation.Function = null;
    for ([_]u8{ 1, 2, 3 }) |input| {
        var session = try Session.start(
            testing.allocator,
            &prepared,
            &.{ input, 0, 0, 0, 0, 0, 0, 0 },
        );
        defer session.deinit();
        if (shared_code) |pointer| try testing.expect(
            pointer == session.program.functions.ptr,
        ) else shared_code = session.program.functions.ptr;
        try testing.expect(try session.run(null) == .requested);
        const checkpoint = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(checkpoint);
        var restored = try Session.restore(testing.allocator, &prepared, checkpoint);
        defer restored.deinit();
        try testing.expect(session.program.functions.ptr == restored.program.functions.ptr);
        try answerWithValue(&session, &.{});
        try answerWithValue(&restored, &.{});
        const result = try session.run(null);
        const other = try restored.run(null);
        try testing.expectEqual(input, (try session.bytes(&result.completed))[0]);
        try testing.expectEqualSlices(
            u8,
            try session.bytes(&result.completed),
            try restored.bytes(&other.completed),
        );
        try testing.expectEqual(retained, try prepared.storageBytes());
    }
}

test "behavior: Sessions retain preparation after all external prepared handles are released" {
    const Prepared = @import("kosmos").Prepared;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try retainedInputExample(&builder));
    defer compiled.deinit();
    const bytes = try programBytes(compiled.program);
    defer testing.allocator.free(bytes);
    var prepared = try Prepared.init(testing.allocator, bytes);
    defer prepared.deinit();
    var clone = try prepared.clone();
    defer clone.deinit();
    var session = try Session.start(testing.allocator, &prepared, &.{ 42, 0, 0, 0, 0, 0, 0, 0 });
    defer session.deinit();
    const checkpoint = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    prepared.deinit();
    clone.deinit();
    try testing.expectError(error.InvalidState, Session.start(testing.allocator, &prepared, &.{}));
    try testing.expectError(error.InvalidState, Session.restore(testing.allocator, &clone, &.{}));
    try testing.expectError(error.InvalidState, Session.restore(
        testing.allocator,
        &clone,
        checkpoint,
    ));
    try testing.expect(try session.run(null) == .requested);
    try answerWithValue(&session, &.{});
    const result = try session.run(null);
    try testing.expectEqual(42, (try session.bytes(&result.completed))[0]);
}

fn startPreparedFailure(
    allocator: std.mem.Allocator,
    prepared: *const @import("kosmos").Prepared,
) !void {
    var session = try Session.start(allocator, prepared, &.{ 1, 0, 0, 0, 0, 0, 0, 0 });
    defer session.deinit();
}
fn restorePreparedFailure(
    allocator: std.mem.Allocator,
    prepared: *const @import("kosmos").Prepared,
    checkpoint: []const u8,
) !void {
    var session = try Session.restore(allocator, prepared, checkpoint);
    defer session.deinit();
}
test "ownership: failed prepared starts and restores preserve the reusable owner" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try retainedInputExample(&builder));
    defer compiled.deinit();
    const bytes = try programBytes(compiled.program);
    defer testing.allocator.free(bytes);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, bytes);
    defer prepared.deinit();
    const retained = try prepared.storageBytes();
    try @import("allocation_testing.zig").check(
        testing.allocator,
        startPreparedFailure,
        .{&prepared},
    );
    var session = try Session.start(testing.allocator, &prepared, &.{ 1, 0, 0, 0, 0, 0, 0, 0 });
    defer session.deinit();
    try testing.expect(try session.run(null) == .requested);
    const checkpoint = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    try @import("allocation_testing.zig").check(
        testing.allocator,
        restorePreparedFailure,
        .{ &prepared, checkpoint },
    );
    try testing.expectEqual(retained, try prepared.storageBytes());
    try answerWithValue(&session, &.{});
    try testing.expect(try session.run(null) == .completed);
}

fn retainedInputExample(builder: *source.Builder) !source.Module {
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const effect = try builder.effect(.{
        .identity = "binding/read",
        .payload = unit,
        .result = unit,
    });
    const main = try builder.declare(&.{integer}, integer, &.{effect}, &.{});
    const operation = try builder.term(.{ .perform = .{
        .effect = effect,
        .payload = try builder.constant(void, {}),
    } });
    try builder.define(
        main,
        try builder.bind(
            try builder.variable(unit),
            operation,
            try builder.pure(try builder.reference(builder.parameter(main, 0))),
        ),
    );
    return builder.module(main, unit);
}

fn invocationFailure(allocator: std.mem.Allocator, command: []const u8) !void {
    var output = @as([1024]u8, @splat(0xa5));
    const bytes = @import("kosmos").invocation.invokeInto(allocator, command, &output) catch |err| {
        for (output) |byte| try testing.expectEqual(0xa5, byte);
        return err;
    };
    var decoded = try horos.data.invocation.decode(
        horos.data.invocation.Outcome,
        testing.allocator,
        bytes,
    );
    defer decoded.deinit();
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0, 0, 0, 0 }, decoded.value.completed);
}

test "ownership: fresh invocation binds captures and rejects stale replies without mutation" {
    const protocol = horos.data.invocation;
    const fresh = @import("kosmos").invocation;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try retainedInputExample(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var first = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{
        .initial_args = &.{ 1, 0, 0, 0, 0, 0, 0, 0 },
    } });
    defer first.deinit();
    var second = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{
        .initial_args = &.{ 2, 0, 0, 0, 0, 0, 0, 0 },
    } });
    defer second.deinit();
    var first_request = try protocol.decode(
        protocol.Request,
        testing.allocator,
        first.record.requested.request,
    );
    defer first_request.deinit();
    var second_request = try protocol.decode(
        protocol.Request,
        testing.allocator,
        second.record.requested.request,
    );
    defer second_request.deinit();
    try expectDistinctRequestCaptures(first_request.value, second_request.value);
    var poll = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{
        .state = first.record.requested.state.?,
    } });
    defer poll.deinit();
    try testing.expectEqualDeep(first.record, poll.record);
    const stale = try protocol.encodeOwned(protocol.Result, testing.allocator, .{
        .request_identity = first_request.value.request_identity,
        .value = &.{},
    });
    defer testing.allocator.free(stale);
    try testing.expectError(error.InvalidResult, fresh.invoke(testing.allocator, .{
        .image = image,
        .instance = .{ .state = second.record.requested.state.? },
        .control = .{ .reply = stale },
    }));
    var resident = try Session.restoreImage(
        testing.allocator,
        image,
        second.record.requested.state.?,
    );
    defer resident.deinit();
    try testing.expectError(error.InvalidResult, resident.answer(stale));
    const unchanged = try resident.checkpoint(testing.allocator);
    defer testing.allocator.free(unchanged);
    try testing.expectEqualSlices(u8, second.record.requested.state.?, unchanged);
    try expectFreshReplyConsumption(
        image,
        second.record.requested.state.?,
        second_request.value.request_identity,
    );
}

test "behavior: current invocation preserves explicit yield polling and cancellation before work" {
    const fresh = @import("kosmos").invocation;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const main = try builder.declare(&.{}, integer, &.{}, &.{});
    try builder.define(main, try builder.term(.{
        .yield_then = try builder.pure(try builder.constant(u64, 42)),
    }));
    var compiled = try source.lower(
        testing.allocator,
        builder.module(main, try builder.scalar(void)),
    );
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var yielded = try fresh.invoke(testing.allocator, .{
        .image = image,
        .instance = .{ .initial_args = &.{} },
    });
    defer yielded.deinit();
    var poll = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{
        .state = yielded.record.yielded.?,
    } });
    defer poll.deinit();
    try testing.expectEqualDeep(yielded.record, poll.record);
    var resumed = try fresh.invoke(testing.allocator, .{
        .image = image,
        .instance = .{ .state = yielded.record.yielded.? },
        .control = .resume_yield,
        .quantum = 0,
    });
    defer resumed.deinit();
    try testing.expect(resumed.record == .progressed);
    var completed = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{
        .state = resumed.record.progressed.?,
    } });
    defer completed.deinit();
    try testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, completed.record.completed);
    var cancelled = try fresh.invoke(testing.allocator, .{
        .image = image,
        .instance = .{ .initial_args = &.{} },
        .control = .{ .cancel = .{ .text = "stop" } },
        .quantum = 0,
    });
    defer cancelled.deinit();
    if (cancelled.record == .progressed) {
        var done = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{
            .state = cancelled.record.progressed.?,
        } });
        defer done.deinit();
        try testing.expectEqualStrings("stop", done.record.cancelled.reason.text);
    } else try testing.expectEqualStrings("stop", cancelled.record.cancelled.reason.text);
}

test "behavior: cancellation rebinds a pending cleanup without repeating its semantic operation" {
    const protocol = horos.data.invocation;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.unwind(&builder));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{0});
    defer session.deinit();
    try testing.expect(try session.run(null) == .requested);
    var before = try session.pendingRequest(testing.allocator);
    defer before.deinit();
    const acquired_result = try protocol.encodeOwned(protocol.Result, testing.allocator, .{
        .request_identity = before.request.request_identity,
        .value = &.{},
    });
    defer testing.allocator.free(acquired_result);
    try session.cancel(.{ .text = "stop" });
    var after = try session.pendingRequest(testing.allocator);
    defer after.deinit();
    try testing.expectEqualStrings(
        before.request.binding.semantic_identity,
        after.request.binding.semantic_identity,
    );
    try testing.expectEqualSlices(
        u8,
        before.request.binding.payload,
        after.request.binding.payload,
    );
    try testing.expect(!std.mem.eql(
        u8,
        &before.request.request_identity,
        &after.request.request_identity,
    ));
    try testing.expectError(error.InvalidResult, session.answer(acquired_result));
    try answerWithValue(&session, &.{});
    try testing.expect(try session.run(null) == .requested);
    try answerWithValue(&session, &.{});
    const result = try session.run(null);
    try testing.expect(result == .failed);
    try testing.expectEqualStrings("stop", (try session.terminalExit()).cancellation.?.text);
}

fn restoreFailure(
    allocator: std.mem.Allocator,
    prepared: *const @import("kosmos").Prepared,
    checkpoint: []const u8,
) !void {
    var session = try Session.restore(allocator, prepared, checkpoint);
    defer session.deinit();
    const bytes = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, checkpoint, bytes);
}

test "ownership: PST3 restore releases every partial owner on allocation failure" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.installations(&builder, 1),
    );
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    _ = try session.run(1);
    const checkpoint = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    try @import("allocation_testing.zig").check(
        testing.allocator,
        restoreFailure,
        .{ &prepared, checkpoint },
    );
}

fn rejectCheckpoint(image: []const u8, state: horos.data.process_state.State) !void {
    const bytes = try horos.data.state_image.emit(testing.allocator, state);
    defer testing.allocator.free(bytes);
    if (Session.restoreImage(testing.allocator, image, bytes)) |value| {
        var accepted = value;
        accepted.deinit();
        return error.AcceptedCorruptCheckpoint;
    } else |err| try testing.expect(err != error.OutOfMemory);
}

test "behavior: PST3 restore rejects wrong identity, code position, slots, and cleanup status" {
    const data = horos.data;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.resourceScalar(&builder),
    );
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    try testing.expect(try session.run(null) == .requested);
    try answerWithValue(&session, &.{ 41, 0, 0, 0, 0, 0, 0, 0 });
    try testing.expect(try session.run(null) == .requested);
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    const checkpoint = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    var decoded = try data.state_image.decodeGraph(testing.allocator, checkpoint);
    defer decoded.deinit();
    try data.state_admission.validateStable(testing.allocator, compiled.program, decoded.state);
    var forged = decoded.state;
    forged.program_identity[0] ^= 1;
    try rejectCheckpoint(image, forged);
    forged = decoded.state;
    const nodes = try testing.allocator.dupe(data.process_state.Node, forged.nodes);
    defer testing.allocator.free(nodes);
    forged.nodes = nodes;
    var checked_frame = false;
    var checked_binding = false;
    var checked_cleanup = false;
    for (nodes) |*node| {
        const original = node.*;
        if (node.activation) |*activation| {
            if (!checked_frame) {
                activation.position = std.math.maxInt(u64);
                try rejectCheckpoint(image, forged);
                node.* = original;
                checked_frame = true;
            }
            if (!checked_binding and original.activation.?.bindings.len != 0) {
                try rejectCorruptBindings(image, forged, node, original);
                checked_binding = true;
            }
        }
        if (node.record == .obligation and !checked_cleanup) {
            node.record.obligation.status = .completed;
            try rejectCheckpoint(image, forged);
            node.* = original;
            checked_cleanup = true;
        }
    }
    try testing.expect(checked_frame and checked_binding and checked_cleanup);
}

test "behavior: PST3 restore rejects aliased unique packages after graph renumbering" {
    const data = horos.data;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.custodyOrder(&builder, 0),
    );
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    try testing.expect(try session.run(null) == .yielded);
    const checkpoint = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    var decoded = try data.state_image.decodeGraph(testing.allocator, checkpoint);
    defer decoded.deinit();
    const nodes = try testing.allocator.dupe(data.process_state.Node, decoded.state.nodes);
    defer testing.allocator.free(nodes);
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    try data.state_admission.validateStable(testing.allocator, compiled.program, decoded.state);
    var first: ?data.graph.Value = null;
    for (nodes) |*node| if (node.record == .package) {
        if (first) |token| {
            try testing.expectEqual(token.schema, node.record.package.continuation.schema);
            node.record.package.continuation = token;
            var forged = decoded.state;
            forged.nodes = nodes;
            try rejectCheckpoint(image, forged);
            return;
        } else first = node.record.package.continuation;
    };
    return error.MissingIndependentPackages;
}

test "behavior: imported storage avoids payload copies and releases a large dead backing" {
    const data = horos.data;
    const Store = @FieldType(@FieldType(@FieldType(Session, "driver"), "outer"), "store");
    const big = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 0x5a);
    const small: data.graph.Value = .{ .schema = 0, .body = .{ .blob = .{ .id = 1 } } };
    const state: data.process_state.State = .{
        .program_identity = @as([32]u8, @splat(0)),
        .status = .active,
        .roots = .{ .current = .{ .id = 0 } },
        .nodes = &.{.{ .record = .{ .environment = .{ .values = &.{
            .{ .schema = 0, .body = .{ .blob = .{ .id = 0 } } }, small,
        }, .tail = null } } }},
        .blobs = &.{ .{ .schema = 0, .bytes = big }, .{ .schema = 0, .bytes = "small" } },
    };
    const bytes = try data.state_image.emit(testing.allocator, state);
    defer testing.allocator.free(bytes);
    var decoded = try data.state_image.decodeGraph(testing.allocator, bytes);
    var moved = false;
    defer if (!moved) decoded.deinit();
    var store: Store = .{ .allocator = testing.allocator };
    defer store.deinit();
    var statistics: std.meta.Child(
        @typeInfo(@FieldType(Session, "statistics")).optional.child,
    ) = .{};
    store.statistics = &statistics.storage;
    var baseline: Store = .{ .allocator = testing.allocator };
    defer baseline.deinit();
    var baseline_statistics: @TypeOf(statistics) = .{};
    baseline.statistics = &baseline_statistics.storage;
    for (state.nodes) |node| _ = try baseline.add(node.record);
    for (state.blobs) |blob| _ = try baseline.literal(&.{.bytes}, .{
        .schema = blob.schema,
        .bytes = blob.bytes,
    });
    try testing.expectEqual(big.len + 5, baseline_statistics.storage.copied_blob_bytes);
    try store.importOwned(&decoded);
    moved = true;
    try testing.expectEqual(0, statistics.storage.copied_blob_bytes);
    try testing.expect(store.imported.?.capacity() >= big.len);
    try store.replace(.{ .id = 0 }, .{ .environment = .{ .values = &.{small}, .tail = null } });
    try store.collect(state.roots);
    try testing.expect(store.imported == null);
    try testing.expectEqual(5, statistics.storage.copied_blob_bytes);
    try testing.expectEqualStrings("small", store.blobs.items[1].bytes);
    const interned = try store.literal(&.{.bytes}, .{ .schema = 0, .bytes = "small" });
    try testing.expectEqual(1, interned.body.blob.id);
}

test "ownership: private index churn retains projections and allocation-free reclamation" {
    const Store = @FieldType(@FieldType(@FieldType(Session, "driver"), "outer"), "store");
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store: Store = .{ .allocator = failing.allocator() };
    defer store.deinit();
    const original = try store.literal(&.{.bytes}, .{ .schema = 0, .bytes = "source" });
    const projected = try store.literal(&.{.bytes}, .{ .schema = 0, .bytes = "projection" });
    const Projection = @typeInfo(@TypeOf(Store.rememberProjection)).@"fn".param_types[1].?;
    const key: Projection = .{ .blob = original.body.blob.id, .schema = 0, .field = 0 };
    try store.rememberProjection(key, projected);
    const root = try store.add(.{ .environment = .{ .values = &.{original}, .tail = null } });
    const roots: horos.data.graph.Roots = .{ .current = root };
    try populatePrivateIndexChurn(&store, 0);
    try store.collect(roots);
    for (1..17) |generation| {
        try populatePrivateIndexChurn(&store, generation);
        try collectPrivateIndexesWithoutAllocation(&store, &failing, roots);
        try testing.expectEqualDeep(projected, store.data_projections.get(key).?.value);
        try testing.expect(store.blob_alive.items[@intCast(projected.body.blob.id)]);
        try testing.expectEqualStrings(
            "projection",
            store.blobs.items[@intCast(projected.body.blob.id)].bytes,
        );
        const same = try store.literal(&.{.bytes}, .{ .schema = 0, .bytes = "source" });
        try testing.expectEqualDeep(original, same);
        try testing.expectEqual(128, store.free_blobs.items.len);
        for (store.free_blobs.items, 2..) |id, expected| try testing.expectEqual(expected, id);
    }
    try store.replace(root, .{ .environment = .{ .values = &.{}, .tail = null } });
    try collectPrivateIndexesWithoutAllocation(&store, &failing, roots);
    try testing.expect(store.data_projections.get(key) == null);
    try testing.expectEqual(130, store.free_blobs.items.len);
    for (store.free_blobs.items[0..128], 2..) |id, expected| try testing.expectEqual(expected, id);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, store.free_blobs.items[128..]);
}

fn populatePrivateIndexChurn(store: anytype, generation: usize) !void {
    for (0..64) |index| {
        var encoded: [16]u8 = undefined;
        std.mem.writeInt(u64, encoded[0..8], generation, .little);
        std.mem.writeInt(u64, encoded[8..16], index * 2, .little);
        const original = try store.literal(&.{.bytes}, .{ .schema = 0, .bytes = &encoded });
        std.mem.writeInt(u64, encoded[8..16], index * 2 + 1, .little);
        const projected = try store.literal(&.{.bytes}, .{ .schema = 0, .bytes = &encoded });
        try store.rememberProjection(.{
            .blob = original.body.blob.id,
            .schema = 0,
            .field = index,
        }, projected);
    }
}

fn collectPrivateIndexesWithoutAllocation(
    store: anytype,
    failing: *testing.FailingAllocator,
    roots: horos.data.graph.Roots,
) !void {
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    defer {
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
    }
    try store.collect(roots);
    try testing.expect(!failing.has_induced_failure);
}

test "behavior: borrow admission distinguishes older from fresh references through return clauses" {
    const fixture = @import("borrow_return_fixtures");
    for (std.enums.values(fixture.ResultFrom)) |from| {
        for ([_]bool{ false, true }) |initial| {
            for ([_]bool{ false, true }) |delegated| {
                for ([_]bool{ false, true }) |younger| {
                    var builder = source.Builder.init(testing.allocator);
                    defer builder.deinit();
                    const module = try fixture.scenario(
                        &builder,
                        from,
                        initial,
                        younger,
                        delegated,
                    );
                    if (younger) {
                        try testing.expectError(
                            error.InvalidOwnership,
                            source.lower(testing.allocator, module),
                        );
                    } else {
                        var compiled = try source.lower(testing.allocator, module);
                        defer compiled.deinit();
                        var session = try initFromImage(testing.allocator, compiled.program, &.{});
                        defer session.deinit();
                        try testing.expect(try drive(&session, null) == .yielded);
                        try session.resumeYield();
                        const result = try drive(&session, null);
                        try testing.expect(result == .completed);
                        try testing.expectEqual(0, (try session.bytes(&result.completed)).len);
                    }
                }
            }
        }
    }
}

test "behavior: resource implementations preserve private authority and loans across requests" {
    inline for (.{ source.examples.resourceScalar, source.examples.resourcePair }) |example| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(testing.allocator, try example(&builder));
        defer compiled.deinit();
        var session = try initFromImage(testing.allocator, compiled.program, &.{});
        defer session.deinit();
        var borrowed = false;
        for ([_][]const u8{
            "example/resource-acquire", "example/resource-use", "example/resource-release",
        }, 0..) |name, index| {
            const pending = try drive(&session, null);
            try testing.expect(pending == .requested);
            try testing.expectEqualStrings(
                name,
                session.program.effects[@intCast(pending.requested.effect)].identity,
            );
            if (index != 0) try testing.expectEqual(
                41,
                (try session.bytes(&pending.requested.payload))[0],
            );
            var snapshot = try guestState(&session);
            defer snapshot.deinit();
            for (snapshot.state.nodes) |node| {
                if (node.record == .borrow) borrowed = true;
            }
            try roundTrip(&session);
            try answerWithValue(&session, if (index == 0) &.{ 41, 0, 0, 0, 0, 0, 0, 0 } else &.{});
        }
        const result = try drive(&session, null);
        try testing.expect(borrowed and result == .completed);
        try testing.expectEqual(42, (try session.bytes(&result.completed))[0]);
    }
}

test "behavior: stable cancellation releases the resource while its protected borrow is suspended" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.resourceScalar(&builder),
    );
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    try testing.expect(try drive(&session, null) == .requested);
    try answerWithValue(&session, &.{ 41, 0, 0, 0, 0, 0, 0, 0 });
    const use = try drive(&session, null);
    try testing.expect(use == .requested);
    try testing.expectEqualStrings(
        "example/resource-use",
        session.program.effects[@intCast(use.requested.effect)].identity,
    );
    try session.cancel(.{ .text = "stop" });
    const release = try drive(&session, null);
    try testing.expect(release == .requested);
    try testing.expectEqualStrings(
        "example/resource-release",
        session.program.effects[@intCast(release.requested.effect)].identity,
    );
    try testing.expectEqual(41, (try session.bytes(&release.requested.payload))[0]);
    try answerWithValue(&session, &.{});
    try testing.expect(try drive(&session, null) == .cancelled);
}

test "behavior: stable admission rejects a fresh store hidden by a later same-slot rebind" {
    const fixture = @import("borrow_return_fixtures");
    const data = horos.data;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try fixture.scenario(
        &builder,
        .pair,
        true,
        false,
        false,
    ));
    defer compiled.deinit();
    var image = compiled.program;
    const blocks = try testing.allocator.dupe(data.activation.Block, image.blocks);
    defer testing.allocator.free(blocks);
    image.blocks = blocks;
    for (blocks) |*block| {
        for (block.instructions, 0..) |write, at| {
            if (write.opcode != .cell_set) continue;
            for (block.instructions[0..at], 0..) |selected, position| {
                if (selected.opcode != .field or selected.immediate != 1 or
                    selected.destination != write.operands[1]) continue;
                const operations = try testing.allocator.alloc(
                    data.activation.Instruction,
                    block.instructions.len + 1,
                );
                defer testing.allocator.free(operations);
                @memcpy(operations[0..block.instructions.len], block.instructions);
                operations[position].immediate = 0;
                operations[operations.len - 1] = selected;
                block.instructions = operations;
                try testing.expectError(
                    error.InvalidOwnership,
                    data.activation_ownership.analyze(testing.allocator, image),
                );
                return;
            }
        }
    }
    return error.TestUnexpectedResult;
}

test "behavior: stable source installs real handlers and keeps the final checked sum after them" {
    for ([_]usize{ 1, 8, 64, 128, 256 }) |count| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(
            testing.allocator,
            try source.examples.installations(&builder, count),
        );
        defer compiled.deinit();
        var session = try initFromImage(testing.allocator, compiled.program, &.{});
        defer session.deinit();
        const result = try drive(&session, null);
        try testing.expect(result == .completed);
        try testing.expectEqual(count * (count + 1) / 2, std.mem.readInt(
            u64,
            (try session.bytes(&result.completed))[0..8],
            .little,
        ));
    }
}

test "behavior: stable source retains an external request and joins into the same activation" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const boolean = try builder.scalar(bool);
    const unit = try builder.scalar(void);
    const effect = try builder.effect(.{
        .identity = "stable/read",
        .payload = unit,
        .result = integer,
    });
    const main = try builder.declare(&.{boolean}, integer, &.{effect}, &.{});
    const value = try builder.variable(integer);
    const branch = try builder.term(.{ .conditional = .{
        .condition = try builder.reference(builder.parameter(main, 0)),
        .when_true = try builder.pure(try builder.reference(value)),
        .when_false = try builder.pure(try builder.constant(u64, 9)),
    } });
    const request = try builder.term(.{ .perform = .{
        .effect = effect,
        .payload = try builder.constant(void, {}),
    } });
    try builder.define(main, try builder.bind(value, request, branch));
    var compiled = try source.lower(testing.allocator, builder.module(main, unit));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{1});
    defer session.deinit();
    try testing.expect(try drive(&session, 0) == .progressed);
    const pending = try drive(&session, null);
    try testing.expect(pending == .requested);
    try testing.expectEqual(effect, pending.requested.effect);
    try testing.expectError(error.InvalidValue, answerWithValue(&session, &.{2}));
    try testing.expect(try session.observe() == .requested);
    try answerWithValue(&session, &.{ 42, 0, 0, 0, 0, 0, 0, 0 });
    const result = try drive(&session, null);
    try testing.expect(result == .completed);
    try testing.expectEqual(42, std.mem.readInt(
        u64,
        (try session.bytes(&result.completed))[0..8],
        .little,
    ));
}

test "behavior: stable source owns its input and keeps tail-recursive control bounded" {
    var builder = source.Builder.init(testing.allocator);
    var compiled = try source.lower(testing.allocator, try source.examples.recursive(&builder));
    var session = initFromImage(
        testing.allocator,
        compiled.program,
        &.{ 16, 39, 0, 0, 0, 0, 0, 0 },
    ) catch |err| {
        compiled.deinit();
        builder.deinit();
        return err;
    };
    defer session.deinit();
    compiled.deinit();
    builder.deinit();
    var result = try drive(&session, 31);
    for (0..1_000_000) |_| {
        if (!(result == .progressed)) break;
        var cut = try guestState(&session);
        defer cut.deinit();
        try testing.expect(cut.state.nodes.len <= 512);
        result = try session.run(31);
        try checkedCheckpoint(&session);
    }
    try testing.expect(result == .completed);
    try testing.expectEqual(1, (try session.bytes(&result.completed))[0]);
}

test "behavior: stable source resumes an owned package after its handler clause has returned" {
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    const module = try escapedPackageExample(&b);
    var compiled = try source.lower(testing.allocator, module);
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    const observed = try drive(&session, null);
    try testing.expect(observed == .completed);
    try testing.expectEqual(42, std.mem.readInt(
        u64,
        (try session.bytes(&observed.completed))[0..8],
        .little,
    ));
}

fn failingSession(allocator: std.mem.Allocator, prepared: *const @import("kosmos").Prepared) !void {
    var session = try Session.start(allocator, prepared, &.{});
    defer session.deinit();
    const before = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(before);
    const result = try session.run(null);
    try testing.expect(result == .completed);
    try checkedCheckpoint(&session);
}

test "ownership: stable source releases partial native owners at every allocation failure" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.deep(&builder));
    defer compiled.deinit();
    var reference = try initFromImage(testing.allocator, compiled.program, &.{});
    defer reference.deinit();
    try testing.expect(try drive(&reference, null) == .completed);
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    try @import("allocation_testing.zig").check(testing.allocator, failingSession, .{&prepared});
}

test "behavior: stable source reenters a live template-cell cycle without sharing branch control" {
    inline for (.{ source.examples.reentrant, source.examples.cloned }) |example| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(testing.allocator, try example(&builder));
        defer compiled.deinit();
        var session = try initFromImage(testing.allocator, compiled.program, &.{});
        defer session.deinit();
        var result = try drive(&session, 1);
        var yielded = false;
        for (0..1_000_000) |_| {
            if (!(result == .progressed or result == .yielded)) break;
            const before = try session.checkpoint(testing.allocator);
            defer testing.allocator.free(before);
            try roundTrip(&session);
            const after = try session.checkpoint(testing.allocator);
            defer testing.allocator.free(after);
            try testing.expectEqualSlices(u8, before, after);
            if (result == .yielded) {
                yielded = true;
                try session.resumeYield();
            }
            result = try drive(&session, 1);
        }
        try testing.expect(yielded and result == .completed);
        try testing.expectEqualSlices(
            u8,
            &.{ 113, 0, 0, 0, 0, 0, 0, 0 },
            try session.bytes(&result.completed),
        );
    }
}

test "behavior: source does not read a reclaimed copyable result only assigned to a dead binding" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const main = try builder.declare(&.{}, integer, &.{}, &.{});
    const unused = try builder.variable(integer);
    try builder.define(main, try builder.bind(
        unused,
        try builder.pure(try builder.constant(u64, 7)),
        try builder.pure(try builder.constant(u64, 42)),
    ));
    var compiled = try source.lower(testing.allocator, builder.module(main, unit));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    const result = try drive(&session, null);
    try testing.expect(result == .completed);
    try testing.expectEqual(42, (try session.bytes(&result.completed))[0]);
}

test "behavior: retained template preserves an older activation across loop-slot rebindings" {
    var session = try initFromImage(testing.allocator, retainedTemplateProgram, &.{});
    defer session.deinit();
    const result = try drive(&session, null);
    try testing.expect(result == .completed);
    try testing.expectEqual(6, (try session.bytes(&result.completed))[0]);
}

test "behavior: stable shallow value and computation resumptions omit the original return clause" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.shallowResumptions(&builder),
    );
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    var result = try drive(&session, 1);
    for (0..1_000_000) |_| {
        if (!(result == .progressed)) break;
        try roundTrip(&session);
        result = try drive(&session, 1);
    }
    try testing.expect(result == .completed);
    const bytes = try session.bytes(&result.completed);
    try testing.expectEqual(64, bytes.len);
    for (0..8) |index| {
        const expected: u64 = if (index < 4) 99 else 42;
        try testing.expectEqual(expected, std.mem.readInt(u64, bytes[index * 8 ..][0..8], .little));
    }
}

test "behavior: stable injection selects definition-site versus use-site capabilities" {
    inline for (.{ source.examples.injection, source.examples.shallowInjection }) |example| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(testing.allocator, try example(&builder));
        defer compiled.deinit();
        for ([_]u8{ 0, 1 }) |injecting| {
            var session = try initFromImage(testing.allocator, compiled.program, &.{injecting});
            defer session.deinit();
            var result = try drive(&session, 1);
            var saw_injection = false;
            for (0..1_000_000) |_| {
                if (!(result == .progressed)) break;
                var snapshot = try guestState(&session);
                defer snapshot.deinit();
                for (snapshot.state.nodes) |node|
                    if (node.record == .injection) {
                        saw_injection = true;
                    };
                try roundTrip(&session);
                result = try drive(&session, 1);
            }
            try testing.expect(result == .completed);
            try testing.expectEqual(@as(
                u64,
                if (injecting == 0) 109 else 209,
            ), std.mem.readInt(u64, (try session.bytes(&result.completed))[0..8], .little));
            try testing.expectEqual(injecting == 1, saw_injection);
        }
    }
}

test "behavior: stable cleanup preserves primary failure and resumes external cleanup" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.unwind(&builder));
    defer compiled.deinit();
    for ([_]u8{ 0, 1 }) |primary| {
        var session = try initFromImage(testing.allocator, compiled.program, &.{primary});
        defer session.deinit();
        for ([_][]const u8{ "example/middle-cleanup", "example/outer-cleanup" }) |name| {
            const pending = try drive(&session, null);
            try testing.expect(pending == .requested);
            try testing.expectEqualStrings(
                name,
                session.program.effects[@intCast(pending.requested.effect)].identity,
            );
            try roundTrip(&session);
            try answerWithValue(&session, &.{});
        }
        const result = try drive(&session, null);
        try testing.expect(result == .failed);
        try testing.expectEqual(
            @as(u8, if (primary == 1) 9 else 7),
            (try session.bytes(&result.failed))[0],
        );
        try testing.expectEqual(2, (try session.terminalExit()).cleanup_failures.len);
        try testing.expectEqual(7, (try session.bytes(
            &(try session.terminalExit()).cleanup_failures[0],
        ))[0]);
        try testing.expectEqual(8, (try session.bytes(
            &(try session.terminalExit()).cleanup_failures[1],
        ))[0]);
    }
}

test "behavior: stable cancellation during yielded cleanup preserves the first reason" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.yieldingCleanup(&builder),
    );
    defer compiled.deinit();
    for ([_]u8{ 0, 1 }) |primary| {
        var session = try initFromImage(testing.allocator, compiled.program, &.{primary});
        defer session.deinit();
        for (0..2) |round| {
            try testing.expect(try drive(&session, null) == .yielded);
            try session.cancel(.{ .text = if (round == 0) "stop" else "later" });
            try session.resumeYield();
            const pending = try drive(&session, null);
            try testing.expect(pending == .requested);
            try answerWithValue(&session, &.{});
        }
        const result = try drive(&session, null);
        try testing.expect(result == .failed);
        try testing.expectEqual(
            @as(u8, if (primary == 1) 9 else 7),
            (try session.bytes(&result.failed))[0],
        );
        try testing.expectEqualStrings("stop", (try session.terminalExit()).cancellation.?.text);
    }
}

test "behavior: stable unwind preserves lexical and temporary-owner cleanup order" {
    for (0..10) |mode| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(
            testing.allocator,
            try source.examples.custodyOrder(&builder, @intCast(mode)),
        );
        defer compiled.deinit();
        var session = try initFromImage(testing.allocator, compiled.program, &.{});
        defer session.deinit();
        var requests: usize = 0;
        var yields: usize = 0;
        var result = try drive(&session, 1);
        for (0..1_000_000) |_| {
            if (!(result == .progressed or result == .yielded or result == .requested)) break;
            if (result == .yielded) {
                yields += 1;
                try session.resumeYield();
            }
            if (result == .requested) {
                try testing.expect(requests < 2);
                const reversed = mode == 1 or mode == 3 or mode >= 4;
                const label: u64 = if (reversed) 2 - requests else requests + 1;
                try testing.expectEqual(label, std.mem.readInt(
                    u64,
                    (try session.bytes(&result.requested.payload))[0..8],
                    .little,
                ));
                requests += 1;
                try answerWithValue(&session, &.{});
            }
            try roundTrip(&session);
            result = try drive(&session, 1);
        }
        try testing.expect(result == .failed);
        try testing.expectEqual(8, (try session.bytes(&result.failed))[0]);
        try testing.expectEqual(2, requests);
        try testing.expectEqual(1, yields);
    }
}

test "behavior: cancellation preserves cleanup at entry yield request and answered boundaries" {
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const info = try horos.library.cleanup.exitInfo(&b, integer);
    const read_effect = try b.effect(.{
        .identity = "cancel/read",
        .payload = unit,
        .result = integer,
    });
    const release = try b.effect(.{
        .identity = "cancel/release",
        .payload = info,
        .result = unit,
    });
    const body = try b.declare(&.{}, integer, &.{read_effect}, &.{});
    const request = try b.term(.{ .perform = .{
        .effect = read_effect,
        .payload = try b.constant(void, {}),
    } });
    const repeated = try b.bind(try b.variable(integer), request, request);
    try b.define(body, try b.term(.{ .yield_then = repeated }));
    const cleanup = try b.declare(&.{info}, unit, &.{release}, &.{});
    try b.define(cleanup, try b.term(.{ .perform = .{
        .effect = release,
        .payload = try b.reference(b.parameter(cleanup, 0)),
    } }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .effects = &.{read_effect},
    } } });
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{info},
        .result = unit,
        .effects = &.{release},
    } } });
    const main = try b.declare(&.{}, integer, &.{ read_effect, release }, &.{});
    try b.define(main, try b.term(.{ .protect = .{
        .body = try b.lambda(body, body_type),
        .cleanup = try b.lambda(cleanup, cleanup_type),
    } }));
    var compiled = try source.lower(testing.allocator, b.module(main, integer));
    defer compiled.deinit();
    for (0..4) |phase| {
        var session = try initFromImage(testing.allocator, compiled.program, &.{});
        defer session.deinit();
        try testing.expectError(error.InvalidUtf8, session.cancel(.{ .text = &.{0xff} }));
        if (phase >= 1) try testing.expect(try drive(&session, null) == .yielded);
        if (phase >= 2) {
            try session.resumeYield();
            const pending = try drive(&session, null);
            try testing.expect(pending == .requested and pending.requested.effect == read_effect);
        }
        if (phase == 3) try answerWithValue(&session, &.{ 7, 0, 0, 0, 0, 0, 0, 0 });
        try session.cancel(.{ .text = "stop" });
        var result = try drive(&session, null);
        if (phase != 0) {
            try testing.expect(result == .requested and result.requested.effect == release);
            try answerWithValue(&session, &.{});
            result = try drive(&session, null);
        }
        try testing.expect(result == .cancelled);
        try testing.expectEqualStrings("stop", result.cancelled.text);
        try testing.expectEqual(0, (try session.terminalExit()).cleanup_failures.len);
    }
}

test "behavior: stable clause failure abandons a captured cleanup without losing its primary exit" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.clauseAbort(&builder));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    const pending = try drive(&session, null);
    try testing.expect(pending == .requested);
    try testing.expectEqualStrings(
        "example/abandoned-release",
        session.program.effects[@intCast(pending.requested.effect)].identity,
    );
    try testing.expectEqualSlices(
        u8,
        &.{ 1, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        try session.bytes(&pending.requested.payload),
    );
    try roundTrip(&session);
    try answerWithValue(&session, &.{});
    const result = try drive(&session, null);
    try testing.expect(result == .failed);
    try testing.expectEqual(9, (try session.bytes(&result.failed))[0]);
}

test "behavior: stable generator resumes private state and closes its retained cleanup" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.generator(&builder));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    var yields: usize = 0;
    var releases: usize = 0;
    var result = try drive(&session, 1);
    for (0..1_000_000) |_| {
        if (!(result != .completed)) break;
        switch (result) {
            .progressed => {},
            .yielded => {
                yields += 1;
                try session.resumeYield();
            },
            .requested => |pending| {
                releases += 1;
                try testing.expectEqualStrings(
                    "example/generator-release",
                    session.program.effects[@intCast(pending.effect)].identity,
                );
                try testing.expectEqual(43, (try session.bytes(&pending.payload))[0]);
                try answerWithValue(&session, &.{});
            },
            else => return error.TestUnexpectedResult,
        }
        try roundTrip(&session);
        result = try drive(&session, 1);
    }
    try testing.expect(result == .completed);
    try testing.expectEqual(1, yields);
    try testing.expectEqual(1, releases);
    try testing.expectEqualSlices(u8, &.{
        42, 0, 0, 0, 0, 0, 0, 0, 43, 0, 0, 0, 0, 0, 0, 0,
    }, try session.bytes(&result.completed));
}

test "behavior: interaction phases follow atomic dispatch and the installed yield successor" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const module = try source.examples.deep(&builder);
    const clause = builder.handlers.items[0].clauses[0].function;
    const body = builder.functions.items[@intCast(clause)].body.?;
    builder.functions.items[@intCast(clause)].body = try builder.term(.{ .yield_then = body });
    var compiled = try source.lower(
        testing.allocator,
        builder.module(module.entry, module.failure),
    );
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var session = try Session.initImage(testing.allocator, image, &.{});
    defer session.deinit();
    var dispatched = false;
    var yielded = false;
    for (0..128) |_| {
        var before = try guestState(&session);
        defer before.deinit();
        const current = before.state.roots.current orelse return error.TestUnexpectedResult;
        const control = before.state.nodes[@intCast(current.id)].record.control;
        const frame = before.state.nodes[@intCast(current.id)].activation.?;
        const block = session.program.blocks[@intCast(control.block)];
        const at_control = frame.position == block.instructions.len;
        const local = at_control and block.terminator == .perform and
            block.terminator.perform.capability != null;
        const yielding = at_control and block.terminator == .yield_value;
        const result = try session.run(1);
        if (local or yielding) {
            var after = try guestState(&session);
            defer after.deinit();
            const next = after.state.nodes[@intCast(after.state.roots.current.?.id)].record.control;
            if (local) {
                try testing.expect(result == .progressed);
                try testing.expect(after.state.roots.pending == null);
                const target = session.program.handlers[0].clauses[0].function;
                try testing.expectEqual(
                    target,
                    session.program.blocks[@intCast(next.block)].function,
                );
                try testing.expect(next.block != control.block);
                dispatched = true;
            } else {
                try testing.expect(result == .yielded);
                try testing.expectEqual(block.terminator.yield_value.block, next.block);
                yielded = true;
            }
            const checkpoint = try session.checkpoint(testing.allocator);
            defer testing.allocator.free(checkpoint);
            var cancelled = try Session.restoreImage(testing.allocator, image, checkpoint);
            defer cancelled.deinit();
            var resumed = try guestState(&cancelled);
            defer resumed.deinit();
            const restored = resumed.state.nodes[
                @intCast(resumed.state.roots.current.?.id)
            ].record.control;
            try testing.expectEqual(next.block, restored.block);
            try cancelled.cancel(.{ .text = "phase-check" });
            try testing.expect(try drive(&cancelled, null) == .cancelled);
        }
        if (yielded) break;
        try testing.expect(result == .progressed);
    }
    try testing.expect(dispatched and yielded);
}

test "behavior: stateful service preserves labeled replies and exclusive turns through restore" {
    inline for (.{ .empty, .requests, .swapped, .cancelled, .overflow, .paired }) |mode| {
        for ([_]bool{ false, true }) |restore| try serviceWitness(mode, restore);
    }
}

fn serviceWitness(
    comptime mode: ServiceMode,
    restore: bool,
) !void {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const module = if (mode == .paired)
        try source.examples.pairedServices(&builder)
    else if (mode == .swapped)
        try source.examples.swappedServiceReplies(&builder)
    else
        try source.examples.statefulService(&builder);
    var compiled = try source.lower(testing.allocator, module);
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var session = try Session.initImage(testing.allocator, image, &.{});
    defer session.deinit();
    var counts: ServiceCounts = .{};
    const final: u64 = switch (mode) {
        .empty => 0,
        .cancelled, .overflow => 1,
        .requests, .swapped, .paired => 2,
    };
    for (0..16) |_| {
        const result = try drive(&session, null);
        switch (result) {
            .yielded => {
                counts.yields += 1;
                try testing.expectEqual(counts.commands, counts.yields);
                try testing.expectEqual(counts.replies + 1, counts.commands);
                if (restore) try restoreService(&session, image);
                if (mode == .cancelled) try session.cancel(.{
                    .text = "stop",
                }) else try session.resumeYield();
            },
            .requested => |pending| try serviceRequest(&session, pending, mode, &counts, final),
            .completed => |value| {
                try testing.expect(
                    mode == .empty or mode == .requests or mode == .swapped or mode == .paired,
                );
                var expected: [8]u8 = undefined;
                std.mem.writeInt(u64, &expected, final, .little);
                try testing.expectEqualSlices(u8, &expected, try session.bytes(&value));
                break;
            },
            .failed => {
                try testing.expect(mode == .overflow);
                break;
            },
            .cancelled => {
                try testing.expect(mode == .cancelled);
                break;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expect(session.isTerminal());
    try testing.expectEqual(@as(usize, if (mode == .paired) 2 else 1), counts.releases);
    try testing.expectEqual(@as(usize, switch (mode) {
        .empty, .cancelled => 0,
        .overflow => 1,
        .requests, .swapped, .paired => 2,
    }), counts.replies);
}

test "behavior: stable successor return clauses retain older capability and cell references" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.successorState(&builder),
    );
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    try testing.expect(try drive(&session, null) == .yielded);
    try roundTrip(&session);
    try session.resumeYield();
    const result = try drive(&session, null);
    try testing.expect(result == .completed);
    try testing.expectEqualSlices(u8, &.{
        42, 0, 0, 0, 0, 0, 0, 0, 37, 0, 0, 0, 0, 0, 0, 0,
    }, try session.bytes(&result.completed));
}

fn captureFrameCheckpoint(session: *Session) ![]u8 {
    for (0..512) |_| {
        try session.step();
        var snapshot = try guestState(session);
        defer snapshot.deinit();
        for (snapshot.state.nodes) |node| {
            if (node.record == .one_shot or node.record == .multi_template)
                return session.checkpoint(testing.allocator);
        }
    }
    return error.MissingCapture;
}

fn emptyNodeRecord(comptime tag: horos.data.graph.NodeTag) horos.data.graph.Node {
    const g = horos.data.graph;
    const value: g.Value = .{ .schema = 0, .body = .{ .scalar = @splat(0) } };
    return switch (tag) {
        .package => .{ .package = .{ .schema = 0, .continuation = value } },
        .resource => .{ .resource = .{ .schema = 0, .value = value } },
        .pending => .{ .pending = .{
            .effect = 0,
            .payload = value,
            .continuation = .{ .id = 0 },
            .source_block = 0,
        } },
        .obligation => .{ .obligation = .{
            .source_block = 0,
            .cleanup = null,
            .resource = null,
            .status = .pending,
        } },
        .exit => .{ .exit = .{ .reason = .{ .normal = value } } },
        else => @unionInit(g.Node, @tagName(tag), std.mem.zeroes(
            @FieldType(g.Node, @tagName(tag)),
        )),
    };
}

const ReturnPathKind = enum { active, yielded, continuation, protection, normal_exit, captured };

fn returnParent(record: *horos.data.graph.Node) ?*?horos.data.graph.NodeRef {
    return switch (record.*) {
        .control => &record.control.parent,
        .continuation => &record.continuation.parent,
        .attachment => &record.attachment.return_to,
        .protection => &record.protection.return_to,
        .region_scope => &record.region_scope.return_to,
        .cleanup_return => &record.cleanup_return.parent,
        .disposal_return => &record.disposal_return.parent,
        else => null,
    };
}

fn rejectDisposalParent(
    image: []const u8,
    original: horos.data.process_state.State,
    frame: usize,
    schema: u64,
) !void {
    const data = horos.data;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state = original;
    const nodes = try arena.allocator().alloc(data.process_state.Node, state.nodes.len + 1);
    @memcpy(nodes[0..state.nodes.len], state.nodes);
    const parent = returnParent(&nodes[frame].record) orelse return error.ExpectedReturnParent;
    nodes[state.nodes.len] = .{ .record = .{ .disposal_return = .{
        .schema = schema,
        .parent = parent.*,
    } } };
    parent.* = .{ .id = state.nodes.len };
    state.nodes = nodes;
    const encoded = try data.state_image.emit(testing.allocator, state);
    defer testing.allocator.free(encoded);
    try testing.expectError(
        error.InvalidState,
        Session.restoreImage(testing.allocator, image, encoded),
    );
}

fn checkReturnPaths(
    session: *Session,
    image: []const u8,
    schema: u64,
    seen: *std.EnumSet(ReturnPathKind),
    captured_cleanup: *bool,
) !void {
    const data = horos.data;
    const bytes = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(bytes);
    var decoded = try data.state_image.decodeGraph(testing.allocator, bytes);
    defer decoded.deinit();
    const state = decoded.state;
    try data.state_admission.validateStable(testing.allocator, session.program, state);
    var selected = std.EnumArray(ReturnPathKind, ?usize).initFill(null);
    var cursor = state.roots.current;
    if (cursor) |ref| {
        if (state.status == .active) selected.set(.active, @intCast(ref.id));
        if (state.status == .yielded) selected.set(.yielded, @intCast(ref.id));
    }
    const nodes = @constCast(state.nodes);
    for (0..nodes.len) |_| {
        const ref = cursor orelse break;
        const record = &nodes[@intCast(ref.id)].record;
        if (record.* == .continuation) selected.set(.continuation, @intCast(ref.id));
        if (record.* == .protection) selected.set(.protection, @intCast(ref.id));
        cursor = if (returnParent(record)) |parent| parent.* else null;
    }
    try testing.expect(cursor == null);
    for (nodes) |node| switch (node.record) {
        .exit => |exit| if (exit.reason == .normal) {
            if (exit.stop) |stop| selected.set(.normal_exit, @intCast(stop.id));
        },
        .one_shot, .multi_template => |token| {
            selected.set(.captured, @intCast(token.capture.?.id));
            if (state.roots.exit != null) captured_cleanup.* = true;
        },
        else => {},
    };
    for (std.enums.values(ReturnPathKind)) |kind| if (!seen.contains(kind)) {
        if (selected.get(kind)) |frame| {
            try rejectDisposalParent(image, state, frame, schema);
            seen.insert(kind);
        }
    };
    const restored = try Session.restoreImage(testing.allocator, image, bytes);
    session.deinit();
    session.* = restored;
}

test "behavior: PST3 return paths reject disposal markers and preserve captured cleanup" {
    var seen: std.EnumSet(ReturnPathKind) = .{};
    var captured_cleanup = false;
    for (0..3) |example| {
        var b = source.Builder.init(testing.allocator);
        defer b.deinit();
        const module = switch (example) {
            0 => try source.examples.deep(&b),
            1 => try source.examples.branchingTailProtected(&b),
            else => try source.examples.clauseAbort(&b),
        };
        if (example == 0) {
            const entry = &b.functions.items[@intCast(module.entry)];
            entry.body = try b.term(.{ .yield_then = entry.body.? });
        }
        var marker = b.schemas.items[@intCast(b.handlers.items[0].clauses[0].resumption)];
        const effects = try b.allocator().alloc(u64, b.effects.items.len);
        for (effects, 0..) |*effect, id| effect.* = id;
        marker.internal.resumption.effects = effects;
        const marker_schema = try b.schema(marker);
        var compiled = try compileDeclarations(b.module(module.entry, module.failure));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer testing.allocator.free(image);
        var session = try Session.initImage(
            testing.allocator,
            image,
            if (example == 1) &.{1} else &.{},
        );
        defer session.deinit();
        for (0..512) |_| {
            try checkReturnPaths(&session, image, marker_schema, &seen, &captured_cleanup);
            if (session.isTerminal()) break;
            switch (try session.observe()) {
                .yielded => try session.resumeYield(),
                .requested => try answerWithValue(&session, &.{}),
                else => try session.step(),
            }
        }
        const result = try session.observe();
        if (example == 2) {
            try testing.expect(result == .failed);
            try testing.expectEqual(9, (try session.bytes(&result.failed))[0]);
        } else {
            try testing.expect(result == .completed);
            try testing.expectEqual(
                if (example == 0) @as(u8, 67) else 60,
                (try session.bytes(&result.completed))[0],
            );
        }
    }
    try testing.expectEqual(std.EnumSet(ReturnPathKind).full.bits, seen.bits);
    try testing.expect(captured_cleanup);
}

test "behavior: PST3 captured handler state obeys one-shot and multi bounds and reference kinds" {
    const data = horos.data;
    inline for (.{ false, true }) |multi| inline for (.{ false, true }) |allowed| {
        var b = source.Builder.init(testing.allocator);
        defer b.deinit();
        const module = if (multi)
            try source.examples.choicesAll(&b)
        else
            try source.examples.deep(&b);
        const result_type = b.handlers.items[0].input;
        const wide = try b.scalar(u16);
        const returns = try b.declare(&.{ wide, result_type }, result_type, &.{}, &.{});
        try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 1))));
        const extra = try b.handler(.{
            .mode = .deep,
            .input = result_type,
            .answer = result_type,
            .return_function = returns,
            .state = &.{wide},
            .clauses = &.{},
        });
        if (allowed) for (b.schemas.items) |*schema| {
            if (schema.* != .internal or schema.internal != .resumption) continue;
            const old = schema.internal.resumption.capture_bound;
            const extended = try b.allocator().alloc(u64, old.len + 1);
            @memcpy(extended[0..old.len], old);
            extended[old.len] = wide;
            schema.internal.resumption.capture_bound = extended;
        };
        var compiled = try compileDeclarations(b.module(module.entry, module.failure));
        defer compiled.deinit();
        var session = try initFromImage(testing.allocator, compiled.program, &.{});
        defer session.deinit();
        const bytes = try captureFrameCheckpoint(&session);
        defer testing.allocator.free(bytes);
        var decoded = try data.state_image.decodeGraph(testing.allocator, bytes);
        defer decoded.deinit();
        try data.state_admission.validateStable(testing.allocator, compiled.program, decoded.state);
        try insertCapturedHandler(&decoded, extra, wide);
        const encoded = try data.state_image.emit(testing.allocator, decoded.state);
        defer testing.allocator.free(encoded);
        var canonical = try data.state_image.decodeGraph(testing.allocator, encoded);
        defer canonical.deinit();
        const checked_nodes = @constCast(canonical.state.nodes);
        const handler_index = for (checked_nodes, 0..) |node, index| {
            if (node.record == .handler and node.record.handler.definition == extra) break index;
        } else return error.MissingInsertedHandler;
        if (!allowed) {
            try testing.expectError(error.InvalidOwnership, data.state_admission.validateStable(
                testing.allocator,
                compiled.program,
                canonical.state,
            ));
            continue;
        }
        try expectCapturedHandlerKinds(compiled.program, canonical.state, handler_index, multi);
    };
}

fn argumentImage() ![]u8 {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const bytes = try builder.schema(.bytes);
    const unit = try builder.scalar(void);
    const entry = try builder.declare(&.{ bytes, bytes, bytes }, bytes, &.{}, &.{});
    try builder.define(entry, try builder.pure(try builder.reference(builder.parameter(entry, 1))));
    var compiled = try source.lower(testing.allocator, builder.module(entry, unit));
    defer compiled.deinit();
    return programBytes(compiled.program);
}

fn argumentBytes(size: usize) ![]u8 {
    const payload = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(payload);
    @memset(payload, 0x39);
    var measure: horos.data.wire.Writer = .{};
    try measure.bytes(payload);
    try measure.bytes("small");
    try measure.bytes("small");
    const bytes = try testing.allocator.alloc(u8, measure.position);
    var writer: horos.data.wire.Writer = .{ .output = bytes };
    try writer.bytes(payload);
    try writer.bytes("small");
    try writer.bytes("small");
    return bytes;
}

fn argumentSessionFailure(
    allocator: std.mem.Allocator,
    prepared: *const @import("kosmos").Prepared,
    input: []const u8,
) !void {
    var session = try Session.start(allocator, prepared, input);
    defer session.deinit();
    const result = try session.run(null);
    try testing.expect(result == .completed);
    try testing.expectEqualSlices(
        u8,
        &.{ 5, 's', 'm', 'a', 'l', 'l' },
        try session.bytes(&result.completed),
    );
}

test "ownership: argument backing releases every partial Session owner on allocation failure" {
    const image = try argumentImage();
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    const input = try argumentBytes(4096);
    defer testing.allocator.free(input);
    try @import("allocation_testing.zig").check(
        testing.allocator,
        argumentSessionFailure,
        .{ &prepared, input },
    );
}

test "behavior: argument Session survives caller release and sheds a large dead payload" {
    const image = try argumentImage();
    defer testing.allocator.free(image);
    const input = try argumentBytes(1 << 20);
    var session = Session.initImage(testing.allocator, image, input) catch |err| {
        testing.allocator.free(input);
        return err;
    };
    defer session.deinit();
    @memset(input, 0xff);
    testing.allocator.free(input);
    const checkpoint = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    var restored = try Session.restoreImage(testing.allocator, image, checkpoint);
    defer restored.deinit();
    const result = try session.run(null);
    const transferred = try restored.run(null);
    const expected = [_]u8{ 5, 's', 'm', 'a', 'l', 'l' };
    try testing.expect(result == .completed and transferred == .completed);
    try testing.expectEqualSlices(u8, &expected, try session.bytes(&result.completed));
    try testing.expectEqualSlices(u8, &expected, try restored.bytes(&transferred.completed));
    const terminal_state = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(terminal_state);
    try testing.expect(terminal_state.len < 1024);
}

fn argumentStoreFailure(
    allocator: std.mem.Allocator,
    prepared: *const @import("kosmos").Prepared,
    input: []const u8,
) !void {
    const core = try prepared.acquire();
    defer core.release();
    var store: @FieldType(@FieldType(
        @FieldType(Session, "driver"),
        "outer",
    ), "store") = .{ .allocator = allocator };
    defer store.deinit();
    var temporary = std.heap.ArenaAllocator.init(allocator);
    defer temporary.deinit();
    const values = try store.importArguments(core.admitted(), input, temporary.allocator());
    try testing.expectEqual(2, store.blobs.items.len);
    try testing.expectEqualDeep(values[1], values[2]);
    const root = try store.add(.{ .environment = .{ .values = values, .tail = null } });
    try store.begin();
    try store.replace(root, .{ .environment = .{ .values = &.{}, .tail = null } });
    try store.collect(.{ .current = root });
    try testing.expect(store.imported != null);
    _ = try store.literal(core.admitted().program().schemas, .{
        .schema = values[1].schema,
        .bytes = &.{ 3, 'n', 'e', 'w' },
    });
    store.rollback();
    const original = (try store.get(root)).environment.values;
    try testing.expectEqualDeep(values, original);
    try testing.expectEqualSlices(
        u8,
        &.{ 5, 's', 'm', 'a', 'l', 'l' },
        store.blobs.items[@intCast(values[1].body.blob.id)].bytes,
    );
    var reader: horos.data.wire.Reader = .{ .input = input };
    const count = try reader.count();
    _ = try reader.take(count);
    try testing.expectEqualSlices(
        u8,
        input[0..reader.position],
        store.blobs.items[@intCast(values[0].body.blob.id)].bytes,
    );
    try store.replace(root, .{ .environment = .{ .values = values[1..2], .tail = null } });
    try store.collect(.{ .current = root });
    try testing.expect(store.imported == null);
    try testing.expectEqualSlices(
        u8,
        &.{ 5, 's', 'm', 'a', 'l', 'l' },
        store.blobs.items[@intCast(values[1].body.blob.id)].bytes,
    );
    const same = try store.literal(core.admitted().program().schemas, .{
        .schema = values[1].schema,
        .bytes = &.{ 5, 's', 'm', 'a', 'l', 'l' },
    });
    try testing.expectEqualDeep(values[1], same);
}

test "ownership: argument backing survives collection and reuse then compacts a tiny survivor" {
    const image = try argumentImage();
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    const input = try argumentBytes(4096);
    defer testing.allocator.free(input);
    try @import("allocation_testing.zig").check(
        testing.allocator,
        argumentStoreFailure,
        .{ &prepared, input },
    );
}

test "ownership: resident terminal compaction preserves rollback and releases backing at commit" {
    const image = try argumentImage();
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    const input = try argumentBytes(4096);
    defer testing.allocator.free(input);
    var initial = try Session.start(testing.allocator, &prepared, input);
    defer initial.deinit();
    const checkpoint = try initial.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    const expected = try horos.data.invocation.encodeOwned(
        horos.data.invocation.Outcome,
        testing.allocator,
        .{ .completed = &.{ 5, 's', 'm', 'a', 'l', 'l' } },
    );
    defer testing.allocator.free(expected);
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    var reference = try Resident.start(counting.allocator(), &prepared, input);
    defer releaseResident(&reference);
    const allocation_start = counting.alloc_index;
    counting.resize_fail_index = counting.resize_index;
    const reference_output = try reference.driveEncoded(counting.allocator(), .none, .{});
    defer counting.allocator().free(reference_output);
    const allocation_count = counting.alloc_index - allocation_start;
    for (0..allocation_count + 1) |failures| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var resident = try Resident.start(failing.allocator(), &prepared, input);
        defer releaseResident(&resident);
        failing.fail_index = failing.alloc_index + failures;
        failing.resize_fail_index = failing.resize_index;
        const output = resident.driveEncoded(failing.allocator(), .none, .{}) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, err);
            const unchanged = try resident.checkpoint(testing.allocator);
            defer testing.allocator.free(unchanged);
            try testing.expectEqualSlices(u8, checkpoint, unchanged);
            const retry = try resident.driveEncoded(testing.allocator, .none, .{});
            defer testing.allocator.free(retry);
            try testing.expectEqualSlices(u8, expected, retry);
            try testing.expect(!(try resident.diagnostics()).imported_backing);
            continue;
        };
        defer failing.allocator().free(output);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try testing.expectEqualSlices(u8, expected, output);
        try testing.expect(!(try resident.diagnostics()).imported_backing);
        try testing.expect(failures > 0);
        return;
    }
    return error.MissingAllocationSweepSuccess;
}

test "behavior: handler continuation preserves staged operands across checkpoint restoration" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.installations(&builder, 8),
    );
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    for (0..256) |_| {
        var before = try guestState(&session);
        defer before.deinit();
        const current = before.state.roots.current.?;
        const control = before.state.nodes[@intCast(current.id)].record.control;
        const block = session.program.blocks[@intCast(control.block)];
        const frame = before.state.nodes[@intCast(current.id)].activation.?;
        if (frame.position == block.instructions.len and block.terminator == .handle) {
            try session.step();
            var after = try guestState(&session);
            defer after.deinit();
            const body = after.state.nodes[@intCast(after.state.roots.current.?.id)].record.control;
            const attachment = after.state.nodes[@intCast(body.parent.?.id)].record.attachment;
            const saved = after.state.nodes[@intCast(attachment.return_to.?.id)];
            try testing.expect(saved.record == .continuation);
            try testing.expect(saved.activation != null);
            try roundTrip(&session);
            const checkpoint = try session.checkpoint(testing.allocator);
            defer testing.allocator.free(checkpoint);
            const result = try drive(&session, null);
            try testing.expect(result == .completed);
            try testing.expectEqual(36, std.mem.readInt(
                u64,
                (try session.bytes(&result.completed))[0..8],
                .little,
            ));
            return;
        }
        try session.step();
    }
    return error.TestUnexpectedResult;
}

fn prepareContractFailure(
    allocator: std.mem.Allocator,
    image: []const u8,
    runtime: *const @import("kosmos").RuntimeArtifact,
) !void {
    var prepared = try @import("kosmos").Prepared.initWithRuntime(allocator, image, runtime);
    defer prepared.deinit();
}

test "ownership: prepared contracts retain encoded bytes without canonicalization scratch" {
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    var fields: [64]source.Id = undefined;
    for (&fields, 0..) |*field, i| field.* = try b.schema(.{ .bounded_text = i + 1 });
    const payload = try b.schema(.{ .product = &fields });
    const effect = try b.effect(.{
        .identity = "large-contract",
        .payload = payload,
        .result = payload,
        .external = true,
    });
    const entry = try b.declare(&.{payload}, payload, &.{effect}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.reference(b.parameter(entry, 0)),
    } }));
    var compiled = try source.lower(testing.allocator, b.module(entry, try b.scalar(void)));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    const admitted = prepared.guest.core.?.admitted();
    const program = admitted.program();
    const contract = try prepared.guest.core.?.contract(0);
    const expected = try horos.data.schema.encodeOwned(
        testing.allocator,
        program.schemas,
        program.effects[0].payload,
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(u8, expected, contract.payload);
    try testing.expectEqualSlices(u8, expected, contract.resume_value);
    const contract_storage = (try prepared.guest.storageBytes()) - admitted.storageBytes();
    try testing.expect(
        contract_storage <= 1024 + 4 * (contract.payload.len + contract.resume_value.len),
    );
    try @import("allocation_testing.zig").check(
        testing.allocator,
        prepareContractFailure,
        .{ image, &prepared.runtime },
    );
}

const blobRetentionCaptured: horos.data.activation.Program = .{
    .roots = .{ .entry = 0, .result = 1, .failure = 2 },
    .schemas = &.{ .bytes, .u64, .unit, .{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = 1,
        .capture_bound = &.{0},
        .use = .reusable,
    } } } },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 1, 3, 1 } }, .result = 1 },
        .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 1 } }, .result = 1 },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{
            .{ .destination = 2, .opcode = .computation, .immediate = 0, .operands = &.{0} },
            .{ .destination = 1, .opcode = .blob_length, .operands = &.{0} },
        }, .terminator = .{
            .apply = .{
                .computation = 2,
                .arguments = &.{},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{
                        .destination = 3,
                        .source = .returned,
                    }},
                },
            },
        } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{ .function = 1, .instructions = &.{.{
            .destination = 1,
            .opcode = .blob_length,
            .operands = &.{0},
        }}, .terminator = .{ .return_value = 1 } },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 3 }},
};

fn blobRetentionProgram(comptime alias: bool) horos.data.activation.Program {
    return .{
        .roots = .{ .entry = 0, .result = 1, .failure = 2 },
        .schemas = &.{ .bytes, .u64, .unit },
        .constants = &.{},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = if (alias) &.{ 0, 2 } else &.{0},
            .layout = .{ .slots = &.{ 0, 1, 0 } },
            .result = 1,
        }},
        .blocks = if (alias) &.{.{ .function = 0, .instructions = &.{
            .{ .destination = 1, .opcode = .blob_length, .operands = &.{0} },
            .{ .destination = 1, .opcode = .blob_length, .operands = &.{2} },
        }, .terminator = .{ .return_value = 1 } }} else &.{.{ .function = 0, .instructions = &.{
            .{ .destination = 1, .opcode = .blob_length, .operands = &.{0} },
            .{ .destination = 1, .opcode = .integer_bit_xor, .operands = &.{ 1, 1 } },
        }, .terminator = .{ .return_value = 1 } }},
    };
}

test "behavior: bounded cuts reclaim dead blobs and preserve direct and captured aliases" {
    inline for (0..3) |kind| {
        const original = comptime if (kind == 2) blobRetentionCaptured else blobRetentionProgram(
            kind == 1,
        );
        const image = try programBytes(original);
        defer testing.allocator.free(image);
        var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
        defer prepared.deinit();
        const payload = try testing.allocator.alloc(u8, 1 << 20);
        defer testing.allocator.free(payload);
        @memset(payload, 'x');
        const arguments = try testing.allocator.alloc(u8, 2 * (payload.len + 10));
        defer testing.allocator.free(arguments);
        var writer: horos.data.wire.Writer = .{ .output = arguments };
        try writer.bytes(payload);
        if (kind == 1) try writer.bytes(payload);
        for ([_]bool{ false, true }) |checkpoint_mode| {
            var budget: @import("kosmos").AllocationBudget = .{
                .parent = testing.allocator,
                .limit = 32 << 20,
            };
            var resident = try Resident.start(
                budget.allocator(),
                &prepared,
                arguments[0..writer.position],
            );
            defer releaseResident(&resident);
            const before = budget.live;
            var parked = try resident.drive(testing.allocator, .none, .{
                .quantum = if (kind == 2) 2 else 1,
                .checkpoint = checkpoint_mode,
            });
            defer parked.deinit();
            try testing.expect(parked.record == .progressed);
            const after = budget.live;
            std.debug.print(
                "bounded blob retention: kind={d}, before={d}, after={d}, checkpoint={}\n",
                .{ kind, before, after, checkpoint_mode },
            );
            if (kind == 0) {
                try testing.expect(after < payload.len / 4);
                try testing.expect(before - after > payload.len - payload.len / 4);
            } else try testing.expect(after >= payload.len);
            const checkpoint = try resident.checkpoint(testing.allocator);
            defer testing.allocator.free(checkpoint);
            var restored = try Resident.restore(testing.allocator, &prepared, checkpoint);
            defer releaseResident(&restored);
            for ([_]*Resident{ &resident, &restored }) |subject| {
                var result = try subject.drive(testing.allocator, .none, .{});
                defer result.deinit();
                try testing.expect(result.record == .completed);
                try testing.expectEqual(@as(
                    u64,
                    if (kind == 0) 0 else payload.len,
                ), std.mem.readInt(u64, result.record.completed[0..8], .little));
            }
        }
    }
}

test "ownership: active-cut blob reclamation rolls back allocation and publication failures" {
    const image = try programBytes(blobRetentionProgram(false));
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    const payload = try testing.allocator.alloc(u8, 64 << 10);
    defer testing.allocator.free(payload);
    @memset(payload, 'y');
    const arguments = try testing.allocator.alloc(u8, payload.len + 10);
    defer testing.allocator.free(arguments);
    var writer: horos.data.wire.Writer = .{ .output = arguments };
    try writer.bytes(payload);
    var session = try Session.start(testing.allocator, &prepared, arguments[0..writer.position]);
    defer session.deinit();
    const initial = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(initial);
    try testing.expect(initial.len >= writer.position);
    for ([_]bool{ false, true }) |checkpoint_mode| {
        try residentFailureSweep(&prepared, .{ .checkpoint = initial }, .none, checkpoint_mode);
        try residentPublicationFailure(
            &prepared,
            .{ .checkpoint = initial },
            .none,
            checkpoint_mode,
        );
    }
}

fn smallSurvivorExample(
    b: *source.Builder,
    keep_original: bool,
    request_boundary: bool,
) !source.Module {
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const sequence = try b.schema(.{ .seq = integer });
    const pause = if (request_boundary) try b.effect(.{
        .identity = "retention/pause",
        .payload = unit,
        .result = unit,
    }) else 0;
    const result_schema = if (keep_original) try b.schema(.{
        .product = &.{ sequence, sequence },
    }) else sequence;
    const entry = try b.declare(
        &.{sequence},
        result_schema,
        if (request_boundary) &.{pause} else &.{},
        &.{},
    );
    const input = try b.reference(b.parameter(entry, 0));
    const kept = try b.variable(sequence);
    const take = try b.primitive(sequence, .sequence_take, &.{ input, try b.constant(u64, 1) }, 0);
    const small = try b.reference(kept);
    const result = if (keep_original) try b.primitive(
        result_schema,
        .product,
        &.{ small, input },
        0,
    ) else small;
    const returned = try b.pure(result);
    const suspended = if (request_boundary)
        try b.bind(try b.variable(unit), try b.term(.{ .perform = .{
            .effect = pause,
            .payload = try b.constant(void, {}),
        } }), returned)
    else
        try b.term(.{ .yield_then = returned });
    try b.define(entry, try b.bind(kept, try b.pure(take), suspended));
    return b.module(entry, unit);
}

test "behavior: public suspension releases large dead input backing while preserving live aliases" {
    const count = 131072;
    const input = try testing.allocator.alloc(u8, count * 8 + 10);
    defer testing.allocator.free(input);
    var writer: horos.data.wire.Writer = .{ .output = input };
    try writer.natural(count);
    for (0..count) |i| try writer.fixed(u64, i + 1);
    const backing = try testing.allocator.alloc(u8, 32 << 20);
    defer testing.allocator.free(backing);
    for ([_]bool{ false, true }) |keep_original| for ([_]bool{ false, true }) |request_boundary| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(testing.allocator, try smallSurvivorExample(
            &builder,
            keep_original,
            request_boundary,
        ));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer testing.allocator.free(image);
        var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
        defer prepared.deinit();
        var workspace = @import("kosmos").Workspace.init(backing);
        var session = try Session.start(
            workspace.allocator(),
            &prepared,
            input[0..writer.position],
        );
        defer session.deinit();
        const observed = try session.run(null);
        try testing.expect(if (request_boundary) observed == .requested else observed == .yielded);
        const retained = workspace.live_payload;
        if (!keep_original and retained >= writer.position / 4)
            std.debug.print("dead input retention: live={d}, input={d}, request={}\n", .{
                retained, writer.position, request_boundary,
            });
        if (keep_original)
            try testing.expect(retained >= writer.position)
        else
            try testing.expect(retained < writer.position / 4);
        const checkpoint = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(checkpoint);
        const after_checkpoint = workspace.live_payload;
        if (!keep_original) try testing.expect(after_checkpoint < writer.position / 4);
        const repeated = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(repeated);
        try testing.expectEqual(after_checkpoint, workspace.live_payload);
        try testing.expectEqualSlices(u8, checkpoint, repeated);
        if (!keep_original) try testing.expect(checkpoint.len < 1024);
        var restored = try Session.restoreImage(testing.allocator, image, checkpoint);
        defer restored.deinit();
        try expectSuspensionContinuation(
            &session,
            &restored,
            request_boundary,
            keep_original,
            input[0..writer.position],
        );
    };
}

test "ownership: suspension reclamation preserves exhaustive rollback and large input publication" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try smallSurvivorExample(&builder, false, true),
    );
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    for ([_]usize{ 8, 8192 }) |count| {
        var input: [65540]u8 = undefined;
        var writer: horos.data.wire.Writer = .{ .output = &input };
        try writer.natural(count);
        for (0..count) |i| try writer.fixed(u64, i + 1);
        var session = try Session.start(testing.allocator, &prepared, input[0..writer.position]);
        defer session.deinit();
        const initial = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(initial);
        try testing.expect(initial.len >= writer.position);
        var steps: u64 = 0;
        var found = false;
        for (0..128) |_| {
            var snapshot = try guestState(&session);
            defer snapshot.deinit();
            const current = snapshot.state.nodes[@intCast(snapshot.state.roots.current.?.id)];
            const block = compiled.program.blocks[@intCast(current.record.control.block)];
            if (current.activation.?.position == block.instructions.len and
                block.terminator == .perform)
            {
                found = true;
                break;
            }
            try session.step();
            steps += 1;
        }
        try testing.expect(found);
        const fixture: ResidentFixture = .{ .checkpoint = initial, .prefix_steps = steps };
        var budget: @import("kosmos").AllocationBudget = .{
            .parent = testing.allocator,
            .limit = 32 << 20,
        };
        var retained = try fixture.restore(budget.allocator(), &prepared);
        defer releaseResident(&retained);
        try testing.expect(budget.live >= writer.position);
        const compact = try retained.checkpoint(testing.allocator);
        defer testing.allocator.free(compact);
        try testing.expect(compact.len < initial.len);
        const before = budget.live;
        var reclaimed = try retained.drive(testing.allocator, .none, .{ .quantum = 1 });
        defer reclaimed.deinit();
        try testing.expect(reclaimed.record == .requested);
        if (count == 8192) try testing.expect(before - budget.live >= writer.position / 2);
        for ([_]bool{ false, true }) |with_checkpoint| {
            if (count == 8) try residentFailureSweep(&prepared, fixture, .none, with_checkpoint);
            try residentPublicationFailure(&prepared, fixture, .none, with_checkpoint);
        }
    }
}

test "behavior: retained recursive tail fixture preserves transactional rollback" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try @import("retained_loop_bench.zig").build(&builder, 3),
    );
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var session = try Session.start(testing.allocator, &prepared, &.{});
    defer session.deinit();
    const before = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(before);
    var transaction = try session.begin();
    const outcome = try session.run(null);
    try testing.expect(outcome == .completed);
    try testing.expectEqual(@as(u64, 8), std.mem.readInt(
        u64,
        (try session.bytes(&outcome.completed))[0..8],
        .little,
    ));
    transaction.rollback(&session);
    const unchanged = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(unchanged);
    try testing.expectEqualSlices(u8, before, unchanged);
    const retried = try session.run(null);
    try testing.expect(retried == .completed);
    try testing.expectEqual(@as(u64, 8), std.mem.readInt(
        u64,
        (try session.bytes(&retried.completed))[0..8],
        .little,
    ));
}

test "behavior: handler return functions distinguish body value from state" {
    for (0..3) |mode| {
        var b = source.Builder.init(testing.allocator);
        defer b.deinit();
        const module = try source.examples.installations(&b, 1);
        const handler = b.handlers.items[0];
        const clause_body = b.functions.items[@intCast(handler.clauses[0].function)].body.?;
        b.terms.items[@intCast(clause_body)].resume_value.argument = try b.constant(u64, 7);
        const returned = handler.return_function;
        if (mode == 1) {
            b.functions.items[@intCast(returned)].body = try b.pure(try b.constant(u64, 99));
        } else if (mode == 2) {
            b.functions.items[@intCast(returned)].body = try b.pure(
                try b.reference(b.parameter(returned, 0)),
            );
        }
        var compiled = try source.lower(testing.allocator, b.module(module.entry, module.failure));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer testing.allocator.free(image);
        var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
        defer prepared.deinit();
        var session = try Session.start(testing.allocator, &prepared, &.{});
        defer session.deinit();
        const result = try session.run(null);
        try testing.expect(result == .completed);
        try testing.expectEqual(([_]u64{ 7, 99, 1 })[mode], std.mem.readInt(
            u64,
            (try session.bytes(&result.completed))[0..8],
            .little,
        ));
    }
}

test "behavior: closed handler bodies preserve escaping values and bounded-step checkpoints" {
    for (0..6) |mode| {
        var b = source.Builder.init(testing.allocator);
        defer b.deinit();
        var compiled = try source.lower(
            testing.allocator,
            try source.examples.installations(&b, 2),
        );
        defer compiled.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var program = compiled.program;
        try configureClosedHandler(a, &program, mode);
        const image = try programBytes(program);
        defer testing.allocator.free(image);
        var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
        defer prepared.deinit();
        try expectClosedHandlerExecution(&prepared, image);
        var bounded = try Session.start(testing.allocator, &prepared, &.{});
        defer bounded.deinit();
        var stepped = try Session.start(testing.allocator, &prepared, &.{});
        defer stepped.deinit();
        _ = try bounded.run(3);
        for (0..3) |_| try stepped.step();
        const bounded_state = try bounded.checkpoint(testing.allocator);
        defer testing.allocator.free(bounded_state);
        const stepped_state = try stepped.checkpoint(testing.allocator);
        defer testing.allocator.free(stepped_state);
        try testing.expectEqualSlices(u8, stepped_state, bounded_state);
    }
}

test "behavior: a callable also used as handler state is materialized" {
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const callable = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
    } } });
    const body = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(body, try b.pure(try b.constant(u64, 42)));
    const returns = try b.declare(&.{ callable, integer }, integer, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 1))));
    const handler = try b.handler(.{
        .mode = .deep,
        .input = integer,
        .answer = integer,
        .state = &.{callable},
        .return_function = returns,
        .clauses = &.{},
    });
    const entry = try b.declare(&.{}, integer, &.{}, &.{});
    const value = try b.lambda(body, callable);
    try b.define(entry, try b.term(.{ .handle = .{
        .handler = handler,
        .body = value,
        .state = &.{value},
    } }));
    var compiled = try source.lower(testing.allocator, b.module(entry, unit));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    var saw_callable = false;
    for (0..1_000_000) |_| {
        if (session.isTerminal()) break;
        _ = try session.run(2);
        var snapshot = try guestState(&session);
        defer snapshot.deinit();
        for (snapshot.state.nodes) |node|
            if (node.record == .computation) {
                saw_callable = true;
            };
    }
    const result = try session.observe();
    try testing.expect(result == .completed);
    try testing.expectEqual(@as(u64, 42), std.mem.readInt(
        u64,
        (try session.bytes(&result.completed))[0..8],
        .little,
    ));
    try testing.expect(saw_callable);
}

test "behavior: sequence consumption keeps canonical state bounded and preserves resident retry" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try @import("sequence_fixture.zig").build(&builder),
    );
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var input: [1024]u8 = undefined;
    var writer: horos.data.wire.Writer = .{ .output = &input };
    try writer.natural(64);
    for (1..65) |value| try writer.fixed(u64, value);
    try writer.fixed(u64, 0);
    var session = try Session.start(testing.allocator, &prepared, input[0..writer.position]);
    defer session.deinit();
    const initial = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(initial);
    var steps: usize = 0;
    while (!session.isTerminal()) : (steps += 1) {
        try testing.expect(steps < 400);
        try session.step();
        var snapshot = try guestState(&session);
        defer snapshot.deinit();
        const live = snapshot.state.nodes.len;
        try testing.expect(live < 40);
    }
    const result = try session.observe();
    try testing.expect(result == .completed);
    try testing.expectEqual(@as(u64, 2080), std.mem.readInt(
        u64,
        (try session.bytes(&result.completed))[0..8],
        .little,
    ));
    var rollback = try Session.restore(testing.allocator, &prepared, initial);
    defer rollback.deinit();
    var transaction = try rollback.begin();
    _ = try rollback.run(null);
    transaction.rollback(&rollback);
    const unchanged = try rollback.checkpoint(testing.allocator);
    defer testing.allocator.free(unchanged);
    try testing.expectEqualSlices(u8, initial, unchanged);
}

test "behavior: mutual tail entry restores each changed guest function" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.recursive(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("kosmos").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var session = try Session.start(testing.allocator, &prepared, &.{ 8, 0, 0, 0, 0, 0, 0, 0 });
    defer session.deinit();
    var initial_state = try guestState(&session);
    defer initial_state.deinit();
    const control = initial_state.state.nodes[
        @intCast(initial_state.state.roots.current.?.id)
    ].record.control;
    var function = session.program.blocks[@intCast(control.block)].function;
    var changes: usize = 0;
    var steps: usize = 0;
    while (!session.isTerminal()) : (steps += 1) {
        try testing.expect(steps < 256);
        try session.step();
        if (session.isTerminal()) break;
        var snapshot = try guestState(&session);
        defer snapshot.deinit();
        const active = snapshot.state.nodes[
            @intCast(snapshot.state.roots.current.?.id)
        ].record.control;
        const next_function = session.program.blocks[@intCast(active.block)].function;
        if (next_function != function) {
            changes += 1;
            function = next_function;
            const checkpoint = try session.checkpoint(testing.allocator);
            defer testing.allocator.free(checkpoint);
            var restored = try Session.restore(testing.allocator, &prepared, checkpoint);
            defer restored.deinit();
            const result = try restored.run(null);
            try testing.expect(result == .completed);
            try testing.expectEqualSlices(u8, &.{1}, try restored.bytes(&result.completed));
        }
    }
    try testing.expectEqual(@as(usize, 9), changes);
    const result = try session.observe();
    try testing.expect(result == .completed);
    try testing.expectEqualSlices(u8, &.{1}, try session.bytes(&result.completed));
}

test "behavior: handler returns preserve the caller results across every guest transition" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(
        testing.allocator,
        try source.examples.installations(&builder, 8),
    );
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    var initial_state = try guestState(&session);
    defer initial_state.deinit();
    const caller = initial_state.state.nodes[
        @intCast(initial_state.state.roots.current.?.id)
    ].record.control;
    const function = session.program.blocks[@intCast(caller.block)].function;
    var returns: usize = 0;
    var was_caller = true;
    for (0..1_000_000) |_| {
        if (session.isTerminal()) break;
        try testing.expect(session.transitions < 256);
        try session.step();
        if (session.isTerminal()) break;
        var snapshot = try guestState(&session);
        defer snapshot.deinit();
        const current = snapshot.state.nodes[
            @intCast(snapshot.state.roots.current.?.id)
        ].record.control;
        const is_caller = session.program.blocks[@intCast(current.block)].function == function;
        if (is_caller) {
            if (!was_caller) returns += 1;
        }
        was_caller = is_caller;
    }
    try testing.expectEqual(@as(usize, 8), returns);
    const result = try session.observe();
    try testing.expect(result == .completed);
    try testing.expectEqual(@as(u64, 36), std.mem.readInt(
        u64,
        (try session.bytes(&result.completed))[0..8],
        .little,
    ));
}

fn guestState(session: *Session) !horos.data.state_image.Owned {
    const bytes = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(bytes);
    return horos.data.state_image.decodeGraph(testing.allocator, bytes);
}

fn roundTrip(session: *Session) !void {
    var prepared = try retainedPreparation(session);
    defer prepared.deinit();
    const state = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(state);
    const restored = try Session.restore(session.allocator, &prepared, state);
    session.deinit();
    session.* = restored;
}

const retainedTemplateProgram: horos.data.activation.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 2 },
    .schemas = &.{
        .u64,                                  .boolean, .unit,
        .{ .internal = .{ .capability = 0 } },
        .{ .internal = .{ .resumption = .{
            .effect = 0,
            .input = 1,
            .answer = 0,
            .capture_bound = &.{0},
            .handled = &.{0},
            .mode = .deep,
            .use = .multi,
        } } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{3},
            .result = 0,
            .effects = &.{0},
        } } },
    },
    .constants = &.{
        .{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 2, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 1, .bytes = &.{0} },
        .{ .schema = 1, .bytes = &.{1} },
        .{ .schema = 2, .bytes = &.{} },
    },
    .effects = &.{.{
        .identity = "stable/loop",
        .payload = 2,
        .result = 1,
        .control_use = .multi,
        .external = false,
    }},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{ 5, 0 } }, .result = 0 },
        .{ .entry = 2, .inputs = &.{0}, .layout = .{
            .slots = &.{ 3, 0, 0, 2, 1, 0, 0, 0, 1, 0 },
        }, .result = 0, .effects = &.{0} },
        .{ .entry = 5, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 6, .inputs = &.{ 0, 1 }, .layout = .{
            .slots = &.{ 2, 4, 1, 0, 1, 0, 0 },
        }, .result = 0 },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{.{
            .destination = 0,
            .opcode = .computation,
        }}, .terminator = .{
            .handle = .{
                .handler = 0,
                .body = 0,
                .arguments = &.{},
                .state = &.{},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{
                        .destination = 1,
                        .source = .returned,
                    }},
                },
            },
        } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{ .function = 1, .instructions = &.{
            .{ .destination = 1, .opcode = .constant, .immediate = 0 },
            .{ .destination = 2, .opcode = .constant, .immediate = 1 },
            .{ .destination = 3, .opcode = .constant, .immediate = 5 },
            .{ .destination = 9, .opcode = .constant, .immediate = 2 },
        }, .terminator = .{
            .perform = .{
                .effect = 0,
                .capability = 0,
                .payload = 3,
                .next = .{
                    .block = 3,
                    .assignments = &.{.{
                        .destination = 4,
                        .source = .returned,
                    }},
                },
            },
        } },
        .{ .function = 1, .instructions = &.{
            .{ .destination = 5, .opcode = .constant, .immediate = 0 },
            .{
                .destination = 6,
                .opcode = .integer_add,
                .operands = &.{ 1, 5 },
                .failures = &.{.{
                    .kind = .arithmetic_overflow,
                    .value = 5,
                }},
            },
            .{
                .destination = 7,
                .opcode = .integer_sub,
                .operands = &.{ 2, 5 },
                .failures = &.{.{
                    .kind = .arithmetic_overflow,
                    .value = 5,
                }},
            },
            .{ .destination = 8, .opcode = .equal, .operands = &.{ 7, 9 } },
        }, .terminator = .{ .branch = .{
            .condition = 8,
            .when_true = .{ .block = 4, .assignments = &.{
                .{ .destination = 1, .source = .{ .slot = 6 } },
                .{ .destination = 2, .source = .{ .slot = 7 } },
            } },
            .when_false = .{ .block = 3, .assignments = &.{
                .{ .destination = 1, .source = .{ .slot = 6 } },
                .{ .destination = 2, .source = .{ .slot = 7 } },
            } },
        } } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 3, .instructions = &.{.{
            .destination = 2,
            .opcode = .constant,
            .immediate = 4,
        }}, .terminator = .{
            .resume_value = .{
                .resumption = 1,
                .argument = 2,
                .next = .{
                    .block = 7,
                    .assignments = &.{.{
                        .destination = 3,
                        .source = .returned,
                    }},
                },
            },
        } },
        .{ .function = 3, .instructions = &.{.{
            .destination = 4,
            .opcode = .constant,
            .immediate = 3,
        }}, .terminator = .{
            .resume_value = .{
                .resumption = 1,
                .argument = 4,
                .next = .{
                    .block = 8,
                    .assignments = &.{.{
                        .destination = 5,
                        .source = .returned,
                    }},
                },
            },
        } },
        .{
            .function = 3,
            .instructions = &.{
                .{
                    .destination = 6,
                    .opcode = .integer_add,
                    .operands = &.{ 3, 5 },
                    .failures = &.{.{
                        .kind = .arithmetic_overflow,
                        .value = 5,
                    }},
                },
            },
            .terminator = .{ .return_value = 6 },
        },
    },
    .handlers = &.{
        .{
            .mode = .deep,
            .input = 0,
            .answer = 0,
            .return_function = 2,
            .clauses = &.{.{
                .effect = 0,
                .function = 3,
                .resumption = 4,
            }},
        },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 5 }},
};

const ResidentJob = struct {
    prepared: @import("kosmos").Prepared,
    allocator: std.mem.Allocator,
    ready: *std.atomic.Value(usize),
    start: *std.atomic.Value(bool),
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        _ = self.ready.fetchAdd(1, .release);
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint(); // tiger: event-loop
        self.work() catch |err| {
            self.failure = err;
        };
    }
    fn work(self: *@This()) !void {
        defer self.prepared.deinit();
        for (0..32) |_| {
            var resident = try Resident.start(self.allocator, &self.prepared, &.{});
            defer releaseResident(&resident);
            var result = try resident.drive(self.allocator, .none, .{});
            defer result.deinit();
            if (result.record != .completed or !std.mem.eql(
                u8,
                result.record.completed,
                &.{ 1, 0, 0, 0, 0, 0, 0, 0 },
            ))
                return error.UnexpectedResult;
            try resident.close();
        }
        var terminal = try Resident.start(self.allocator, &self.prepared, &.{});
        defer releaseResident(&terminal);
        var result = try terminal.drive(self.allocator, .none, .{});
        defer result.deinit();
        if (result.record != .completed) return error.UnexpectedResult;
        self.prepared.deinit();
        try terminal.close();
    }
};

fn expectLexicalCapture(builder: *source.Builder, original: source.Module) !void {
    const inner = &builder.functions.items[1];
    inner.body = try builder.term(.{ .yield_then = inner.body.? });
    var yielding = try source.lower(
        testing.allocator,
        builder.module(original.entry, original.failure),
    );
    defer yielding.deinit();
    var paused = try initFromImage(
        testing.allocator,
        yielding.program,
        &.{ 40, 0, 0, 0, 0, 0, 0, 0 },
    );
    defer paused.deinit();
    try testing.expect(try paused.run(null) == .yielded);
    const checkpoint = try paused.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    const image = try programBytes(yielding.program);
    defer testing.allocator.free(image);
    var restored = try Session.restoreImage(testing.allocator, image, checkpoint);
    defer restored.deinit();
    try restored.resumeYield();
    const completed = try restored.run(null);
    try testing.expect(completed == .completed);
    try testing.expectEqualSlices(
        u8,
        &.{ 42, 0, 0, 0, 0, 0, 0, 0 },
        try restored.bytes(&completed.completed),
    );
}

fn expectResidentTransactionCopies(
    prepared: *const @import("kosmos").Prepared,
    state: []const u8,
) !void {
    var engine_storage = try Session.restore(
        testing.allocator,
        prepared,
        state,
    );
    defer engine_storage.deinit();
    const engine = &engine_storage;
    const copies = engine.driver.outer.frames.slots.statistics.value_copies;
    const custody_copies = engine.driver.outer.frames.custody.nodes.statistics.value_copies;
    {
        var transaction = try engine.begin();
        defer transaction.rollback(engine);
        try testing.expectEqual(copies, engine.driver.outer.frames.slots.statistics.value_copies);
        try testing.expectEqual(
            custody_copies,
            engine.driver.outer.frames.custody.nodes.statistics.value_copies,
        );
    }
}

fn expectInvocationObservation(
    subject: *Session,
    result: SessionObservation,
    expected: []const u8,
    record: horos.data.invocation.Outcome,
) !void {
    switch (result) {
        .progressed => try testing.expectEqualSlices(u8, expected, record.progressed.?),
        .yielded => try testing.expectEqualSlices(u8, expected, record.yielded.?),
        .requested => {
            try testing.expectEqualSlices(u8, expected, record.requested.state.?);
            var pending = try subject.pendingRequest(testing.allocator);
            defer pending.deinit();
            var decoded = try horos.data.invocation.decode(
                horos.data.invocation.Request,
                testing.allocator,
                record.requested.request,
            );
            defer decoded.deinit();
            try testing.expectEqualDeep(pending.request, decoded.value);
        },
        .completed => |value| try testing.expectEqualSlices(
            u8,
            try subject.bytes(&value),
            record.completed,
        ),
        .failed => |value| {
            try testing.expectEqualSlices(u8, try subject.bytes(&value), record.failed.value);
            try testing.expectEqualDeep(
                (try subject.terminalExit()).cancellation,
                record.failed.cancellation,
            );
            try expectCleanupFailures(subject, record.failed.cleanup_failures);
        },
        .cancelled => |reason| {
            try testing.expectEqualDeep(reason, record.cancelled.reason);
            try expectCleanupFailures(subject, record.cancelled.cleanup_failures);
        },
    }
}

const SessionObservation = @typeInfo(
    @typeInfo(@TypeOf(Session.observe)).@"fn".return_type.?,
).error_union.payload;

fn rejectCorruptBindings(
    image: []const u8,
    forged: horos.data.process_state.State,
    node: *horos.data.process_state.Node,
    original: horos.data.process_state.Node,
) !void {
    const bindings = try testing.allocator.dupe(
        horos.data.process_state.Binding,
        original.activation.?.bindings,
    );
    defer testing.allocator.free(bindings);
    node.activation.?.bindings = bindings;
    bindings[0].slot = std.math.maxInt(u64);
    node.activation.?.bindings = bindings[0..1];
    node.activation.?.owners = &.{};
    if (bindings[0].value.body == .owned) node.activation.?.owners = &.{.{
        .scope = node.activation.?.scope,
        .slot = std.math.maxInt(u64),
    }};
    try rejectCheckpoint(image, forged);
    node.* = original;
    node.activation.?.bindings = &.{};
    node.activation.?.owners = &.{};
    try rejectCheckpoint(image, forged);
    node.* = original;
}

fn expectSuspensionContinuation(
    session: *Session,
    restored: *Session,
    request_boundary: bool,
    keep_original: bool,
    input: []const u8,
) !void {
    for ([_]*Session{ session, restored }) |subject| {
        if (request_boundary) {
            var pending = try subject.pendingRequest(testing.allocator);
            defer pending.deinit();
            const protocol = horos.data.invocation;
            const reply = try protocol.encodeOwned(protocol.Result, testing.allocator, .{
                .request_identity = pending.request.request_identity,
                .value = &.{},
            });
            defer testing.allocator.free(reply);
            try subject.answer(reply);
        } else try subject.resumeYield();
        const result = try subject.run(null);
        try testing.expect(result == .completed);
        const bytes = try subject.bytes(&result.completed);
        const expected = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 0, 0 };
        try testing.expectEqualSlices(u8, &expected, bytes[0..expected.len]);
        if (keep_original) try testing.expectEqualSlices(
            u8,
            input,
            bytes[expected.len..],
        ) else try testing.expectEqual(expected.len, bytes.len);
    }
}

fn expectClonePublicationFailure(
    session: *Session,
    prepared: *const @import("kosmos").Prepared,
) !void {
    var found = false;
    for (0..256) |_| {
        var snapshot = try guestState(session);
        defer snapshot.deinit();
        const node = snapshot.state.nodes[@intCast(snapshot.state.roots.current.?.id)];
        const block = session.program.blocks[@intCast(node.record.control.block)];
        const position = node.activation.?.position;
        if (position < block.instructions.len and
            block.instructions[@intCast(position)].opcode == .clone_resumption)
        {
            const before_clone = try session.checkpoint(testing.allocator);
            defer testing.allocator.free(before_clone);
            for ([_]bool{ false, true }) |with_checkpoint| try residentPublicationFailure(
                prepared,
                .{ .checkpoint = before_clone },
                .none,
                with_checkpoint,
            );
            found = true;
            break;
        }
        try session.step();
    }
    try testing.expect(found);
}

fn expectResidentOutputFailures(resident: *Resident, before: []const u8) !void {
    var tiny = [_]u8{0xa5};
    try testing.expectError(error.Capacity, resident.driveInto(
        .none,
        .{ .quantum = 1, .checkpoint = true },
        &tiny,
    ));
    try testing.expectEqual(0xa5, tiny[0]);
    try expectResidentCheckpoint(resident, before);
    var empty: [0]u8 = .{};
    var output = std.heap.FixedBufferAllocator.init(&empty);
    try testing.expectError(error.OutOfMemory, resident.driveEncoded(
        output.allocator(),
        .none,
        .{ .quantum = 1, .checkpoint = true },
    ));
    try expectResidentCheckpoint(resident, before);
    try testing.expectError(error.OutOfMemory, resident.drive(
        output.allocator(),
        .none,
        .{ .quantum = 1, .checkpoint = true },
    ));
    try expectResidentCheckpoint(resident, before);
}

fn expectFreshReplyConsumption(image: []const u8, state: []const u8, identity: [32]u8) !void {
    const protocol = horos.data.invocation;
    const fresh = @import("kosmos").invocation;
    const response = try protocol.encodeOwned(protocol.Result, testing.allocator, .{
        .request_identity = identity,
        .value = &.{},
    });
    defer testing.allocator.free(response);
    var zero = try fresh.invoke(testing.allocator, .{
        .image = image,
        .instance = .{ .state = state },
        .control = .{ .reply = response },
        .quantum = 0,
    });
    defer zero.deinit();
    try testing.expect(zero.record == .progressed);
    try testing.expectError(error.InvalidState, fresh.invoke(testing.allocator, .{
        .image = image,
        .instance = .{ .state = zero.record.progressed.? },
        .control = .{ .reply = response },
    }));
    var completed = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{
        .state = zero.record.progressed.?,
    } });
    defer completed.deinit();
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0, 0, 0, 0 }, completed.record.completed);
    const command = try protocol.encodeOwned(protocol.Input, testing.allocator, .{
        .image = image,
        .instance = .{ .state = state },
        .control = .{ .reply = response },
    });
    defer testing.allocator.free(command);
    const original = try testing.allocator.dupe(u8, command);
    defer testing.allocator.free(original);
    try @import("allocation_testing.zig").check(testing.allocator, invocationFailure, .{command});
    try testing.expectEqualSlices(u8, original, command);
    var output = @as([32]u8, @splat(0xa5));
    try testing.expectError(error.Capacity, fresh.invokeInto(
        testing.allocator,
        command,
        output[0..1],
    ));
    for (output) |byte| try testing.expectEqual(0xa5, byte);
    try testing.expectEqualSlices(u8, original, command);
}

fn escapedPackageFinish(
    b: *source.Builder,
    answer: u64,
    integer: u64,
    package: u64,
    token: u64,
) !u64 {
    const finish = try b.declare(&.{answer}, integer, &.{}, &.{});
    const ordinary = try b.variable(integer);
    const suspended = try b.variable(package);
    const k = try b.variable(token);
    const resumed = try b.variable(answer);
    const again = try b.term(.{ .call = .{
        .function = finish,
        .arguments = &.{try b.reference(resumed)},
    } });
    const resume_value = try b.term(.{ .resume_value = .{
        .resumption = try b.reference(k),
        .argument = try b.constant(u64, 42),
    } });
    const recover = try b.bind(k, try b.pure(try b.primitive(
        token,
        .unpack,
        &.{try b.reference(suspended)},
        0,
    )), try b.bind(resumed, resume_value, again));
    try b.define(finish, try b.term(.{ .match_sum = .{
        .value = try b.reference(b.parameter(finish, 0)),
        .cases = &.{
            .{ .variable = ordinary, .body = try b.pure(try b.reference(ordinary)) },
            .{ .variable = suspended, .body = recover },
        },
    } }));
    return finish;
}

fn escapedPackageExample(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const effect = try b.effect(.{
        .identity = "stable/escape",
        .payload = unit,
        .result = integer,
        .external = false,
    });
    const cap = try b.schema(.{ .internal = .{ .capability = effect } });
    const token = try b.reserveSchema();
    const package = try b.schema(.{ .internal = .{ .suspension_package = token } });
    const answer = try b.schema(.{ .sum = &.{ integer, package } });
    try b.defineSchema(token, .{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = integer,
        .answer = answer,
        .handled = &.{effect},
        .mode = .deep,
        .use = .linear,
    } } });
    const returns = try b.declare(&.{integer}, answer, &.{}, &.{});
    try b.define(returns, try b.pure(try b.primitive(answer, .variant, &.{
        try b.reference(b.parameter(returns, 0)),
    }, 0)));
    const clause = try b.declare(&.{ unit, token }, answer, &.{}, &.{});
    const packaged = try b.primitive(package, .package, &.{
        try b.reference(b.parameter(clause, 1)),
    }, 0);
    try b.define(clause, try b.pure(try b.primitive(answer, .variant, &.{packaged}, 1)));
    const handler = try b.handler(
        .{
            .mode = .deep,
            .input = integer,
            .answer = answer,
            .return_function = returns,
            .clauses = &.{.{
                .effect = effect,
                .function = clause,
                .resumption = token,
            }},
        },
    );
    const body = try b.declare(&.{cap}, integer, &.{effect}, &.{});
    try b.define(body, try b.term(.{ .perform = .{
        .effect = effect,
        .capability = try b.reference(b.parameter(body, 0)),
        .payload = try b.constant(void, {}),
    } }));
    const finish = try escapedPackageFinish(b, answer, integer, package, token);
    const main = try b.declare(&.{}, integer, &.{}, &.{});
    const result = try b.variable(answer);
    const signature = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = integer,
        .effects = &.{effect},
    } } });
    const handled = try b.term(.{ .handle = .{
        .handler = handler,
        .body = try b.lambda(body, signature),
    } });
    try b.define(main, try b.bind(result, handled, try b.term(.{ .call = .{
        .function = finish,
        .arguments = &.{try b.reference(result)},
    } })));
    return b.module(main, unit);
}

fn configureClosedHandler(
    a: std.mem.Allocator,
    program: *horos.data.activation.Program,
    mode: usize,
) !void {
    const ir = horos.data.activation;
    const blocks = try a.dupe(ir.Block, program.blocks);
    program.blocks = blocks;
    const entry = program.functions[@intCast(program.roots.entry)].entry;
    try testing.expect(blocks[@intCast(entry)].terminator == .handle);
    const first = &blocks[@intCast(entry)].terminator.handle;
    const following = first.next.block;
    try testing.expect(blocks[@intCast(following)].terminator == .handle);
    const second = &blocks[@intCast(following)].terminator.handle;
    if (mode == 1) {
        for ([_]u64{ entry, following }) |id| {
            const block = &blocks[@intCast(id)];
            const instructions = try a.alloc(ir.Instruction, block.instructions.len + 1);
            @memcpy(instructions[0..block.instructions.len], block.instructions);
            const body = block.terminator.handle.body;
            instructions[instructions.len - 1] = .{
                .destination = body,
                .opcode = .move,
                .operands = try a.dupe(u64, &.{body}),
            };
            block.instructions = instructions;
        }
    } else if (mode == 2) {
        second.body = first.body;
    } else if (mode == 3 or mode == 5) {
        const functions = try a.dupe(ir.Function, program.functions);
        program.functions = functions;
        const function = &functions[@intCast(program.roots.entry)];
        const old = function.layout.slots;
        const layout = try a.alloc(u64, old.len + 1);
        @memcpy(layout[0..old.len], old);
        layout[old.len] = old[@intCast(first.body)];
        function.layout.slots = layout;
        const assignments = try a.alloc(ir.Assignment, first.next.assignments.len + 1);
        @memcpy(assignments[0..first.next.assignments.len], first.next.assignments);
        assignments[assignments.len - 1] = .{
            .destination = old.len,
            .source = .{ .slot = first.body },
        };
        first.next.assignments = assignments;
        if (mode == 3) second.body = old.len;
    } else if (mode == 4) {
        const body_schema = program.functions[
            @intCast(program.roots.entry)
        ].layout.slots[
            @intCast(first.body)
        ];
        const schemas = try a.dupe(horos.data.program.Schema, program.schemas);
        schemas[@intCast(body_schema)].internal.computation.use = .linear;
        program.schemas = schemas;
        const captures = try a.dupe(horos.data.program.Capture, program.scopes.captures);
        for (program.constructors) |constructor| if (constructor.schema == body_schema) {
            captures[@intCast(constructor.capture)].use = .linear;
        };
        program.scopes.captures = captures;
    }
}

fn expectClosedHandlerExecution(
    prepared: *const @import("kosmos").Prepared,
    image: []const u8,
) !void {
    var session = try Session.start(testing.allocator, prepared, &.{});
    defer session.deinit();
    var strict_stats: std.meta.Child(
        @typeInfo(@FieldType(Session, "statistics")).optional.child,
    ) = .{};
    session.setStatistics(&strict_stats);
    var saw_callable = false;
    for (0..1_000_000) |_| {
        if (session.isTerminal()) break;
        try session.step();
        var snapshot = try guestState(&session);
        defer snapshot.deinit();
        for (snapshot.state.nodes) |node|
            if (node.record == .computation) {
                saw_callable = true;
            };
        const checkpoint = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(checkpoint);
        var restored = try Session.restoreImage(testing.allocator, image, checkpoint);
        defer restored.deinit();
        const again = try restored.checkpoint(testing.allocator);
        defer testing.allocator.free(again);
        try testing.expectEqualSlices(u8, checkpoint, again);
    }
    const result = try session.observe();
    try testing.expect(result == .completed);
    try testing.expectEqual(@as(u64, 3), std.mem.readInt(
        u64,
        (try session.bytes(&result.completed))[0..8],
        .little,
    ));
    try testing.expect(saw_callable);
    var fast = try Session.start(testing.allocator, prepared, &.{});
    defer fast.deinit();
    var fast_stats: std.meta.Child(
        @typeInfo(@FieldType(Session, "statistics")).optional.child,
    ) = .{};
    fast.setStatistics(&fast_stats);
    const fast_result = try fast.run(null);
    try testing.expect(fast_result == .completed);
    try testing.expectEqual(@as(u64, 3), std.mem.readInt(
        u64,
        (try fast.bytes(&fast_result.completed))[0..8],
        .little,
    ));
    try testing.expectEqual(strict_stats.transitions, fast_stats.transitions);
}

fn insertCapturedHandler(decoded: *horos.data.state_image.Owned, extra: u64, wide: u64) !void {
    const data = horos.data;
    const g = data.graph;
    const a = decoded.arena.allocator();
    const count = decoded.state.nodes.len;
    const nodes = try a.alloc(data.process_state.Node, count + 2);
    @memcpy(nodes[0..count], decoded.state.nodes);
    const token = for (nodes[0..count]) |node| {
        if (node.record == .one_shot or node.record == .multi_template)
            break if (node.record == .one_shot)
                node.record.one_shot
            else
                node.record.multi_template;
    } else return error.MissingCapture;
    const saved = &nodes[@intCast(token.capture.?.id)].record.continuation;
    nodes[count] = .{
        .record = .{
            .handler = .{
                .definition = extra,
                .state = try a.dupe(
                    g.Value,
                    &.{.{
                        .schema = wide,
                        .body = .{ .scalar = @splat(0) },
                    }},
                ),
                .evidence = saved.evidence,
                .region = saved.region,
            },
        },
    };
    nodes[count + 1] = .{ .record = .{ .attachment = .{
        .handler = .{ .id = count },
        .outer = saved.evidence,
        .return_to = saved.parent,
        .region = saved.region,
    } } };
    saved.parent = .{ .id = count + 1 };
    decoded.state.nodes = nodes;
}

fn expectCapturedHandlerKinds(
    program: horos.data.activation.Program,
    state: horos.data.process_state.State,
    handler_index: usize,
    multi: bool,
) !void {
    const data = horos.data;
    const g = data.graph;
    const checked_nodes = @constCast(state.nodes);
    try data.state_admission.validateStable(
        testing.allocator,
        program,
        state,
    );
    const original = checked_nodes[handler_index];
    inline for (std.enums.values(g.NodeTag)) |tag| {
        if (comptime tag != .handler) {
            checked_nodes[handler_index].record = emptyNodeRecord(tag);
            if (data.state_admission.validateStable(
                testing.allocator,
                program,
                state,
            )) |_| {
                return error.AcceptedWrongCapturedHandlerKind;
            } else |err| try testing.expect(err != error.OutOfMemory);
            checked_nodes[handler_index] = original;
        }
    }
    const image = try programBytes(program);
    defer testing.allocator.free(image);
    const checkpoint = try data.state_image.emit(testing.allocator, state);
    defer testing.allocator.free(checkpoint);
    var restored = try Session.restoreImage(testing.allocator, image, checkpoint);
    defer restored.deinit();
    const result = try restored.run(null);
    try testing.expect(result == .completed);
    const expected: []const u8 = if (multi)
        &.{ 4, 0, 0, 0, 1, 1, 0, 1, 1 }
    else
        &.{ 67, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqualSlices(u8, expected, try restored.bytes(&result.completed));
}

const ServiceMode = enum { empty, requests, swapped, cancelled, overflow, paired };
const ServiceCounts = struct {
    commands: usize = 0,
    replies: usize = 0,
    releases: usize = 0,
    yields: usize = 0,
};
fn restoreService(session: *Session, image: []const u8) !void {
    const checkpoint = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    var resumed = try Session.restoreImage(testing.allocator, image, checkpoint);
    errdefer resumed.deinit();
    const roundtrip = try resumed.checkpoint(testing.allocator);
    defer testing.allocator.free(roundtrip);
    try testing.expectEqualSlices(u8, checkpoint, roundtrip);
    session.deinit();
    session.* = resumed;
}
fn serviceRequest(
    session: *Session,
    pending: @FieldType(SessionObservation, "requested"),
    comptime mode: ServiceMode,
    counts: *ServiceCounts,
    final: u64,
) !void {
    const identity = session.program.effects[@intCast(pending.effect)].identity;
    if (std.mem.eql(u8, identity, "example/service-command")) {
        try testing.expectEqual(counts.commands, counts.replies);
        if (mode == .empty or
            (if (mode == .paired) counts.commands == counts.releases + 1 else counts.commands == 2))
        {
            try answerWithValue(session, &.{1});
        } else {
            var request: [17]u8 = undefined;
            request[0] = 0;
            std.mem.writeInt(u64, request[1..9], counts.commands + 1, .little);
            std.mem.writeInt(
                u64,
                request[9..17],
                if (mode == .overflow and counts.commands == 1) std.math.maxInt(u64) else 1,
                .little,
            );
            counts.commands += 1;
            try answerWithValue(session, &request);
        }
    } else if (std.mem.eql(u8, identity, "example/service-reply")) {
        var expected: [16]u8 = undefined;
        std.mem.writeInt(
            u64,
            expected[0..8],
            if (mode == .swapped) (counts.replies + 1) ^ 3 else counts.replies + 1,
            .little,
        );
        std.mem.writeInt(
            u64,
            expected[8..16],
            if (mode == .paired) 0 else counts.replies,
            .little,
        );
        try testing.expectEqualSlices(
            u8,
            &expected,
            try session.bytes(&pending.payload),
        );
        counts.replies += 1;
        try answerWithValue(session, &.{});
    } else {
        try testing.expectEqualStrings("example/service-finalize", identity);
        counts.releases += 1;
        var expected: [8]u8 = undefined;
        std.mem.writeInt(u64, &expected, if (mode == .paired) 1 else final, .little);
        try testing.expectEqualSlices(
            u8,
            &expected,
            try session.bytes(&pending.payload),
        );
        try answerWithValue(session, &.{});
    }
}

fn expectDistinctRequestCaptures(
    first: horos.data.invocation.Request,
    second: horos.data.invocation.Request,
) !void {
    try testing.expectEqualDeep(
        first.binding.semantic_identity,
        second.binding.semantic_identity,
    );
    try testing.expectEqualSlices(
        u8,
        first.binding.payload,
        second.binding.payload,
    );
    try testing.expect(!std.mem.eql(
        u8,
        &first.request_identity,
        &second.request_identity,
    ));
}

fn residentTransitionAllocations(
    prepared: *const @import("kosmos").Prepared,
    fixture: ResidentFixture,
    control: horos.data.invocation.Control,
    checkpoint_mode: bool,
) !usize {
    var counting = testing.FailingAllocator.init(testing.allocator, .{
        .resize_fail_index = 0,
    });
    var resident = try fixture.restore(counting.allocator(), prepared);
    defer releaseResident(&resident);
    var statistics: std.meta.Child(
        @typeInfo(@FieldType(Session, "statistics")).optional.child,
    ) = .{};
    try resident.setStatistics(&statistics);
    _ = try resident.diagnostics();
    const allocation_start = counting.alloc_index;
    counting.resize_fail_index = counting.resize_index;
    var output = try resident.drive(counting.allocator(), control, .{
        .quantum = 1,
        .checkpoint = checkpoint_mode,
    });
    defer output.deinit();
    return counting.alloc_index - allocation_start;
}
