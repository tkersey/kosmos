const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const base = @import("../base/session.zig");
const native = @import("native_baseline");
const a = std.testing.allocator;
const support = @import("test_support.zig");
const Output = support.Output;

test "authored guest scalar instruction cuts equal native canonical PST3" {
    var core = try support.prepareCore();
    defer core.deinit();
    const image = try support.guestImage();
    defer a.free(image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    for ([_]u64{ 0, 17, std.math.maxInt(u64) - 7 }) |input| {
        var guest = try native.Session.initImage(a, image, &std.mem.toBytes(input));
        defer guest.deinit();
        for (0..7) |instruction| {
            const before = try guest.checkpoint(a);
            defer a.free(before);
            var decoded = try data.state_image.decodeGraph(a, before);
            defer decoded.deinit();
            const state = try projection.stateBytes(a, admitted, decoded.state);
            defer a.free(state);
            const arguments = try std.mem.concat(a, u8, &.{ program, state });
            defer a.free(arguments);
            var portable = try base.Session.start(a, &core, arguments, .{});
            defer portable.deinit();
            const outcome = try portable.run(null);
            if (outcome != .completed) std.debug.print(
                "portable instruction {d}: {s}\n",
                .{ instruction, @tagName(outcome) },
            );
            try std.testing.expect(outcome == .completed);
            var result = try projection.decode(Output, a, try portable.bytes(&outcome.completed));
            defer result.deinit();
            try std.testing.expectEqual(@as(u64, 1), result.value.work);
            try support.expectNativeSuccessor(&guest, admitted, result.value.state);
        }
    }
}

test "authored instruction faults enter guest failure unwinding at the same native cut" {
    var core = try support.prepareCore();
    defer core.deinit();
    const image = try support.guestImage();
    defer a.free(image);
    for ([_]u64{ std.math.maxInt(u64) - 6, std.math.maxInt(u64) }) |input|
        try support.expectNativeCuts(&core, image, &std.mem.toBytes(input), 40);
}

fn controlImage() ![]u8 {
    const image = try a.alloc(u8, try data.program_image.encodedLength(control_program));
    errdefer a.free(image);
    _ = try data.program_image.encode(a, control_program, image);
    return image;
}

test "authored simultaneous edges branches calls and returns equal every native cut" {
    var core = try support.prepareCore();
    defer core.deinit();
    const image = try controlImage();
    defer a.free(image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    for ([_]bool{ false, true }) |condition| {
        const input = try std.mem.concat(a, u8, &.{
            &std.mem.toBytes(@as(
                u64,
                39,
            )),
            &std.mem.toBytes(@as(
                u64,
                11,
            )),
            &.{@intFromBool(
                condition,
            )},
        });
        defer a.free(input);
        var guest = try native.Session.initImage(a, image, input);
        defer guest.deinit();
        for (0..16) |cut| {
            const before = try guest.checkpoint(a);
            defer a.free(before);
            var decoded = try data.state_image.decodeGraph(a, before);
            defer decoded.deinit();
            if (decoded.state.status == .completed) break;
            try std.testing.expect(cut < 15);
            const state = try projection.stateBytes(a, admitted, decoded.state);
            defer a.free(state);
            const arguments = try std.mem.concat(a, u8, &.{ program, state });
            defer a.free(arguments);
            var portable = try base.Session.start(a, &core, arguments, .{});
            defer portable.deinit();
            const outcome = try portable.run(null);
            if (outcome != .completed) std.debug.print(
                "control cut {d}: {s}\n",
                .{ cut, @tagName(outcome) },
            );
            try std.testing.expect(outcome == .completed);
            var result = try projection.decode(Output, a, try portable.bytes(&outcome.completed));
            defer result.deinit();
            try std.testing.expectEqual(@as(u64, 1), result.value.work);
            try support.expectNativeSuccessor(&guest, admitted, result.value.state);
        }
    }
}

test "authored products variants projections selection and aggregate control match native cuts" {
    var core = try support.prepareCore();
    defer core.deinit();

    const image = try a.alloc(u8, try data.program_image.encodedLength(aggregate_program));
    defer a.free(image);
    _ = try data.program_image.encode(a, aggregate_program, image);
    for ([_]u64{ 0, 1, std.math.maxInt(u64) }) |input| try support.expectNativeCuts(
        &core,
        image,
        &std.mem.toBytes(input),
        20,
    );
}

const control_continuation: data.activation.Edge = .{ .block = 4, .assignments = &.{
    .{ .destination = 3, .source = .returned },
    .{ .destination = 4, .source = .{ .slot = 0 } },
} };

const control_program: data.activation.Program = .{
    .roots = .{ .entry = 0, .result = 1, .failure = 0 },
    .schemas = &.{ .unit, .u64, .boolean },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 1, 1, 2, 1, 1, 1 } },
            .result = 1,
        },
        .{
            .entry = 5,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 1, 1, 1 } },
            .result = 1,
        },
        .{
            .entry = 6,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 1, 1, 1 } },
            .result = 1,
        },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{
                .jump = .{
                    .block = 1,
                    .assignments = &.{
                        .{ .destination = 0, .source = .{ .slot = 1 } },
                        .{ .destination = 1, .source = .{ .slot = 0 } },
                    },
                },
            },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .branch = .{
            .condition = 2,
            .when_true = .{ .block = 2 },
            .when_false = .{ .block = 3 },
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .call = .{
            .function = 1,
            .arguments = &.{ 0, 1 },
            .next = control_continuation,
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .call = .{
            .function = 2,
            .arguments = &.{ 0, 1 },
            .next = control_continuation,
        } } },
        .{ .function = 0, .instructions = &.{.{
            .destination = 5,
            .opcode = .integer_bit_xor,
            .operands = &.{ 3, 4 },
        }}, .terminator = .{ .return_value = 5 } },
        .{ .function = 1, .instructions = &.{.{
            .destination = 2,
            .opcode = .integer_bit_xor,
            .operands = &.{ 0, 1 },
        }}, .terminator = .{ .return_value = 2 } },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{
                .call = .{
                    .function = 1,
                    .arguments = &.{ 1, 0 },
                    .next = .{
                        .block = 7,
                        .assignments = &.{.{
                            .destination = 2,
                            .source = .returned,
                        }},
                    },
                },
            },
        },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
    },
};

