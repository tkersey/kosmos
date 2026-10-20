//! Read-only encoding of immutable execution values. Memoized size discovery
//! rejects cycles and avoids exponential work on shared or zero-width values.
const std = @import("std");
const data = @import("horos_data");
const g = data.graph;
const p = data.program;
const Store = @import("store.zig").Store;
const Error = @import("runtime_types.zig").Error;
const Size = struct { done: bool = false, bytes: usize = 0 };
const Visit = struct { value: g.Value, leave: bool = false };

const Encoder = struct {
    allocator: std.mem.Allocator,
    schemas: []const p.Schema,
    store: *const Store,
    sizes: std.AutoHashMapUnmanaged(p.Id, Size) = .empty,

    fn header(self: *Encoder, value: g.Value, writer: *data.wire.Writer) Error!void {
        const node = self.store.nodes.items[@intCast(value.body.reference.id)].aggregate;
        const count = if (self.store.encoded_sequences.get(@intCast(value.body.reference.id))) |v|
            v.count
        else
            node.fields.len;
        switch (self.schemas[@intCast(value.schema)]) {
            .product, .array => {},
            .sum => try writer.natural(node.tag),
            .seq, .vector => try writer.natural(count),
            else => return error.InvalidValue,
        }
    }
    fn size(self: *Encoder, value: g.Value) Error!usize {
        return switch (value.body) {
            .scalar => data.scalar.width(self.schemas[@intCast(value.schema)]) orelse
                return error.InvalidValue,
            .blob => |ref| self.store.blobs.items[@intCast(ref.id)].bytes.len,
            .reference => |ref| (self.sizes.get(ref.id) orelse return error.InvalidState).bytes,
            .owned => error.InvalidValue,
        };
    }
    fn discover(self: *Encoder, root: g.Value) Error!usize {
        var pending: std.ArrayList(Visit) = .empty;
        defer pending.deinit(self.allocator);
        try pending.append(self.allocator, .{ .value = root });
        while (pending.pop()) |visit| {
            if (visit.value.body != .reference) continue;
            const ref = visit.value.body.reference;
            if (ref.id >= self.store.nodes.items.len or !self.store.alive.items[@intCast(ref.id)])
                return error.InvalidReference;
            const node = self.store.nodes.items[@intCast(ref.id)];
            if (node != .aggregate or node.aggregate.schema != visit.value.schema)
                return error.InvalidValue;
            if (visit.leave) {
                var measure: data.wire.Writer = .{};
                try self.header(visit.value, &measure);
                var length = measure.position;
                if (self.store.encoded_sequences.get(@intCast(ref.id))) |sequence| {
                    length = std.math.add(usize, length, sequence.length) catch
                        return error.InvalidLength;
                } else for (node.aggregate.fields) |field| {
                    length = std.math.add(
                        usize,
                        length,
                        try self.size(field),
                    ) catch return error.InvalidLength;
                }
                self.sizes.getPtr(ref.id).?.* = .{ .done = true, .bytes = length };
                continue;
            }
            const entry = try self.sizes.getOrPut(self.allocator, ref.id);
            if (entry.found_existing) {
                if (!entry.value_ptr.done) return error.InvalidValue;
                continue;
            }
            entry.value_ptr.* = .{};
            try pending.append(self.allocator, .{ .value = visit.value, .leave = true });
            if (!self.store.encoded_sequences.contains(@intCast(ref.id))) {
                var i = node.aggregate.fields.len;
                while (i != 0) {
                    i -= 1;
                    try pending.append(self.allocator, .{ .value = node.aggregate.fields[i] });
                }
            }
        }
        return self.size(root);
    }
    fn write(self: *Encoder, root: g.Value, writer: *data.wire.Writer) Error!void {
        var pending: std.ArrayList(g.Value) = .empty;
        defer pending.deinit(self.allocator);
        try pending.append(self.allocator, root);
        while (pending.pop()) |value| switch (value.body) {
            .scalar => |scalar| try writer.put(scalar[0..try self.size(value)]),
            .blob => |ref| try writer.put(self.store.blobs.items[@intCast(ref.id)].bytes),
            .reference => |ref| {
                if (try self.size(value) == 0) continue;
                try self.header(value, writer);
                if (self.store.encoded_sequences.get(@intCast(ref.id))) |sequence| {
                    const bytes = self.store.blobs.items[@intCast(sequence.backing.id)].bytes;
                    try writer.put(bytes[sequence.start..][0..sequence.length]);
                } else {
                    const fields = self.store.nodes.items[@intCast(ref.id)].aggregate.fields;
                    var i = fields.len;
                    while (i != 0) {
                        i -= 1;
                        try pending.append(self.allocator, fields[i]);
                    }
                }
            },
            .owned => return error.InvalidValue,
        };
    }
};

pub fn encode(
    allocator: std.mem.Allocator,
    schemas: []const p.Schema,
    store: *const Store,
    value: g.Value,
) Error![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var encoder: Encoder = .{
        .allocator = scratch.allocator(),
        .schemas = schemas,
        .store = store,
    };
    const length = try encoder.discover(value);
    const bytes = try allocator.alloc(u8, length);
    errdefer allocator.free(bytes);
    var writer: data.wire.Writer = .{ .output = bytes };
    try encoder.write(value, &writer);
    std.debug.assert(writer.position == length);
    return bytes;
}
