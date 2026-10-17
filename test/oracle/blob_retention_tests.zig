const std = @import("std");
const data = @import("horos_data");
const runtime = @import("stable_session.zig");
const a = std.testing.allocator;
pub const captured: data.activation.Program = .{
    .roots = .{ .entry = 0, .result = 1, .failure = 2 },
    .schemas = &.{ .bytes, .u64, .unit, .{ .internal = .{ .computation = .{ .parameters = &.{}, .result = 1, .capture_bound = &.{0}, .use = .reusable } } } },
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
        }, .terminator = .{ .apply = .{ .computation = 2, .arguments = &.{}, .next = .{ .block = 1, .assignments = &.{.{ .destination = 3, .source = .returned }} } } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{ .function = 1, .instructions = &.{.{ .destination = 1, .opcode = .blob_length, .operands = &.{0} }}, .terminator = .{ .return_value = 1 } },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 3 }},
};

pub fn program(comptime alias: bool) data.activation.Program {
    return .{
        .roots = .{ .entry = 0, .result = 1, .failure = 2 },
        .schemas = &.{ .bytes, .u64, .unit },
        .constants = &.{},
        .effects = &.{},
        .functions = &.{.{ .entry = 0, .inputs = if (alias) &.{ 0, 2 } else &.{0}, .layout = .{ .slots = &.{ 0, 1, 0 } }, .result = 1 }},
        .blocks = if (alias) &.{.{ .function = 0, .instructions = &.{
            .{ .destination = 1, .opcode = .blob_length, .operands = &.{0} },
            .{ .destination = 1, .opcode = .blob_length, .operands = &.{2} },
        }, .terminator = .{ .return_value = 1 } }} else &.{.{ .function = 0, .instructions = &.{
            .{ .destination = 1, .opcode = .blob_length, .operands = &.{0} },
            .{ .destination = 1, .opcode = .integer_bit_xor, .operands = &.{ 1, 1 } },
        }, .terminator = .{ .return_value = 1 } }},
    };
}

test "measure consumed large blob residency and preserve a live alias" {
    inline for (0..3) |kind| {
        const alias = kind != 0;
        const original = comptime if (kind == 2) captured else program(alias);
        const image = try a.alloc(u8, try data.program_image.encodedLength(original));
        defer a.free(image);
        _ = try data.program_image.encode(a, original, image);
        var prepared = try runtime.Prepared.init(a, image);
        defer prepared.deinit();
        const payload = try a.alloc(u8, 1 << 20);
        defer a.free(payload);
        @memset(payload, 'x');
        const arguments = try a.alloc(u8, 2 * (payload.len + 10));
        defer a.free(arguments);
        var writer: data.wire.Writer = .{ .output = arguments };
        try writer.bytes(payload);
        if (kind == 1) try writer.bytes(payload);
        var budget: runtime.AllocationBudget = .{ .parent = a, .limit = 8 << 20 };
        var resident = try runtime.Resident.start(budget.allocator(), &prepared, arguments[0..writer.position]);
        defer resident.close() catch unreachable;
        var stats: @import("../../src/interpreter_v2/runtime_types.zig").Statistics = .{};
        try resident.setStatistics(&stats);
        const before = budget.live;
        var parked = try resident.drive(a, .none, .{ .quantum = if (kind == 2) 2 else 1, .checkpoint = true });
        defer parked.deinit();
        try std.testing.expect(parked.record == .progressed);
        try std.testing.expectEqual(@as(u64, if (kind == 1) 0 else 1), stats.early_blob_collections);
        const after = budget.live;
        std.debug.print("blob kind={d} alias={any} resident_before={d} resident_after={d}\n", .{ kind, alias, before, after });
        if (alias) {
            try std.testing.expect(after >= payload.len);
        } else {
            try std.testing.expect(after < 8192);
            try std.testing.expect(before - after > payload.len - 8192);
        }
        var result = try resident.drive(a, .none, .{});
        defer result.deinit();
        try std.testing.expect(result.record == .completed);
        try std.testing.expectEqual(@as(u64, if (alias) payload.len else 0), std.mem.readInt(u64, result.record.completed[0..8], .little));
        try std.testing.expectEqual(@as(u64, if (kind == 1) 0 else 1), stats.early_blob_collections);
    }
}

fn finish(resident: *runtime.Resident) void {
    resident.close() catch |err| switch (err) {
        error.InvalidState => return,
        error.UnfinishedSession => {
            var result = resident.drive(a, .none, .{}) catch unreachable;
            result.deinit();
            resident.close() catch unreachable;
        },
        else => unreachable,
    };
}

test "early blob collection rolls back byte-identically at every allocation failure" {
    const original = comptime program(false);
    const image = try a.alloc(u8, try data.program_image.encodedLength(original));
    defer a.free(image);
    _ = try data.program_image.encode(a, original, image);
    var prepared = try runtime.Prepared.init(a, image);
    defer prepared.deinit();
    const payload = try a.alloc(u8, 64 << 10);
    defer a.free(payload);
    @memset(payload, 'y');
    const args = try a.alloc(u8, payload.len + 10);
    defer a.free(args);
    var writer: data.wire.Writer = .{ .output = args };
    try writer.bytes(payload);
    var initial = try runtime.Session.start(a, &prepared, args[0..writer.position]);
    defer initial.deinit();
    const checkpoint = try initial.checkpoint(a);
    defer a.free(checkpoint);
    var reference = try runtime.Resident.restore(a, &prepared, checkpoint);
    defer finish(&reference);
    var expected = try reference.drive(a, .none, .{ .quantum = 1, .checkpoint = true });
    defer expected.deinit();
    var failed_after_collection = false;
    var completed = false;
    for (0..512) |failure| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        var resident = try runtime.Resident.restore(failing.allocator(), &prepared, checkpoint);
        defer {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            finish(&resident);
        }
        var stats: @import("../../src/interpreter_v2/runtime_types.zig").Statistics = .{};
        try resident.setStatistics(&stats);
        failing.fail_index = failing.alloc_index + failure;
        failing.resize_fail_index = failing.resize_index;
        var result = resident.drive(failing.allocator(), .none, .{ .quantum = 1, .checkpoint = true }) catch |err| {
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(!(try resident.diagnostics()).pending_blob_collection);
            failed_after_collection = failed_after_collection or stats.early_blob_collections != 0;
            const unchanged = try resident.checkpoint(a);
            defer a.free(unchanged);
            try std.testing.expectEqualSlices(u8, checkpoint, unchanged);
            var retried = try resident.drive(a, .none, .{ .quantum = 1, .checkpoint = true });
            defer retried.deinit();
            try std.testing.expectEqualDeep(expected.record, retried.record);
            continue;
        };
        defer result.deinit();
        try std.testing.expectEqualDeep(expected.record, result.record);
        try std.testing.expect(failed_after_collection and failure != 0);
        completed = true;
        break;
    }
    try std.testing.expect(completed);
}
