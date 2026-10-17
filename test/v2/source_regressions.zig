//! Current regressions migrated from the predecessor compiler/runtime suite.
const std = @import("std");
const horos = @import("horos");
const data = horos.data;
const Session = @import("kosmos").Session;
const testing = std.testing;
const allocator = testing.allocator;
const borrow_returns = @import("borrow_return_fixtures");

fn programBytes(program: data.activation.Program) ![]u8 {
    const bytes = try allocator.alloc(u8, try data.program_image.encodedLength(program));
    errdefer allocator.free(bytes);
    _ = try data.program_image.encode(allocator, program, bytes);
    return bytes;
}

fn rejectState(program: data.activation.Program, image: []const u8, state: data.process_state.State, expected: anyerror) !void {
    const bytes = try data.state_image.emit(allocator, state);
    defer allocator.free(bytes);
    var canonical = try data.state_image.decodeGraph(allocator, bytes);
    defer canonical.deinit();
    try testing.expectError(expected, data.state_admission.validateStable(allocator, program, canonical.state));
    try testing.expectError(expected, Session.restoreImage(allocator, image, bytes));
}

fn slotValue(node: *data.process_state.Node, slot: u64) !*data.graph.Value {
    for (@constCast(node.activation.?.bindings)) |*binding|
        if (binding.slot == slot) return &binding.value;
    return error.MissingLiveSlot;
}

fn answerUnit(session: *Session) !void {
    var pending = try session.pendingRequest(allocator);
    defer pending.deinit();
    const response = try data.invocation.encodeOwned(data.invocation.Result, allocator, .{
        .request_identity = pending.request.request_identity,
        .value = &.{},
    });
    defer allocator.free(response);
    try session.answer(response);
}

test "current duplicate one-shot custody rejects while distinct tokens still resume" {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    var compiled = try horos.program.compile(allocator, try horos.source.examples.ownership(&b));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer allocator.free(image);
    var session = try Session.initImage(allocator, image, &.{});
    defer session.deinit();
    try testing.expect(try session.run(null) == .yielded);
    const checkpoint = try session.checkpoint(allocator);
    defer allocator.free(checkpoint);
    var saved = try data.state_image.decodeGraph(allocator, checkpoint);
    defer saved.deinit();
    const nodes = @constCast(saved.state.nodes);
    var first: ?data.graph.Value = null;
    var changed = false;
    for (nodes) |*node| if (node.activation) |frame| {
        for (@constCast(frame.bindings)) |*binding| {
            if (binding.value.body != .owned) continue;
            const target = nodes[@intCast(binding.value.body.owned.node.id)].record;
            if (target != .one_shot) continue;
            if (first) |other| {
                try testing.expectEqual(other.schema, binding.value.schema);
                try testing.expect(other.body.owned.node.id != binding.value.body.owned.node.id);
                const original = binding.value;
                binding.value = other;
                try rejectState(compiled.program, image, saved.state, error.InvalidOwnership);
                binding.value = original;
                changed = true;
                break;
            } else first = binding.value;
        }
        if (changed) break;
    };
    try testing.expect(changed);
    var restored = try Session.restoreImage(allocator, image, checkpoint);
    defer restored.deinit();
    try restored.resumeYield();
    const result = try restored.run(null);
    try testing.expect(result == .completed);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 0, 0, 0 }, try restored.bytes(&result.completed));
}

test "current cleanup rejects duplicate obligations and a forged running continuation" {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    var compiled = try horos.program.compile(allocator, try horos.source.examples.yieldingCleanup(&b));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer allocator.free(image);
    var session = try Session.initImage(allocator, image, &.{0});
    defer session.deinit();
    var duplicate = false;
    var running = false;
    for (0..512) |_| {
        const bytes = try session.checkpoint(allocator);
        defer allocator.free(bytes);
        var saved = try data.state_image.decodeGraph(allocator, bytes);
        defer saved.deinit();
        const nodes = @constCast(saved.state.nodes);
        var first: ?data.graph.OwnedRef = null;
        for (nodes) |*node| {
            const original = node.*;
            if (!duplicate and node.record == .protection) {
                if (first) |owned| {
                    node.record.protection.obligation = owned;
                    try rejectState(compiled.program, image, saved.state, error.InvalidOwnership);
                    node.* = original;
                    duplicate = true;
                } else first = node.record.protection.obligation;
            }
            if (!running and saved.state.roots.pending != null and node.record == .obligation and
                node.record.obligation.status == .running)
            {
                node.record.obligation.status.running = saved.state.roots.pending.?;
                try rejectState(compiled.program, image, saved.state, error.InvalidState);
                node.* = original;
                running = true;
            }
        }
        const restored = try Session.restoreImage(allocator, image, bytes);
        session.deinit();
        session = restored;
        if (session.isTerminal()) break;
        switch (try session.observe()) {
            .yielded => try session.resumeYield(),
            .requested => try answerUnit(&session),
            else => try session.step(),
        }
    }
    try testing.expect(duplicate and running);
    const result = try session.observe();
    try testing.expect(result == .failed);
    try testing.expectEqual(7, (try session.bytes(&result.failed))[0]);
}

