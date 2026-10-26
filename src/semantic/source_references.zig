const std = @import("std");
const source = @import("horos").source;
const artifact = @import("artifact.zig");
const relocation = source.relation.Relocation;
pub const Reference = relocation.Reference;
pub const Value = struct {
    source: artifact.Digest,
    users: []const []const []const Reference,
};
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const List = std.ArrayList(Reference);
const kind_names = @typeInfo(relocation.Kind).@"enum".field_names;

pub fn init(
    a: std.mem.Allocator,
    module: source.Module,
    digest: artifact.Digest,
) !Owned {
    var temporary = std.heap.ArenaAllocator.init(a);
    defer temporary.deinit();
    var work: u64 = std.math.maxInt(u64);
    const catalog = try source.constructor_bindings.admitCatalog(
        a,
        temporary.allocator(),
        module,
        &work,
    );
    var emitted = module;
    emitted.constants = catalog.constants;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const storage = arena.allocator();
    const tables = try storage.alloc([]List, kind_names.len);
    inline for (kind_names, 0..) |name, index| {
        const kind = @field(relocation.Kind, name);
        std.debug.assert(@backingInt(kind) == index);
        const length = if (kind == .region)
            std.math.cast(usize, module.region_count) orelse return error.InvalidReference
        else
            @field(emitted, name ++ "s").len;
        tables[index] = try storage.alloc(List, length);
        @memset(tables[index], .empty);
    }
    try collect(storage, emitted, catalog.constructors, tables);
    const result = try storage.alloc([]const []const Reference, tables.len);
    for (tables, result) |table, *out| {
        const rows = try storage.alloc([]const Reference, table.len);
        for (table, rows) |list, *row| row.* = list.items;
        out.* = rows;
    }
    return .{ .arena = arena, .value = .{ .source = digest, .users = result } };
}

fn collect(
    a: std.mem.Allocator,
    module: source.Module,
    constructors: []const source.constructor_bindings.Binding,
    tables: [][]List,
) !void {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    for (tables, 0..) |owners, kind| for (0..owners.len) |id| {
        _ = scratch.reset(.retain_capacity);
        var refs: List = .empty;
        try relocation.visitReferencesWithWork(
            scratch.allocator(),
            module,
            constructors,
            @fromBackingInt(@intCast(kind)),
            id,
            &refs,
            null,
        );
        for (refs.items) |ref| {
            const destinations = tables[@backingInt(ref.kind)];
            if (ref.id >= destinations.len) return error.InvalidReference;
            const list = &destinations[@intCast(ref.id)];
            const owner: Reference = .{ .kind = @fromBackingInt(@intCast(kind)), .id = id };
            if (list.items.len != 0 and std.meta.eql(list.items[list.items.len - 1], owner))
                continue;
            try list.append(a, owner);
        }
    };
}
