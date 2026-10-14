const std = @import("std");
const horos = @import("horos");
const source = horos.source;
const Session = @import("stable_runtime").Session;
const testing = std.testing;
const Resident = @import("stable_runtime").Resident;

test {
    // Dependency-module tests are not collected by this root test artifact.
    _ = @import("source_regressions.zig");
    _ = @import("resident_binding.zig");
}

test "encoded cursors export canonical immutable checkpoints and restore as ordinary values" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const sequence = try builder.schema(.{ .seq = integer });
    const pair = try builder.schema(.{ .product = &.{ integer, sequence } });
    const optional = try builder.schema(.{ .sum = &.{ unit, pair } });
    const entry = try builder.declare(&.{sequence}, sequence, &.{}, &.{});
    const popped = try builder.primitive(optional, .sequence_pop, &.{try builder.reference(builder.parameter(entry, 0))}, 0);
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
            .{ .variable = empty, .body = try builder.pure(try builder.primitive(sequence, .sequence, &.{}, 0)) },
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
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    for ([_]bool{ false, true }) |checkpoint_mode|
        try residentFailureSweep(&prepared, initial, .none, checkpoint_mode);
    try testing.expect(try drive(&session, null) == .yielded);
    try testing.expect(session.store.encoded_sequences.count() != 0);
    const nodes = session.store.nodes.items.len;
    const blobs = session.store.blobs.items.len;
    const state = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(state);
    const again = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, state, again);
    try testing.expectEqual(nodes, session.store.nodes.items.len);
    try testing.expectEqual(blobs, session.store.blobs.items.len);
    var restored = try Session.restoreImage(testing.allocator, image, state);
    defer restored.deinit();
    try testing.expectEqual(0, restored.store.encoded_sequences.count());
    try restored.resumeYield();
    const result = try drive(&restored, null);
    try testing.expect(result == .completed);
    var expected: [505]u8 = undefined;
    expected[0] = 63;
    @memcpy(expected[1..], input[9..]);
    try testing.expectEqualSlices(u8, &expected, try restored.bytes(&result.completed));
}

test "owned FIFO package queues preserve scheduling through instruction checkpoints" {
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
        try testing.expectEqualSlices(u8, &.{ 30, 0, 0, 0, 0, 0, 0, 0, 4, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0 }, try session.bytes(&outcome.completed));
        return;
    }
    return error.TestUnexpectedResult;
}

test "fast projections still reject malformed unselected input payloads" {
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
        const projected = try builder.primitive(integer, if (variant) .variant_tag else .field, &.{try builder.reference(builder.parameter(entry, 0))}, 0);
        try builder.define(entry, try builder.pure(projected));
        var compiled = try source.lower(testing.allocator, builder.module(entry, unit));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer testing.allocator.free(image);
        const truncated: []const u8 = if (variant) &.{ 0, 16 } else &.{ 42, 0, 0, 0, 0, 0, 0, 0, 16 };
        try testing.expectError(error.Truncated, Session.initImage(testing.allocator, image, truncated));
        if (mode == 2) try testing.expectError(error.InvalidUtf8, Session.initImage(testing.allocator, image, &.{ 0, 1, 0xff }));
        const valid: []const u8 = if (variant) &.{ 0, 0 } else &.{ 42, 0, 0, 0, 0, 0, 0, 0, 0 };
        var session = try Session.initImage(testing.allocator, image, valid);
        defer session.deinit();
        const result = try session.run(null);
        try testing.expect(result == .completed);
        try testing.expectEqual(@as(u8, if (variant) 0 else 42), result.completed.body.scalar[0]);
    }
}

test "higher-order scoped bodies retain definition and use capabilities with cleanup" {
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
        try session.store.collectWith(session.roots, &session.frames);
        var retained = false;
        for (session.store.nodes.items, session.store.alive.items) |node, live| {
            if (!live or node != .computation) continue;
            const captures = (try session.store.get(node.computation.environment)).environment.values;
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
        try testing.expectEqualStrings("retained-scope/release", restored.program.effects[@intCast(cleanup.requested.effect)].identity);
        try testing.expectEqual(77, cleanup.requested.payload.body.scalar[0]);
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
            try testing.expectEqualSlices(u8, &.{ 0x61, 4, 0, 0, 0, 0, 0, 0, 99, 0, 0, 0, 0, 0, 0, 0 }, try finished.bytes(&result.completed));
        }
    }
}

// Data-level mutation fixtures need declarations that a closed compiler can prune.
// No imports are present; programBytes/initFromImage still perform closed admission.
fn compileDeclarations(module: source.Module) !source.Compiled {
    return (try source.component.compile(testing.allocator, module, .{ .exports = &.{} })).construction;
}

test "retained scoped interaction agrees at every quantum with general resumptions" {
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
                    try testing.expectEqualStrings("retained-scope/release", session.program.effects[@intCast(request.effect)].identity);
                    try testing.expectEqual(77, request.payload.body.scalar[0]);
                    releases += 1;
                    try answerWithValue(&session, &.{});
                },
                .completed => |value| {
                    var result = value;
                    try testing.expectEqualSlices(u8, &.{ 0x61, 4, 0, 0, 0, 0, 0, 0, 99, 0, 0, 0, 0, 0, 0, 0 }, try session.bytes(&result));
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

test "branching tail handlers create no resumption and survive every instruction checkpoint" {
    var nodes: [2]u64 = undefined;
    for ([_]bool{ false, true }, 0..) |selected, variant| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const module = try source.examples.branchingTail(&builder);
        var compiled = if (selected)
            try source.lower(testing.allocator, module)
        else
            try compileDeclarations(module);
        defer compiled.deinit();
        const clause = compiled.program.handlers[0].clauses[0];
        const clauses = try testing.allocator.dupe(horos.data.activation.Clause, compiled.program.handlers[0].clauses);
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
            var stats: std.meta.Child(@typeInfo(@FieldType(Session, "statistics")).optional.child) = .{};
            session.statistics = &stats;
            session.store.statistics = &stats.storage;
            const result = try session.run(null);
            try testing.expect(result == .completed);
            try testing.expectEqual(@as(u64, if (input == 1) 60 else 100), std.mem.readInt(u64, result.completed.body.scalar[0..8], .little));
            try testing.expectEqual(@as(u64, if (selected) 0 else 1), stats.one_shot_captures);
            try testing.expectEqual(@as(u64, if (selected) 1 else 0), stats.direct_clauses);
            nodes[variant] = stats.storage.added_nodes;
            try checkpointTail(image, input, clause.function, selected);
        }
    }
    std.debug.print("branching-tail store nodes: general={d} tail={d}\n", .{ nodes[0], nodes[1] });
    try testing.expect(nodes[1] < nodes[0]);
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
        if (session.roots.current) |current| {
            const control = (try session.store.get(current)).control;
            if (session.program.blocks[@intCast(control.block)].function == function) saw_tail = true;
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
    try testing.expectEqual(@as(u64, if (input == 1) 60 else 100), std.mem.readInt(u64, outcome.completed.body.scalar[0..8], .little));
}

test "tail clause checkpoints retain body cleanup on cancellation" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.branchingTailProtected(&builder));
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
            try testing.expectEqualStrings("example/tail-cleanup", session.program.effects[@intCast(outcome.requested.effect)].identity);
            try answerWithValue(&session, &.{});
            const completed = try session.run(null);
            try testing.expect(completed == .completed);
            try testing.expectEqual(60, completed.completed.body.scalar[0]);
            break;
        }
        try testing.expect(outcome == .progressed);
        const current = session.roots.current.?;
        const record = try session.store.get(current);
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
        try testing.expectEqualStrings("example/tail-cleanup", cancelled.program.effects[@intCast(cleanup.requested.effect)].identity);
        try answerWithValue(&cancelled, &.{});
        try testing.expect(try cancelled.run(null) == .cancelled);
        cancellation_points += 1;
    }
    try testing.expect(cancellation_points >= 3);
    try testing.expect(session.terminal != null);
}

test "immediate lexical calls avoid closure storage and preserve checked results" {
    var nodes: [2]u64 = undefined;
    for ([_]bool{ false, true }, 0..) |immediate, index| {
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
        var compiled = try source.lower(testing.allocator, builder.module(original.entry, original.failure));
        defer compiled.deinit();
        var session = try initFromImage(testing.allocator, compiled.program, &.{ 40, 0, 0, 0, 0, 0, 0, 0 });
        defer session.deinit();
        var statistics: std.meta.Child(@typeInfo(@FieldType(Session, "statistics")).optional.child) = .{};
        session.store.statistics = &statistics.storage;
        const result = try session.run(null);
        try testing.expect(result == .completed);
        try testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, try session.bytes(&result.completed));
        nodes[index] = statistics.storage.added_nodes;
        var overflow = try initFromImage(testing.allocator, compiled.program, &(@as([8]u8, @splat(0xff))));
        defer overflow.deinit();
        const failed = try overflow.run(null);
        try testing.expect(failed == .failed);
        try testing.expectEqual(0, (try overflow.bytes(&failed.failed)).len);

        // An unfinished direct call keeps its capture through portable State.
        const inner = &builder.functions.items[1];
        inner.body = try builder.term(.{ .yield_then = inner.body.? });
        var yielding = try source.lower(testing.allocator, builder.module(original.entry, original.failure));
        defer yielding.deinit();
        var paused = try initFromImage(testing.allocator, yielding.program, &.{ 40, 0, 0, 0, 0, 0, 0, 0 });
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
        try testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, try restored.bytes(&completed.completed));
    }
    std.debug.print("immediate-call store nodes: retained={d} immediate={d}\n", .{ nodes[0], nodes[1] });
    try testing.expect(nodes[1] < nodes[0]);
}

test "stable statistics count one-shot captures and repeated multi-shot activations" {
    for ([_]bool{ false, true }) |multi| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const original = try source.examples.deep(&builder);
        if (multi) {
            for (builder.effects.items) |*effect| effect.control_use = .multi;
            for (builder.schemas.items) |*schema| {
                if (schema.* == .internal and schema.internal == .resumption) schema.internal.resumption.use = .multi;
            }
            const clause = builder.handlers.items[0].clauses[0].function;
            const body = builder.functions.items[@intCast(clause)].body.?;
            const first = builder.terms.items[@intCast(body)].bind;
            const discarded = try builder.variable(builder.variables.items[@intCast(first.variable)]);
            builder.functions.items[@intCast(clause)].body = try builder.bind(discarded, first.value, body);
        }
        var compiled = try source.lower(testing.allocator, builder.module(original.entry, original.failure));
        defer compiled.deinit();
        var session = try initFromImage(testing.allocator, compiled.program, &.{});
        defer session.deinit();
        var statistics: std.meta.Child(@typeInfo(@FieldType(Session, "statistics")).optional.child) = .{};
        session.statistics = &statistics;
        const result = try session.run(null);
        try testing.expect(result == .completed);
        try testing.expectEqualSlices(u8, &.{ 67, 0, 0, 0, 0, 0, 0, 0 }, try session.bytes(&result.completed));
        try testing.expectEqual(@as(u64, if (multi) 1 else 0), statistics.multi_templates);
        try testing.expectEqual(@as(u64, if (multi) 0 else 1), statistics.one_shot_captures);
        try testing.expectEqual(@as(u64, if (multi) 2 else 0), statistics.branch_activations);
    }
}

