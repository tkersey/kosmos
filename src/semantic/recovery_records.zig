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

pub fn checkProgram(
    owner: *const old.data.program_image.Admitted,
    checked: data.activation.Program,
) !void {
    @setEvalBranchQuota(100_000);
    if (!sameRecords(owner.program(), checked)) return error.InvalidRecovery;
}

fn sameRecords(before: anytype, after: anytype) bool {
    return RecordPair(@TypeOf(before), @TypeOf(after)).equal(before, after);
}

fn RecordPair(comptime Before: type, comptime After: type) type {
    const layout = @typeInfo(Before);
    const other_layout = @typeInfo(After);
    std.debug.assert(std.meta.activeTag(layout) == std.meta.activeTag(other_layout));
    return struct {
        fn equal(before: Before, after: After) bool {
            return switch (layout) {
                .void => true,
                .int, .bool => before == after,
                .@"enum" => @backingInt(before) == @backingInt(after),
                .@"struct" => |info| blk: {
                    const names = other_layout.@"struct".field_names;
                    comptime std.debug.assert(info.field_names.len == names.len);
                    inline for (info.field_names, names) |old_name, new_name| {
                        comptime std.debug.assert(std.mem.eql(u8, old_name, new_name));
                        if (!sameRecords(@field(before, old_name), @field(after, new_name)))
                            break :blk false;
                    }
                    break :blk true;
                },
                .@"union" => switch (before) {
                    inline else => |value, tag| blk: {
                        const other = @field(other_layout.@"union".tag_type.?, @tagName(tag));
                        comptime std.debug.assert(@backingInt(tag) == @backingInt(other));
                        if (after != other) break :blk false;
                        break :blk sameRecords(value, @field(after, @tagName(tag)));
                    },
                },
                .optional => if (before) |value|
                    if (after) |other| sameRecords(value, other) else false
                else
                    after == null,
                inline .pointer, .array => |info| blk: {
                    if (before.len != after.len) break :blk false;
                    if (info.child == u8 and other_layout == .pointer)
                        break :blk std.mem.eql(u8, before, after);
                    for (before, after) |left, right| {
                        if (!sameRecords(left, right)) break :blk false;
                    }
                    break :blk true;
                },
                else => @compileError("unsupported program record " ++ @typeName(@TypeOf(before))),
            };
        }
    };
}

const opt = current.source.recovery_optimization;
const Derivation = @import("recovery_specialization.zig").Derivation;
pub const Evidence = struct { recovery: []const u8, derivation: ?Derivation };

pub const DecodedEvidence = struct {
    arena: std.heap.ArenaAllocator,
    value: Evidence,
    derivation_bytes: ?[]const u8,

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
    const start = reader.position;
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
    return .{
        .arena = arena,
        .value = .{ .recovery = inner, .derivation = derivation },
        .derivation_bytes = if (present) bytes[start..reader.position] else null,
    };
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
