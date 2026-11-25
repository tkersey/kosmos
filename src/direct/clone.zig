// Copyright (c) 2026 World contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const g = data.graph;
const Store = @import("../interpreter_v2/store.zig").Store;
const Error = @import("../interpreter_v2/runtime_types.zig").Error;
const Frames = @import("../interpreter_v2/activation_frames.zig").Frames;
const Map = std.AutoHashMap(p.Id, g.NodeRef);
const Lists = std.AutoHashMap(p.Id, std.ArrayList(g.NodeRef));

pub fn instantiate(
    allocator: std.mem.Allocator,
    store: *Store,
    template: g.Capture,
    frames: *Frames,
) Error!g.Capture {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var copy: Cloner = .{
        .frames = frames,
        .allocator = scratch,
        .store = store,
        .map = Map.init(scratch),
        .waiting = Lists.init(scratch),
        .considered = std.AutoHashMap(p.Id, void).init(scratch),
        .discovered = std.AutoHashMap(p.Id, void).init(scratch),
        .dependents = Lists.init(scratch),
    };
    try copy.capture(template, false);
    try copy.close();
    for (copy.originals.items) |reference| {
        const target = copy.map.get(reference.id).?;
        const changed = try rebase(g.Node, scratch, try store.get(reference), copy.map);
        try store.replace(target, changed);
        try copy.frames.rebaseFrame(target.id, copy.map);
    }
    var result = try rebase(g.Capture, scratch, template, copy.map);
    result.use_site_capabilities = try allocator.dupe(g.Value, result.use_site_capabilities);
    return result;
}

const Cloner = struct {
    const Self = @This();
    frames: *Frames,
    allocator: std.mem.Allocator,
    store: *Store,
    map: Map,
    originals: std.ArrayList(g.NodeRef) = .empty,
    templates: std.ArrayList(g.NodeRef) = .empty,
    waiting: Lists,
    considered: std.AutoHashMap(p.Id, void),
    discovered: std.AutoHashMap(p.Id, void),
    pending: std.ArrayList(g.NodeRef) = .empty,
    dependents: Lists,
    references: std.ArrayList(data.graph_order.Reference) = .empty,
    scanned: usize = 0,
    propagated: usize = 0,

    fn close(self: *Self) Error!void {
        while (self.scanned < self.pending.items.len or
            self.propagated < self.originals.items.len or
            self.templates.items.len != 0)
        {
            if (self.templates.pop()) |reference| {
                try self.template(reference);
            } else if (self.propagated < self.originals.items.len) {
                const changed = self.originals.items[self.propagated];
                self.propagated += 1;
                if (self.dependents.get(changed.id)) |parents| {
                    for (parents.items) |parent| try self.include(parent);
                }
            } else try self.scan(self.pending.items[self.scanned]);
        }
    }

    fn scan(self: *Self, original: g.NodeRef) Error!void {
        const node = try self.store.get(original);
        const immutable = switch (node) {
            .environment, .aggregate, .computation => true,
            else => false,
        };
        self.references.clearRetainingCapacity();
        try data.graph_order.references(g.Node, node, &self.references, self.allocator);
        try self.frames.references(original.id, &self.references, self.allocator);
        self.scanned += 1;
        for (self.references.items) |reference| if (reference == .node) {
            const child: g.NodeRef = .{ .id = reference.node };
            if (immutable) try self.addDependency(child, original);
            switch (try self.store.get(child)) {
                .environment, .aggregate, .computation => try self.discover(child),
                .cell => |cell| try self.addDependency(cell.region, child),
                .multi_template => try self.template(child),
                else => {},
            }
        };
    }

    fn discover(self: *Self, reference: g.NodeRef) Error!void {
        const entry = try self.discovered.getOrPut(reference.id);
        if (!entry.found_existing) try self.pending.append(self.allocator, reference);
    }

    fn addDependency(self: *Self, child: g.NodeRef, parent: g.NodeRef) Error!void {
        const entry = try self.dependents.getOrPut(child.id);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(self.allocator, parent);
        if (self.map.contains(child.id)) try self.include(parent);
    }

    fn include(self: *Self, reference: g.NodeRef) Error!void {
        if (self.map.contains(reference.id)) return;
        const copied = try self.store.add(try self.store.get(reference));
        try self.frames.copyFrame(reference.id, copied.id);
        try self.map.put(reference.id, copied);
        try self.originals.append(self.allocator, reference);
        try self.discover(reference);
        if (self.waiting.fetchRemove(reference.id)) |waiting|
            try self.templates.appendSlice(self.allocator, waiting.value.items);
    }

    fn capture(self: *Self, saved: g.Capture, include_handler: bool) Error!void {
        var cursor = saved.capture;
        while (cursor) |reference| {
            const record = try self.store.get(reference);
            try self.include(reference);
            if (reference.id == saved.delimiter.id) {
                if (include_handler) try self.include(record.attachment.handler);
                return;
            }
            cursor = switch (record) {
                .continuation => |continuation| continuation.parent,
                .attachment => |attachment| blk: {
                    try self.include(attachment.handler);
                    break :blk attachment.return_to;
                },
                .region_scope => |scope| blk: {
                    try self.include(scope.region);
                    break :blk scope.return_to;
                },
                .injection => |injected| injected.continuation,
                else => return error.InvalidState,
            };
        }
        return error.InvalidScope;
    }

    fn template(self: *Self, reference: g.NodeRef) Error!void {
        if (self.map.contains(reference.id)) return;
        const saved = (try self.store.get(reference)).multi_template;
        const delimiter = (try self.store.get(saved.delimiter)).attachment;
        const activation = (try self.store.get(delimiter.handler)).handler;
        const dependencies = [_]?g.NodeRef{ delimiter.outer, activation.region };
        for (dependencies) |dependency| if (dependency) |owner| {
            if (self.map.contains(owner.id)) {
                try self.include(reference);
                try self.capture(saved, true);
                return;
            }
        };
        const seen = try self.considered.getOrPut(reference.id);
        if (seen.found_existing) return;
        for (dependencies) |dependency| if (dependency) |owner| {
            const waiting = try self.waiting.getOrPut(owner.id);
            if (!waiting.found_existing) waiting.value_ptr.* = .empty;
            try waiting.value_ptr.append(self.allocator, reference);
        };
    }
};

fn rebase(comptime T: type, allocator: std.mem.Allocator, value: T, map: Map) Error!T {
    @setEvalBranchQuota(10000);
    if (T == g.NodeRef) return map.get(value.id) orelse value;
    if (T == g.BlobRef) return value;
    return switch (@typeInfo(T)) {
        .pointer => |info| blk: {
            const result = try allocator.alloc(info.child, value.len);
            for (result, value) |*to, from|
                to.* = try @call(.always_inline, rebase, .{ info.child, allocator, from, map });
            break :blk result;
        },
        .optional => |info| if (value) |present|
            try @call(.always_inline, rebase, .{ info.child, allocator, present, map })
        else
            null,
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, Field| {
                @field(result, name) = try @call(.always_inline, rebase, .{
                    Field, allocator, @field(value, name), map,
                });
            }
            break :blk result;
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| @unionInit(T, @tagName(tag), try @call(
                .always_inline,
                rebase,
                .{ @TypeOf(payload), allocator, payload, map },
            )),
        },
        .array => |info| blk: {
            var result: T = undefined;
            for (&result, value) |*to, from|
                to.* = try @call(.always_inline, rebase, .{ info.child, allocator, from, map });
            break :blk result;
        },
        else => value,
    };
}