fn releaseResident(resident: *Resident) void {
    resident.close() catch |err| switch (err) {
        error.UnfinishedSession => {
            const bytes = resident.takeCheckpoint(testing.allocator) catch unreachable;
            testing.allocator.free(bytes); // Explicit fixture custody transfer.
        },
        error.InvalidState => {},
        else => unreachable,
    };
}

// Regression transferred from PR #60, 750f8ec74f909735c96992eb05bfe0c22904526e.
fn residentBeforeOwnedUnwind(allocator: std.mem.Allocator, prepared: *const @import("stable_runtime").Prepared) !Resident {
    var resident = try Resident.start(allocator, prepared, &.{});
    errdefer releaseResident(&resident);
    var yielded = try resident.drive(allocator, .none, .{});
    defer yielded.deinit();
    try testing.expect(yielded.record == .yielded);
    var cancelling = try resident.drive(allocator, .{ .cancel = .{ .text = "live-owned-unwind" } }, .{ .quantum = 0 });
    defer cancelling.deinit();
    return resident;
}

test "live owned unwind preserves physical ownership and retry at every allocation failure" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.ownership(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var reference = try residentBeforeOwnedUnwind(testing.allocator, &prepared);
    defer releaseResident(&reference);
    var expected = try reference.drive(testing.allocator, .none, .{ .quantum = 1 });
    defer expected.deinit();
    var index: usize = 0;
    while (true) : (index += 1) {
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
        break;
    }
}

fn residentFailureSweep(prepared: *const @import("stable_runtime").Prepared, checkpoint: []const u8, control: horos.data.invocation.Control, checkpoint_mode: bool) !void {
    var reference = try Resident.restore(testing.allocator, prepared, checkpoint);
    defer releaseResident(&reference);
    var expected = try reference.drive(testing.allocator, control, .{ .checkpoint = checkpoint_mode });
    defer expected.deinit();
    var failures: usize = 0;
    var failed_after_mutation = false;
    while (true) : (failures += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var resident = try Resident.restore(failing.allocator(), prepared, checkpoint);
        defer releaseResident(&resident);
        var statistics: std.meta.Child(@typeInfo(@FieldType(Session, "statistics")).optional.child) = .{};
        try resident.setStatistics(&statistics);
        const collection_cursors = (try resident.diagnostics()).collection_cursors;
        failing.fail_index = failing.alloc_index + failures;
        failing.resize_fail_index = failing.resize_index;
        var output = resident.drive(failing.allocator(), control, .{ .checkpoint = checkpoint_mode }) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(collection_cursors, (try resident.diagnostics()).collection_cursors);
            failed_after_mutation = failed_after_mutation or statistics.transitions != 0 or statistics.storage.added_nodes != 0 or statistics.storage.journal_nodes != 0;
            const unchanged = try resident.checkpoint(testing.allocator);
            defer testing.allocator.free(unchanged);
            try testing.expectEqualSlices(u8, checkpoint, unchanged);
            var retried = try resident.drive(testing.allocator, control, .{ .checkpoint = checkpoint_mode });
            defer retried.deinit();
            try testing.expectEqualDeep(expected.record, retried.record);
            continue;
        };
        defer output.deinit();
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try testing.expectEqualDeep(expected.record, output.record);
        try testing.expect(failures != 0 and failed_after_mutation);
        break;
    }
}

test "resident rollback preserves acquired replies, cleanup custody, and reentrant captures at every allocation failure" {
    const protocol = horos.data.invocation;
    inline for (.{ retainedInputExample, source.examples.unwind, source.examples.reentrant, source.examples.cloned }, 0..) |example, index| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(testing.allocator, try example(&builder));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer testing.allocator.free(image);
        var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
        defer prepared.deinit();
        const arguments: []const u8 = switch (index) {
            0 => &.{ 42, 0, 0, 0, 0, 0, 0, 0 },
            1 => &.{0},
            else => &.{},
        };
        var session = try Session.start(testing.allocator, &prepared, arguments);
        defer session.deinit();
        if (index == 3) {
            const initial = try session.checkpoint(testing.allocator);
            defer testing.allocator.free(initial);
            for ([_]bool{ false, true }) |with_checkpoint| try residentFailureSweep(&prepared, initial, .none, with_checkpoint);
        }
        const observation = try session.run(null);
        const checkpoint = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(checkpoint);
        if (index >= 2) {
            try testing.expect(observation == .yielded);
            for ([_]bool{ false, true }) |with_checkpoint| try residentFailureSweep(&prepared, checkpoint, .resume_yield, with_checkpoint);
        } else {
            try testing.expect(observation == .requested);
            var pending = try session.pendingRequest(testing.allocator);
            defer pending.deinit();
            const reply = try protocol.encodeOwned(protocol.Result, testing.allocator, .{ .request_identity = pending.request.request_identity, .value = &.{} });
            defer testing.allocator.free(reply);
            for ([_]bool{ false, true }) |with_checkpoint| try residentFailureSweep(&prepared, checkpoint, .{ .reply = reply }, with_checkpoint);
            if (index == 1) for ([_]bool{ false, true }) |with_checkpoint| try residentFailureSweep(&prepared, checkpoint, .{ .cancel = .{ .text = "stop" } }, with_checkpoint);
        }
    }
}

test "resident output capacity and checkpoint transfer preserve custody on failure" {
    const protocol = horos.data.invocation;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try retainedInputExample(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var resident = try Resident.start(testing.allocator, &prepared, &.{ 42, 0, 0, 0, 0, 0, 0, 0 });
    defer releaseResident(&resident);
    try testing.expectError(error.UnfinishedSession, resident.close());
    var pending = try resident.drive(testing.allocator, .none, .{ .checkpoint = true });
    defer pending.deinit();
    // The separate low-level Session API retains direct transaction access.
    var engine_storage = try Session.restore(testing.allocator, &prepared, pending.record.requested.state.?);
    defer engine_storage.deinit();
    const engine = &engine_storage;
    const copies = engine.frames.slots.statistics.value_copies;
    const custody_copies = engine.frames.custody.nodes.statistics.value_copies;
    {
        var transaction = try engine.begin();
        defer transaction.rollback(engine);
        try testing.expectEqual(copies, engine.frames.slots.statistics.value_copies);
        try testing.expectEqual(custody_copies, engine.frames.custody.nodes.statistics.value_copies);
    }
    var request = try protocol.decode(protocol.Request, testing.allocator, pending.record.requested.request);
    defer request.deinit();
    const reply = try protocol.encodeOwned(protocol.Result, testing.allocator, .{ .request_identity = request.value.request_identity, .value = &.{} });
    defer testing.allocator.free(reply);
    var output = @as([512]u8, @splat(0xa5));
    try testing.expectError(error.Capacity, resident.driveInto(.{ .reply = reply }, .{ .checkpoint = true }, output[0..1]));
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
    try testing.expectError(error.InvalidState, restored.drive(testing.allocator, .none, .{ .quantum = 0 }));
}

test "shallow resumption preserves every resident boundary after failed publication" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.shallowResumptions(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
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
            for (portable.state.nodes) |entry| {
                const node = entry.record;
                if (node != .one_shot) continue;
                const signature = compiled.program.schemas[@intCast(node.one_shot.schema)].internal.resumption;
                if (signature.mode != .shallow) continue;
                // The token already belongs to the entry State. Exercise every
                // subsequent allocation failure, not only the output buffer.
                for ([_]bool{ false, true }) |checkpoint_mode|
                    try residentFailureSweep(&prepared, before, .none, checkpoint_mode);
                swept = true;
                break;
            }
        }
        var tiny = [_]u8{0xa5};
        try testing.expectError(error.Capacity, resident.driveInto(.none, .{ .quantum = 1, .checkpoint = true }, &tiny));
        try testing.expectEqual(0xa5, tiny[0]);
        try expectResidentCheckpoint(&resident, before);
        var empty: [0]u8 = .{};
        var output = std.heap.FixedBufferAllocator.init(&empty);
        try testing.expectError(error.OutOfMemory, resident.driveEncoded(output.allocator(), .none, .{ .quantum = 1, .checkpoint = true }));
        try expectResidentCheckpoint(&resident, before);
        try testing.expectError(error.OutOfMemory, resident.drive(output.allocator(), .none, .{ .quantum = 1, .checkpoint = true }));
        try expectResidentCheckpoint(&resident, before);
        var succeeded = try resident.drive(testing.allocator, .none, .{ .quantum = 1, .checkpoint = true });
        defer succeeded.deinit();
        if (succeeded.record == .completed) {
            try testing.expect(swept);
            // Independent source expectation: four shallow value answers and
            // four shallow computation answers retain their distinct results.
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

test "independent native residents release shared preparation exactly once" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.installations(&builder, 1));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var memory: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer if (memory.deinit() != .ok) @panic("shared preparation leaked");
    const allocator = memory.allocator();
    const Job = struct {
        prepared: @import("stable_runtime").Prepared,
        allocator: std.mem.Allocator,
        ready: *std.atomic.Value(usize),
        start: *std.atomic.Value(bool),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .release);
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
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
                if (result.record != .completed or !std.mem.eql(u8, result.record.completed, &.{ 1, 0, 0, 0, 0, 0, 0, 0 }))
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
    for (0..8) |_| {
        var prepared = try @import("stable_runtime").Prepared.init(allocator, image);
        defer prepared.deinit();
        var ready: std.atomic.Value(usize) = .init(0);
        var start: std.atomic.Value(bool) = .init(false);
        var jobs: [8]Job = undefined;
        var initialized: usize = 0;
        defer for (jobs[0..initialized]) |*job| job.prepared.deinit();
        for (&jobs) |*job| {
            job.* = .{ .prepared = try prepared.clone(), .allocator = allocator, .ready = &ready, .start = &start };
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
            threads[started] = try std.Thread.spawn(.{}, Job.run, .{job});
            started += 1;
        }
        while (ready.load(.acquire) != jobs.len) std.atomic.spinLoopHint();
        start.store(true, .release);
        for (threads) |thread| thread.join();
        started = 0;
        for (jobs) |job| if (job.failure) |err| return err;
    }
}