test "current yielded cleanup preserves binary and text first cancellation through restore" {
    for ([_]u8{ 0, 1 }) |primary| {
        for ([_]data.invocation.Reason{ .{ .text = "stop" }, .{ .bytes = &.{ 0xff, 0 } } }) |reason| {
            var b = horos.source.Builder.init(allocator);
            defer b.deinit();
            var compiled = try horos.program.compile(allocator, try horos.source.examples.yieldingCleanup(&b));
            defer compiled.deinit();
            const image = try programBytes(compiled.program);
            defer allocator.free(image);
            var session = try Session.initImage(allocator, image, &.{primary});
            defer session.deinit();
            for (0..2) |round| {
                try testing.expect(try session.run(null) == .yielded);
                try session.cancel(if (round == 0) reason else .{ .text = "later" });
                const bytes = try session.checkpoint(allocator);
                defer allocator.free(bytes);
                const restored = try Session.restoreImage(allocator, image, bytes);
                session.deinit();
                session = restored;
                try testing.expect(try session.run(null) == .yielded);
                try session.resumeYield();
                const request = try session.run(null);
                try testing.expect(request == .requested);
                try testing.expectEqualStrings(if (round == 0)
                    "example/middle-cleanup"
                else
                    "example/outer-cleanup", compiled.program.effects[@intCast(request.requested.effect)].identity);
                try answerUnit(&session);
            }
            const result = try session.run(null);
            try testing.expect(result == .failed);
            try testing.expectEqual(if (primary == 0) @as(u8, 7) else 9, (try session.bytes(&result.failed))[0]);
            try testing.expectEqualDeep(reason, (try session.terminalExit()).cancellation.?);
        }
    }
}

test "current code admission rejects forged empty capture obligations" {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    var compiled = try horos.program.compile(allocator, try horos.source.examples.clauseAbort(&b));
    defer compiled.deinit();
    var program = compiled.program;
    const schemas = try allocator.dupe(data.program.Schema, program.schemas);
    defer allocator.free(schemas);
    program.schemas = schemas;
    var checked = false;
    for (schemas) |*schema| {
        if (schema.* != .internal or schema.internal != .resumption or
            !schema.internal.resumption.obligations) continue;
        const original = schema.*;
        for ([_]data.program.Use{ .affine, .multi }) |use| {
            schema.internal.resumption.obligations = false;
            schema.internal.resumption.use = use;
            try testing.expectError(error.InvalidOwnership, programBytes(program));
        }
        schema.* = original;
        checked = true;
    }
    try testing.expect(checked);
}

test "current suspended delimiters cannot terminate a live return spine" {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    var compiled = try horos.program.compile(allocator, try phaseReturnExample(&b));
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer allocator.free(image);
    var session = try Session.initImage(allocator, image, &.{});
    defer session.deinit();
    var checked = false;
    for (0..128) |_| {
        const checkpoint = try session.checkpoint(allocator);
        defer allocator.free(checkpoint);
        var saved = try data.state_image.decodeGraph(allocator, checkpoint);
        defer saved.deinit();
        const nodes = @constCast(saved.state.nodes);
        if (saved.state.roots.current) |current| {
            if (nodes[@intCast(current.id)].record == .control) {
                const control = nodes[@intCast(current.id)].record.control;
                if (control.parent) |parent| {
                    const node = &nodes[@intCast(parent.id)].record;
                    if (node.* == .attachment) {
                        node.attachment.phase = .suspended;
                        node.attachment.return_to = null;
                        for ([_]data.process_state.Status{ .active, .yielded }) |status| {
                            saved.state.status = status;
                            try rejectState(compiled.program, image, saved.state, error.InvalidState);
                        }
                        checked = true;
                    }
                }
            }
        }
        if (session.isTerminal()) break;
        try session.step();
    }
    try testing.expect(checked);
    const result = try session.observe();
    try testing.expect(result == .completed);
    try testing.expectEqualSlices(u8, &.{ 9, 0, 0, 0, 0, 0, 0, 0 }, try session.bytes(&result.completed));
}

fn rejectMalformedState(program: data.activation.Program, image: []const u8, state: data.process_state.State) !void {
    if (data.state_admission.validateStable(allocator, program, state)) |_| {
        return error.AcceptedMalformedState;
    } else |err| try testing.expect(err != error.OutOfMemory and err != error.Capacity);
    const bytes = data.state_image.emit(allocator, state) catch |err| {
        // Graph encoding itself refuses dangling references before producing bytes.
        try testing.expect(err != error.OutOfMemory and err != error.Capacity);
        return;
    };
    defer allocator.free(bytes);
    if (Session.restoreImage(allocator, image, bytes)) |accepted| {
        var owner = accepted;
        owner.deinit();
        return error.AcceptedMalformedCheckpoint;
    } else |err| try testing.expect(err != error.OutOfMemory and err != error.Capacity);
}

