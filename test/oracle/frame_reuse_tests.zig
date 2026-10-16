const std = @import("std");
const data = @import("horos_data");
const runtime = @import("stable_session.zig");
const a = std.testing.allocator;

pub fn fixture(allocator: std.mem.Allocator, compatible: bool) !data.activation.Program {
    const blocks = try allocator.alloc(data.activation.Block, 8);
    for (0..2) |function| {
        const start = function * 4;
        blocks[start] = .{ .function = function, .instructions = &.{ .{ .destination = 1, .opcode = .constant, .immediate = 0 }, .{ .destination = 2, .opcode = .less, .operands = &.{ 0, 1 } } }, .terminator = .{ .branch = .{ .condition = 2, .when_true = .{ .block = start + 3 }, .when_false = .{ .block = start + 1 } } } };
        blocks[start + 1] = .{ .function = function, .instructions = &.{.{ .destination = 0, .opcode = .integer_sub, .operands = &.{ 0, 1 }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = 1 }} }}, .terminator = .{ .call = .{ .function = 1 - function, .arguments = &.{0}, .next = .{ .block = start + 2, .assignments = &.{.{ .destination = 3, .source = .returned }} } } } };
        blocks[start + 2] = .{ .function = function, .instructions = &.{}, .terminator = .{ .return_value = 3 } };
        blocks[start + 3] = .{ .function = function, .instructions = &.{}, .terminator = .{ .return_value = 0 } };
    }
    const functions = try allocator.alloc(data.activation.Function, 2);
    functions[0] = .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0, 2, 0 } }, .result = 0 };
    functions[1] = .{ .entry = 4, .inputs = &.{0}, .layout = .{ .slots = if (compatible) &.{ 0, 0, 2, 0 } else &.{ 0, 0, 2, 0, 0 } }, .result = 0 };
    return .{ .roots = .{ .entry = 0, .result = 0, .failure = 1 }, .schemas = &.{ .u64, .unit, .boolean }, .constants = &.{ .{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } }, .{ .schema = 1, .bytes = &.{} } }, .effects = &.{}, .functions = functions, .blocks = blocks };
}

test "mutual tail frame reuse retains prior views and falls back on incompatible layouts" {
    for ([_]bool{ false, true }) |compatible| for ([_]bool{ false, true }) |retain| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const program = try fixture(arena.allocator(), compatible);
        const image = try a.alloc(u8, try data.program_image.encodedLength(program));
        defer a.free(image);
        _ = try data.program_image.encode(a, program, image);
        var session = try runtime.Session.initImage(a, image, &.{ 8, 0, 0, 0, 0, 0, 0, 0 });
        defer session.deinit();
        const initial = try session.frames.get(session.roots.current.?.id);
        const retained = if (retain) try session.frames.forkFrame(initial) else null;
        defer if (retained) |frame| session.frames.releaseFrame(frame);
        var stats: @import("../../src/interpreter_v2/runtime_types.zig").Statistics = .{};
        session.statistics = &stats;
        var steps: usize = 0;
        while (session.terminal == null) : (steps += 1) {
            try std.testing.expect(steps < 100);
            const previous = try session.frames.get(session.roots.current.?.id);
            const reuses = stats.tail_frame_reuses;
            try session.step();
            if (stats.tail_frame_reuses > reuses) {
                const next = try session.frames.get(session.roots.current.?.id);
                try std.testing.expect(next.function != previous.function);
                try std.testing.expectEqualDeep(previous.view, next.view);
                const checkpoint = try session.checkpoint(a);
                defer a.free(checkpoint);
                var restored = try runtime.Session.restoreImage(a, image, checkpoint);
                defer restored.deinit();
                const result = try restored.run(null);
                try std.testing.expect(result == .completed);
                try std.testing.expectEqual(0, std.mem.readInt(u64, (try restored.bytes(&result.completed))[0..8], .little));
            }
        }
        if (retained) |frame| try std.testing.expectEqual(8, (try session.frames.slots.get(frame.view, 0)).body.scalar[0]);
        try std.testing.expectEqual(@as(u64, if (compatible) 8 else 0), stats.tail_frame_reuses);
        try std.testing.expectEqual(@as(u64, if (compatible) 0 else 8), stats.tail_frame_reuse_fallbacks);
        try std.testing.expectEqual(@as(u64, 8), stats.stack_argument_calls);
        try std.testing.expectEqual(@as(u64, 0), stats.heap_argument_calls);
        if (compatible) try std.testing.expectEqual(retain, session.frames.slots.statistics.value_copies != 0);
        try std.testing.expect(try session.observe() == .completed);
    };
}

