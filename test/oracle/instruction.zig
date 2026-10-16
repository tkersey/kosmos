// Copyright (c) 2026 World contributors. MIT license.
//! Interpret current instructions using their function layout result schema.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const g = data.graph;
const read = @import("../../src/interpreter_v2/operands.zig").read;
pub const Result = @import("../../src/interpreter_v2/data_instruction.zig").Result;

pub fn execute(machine: anytype, instruction: data.activation.Instruction, result_type: p.Id, slots: anytype, aggregate_values: *@import("../../src/interpreter_v2/values.zig").Values) @TypeOf(machine.*).ExecutionError!Result {
    const value: g.Value = switch (instruction.opcode) {
        .constant, .move, .integer_add, .integer_sub, .integer_mul, .integer_div, .integer_rem, .integer_bit_and, .integer_bit_or, .integer_bit_xor, .equal, .less, .integer_bit_not, .integer_convert, .enum_tag, .boolean_not, .product, .field, .variant, .variant_tag, .variant_payload, .select, .sequence, .sequence_length, .sequence_get, .sequence_append, .sequence_concat, .sequence_pop, .sequence_set, .sequence_take, .sequence_pop_last, .blob_length, .blob_concat, .blob_slice, .blob_compare, .blob_byte, .text_scalar, .text_integer, .blob_from_byte => return @import("../../src/interpreter_v2/data_instruction.zig").execute(machine, instruction, result_type, slots, aggregate_values),
        .computation => blk: {
            const environment = try captureEnvironment(machine, slots, instruction.operands);
            const closure = try machine.store.add(.{ .computation = .{ .constructor = instruction.immediate, .environment = environment } });
            const use = machine.program.schemas[@intCast(result_type)].internal.computation.use;
            break :blk .{ .schema = result_type, .body = if (use == .reusable or use == .multi) .{ .reference = closure } else .{ .owned = .{ .node = closure } } };
        },
        .cell_new => blk: {
            const region = valueRef((try read(slots, instruction.operands[0])));
            const cell = try machine.store.add(.{ .cell = .{ .schema = result_type, .region = region, .value = (try read(slots, instruction.operands[1])) } });
            break :blk .{ .schema = result_type, .body = .{ .reference = cell } };
        },
        .cell_get => (try machine.store.get(valueRef((try read(slots, instruction.operands[0]))))).cell.value orelse return error.InvalidState,
        .cell_set => blk: {
            const reference = valueRef((try read(slots, instruction.operands[0])));
            var cell = (try machine.store.get(reference)).cell;
            cell.value = (try read(slots, instruction.operands[1]));
            try machine.store.replace(reference, .{ .cell = cell });
            break :blk .{ .schema = result_type, .body = .{ .scalar = @as([8]u8, @splat(0)) } };
        },
        .package => blk: {
            const package = try machine.store.add(.{ .package = .{ .schema = result_type, .continuation = (try read(slots, instruction.operands[0])) } });
            break :blk .{ .schema = result_type, .body = .{ .owned = .{ .node = package } } };
        },
        .unpack => (try machine.store.get(valueRef((try read(slots, instruction.operands[0]))))).package.continuation,
        .clone_resumption => blk: {
            var captured = try machine.takeCapture((try read(slots, instruction.operands[0])));
            captured.schema = result_type;
            const template = try machine.store.add(.{ .multi_template = captured });
            if (machine.statistics) |statistics| statistics.multi_templates +|= 1;
            break :blk .{ .schema = result_type, .body = .{ .reference = template } };
        },
        .resource_pack => blk: {
            const resource = try machine.store.add(.{ .resource = .{ .schema = result_type, .value = (try read(slots, instruction.operands[0])) } });
            break :blk .{ .schema = result_type, .body = .{ .owned = .{ .node = resource } } };
        },
        .resource_unpack => blk: {
            const record = try machine.store.get(valueRef((try read(slots, instruction.operands[0]))));
            break :blk (if (record == .borrow) (try machine.store.get(record.borrow.resource)).resource else record.resource).value;
        },
    };
    return .{ .value = value };
}

fn captureEnvironment(machine: anytype, slots: anytype, operands: []const p.Id) @TypeOf(machine.*).ExecutionError!g.NodeRef {
    const values = try machine.allocator.alloc(g.Value, operands.len);
    errdefer machine.allocator.free(values);
    for (values, operands) |*value, slot| value.* = try read(slots, slot);
    return machine.store.addOwned(.{ .environment = .{ .values = values, .tail = null } });
}

fn valueRef(value: g.Value) g.NodeRef {
    return switch (value.body) {
        .reference => |reference| reference,
        .owned => |owned| owned.node,
        else => unreachable,
    };
}