test "resident progress defers checkpoint publication until explicitly requested" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try retainedInputExample(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
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

test "a long resident drive journals entry state rather than transition history" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.recursive(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var resident = try Resident.start(testing.allocator, &prepared, &.{ 16, 39, 0, 0, 0, 0, 0, 0 });
    defer releaseResident(&resident);
    var statistics: std.meta.Child(@typeInfo(@FieldType(Session, "statistics")).optional.child) = .{};
    try resident.setStatistics(&statistics);
    const entry_nodes = (try resident.diagnostics()).nodes;
    var result = try resident.drive(testing.allocator, .none, .{});
    defer result.deinit();
    try testing.expectEqualSlices(u8, &.{1}, result.record.completed);
    try testing.expect(statistics.transitions >= 10_000);
    try testing.expect(statistics.storage.journal_nodes <= entry_nodes);
    try testing.expect((try resident.diagnostics()).nodes <= 512);
}

test "resident gate rejects reentrant observation during allocator callbacks" {
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
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
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
    var result = try resident.drive(testing.allocator, .none, .{ .quantum = 0 });
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
    try horos.data.state_admission.validateStable(testing.allocator, subject.program, decoded.state);
    const reencoded = try horos.data.state_image.emit(testing.allocator, decoded.state);
    defer testing.allocator.free(reencoded);
    try testing.expectEqualSlices(u8, bytes, reencoded);
    const repeated = try subject.checkpoint(testing.allocator);
    defer testing.allocator.free(repeated);
    try testing.expectEqualSlices(u8, bytes, repeated);
    try testing.expectEqual(subject.program_identity, decoded.state.program_identity);
}

fn drive(subject: *Session, quantum: ?usize) !@import("stable_runtime").Observation {
    const before = try subject.checkpoint(testing.allocator);
    defer testing.allocator.free(before);
    const codec = horos.data.program_image;
    const image = try testing.allocator.alloc(u8, try codec.encodedLength(subject.program));
    defer testing.allocator.free(image);
    _ = try codec.encode(testing.allocator, subject.program, image);
    var restored = try Session.restoreImage(testing.allocator, image, before);
    defer restored.deinit();
    var fresh = try @import("stable_runtime").invocation.invoke(testing.allocator, .{
        .image = image,
        .instance = .{ .state = before },
        .quantum = quantum,
    });
    defer fresh.deinit();
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var resident = try Resident.restore(testing.allocator, &prepared, before);
    defer releaseResident(&resident);
    var committed = try resident.drive(testing.allocator, .none, .{ .quantum = quantum, .checkpoint = true });
    defer committed.deinit();
    try testing.expectEqualDeep(fresh.record, committed.record);
    @memset(image, 0xff);
    @memset(before, 0xff);
    const result = try subject.run(quantum);
    _ = try restored.run(quantum);
    const expected = try subject.checkpoint(testing.allocator);
    defer testing.allocator.free(expected);
    const actual = try restored.checkpoint(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, expected, actual);
    switch (result) {
        .progressed => try testing.expectEqualSlices(u8, expected, fresh.record.progressed.?),
        .yielded => try testing.expectEqualSlices(u8, expected, fresh.record.yielded.?),
        .requested => {
            try testing.expectEqualSlices(u8, expected, fresh.record.requested.state.?);
            var pending = try subject.pendingRequest(testing.allocator);
            defer pending.deinit();
            var decoded = try horos.data.invocation.decode(horos.data.invocation.Request, testing.allocator, fresh.record.requested.request);
            defer decoded.deinit();
            try testing.expectEqualDeep(pending.request, decoded.value);
        },
        .completed => |value| try testing.expectEqualSlices(u8, try subject.bytes(&value), fresh.record.completed),
        .failed => |value| {
            try testing.expectEqualSlices(u8, try subject.bytes(&value), fresh.record.failed.value);
            try testing.expectEqualDeep((try subject.terminalExit()).cancellation, fresh.record.failed.cancellation);
            try expectCleanupFailures(subject, fresh.record.failed.cleanup_failures);
        },
        .cancelled => |reason| {
            try testing.expectEqualDeep(reason, fresh.record.cancelled.reason);
            try expectCleanupFailures(subject, fresh.record.cancelled.cleanup_failures);
        },
    }
    try checkedCheckpoint(subject);
    return result;
}

fn expectCleanupFailures(subject: *Session, bytes: []const u8) !void {
    var reader: horos.data.wire.Reader = .{ .input = bytes };
    const failures = (try subject.terminalExit()).cleanup_failures;
    try testing.expectEqual(failures.len, try reader.count());
    for (failures) |value| try testing.expectEqualSlices(u8, try subject.bytes(&value), try reader.bytes());
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

test "failed PST3 export retains exactly the same resident instruction boundary" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.installations(&builder, 1));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    try testing.expect(try session.run(1) == .progressed);
    const before = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(before);
    try @import("allocation_testing.zig").check(testing.allocator, checkpointFailure, .{ &session, before });
    const result = try drive(&session, null);
    try testing.expect(result == .completed);
    try testing.expectEqual(1, result.completed.body.scalar[0]);
}

fn initFromImage(allocator: std.mem.Allocator, program: horos.data.activation.Program, arguments: []const u8) !Session {
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

test "prepared Programs reuse immutable code and facts across sequential Sessions" {
    const Prepared = @import("stable_runtime").Prepared;
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
        var session = try Session.start(testing.allocator, &prepared, &.{ input, 0, 0, 0, 0, 0, 0, 0 });
        defer session.deinit();
        if (shared_code) |pointer| try testing.expect(pointer == session.program.functions.ptr) else shared_code = session.program.functions.ptr;
        const base = session.flow.facts.pool.base.?;
        const nodes = base.nodeCount();
        try testing.expect(try session.run(null) == .requested);
        const checkpoint = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(checkpoint);
        var restored = try Session.restore(testing.allocator, &prepared, checkpoint);
        defer restored.deinit();
        try testing.expect(session.program.functions.ptr == restored.program.functions.ptr);
        try testing.expect(session.flow.facts.live.ptr == restored.flow.facts.live.ptr);
        try testing.expect(session.flow.facts.pool != restored.flow.facts.pool);
        try testing.expect(restored.flow.facts.pool.base.? == base);
        try answerWithValue(&session, &.{});
        try answerWithValue(&restored, &.{});
        const result = try session.run(null);
        const other = try restored.run(null);
        try testing.expectEqual(input, result.completed.body.scalar[0]);
        try testing.expectEqualDeep(result, other);
        try testing.expectEqual(nodes, base.nodeCount());
        try testing.expectEqual(retained, try prepared.storageBytes());
    }
}

test "Sessions retain preparation after all external prepared handles are released" {
    const Prepared = @import("stable_runtime").Prepared;
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
    prepared.deinit();
    clone.deinit();
    try testing.expectError(error.InvalidState, Session.start(testing.allocator, &prepared, &.{}));
    try testing.expectError(error.InvalidState, Session.restore(testing.allocator, &clone, &.{}));
    try testing.expect(try session.run(null) == .requested);
    try answerWithValue(&session, &.{});
    const result = try session.run(null);
    try testing.expectEqual(42, result.completed.body.scalar[0]);
}

fn startPreparedFailure(allocator: std.mem.Allocator, prepared: *const @import("stable_runtime").Prepared) !void {
    var session = try Session.start(allocator, prepared, &.{ 1, 0, 0, 0, 0, 0, 0, 0 });
    defer session.deinit();
}
fn restorePreparedFailure(allocator: std.mem.Allocator, prepared: *const @import("stable_runtime").Prepared, checkpoint: []const u8) !void {
    var session = try Session.restore(allocator, prepared, checkpoint);
    defer session.deinit();
}
test "failed prepared starts and restores preserve the reusable owner" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try retainedInputExample(&builder));
    defer compiled.deinit();
    const bytes = try programBytes(compiled.program);
    defer testing.allocator.free(bytes);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, bytes);
    defer prepared.deinit();
    const retained = try prepared.storageBytes();
    try @import("allocation_testing.zig").check(testing.allocator, startPreparedFailure, .{&prepared});
    var session = try Session.start(testing.allocator, &prepared, &.{ 1, 0, 0, 0, 0, 0, 0, 0 });
    defer session.deinit();
    try testing.expect(try session.run(null) == .requested);
    const checkpoint = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    try @import("allocation_testing.zig").check(testing.allocator, restorePreparedFailure, .{ &prepared, checkpoint });
    try testing.expectEqual(retained, try prepared.storageBytes());
    try answerWithValue(&session, &.{});
    try testing.expect(try session.run(null) == .completed);
}

fn retainedInputExample(builder: *source.Builder) !source.Module {
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const effect = try builder.effect(.{ .identity = "binding/read", .payload = unit, .result = unit });
    const main = try builder.declare(&.{integer}, integer, &.{effect}, &.{});
    const operation = try builder.term(.{ .perform = .{ .effect = effect, .payload = try builder.constant(void, {}) } });
    try builder.define(main, try builder.bind(try builder.variable(unit), operation, try builder.pure(try builder.reference(builder.parameter(main, 0)))));
    return builder.module(main, unit);
}

fn invocationFailure(allocator: std.mem.Allocator, command: []const u8) !void {
    var output = @as([1024]u8, @splat(0xa5));
    const bytes = @import("stable_runtime").invocation.invokeInto(allocator, command, &output) catch |err| {
        for (output) |byte| try testing.expectEqual(0xa5, byte);
        return err;
    };
    var decoded = try horos.data.invocation.decode(horos.data.invocation.Outcome, testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0, 0, 0, 0 }, decoded.value.completed);
}

test "current fresh invocation binds captured values and rejects stale replies without mutation" {
    const protocol = horos.data.invocation;
    const fresh = @import("stable_runtime").invocation;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try retainedInputExample(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var first = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{ .initial_args = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } } });
    defer first.deinit();
    var second = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{ .initial_args = &.{ 2, 0, 0, 0, 0, 0, 0, 0 } } });
    defer second.deinit();
    var first_request = try protocol.decode(protocol.Request, testing.allocator, first.record.requested.request);
    defer first_request.deinit();
    var second_request = try protocol.decode(protocol.Request, testing.allocator, second.record.requested.request);
    defer second_request.deinit();
    try testing.expectEqualDeep(first_request.value.binding.semantic_identity, second_request.value.binding.semantic_identity);
    try testing.expectEqualSlices(u8, first_request.value.binding.payload, second_request.value.binding.payload);
    try testing.expect(!std.mem.eql(u8, &first_request.value.request_identity, &second_request.value.request_identity));
    var poll = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{ .state = first.record.requested.state.? } });
    defer poll.deinit();
    try testing.expectEqualDeep(first.record, poll.record);
    const stale = try protocol.encodeOwned(protocol.Result, testing.allocator, .{ .request_identity = first_request.value.request_identity, .value = &.{} });
    defer testing.allocator.free(stale);
    try testing.expectError(error.InvalidResult, fresh.invoke(testing.allocator, .{
        .image = image,
        .instance = .{ .state = second.record.requested.state.? },
        .control = .{ .reply = stale },
    }));
    var resident = try Session.restoreImage(testing.allocator, image, second.record.requested.state.?);
    defer resident.deinit();
    try testing.expectError(error.InvalidResult, resident.answer(stale));
    const unchanged = try resident.checkpoint(testing.allocator);
    defer testing.allocator.free(unchanged);
    try testing.expectEqualSlices(u8, second.record.requested.state.?, unchanged);
    const response = try protocol.encodeOwned(protocol.Result, testing.allocator, .{ .request_identity = second_request.value.request_identity, .value = &.{} });
    defer testing.allocator.free(response);
    var zero = try fresh.invoke(testing.allocator, .{
        .image = image,
        .instance = .{ .state = second.record.requested.state.? },
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
    var completed = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{ .state = zero.record.progressed.? } });
    defer completed.deinit();
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0, 0, 0, 0 }, completed.record.completed);
    const command = try protocol.encodeOwned(protocol.Input, testing.allocator, .{
        .image = image,
        .instance = .{ .state = second.record.requested.state.? },
        .control = .{ .reply = response },
    });
    defer testing.allocator.free(command);
    const original = try testing.allocator.dupe(u8, command);
    defer testing.allocator.free(original);
    try @import("allocation_testing.zig").check(testing.allocator, invocationFailure, .{command});
    try testing.expectEqualSlices(u8, original, command);
    var output = @as([32]u8, @splat(0xa5));
    try testing.expectError(error.Capacity, fresh.invokeInto(testing.allocator, command, output[0..1]));
    for (output) |byte| try testing.expectEqual(0xa5, byte);
    try testing.expectEqualSlices(u8, original, command);
}