test "current pending contracts blobs and identity reject before publishing a request" {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    const bytes_type = try b.schema(.bytes);
    const unit = try b.scalar(void);
    const effect = try b.effect(.{ .identity = "admission/blob", .payload = bytes_type, .result = unit });
    const entry = try b.declare(&.{bytes_type}, unit, &.{effect}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.reference(b.parameter(entry, 0)),
    } }));
    var compiled = try horos.program.compile(allocator, b.module(entry, unit));
    defer compiled.deinit();
    const program = compiled.program;
    const image = try programBytes(program);
    defer allocator.free(image);
    var session = try Session.initImage(allocator, image, &.{ 1, 0x80 });
    defer session.deinit();
    try testing.expect(try session.run(null) == .requested);
    const checkpoint = try session.checkpoint(allocator);
    defer allocator.free(checkpoint);
    var saved = try data.state_image.decodeGraph(allocator, checkpoint);
    defer saved.deinit();
    try data.state_admission.validateStable(allocator, program, saved.state);
    const pending = &@constCast(saved.state.nodes)[@intCast(saved.state.roots.pending.?.id)].record.pending;
    const original = pending.*;
    const blobs = @constCast(saved.state.blobs);
    try testing.expectEqual(1, blobs.len);
    const blob = blobs[0];
    for (0..8) |mutation| {
        switch (mutation) {
            0 => pending.effect = program.effects.len,
            1 => pending.payload.schema = program.schemas.len,
            2 => pending.continuation = saved.state.roots.pending.?,
            3 => saved.state.program_identity[0] ^= 1,
            4 => saved.state.status = .active,
            5 => blobs[0].schema = program.schemas.len,
            6 => blobs[0].bytes = &.{ 2, 0x80 },
            7 => pending.payload.body.blob.id = blobs.len,
            else => unreachable,
        }
        try rejectMalformedState(program, image, saved.state);
        pending.* = original;
        blobs[0] = blob;
        saved.state.program_identity = session.program_identity;
        saved.state.status = .parked;
    }
    var restored = try Session.restoreImage(allocator, image, checkpoint);
    defer restored.deinit();
    var expected = try session.pendingRequest(allocator);
    defer expected.deinit();
    var actual = try restored.pendingRequest(allocator);
    defer actual.deinit();
    try testing.expectEqualDeep(expected.request, actual.request);
    try testing.expectEqualSlices(u8, expected.state, actual.state);
}

test "current captured delimiters and branch-local region aliases reject corruption" {
    var one_shot = false;
    var multi = false;
    var local_alias = false;
    inline for (.{ horos.source.examples.deep, horos.source.examples.choicesAll, horos.source.examples.stateLocal }) |example| {
        var b = horos.source.Builder.init(allocator);
        defer b.deinit();
        var compiled = try horos.program.compile(allocator, try example(&b));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer allocator.free(image);
        var session = try Session.initImage(allocator, image, &.{});
        defer session.deinit();
        for (0..1024) |_| {
            const bytes = try session.checkpoint(allocator);
            defer allocator.free(bytes);
            var saved = try data.state_image.decodeGraph(allocator, bytes);
            defer saved.deinit();
            const nodes = @constCast(saved.state.nodes);
            for (nodes) |*node| {
                const original = node.*;
                const record = node.record;
                if ((record == .one_shot and !one_shot) or (record == .multi_template and !multi)) {
                    const token = if (record == .one_shot) record.one_shot else record.multi_template;
                    const delimiter = &nodes[@intCast(token.delimiter.id)].record.attachment;
                    try testing.expect(delimiter.phase == .suspended);
                    delimiter.phase = .active;
                    try rejectMalformedState(compiled.program, image, saved.state);
                    delimiter.phase = .suspended;
                    if (record == .one_shot) one_shot = true else multi = true;
                }
                if (record == .cell and !local_alias) for (nodes) |other| {
                    if (other.record != .cell or other.record.cell.schema != record.cell.schema or
                        other.record.cell.region.id == record.cell.region.id) continue;
                    node.record.cell.region = other.record.cell.region;
                    try rejectMalformedState(compiled.program, image, saved.state);
                    node.* = original;
                    local_alias = true;
                    break;
                };
            }
            const restored = try Session.restoreImage(allocator, image, bytes);
            session.deinit();
            session = restored;
            if (session.isTerminal()) break;
            try session.step();
        }
        try testing.expect(session.isTerminal());
        try testing.expect(try session.observe() == .completed);
    }
    try testing.expect(one_shot and multi and local_alias);
}

fn substituteSuccessorBorrow(program: data.activation.Program, state: data.process_state.State, from: borrow_returns.ResultFrom) !void {
    const nodes = @constCast(state.nodes);
    const current = &nodes[@intCast(state.roots.current.?.id)];
    const resumed = program.blocks[@intCast(current.record.control.block)].terminator.resume_with;
    const older = try slotValue(current, resumed.state[0]);
    const younger = current.record.control.evidence orelse return error.ExpectedYoungerHandler;
    try testing.expect(older.body == .reference and older.body.reference.id != younger.id);
    if (from == .state) {
        older.body.reference = younger;
        return;
    }
    const value = try slotValue(current, resumed.resumption);
    const token = nodes[@intCast(value.body.owned.node.id)].record.one_shot;
    const capture = &nodes[@intCast(token.capture.?.id)];
    var changed: usize = 0;
    for (@constCast(capture.activation.?.bindings)) |*binding| {
        const item = &binding.value;
        if (item.schema == older.schema and item.body == .reference and
            item.body.reference.id == older.body.reference.id)
        {
            item.body.reference = younger;
            changed += 1;
        }
    }
    try testing.expect(changed != 0);
}

test "current successor State and body results retain return-clause borrow constraints" {
    for (std.enums.values(borrow_returns.ResultFrom)) |from| for ([_]bool{ false, true }) |delegated| {
        var b = horos.source.Builder.init(allocator);
        defer b.deinit();
        var compiled = try horos.program.compile(allocator, try borrow_returns.scenario(&b, from, false, false, delegated));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer allocator.free(image);
        var session = try Session.initImage(allocator, image, &.{});
        defer session.deinit();
        var checked = false;
        for (0..512) |_| {
            const checkpoint = try session.checkpoint(allocator);
            defer allocator.free(checkpoint);
            var saved = try data.state_image.decodeGraph(allocator, checkpoint);
            defer saved.deinit();
            if (saved.state.roots.current) |id| {
                const node = saved.state.nodes[@intCast(id.id)];
                if (node.record == .control) {
                    const block = compiled.program.blocks[@intCast(node.record.control.block)];
                    if (block.terminator == .resume_with and
                        node.activation.?.position == block.instructions.len)
                    {
                        try substituteSuccessorBorrow(compiled.program, saved.state, from);
                        try rejectState(compiled.program, image, saved.state, error.InvalidScope);
                        checked = true;
                        break;
                    }
                }
            }
            try session.step();
        }
        try testing.expect(checked);
        const result = try session.run(null);
        try testing.expect(result == .yielded);
        try session.resumeYield();
        try testing.expect(try session.run(null) == .completed);
    };
}

