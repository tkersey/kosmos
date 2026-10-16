// Copyright (c) 2026 World contributors. MIT license.
//! Level-independent ordinary value instructions shared by bootstrap and base.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const g = data.graph;
const read = @import("operands.zig").read;
pub const Result = union(enum) { value: g.Value, failed: g.Value };

pub fn execute(machine: anytype, instruction: data.activation.Instruction, result_type: p.Id, slots: anytype, aggregate_values: *@import("values.zig").Values) @TypeOf(machine.*).ExecutionError!Result {
    const value: g.Value = switch (instruction.opcode) {
        .constant => try machine.store.literal(machine.program.schemas, machine.program.constants[@intCast(instruction.immediate)]),
        .move => (try read(slots, instruction.operands[0])),
        .integer_add, .integer_sub, .integer_mul, .integer_div, .integer_rem, .integer_bit_and, .integer_bit_or, .integer_bit_xor, .equal, .less => blk: {
            const left = &(try read(slots, instruction.operands[0]));
            const right = &(try read(slots, instruction.operands[1]));
            const shape = machine.program.schemas[@intCast(left.schema)];
            const a = try data.scalar.fromBytes(shape, try machine.bytes(left));
            const b = try data.scalar.fromBytes(shape, try machine.bytes(right));
            switch (try data.scalar.binary(instruction.opcode, shape, a, b)) {
                .fault => |fault| {
                    const failure = try machine.instructionFailure(instruction, fault);
                    return .{ .failed = failure };
                },
                .value => |value| break :blk .{ .schema = result_type, .body = .{ .scalar = value } },
            }
        },
        .integer_bit_not, .integer_convert, .enum_tag => blk: {
            const source = (try read(slots, instruction.operands[0]));
            switch (try data.scalar.unary(instruction.opcode, machine.program.schemas[@intCast(source.schema)], machine.program.schemas[@intCast(result_type)], source.body.scalar)) {
                .value => |value| break :blk .{ .schema = result_type, .body = .{ .scalar = value } },
                .fault => |fault| {
                    return .{ .failed = try machine.instructionFailure(instruction, fault) };
                },
            }
        },
        .boolean_not => blk: {
            var value = @as([8]u8, @splat(0));
            value[0] = 1 - (try machine.bytes(&(try read(slots, instruction.operands[0]))))[0];
            break :blk .{ .schema = result_type, .body = .{ .scalar = value } };
        },
        .product, .field, .variant, .variant_tag, .variant_payload, .select, .sequence, .sequence_length, .sequence_get, .sequence_append, .sequence_concat, .sequence_pop, .sequence_set, .sequence_take, .sequence_pop_last => aggregate_values.evaluate(instruction, result_type, slots) catch |err| {
            const fault: p.Fault = switch (err) {
                error.CollectionCapacity => .capacity_exceeded,
                error.ElementIndex => .invalid_index,
                error.WrongVariant => .invalid_variant,
                else => |other| return other,
            };
            return .{ .failed = try machine.instructionFailure(instruction, fault) };
        },
        .blob_length, .blob_concat, .blob_slice, .blob_compare, .blob_byte, .text_scalar, .text_integer, .blob_from_byte => blk: {
            switch (try @import("blobs.zig").evaluate(aggregate_values, instruction, result_type, slots)) {
                .value => |value| break :blk value,
                .fault => |fault| {
                    return .{ .failed = try machine.instructionFailure(instruction, fault) };
                },
            }
        },
        .computation, .cell_new, .cell_get, .cell_set, .package, .unpack, .clone_resumption, .resource_pack, .resource_unpack => return error.UnsupportedTransition,
    };
    return .{ .value = value };
}
