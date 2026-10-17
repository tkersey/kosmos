//! Guest records become ordinary outer values. Their numeric references retain
//! identity; guest internal-schema descriptors are data, never outer capabilities.
//! The facade obtains these projections from actual admission owners.
const std = @import("std");
const data = @import("horos_data");
const native = data.schema.native;
const wire = data.wire;
const source = @import("horos").source;

pub const Program = struct {
    identity: [32]u8,
    code: data.activation.Program,
    schemas: data.admission.SchemaFacts,
    uses: data.traits.Facts,
    /// Sorted live slot IDs at each block position, derived by the admitted
    /// owner. Private analysis-set handles never cross into the core.
    live: []const []const []const data.program.Id,
};
pub const State = data.process_state.State;
pub const Error = wire.Error || std.mem.Allocator.Error || error{InvalidValue};

pub fn schema(comptime T: type, builder: *source.Builder) source.Error!data.program.Id {
    return native.lower(native.info(T), builder);
}

pub fn programBytes(a: std.mem.Allocator, admitted: *const data.program_image.Admitted) ![]u8 {
    var analysis = try admitted.analysis(a);
    defer analysis.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const live = try scratch.alloc([]const []const data.program.Id, analysis.facts.live.len);
    for (live, analysis.facts.live) |*target, positions| {
        const entries = try scratch.alloc([]const data.program.Id, positions.len);
        for (entries, positions) |*entry, root| {
            var slots: std.ArrayList(data.program.Id) = .empty;
            var iterator = analysis.facts.pool.iterator(root);
            while (iterator.next()) |slot| try slots.append(scratch, slot);
            entry.* = slots.items;
        }
        target.* = entries;
    }
    return encode(Program, a, .{
        .identity = admitted.identity(),
        .code = admitted.program(),
        .schemas = admitted.schemaFacts(),
        .uses = admitted.traits(),
        .live = live,
    });
}

pub fn stateBytes(a: std.mem.Allocator, admitted: *const data.program_image.Admitted, state: State) ![]u8 {
    try data.state_admission.validateAdmitted(a, admitted, state);
    return encode(State, a, state);
}

/// Ordinary data admission is followed by guest program-relative admission.
/// Neither establishes execution history, semantic correspondence, or custody.
pub fn readState(a: std.mem.Allocator, admitted: *const data.program_image.Admitted, bytes: []const u8) !data.state_image.Owned {
    var decoded = try decode(State, a, bytes);
    defer decoded.deinit();
    var canonical = try data.state_image.canonicalize(a, decoded.value);
    errdefer canonical.deinit();
    try data.state_admission.validateAdmitted(a, admitted, canonical.state);
    return canonical;
}

pub fn encode(comptime T: type, a: std.mem.Allocator, value: T) Error![]u8 {
    var measure: wire.Writer = .{};
    try write(T, value, &measure);
    const bytes = try a.alloc(u8, measure.position);
    errdefer a.free(bytes);
    var output: wire.Writer = .{ .output = bytes };
    try write(T, value, &output);
    return bytes;
}

pub fn encodeInto(comptime T: type, buffer: []u8, value: T) Error![]const u8 {
    var writer: wire.Writer = .{ .output = buffer };
    try write(T, value, &writer);
    return buffer[0..writer.position];
}

pub fn Owned(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn decode(comptime T: type, a: std.mem.Allocator, bytes: []const u8) Error!Owned(T) {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var input: wire.Reader = .{ .input = bytes };
    const value = try read(T, arena.allocator(), &input);
    try input.finish();
    return .{ .arena = arena, .value = value };
}

// This is the existing schema-directed value encoding, with no new envelope.
// Reflection follows record fields, so record additions cannot be silently lost.
fn write(comptime T: type, value: T, output: *wire.Writer) Error!void {
    _ = comptime native.info(T);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try output.byte(@intFromBool(value)),
        .int => try output.fixed(T, value),
        .@"enum" => try output.fixed(u32, @intCast(@backingInt(value))),
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Child|
            try write(Child, @field(value, name), output),
        .@"union" => |info| inline for (info.field_names, info.field_types, 0..) |name, Child, index| {
            if (std.meta.activeTag(value) == @field(info.tag_type.?, name)) {
                try output.natural(index);
                return write(Child, @field(value, name), output);
            }
        },
        .optional => |info| {
            try output.natural(if (value == null) 0 else 1);
            if (value) |present| try write(info.child, present, output);
        },
        .array => |info| for (value) |element| try write(info.child, element, output),
        .pointer => |info| {
            try output.natural(value.len);
            if (info.child == u8) return output.put(value);
            if (comptime minimum(info.child) == 0) return;
            for (value) |element| try write(info.child, element, output);
        },
        else => @compileError("unsupported guest projection field " ++ @typeName(T)),
    }
}