test "current restored region frames retain their saved invocation effect contract" {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    var compiled = try horos.program.compile(allocator, try regionInvocationExample(&b));
    defer compiled.deinit();
    const program = compiled.program;
    try testing.expectEqual(0, program.functions[@intCast(program.roots.entry)].effects.len);
    const image = try programBytes(program);
    defer allocator.free(image);
    var wider: ?struct { scope: u64, body: u64 } = null;
    for (program.blocks, 0..) |block, id| {
        if (block.terminator != .with_region) continue;
        const function = program.functions[@intCast(block.function)];
        const schema = function.layout.slots[@intCast(block.terminator.with_region.body)];
        if (program.schemas[@intCast(schema)].internal.computation.effects.len == 0) continue;
        for (program.constructors) |constructor| if (constructor.schema == schema) {
            wider = .{ .scope = id, .body = program.functions[@intCast(constructor.function)].entry };
            break;
        };
    }
    try testing.expect(wider != null);
    var session = try Session.initImage(allocator, image, &.{});
    defer session.deinit();
    for (0..128) |_| {
        try session.step();
        const checkpoint = try session.checkpoint(allocator);
        defer allocator.free(checkpoint);
        var original = try data.state_image.decodeGraph(allocator, checkpoint);
        defer original.deinit();
        for (original.state.nodes, 0..) |node, scope| {
            if (node.record != .region_scope) continue;
            for (0..4) |mask| {
                var saved = try data.state_image.decodeGraph(allocator, checkpoint);
                defer saved.deinit();
                const nodes = @constCast(saved.state.nodes);
                if (mask & 1 != 0) {
                    const current = &nodes[@intCast(saved.state.roots.current.?.id)];
                    current.record.control.block = wider.?.body;
                    current.activation.?.position = 0;
                }
                if (mask & 2 != 0) nodes[scope].record.region_scope.source_block = wider.?.scope;
                if (mask == 0) {
                    var restored = try Session.restoreImage(allocator, image, checkpoint);
                    defer restored.deinit();
                    try testing.expect(try restored.run(null) == .completed);
                } else try rejectState(program, image, saved.state, if (mask == 1) error.InvalidEffect else error.InvalidScope);
            }
            return;
        }
    }
    return error.RegionScopeNotReached;
}

test "current full-width zero-size cardinalities survive yield and PST3 restore" {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const maximum = std.math.maxInt(u64);
    const sequence = try b.schema(.{ .seq = unit });
    const vector = try b.schema(.{ .vector = .{ .element = unit, .maximum = maximum } });
    const array = try b.schema(.{ .array = .{ .element = unit, .length = maximum } });
    const tuple = try b.schema(.{ .product = &.{ integer, integer, integer } });
    const entry = try b.declare(&.{ sequence, vector, array }, tuple, &.{}, &.{});
    var lengths: [3]u64 = undefined;
    for (&lengths, 0..) |*length, i| length.* = try b.primitive(integer, .sequence_length, &.{try b.reference(b.parameter(entry, i))}, 0);
    const result = try b.pure(try b.primitive(tuple, .product, &lengths, 0));
    try b.define(entry, try b.term(.{ .yield_then = result }));
    const module = b.module(entry, unit);
    for ([_]u64{ 0, 1, 1 << 32, 768614336404564650, maximum }) |count| {
        var initial: [20]u8 = undefined;
        var writer: data.wire.Writer = .{ .output = &initial };
        try writer.natural(count);
        try writer.natural(count);
        var expected: [24]u8 = undefined;
        std.mem.writeInt(u64, expected[0..8], count, .little);
        std.mem.writeInt(u64, expected[8..16], count, .little);
        std.mem.writeInt(u64, expected[16..24], maximum, .little);
        try expectBindingExecution(module, initial[0..writer.position], .{ .completed = &expected });
    }
}

test "current restored token interfaces bound actual captured continuation effects" {
    var b = horos.source.Builder.init(allocator);
    defer b.deinit();
    var compiled = try horos.program.compile(allocator, try restoredEffectExample(&b));
    defer compiled.deinit();
    const program = compiled.program;
    const image = try programBytes(program);
    defer allocator.free(image);
    const replacement = for (program.handlers, 0..) |handler, id| {
        if (handler.effects.len == 0) break id;
    } else return error.MissingNarrowHandler;
    const handler = program.handlers[replacement];
    const schema = handler.clauses[0].resumption;
    const function = program.functions[@intCast(handler.clauses[0].function)];
    var session = try Session.initImage(allocator, image, &.{1});
    defer session.deinit();
    for (0..512) |_| {
        try session.step();
        const checkpoint = try session.checkpoint(allocator);
        defer allocator.free(checkpoint);
        var saved = try data.state_image.decodeGraph(allocator, checkpoint);
        defer saved.deinit();
        const nodes = @constCast(saved.state.nodes);
        for (nodes) |*node| {
            if (node.record != .one_shot) continue;
            const original_schema = node.record.one_shot.schema;
            if (program.schemas[@intCast(original_schema)].internal.resumption.effects.len == 0)
                continue;
            node.record.one_shot.schema = schema;
            const delimiter = nodes[@intCast(node.record.one_shot.delimiter.id)].record.attachment;
            nodes[@intCast(delimiter.handler.id)].record.handler.definition = replacement;
            const current = &nodes[@intCast(saved.state.roots.current.?.id)];
            current.record.control.block = function.entry;
            // Both clauses have the same two source parameters and custody shape.
            const frame = &current.activation.?;
            frame.position = 0;
            for (@constCast(frame.bindings)) |*binding| {
                if (binding.value.schema == original_schema) binding.value.schema = schema;
            }
            try rejectState(program, image, saved.state, error.InvalidEffect);
            var original = try Session.restoreImage(allocator, image, checkpoint);
            defer original.deinit();
            const pending = try original.run(null);
            try testing.expect(pending == .requested);
            try testing.expectEqualStrings("restore/B", program.effects[@intCast(pending.requested.effect)].identity);
            return;
        }
    }
    return error.CaptureNotFound;
}