test "current invocation preserves explicit yield polling and cancellation before work" {
    const fresh = @import("stable_runtime").invocation;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const main = try builder.declare(&.{}, integer, &.{}, &.{});
    try builder.define(main, try builder.term(.{ .yield_then = try builder.pure(try builder.constant(u64, 42)) }));
    var compiled = try source.lower(testing.allocator, builder.module(main, try builder.scalar(void)));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var yielded = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{ .initial_args = &.{} } });
    defer yielded.deinit();
    var poll = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{ .state = yielded.record.yielded.? } });
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
    var completed = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{ .state = resumed.record.progressed.? } });
    defer completed.deinit();
    try testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, completed.record.completed);
    var cancelled = try fresh.invoke(testing.allocator, .{
        .image = image,
        .instance = .{ .initial_args = &.{} },
        .control = .{ .cancel = .{ .text = "stop" } },
        .quantum = 0,
    });
    defer cancelled.deinit();
    // Zero work can initiate cancellation; an unwind may need further quanta.
    if (cancelled.record == .progressed) {
        var done = try fresh.invoke(testing.allocator, .{ .image = image, .instance = .{ .state = cancelled.record.progressed.? } });
        defer done.deinit();
        try testing.expectEqualStrings("stop", done.record.cancelled.reason.text);
    } else try testing.expectEqualStrings("stop", cancelled.record.cancelled.reason.text);
}

test "cancellation rebinds a pending cleanup without repeating its semantic operation" {
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
    const acquired_result = try protocol.encodeOwned(protocol.Result, testing.allocator, .{ .request_identity = before.request.request_identity, .value = &.{} });
    defer testing.allocator.free(acquired_result);
    try session.cancel(.{ .text = "stop" });
    var after = try session.pendingRequest(testing.allocator);
    defer after.deinit();
    try testing.expectEqualStrings(before.request.binding.semantic_identity, after.request.binding.semantic_identity);
    try testing.expectEqualSlices(u8, before.request.binding.payload, after.request.binding.payload);
    try testing.expect(!std.mem.eql(u8, &before.request.request_identity, &after.request.request_identity));
    try testing.expectError(error.InvalidResult, session.answer(acquired_result));
    // The host explicitly re-encodes the already obtained typed result against
    // the successor challenge; no external operation runs inside this helper.
    try answerWithValue(&session, &.{});
    try testing.expect(try session.run(null) == .requested);
    try answerWithValue(&session, &.{});
    const result = try session.run(null);
    try testing.expect(result == .failed);
    try testing.expectEqualStrings("stop", (try session.terminalExit()).cancellation.?.text);
}

fn restoreFailure(allocator: std.mem.Allocator, image: []const u8, checkpoint: []const u8) !void {
    var session = try Session.restoreImage(allocator, image, checkpoint);
    defer session.deinit();
    const bytes = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, checkpoint, bytes);
}

test "PST3 restore releases every partial owner on allocation failure" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.installations(&builder, 1));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    _ = try session.run(1);
    const checkpoint = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    try @import("allocation_testing.zig").check(testing.allocator, restoreFailure, .{ image, checkpoint });
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

test "PST3 restore rejects wrong identity, code position, slots, and cleanup status" {
    const data = horos.data;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.resourceScalar(&builder));
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
                const bindings = try testing.allocator.dupe(data.process_state.Binding, original.activation.?.bindings);
                defer testing.allocator.free(bindings);
                node.activation.?.bindings = bindings;
                bindings[0].slot = std.math.maxInt(u64);
                // A single-row view avoids failing only the sorted-slot shape rule.
                node.activation.?.bindings = bindings[0..1];
                node.activation.?.owners = &.{};
                if (bindings[0].value.body == .owned) node.activation.?.owners = &.{.{ .scope = node.activation.?.scope, .slot = std.math.maxInt(u64) }};
                try rejectCheckpoint(image, forged);
                node.* = original;
                node.activation.?.bindings = &.{};
                node.activation.?.owners = &.{};
                try rejectCheckpoint(image, forged);
                node.* = original;
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

test "PST3 restore rejects aliased unique packages after graph renumbering" {
    const data = horos.data;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.custodyOrder(&builder, 0));
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

test "imported storage avoids payload copies and releases a large dead backing" {
    const data = horos.data;
    const Store = @FieldType(Session, "store");
    const big = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 0x5a);
    const small: data.graph.Value = .{ .schema = 0, .body = .{ .blob = .{ .id = 1 } } };
    // This is a physical Store test: no executable Program or control transition.
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
    var statistics: std.meta.Child(@typeInfo(@FieldType(Session, "statistics")).optional.child) = .{};
    store.statistics = &statistics.storage;
    var baseline: Store = .{ .allocator = testing.allocator };
    defer baseline.deinit();
    var baseline_statistics: @TypeOf(statistics) = .{};
    baseline.statistics = &baseline_statistics.storage;
    // Contrast transferred checkpoint storage with ordinary copying insertion.
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

test "stable borrow admission distinguishes older from fresh references through return clauses" {
    const fixture = @import("borrow_return_fixtures");
    for (std.enums.values(fixture.ResultFrom)) |from| {
        for ([_]bool{ false, true }) |initial| {
            for ([_]bool{ false, true }) |delegated| {
                for ([_]bool{ false, true }) |younger| {
                    var builder = source.Builder.init(testing.allocator);
                    defer builder.deinit();
                    const module = try fixture.scenario(&builder, from, initial, younger, delegated);
                    if (younger) {
                        try testing.expectError(error.InvalidOwnership, source.lower(testing.allocator, module));
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

test "stable resource implementations preserve private authority and loans across requests" {
    inline for (.{ source.examples.resourceScalar, source.examples.resourcePair }) |example| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(testing.allocator, try example(&builder));
        defer compiled.deinit();
        var session = try initFromImage(testing.allocator, compiled.program, &.{});
        defer session.deinit();
        var borrowed = false;
        for ([_][]const u8{ "example/resource-acquire", "example/resource-use", "example/resource-release" }, 0..) |name, index| {
            const pending = try drive(&session, null);
            try testing.expect(pending == .requested);
            try testing.expectEqualStrings(name, session.program.effects[@intCast(pending.requested.effect)].identity);
            if (index != 0) try testing.expectEqual(41, pending.requested.payload.body.scalar[0]);
            for (session.store.nodes.items, session.store.alive.items) |node, alive| {
                if (alive and node == .borrow) borrowed = true;
            }
            try session.store.collectWith(session.roots, &session.frames);
            try answerWithValue(&session, if (index == 0) &.{ 41, 0, 0, 0, 0, 0, 0, 0 } else &.{});
        }
        const result = try drive(&session, null);
        try testing.expect(borrowed and result == .completed);
        try testing.expectEqual(42, result.completed.body.scalar[0]);
    }
}

test "stable cancellation releases the resource while its protected borrow is suspended" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.resourceScalar(&builder));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    try testing.expect(try drive(&session, null) == .requested);
    try answerWithValue(&session, &.{ 41, 0, 0, 0, 0, 0, 0, 0 });
    const use = try drive(&session, null);
    try testing.expect(use == .requested);
    try testing.expectEqualStrings("example/resource-use", session.program.effects[@intCast(use.requested.effect)].identity);
    try session.cancel(.{ .text = "stop" });
    const release = try drive(&session, null);
    try testing.expect(release == .requested);
    try testing.expectEqualStrings("example/resource-release", session.program.effects[@intCast(release.requested.effect)].identity);
    try testing.expectEqual(41, release.requested.payload.body.scalar[0]);
    try answerWithValue(&session, &.{});
    try testing.expect(try drive(&session, null) == .cancelled);
}

test "stable admission rejects a fresh store hidden by a later same-slot rebind" {
    const fixture = @import("borrow_return_fixtures");
    const data = horos.data;
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try fixture.scenario(&builder, .pair, true, false, false));
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
                const operations = try testing.allocator.alloc(data.activation.Instruction, block.instructions.len + 1);
                defer testing.allocator.free(operations);
                @memcpy(operations[0..block.instructions.len], block.instructions);
                // Store the fresh field, then overwrite the same slot with the
                // older field. End-of-block provenance would miss the bad store.
                operations[position].immediate = 0;
                operations[operations.len - 1] = selected;
                block.instructions = operations;
                try testing.expectError(error.InvalidOwnership, data.activation_ownership.analyze(testing.allocator, image));
                return;
            }
        }
    }
    return error.TestUnexpectedResult;
}

test "stable source installs real handlers and keeps the final checked sum after them" {
    for ([_]usize{ 1, 8, 64, 128, 256 }) |count| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(testing.allocator, try source.examples.installations(&builder, count));
        defer compiled.deinit();
        var session = try initFromImage(testing.allocator, compiled.program, &.{});
        defer session.deinit();
        const result = try drive(&session, null);
        try testing.expect(result == .completed);
        try testing.expectEqual(count * (count + 1) / 2, std.mem.readInt(u64, result.completed.body.scalar[0..8], .little));
        try testing.expectEqual(0, session.frames.entries.count());
        try testing.expect(session.frames.slots.statistics.value_copies <= 32 * count + 128);
    }
}

test "stable source retains an external request and joins into the same activation" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const boolean = try builder.scalar(bool);
    const unit = try builder.scalar(void);
    const effect = try builder.effect(.{ .identity = "stable/read", .payload = unit, .result = integer });
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
    try testing.expectEqual(42, std.mem.readInt(u64, result.completed.body.scalar[0..8], .little));
}

test "stable source owns its input and keeps tail-recursive control bounded" {
    var builder = source.Builder.init(testing.allocator);
    var compiled = try source.lower(testing.allocator, try source.examples.recursive(&builder));
    var session = initFromImage(testing.allocator, compiled.program, &.{ 16, 39, 0, 0, 0, 0, 0, 0 }) catch |err| {
        compiled.deinit();
        builder.deinit();
        return err;
    };
    defer session.deinit();
    compiled.deinit();
    builder.deinit();
    var result = try drive(&session, 31);
    while (result == .progressed) {
        try testing.expect(session.frames.entries.count() <= 2);
        try testing.expect(session.store.nodes.items.len <= 512);
        result = try drive(&session, 31);
    }
    try testing.expect(result == .completed);
    try testing.expectEqual(1, result.completed.body.scalar[0]);
}