test "eight stack arguments and nine heap arguments preserve ordered predecessor values" {
    for ([_]usize{ 8, 9 }) |count| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const memory = arena.allocator();
        const inputs = try memory.alloc(data.program.Id, count);
        const arguments = try memory.alloc(data.program.Id, count);
        for (inputs, arguments, 0..) |*input, *argument, i| {
            input.* = i;
            argument.* = count - i - 1;
        }
        const layout = try memory.alloc(data.program.Id, count + 1);
        @memset(layout, 0);
        const program: data.activation.Program = .{
            .roots = .{ .entry = 0, .result = 0, .failure = 1 },
            .schemas = &.{ .u64, .unit },
            .constants = &.{},
            .effects = &.{},
            .functions = &.{
                .{ .entry = 0, .inputs = inputs, .layout = .{ .slots = layout }, .result = 0 },
                .{ .entry = 2, .inputs = inputs, .layout = .{ .slots = layout[0..count] }, .result = 0 },
            },
            .blocks = &.{
                .{ .function = 0, .instructions = &.{}, .terminator = .{ .call = .{ .function = 1, .arguments = arguments, .next = .{ .block = 1, .assignments = &.{.{ .destination = count, .source = .returned }} } } } },
                .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = count } },
                .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = count - 1 } },
            },
        };
        const image = try memory.alloc(u8, try data.program_image.encodedLength(program));
        _ = try data.program_image.encode(a, program, image);
        const bytes = try memory.alloc(u8, count * 8);
        for (0..count) |i| std.mem.writeInt(u64, bytes[i * 8 ..][0..8], i + 1, .little);
        var session = try runtime.Session.initImage(a, image, bytes);
        defer session.deinit();
        var stats: @import("../../src/interpreter_v2/runtime_types.zig").Statistics = .{};
        session.statistics = &stats;
        try session.step();
        const checkpoint = try session.checkpoint(a);
        defer a.free(checkpoint);
        var restored = try runtime.Session.restoreImage(a, image, checkpoint);
        defer restored.deinit();
        const result = try restored.run(null);
        try std.testing.expect(result == .completed);
        try std.testing.expectEqual(1, std.mem.readInt(u64, (try restored.bytes(&result.completed))[0..8], .little));
        try std.testing.expectEqual(@as(u64, @intFromBool(count == 8)), stats.stack_argument_calls);
        try std.testing.expectEqual(@as(u64, @intFromBool(count == 9)), stats.heap_argument_calls);
    }
}

pub fn wideFixture(allocator: std.mem.Allocator, count: usize, compatible: bool) !data.activation.Program {
    if (count < 4 or count > 65536) return error.InvalidFixture;
    if (count == 4) return fixture(allocator, compatible);
    var program = try fixture(allocator, true);
    const functions = try allocator.dupe(data.activation.Function, program.functions);
    for (functions, 0..) |*function, index| {
        const layout = try allocator.alloc(data.program.Id, count);
        @memset(layout, 0);
        layout[2] = 2;
        if (!compatible and index == 1) layout[count - 1] = 1;
        function.layout.slots = layout;
    }
    program.functions = functions;
    return program;
}

test "wide exact layout classes survive shared preparation retained views and restoration" {
    for ([_]usize{ 4096, 65536 }) |count| for ([_]bool{ false, true }) |compatible| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const program = try wideFixture(arena.allocator(), count, compatible);
        const image = try a.alloc(u8, try data.program_image.encodedLength(program));
        defer a.free(image);
        _ = try data.program_image.encode(a, program, image);
        var prepared = try runtime.Prepared.init(a, image);
        defer prepared.deinit();
        var survivor = try prepared.clone();
        defer survivor.deinit();
        var session = try runtime.Session.start(a, &prepared, &.{ 8, 0, 0, 0, 0, 0, 0, 0 });
        defer session.deinit();
        prepared.deinit();
        try std.testing.expect(session.frames.layouts == survivor.core.?.frameLayouts());
        const storage_bytes = try survivor.storageBytes();
        const initial = try session.frames.get(session.roots.current.?.id);
        const retained = try session.frames.forkFrame(initial);
        defer session.frames.releaseFrame(retained);
        var occupied = initial;
        occupied.custody.initialized = true;
        try std.testing.expect(!session.frames.canRestart(occupied, 1));
        var stats: @import("../../src/interpreter_v2/runtime_types.zig").Statistics = .{};
        session.statistics = &stats;
        while (session.terminal == null) {
            try session.step();
            const checkpoint = try session.checkpoint(a);
            defer a.free(checkpoint);
            var restored = try runtime.Session.restore(a, &survivor, checkpoint);
            defer restored.deinit();
            try std.testing.expect(restored.frames.layouts == session.frames.layouts);
            const result = try restored.run(null);
            try std.testing.expect(result == .completed);
            try std.testing.expectEqual(0, std.mem.readInt(u64, (try restored.bytes(&result.completed))[0..8], .little));
        }
        try std.testing.expectEqual(@as(u64, if (compatible) 8 else 0), stats.tail_frame_reuses);
        try std.testing.expectEqual(@as(u64, if (compatible) 0 else 8), stats.tail_frame_reuse_fallbacks);
        try std.testing.expectEqual(8, (try session.frames.slots.get(retained.view, 0)).body.scalar[0]);
        try std.testing.expectEqual(storage_bytes, try survivor.storageBytes());
    };
}
