//! Program-local capture admission remains valid across native checkpoint restore.
const std = @import("std");
const h = @import("horos");
const d = h.data;
const k = @import("kosmos");
const a = std.testing.allocator;
const p: d.activation.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64,                                                                                                                                                        .unit,
        .{ .internal = .{ .computation = .{ .parameters = &.{3}, .result = 0, .effects = &.{0}, .capture_bound = &.{0}, .use = .reusable } } },                      .{ .internal = .{ .capability = 0 } },
        .{ .internal = .{ .resumption = .{ .effect = 0, .input = 0, .answer = 0, .handled = &.{0}, .capture_bound = &.{ 0, 3 }, .mode = .deep, .use = .linear } } }, .{ .internal = .{ .resumption = .{ .effect = 0, .input = 0, .answer = 0, .handled = &.{0}, .capture_bound = &.{}, .mode = .deep, .use = .linear } } },
    },
    .constants = &.{ .{ .schema = 1, .bytes = &.{} }, .{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } } },
    .effects = &.{.{ .identity = "local-capture/state-probe", .payload = 1, .result = 0, .external = false }},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 2, 0 } }, .result = 0 },
        .{ .entry = 2, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 3, 1, 0 } }, .result = 0, .effects = &.{0} },
        .{ .entry = 5, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 6, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 1, 4, 0 } }, .result = 0 },
        .{ .entry = 8, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 1, 5, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{.{ .destination = 1, .opcode = .computation, .operands = &.{0} }}, .terminator = .{ .handle = .{ .handler = 0, .body = 1, .arguments = &.{}, .state = &.{}, .next = .{ .block = 1, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .yield_value = .{ .block = 3 } } },
        .{ .function = 1, .instructions = &.{.{ .destination = 2, .opcode = .constant }}, .terminator = .{ .perform = .{ .effect = 0, .capability = 1, .payload = 2, .next = .{ .block = 4, .assignments = &.{.{ .destination = 3, .source = .returned }} } } } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 3, .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 1 }}, .terminator = .{ .resume_value = .{ .resumption = 1, .argument = 2, .next = .{ .block = 7, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } },
        .{ .function = 3, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        .{ .function = 4, .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 1 }}, .terminator = .{ .resume_value = .{ .resumption = 1, .argument = 2, .next = .{ .block = 9, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } },
        .{ .function = 4, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
    },
    .handlers = &.{
        .{ .mode = .deep, .input = 0, .answer = 0, .return_function = 2, .clauses = &.{.{ .effect = 0, .function = 3, .resumption = 4 }} },
        .{ .mode = .deep, .input = 0, .answer = 0, .return_function = 2, .clauses = &.{.{ .effect = 0, .function = 4, .resumption = 5 }} },
    },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 2 }},
    .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
};
fn release(r: *k.Resident) void {
    if (!r.live) return;
    r.close() catch {
        const bytes = r.takeCheckpoint(a) catch unreachable;
        a.free(bytes);
    };
}
test "checkpoint restore qualifies runtime bindings against capture provenance" {
    var admitted = try d.activation_ownership.analyze(a, p);
    admitted.deinit();
    const encoded = try a.alloc(u8, try d.program_image.encodedLength(p));
    defer a.free(encoded);
    _ = try d.program_image.encode(a, p, encoded);
    var prepared = try k.Prepared.init(a, encoded);
    defer prepared.deinit();
    var r = try k.Resident.start(a, &prepared, &.{ 9, 0, 0, 0, 0, 0, 0, 0 });
    defer release(&r);
    var pubn = try r.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer pubn.deinit();
    var authentic = try k.Resident.restore(a, &prepared, pubn.checkpoint.?.bytes());
    defer release(&authentic);
    var captured = try authentic.publish(.{ .record = a }, .resume_yield, .{ .quantum = 2, .checkpoint = .receipt });
    defer captured.deinit();
    var captured_state = try d.state_image.decodeGraph(a, captured.checkpoint.?.bytes());
    defer captured_state.deinit();
    try d.state_admission.validateStable(a, p, captured_state.state);
    var continuation = try k.Resident.restore(a, &prepared, captured.checkpoint.?.bytes());
    defer release(&continuation);
    var finished = try continuation.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer finished.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 9, 0, 0, 0, 0, 0, 0, 0 }, finished.outcome.record.record.completed);
    var state = try d.state_image.decodeGraph(a, pubn.checkpoint.?.bytes());
    defer state.deinit();
    const nodes = try a.dupe(d.process_state.Node, state.state.nodes);
    defer a.free(nodes);
    var modified = state.state;
    modified.nodes = nodes;
    var changed: usize = 0;
    for (nodes) |*node| if (node.record == .handler) {
        node.record.handler.definition = 1;
        changed += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), changed);
    const wire = try d.state_image.serialize(a, modified, .{ .allocate = a }, null);
    defer a.free(wire.bytes.?);
    try std.testing.expectError(error.InvalidOwnership, k.Resident.restore(a, &prepared, wire.bytes.?));
}