test "stable source resumes an owned package after its handler clause has returned" {
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const effect = try b.effect(.{ .identity = "stable/escape", .payload = unit, .result = integer, .external = false });
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
    try b.define(returns, try b.pure(try b.primitive(answer, .variant, &.{try b.reference(b.parameter(returns, 0))}, 0)));
    const clause = try b.declare(&.{ unit, token }, answer, &.{}, &.{});
    const packaged = try b.primitive(package, .package, &.{try b.reference(b.parameter(clause, 1))}, 0);
    try b.define(clause, try b.pure(try b.primitive(answer, .variant, &.{packaged}, 1)));
    const handler = try b.handler(.{ .mode = .deep, .input = integer, .answer = answer, .return_function = returns, .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }} });
    const body = try b.declare(&.{cap}, integer, &.{effect}, &.{});
    try b.define(body, try b.term(.{ .perform = .{
        .effect = effect,
        .capability = try b.reference(b.parameter(body, 0)),
        .payload = try b.constant(void, {}),
    } }));
    const finish = try b.declare(&.{answer}, integer, &.{}, &.{});
    const ordinary = try b.variable(integer);
    const suspended = try b.variable(package);
    const k = try b.variable(token);
    const resumed = try b.variable(answer);
    const again = try b.term(.{ .call = .{ .function = finish, .arguments = &.{try b.reference(resumed)} } });
    const resume_value = try b.term(.{ .resume_value = .{
        .resumption = try b.reference(k),
        .argument = try b.constant(u64, 42),
    } });
    const recover = try b.bind(k, try b.pure(try b.primitive(token, .unpack, &.{try b.reference(suspended)}, 0)), try b.bind(resumed, resume_value, again));
    try b.define(finish, try b.term(.{ .match_sum = .{
        .value = try b.reference(b.parameter(finish, 0)),
        .cases = &.{
            .{ .variable = ordinary, .body = try b.pure(try b.reference(ordinary)) },
            .{ .variable = suspended, .body = recover },
        },
    } }));
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
    var compiled = try source.lower(testing.allocator, b.module(main, unit));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    const observed = try drive(&session, null);
    try testing.expect(observed == .completed);
    try testing.expectEqual(42, std.mem.readInt(u64, observed.completed.body.scalar[0..8], .little));
}

fn failingSession(allocator: std.mem.Allocator, program: horos.data.activation.Program) !void {
    var session = try initFromImage(allocator, program, &.{});
    defer session.deinit();
    const result = try drive(&session, null);
    try testing.expect(result == .completed);
}

test "stable source releases partial native owners at every allocation failure" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.deep(&builder));
    defer compiled.deinit();
    try @import("allocation_testing.zig").check(testing.allocator, failingSession, .{compiled.program});
}

test "stable source reenters a live template-cell cycle without sharing branch control" {
    inline for (.{ source.examples.reentrant, source.examples.cloned }) |example| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(testing.allocator, try example(&builder));
        defer compiled.deinit();
        var session = try initFromImage(testing.allocator, compiled.program, &.{});
        defer session.deinit();
        var result = try drive(&session, 1);
        var yielded = false;
        while (result == .progressed or result == .yielded) {
            const before = try session.checkpoint(testing.allocator);
            defer testing.allocator.free(before);
            // Replace every private view handle without changing logical values.
            var frames = session.frames.entries.valueIterator();
            while (frames.next()) |frame| {
                const replacement = try session.frames.forkFrame(frame.*);
                session.frames.releaseFrame(frame.*);
                frame.* = replacement;
            }
            // An aggressive correctness lane: every live frame must participate
            // in graph tracing, including the cyclic retained template.
            try session.store.collectWith(session.roots, &session.frames);
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
        try testing.expectEqualSlices(u8, &.{ 113, 0, 0, 0, 0, 0, 0, 0 }, try session.bytes(&result.completed));
    }
}

test "stable source does not read a reclaimed copyable result only assigned to a dead binding" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const main = try builder.declare(&.{}, integer, &.{}, &.{});
    const unused = try builder.variable(integer);
    try builder.define(main, try builder.bind(unused, try builder.pure(try builder.constant(u64, 7)), try builder.pure(try builder.constant(u64, 42))));
    var compiled = try source.lower(testing.allocator, builder.module(main, unit));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    const result = try drive(&session, null);
    try testing.expect(result == .completed);
    try testing.expectEqual(42, result.completed.body.scalar[0]);
}

test "stable retained template preserves an older activation across loop-slot rebindings" {
    const d = horos.data;
    const program: d.activation.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 2 },
        .schemas = &.{
            .u64,                                  .boolean,                                                                                                                                              .unit,
            .{ .internal = .{ .capability = 0 } }, .{ .internal = .{ .resumption = .{ .effect = 0, .input = 1, .answer = 0, .capture_bound = &.{0}, .handled = &.{0}, .mode = .deep, .use = .multi } } }, .{ .internal = .{ .computation = .{ .parameters = &.{3}, .result = 0, .effects = &.{0} } } },
        },
        .constants = &.{
            .{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .schema = 0, .bytes = &.{ 2, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .schema = 1, .bytes = &.{0} },
            .{ .schema = 1, .bytes = &.{1} },
            .{ .schema = 2, .bytes = &.{} },
        },
        .effects = &.{.{ .identity = "stable/loop", .payload = 2, .result = 1, .control_use = .multi, .external = false }},
        .functions = &.{
            .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{ 5, 0 } }, .result = 0 },
            .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{ 3, 0, 0, 2, 1, 0, 0, 0, 1, 0 } }, .result = 0, .effects = &.{0} },
            .{ .entry = 5, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
            .{ .entry = 6, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 2, 4, 1, 0, 1, 0, 0 } }, .result = 0 },
        },
        .blocks = &.{
            .{ .function = 0, .instructions = &.{.{ .destination = 0, .opcode = .computation }}, .terminator = .{ .handle = .{ .handler = 0, .body = 0, .arguments = &.{}, .state = &.{}, .next = .{ .block = 1, .assignments = &.{.{ .destination = 1, .source = .returned }} } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
            .{ .function = 1, .instructions = &.{
                .{ .destination = 1, .opcode = .constant, .immediate = 0 },
                .{ .destination = 2, .opcode = .constant, .immediate = 1 },
                .{ .destination = 3, .opcode = .constant, .immediate = 5 },
                .{ .destination = 9, .opcode = .constant, .immediate = 2 },
            }, .terminator = .{ .perform = .{ .effect = 0, .capability = 0, .payload = 3, .next = .{ .block = 3, .assignments = &.{.{ .destination = 4, .source = .returned }} } } } },
            .{ .function = 1, .instructions = &.{
                .{ .destination = 5, .opcode = .constant, .immediate = 0 },
                .{ .destination = 6, .opcode = .integer_add, .operands = &.{ 1, 5 }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = 5 }} },
                .{ .destination = 7, .opcode = .integer_sub, .operands = &.{ 2, 5 }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = 5 }} },
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
            .{ .function = 3, .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 4 }}, .terminator = .{ .resume_value = .{ .resumption = 1, .argument = 2, .next = .{ .block = 7, .assignments = &.{.{ .destination = 3, .source = .returned }} } } } },
            .{ .function = 3, .instructions = &.{.{ .destination = 4, .opcode = .constant, .immediate = 3 }}, .terminator = .{ .resume_value = .{ .resumption = 1, .argument = 4, .next = .{ .block = 8, .assignments = &.{.{ .destination = 5, .source = .returned }} } } } },
            .{ .function = 3, .instructions = &.{.{ .destination = 6, .opcode = .integer_add, .operands = &.{ 3, 5 }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = 5 }} }}, .terminator = .{ .return_value = 6 } },
        },
        .handlers = &.{.{ .mode = .deep, .input = 0, .answer = 0, .return_function = 2, .clauses = &.{.{ .effect = 0, .function = 3, .resumption = 4 }} }},
        .scopes = .{ .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
        .constructors = &.{.{ .function = 1, .capture = 0, .schema = 5 }},
    };
    var session = try initFromImage(testing.allocator, program, &.{});
    defer session.deinit();
    const result = try drive(&session, null);
    try testing.expect(result == .completed);
    // Each activation starts at x=1, count=2, then returns 3. The retained
    // template must not inherit the first branch's x=3/count=0 bindings.
    try testing.expectEqual(6, result.completed.body.scalar[0]);
}

test "stable shallow value and computation resumptions omit the original return clause" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.shallowResumptions(&builder));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    var result = try drive(&session, 1);
    while (result == .progressed) {
        try session.store.collectWith(session.roots, &session.frames);
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

test "stable injection selects definition-site versus use-site capabilities" {
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
            while (result == .progressed) {
                for (session.store.nodes.items, session.store.alive.items) |node, alive|
                    if (alive and node == .injection) {
                        saw_injection = true;
                    };
                try session.store.collectWith(session.roots, &session.frames);
                result = try drive(&session, 1);
            }
            try testing.expect(result == .completed);
            try testing.expectEqual(@as(u64, if (injecting == 0) 109 else 209), std.mem.readInt(u64, result.completed.body.scalar[0..8], .little));
            try testing.expectEqual(injecting == 1, saw_injection);
        }
    }
}

test "stable cleanup preserves primary failure and resumes external cleanup" {
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
            try testing.expectEqualStrings(name, session.program.effects[@intCast(pending.requested.effect)].identity);
            try session.store.collectWith(session.roots, &session.frames);
            try answerWithValue(&session, &.{});
        }
        const result = try drive(&session, null);
        try testing.expect(result == .failed);
        try testing.expectEqual(@as(u8, if (primary == 1) 9 else 7), result.failed.body.scalar[0]);
        try testing.expectEqual(2, (try session.terminalExit()).cleanup_failures.len);
        try testing.expectEqual(7, (try session.terminalExit()).cleanup_failures[0].body.scalar[0]);
        try testing.expectEqual(8, (try session.terminalExit()).cleanup_failures[1].body.scalar[0]);
    }
}

test "stable cancellation during yielded cleanup preserves the first reason" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.yieldingCleanup(&builder));
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
        try testing.expectEqual(@as(u8, if (primary == 1) 9 else 7), result.failed.body.scalar[0]);
        try testing.expectEqualStrings("stop", (try session.terminalExit()).cancellation.?.text);
    }
}

test "stable unwind preserves lexical and temporary-owner cleanup order" {
    for (0..10) |mode| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(testing.allocator, try source.examples.custodyOrder(&builder, @intCast(mode)));
        defer compiled.deinit();
        var session = try initFromImage(testing.allocator, compiled.program, &.{});
        defer session.deinit();
        var requests: usize = 0;
        var yields: usize = 0;
        var result = try drive(&session, 1);
        while (result == .progressed or result == .yielded or result == .requested) {
            if (result == .yielded) {
                yields += 1;
                try session.resumeYield();
            }
            if (result == .requested) {
                try testing.expect(requests < 2);
                const reversed = mode == 1 or mode == 3 or mode >= 4;
                const label: u64 = if (reversed) 2 - requests else requests + 1;
                try testing.expectEqual(label, std.mem.readInt(u64, result.requested.payload.body.scalar[0..8], .little));
                requests += 1;
                try answerWithValue(&session, &.{});
            }
            try session.store.collectWith(session.roots, &session.frames);
            result = try drive(&session, 1);
        }
        try testing.expect(result == .failed);
        try testing.expectEqual(8, result.failed.body.scalar[0]);
        try testing.expectEqual(2, requests);
        try testing.expectEqual(1, yields);
    }
}

