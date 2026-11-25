// Copyright (c) 2026 World contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const g = data.graph;
const read = @import("../interpreter_v2/operands.zig").read;
const Values = @import("../interpreter_v2/values.zig").Values;
const Session = @import("session.zig").Session;
const Error = @import("session.zig").Error;
const valueRef = @import("control.zig").valueRef;
pub const Result = union(enum) { value: g.Value, failed: g.Value };
const zero: [8]u8 = @splat(0);

pub fn execute(
    session: *Session,
    instruction: data.activation.Instruction,
    result_type: p.Id,
    slots: anytype,
    values: *Values,
) Error!Result {
    return switch (instruction.opcode) {
        .constant => .{ .value = try session.store.literal(
            session.program.schemas,
            session.program.constants[@intCast(instruction.immediate)],
        ) },
        .move => .{ .value = try read(slots, instruction.operands[0]) },
        .integer_bit_not, .integer_convert, .enum_tag => unary(
            session,
            instruction,
            result_type,
            slots,
        ),
        .boolean_not => blk: {
            var value = zero;
            value[0] = 1 - (try session.bytes(&(try read(slots, instruction.operands[0]))))[0];
            break :blk .{ .value = .{ .schema = result_type, .body = .{ .scalar = value } } };
        },
        .blob_length,
        .blob_concat,
        .blob_slice,
        .blob_compare,
        .blob_byte,
        .text_scalar,
        .text_integer,
        .blob_from_byte,
        => switch (try @import("../interpreter_v2/blobs.zig").evaluate(
            values,
            instruction,
            result_type,
            slots,
        )) {
            .value => |value| .{ .value = value },
            .fault => |fault| .{ .failed = try session.instructionFailure(instruction, fault) },
        },
        else => composite(session, instruction, result_type, slots, values),
    };
}

fn composite(
    session: *Session,
    instruction: data.activation.Instruction,
    result_type: p.Id,
    slots: anytype,
    values: *Values,
) Error!Result {
    return switch (instruction.opcode) {
        .integer_add,
        .integer_sub,
        .integer_mul,
        .integer_div,
        .integer_rem,
        .integer_bit_and,
        .integer_bit_or,
        .integer_bit_xor,
        .equal,
        .less,
        => binary(session, instruction, result_type, slots),
        .product,
        .field,
        .variant,
        .variant_tag,
        .variant_payload,
        .select,
        .sequence,
        .sequence_length,
        .sequence_get,
        .sequence_append,
        .sequence_concat,
        .sequence_pop,
        .sequence_set,
        .sequence_take,
        .sequence_pop_last,
        => aggregate(session, instruction, result_type, slots, values),
        else => .{ .value = try storage(session, instruction, result_type, slots) },
    };
}

fn binary(
    session: *Session,
    instruction: data.activation.Instruction,
    result_type: p.Id,
    slots: anytype,
) Error!Result {
    const left = &(try read(slots, instruction.operands[0]));
    const right = &(try read(slots, instruction.operands[1]));
    const shape = session.program.schemas[@intCast(left.schema)];
    const a = try data.scalar.fromBytes(shape, try session.bytes(left));
    const b = try data.scalar.fromBytes(shape, try session.bytes(right));
    return switch (try data.scalar.binary(instruction.opcode, shape, a, b)) {
        .fault => |fault| .{ .failed = try session.instructionFailure(instruction, fault) },
        .value => |value| .{ .value = .{ .schema = result_type, .body = .{ .scalar = value } } },
    };
}

fn unary(
    session: *Session,
    instruction: data.activation.Instruction,
    result_type: p.Id,
    slots: anytype,
) Error!Result {
    const source = try read(slots, instruction.operands[0]);
    return switch (try data.scalar.unary(
        instruction.opcode,
        session.program.schemas[@intCast(source.schema)],
        session.program.schemas[@intCast(result_type)],
        source.body.scalar,
    )) {
        .value => |value| .{ .value = .{ .schema = result_type, .body = .{ .scalar = value } } },
        .fault => |fault| .{ .failed = try session.instructionFailure(instruction, fault) },
    };
}

