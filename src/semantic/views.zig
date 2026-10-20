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

pub fn encode(a: std.mem.Allocator, view: GuestView) ![]u8 {
    return projection.encode(GuestView, a, view);
}
pub fn schemaBytes(a: std.mem.Allocator) ![]u8 {
    var b = @import("horos").source.Builder.init(a);
    defer b.deinit();
    const root = try projection.schema(GuestView, &b);
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
    if (!std.meta.eql(guest.identity(), binding.guest) or !std.meta.eql(
        artifact.digest(checkpoint),
        binding.checkpoint,
    )) return error.InvalidViewBinding;
    var state = try data.state_image.decodeGraph(a, checkpoint);
    defer state.deinit();
    try data.state_admission.validateAdmitted(a, guest, state.state);
    const encoded = try data.state_image.emit(a, state.state);
    defer a.free(encoded);
    if (!std.mem.eql(u8, checkpoint, encoded)) return error.NonCanonicalView;
    if (allowed) |mask| if (mask.len != state.state.nodes.len) return error.InvalidDisclosure;
    var result: Owned = .{ .arena = std.heap.ArenaAllocator.init(a), .value = undefined };
    errdefer result.deinit();
    var collector: Collector = .{ .a = result.arena.allocator(), .allowed = allowed };
    var nodes: std.ArrayList(Node) = .empty;
    var complete = true;
    for (state.state.nodes, 0..) |node, i| {
        if (!collector.permits(i)) {
            complete = false;
            continue;
        }
        const block: ?u64 = switch (node.record) {
            .control => |v| v.block,
            inline .continuation, .region_scope, .protection, .obligation, .pending => |v| blk: {
                break :blk v.source_block;
            },

            else => null,
        };
        try nodes.append(collector.a, .{
            .id = i,
            .tag = @backingInt(std.meta.activeTag(node.record)),
            .block = block,
            .position = if (node.activation) |v| v.position else null,
        });
        collector.from = i;
        try collector.walk(@TypeOf(node), node, "node", false);
    }
    collector.from = null;
    try collector.walk(g.Roots, state.state.roots, "roots", false);
    result.value = .{
        .binding = binding,
        .complete_graph = complete,
        .nodes = nodes.items,
        .roots = collector.roots.items,
        .edges = collector.edges.items,
    };
    return result;
}

const Collector = struct {
    a: std.mem.Allocator,
    allowed: ?[]const bool,
    from: ?u64 = null,
    roots: std.ArrayList(Root) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    fn permits(self: Collector, id: usize) bool {
        return if (self.allowed) |mask| id < mask.len and mask[id] else true;
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
    ) std.mem.Allocator.Error!void {
        @setEvalBranchQuota(100_000);
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
