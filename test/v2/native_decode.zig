//! The baseline generator is fixed to Horos 4.0.0 / Kosmos 7.0.0.
const std = @import("std");
const horos = @import("horos");
const kosmos = @import("kosmos");
const a = std.testing.allocator;

fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

test "predecessor large checkpoint recovery" {
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    const bytes = try builder.schema(.bytes);
    const unit = try builder.scalar(void);
    const entry = try builder.declare(&.{bytes}, bytes, &.{}, &.{});
    const returned = try builder.pure(try builder.reference(builder.parameter(entry, 0)));
    try builder.define(entry, try builder.term(.{ .yield_then = returned }));
    var compiled = try horos.program.compile(a, builder.module(entry, unit));
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    try std.testing.expectEqual(52, image.len);
    var frozen_image: [52]u8 = undefined;
    _ = try std.fmt.hexToBytes(&frozen_image, "41424c5f4250493303000000200000000000000001000001020a0000000100000100010000020000070100000000000000000000");
    try std.testing.expectEqualSlices(u8, &frozen_image, image);
    // Restore against historical bytes, never a silently recompiled substitute.
    var prepared = try kosmos.Prepared.init(a, &frozen_image);
    defer prepared.deinit();
    const hashes = [_][]const u8{
        "a19f3827192ce60a69401b1ca504402f9e1ca43bcebadbf1e12f2f9acb85cad6",
        "845de6efada7810fcb4068b503e2cee0060f15ce38f48af70316cfcf8eb733eb",
        "200ccebcae2790b1698e95595d83e1f58a11a526318a85f5f8b07e9555322d63",
    };
    const lengths = [_]usize{ 1_048_658, 67_108_692, 68_157_524 };
    for ([_]usize{ 1_048_576, 67_108_608, 68_157_440 }, hashes, lengths) |size, hash, length| {
        var measure: horos.data.wire.Writer = .{};
        try measure.natural(size);
        const argument = try a.alloc(u8, measure.position + size);
        defer a.free(argument);
        var writer: horos.data.wire.Writer = .{ .output = argument };
        try writer.natural(size);
        @memset(argument[writer.position..], 0x39);
        var resident = try kosmos.Resident.start(a, &prepared, argument);
        var yielded = try resident.drive(a, .none, .{});
        defer yielded.deinit();
        try std.testing.expect(yielded.record == .yielded);
        const checkpoint = try resident.takeCheckpoint(a);
        defer a.free(checkpoint);
        try std.testing.expectError(error.InvalidState, resident.drive(a, .none, .{}));
        try std.testing.expectEqual(length, checkpoint.len);
        var expected_hash: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected_hash, hash);
        try std.testing.expectEqualSlices(u8, &expected_hash, &digest(checkpoint));
        // Includes the below-64-MiB encoded state whose records exceed the budget.
        if (size != 1_048_576)
            try std.testing.expectError(error.Capacity, horos.data.state_image.decodeGraphLimited(a, checkpoint, .{ .max_decoded_bytes = 64 << 20 }));
        var restored = try kosmos.Resident.restore(a, &prepared, checkpoint);
        var result = try restored.drive(a, .resume_yield, .{});
        defer result.deinit();
        try std.testing.expect(result.record == .completed);
        try std.testing.expectEqualSlices(u8, argument, result.record.completed);
        try restored.close();
        if (size == 68_157_440) {
            const input: horos.data.invocation.Input = .{ .image = &frozen_image, .instance = .{ .state = checkpoint }, .control = .resume_yield };
            {
                var typed = try kosmos.invocation.invoke(a, input);
                defer typed.deinit();
                try std.testing.expectEqualSlices(u8, argument, typed.record.completed);
            }
            const encoded = try horos.data.invocation.encodeOwned(horos.data.invocation.Input, a, input);
            defer a.free(encoded);
            const output = try kosmos.invocation.invokeBytes(a, encoded);
            defer a.free(output);
            var decoded = try horos.data.invocation.decode(horos.data.invocation.Outcome, a, output);
            defer decoded.deinit();
            try std.testing.expectEqualSlices(u8, argument, decoded.value.completed);
        }
    }
}