fn effectFreeHelperFixture(allocator: std.mem.Allocator) !d.activation.Program {
    var program = p;
    const schemas = try allocator.dupe(d.program.Schema, p.schemas);
    schemas[2].internal.computation.effects = &.{};
    const functions = try allocator.alloc(d.activation.Function, p.functions.len + 1);
    @memcpy(functions[0..p.functions.len], p.functions);
    functions[1].effects = &.{};
    functions[5] = .{ .entry = 10, .inputs = &.{0}, .layout = .{ .slots = &.{3} }, .result = 3 };
    const blocks = try allocator.alloc(d.activation.Block, p.blocks.len + 2);
    @memcpy(blocks[0..p.blocks.len], p.blocks);
    blocks[0].terminator.handle.handler = 1;
    blocks[2].terminator = .{ .call = .{ .function = 5, .arguments = &.{1}, .next = .{ .block = 4, .assignments = &.{.{ .destination = 1, .source = .returned }} } } };
    blocks[3].instructions = &.{};
    blocks[3].terminator = .{ .return_value = 0 };
    blocks[10] = .{ .function = 5, .instructions = &.{}, .terminator = .{ .yield_value = .{ .block = 11 } } };
    blocks[11] = .{ .function = 5, .instructions = &.{}, .terminator = .{ .return_value = 0 } };
    program.schemas = schemas;
    program.functions = functions;
    program.blocks = blocks;
    return program;
}

test "effect-free yielding helper preserves an excluded caller capture on restore" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const program = try effectFreeHelperFixture(alloc);
    var diagnostic: d.admission.Diagnostic = .{};
    var admitted = d.activation_ownership.analyzeDiagnosed(a, program, &diagnostic) catch |err| {
        std.debug.print("effect-free program rejected {t}: {any}\n", .{ err, diagnostic });
        return err;
    };
    admitted.deinit();
    const encoded = try alloc.alloc(u8, try d.program_image.encodedLength(program));
    _ = try d.program_image.encode(alloc, program, encoded);
    var prepared = try k.Prepared.init(a, encoded);
    defer prepared.deinit();
    const expected = [_]u8{ 9, 0, 0, 0, 0, 0, 0, 0 };
    var resident = try k.Resident.start(a, &prepared, &expected);
    defer release(&resident);
    var checkpoint = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer checkpoint.deinit();
    var state = try d.state_image.decodeGraph(a, checkpoint.checkpoint.?.bytes());
    defer state.deinit();
    try std.testing.expectEqual(d.process_state.Status.yielded, state.state.status);
    const current = state.state.nodes[@intCast(state.state.roots.current.?.id)];
    try std.testing.expectEqual(@as(d.program.Id, 11), current.record.control.block);
    var saved_caller = false;
    for (state.state.nodes) |node| if (node.record == .continuation and node.record.continuation.source_block == 2) {
        for (node.activation.?.bindings) |binding| if (binding.slot == 0) {
            try std.testing.expectEqual(@as(d.program.Id, 0), binding.value.schema);
            saved_caller = true;
        };
    };
    try std.testing.expect(saved_caller);
    var uninterrupted = try resident.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
    defer uninterrupted.deinit();
    try std.testing.expectEqualSlices(u8, &expected, uninterrupted.outcome.record.record.completed);
    d.state_admission.validateStable(a, program, state.state) catch |err| {
        std.debug.print("effect-free checkpoint rejected {t}\n", .{err});
        return err;
    };
    var restored = try k.Resident.restore(a, &prepared, checkpoint.checkpoint.?.bytes());
    defer release(&restored);
    var finished = try restored.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
    defer finished.deinit();
    try std.testing.expectEqualSlices(u8, uninterrupted.outcome.record.record.completed, finished.outcome.record.record.completed);
}