test "stable cancellation preserves cleanup at entry yield request and answered boundaries" {
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const info = try horos.library.cleanup.exitInfo(&b, integer);
    const read_effect = try b.effect(.{ .identity = "cancel/read", .payload = unit, .result = integer });
    const release = try b.effect(.{ .identity = "cancel/release", .payload = info, .result = unit });
    const body = try b.declare(&.{}, integer, &.{read_effect}, &.{});
    const request = try b.term(.{ .perform = .{ .effect = read_effect, .payload = try b.constant(void, {}) } });
    const repeated = try b.bind(try b.variable(integer), request, request);
    try b.define(body, try b.term(.{ .yield_then = repeated }));
    const cleanup = try b.declare(&.{info}, unit, &.{release}, &.{});
    try b.define(cleanup, try b.term(.{ .perform = .{ .effect = release, .payload = try b.reference(b.parameter(cleanup, 0)) } }));
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

test "stable clause failure abandons a captured cleanup without losing its primary exit" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.clauseAbort(&builder));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    const pending = try drive(&session, null);
    try testing.expect(pending == .requested);
    try testing.expectEqualStrings("example/abandoned-release", session.program.effects[@intCast(pending.requested.effect)].identity);
    try testing.expectEqualSlices(u8, &.{ 1, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, try session.bytes(&pending.requested.payload));
    try session.store.collectWith(session.roots, &session.frames);
    try answerWithValue(&session, &.{});
    const result = try drive(&session, null);
    try testing.expect(result == .failed);
    try testing.expectEqual(9, result.failed.body.scalar[0]);
}

test "stable generator resumes private state and closes its retained cleanup" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.generator(&builder));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    var yields: usize = 0;
    var releases: usize = 0;
    var result = try drive(&session, 1);
    while (result != .completed) {
        switch (result) {
            .progressed => {},
            .yielded => {
                yields += 1;
                try session.resumeYield();
            },
            .requested => |pending| {
                releases += 1;
                try testing.expectEqualStrings("example/generator-release", session.program.effects[@intCast(pending.effect)].identity);
                try testing.expectEqual(43, pending.payload.body.scalar[0]);
                try answerWithValue(&session, &.{});
            },
            else => return error.TestUnexpectedResult,
        }
        try session.store.collectWith(session.roots, &session.frames);
        result = try drive(&session, 1);
    }
    try testing.expectEqual(1, yields);
    try testing.expectEqual(1, releases);
    try testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0, 43, 0, 0, 0, 0, 0, 0, 0 }, try session.bytes(&result.completed));
}

test "stateful service preserves labeled replies and exclusive turns through restore" {
    inline for (.{ .empty, .requests, .swapped, .cancelled, .overflow }) |mode| {
        for ([_]bool{ false, true }) |restore| try serviceWitness(mode, restore);
    }
}

fn serviceWitness(comptime mode: enum { empty, requests, swapped, cancelled, overflow }, restore: bool) !void {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const module = if (mode == .swapped) try source.examples.swappedServiceReplies(&builder) else try source.examples.statefulService(&builder);
    var compiled = try source.lower(testing.allocator, module);
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var session = try Session.initImage(testing.allocator, image, &.{});
    defer session.deinit();
    var commands: usize = 0;
    var replies: usize = 0;
    var releases: usize = 0;
    var yields: usize = 0;
    const final: u64 = switch (mode) {
        .empty => 0,
        .cancelled, .overflow => 1,
        .requests, .swapped => 2,
    };
    while (true) {
        const result = try drive(&session, null);
        switch (result) {
            .yielded => {
                yields += 1;
                // The next command cannot be requested while this turn is held.
                try testing.expectEqual(commands, yields);
                try testing.expectEqual(replies + 1, commands);
                if (restore) {
                    const checkpoint = try session.checkpoint(testing.allocator);
                    defer testing.allocator.free(checkpoint);
                    var resumed = try Session.restoreImage(testing.allocator, image, checkpoint);
                    errdefer resumed.deinit();
                    const roundtrip = try resumed.checkpoint(testing.allocator);
                    defer testing.allocator.free(roundtrip);
                    try testing.expectEqualSlices(u8, checkpoint, roundtrip);
                    session.deinit();
                    session = resumed;
                }
                if (mode == .cancelled) try session.cancel(.{ .text = "stop" }) else try session.resumeYield();
            },
            .requested => |pending| {
                const identity = session.program.effects[@intCast(pending.effect)].identity;
                if (std.mem.eql(u8, identity, "example/service-command")) {
                    // Each admitted request has replied before another is admitted.
                    try testing.expectEqual(commands, replies);
                    if (mode == .empty or commands == 2) {
                        try answerWithValue(&session, &.{1}); // close
                    } else {
                        var request: [17]u8 = undefined;
                        request[0] = 0; // serve(id, delta)
                        std.mem.writeInt(u64, request[1..9], commands + 1, .little);
                        std.mem.writeInt(u64, request[9..17], if (mode == .overflow and commands == 1) std.math.maxInt(u64) else 1, .little);
                        commands += 1;
                        try answerWithValue(&session, &request);
                    }
                } else if (std.mem.eql(u8, identity, "example/service-reply")) {
                    var expected: [16]u8 = undefined;
                    std.mem.writeInt(u64, expected[0..8], if (mode == .swapped) (replies + 1) ^ 3 else replies + 1, .little);
                    std.mem.writeInt(u64, expected[8..16], replies, .little);
                    try testing.expectEqualSlices(u8, &expected, try session.bytes(&pending.payload));
                    replies += 1;
                    try answerWithValue(&session, &.{});
                } else {
                    try testing.expectEqualStrings("example/service-finalize", identity);
                    releases += 1;
                    var expected: [8]u8 = undefined;
                    std.mem.writeInt(u64, &expected, final, .little);
                    try testing.expectEqualSlices(u8, &expected, try session.bytes(&pending.payload));
                    try answerWithValue(&session, &.{});
                }
            },
            .completed => |value| {
                try testing.expect(mode == .empty or mode == .requests or mode == .swapped);
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
    try testing.expectEqual(@as(usize, 1), releases);
    try testing.expectEqual(@as(usize, switch (mode) {
        .empty, .cancelled => 0,
        .overflow => 1,
        .requests, .swapped => 2,
    }), replies);
}

test "stable successor return clauses retain older capability and cell references" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.successorState(&builder));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    try testing.expect(try drive(&session, null) == .yielded);
    try session.store.collectWith(session.roots, &session.frames);
    try session.resumeYield();
    const result = try drive(&session, null);
    try testing.expect(result == .completed);
    try testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0, 37, 0, 0, 0, 0, 0, 0, 0 }, try session.bytes(&result.completed));
}

fn captureFrameCheckpoint(session: *Session) ![]u8 {
    for (0..512) |_| {
        try session.step();
        for (session.store.nodes.items, session.store.alive.items) |node, alive| {
            if (alive and (node == .one_shot or node == .multi_template))
                return session.checkpoint(testing.allocator);
        }
    }
    return error.MissingCapture;
}

fn emptyRecordPayload(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            var value: T = undefined;
            inline for (info.field_names, info.field_types) |field_name, FieldType| @field(value, field_name) = emptyRecordPayload(FieldType);
            break :blk value;
        },
        .@"union" => |info| @unionInit(T, info.field_names[0], emptyRecordPayload(info.field_types[0])),
        else => std.mem.zeroes(T),
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

fn rejectDisposalParent(image: []const u8, original: horos.data.process_state.State, frame: usize, schema: u64) !void {
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
    // The public restore path must reject the canonical bytes before execution.
    try testing.expectError(error.InvalidState, Session.restoreImage(testing.allocator, image, encoded));
}

fn checkReturnPaths(session: *Session, image: []const u8, schema: u64, seen: *std.EnumSet(ReturnPathKind), captured_cleanup: *bool) !void {
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
    while (cursor) |ref| {
        const record = &nodes[@intCast(ref.id)].record;
        if (record.* == .continuation) selected.set(.continuation, @intCast(ref.id));
        if (record.* == .protection) selected.set(.protection, @intCast(ref.id));
        cursor = if (returnParent(record)) |parent| parent.* else null;
    }
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
    // Continue from actual restored bytes at every boundary, including cleanup.
    const restored = try Session.restoreImage(testing.allocator, image, bytes);
    session.deinit();
    session.* = restored;
}

test "PST3 normal return paths reject disposal markers while captured cleanup stays valid" {
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
        // Keep effect admission valid so rejection must detect the return path.
        var marker = b.schemas.items[@intCast(b.handlers.items[0].clauses[0].resumption)];
        const effects = try b.allocator().alloc(u64, b.effects.items.len);
        for (effects, 0..) |*effect, id| effect.* = id;
        marker.internal.resumption.effects = effects;
        const marker_schema = try b.schema(marker);
        var compiled = try compileDeclarations(b.module(module.entry, module.failure));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer testing.allocator.free(image);
        var session = try Session.initImage(testing.allocator, image, if (example == 1) &.{1} else &.{});
        defer session.deinit();
        for (0..512) |_| {
            try checkReturnPaths(&session, image, marker_schema, &seen, &captured_cleanup);
            if (session.terminal != null) break;
            switch (session.status) {
                .yielded => try session.resumeYield(),
                .parked => try answerWithValue(&session, &.{}),
                else => try session.step(),
            }
        }
        const result = try session.observe();
        if (example == 2) {
            try testing.expect(result == .failed);
            try testing.expectEqual(9, result.failed.body.scalar[0]);
        } else {
            try testing.expect(result == .completed);
            try testing.expectEqual(if (example == 0) @as(u8, 67) else 60, result.completed.body.scalar[0]);
        }
    }
    try testing.expectEqual(std.EnumSet(ReturnPathKind).full.bits, seen.bits);
    try testing.expect(captured_cleanup);
}