const BindingForm = enum { bind, sum_zero, sum_one, product };
const BindingConsumer = enum { value, call, closure };
const BindingBody = struct { term: data.program.Id, schema: data.program.Id };

fn bindingBody(
    b: *horos.source.Builder,
    name: data.program.Id,
    consumer: BindingConsumer,
) !BindingBody {
    const integer = try b.scalar(u64);
    const read = try b.pure(try b.reference(name));
    if (consumer == .value) return .{ .term = read, .schema = integer };
    const helper = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(helper, read);
    if (consumer == .call) return .{
        .term = try b.term(.{ .call = .{ .function = helper, .arguments = &.{} } }),
        .schema = integer,
    };
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .capture_bound = &.{integer},
    } } });
    return .{
        .term = try b.pure(try b.lambda(helper, computation)),
        .schema = computation,
    };
}

fn introduceBinding(
    b: *horos.source.Builder,
    name: data.program.Id,
    body: data.program.Id,
    form: BindingForm,
) !data.program.Id {
    const integer = try b.scalar(u64);
    const two = try b.constant(u64, 2);
    if (form == .bind) return b.bind(name, try b.pure(two), body);
    if (form == .product) {
        const product = try b.schema(.{ .product = &.{ integer, integer } });
        const pair = try b.primitive(product, .product, &.{ two, try b.constant(u64, 9) }, 0);
        return b.term(.{ .unpack_product = .{
            .value = pair,
            .variables = &.{ name, try b.variable(integer) },
            .body = body,
        } });
    }
    const sum = try b.schema(.{ .sum = &.{ integer, integer } });
    const tag: data.program.Id = if (form == .sum_zero) 0 else 1;
    return b.term(.{ .match_sum = .{
        .value = try b.primitive(sum, .variant, &.{two}, tag),
        .cases = &.{ .{ .variable = name, .body = body }, .{ .variable = name, .body = body } },
    } });
}

fn shadowedBindingExample(
    b: *horos.source.Builder,
    form: BindingForm,
    consumer: BindingConsumer,
    shadow: bool,
    yield_inside: bool,
) !horos.source.Module {
    const integer = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    const entry = try b.declare(&.{integer}, pair, &.{}, &.{});
    const outer = b.parameter(entry, 0);
    const name = if (shadow) outer else try b.variable(integer);
    const body = try bindingBody(b, name, consumer);
    const inner = if (yield_inside) try b.term(.{ .yield_then = body.term }) else body.term;
    const scope = try introduceBinding(b, name, inner, form);
    const result = try b.variable(body.schema);
    const value = if (consumer == .closure) try b.variable(integer) else result;
    const combined = try b.primitive(pair, .product, &.{
        try b.reference(value), try b.reference(outer),
    }, 0);
    const returned = try b.pure(combined);
    const after = if (consumer == .closure) try b.bind(value, try b.term(.{ .apply = .{
        .computation = try b.reference(result),
        .arguments = &.{},
    } }), returned) else returned;
    try b.define(entry, try b.bind(result, scope, after));
    return b.module(entry, integer);
}

const BindingExit = union(enum) { completed: []const u8, failed: []const u8 };

fn expectBindingExecution(module: horos.source.Module, initial: []const u8, expected: BindingExit) !void {
    var compiled = try horos.program.compile(allocator, module);
    defer compiled.deinit();
    const image = try programBytes(compiled.program);
    defer allocator.free(image);
    for ([_]?u64{ null, 1 }) |quantum| for ([_]bool{ false, true }) |transfer| {
        var session = try Session.initImage(allocator, image, initial);
        defer session.deinit();
        for (0..1024) |_| {
            const result = try session.run(quantum);
            if (result == .completed or result == .failed) {
                switch (expected) {
                    .completed => |value| {
                        try testing.expect(result == .completed);
                        try testing.expectEqualSlices(u8, value, try session.bytes(&result.completed));
                    },
                    .failed => |value| {
                        try testing.expect(result == .failed);
                        try testing.expectEqualSlices(u8, value, try session.bytes(&result.failed));
                    },
                }
                break;
            }
            try testing.expect(result == .progressed or result == .yielded);
            if (transfer) {
                const bytes = try session.checkpoint(allocator);
                defer allocator.free(bytes);
                const next = try Session.restoreImage(allocator, image, bytes);
                session.deinit();
                session = next;
            }
            if (result == .yielded) try session.resumeYield();
        } else return error.FiniteFixtureDidNotTerminate;
    };
}