const CleanupEffect = enum { absent, unused, performed };

fn cleanupFixture(allocator: std.mem.Allocator, effect: CleanupEffect, yield_body: bool) !d.activation.Program {
    var program = p;
    const schemas = try allocator.alloc(d.program.Schema, 15);
    @memcpy(schemas[0..6], p.schemas);
    schemas[2].internal.computation.effects = if (effect == .absent) &.{} else &.{0};
    schemas[6] = .{ .internal = .{ .computation = .{ .parameters = &.{}, .result = 3, .effects = &.{}, .capture_bound = &.{3} } } };
    schemas[7] = .{ .internal = .{ .computation = .{ .parameters = &.{14}, .result = 1, .effects = if (effect == .absent) &.{} else &.{0}, .capture_bound = if (effect == .absent) &.{} else &.{3} } } };
    schemas[8] = .text;
    schemas[9] = .bytes;
    schemas[10] = .{ .sum = &.{ 8, 9 } };
    schemas[11] = .{ .sum = &.{ 1, 1, 10, 1 } };
    schemas[12] = .{ .sum = &.{ 1, 10 } };
    schemas[13] = .{ .seq = 1 };
    schemas[14] = .{ .product = &.{ 11, 12, 13 } };
    const functions = try allocator.alloc(d.activation.Function, 7);
    @memcpy(functions[0..5], p.functions);
    functions[1].effects = if (effect == .absent) &.{} else &.{0};
    functions[1].layout.slots = &.{ 0, 3, 1, 0, 6, 7 };
    functions[5] = .{ .entry = 10, .inputs = &.{0}, .layout = .{ .slots = &.{3} }, .result = 3 };
    functions[6] = .{ .entry = 11, .inputs = &.{0}, .layout = .{ .slots = &.{ 14, 1 } }, .result = 1 };
    if (effect != .absent) functions[6] = .{ .entry = 11, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 3, 14, 1, 0 } }, .result = 1, .effects = &.{0} };
    const blocks = try allocator.alloc(d.activation.Block, 15);
    @memcpy(blocks[0..10], p.blocks);
    blocks[0].terminator.handle.handler = 1;
    blocks[2].instructions = try allocator.dupe(d.activation.Instruction, &.{
        .{ .destination = 4, .opcode = .computation, .operands = &.{1}, .immediate = 1 },
        .{ .destination = 5, .opcode = .computation, .immediate = 2, .operands = if (effect == .absent) &.{} else &.{1} },
    });
    blocks[2].terminator = .{ .protect = .{ .body = 4, .cleanup = 5, .arguments = &.{}, .next = .{ .block = 4, .assignments = &.{.{ .destination = 1, .source = .returned }} } } };
    blocks[3].instructions = &.{};
    blocks[3].terminator = .{ .return_value = 0 };
    blocks[10] = .{ .function = 5, .instructions = &.{}, .terminator = .{ .return_value = 0 } };
    blocks[11] = .{ .function = 6, .instructions = &.{}, .terminator = .{ .yield_value = .{ .block = 12 } } };
    blocks[12] = .{ .function = 6, .instructions = &.{.{ .destination = 1, .opcode = .constant }}, .terminator = .{ .return_value = 1 } };
    blocks[13] = .{ .function = 5, .instructions = &.{}, .terminator = .{ .return_value = 0 } };
    if (yield_body) blocks[10].terminator = .{ .yield_value = .{ .block = 13 } };
    blocks[14] = .{ .function = 6, .instructions = &.{}, .terminator = .{ .return_value = if (effect == .absent) @as(d.program.Id, 1) else 2 } };
    if (effect != .absent) blocks[12] = .{ .function = 6, .instructions = &.{.{ .destination = 2, .opcode = .constant }}, .terminator = .{ .return_value = 2 } };
    if (effect == .performed) {
        // Preserve the caller integer only under the broad handler. Both
        // handlers permit the cleanup's own live unit value across its perform.
        schemas[4].internal.resumption.capture_bound = &.{ 0, 1, 3 };
        schemas[5].internal.resumption.capture_bound = &.{ 1, 3 };
        schemas[4].internal.resumption.obligations = true;
        schemas[5].internal.resumption.obligations = true;
        blocks[12].terminator = .{ .perform = .{ .effect = 0, .capability = 0, .payload = 2, .next = .{ .block = 14, .assignments = &.{.{ .destination = 3, .source = .returned }} } } };
    }
    program.schemas = schemas;
    program.functions = functions;
    program.blocks = blocks;
    program.constructors = try allocator.dupe(d.program.Constructor, &.{ p.constructors[0], .{ .function = 5, .capture = 1, .schema = 6 }, .{ .function = 6, .capture = 2, .schema = 7 } });
    program.scopes.captures = try allocator.dupe(d.program.Capture, &.{ p.scopes.captures[0], .{ .fields = &.{3}, .use = .reusable }, .{ .fields = if (effect == .absent) &.{} else &.{3}, .use = .reusable } });
    return program;
}

