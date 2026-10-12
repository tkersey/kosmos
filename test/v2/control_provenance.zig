//! Program-local capture admission remains valid across native checkpoint restore.
const std = @import("std");
const d = @import("horos").data;
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