fn aggregate(
    session: *Session,
    instruction: data.activation.Instruction,
    result_type: p.Id,
    slots: anytype,
    values: *Values,
) Error!Result {
    const value = values.evaluate(instruction, result_type, slots) catch |err| {
        const fault: p.Fault = switch (err) {
            error.CollectionCapacity => .capacity_exceeded,
            error.ElementIndex => .invalid_index,
            error.WrongVariant => .invalid_variant,
            else => |other| return other,
        };
        return .{ .failed = try session.instructionFailure(instruction, fault) };
    };
    return .{ .value = value };
}

fn storage(
    session: *Session,
    instruction: data.activation.Instruction,
    result_type: p.Id,
    slots: anytype,
) Error!g.Value {
    const store = &session.store;
    const operands = instruction.operands;
    return switch (instruction.opcode) {
        .computation => computation(session, instruction, result_type, slots),
        .cell_new => .{ .schema = result_type, .body = .{ .reference = try store.add(.{ .cell = .{
            .schema = result_type,
            .region = valueRef(try read(slots, operands[0])),
            .value = try read(slots, operands[1]),
        } }) } },
        .cell_get => (try store.get(valueRef(try read(slots, operands[0])))).cell.value orelse
            error.InvalidState,
        .cell_set => blk: {
            const reference = valueRef(try read(slots, operands[0]));
            var cell = (try store.get(reference)).cell;
            cell.value = try read(slots, operands[1]);
            try store.replace(reference, .{ .cell = cell });
            break :blk .{ .schema = result_type, .body = .{ .scalar = zero } };
        },
        .package => .{ .schema = result_type, .body = .{ .owned = .{
            .node = try store.add(.{ .package = .{
                .schema = result_type,
                .continuation = try read(slots, operands[0]),
            } }),
        } } },
        .unpack => (try store.get(valueRef(try read(slots, operands[0])))).package.continuation,
        .clone_resumption => cloneResumption(session, result_type, slots, operands[0]),
        .resource_pack => .{ .schema = result_type, .body = .{ .owned = .{
            .node = try store.add(.{ .resource = .{
                .schema = result_type,
                .value = try read(slots, operands[0]),
            } }),
        } } },
        .resource_unpack => blk: {
            const record = try store.get(valueRef(try read(slots, operands[0])));
            const resource = if (record == .borrow)
                (try store.get(record.borrow.resource)).resource
            else
                record.resource;
            break :blk resource.value;
        },
        else => unreachable,
    };
}

fn computation(
    session: *Session,
    instruction: data.activation.Instruction,
    result_type: p.Id,
    slots: anytype,
) Error!g.Value {
    const environment = try captureEnvironment(session, slots, instruction.operands);
    const closure = try session.store.add(.{ .computation = .{
        .constructor = instruction.immediate,
        .environment = environment,
    } });
    const use = session.program.schemas[@intCast(result_type)].internal.computation.use;
    return .{
        .schema = result_type,
        .body = if (use == .reusable or use == .multi)
            .{ .reference = closure }
        else
            .{ .owned = .{ .node = closure } },
    };
}

fn cloneResumption(
    session: *Session,
    result_type: p.Id,
    slots: anytype,
    operand: p.Id,
) Error!g.Value {
    var captured = try session.takeCapture(try read(slots, operand));
    captured.schema = result_type;
    const template = try session.store.add(.{ .multi_template = captured });
    if (session.statistics) |statistics| statistics.multi_templates +|= 1;
    return .{ .schema = result_type, .body = .{ .reference = template } };
}

fn captureEnvironment(session: *Session, slots: anytype, operands: []const p.Id) Error!g.NodeRef {
    const values = try session.allocator.alloc(g.Value, operands.len);
    errdefer session.allocator.free(values);
    for (values, operands) |*value, slot| value.* = try read(slots, slot);
    return session.store.addOwned(.{ .environment = .{ .values = values, .tail = null } });
}