test "restore allocation failures release partial owners and preserve the input for retry" {
    var image: [52]u8 = undefined;
    _ = try std.fmt.hexToBytes(&image, "41424c5f4250493303000000200000000000000001000001020a0000000100000100010000020000070100000000000000000000");
    var prepared = try kosmos.Prepared.init(a, &image);
    defer prepared.deinit();
    var original = try kosmos.Resident.start(a, &prepared, &.{ 1, 0x39 });
    var yielded = try original.drive(a, .none, .{});
    defer yielded.deinit();
    const checkpoint = try original.takeCheckpoint(a);
    defer a.free(checkpoint);
    var failure: usize = 0;
    while (true) : (failure += 1) {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = failure });
        var restored = kosmos.Resident.restore(failing.allocator(), &prepared, checkpoint) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        var result = try restored.drive(a, .resume_yield, .{});
        defer result.deinit();
        try std.testing.expectEqualSlices(u8, &.{ 1, 0x39 }, result.record.completed);
        try restored.close();
        try std.testing.expect(failure > 0);
        break;
    }
}

test "public Prepared and ERS3 reply admission accept large native bytes" {
    const data = horos.data;
    const count = 65 << 20;
    var measure: data.wire.Writer = .{};
    try measure.natural(count);
    const value = try a.alloc(u8, measure.position + count);
    defer a.free(value);
    var writer: data.wire.Writer = .{ .output = value };
    try writer.natural(count);
    @memset(value[writer.position..], 0x39);
    {
        const program: data.activation.Program = .{
            .roots = .{ .entry = 0, .result = 0, .failure = 1 },
            .schemas = &.{ .bytes, .unit },
            .constants = &.{.{ .schema = 0, .bytes = value }},
            .effects = &.{},
            .functions = &.{.{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 }},
            .blocks = &.{.{ .function = 0, .instructions = &.{.{ .destination = 0, .opcode = .constant }}, .terminator = .{ .return_value = 0 } }},
        };
        const image = try a.alloc(u8, try data.program_image.encodedLength(program));
        defer a.free(image);
        _ = try data.program_image.encode(a, program, image);
        var prepared = try kosmos.Prepared.init(a, image);
        defer prepared.deinit();
        var resident = try kosmos.Resident.start(a, &prepared, &.{});
        var result = try resident.drive(a, .none, .{});
        defer result.deinit();
        try std.testing.expectEqualSlices(u8, value, result.record.completed);
        try resident.close();
    }
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const bytes = try b.schema(.bytes);
    const unit = try b.scalar(void);
    const effect = try b.effect(.{ .identity = "native/large-reply", .payload = unit, .result = bytes });
    const entry = try b.declare(&.{}, bytes, &.{effect}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{ .effect = effect, .payload = try b.constant(void, {}) } }));
    var compiled = try horos.program.compile(a, b.module(entry, unit));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    var prepared = try kosmos.Prepared.init(a, image);
    defer prepared.deinit();
    var resident = try kosmos.Resident.start(a, &prepared, &.{});
    var pending = try resident.drive(a, .none, .{});
    defer pending.deinit();
    var request = try data.invocation.decode(data.invocation.Request, a, pending.record.requested.request);
    defer request.deinit();
    const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = request.value.request_identity, .value = value });
    defer a.free(reply);
    var result = try resident.drive(a, .{ .reply = reply }, .{});
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, value, result.record.completed);
    try resident.close();
}

test "native execution can grow beyond the old decoder allowance before checkpoint transfer" {
    const data = horos.data;
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const bytes = try b.schema(.bytes);
    const unit = try b.scalar(void);
    const entry = try b.declare(&.{bytes}, bytes, &.{}, &.{});
    const input = try b.reference(b.parameter(entry, 0));
    const grown = try b.variable(bytes);
    const concatenated = try b.value(.{ .schema = bytes, .expression = .{ .primitive = .{
        .opcode = .blob_concat,
        .operands = &.{ input, input },
        .failures = &.{.{ .kind = .capacity_exceeded, .value = try b.failureLiteral(try b.constant(void, {})) }},
    } } });
    try b.define(entry, try b.bind(grown, try b.pure(concatenated), try b.term(.{ .yield_then = try b.pure(try b.reference(grown)) })));
    var compiled = try horos.program.compile(a, b.module(entry, unit));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    var prepared = try kosmos.Prepared.init(a, image);
    defer prepared.deinit();
    const size = 34 << 20;
    var measure: data.wire.Writer = .{};
    try measure.natural(size);
    const argument = try a.alloc(u8, measure.position + size);
    defer a.free(argument);
    var writer: data.wire.Writer = .{ .output = argument };
    try writer.natural(size);
    @memset(argument[writer.position..], 0x39);
    var resident = try kosmos.Resident.start(a, &prepared, argument);
    var published = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer published.deinit();
    try std.testing.expect(published.outcome.record.record == .yielded);
    const receipt = published.checkpoint.?;
    try std.testing.expect(receipt.bytes().len > 64 << 20);
    try resident.transferCheckpoint(receipt);
    var restored = try kosmos.Resident.restore(a, &prepared, receipt.bytes());
    var result = try restored.drive(a, .resume_yield, .{});
    defer result.deinit();
    var reader: data.wire.Reader = .{ .input = result.record.completed };
    try std.testing.expectEqual(size * 2, try reader.natural());
    const payload = result.record.completed[reader.position..];
    try std.testing.expectEqual(size * 2, payload.len);
    try std.testing.expect(std.mem.allEqual(u8, payload, 0x39));
    try restored.close();
}