test "PST3 captured handler state obeys one-shot and multi bounds and reference kinds" {
    const data = horos.data;
    const g = data.graph;
    inline for (.{ false, true }) |multi| inline for (.{ false, true }) |allowed| {
        var b = source.Builder.init(testing.allocator);
        defer b.deinit();
        const module = if (multi) try source.examples.choicesAll(&b) else try source.examples.deep(&b);
        // The captured body returns the handler input, before answer transformation.
        const result_type = b.handlers.items[0].input;
        const wide = try b.scalar(u16);
        const returns = try b.declare(&.{ wide, result_type }, result_type, &.{}, &.{});
        try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 1))));
        const extra = try b.handler(.{ .mode = .deep, .input = result_type, .answer = result_type, .return_function = returns, .state = &.{wide}, .clauses = &.{} });
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
        const a = decoded.arena.allocator();
        const count = decoded.state.nodes.len;
        const nodes = try a.alloc(data.process_state.Node, count + 2);
        @memcpy(nodes[0..count], decoded.state.nodes);
        const token = for (nodes[0..count]) |node| {
            if (node.record == .one_shot or node.record == .multi_template)
                break if (node.record == .one_shot) node.record.one_shot else node.record.multi_template;
        } else return error.MissingCapture;
        const saved = &nodes[@intCast(token.capture.?.id)].record.continuation;
        nodes[count] = .{ .record = .{ .handler = .{ .definition = extra, .state = try a.dupe(g.Value, &.{.{ .schema = wide, .body = .{ .scalar = @splat(0) } }}), .evidence = saved.evidence, .region = saved.region } } };
        nodes[count + 1] = .{ .record = .{ .attachment = .{ .handler = .{ .id = count }, .outer = saved.evidence, .return_to = saved.parent, .region = saved.region } } };
        saved.parent = .{ .id = count + 1 };
        decoded.state.nodes = nodes;
        const encoded = try data.state_image.emit(testing.allocator, decoded.state);
        defer testing.allocator.free(encoded);
        var canonical = try data.state_image.decodeGraph(testing.allocator, encoded);
        defer canonical.deinit();
        const checked_nodes = @constCast(canonical.state.nodes);
        const handler_index = for (checked_nodes, 0..) |node, index| {
            if (node.record == .handler and node.record.handler.definition == extra) break index;
        } else return error.MissingInsertedHandler;
        if (!allowed) {
            try testing.expectError(error.InvalidOwnership, data.state_admission.validateStable(testing.allocator, compiled.program, canonical.state));
            continue;
        }
        try data.state_admission.validateStable(testing.allocator, compiled.program, canonical.state);
        const original = checked_nodes[handler_index];
        inline for (@typeInfo(g.Node).@"union".field_names, @typeInfo(g.Node).@"union".field_types) |field_name, FieldType| {
            if (comptime !std.mem.eql(u8, field_name, "handler")) {
                checked_nodes[handler_index].record = @unionInit(g.Node, field_name, emptyRecordPayload(FieldType));
                if (data.state_admission.validateStable(testing.allocator, compiled.program, canonical.state)) |_| {
                    return error.AcceptedWrongCapturedHandlerKind;
                } else |err| try testing.expect(err != error.OutOfMemory);
                checked_nodes[handler_index] = original;
            }
        }
        const image = try programBytes(compiled.program);
        defer testing.allocator.free(image);
        const checkpoint = try data.state_image.emit(testing.allocator, canonical.state);
        defer testing.allocator.free(checkpoint);
        var restored = try Session.restoreImage(testing.allocator, image, checkpoint);
        defer restored.deinit();
        const result = try restored.run(null);
        try testing.expect(result == .completed);
        const expected: []const u8 = if (multi) &.{ 4, 0, 0, 0, 1, 1, 0, 1, 1 } else &.{ 67, 0, 0, 0, 0, 0, 0, 0 };
        try testing.expectEqualSlices(u8, expected, try restored.bytes(&result.completed));
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

fn argumentSessionFailure(allocator: std.mem.Allocator, prepared: *const @import("stable_runtime").Prepared, input: []const u8) !void {
    var session = try Session.start(allocator, prepared, input);
    defer session.deinit();
    const result = try session.run(null);
    try testing.expect(result == .completed);
    try testing.expectEqualSlices(u8, &.{ 5, 's', 'm', 'a', 'l', 'l' }, try session.bytes(&result.completed));
}

test "argument backing releases every partial Session owner on allocation failure" {
    const image = try argumentImage();
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    const input = try argumentBytes(4096);
    defer testing.allocator.free(input);
    try @import("allocation_testing.zig").check(testing.allocator, argumentSessionFailure, .{ &prepared, input });
}

test "argument Session survives caller release and sheds a large dead payload" {
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
    try testing.expect(session.store.imported == null);
}

fn argumentStoreFailure(allocator: std.mem.Allocator, prepared: *const @import("stable_runtime").Prepared, input: []const u8) !void {
    const core = try prepared.acquire();
    defer core.release();
    var store: @FieldType(Session, "store") = .{ .allocator = allocator };
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
    _ = try store.literal(core.admitted().program().schemas, .{ .schema = values[1].schema, .bytes = &.{ 3, 'n', 'e', 'w' } });
    store.rollback();
    const original = (try store.get(root)).environment.values;
    try testing.expectEqualDeep(values, original);
    try testing.expectEqualSlices(u8, &.{ 5, 's', 'm', 'a', 'l', 'l' }, store.blobs.items[@intCast(values[1].body.blob.id)].bytes);
    var reader: horos.data.wire.Reader = .{ .input = input };
    const count = try reader.count();
    _ = try reader.take(count);
    try testing.expectEqualSlices(u8, input[0..reader.position], store.blobs.items[@intCast(values[0].body.blob.id)].bytes);
    try store.replace(root, .{ .environment = .{ .values = values[1..2], .tail = null } });
    try store.collect(.{ .current = root });
    try testing.expect(store.imported == null);
    try testing.expectEqualSlices(u8, &.{ 5, 's', 'm', 'a', 'l', 'l' }, store.blobs.items[@intCast(values[1].body.blob.id)].bytes);
    const same = try store.literal(core.admitted().program().schemas, .{ .schema = values[1].schema, .bytes = &.{ 5, 's', 'm', 'a', 'l', 'l' } });
    try testing.expectEqualDeep(values[1], same);
}

test "argument backing survives journal collection and reuse then compacts a tiny survivor" {
    const image = try argumentImage();
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    const input = try argumentBytes(4096);
    defer testing.allocator.free(input);
    try @import("allocation_testing.zig").check(testing.allocator, argumentStoreFailure, .{ &prepared, input });
}

test "resident terminal compaction preserves rollback and releases backing at commit" {
    const image = try argumentImage();
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    const input = try argumentBytes(4096);
    defer testing.allocator.free(input);
    var initial = try Session.start(testing.allocator, &prepared, input);
    defer initial.deinit();
    const checkpoint = try initial.checkpoint(testing.allocator);
    defer testing.allocator.free(checkpoint);
    const expected = try horos.data.invocation.encodeOwned(horos.data.invocation.Outcome, testing.allocator, .{ .completed = &.{ 5, 's', 'm', 'a', 'l', 'l' } });
    defer testing.allocator.free(expected);
    var failures: usize = 0;
    while (true) : (failures += 1) {
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
        break;
    }
}

test "handler continuation transfers the active view after staging call operands" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.installations(&builder, 8));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    for (0..256) |_| {
        const current = session.roots.current.?;
        const control = (try session.store.get(current)).control;
        const block = session.program.blocks[@intCast(control.block)];
        const frame = try session.frames.get(current.id);
        if (frame.position == block.instructions.len and block.terminator == .handle) {
            try session.step();
            const body = (try session.store.get(session.roots.current.?)).control;
            const attachment = (try session.store.get(body.parent.?)).attachment;
            const saved = try session.frames.get(attachment.return_to.?.id);
            try testing.expectEqualDeep(frame.view, saved.view);
            try testing.expectEqual(current.id, attachment.return_to.?.id);
            try testing.expect(try session.store.get(current) == .continuation);
            const checkpoint = try session.checkpoint(testing.allocator);
            defer testing.allocator.free(checkpoint);
            const result = try drive(&session, null);
            try testing.expect(result == .completed);
            try testing.expectEqual(36, std.mem.readInt(u64, result.completed.body.scalar[0..8], .little));
            return;
        }
        try session.step();
    }
    return error.TestUnexpectedResult;
}

fn prepareContractFailure(allocator: std.mem.Allocator, image: []const u8) !void {
    var prepared = try @import("stable_runtime").Prepared.init(allocator, image);
    defer prepared.deinit();
}

test "prepared contracts retain encoded bytes without canonicalization scratch" {
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    var fields: [64]source.Id = undefined;
    for (&fields, 0..) |*field, i| field.* = try b.schema(.{ .bounded_text = i + 1 });
    const payload = try b.schema(.{ .product = &fields });
    const effect = try b.effect(.{ .identity = "large-contract", .payload = payload, .result = payload, .external = true });
    const entry = try b.declare(&.{payload}, payload, &.{effect}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{ .effect = effect, .payload = try b.reference(b.parameter(entry, 0)) } }));
    var compiled = try source.lower(testing.allocator, b.module(entry, try b.scalar(void)));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    const admitted = prepared.core.?.admitted();
    const program = admitted.program();
    const contract = try prepared.core.?.contract(0);
    const expected = try horos.data.schema.encodeOwned(testing.allocator, program.schemas, program.effects[0].payload);
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(u8, expected, contract.payload);
    try testing.expectEqualSlices(u8, expected, contract.resume_value);
    // Arena growth and the contract table are chargeable; temporary partition
    // maps and schema graphs must not remain owned by preparation.
    const contract_storage = (try prepared.storageBytes()) - admitted.storageBytes();
    try testing.expect(contract_storage <= 1024 + 4 * (contract.payload.len + contract.resume_value.len));
    try @import("allocation_testing.zig").check(testing.allocator, prepareContractFailure, .{image});
}

fn smallSurvivorExample(b: *source.Builder, keep_original: bool, request_boundary: bool) !source.Module {
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const sequence = try b.schema(.{ .seq = integer });
    const pause = if (request_boundary) try b.effect(.{ .identity = "retention/pause", .payload = unit, .result = unit }) else 0;
    const result_schema = if (keep_original) try b.schema(.{ .product = &.{ sequence, sequence } }) else sequence;
    const entry = try b.declare(&.{sequence}, result_schema, if (request_boundary) &.{pause} else &.{}, &.{});
    const input = try b.reference(b.parameter(entry, 0));
    const kept = try b.variable(sequence);
    const take = try b.primitive(sequence, .sequence_take, &.{ input, try b.constant(u64, 1) }, 0);
    const small = try b.reference(kept);
    const result = if (keep_original) try b.primitive(result_schema, .product, &.{ small, input }, 0) else small;
    const returned = try b.pure(result);
    const suspended = if (request_boundary)
        try b.bind(try b.variable(unit), try b.term(.{ .perform = .{ .effect = pause, .payload = try b.constant(void, {}) } }), returned)
    else
        try b.term(.{ .yield_then = returned });
    try b.define(entry, try b.bind(kept, try b.pure(take), suspended));
    return b.module(entry, unit);
}