test "lexical binders preserve inner values and outside continuations through captures and yield" {
    inline for (std.meta.tags(BindingForm)) |form| {
        inline for (std.meta.tags(BindingConsumer)) |consumer| {
            for ([_]bool{ false, true }) |shadow| {
                for ([_]bool{ false, true }) |yield_inside| {
                    var b = horos.source.Builder.init(std.testing.allocator);
                    defer b.deinit();
                    const module = try shadowedBindingExample(
                        &b,
                        form,
                        consumer,
                        shadow,
                        yield_inside,
                    );
                    expectBindingExecution(module, &.{ 1, 0, 0, 0, 0, 0, 0, 0 }, .{
                        .completed = &.{ 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 },
                    }) catch |err| {
                        std.debug.print("form={s} consumer={s} shadow={any} yield={any}\n", .{
                            @tagName(form), @tagName(consumer), shadow, yield_inside,
                        });
                        return err;
                    };
                }
            }
        }
    }
}

test "lexical environments distinguish shared term bodies under different bindings" {
    var b = horos.source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const entry = try b.declare(&.{boolean}, integer, &.{}, &.{});
    const name = try b.variable(integer);
    const shared = try b.pure(try b.reference(name));
    const left = try b.bind(name, try b.pure(try b.constant(u64, 11)), shared);
    const right = try b.bind(name, try b.pure(try b.constant(u64, 22)), shared);
    try b.define(entry, try b.term(.{ .conditional = .{
        .condition = try b.reference(b.parameter(entry, 0)),
        .when_true = left,
        .when_false = right,
    } }));
    const module = b.module(entry, integer);
    try expectBindingExecution(module, &.{1}, .{ .completed = &.{ 11, 0, 0, 0, 0, 0, 0, 0 } });
    try expectBindingExecution(module, &.{0}, .{ .completed = &.{ 22, 0, 0, 0, 0, 0, 0, 0 } });
}

fn ownedBindingExample(b: *horos.source.Builder, fail: bool) !horos.source.Module {
    const integer = try b.scalar(u64);
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .use = .linear,
    } } });
    const outer = try b.declare(&.{}, integer, &.{}, &.{});
    const inner = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(outer, try b.pure(try b.constant(u64, 1)));
    try b.define(inner, try b.pure(try b.constant(u64, 2)));
    const name = try b.variable(computation);
    const inner_exit = if (fail)
        try b.term(.{ .fail = try b.constant(u64, 9) })
    else
        try b.term(.{ .apply = .{ .computation = try b.reference(name), .arguments = &.{} } });
    const nested = try b.bind(name, try b.pure(try b.lambda(inner, computation)), inner_exit);
    const after = try b.term(.{ .apply = .{
        .computation = try b.reference(name),
        .arguments = &.{},
    } });
    const entry = try b.declare(&.{}, integer, &.{}, &.{});
    const rest = try b.bind(try b.variable(integer), nested, after);
    try b.define(entry, try b.bind(name, try b.pure(try b.lambda(outer, computation)), rest));
    return b.module(entry, integer);
}

test "lexical shadowing preserves distinct owned values on consumption and failure" {
    for ([_]bool{ false, true }) |fail| {
        var b = horos.source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try ownedBindingExample(&b, fail);
        const expected: BindingExit = if (fail)
            .{ .failed = &.{ 9, 0, 0, 0, 0, 0, 0, 0 } }
        else
            .{ .completed = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } };
        try expectBindingExecution(module, &.{}, expected);
    }
}

fn restoredEffectExample(b: *horos.source.Builder) !horos.source.Module {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const a = try b.effect(.{ .identity = "restore/A", .payload = unit, .result = unit, .external = false });
    const residual = try b.effect(.{ .identity = "restore/B", .payload = unit, .result = unit, .external = true });
    const cap = try b.schema(.{ .internal = .{ .capability = a } });
    const returns = try b.declare(&.{unit}, unit, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    var branches: [2]data.program.Id = undefined;
    for (&branches, 0..) |*branch, index| {
        const row: []const data.program.Id = if (index == 0) &.{} else &.{residual};
        const token = try b.schema(.{ .internal = .{ .resumption = .{ .effect = a, .input = unit, .answer = unit, .mode = .deep, .use = .linear, .handled = &.{a}, .effects = row, .capture_bound = &.{ unit, cap } } } });
        const clause = try b.declare(&.{ unit, token }, unit, row, &.{});
        const resume_term = try b.term(.{ .resume_value = .{ .resumption = try b.reference(b.parameter(clause, 1)), .argument = try b.constant(void, {}) } });
        const yield = try b.term(.{ .yield_then = try b.pure(try b.constant(void, {})) });
        try b.define(clause, try b.bind(try b.variable(unit), resume_term, yield));
        const handler = try b.handler(.{ .mode = .deep, .input = unit, .answer = unit, .effects = row, .return_function = returns, .clauses = &.{.{ .effect = a, .function = clause, .resumption = token }} });
        const body_row: []const data.program.Id = if (index == 0) &.{a} else &.{ a, residual };
        const body = try b.declare(&.{cap}, unit, body_row, &.{});
        const first = try b.term(.{ .perform = .{ .effect = a, .capability = try b.reference(b.parameter(body, 0)), .payload = try b.constant(void, {}) } });
        const last = if (index == 0) try b.pure(try b.constant(void, {})) else try b.term(.{ .perform = .{ .effect = residual, .payload = try b.constant(void, {}) } });
        try b.define(body, try b.bind(try b.variable(unit), first, last));
        const signature = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap}, .result = unit, .effects = body_row } } });
        branch.* = try b.term(.{ .handle = .{ .handler = handler, .body = try b.lambda(body, signature) } });
    }
    const entry = try b.declare(&.{boolean}, unit, &.{residual}, &.{});
    try b.define(entry, try b.term(.{ .conditional = .{ .condition = try b.reference(b.parameter(entry, 0)), .when_true = branches[1], .when_false = branches[0] } }));
    return b.module(entry, unit);
}