const aggregate_program: data.activation.Program = .{
    .roots = .{ .entry = 0, .result = 1, .failure = 0 },
    .schemas = &.{
        .unit, .u64, .bytes, .{ .product = &.{ 1, 2 } }, .{ .sum = &.{ 0, 3 } }, .boolean,
    },
    .constants = &.{ .{ .schema = 0, .bytes = &.{} }, .{
        .schema = 2,
        .bytes = &.{ 3, 4, 5, 6 },
    } },
    .effects = &.{},
    .functions = &.{.{ .entry = 0, .inputs = &.{0}, .layout = .{
        .slots = &.{ 1, 2, 3, 4, 1, 3, 1, 5, 3, 1, 2 },
    }, .result = 1 }},
    .blocks = &.{
        .{ .function = 0, .instructions = &.{
            .{ .destination = 1, .opcode = .constant, .immediate = 1 },
            .{ .destination = 2, .opcode = .product, .operands = &.{ 0, 1 } },
            .{ .destination = 3, .opcode = .variant, .operands = &.{2}, .immediate = 1 },
            .{ .destination = 4, .opcode = .variant_tag, .operands = &.{3} },
            .{
                .destination = 5,
                .opcode = .variant_payload,
                .operands = &.{3},
                .immediate = 1,
                .failures = &.{.{
                    .kind = .invalid_variant,
                    .value = 0,
                }},
            },
            .{ .destination = 6, .opcode = .field, .operands = &.{5}, .immediate = 0 },
            .{ .destination = 7, .opcode = .less, .operands = &.{ 6, 4 } },
            .{ .destination = 8, .opcode = .select, .operands = &.{ 7, 2, 5 } },
        }, .terminator = .{
            .switch_variant = .{
                .value = 3,
                .cases = &.{
                    .{ .block = 2 },
                    .{
                        .block = 1,
                        .assignments = &.{.{
                            .destination = 8,
                            .source = .returned,
                        }},
                    },
                },
            },
        } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .unpack_product = .{
            .value = 8,
            .destinations = &.{ 9, 10 },
            .next = .{ .block = 3 },
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 9 } },
    },
};