test "effect-free cleanup yielded with returned capability remains restorable" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const program = try cleanupFixture(alloc, .absent, false);
    var diagnostic: d.admission.Diagnostic = .{};
    var admitted = d.activation_ownership.analyzeDiagnosed(a, program, &diagnostic) catch |err| {
        std.debug.print("cleanup program rejected {t}: {any}\n", .{ err, diagnostic });
        return err;
    };
    admitted.deinit();
    const encoded = try alloc.alloc(u8, try d.program_image.encodedLength(program));
    _ = try d.program_image.encode(alloc, program, encoded);
    var prepared = try k.Prepared.init(a, encoded);
    defer prepared.deinit();
    const expected = [_]u8{ 9, 0, 0, 0, 0, 0, 0, 0 };
    var resident = try k.Resident.start(a, &prepared, &expected);
    defer release(&resident);
    var checkpoint = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer checkpoint.deinit();
    var state = try d.state_image.decodeGraph(a, checkpoint.checkpoint.?.bytes());
    defer state.deinit();
    try std.testing.expectEqual(d.process_state.Status.yielded, state.state.status);
    const current = state.state.nodes[@intCast(state.state.roots.current.?.id)];
    try std.testing.expectEqual(@as(d.program.Id, 12), current.record.control.block);
    const cleanup_return = state.state.nodes[@intCast(current.record.control.parent.?.id)].record.cleanup_return;
    const normal = state.state.nodes[@intCast(cleanup_return.exit.id)].record.exit.reason.normal;
    try std.testing.expectEqual(@as(d.program.Id, 3), normal.schema);
    try std.testing.expectEqual(current.record.control.evidence.?.id, normal.body.reference.id);
    var saved_caller = false;
    for (state.state.nodes) |node| if (node.record == .continuation and node.record.continuation.source_block == 2) {
        for (node.activation.?.bindings) |binding| if (binding.slot == 0) {
            try std.testing.expectEqual(@as(d.program.Id, 0), binding.value.schema);
            saved_caller = true;
        };
    };
    try std.testing.expect(saved_caller);
    var uninterrupted = try resident.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
    defer uninterrupted.deinit();
    try std.testing.expectEqualSlices(u8, &expected, uninterrupted.outcome.record.record.completed);
    d.state_admission.validateStable(a, program, state.state) catch |err| {
        std.debug.print("cleanup checkpoint rejected {t}\n", .{err});
        return err;
    };
    var restored = try k.Resident.restore(a, &prepared, checkpoint.checkpoint.?.bytes());
    defer release(&restored);
    var finished = try restored.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
    defer finished.deinit();
    try std.testing.expectEqualSlices(u8, uninterrupted.outcome.record.record.completed, finished.outcome.record.record.completed);
}

