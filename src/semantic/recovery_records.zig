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

const opt = current.source.recovery_optimization;
const Derivation = @import("recovery_specialization.zig").Derivation;
pub const Evidence = struct { recovery: []const u8, derivation: ?Derivation };

pub const DecodedEvidence = struct {
    arena: std.heap.ArenaAllocator,
    value: Evidence,

    pub fn deinit(self: *DecodedEvidence) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decodeEvidence(
    a: Allocator,
    bytes: []const u8,
    specialized: bool,
    limits: opt.Limits,
    work: *u64,
) !DecodedEvidence {
    if (bytes.len > limits.lowering_bytes) return error.Capacity;
    var reader: data.wire.Reader = .{ .input = bytes };
    const inner = try reader.bytes();
    if (inner.len > @max(limits.evidence_bytes, limits.structural_evidence_bytes))
        return error.ScalarFieldLimit;
    const present = switch (try reader.byte()) {
        0 => false,
        1 => true,
        else => return error.InvalidTag,
    };
    if (present != specialized) return error.InvalidRealization;
    try data.admission.spend(work, bytes.len);
    var logical = limits.lowering_bytes;
    var physical = limits.lowering_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    var arena = std.heap.ArenaAllocator.init(cap.allocator());
    errdefer arena.deinit();
    const derivation = if (present) blk: {
        const result = data.record.readBounded(Derivation, &reader, arena.allocator(), &logical);
        break :blk result catch |err| {
            if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
            return err;
        };
    } else null;
    try reader.finish();
    arena.child_allocator = a;
    return .{ .arena = arena, .value = .{ .recovery = inner, .derivation = derivation } };
}

pub fn encodeEvidence(
    a: Allocator,
    output: Allocator,
    value: Evidence,
    limits: opt.Limits,
) ![]u8 {
    var physical = limits.lowering_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    const scratch = cap.allocator();
    var available: u64 = limits.lowering_bytes;
    var size: data.wire.Writer = .{ .remaining = &available };
    try writeEvidence(scratch, value, &size, &cap);
    const bytes = try output.alloc(u8, size.position);
    errdefer output.free(bytes);
    var writer: data.wire.Writer = .{ .output = bytes };
    try writeEvidence(scratch, value, &writer, &cap);
    return bytes;
}

fn writeEvidence(
    scratch: Allocator,
    value: Evidence,
    writer: *data.wire.Writer,
    cap: *const data.AllocationBudget,
) !void {
    data.record.writeAlloc(Evidence, scratch, value, writer) catch |err| return switch (err) {
        error.RelationLimit => error.Capacity,
        error.OutOfMemory => if (cap.exhausted) error.Capacity else err,
        else => err,
    };
}