fn minimum(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .void => 0,
        .bool => 1,
        .int => @sizeOf(T),
        .@"enum" => 4,
        .@"struct" => |info| blk: {
            var size: usize = 0;
            for (info.field_types) |Child| size += minimum(Child);
            break :blk size;
        },
        .array => |info| info.len * minimum(info.child),
        .@"union", .optional, .pointer => 1,
        else => @compileError("unsupported guest projection field " ++ @typeName(T)),
    };
}

fn read(comptime T: type, a: std.mem.Allocator, input: *wire.Reader) Error!T {
    _ = comptime native.info(T);
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => switch (try input.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidValue,
        },
        .int => input.fixed(T),
        .@"enum" => |info| blk: {
            const tag = try input.fixed(u32);
            inline for (info.field_names, info.field_values) |name, value|
                if (tag == value) break :blk @field(T, name);
            break :blk error.InvalidValue;
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, Child|
                @field(result, name) = try read(Child, a, input);
            break :blk result;
        },
        .@"union" => |info| blk: {
            const tag = try input.natural();
            inline for (info.field_names, info.field_types, 0..) |name, Child, index|
                if (tag == index) break :blk @unionInit(T, name, try read(Child, a, input));
            break :blk error.InvalidValue;
        },
        .optional => |info| switch (try input.natural()) {
            0 => null,
            1 => try read(info.child, a, input),
            else => error.InvalidValue,
        },
        .array => |info| blk: {
            var result: T = undefined;
            for (&result) |*element| element.* = try read(info.child, a, input);
            break :blk result;
        },
        .pointer => |info| blk: {
            const count = try input.count();
            const size = comptime minimum(info.child);
            if (size != 0 and count > (input.input.len - input.position) / size) return error.Truncated;
            _ = std.math.mul(usize, count, @sizeOf(info.child)) catch return error.Capacity;
            const result = try a.alloc(info.child, count);
            if (info.child == u8) {
                @memcpy(result, try input.take(count));
            } else if (comptime minimum(info.child) == 0) {
                // A zero-byte contract has exactly one value. Avoid a loop
                // proportional to a compressed unit count.
                if (count != 0) @memset(result, try read(info.child, a, input));
            } else for (result) |*element| element.* = try read(info.child, a, input);
            break :blk result;
        },
        else => @compileError("unsupported guest projection field " ++ @typeName(T)),
    };
}

test "actual guest program and state records derive only ordinary outer schemas" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    _ = try schema(Program, &b);
    _ = try schema(State, &b);
    for (b.schemas.items) |shape|
        try std.testing.expect(@import("../base/profile.zig").permitsSchema(std.meta.activeTag(shape)));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    _ = try data.admission.schemas(arena.allocator(), b.schemas.items);
}

test "projection preserves aliases cycles owners and dormant control as data" {
    const state: State = .{
        .program_identity = @splat(42),
        .status = .yielded,
        .roots = .{ .current = .{ .id = 0 } },
        .nodes = &.{
            .{ .record = .{ .environment = .{ .values = &.{
                .{ .schema = 1, .body = .{ .reference = .{ .id = 1 } } },
                .{ .schema = 1, .body = .{ .reference = .{ .id = 1 } } },
                .{ .schema = 1, .body = .{ .owned = .{ .node = .{ .id = 2 } } } },
            }, .tail = .{ .id = 0 } } } },
            .{ .record = .{ .obligation = .{ .source_block = 3, .cleanup = null, .status = .pending } } },
            .{ .record = .{ .obligation = .{ .source_block = 3, .cleanup = null, .status = .pending } } },
        },
    };
    // This deliberately cyclic record tests projection, not guest admission.
    const a = std.testing.allocator;
    const bytes = try encode(State, a, state);
    defer a.free(bytes);
    var decoded = try decode(State, a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(state, decoded.value);
    var b = source.Builder.init(a);
    defer b.deinit();
    const root = try schema(State, &b);
    try data.schema.validateReachableValue(a, b.schemas.items, root, bytes);
}

test "projection distinguishes enum values from union case positions" {
    const Record = struct { tag: data.program.TerminatorTag, term: data.activation.Terminator };
    const record: Record = .{ .tag = .dispose, .term = .{ .dispose = .{ .owned = 0, .next = .{ .block = 1 } } } };
    const a = std.testing.allocator;
    const bytes = try encode(Record, a, record);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(u8, 15), bytes[0]);
    try std.testing.expectEqual(@as(u8, 14), bytes[4]);
    var decoded = try decode(Record, a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(record, decoded.value);
    var b = source.Builder.init(a);
    defer b.deinit();
    const root = try schema(Record, &b);
    try data.schema.validateReachableValue(a, b.schemas.items, root, bytes);
}

test "projection rejects hostile counts before container allocation" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.Truncated, decode([]const State, a, &.{ 255, 255, 255, 255, 15 }));
    try std.testing.expectError(error.InvalidValue, decode(bool, a, &.{2}));
    try std.testing.expectError(error.InvalidValue, decode(?u64, a, &.{2}));
}