test "cleanup suspension summaries preserve checkpoint completion and cancellation" {
    for ([_]CleanupEffect{ .unused, .performed }) |effect| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var program = try cleanupFixture(alloc, effect, true);
        if (effect == .performed) {
            try std.testing.expectError(error.InvalidOwnership, d.activation_ownership.analyze(a, program));
            const blocks = try alloc.dupe(d.activation.Block, program.blocks);
            blocks[0].terminator.handle.handler = 0;
            program.blocks = blocks;
        }
        const bytes = try alloc.alloc(u8, try d.program_image.encodedLength(program));
        _ = try d.program_image.encode(alloc, program, bytes);
        var prepared = try k.Prepared.init(a, bytes);
        defer prepared.deinit();
        const expected = [_]u8{ 9, 0, 0, 0, 0, 0, 0, 0 };
        var resident = try k.Resident.start(a, &prepared, &expected);
        defer release(&resident);
        var checkpoint = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
        defer checkpoint.deinit();
        try std.testing.expect(checkpoint.outcome.record.record == .yielded);
        var restored = try k.Resident.restore(a, &prepared, checkpoint.checkpoint.?.bytes());
        defer release(&restored);
        var cleanup = try resident.publish(.{ .record = a }, .resume_yield, .{});
        defer cleanup.deinit();
        var restored_cleanup = try restored.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
        defer restored_cleanup.deinit();
        try std.testing.expect(cleanup.outcome.record.record == .yielded);
        try std.testing.expect(restored_cleanup.outcome.record.record == .yielded);
        var during_cleanup = try k.Resident.restore(a, &prepared, restored_cleanup.checkpoint.?.bytes());
        defer release(&during_cleanup);
        var uninterrupted = try resident.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
        defer uninterrupted.deinit();
        var finished = try during_cleanup.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
        defer finished.deinit();
        try std.testing.expectEqualSlices(u8, &expected, finished.outcome.record.record.completed);
        try std.testing.expectEqualSlices(u8, uninterrupted.checkpoint.?.bytes(), finished.checkpoint.?.bytes());
        var cancelled = try k.Resident.restore(a, &prepared, checkpoint.checkpoint.?.bytes());
        defer release(&cancelled);
        var cancel_cleanup = try cancelled.publish(.{ .record = a }, .{ .cancel = .{ .text = "stop" } }, .{ .checkpoint = .receipt });
        defer cancel_cleanup.deinit();
        try std.testing.expect(cancel_cleanup.outcome.record.record == .yielded);
        var cancelling = try k.Resident.restore(a, &prepared, cancel_cleanup.checkpoint.?.bytes());
        defer release(&cancelling);
        var stopped = try cancelling.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
        defer stopped.deinit();
        try std.testing.expectEqualStrings("stop", stopped.outcome.record.record.cancelled.reason.text);
        var restored_stop = try k.Resident.restore(a, &prepared, stopped.checkpoint.?.bytes());
        defer release(&restored_stop);
    }
}

