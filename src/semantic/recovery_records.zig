const std = @import("std");
const old = @import("horos");
const current = @import("horos_recovery");
const data = current.data;
const Allocator = std.mem.Allocator;

pub fn encode(a: Allocator, value: anytype) ![]u8 {
    var size: data.wire.Writer = .{};
    try data.record.writeAlloc(@TypeOf(value), a, value, &size);
    const bytes = try a.alloc(u8, size.position);
    errdefer a.free(bytes);
    var out: data.wire.Writer = .{ .output = bytes };
    try data.record.writeAlloc(@TypeOf(value), a, value, &out);
    return bytes;
}

pub fn module(arena: Allocator, source: old.source.Module) !current.source.Module {
    const bytes = try encode(arena, source);
    var reader: data.wire.Reader = .{ .input = bytes };
    const result = try data.record.read(current.source.Module, &reader, arena);
    try reader.finish();
    return result;
}

pub fn image(a: Allocator, storage: Allocator, program: data.activation.Program) ![]u8 {
    const bytes = try storage.alloc(u8, try data.program_image.encodedLength(program));
    errdefer storage.free(bytes);
    _ = try data.program_image.encode(a, program, bytes);
    return bytes;
}

pub fn checkImage(
    a: Allocator,
    bytes: []const u8,
    owner: *const old.data.program_image.Admitted,
) !void {
    var decoded = try old.data.program_image.decode(a, bytes);
    defer decoded.deinit();
    if (!old.data.record.equal(old.data.activation.Program, decoded.program, owner.program()))
        return error.InvalidRecovery;
}