fn capabilityExample(b: *horos.source.Builder, through_pair: bool) !struct {
    module: horos.source.Module,
    cap: u64,
    pair: u64,
} {
    const unit = try b.scalar(void);
    const effect = try b.effect(.{ .identity = "saved-capability", .payload = unit, .result = unit, .external = false });
    const cap = try b.schema(.{ .internal = .{ .capability = effect } });
    const pair = try b.schema(.{ .product = &.{ cap, cap } });
    var handlers: [2]data.program.Id = undefined;
    for (&handlers, [_]data.program.Id{ unit, cap }) |*handler, result| {
        const returns = try b.declare(&.{result}, result, &.{}, &.{});
        try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
        const token = try b.schema(.{ .internal = .{ .resumption = .{ .effect = effect, .input = unit, .answer = result, .capture_bound = &.{ unit, cap, pair }, .handled = &.{effect}, .mode = .deep, .use = .linear } } });
        const clause = try b.declare(&.{ unit, token }, result, &.{}, &.{});
        try b.define(clause, try b.term(.{ .resume_value = .{ .resumption = try b.reference(b.parameter(clause, 1)), .argument = try b.constant(void, {}) } }));
        handler.* = try b.handler(.{ .mode = .deep, .input = result, .answer = result, .return_function = returns, .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }} });
    }
    const inner = try b.declare(&.{ cap, cap }, cap, &.{}, &.{});
    const fresh = try b.reference(b.parameter(inner, 0));
    const older = try b.reference(b.parameter(inner, 1));
    const body = if (through_pair) blk: {
        const helper = try b.declare(&.{ cap, cap }, pair, &.{}, &.{});
        try b.define(helper, try b.pure(try b.primitive(pair, .product, &.{ try b.reference(b.parameter(helper, 0)), try b.reference(b.parameter(helper, 1)) }, 0)));
        const answer = try b.variable(pair);
        break :blk try b.bind(answer, try b.term(.{ .call = .{ .function = helper, .arguments = &.{ fresh, older } } }), try b.pure(try b.primitive(cap, .field, &.{try b.reference(answer)}, 1)));
    } else try b.pure(older);
    try b.define(inner, body);
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{ cap, cap }, .result = cap } } });
    const outer = try b.declare(&.{cap}, unit, &.{effect}, &.{});
    const answer = try b.variable(cap);
    const installed = try b.term(.{ .handle = .{ .handler = handlers[1], .body = try b.lambda(inner, inner_type), .arguments = &.{try b.reference(b.parameter(outer, 0))} } });
    try b.define(outer, try b.bind(answer, installed, try b.term(.{ .perform = .{ .effect = effect, .capability = try b.reference(answer), .payload = try b.constant(void, {}) } })));
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap}, .result = unit, .effects = &.{effect} } } });
    const main = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(main, try b.term(.{ .handle = .{ .handler = handlers[0], .body = try b.lambda(outer, outer_type) } }));
    return .{ .module = b.module(main, unit), .cap = cap, .pair = pair };
}

test "saved same-family capability substitution cannot escape through a helper return" {
    for ([_]bool{ false, true }) |through_pair| {
        var b = horos.source.Builder.init(allocator);
        defer b.deinit();
        const fixture = try capabilityExample(&b, through_pair);
        const cap = fixture.cap;
        const pair = fixture.pair;
        var compiled = try horos.program.compile(allocator, fixture.module);
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer allocator.free(image);
        var session = try Session.initImage(allocator, image, &.{});
        defer session.deinit();
        var rejected: usize = 0;
        for (0..512) |_| {
            const bytes = try session.checkpoint(allocator);
            defer allocator.free(bytes);
            var snapshot = try data.state_image.decodeGraph(allocator, bytes);
            defer snapshot.deinit();
            try data.state_admission.validateStable(allocator, compiled.program, snapshot.state);
            if (snapshot.state.roots.current) |current| {
                const node = &@constCast(snapshot.state.nodes)[@intCast(current.id)];
                if (node.record == .control) {
                    const function = compiled.program.blocks[@intCast(node.record.control.block)].function;
                    const result = compiled.program.functions[@intCast(function)].result;
                    if ((result == cap or result == pair) and node.record.control.evidence != null) {
                        const younger = node.record.control.evidence.?;
                        for (@constCast(node.activation.?.bindings)) |*binding| {
                            const value = binding.value;
                            if (value.schema != cap or value.body != .reference or
                                value.body.reference.id == younger.id) continue;
                            binding.value.body.reference = younger;
                            try rejectState(compiled.program, image, snapshot.state, error.InvalidScope);
                            binding.value = value;
                            rejected += 1;
                        }
                    }
                }
            }
            if (session.isTerminal()) break;
            const restored = try Session.restoreImage(allocator, image, bytes);
            session.deinit();
            session = restored;
            try session.step();
        }
        try testing.expect(rejected >= if (through_pair) @as(usize, 2) else 1);
        const result = try session.observe();
        try testing.expect(result == .completed);
        try testing.expectEqual(0, (try session.bytes(&result.completed)).len);
    }
}

