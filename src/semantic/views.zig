//! Immutable descriptions of an admitted guest cut. These values carry no
//! continuation, receipt or execution grant. The caller owns disclosure.
const std = @import("std");
const data = @import("horos_data");
const projection = @import("projection.zig");
const artifact = @import("artifact.zig");
const g = data.graph;

pub const Binding = struct {
    guest: [32]u8,
    core: [32]u8,
    realization: [32]u8,
    checkpoint: [32]u8,
    execution: [32]u8,
    guest_revision: u64,
    realization_revision: u64,
    disclosure: [32]u8,
};
pub const Root = struct { node: u64, owned: bool, field: []const u8 };
pub const Edge = struct { from: u64, to: u64, owned: bool, field: []const u8 };
pub const Node = struct { id: u64, tag: u64, block: ?u64, position: ?u64 };
pub const GuestView = struct {
    binding: Binding,
    complete_graph: bool,
    // Only block/activation locations are available in this projection. Guest
    // payloads, source text and blob bytes are never implied by completeness.
    nodes: []const Node,
    roots: []const Root,
    edges: []const Edge,
};
pub const Owned = projection.Owned(GuestView);
pub const queries = @import("view_queries.zig");
pub const FieldSelection = struct { node: u64, field: []const u8 };
pub const ValueAccess = union(enum) {
    none,
    nodes: []const bool,
    fields: []const FieldSelection,
};
pub const BlobRange = struct { blob: u64, offset: u64, length: u64 };
pub const Disclosure = struct {
    nodes: ?[]const bool = null,
    values: ValueAccess = .none,
    blobs: []const BlobRange = &.{},
    snapshot: bool = false,
};
pub const TypedValue = struct { node: u64, field: []const u8, value: g.Value };
pub const Structure = struct { node: u64, schema: u64, tag: u64 };
pub const Schema = struct { id: u64, descriptor: []const u8 };
pub const BlobSlice = struct {
    blob: u64,
    schema: u64,
    offset: u64,
    total_bytes: u64,
    bytes: []const u8,
};
pub const Coverage = enum { not_requested, partial, complete };
pub const DetailedView = struct {
    contract: []const u8 = "kosmos.guest-view/2",
    metadata: GuestView,
    value_coverage: Coverage,
    values: []const TypedValue,
    structures: []const Structure,
    schemas: []const Schema,
    blobs: []const BlobSlice,
    snapshot: ?data.process_state.State = null,
};
pub const Detailed = struct {
    arena: std.heap.ArenaAllocator,
    value: DetailedView,
    snapshot_owner: ?data.state_image.Owned = null,

    pub fn deinit(self: *Detailed) void {
        if (self.snapshot_owner) |*owner| owner.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

const Captured = struct {
    arena: std.heap.ArenaAllocator,
    metadata: GuestView,
    values: []const TypedValue,
    structures: []const Structure,
    value_coverage: Coverage,
};

pub fn encode(a: std.mem.Allocator, view: GuestView) ![]u8 {
    return projection.encode(GuestView, a, view);
}
pub fn schemaBytes(a: std.mem.Allocator) ![]u8 {
    var b = @import("horos").source.Builder.init(a);
    defer b.deinit();
    const root = try projection.schema(GuestView, &b);
    return data.schema.encodeOwned(a, b.schemas.items, root);
}

pub fn encodeDetailed(a: std.mem.Allocator, view: DetailedView) ![]u8 {
    return projection.encode(DetailedView, a, view);
}

pub fn detailedSchemaBytes(a: std.mem.Allocator) ![]u8 {
    var b = @import("horos").source.Builder.init(a);
    defer b.deinit();
    const root = try projection.schema(DetailedView, &b);
    return data.schema.encodeOwned(a, b.schemas.items, root);
}

/// `allowed` is the enclosing owner's node disclosure mask, not model-supplied
/// permission. Null means that owner has authorized the whole reference graph.
/// Admission proves shape; the owner separately binds the actual publication.
pub fn capture(
    a: std.mem.Allocator,
    guest: *const data.program_image.Admitted,
    checkpoint: []const u8,
    binding: Binding,
    allowed: ?[]const bool,
) !Owned {
    var state = try admittedCut(a, guest, checkpoint, binding);
    defer state.deinit();
    const captured = try captureState(a, state.state, binding, .{ .nodes = allowed });
    return .{ .arena = captured.arena, .value = captured.metadata };
}

fn admittedCut(
    a: std.mem.Allocator,
    guest: *const data.program_image.Admitted,
    checkpoint: []const u8,
    binding: Binding,
) !data.state_image.Borrowed {
    if (!std.meta.eql(guest.identity(), binding.guest) or !std.meta.eql(
        artifact.digest(checkpoint),
        binding.checkpoint,
    )) return error.InvalidViewBinding;
    var state = try data.state_image.decodeGraphBorrowed(a, checkpoint, .{});
    errdefer state.deinit();
    try data.state_admission.validateAdmitted(a, guest, state.state);
    return state;
}

fn captureState(
    a: std.mem.Allocator,
    state: data.process_state.State,
    binding: Binding,
    disclosure: Disclosure,
) !Captured {
    if (disclosure.nodes) |mask| if (mask.len != state.nodes.len) return error.InvalidDisclosure;
    if (disclosure.values == .nodes and disclosure.values.nodes.len != state.nodes.len)
        return error.InvalidDisclosure;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var collector: Collector = .{
        .a = arena.allocator(),
        .allowed = disclosure.nodes,
        .value_access = disclosure.values,
    };
    var nodes: std.ArrayList(Node) = .empty;
    var structures: std.ArrayList(Structure) = .empty;
    var complete = true;
    for (state.nodes, 0..) |node, i| {
        if (!collector.permits(i)) {
            complete = false;
            continue;
        }
        try nodes.append(collector.a, describeNode(node, i));
        collector.from = i;
        try collector.walk(@TypeOf(node), node, "node", false);
        if (node.record == .aggregate and disclosure.values == .nodes and
            disclosure.values.nodes[i]) try structures.append(collector.a, .{
            .node = i,
            .schema = node.record.aggregate.schema,
            .tag = node.record.aggregate.tag,
        });
    }
    collector.from = null;
    try collector.walk(g.Roots, state.roots, "roots", false);
    return .{
        .arena = arena,
        .metadata = .{
            .binding = binding,
            .complete_graph = complete,
            .nodes = nodes.items,
            .roots = collector.roots.items,
            .edges = collector.edges.items,
        },
        .values = collector.values.items,
        .structures = structures.items,
        .value_coverage = if (disclosure.values == .none)
            .not_requested
        else if (complete and collector.complete_values) .complete else .partial,
    };
}

fn describeNode(node: data.process_state.Node, id: usize) Node {
    return .{
        .id = id,
        .tag = @backingInt(std.meta.activeTag(node.record)),
        .block = switch (node.record) {
            .control => |value| value.block,
            inline .continuation,
            .region_scope,
            .protection,
            .obligation,
            .pending,
            => |value| value.source_block,
            else => null,
        },
        .position = if (node.activation) |value| value.position else null,
    };
}

pub fn captureDetailed(
    a: std.mem.Allocator,
    guest: *const data.program_image.Admitted,
    checkpoint: []const u8,
    binding: Binding,
    disclosure: Disclosure,
) !Detailed {
    try validateSnapshotDisclosure(disclosure);
    var state = try admittedCut(a, guest, checkpoint, binding);
    defer state.deinit();
    var captured = try captureState(a, state.state, binding, disclosure);
    errdefer captured.arena.deinit();
    const storage = captured.arena.allocator();
    const schemas = try valueSchemas(storage, guest, captured.values, captured.structures);
    const blobs = try blobSlices(storage, state.state, captured.values, disclosure.blobs);
    const snapshot = if (disclosure.snapshot)
        try data.state_image.decodeGraph(a, checkpoint)
    else
        null;
    return .{ .arena = captured.arena, .snapshot_owner = snapshot, .value = .{
        .metadata = captured.metadata,
        .value_coverage = captured.value_coverage,
        .values = captured.values,
        .structures = captured.structures,
        .schemas = schemas,
        .blobs = blobs,
        .snapshot = if (snapshot) |owned| owned.state else null,
    } };
}

fn validateSnapshotDisclosure(disclosure: Disclosure) !void {
    if (!disclosure.snapshot) return;
    if (disclosure.nodes != null or disclosure.values != .nodes or disclosure.blobs.len != 0)
        return error.InvalidDisclosure;
    for (disclosure.values.nodes) |selected| if (!selected) return error.InvalidDisclosure;
}

fn valueSchemas(
    a: std.mem.Allocator,
    guest: *const data.program_image.Admitted,
    values: []const TypedValue,
    structures: []const Structure,
) ![]const Schema {
    var schemas: std.ArrayList(Schema) = .empty;
    for (values) |value| try appendSchema(a, guest, &schemas, value.value.schema);
    for (structures) |structure| try appendSchema(a, guest, &schemas, structure.schema);
    return schemas.items;
}

fn appendSchema(
    a: std.mem.Allocator,
    guest: *const data.program_image.Admitted,
    schemas: *std.ArrayList(Schema),
    id: u64,
) !void {
    for (schemas.items) |schema| if (schema.id == id) return;
    try schemas.append(a, .{
        .id = id,
        .descriptor = try data.schema.encodeOwned(a, guest.program().schemas, id),
    });
}

fn blobSlices(
    a: std.mem.Allocator,
    state: data.process_state.State,
    values: []const TypedValue,
    ranges: []const BlobRange,
) ![]const BlobSlice {
    const slices = try a.alloc(BlobSlice, ranges.len);
    for (ranges, slices) |range, *slice| {
        for (values) |value| {
            if (value.value.body == .blob and value.value.body.blob.id == range.blob) break;
        } else return error.InvalidDisclosure;
        if (range.blob >= state.blobs.len) return error.InvalidDisclosure;
        const blob = state.blobs[@intCast(range.blob)];
        if (range.offset > blob.bytes.len or range.length > blob.bytes.len - range.offset)
            return error.InvalidDisclosure;
        const start: usize = @intCast(range.offset);
        const end: usize = @intCast(range.offset + range.length);
        slice.* = .{
            .blob = range.blob,
            .schema = blob.schema,
            .offset = range.offset,
            .total_bytes = blob.bytes.len,
            .bytes = try a.dupe(u8, blob.bytes[start..end]),
        };
    }
    return slices;
}

const Collector = struct {
    a: std.mem.Allocator,
    allowed: ?[]const bool,
    from: ?u64 = null,
    roots: std.ArrayList(Root) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    value_access: ValueAccess = .none,
    values: std.ArrayList(TypedValue) = .empty,
    complete_values: bool = true,
    fn permits(self: Collector, id: usize) bool {
        return if (self.allowed) |mask| id < mask.len and mask[id] else true;
    }
    fn permitsValue(self: Collector, node: u64, field: []const u8) bool {
        return switch (self.value_access) {
            .none => false,
            .nodes => |mask| node < mask.len and mask[@intCast(node)],
            .fields => |fields| blk: {
                for (fields) |selected| {
                    if (selected.node == node and std.mem.eql(u8, selected.field, field))
                        break :blk true;
                }
                break :blk false;
            },
        };
    }
    fn appendValue(
        self: *Collector,
        value: g.Value,
        field: []const u8,
    ) (std.mem.Allocator.Error || error{InvalidDisclosure})!void {
        if (self.value_access == .none) return;
        const node = self.from orelse return error.InvalidDisclosure;
        const visible = switch (value.body) {
            .reference => |ref| self.permits(@intCast(ref.id)),
            .owned => |ref| self.permits(@intCast(ref.node.id)),
            else => true,
        };
        if (!visible or !self.permitsValue(node, field)) {
            self.complete_values = false;
            return;
        }
        try self.values.append(self.a, .{
            .node = node,
            .field = try self.a.dupe(u8, field),
            .value = value,
        });
    }
    fn appendReference(
        self: *Collector,
        value: g.NodeRef,
        path: []const u8,
        owned: bool,
    ) std.mem.Allocator.Error!void {
        if (!self.permits(@intCast(value.id))) return;
        const field = try self.a.dupe(u8, path);
        if (self.from) |from| {
            try self.edges.append(self.a, .{
                .from = from,
                .to = value.id,
                .owned = owned,
                .field = field,
            });
        } else try self.roots.append(self.a, .{
            .node = value.id,
            .owned = owned,
            .field = field,
        });
        return;
    }
    inline fn walk(
        self: *Collector,
        comptime T: type,
        value: T,
        path: []const u8,
        owned: bool,
    ) (std.mem.Allocator.Error || error{InvalidDisclosure})!void {
        @setEvalBranchQuota(100_000);
        if (T == g.Value) try self.appendValue(value, path);
        if (T == g.BlobRef) return;
        if (T == g.NodeRef) return self.appendReference(value, path, owned);
        if (T == g.OwnedRef)
            return @call(.always_inline, walk, .{ self, g.NodeRef, value.node, path, true });
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Child| {
                if (comptime containsReference(Child)) try @call(.always_inline, walk, .{
                    self,
                    Child,
                    @field(value, name),
                    try std.fmt.allocPrint(self.a, "{s}.{s}", .{ path, name }),
                    owned,
                });
            },
            .@"union" => switch (value) {
                inline else => |child, tag| if (comptime containsReference(@TypeOf(
                    child,
                ))) try @call(.always_inline, walk, .{
                    self,
                    @TypeOf(child),
                    child,
                    try std.fmt.allocPrint(self.a, "{s}.{s}", .{ path, @tagName(tag) }),
                    owned,
                }),
            },
            .optional => |info| if (value) |child| try @call(.always_inline, walk, .{
                self, info.child, child, path, owned,
            }),
            .pointer => |info| if (comptime containsReference(info.child)) {
                for (value, 0..) |child, i| try @call(.always_inline, walk, .{
                    self,
                    info.child,
                    child,
                    try std.fmt.allocPrint(self.a, "{s}[{d}]", .{ path, i }),
                    owned,
                });
            },
            .array => |info| if (comptime containsReference(info.child)) {
                for (value, 0..) |child, i| try @call(.always_inline, walk, .{
                    self,
                    info.child,
                    child,
                    try std.fmt.allocPrint(self.a, "{s}[{d}]", .{ path, i }),
                    owned,
                });
            },
            else => {},
        }
    }
};
inline fn containsReference(comptime T: type) bool {
    if (T == g.NodeRef or T == g.OwnedRef) return true;
    if (T == g.BlobRef) return false;
    return switch (@typeInfo(T)) {
        inline .pointer, .array, .optional => |info| @call(
            .always_inline,
            containsReference,
            .{info.child},
        ),
        inline .@"struct", .@"union" => |info| blk: {
            inline for (info.field_types) |Child|
                if (@call(.always_inline, containsReference, .{Child})) break :blk true;
            break :blk false;
        },
        else => false,
    };
}