test "public suspension releases large dead input backing while preserving live aliases" {
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
        var compiled = try source.lower(testing.allocator, try smallSurvivorExample(&builder, keep_original, request_boundary));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer testing.allocator.free(image);
        var workspace = @import("stable_runtime").Workspace.init(backing);
        var session = try Session.initImage(workspace.allocator(), image, input[0..writer.position]);
        defer session.deinit();
        const observed = try session.run(null);
        try testing.expect(if (request_boundary) observed == .requested else observed == .yielded);
        const retained = workspace.live_payload;
        if (keep_original) try testing.expect(retained >= writer.position) else try testing.expect(retained < writer.position / 4);
        const checkpoint = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(checkpoint);
        try testing.expectEqual(retained, workspace.live_payload);
        const repeated = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(repeated);
        try testing.expectEqualSlices(u8, checkpoint, repeated);
        if (!keep_original) try testing.expect(checkpoint.len < 1024);
        var restored = try Session.restoreImage(testing.allocator, image, checkpoint);
        defer restored.deinit();
        for ([_]*Session{ &session, &restored }) |subject| {
            if (request_boundary) {
                var pending = try subject.pendingRequest(testing.allocator);
                defer pending.deinit();
                const protocol = horos.data.invocation;
                const reply = try protocol.encodeOwned(protocol.Result, testing.allocator, .{ .request_identity = pending.request.request_identity, .value = &.{} });
                defer testing.allocator.free(reply);
                try subject.answer(reply);
            } else try subject.resumeYield();
            const result = try subject.run(null);
            try testing.expect(result == .completed);
            const bytes = try subject.bytes(&result.completed);
            const expected = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 0, 0 };
            try testing.expectEqualSlices(u8, &expected, bytes[0..expected.len]);
            if (keep_original) try testing.expectEqualSlices(u8, input[0..writer.position], bytes[expected.len..]) else try testing.expectEqual(expected.len, bytes.len);
        }
    };
}

test "suspension reclamation rolls back every allocation failure" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try smallSurvivorExample(&builder, false, true));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var input: [65540]u8 = undefined;
    var writer: horos.data.wire.Writer = .{ .output = &input };
    try writer.natural(8192);
    for (0..8192) |i| try writer.fixed(u64, i + 1);
    var session = try Session.start(testing.allocator, &prepared, input[0..writer.position]);
    defer session.deinit();
    const before = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(before);
    for ([_]bool{ false, true }) |with_checkpoint| try residentFailureSweep(&prepared, before, .none, with_checkpoint);
}

test "resident retained recursive tail frames preserve rollback at every allocation failure" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try @import("retained_loop_bench.zig").build(&builder, 3));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var session = try Session.start(testing.allocator, &prepared, &.{});
    defer session.deinit();
    const before = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(before);
    const outcome = try session.run(null);
    try testing.expect(outcome == .completed);
    try testing.expectEqual(@as(u64, 8), std.mem.readInt(u64, outcome.completed.body.scalar[0..8], .little));
    for ([_]bool{ false, true }) |with_checkpoint| try residentFailureSweep(&prepared, before, .none, with_checkpoint);
}

test "handler return functions distinguish body value from state and preserve rollback" {
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
            b.functions.items[@intCast(returned)].body = try b.pure(try b.reference(b.parameter(returned, 0)));
        }
        var compiled = try source.lower(testing.allocator, b.module(module.entry, module.failure));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer testing.allocator.free(image);
        var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
        defer prepared.deinit();
        var session = try Session.start(testing.allocator, &prepared, &.{});
        defer session.deinit();
        const initial = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(initial);
        for ([_]bool{ false, true }) |with_checkpoint|
            try residentFailureSweep(&prepared, initial, .none, with_checkpoint);
        const result = try session.run(null);
        try testing.expect(result == .completed);
        try testing.expectEqual(([_]u64{ 7, 99, 1 })[mode], std.mem.readInt(u64, result.completed.body.scalar[0..8], .little));
        try testing.expectEqual(0, session.frames.entries.count());
    }
}

test "immediate closed handler bodies elide allocation only when the value cannot escape" {
    const ir = horos.data.activation;
    for (0..6) |mode| {
        var b = source.Builder.init(testing.allocator);
        defer b.deinit();
        var compiled = try source.lower(testing.allocator, try source.examples.installations(&b, 2));
        defer compiled.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var program = compiled.program;
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
                instructions[instructions.len - 1] = .{ .destination = body, .opcode = .move, .operands = try a.dupe(u64, &.{body}) };
                block.instructions = instructions;
            }
        } else if (mode == 2) {
            second.body = first.body; // The callable must survive the first handler.
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
            assignments[assignments.len - 1] = .{ .destination = old.len, .source = .{ .slot = first.body } };
            first.next.assignments = assignments;
            // Capture still needs the source if the copied destination is dead.
            if (mode == 3) second.body = old.len;
        } else if (mode == 4) {
            const body_schema = program.functions[@intCast(program.roots.entry)].layout.slots[@intCast(first.body)];
            const schemas = try a.dupe(horos.data.program.Schema, program.schemas);
            schemas[@intCast(body_schema)].internal.computation.use = .linear;
            program.schemas = schemas;
            const captures = try a.dupe(horos.data.program.Capture, program.scopes.captures);
            for (program.constructors) |constructor| if (constructor.schema == body_schema) {
                captures[@intCast(constructor.capture)].use = .linear;
            };
            program.scopes.captures = captures;
        }
        const image = try programBytes(program);
        defer testing.allocator.free(image);
        var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
        defer prepared.deinit();
        var session = try Session.start(testing.allocator, &prepared, &.{});
        defer session.deinit();
        const initial = try session.checkpoint(testing.allocator);
        defer testing.allocator.free(initial);
        for ([_]bool{ false, true }) |with_checkpoint|
            try residentFailureSweep(&prepared, initial, .none, with_checkpoint);
        var strict_stats: std.meta.Child(@typeInfo(@FieldType(Session, "statistics")).optional.child) = .{};
        session.statistics = &strict_stats;
        session.store.statistics = &strict_stats.storage;
        var saw_callable = false;
        while (session.terminal == null) {
            try session.step();
            for (session.store.nodes.items, session.store.alive.items) |node, alive|
                if (alive and node == .computation) {
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
        try testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, result.completed.body.scalar[0..8], .little));
        try testing.expect(saw_callable); // Explicit single-step retains this horos.
        var fast = try Session.start(testing.allocator, &prepared, &.{});
        defer fast.deinit();
        var fast_stats: std.meta.Child(@typeInfo(@FieldType(Session, "statistics")).optional.child) = .{};
        fast.statistics = &fast_stats;
        fast.store.statistics = &fast_stats.storage;
        const fast_result = try fast.run(null);
        try testing.expect(fast_result == .completed);
        try testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, fast_result.completed.body.scalar[0..8], .little));
        try testing.expectEqual(strict_stats.transitions, fast_stats.transitions);
        try testing.expectEqual(@as(u64, if (mode == 0) 4 else if (mode == 5) 2 else 0), strict_stats.storage.added_nodes - fast_stats.storage.added_nodes);

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

test "a callable also used as handler state is materialized" {
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const callable = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = integer } } });
    const body = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(body, try b.pure(try b.constant(u64, 42)));
    const returns = try b.declare(&.{ callable, integer }, integer, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 1))));
    const handler = try b.handler(.{ .mode = .deep, .input = integer, .answer = integer, .state = &.{callable}, .return_function = returns, .clauses = &.{} });
    const entry = try b.declare(&.{}, integer, &.{}, &.{});
    const value = try b.lambda(body, callable);
    try b.define(entry, try b.term(.{ .handle = .{ .handler = handler, .body = value, .state = &.{value} } }));
    var compiled = try source.lower(testing.allocator, b.module(entry, unit));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    var saw_callable = false;
    while (session.terminal == null) {
        _ = try session.run(2);
        for (session.store.nodes.items, session.store.alive.items) |node, alive|
            if (alive and node == .computation) {
                saw_callable = true;
            };
    }
    const result = try session.observe();
    try testing.expect(result == .completed);
    try testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, result.completed.body.scalar[0..8], .little));
    try testing.expect(saw_callable);
}

test "sequence consumption reclaims intermediate cursors and preserves resident retry" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try @import("sequence_fixture.zig").build(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
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
    var previous: usize = 0;
    var reclaimed = false;
    var steps: usize = 0;
    while (session.terminal == null) : (steps += 1) {
        try testing.expect(steps < 400);
        try session.step();
        const live = session.store.nodes.items.len - session.store.free_nodes.items.len;
        if (steps < 255 and live < previous) reclaimed = true;
        try testing.expect(live < 40);
        previous = live;
    }
    try testing.expect(reclaimed);
    const result = try session.observe();
    try testing.expect(result == .completed);
    try testing.expectEqual(@as(u64, 2080), std.mem.readInt(u64, result.completed.body.scalar[0..8], .little));
    var rollback = try Session.restore(testing.allocator, &prepared, initial);
    defer rollback.deinit();
    rollback.collection_cursors = 24;
    var transaction = try rollback.begin();
    _ = try rollback.run(null);
    try testing.expect(rollback.collection_cursors != 24);
    transaction.rollback(&rollback);
    try testing.expectEqual(@as(usize, 24), rollback.collection_cursors);
    const unchanged = try rollback.checkpoint(testing.allocator);
    defer testing.allocator.free(unchanged);
    try testing.expectEqualSlices(u8, initial, unchanged);
    for ([_]bool{ false, true }) |with_checkpoint|
        try residentFailureSweep(&prepared, initial, .none, with_checkpoint);
}

test "mutual tail entry reuses its active control and restores each changed frame" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.recursive(&builder));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer testing.allocator.free(image);
    var prepared = try @import("stable_runtime").Prepared.init(testing.allocator, image);
    defer prepared.deinit();
    var session = try Session.start(testing.allocator, &prepared, &.{ 8, 0, 0, 0, 0, 0, 0, 0 });
    defer session.deinit();
    const initial = try session.checkpoint(testing.allocator);
    defer testing.allocator.free(initial);
    const control = session.roots.current.?;
    var function = (try session.frames.get(control.id)).function;
    var changes: usize = 0;
    var steps: usize = 0;
    while (session.terminal == null) : (steps += 1) {
        try testing.expect(steps < 256);
        try session.step();
        if (session.terminal != null) break;
        try testing.expectEqual(control, session.roots.current.?);
        const frame = try session.frames.get(control.id);
        if (frame.function != function) {
            changes += 1;
            function = frame.function;
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
    for ([_]bool{ false, true }) |with_checkpoint|
        try residentFailureSweep(&prepared, initial, .none, with_checkpoint);
}

test "handler returns consume the original caller continuation without losing live results" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try source.lower(testing.allocator, try source.examples.installations(&builder, 8));
    defer compiled.deinit();
    var session = try initFromImage(testing.allocator, compiled.program, &.{});
    defer session.deinit();
    const caller = session.roots.current.?;
    const function = (try session.frames.get(caller.id)).function;
    var returns: usize = 0;
    var was_caller = true;
    while (session.terminal == null) {
        try testing.expect(session.transitions < 256);
        try session.step();
        if (session.terminal != null) break;
        const current = session.roots.current.?;
        const is_caller = (try session.frames.get(current.id)).function == function;
        if (is_caller) {
            try testing.expectEqual(caller, current);
            if (!was_caller) returns += 1;
        }
        was_caller = is_caller;
    }
    try testing.expectEqual(@as(usize, 8), returns);
    const result = try session.observe();
    try testing.expect(result == .completed);
    try testing.expectEqual(@as(u64, 36), std.mem.readInt(u64, result.completed.body.scalar[0..8], .little));
}
