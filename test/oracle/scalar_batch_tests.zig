const std = @import("std");
const data = @import("horos_data");
const runtime = @import("stable_session.zig");
const a = std.testing.allocator;
const program: data.activation.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{.{ .entry = 0, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0, 0, 0, 0, 0 } }, .result = 0 }},
    .blocks = &.{.{ .function = 0, .instructions = &.{
        .{ .destination = 2, .opcode = .integer_bit_xor, .operands = &.{ 0, 1 } },
        .{ .destination = 3, .opcode = .integer_bit_not, .operands = &.{2} },
        .{ .destination = 4, .opcode = .integer_bit_and, .operands = &.{ 3, 0 } },
        .{ .destination = 5, .opcode = .integer_bit_or, .operands = &.{ 4, 1 } },
    }, .terminator = .{ .return_value = 5 } }},
};

test "scalar batches preserve every quantum prefix and restored logical position" {
    const image = try a.alloc(u8, try data.program_image.encodedLength(program));
    defer a.free(image);
    _ = try data.program_image.encode(a, program, image);
    var prepared = try runtime.Prepared.init(a, image);
    defer prepared.deinit();
    for ([_]u64{ 0, 1, 0x123456789abcdef0, std.math.maxInt(u64) }) |input| {
        var args: [16]u8 = undefined;
        std.mem.writeInt(u64, args[0..8], input, .little);
        std.mem.writeInt(u64, args[8..16], 0x55, .little);
        for ([_]usize{ 0, 254, 255, std.math.maxInt(usize) }) |initial_transitions| for (0..8) |quantum| {
            var fast = try runtime.Session.start(a, &prepared, &args);
            defer fast.deinit();
            var slow = try runtime.Session.initImage(a, image, &args);
            defer slow.deinit();
            var fast_stats: @import("../../src/interpreter_v2/runtime_types.zig").Statistics = .{};
            var slow_stats: @import("../../src/interpreter_v2/runtime_types.zig").Statistics = .{};
            fast.statistics = &fast_stats;
            slow.statistics = &slow_stats;
            fast.transitions = initial_transitions;
            slow.transitions = initial_transitions;
            const outcome = try fast.run(quantum);
            for (0..quantum) |_| {
                if (try slow.observe() != .progressed) break;
                try slow.step();
            }
            try std.testing.expectEqual(std.meta.activeTag(outcome), std.meta.activeTag(try slow.observe()));
            try std.testing.expectEqual(slow_stats.transitions, fast_stats.transitions);
            const left = try fast.checkpoint(a);
            defer a.free(left);
            const right = try slow.checkpoint(a);
            defer a.free(right);
            try std.testing.expectEqualSlices(u8, right, left);
            if (quantum >= 4 or (initial_transitions == 0 and quantum >= 2)) try std.testing.expect(fast_stats.dispatches < slow_stats.dispatches);
            var restored = try runtime.Session.restore(a, &prepared, left);
            defer restored.deinit();
            const final = try restored.run(null);
            try std.testing.expect(final == .completed);
            try std.testing.expectEqual((~(input ^ 0x55) & input) | 0x55, std.mem.readInt(u64, (try restored.bytes(&final.completed))[0..8], .little));
        };
    }
}

test "scalar batching stops before a checked failure and preserves its exact prefix" {
    var original = program;
    var blocks = program.blocks[0..1].*;
    var instructions = program.blocks[0].instructions[0..4].*;
    instructions[2] = .{ .destination = 4, .opcode = .integer_add, .operands = &.{ 2, 2 }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = 0 }} };
    blocks[0].instructions = &instructions;
    original.blocks = &blocks;
    original.constants = &.{.{ .schema = 1, .bytes = &.{} }};
    const image = try a.alloc(u8, try data.program_image.encodedLength(original));
    defer a.free(image);
    _ = try data.program_image.encode(a, original, image);
    var args: [16]u8 = @splat(0);
    @memset(args[0..8], 0xff);
    for (0..9) |quantum| {
        var fast = try runtime.Session.initImage(a, image, &args);
        defer fast.deinit();
        var slow = try runtime.Session.initImage(a, image, &args);
        defer slow.deinit();
        _ = try fast.run(quantum);
        for (0..quantum) |_| {
            if (try slow.observe() != .progressed) break;
            try slow.step();
        }
        const actual = try fast.checkpoint(a);
        defer a.free(actual);
        const expected = try slow.checkpoint(a);
        defer a.free(expected);
        try std.testing.expectEqualSlices(u8, expected, actual);
        var restored = try runtime.Session.restoreImage(a, image, actual);
        defer restored.deinit();
        try std.testing.expect(try restored.run(null) == .failed);
    }
}

test "scalar batch resident rollback preserves prior input at every allocation failure" {
    const image = try a.alloc(u8, try data.program_image.encodedLength(program));
    defer a.free(image);
    _ = try data.program_image.encode(a, program, image);
    var prepared = try runtime.Prepared.init(a, image);
    defer prepared.deinit();
    const args: [16]u8 = @splat(0x55);
    var initial = try runtime.Session.start(a, &prepared, &args);
    defer initial.deinit();
    const checkpoint = try initial.checkpoint(a);
    defer a.free(checkpoint);
    var reference = try runtime.Resident.restore(a, &prepared, checkpoint);
    defer reference.close() catch unreachable;
    const expected = try reference.driveEncoded(a, .none, .{});
    defer a.free(expected);
    var failed_after_batch = false;
    var completed = false;
    for (0..4096) |failure| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        var resident = try runtime.Resident.restore(failing.allocator(), &prepared, checkpoint);
        defer resident.close() catch unreachable;
        var stats: @import("../../src/interpreter_v2/runtime_types.zig").Statistics = .{};
        try resident.setStatistics(&stats);
        failing.fail_index = failing.alloc_index + failure;
        failing.resize_fail_index = failing.resize_index;
        const result = resident.driveEncoded(failing.allocator(), .none, .{}) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed_after_batch = failed_after_batch or stats.batched_scalar_operations != 0;
            const unchanged = try resident.checkpoint(a);
            defer a.free(unchanged);
            try std.testing.expectEqualSlices(u8, checkpoint, unchanged);
            const retried = try resident.driveEncoded(a, .none, .{});
            defer a.free(retried);
            try std.testing.expectEqualSlices(u8, expected, retried);
            continue;
        };
        defer failing.allocator().free(result);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try std.testing.expectEqualSlices(u8, expected, result);
        try std.testing.expect(failure != 0 and failed_after_batch);
        completed = true;
        break;
    }
    try std.testing.expect(completed);
}
