// Copyright (c) 2026 World contributors. MIT license.
//! Application-independent operations on canonical pointer-free blobs.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const g = data.graph;
const Values = @import("values.zig").Values;
const Error = @import("runtime_types.zig").Error;
const read = @import("operands.zig").read;
pub const Result = union(enum) { value: g.Value, fault: p.Fault };

fn payload(values: *Values, value: g.Value) Error![]const u8 {
    var reader: data.wire.Reader = .{ .input = try values.bytes(&value) };
    const bytes = try reader.take(try reader.count());
    try reader.finish();
    return bytes;
}
fn maximum(shape: p.Schema) u64 {
    return switch (shape) {
        .bounded_text => |n| n,
        .bounded_bytes => |n| n,
        else => std.math.maxInt(u64),
    };
}
fn blob(values: *Values, schema: p.Id, parts: []const []const u8) Error!Result {
    var size: usize = 0;
    for (parts) |part| size = std.math.add(usize, size, part.len) catch return error.OutOfMemory;
    if (size > maximum(values.schemas[@intCast(schema)])) return .{ .fault = .capacity_exceeded };
    var measure: data.wire.Writer = .{};
    try measure.natural(size);
    const output = try values.store.allocator.alloc(
        u8,
        std.math.add(usize, measure.position, size) catch return error.OutOfMemory,
    );
    errdefer values.store.allocator.free(output);
    var writer: data.wire.Writer = .{ .output = output };
    try writer.natural(size);
    for (parts) |part| try writer.put(part);
    return .{ .value = try values.store.literalOwned(values.schemas, schema, output) };
}
pub fn evaluate(
    values: *Values,
    op: data.activation.Instruction,
    result_type: p.Id,
    slots: anytype,
) Error!Result {
    const left = (try read(slots, op.operands[0]));
    const result = result_type;
    switch (op.opcode) {
        .text_scalar => {
            const raw = std.mem.readInt(u32, left.body.scalar[0..4], .little);
            if (raw > std.math.maxInt(u21)) return .{ .fault = .invalid_utf8 };
            var storage: [4]u8 = undefined;
            const count = std.unicode.utf8Encode(@intCast(
                raw,
            ), &storage) catch return .{ .fault = .invalid_utf8 };
            return blob(values, result, &.{storage[0..count]});
        },
        .text_integer => {
            const n = try data.scalar.integer(
                values.schemas[@intCast(left.schema)],
                left.body.scalar,
            );
            var storage: [40]u8 = undefined;
            const text = std.fmt.bufPrint(&storage, "{d}", .{n}) catch return error.InvalidValue;
            return blob(values, result, &.{text});
        },
        .blob_from_byte => return blob(values, result, &.{left.body.scalar[0..1]}),
        else => {},
    }
    const a = try payload(values, left);
    if (op.opcode == .blob_length) return .{ .value = Values.natural(result, a.len) };
    return evaluatePayload(values, op, result, slots, a);
}

fn evaluatePayload(
    values: *Values,
    op: data.activation.Instruction,
    result: p.Id,
    slots: anytype,
    a: []const u8,
) Error!Result {
    const right = (try read(slots, op.operands[1]));
    switch (op.opcode) {
        .blob_concat => return blob(values, result, &.{ a, try payload(values, right) }),
        .blob_compare => {
            const order: i8 = switch (std.mem.order(u8, a, try payload(values, right))) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
            return .{ .value = .{ .schema = result, .body = .{
                .scalar = data.scalar.fromInteger(.i8, order).?,
            } } };
        },
        .blob_byte => {
            const index = std.mem.readInt(u64, right.body.scalar[0..8], .little);
            const shape = values.schemas[@intCast(result)].sum;
            const child = if (index < a.len) Values.natural(shape[1], a[
                @intCast(
                    index,
                )
            ]) else Values.natural(shape[0], 0);
            return .{ .value = try values.aggregate(result, .{
                .tag = @intFromBool(index < a.len),
                .fields = &.{child},
            }) };
        },
        .blob_slice => {
            const start = std.mem.readInt(u64, right.body.scalar[0..8], .little);
            const end = std.mem.readInt(
                u64,
                (try read(slots, op.operands[2])).body.scalar[0..8],
                .little,
            );
            if (start > end or end > a.len) return .{ .fault = .capacity_exceeded };
            const shape = values.schemas[@intCast(result)];
            const bytes = a[@intCast(start)..@intCast(end)];
            if (bytes.len > maximum(shape)) return .{ .fault = .capacity_exceeded };
            if ((shape == .text or shape == .bounded_text) and
                !std.unicode.utf8ValidateSlice(bytes)) return .{ .fault = .invalid_utf8 };
            return blob(values, result, &.{bytes});
        },
        else => return error.UnsupportedTransition,
    }
}
