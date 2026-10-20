//! Project reachable execution values to the existing canonical graph grammar.
//! Private value nodes and their backing storage never become wire authority.
const std = @import("std");
const data = @import("horos_data");
const g = data.graph;
const Store = @import("store.zig").Store;
const Error = @import("runtime_types.zig").Error;

const Projection = struct {
    allocator: std.mem.Allocator,
    schemas: []const data.program.Schema,
    exportable: []const bool,
    store: *const Store,
    blobs: std.ArrayList(g.Blob) = .empty,
    encoded: std.AutoHashMapUnmanaged(u64, g.BlobRef) = .empty,

    fn value(self: *Projection, input: g.Value) Error!g.Value {
        if (input.body != .reference or !self.exportable[@intCast(input.schema)]) return input;
        const id = input.body.reference.id;
        if (self.encoded.get(id)) |ref| return .{
            .schema = input.schema,
            .body = .{ .blob = ref },
        };
        const bytes = try @import("value_encoding.zig").encode(
            self.allocator,
            self.schemas,
            self.store,
            input,
        );
        const reference: g.BlobRef = .{ .id = self.blobs.items.len };
        try self.blobs.append(self.allocator, .{ .schema = input.schema, .bytes = bytes });
        try self.encoded.put(self.allocator, id, reference);
        return .{ .schema = input.schema, .body = .{ .blob = reference } };
    }
    fn convert(self: *Projection, comptime T: type, input: T) Error!T {
        if (T == g.Value) return self.value(input);
        return switch (@typeInfo(T)) {
            .pointer => |info| blk: {
                if (info.child == u8) break :blk input;
                const result = try self.allocator.alloc(info.child, input.len);
                for (result, input) |*target, item|
                    target.* = try @call(.always_inline, convert, .{ self, info.child, item });
                break :blk result;
            },
            .@"struct" => |info| blk: {
                var result: T = undefined;
                inline for (info.field_names, info.field_types) |field_name, FieldType|
                    @field(result, field_name) = try @call(.always_inline, convert, .{
                        self,
                        FieldType,
                        @field(input, field_name),
                    });
                break :blk result;
            },
            .@"union" => switch (input) {
                inline else => |item, tag| @unionInit(
                    T,
                    @tagName(tag),
                    try @call(.always_inline, convert, .{ self, @TypeOf(item), item }),
                ),
            },
            .optional => |info| if (input) |item|
                try @call(.always_inline, convert, .{ self, info.child, item })
            else
                null,
            else => input,
        };
    }
};

/// All returned storage belongs to the supplied invocation-local arena. The
/// Store is read-only: repeated export cannot mutate cursor or custody state.
pub fn project(
    allocator: std.mem.Allocator,
    schemas: []const data.program.Schema,
    store: *const Store,
    state: anytype,
) Error!@TypeOf(state) {
    if (store.encoded_sequences.count() == 0) return state;
    return projectOrdinary(allocator, schemas, store, state);
}

/// The restricted base retains ordinary aggregates structurally as well as
/// sequence cursors. Materialize those values only at an explicit wire boundary.
pub fn projectOrdinary(
    allocator: std.mem.Allocator,
    schemas: []const data.program.Schema,
    store: *const Store,
    state: anytype,
) Error!@TypeOf(state) {
    const State = @TypeOf(state);
    const Node = std.meta.Elem(@FieldType(State, "nodes"));
    const facts = try data.admission.schemas(allocator, schemas);
    var projection: Projection = .{
        .allocator = allocator,
        .schemas = schemas,
        .exportable = facts.exportable,
        .store = store,
    };
    try projection.blobs.appendSlice(allocator, state.blobs);
    const nodes = try allocator.alloc(Node, state.nodes.len);
    for (nodes) |*node| node.* = if (Node == g.Node)
        .{ .environment = .{ .values = &.{}, .tail = null } }
    else
        .{ .record = .{ .environment = .{ .values = &.{}, .tail = null } } };
    const visited = try allocator.alloc(bool, nodes.len);
    @memset(visited, false);
    var pending: std.ArrayList(data.graph_order.Reference) = .empty;
    try data.graph_order.references(g.Roots, state.roots, &pending, allocator);
    while (pending.pop()) |reference| if (reference == .node) {
        const id: usize = @intCast(reference.node);
        if (id >= nodes.len) return error.InvalidReference;
        if (visited[id]) continue;
        visited[id] = true;
        nodes[id] = try projection.convert(Node, state.nodes[id]);
        try data.graph_order.references(Node, nodes[id], &pending, allocator);
    };
    var result = state;
    result.nodes = nodes;
    result.blobs = projection.blobs.items;
    return result;
}