test "large bytes retained only by a parked multi-shot template survive transfer and repeated activation" {
    const data = horos.data;
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const bytes = try b.schema(.bytes);
    const unit = try b.scalar(void);
    const effect = try b.effect(.{ .identity = "native/large-template", .payload = unit, .result = unit, .external = false, .control_use = .multi });
    const cap = try b.schema(.{ .internal = .{ .capability = effect } });
    const token = try b.schema(.{ .internal = .{ .resumption = .{ .effect = effect, .input = unit, .answer = bytes, .capture_bound = &.{ bytes, cap, unit }, .handled = &.{effect}, .mode = .deep, .use = .multi } } });
    const returns = try b.declare(&.{bytes}, bytes, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    const clause = try b.declare(&.{ unit, token }, bytes, &.{}, &.{});
    const resume_term = try b.term(.{ .resume_value = .{ .resumption = try b.reference(b.parameter(clause, 1)), .argument = try b.constant(void, {}) } });
    try b.define(clause, try b.term(.{ .yield_then = try b.bind(try b.variable(bytes), resume_term, resume_term) }));
    const handler = try b.handler(.{ .mode = .deep, .input = bytes, .answer = bytes, .return_function = returns, .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }} });
    const body = try b.declare(&.{ cap, bytes }, bytes, &.{effect}, &.{});
    try b.define(body, try b.bind(try b.variable(unit), try b.term(.{ .perform = .{ .effect = effect, .capability = try b.reference(b.parameter(body, 0)), .payload = try b.constant(void, {}) } }), try b.pure(try b.reference(b.parameter(body, 1)))));
    const signature = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{ cap, bytes }, .result = bytes, .effects = &.{effect} } } });
    const entry = try b.declare(&.{bytes}, bytes, &.{}, &.{});
    try b.define(entry, try b.term(.{ .handle = .{ .handler = handler, .body = try b.lambda(body, signature), .arguments = &.{try b.reference(b.parameter(entry, 0))} } }));
    var compiled = try horos.program.compile(a, b.module(entry, unit));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    var prepared = try kosmos.Prepared.init(a, image);
    defer prepared.deinit();
    const size = 65 << 20;
    var measure: data.wire.Writer = .{};
    try measure.natural(size);
    const argument = try a.alloc(u8, measure.position + size);
    defer a.free(argument);
    var writer: data.wire.Writer = .{ .output = argument };
    try writer.natural(size);
    @memset(argument[writer.position..], 0x39);
    var resident = try kosmos.Resident.start(a, &prepared, argument);
    var published = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer published.deinit();
    try std.testing.expect(published.outcome.record.record == .yielded);
    const receipt = published.checkpoint.?;
    try std.testing.expect(receipt.bytes().len > 64 << 20);
    {
        var decoded = try data.state_image.decodeGraph(a, receipt.bytes());
        defer decoded.deinit();
        var templates: usize = 0;
        for (decoded.state.nodes) |node| if (node.record == .multi_template) {
            templates += 1;
        };
        try std.testing.expectEqual(1, templates);
    }
    try resident.transferCheckpoint(receipt);
    var restored = try kosmos.Resident.restore(a, &prepared, receipt.bytes());
    var statistics: kosmos.Statistics = .{};
    try restored.setStatistics(&statistics);
    var result = try restored.drive(a, .resume_yield, .{});
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, argument, result.record.completed);
    try std.testing.expectEqual(2, statistics.branch_activations);
    try restored.close();
}