// The outer handler excludes the caller's retained integer. The shallow token
// carries its capability solely as an argument to an effect-free function.
// Discarding that token executes neither this function nor the capability.
fn retainedTokenCapabilityFixture(b: *h.source.Builder) !h.source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const unit_value = try b.constant(void, {});
    const outer_effect = try b.effect(.{ .identity = "outer", .payload = unit, .result = unit, .external = false });
    const token_effect = try b.effect(.{ .identity = "token", .payload = unit, .result = unit, .external = false });
    const outer_capability = try b.schema(.{ .internal = .{ .capability = outer_effect } });
    const token_capability = try b.schema(.{ .internal = .{ .capability = token_effect } });
    const token_schema = try b.reserveSchema();
    try b.defineSchema(token_schema, .{ .internal = .{ .resumption = .{ .effect = token_effect, .input = unit, .answer = unit, .effects = &.{token_effect}, .handled = &.{token_effect}, .capture_bound = &.{ unit, integer, outer_capability, token_capability }, .mode = .shallow, .use = .linear } } });
    const outer_resumption = try b.schema(.{ .internal = .{ .resumption = .{ .effect = outer_effect, .input = unit, .answer = integer, .effects = &.{token_effect}, .handled = &.{outer_effect}, .capture_bound = &.{ unit, outer_capability, token_capability, token_schema }, .mode = .deep, .use = .linear } } });
    const entry = try b.declare(&.{}, integer, &.{token_effect}, &.{});
    const outer_body = try b.declare(&.{outer_capability}, integer, &.{ outer_effect, token_effect }, &.{});
    const outer_return = try b.declare(&.{integer}, integer, &.{}, &.{});
    const outer_clause = try b.declare(&.{ unit, outer_resumption }, integer, &.{token_effect}, &.{});
    try b.define(outer_return, try b.pure(try b.reference(b.parameter(outer_return, 0))));
    try b.define(outer_clause, try b.term(.{ .yield_then = try b.term(.{ .resume_value = .{ .resumption = try b.reference(b.parameter(outer_clause, 1)), .argument = unit_value } }) }));
    const token_body = try b.declare(&.{token_capability}, unit, &.{token_effect}, &.{});
    const token_return = try b.declare(&.{unit}, token_schema, &.{}, &.{});
    const token_clause = try b.declare(&.{ unit, token_schema }, token_schema, &.{}, &.{});
    try b.define(token_return, try b.term(.{ .fail = unit_value }));
    try b.define(token_clause, try b.pure(try b.reference(b.parameter(token_clause, 1))));
    const ignore_capability = try b.declare(&.{outer_capability}, unit, &.{}, &.{});
    try b.define(ignore_capability, try b.pure(unit_value));
    const unused = try b.variable(unit);
    try b.define(token_body, try b.bind(unused, try b.term(.{ .perform = .{ .effect = token_effect, .capability = try b.reference(b.parameter(token_body, 0)), .payload = unit_value } }), try b.term(.{ .call = .{ .function = ignore_capability, .arguments = &.{try b.reference(b.parameter(outer_body, 0))} } })));
    const token_handler = try b.handler(.{ .mode = .shallow, .input = unit, .answer = token_schema, .return_function = token_return, .clauses = &.{.{ .effect = token_effect, .function = token_clause, .resumption = token_schema }} });
    const token_body_schema = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{token_capability}, .result = unit, .effects = &.{token_effect}, .capture_bound = &.{outer_capability} } } });
    const dispose_helper = try b.declare(&.{token_schema}, unit, &.{token_effect}, &.{});
    try b.define(dispose_helper, try b.term(.{ .yield_then = try b.bind(try b.variable(unit), try b.term(.{ .dispose = try b.reference(b.parameter(dispose_helper, 0)) }), try b.pure(unit_value)) }));
    const token = try b.variable(token_schema);
    const retained = try b.variable(integer);
    try b.define(outer_body, try b.bind(token, try b.term(.{ .handle = .{ .handler = token_handler, .body = try b.lambda(token_body, token_body_schema) } }), try b.bind(retained, try b.pure(try b.constant(u64, 42)), try b.bind(try b.variable(unit), try b.term(.{ .call = .{ .function = dispose_helper, .arguments = &.{try b.reference(token)} } }), try b.pure(try b.reference(retained))))));
    const outer_handler = try b.handler(.{ .mode = .deep, .input = integer, .answer = integer, .effects = &.{token_effect}, .return_function = outer_return, .clauses = &.{.{ .effect = outer_effect, .function = outer_clause, .resumption = outer_resumption }} });
    const outer_body_schema = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{outer_capability}, .result = integer, .effects = &.{ outer_effect, token_effect } } } });
    try b.define(entry, try b.term(.{ .handle = .{ .handler = outer_handler, .body = try b.lambda(outer_body, outer_body_schema) } }));
    return b.module(entry, unit);
}

test "unused capability inside a shallow token does not invent disposal capture" {
    var builder = h.source.Builder.init(a);
    defer builder.deinit();
    const module = try retainedTokenCapabilityFixture(&builder);
    var compiled = try h.program.compile(a, module);
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try d.program_image.encodedLength(compiled.program));
    defer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    var prepared = try k.Prepared.init(a, bytes);
    defer prepared.deinit();
    var resident = try k.Resident.start(a, &prepared, &.{});
    defer release(&resident);
    var checkpoint = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer checkpoint.deinit();
    try std.testing.expect(checkpoint.outcome.record.record == .yielded);
    var uninterrupted = try resident.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
    defer uninterrupted.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, uninterrupted.outcome.record.record.completed);
    var restored = try k.Resident.restore(a, &prepared, checkpoint.checkpoint.?.bytes());
    defer release(&restored);
    var finished = try restored.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
    defer finished.deinit();
    try std.testing.expectEqualSlices(u8, uninterrupted.checkpoint.?.bytes(), finished.checkpoint.?.bytes());
    var cancelled = try k.Resident.restore(a, &prepared, checkpoint.checkpoint.?.bytes());
    defer release(&cancelled);
    var stopped = try cancelled.publish(.{ .record = a }, .{ .cancel = .{ .text = "stop" } }, .{ .checkpoint = .receipt });
    defer stopped.deinit();
    try std.testing.expectEqualStrings("stop", stopped.outcome.record.record.cancelled.reason.text);
    var restored_stop = try k.Resident.restore(a, &prepared, stopped.checkpoint.?.bytes());
    defer release(&restored_stop);
}
