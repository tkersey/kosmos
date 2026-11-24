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

pub fn limitedImage(
    a: Allocator,
    program: data.activation.Program,
    storage_bytes: usize,
    work: *u64,
) ![]u8 {
    const size = try data.program_image.encodedLengthWithWork(program, work);
    if (size > storage_bytes) return error.Capacity;
    try data.admission.spend(work, size);
    var physical = storage_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    const bytes = try a.alloc(u8, size);
    errdefer a.free(bytes);
    _ = data.program_image.encode(cap.allocator(), program, bytes) catch |err| {
        if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
        return err;
    };
    return bytes;
}

pub fn targetProgram(
    arena: Allocator,
    owner: *const old.data.program_image.Admitted,
    storage_bytes: usize,
    work: *u64,
) !data.activation.Program {
    const program = owner.program();
    var measure: data.wire.Writer = .{ .remaining = work };
    try data.record.write(@TypeOf(program), program, &measure);
    if (measure.position > storage_bytes) return error.Capacity;
    try data.admission.spend(work, measure.position);
    const bytes = try arena.alloc(u8, measure.position);
    var out: data.wire.Writer = .{ .output = bytes, .remaining = work };
    try data.record.write(@TypeOf(program), program, &out);
    var reader: data.wire.Reader = .{ .input = bytes };
    var capacity = storage_bytes - bytes.len;
    const target = try data.record.readBounded(data.activation.Program, &reader, arena, &capacity);
    try reader.finish();
    try checkProgramWithWork(owner, target, work);
    return target;
}

pub fn checkProgram(
    owner: *const old.data.program_image.Admitted,
    checked: data.activation.Program,
) !void {
    return checkProgramWithWork(owner, checked, null);
}

pub fn checkProgramWithWork(
    owner: *const old.data.program_image.Admitted,
    checked: data.activation.Program,
    work: ?*u64,
) !void {
    @setEvalBranchQuota(100_000);
    if (!try sameRecords(owner.program(), checked, work)) return error.InvalidRecovery;
}

fn sameRecords(before: anytype, after: anytype, work: ?*u64) error{RelationLimit}!bool {
    return RecordPair(@TypeOf(before), @TypeOf(after)).equal(before, after, work);
}

fn RecordPair(comptime Before: type, comptime After: type) type {
    const layout = @typeInfo(Before);
    const other_layout = @typeInfo(After);
    std.debug.assert(std.meta.activeTag(layout) == std.meta.activeTag(other_layout));
    return struct {
        fn equal(before: Before, after: After, work: ?*u64) error{RelationLimit}!bool {
            try data.admission.spend(work, 1);
            return switch (layout) {
                .void => true,
                .int, .bool => before == after,
                .@"enum" => @backingInt(before) == @backingInt(after),
                .@"struct" => |info| blk: {
                    const names = other_layout.@"struct".field_names;
                    comptime std.debug.assert(info.field_names.len == names.len);
                    inline for (info.field_names, names) |old_name, new_name| {
                        comptime std.debug.assert(std.mem.eql(u8, old_name, new_name));
                        if (!try sameRecords(
                            @field(before, old_name),
                            @field(after, new_name),
                            work,
                        ))
                            break :blk false;
                    }
                    break :blk true;
                },
                .@"union" => switch (before) {
                    inline else => |value, tag| blk: {
                        const other = @field(other_layout.@"union".tag_type.?, @tagName(tag));
                        comptime std.debug.assert(@backingInt(tag) == @backingInt(other));
                        if (after != other) break :blk false;
                        break :blk try sameRecords(value, @field(after, @tagName(tag)), work);
                    },
                },
                .optional => if (before) |value|
                    if (after) |other| try sameRecords(value, other, work) else false
                else
                    after == null,
                inline .pointer, .array => |info| blk: {
                    if (before.len != after.len) break :blk false;
                    if (info.child == u8 and other_layout == .pointer) {
                        try data.admission.spend(work, before.len);
                        break :blk std.mem.eql(u8, before, after);
                    }
                    for (before, after) |left, right| {
                        if (!try sameRecords(left, right, work)) break :blk false;
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

    pub fn deinit(self: *DecodedEvidence) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const EvidenceParts = struct { recovery: []const u8, derivation: ?[]const u8 };

pub fn evidenceParts(bytes: []const u8, specialized: bool, limits: opt.Limits) !EvidenceParts {
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
    if (!present) try reader.finish();
    return .{ .recovery = inner, .derivation = if (present) bytes[reader.position..] else null };
}

pub fn decodeEvidence(
    a: Allocator,
    bytes: []const u8,
    specialized: bool,
    limits: opt.Limits,
    work: *u64,
) !DecodedEvidence {
    const parts = try evidenceParts(bytes, specialized, limits);
    try data.admission.spend(work, bytes.len);
    var logical = limits.lowering_bytes;
    var physical = limits.lowering_bytes;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    var arena = std.heap.ArenaAllocator.init(cap.allocator());
    errdefer arena.deinit();
    const derivation = if (parts.derivation) |raw| blk: {
        var reader: data.wire.Reader = .{ .input = raw };
        const result = data.record.readBounded(Derivation, &reader, arena.allocator(), &logical);
        const parsed = result catch |err| {
            if (err == error.OutOfMemory and cap.exhausted) return error.Capacity;
            return err;
        };
        try reader.finish();
        break :blk parsed;
    } else null;
    arena.child_allocator = a;
    return .{
        .arena = arena,
        .value = .{ .recovery = parts.recovery, .derivation = derivation },
    };
}

pub fn transportBytes(a: Allocator, proof: opt.Evidence, limits: opt.Limits, work: *u64) ![]u8 {
    const maximum = switch (proof.rule) {
        .structural_fallback => limits.structural_evidence_bytes,
        .scalar_field_reuse_v1 => limits.evidence_bytes,
        else => return error.UnsupportedVersion,
    };
    var measure: data.wire.Writer = .{ .remaining = work };
    try data.record.write(opt.Evidence, proof, &measure);
    if (measure.position > maximum) return error.ScalarFieldLimit;
    const bytes = try a.alloc(u8, measure.position);
    errdefer a.free(bytes);
    var writer: data.wire.Writer = .{ .output = bytes, .remaining = work };
    try data.record.write(opt.Evidence, proof, &writer);
    return bytes;
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