fn regionInvocationExample(b: *horos.source.Builder) !horos.source.Module {
    const unit = try b.scalar(void);
    const effect = try b.effect(.{
        .identity = "restore/foreign-region",
        .payload = unit,
        .result = unit,
    });
    const region_id = b.region();
    const region = try b.schema(.{ .internal = .{ .region = region_id } });
    const wide_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = unit,
        .effects = &.{effect},
    } } });
    var wrappers: [2]data.program.Id = undefined;
    for (&wrappers, 0..) |*wrapper, index| {
        const row: []const data.program.Id = if (index == 0) &.{} else &.{effect};
        const body = try b.declare(&.{region}, unit, row, &.{region_id});
        const value = try b.constant(void, {});
        const term = if (index == 0) try b.pure(value) else try b.term(.{ .perform = .{
            .effect = effect,
            .payload = value,
        } });
        try b.define(body, term);
        const body_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{region},
            .result = unit,
            .effects = row,
            .regions = &.{region_id},
        } } });
        const parameters: []const data.program.Id = if (index == 0) &.{wide_type} else &.{};
        wrapper.* = try b.declare(parameters, unit, row, &.{});
        try b.define(wrapper.*, try b.term(.{ .with_region = .{
            .region = region_id,
            .body = try b.lambda(body, body_type),
        } }));
    }
    const entry = try b.declare(&.{}, unit, &.{}, &.{});
    // Passing an unused computation retains its code without performing its effects.
    try b.define(entry, try b.term(.{ .call = .{
        .function = wrappers[0],
        .arguments = &.{try b.lambda(wrappers[1], wide_type)},
    } }));
    return b.module(entry, unit);
}

fn phaseReturnExample(b: *horos.source.Builder) !horos.source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const returns = try b.declare(&.{integer}, boolean, &.{}, &.{});
    try b.define(returns, try b.pure(try b.constant(bool, true)));
    const handler = try b.handler(.{
        .mode = .deep,
        .input = integer,
        .answer = boolean,
        .return_function = returns,
        .clauses = &.{},
    });
    const body = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(body, try b.pure(try b.constant(u64, 42)));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
    } } });
    const main = try b.declare(&.{}, integer, &.{}, &.{});
    const installed = try b.term(.{ .handle = .{
        .handler = handler,
        .body = try b.lambda(body, body_type),
    } });
    try b.define(main, try b.bind(
        try b.variable(boolean),
        installed,
        try b.pure(try b.constant(u64, 9)),
    ));
    return b.module(main, unit);
}

test "tail indirect application retains its environment without accumulating return controls" {
    const source = horos.source;
    for ([_]bool{ false, true }) |non_tail| {
        var b = source.Builder.init(allocator);
        defer b.deinit();
        const integer = try b.scalar(u64);
        const unit = try b.scalar(void);
        const signature = try b.reserveSchema();
        try b.defineSchema(signature, .{ .internal = .{ .computation = .{ .parameters = &.{ signature, integer }, .result = integer, .capture_bound = &.{integer} } } });
        const entry = try b.declare(&.{ integer, integer }, integer, &.{}, &.{});
        const loop = try b.declare(&.{ signature, integer }, integer, &.{}, &.{});
        const count = try b.reference(b.parameter(loop, 1));
        const decremented = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{ .opcode = .integer_sub, .operands = &.{ count, try b.constant(u64, 1) }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = try b.failureLiteral(try b.constant(void, {})) }} } } });
        var next = try b.term(.{ .apply = .{ .computation = try b.reference(b.parameter(loop, 0)), .arguments = &.{ try b.reference(b.parameter(loop, 0)), decremented } } });
        if (non_tail) {
            const returned = try b.variable(integer);
            const plus = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{ try b.reference(returned), try b.constant(u64, 1) }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = try b.failureLiteral(try b.constant(void, {})) }} } } });
            next = try b.bind(returned, next, try b.pure(plus));
        }
        try b.define(loop, try b.term(.{ .conditional = .{
            .condition = try b.primitive(try b.scalar(bool), .equal, &.{ count, try b.constant(u64, 0) }, 0),
            .when_true = try b.pure(try b.reference(b.parameter(entry, 1))),
            .when_false = next,
        } }));
        const function = try b.lambda(loop, signature);
        try b.define(entry, try b.term(.{ .apply = .{ .computation = function, .arguments = &.{ function, try b.reference(b.parameter(entry, 0)) } } }));
        var compiled = try horos.program.compile(allocator, b.module(entry, unit));
        defer compiled.deinit();
        const image = try programBytes(compiled.program);
        defer allocator.free(image);
        for ([_]u64{ 7, 127, 1024 }) |count_input| {
            var input: [16]u8 = undefined;
            std.mem.writeInt(u64, input[0..8], count_input, .little);
            std.mem.writeInt(u64, input[8..16], 37, .little);
            var session = try Session.initImage(allocator, image, &input);
            defer session.deinit();
            var rounds: usize = 0;
            while (true) {
                rounds += 1;
                try testing.expect(rounds < 4096);
                const outcome = try session.run(13);
                if (outcome == .completed) {
                    const result = try session.bytes(&outcome.completed);
                    try testing.expectEqual(@as(u64, 37) + if (non_tail) count_input else 0, std.mem.readInt(u64, result[0..8], .little));
                    break;
                }
                try testing.expect(outcome == .progressed);
                const state = try session.checkpoint(allocator);
                defer allocator.free(state);
                if (!non_tail) {
                    var decoded = try data.state_image.decodeGraph(allocator, state);
                    defer decoded.deinit();
                    try testing.expect(decoded.state.nodes.len <= 16);
                }
                // Use the restored state, including the closure's captured seed.
                if (rounds % 7 == 0) {
                    const restored = try Session.restoreImage(allocator, image, state);
                    session.deinit();
                    session = restored;
                }
            }
        }
    }
}
