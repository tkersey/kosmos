// Copyright (c) 2026 World contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const Error = @import("runtime_types.zig").Error;

pub const ElementOffsets = struct {
    pub const Key = struct { blob: u64, offset: usize, element: p.Id };
    allocator: std.mem.Allocator,
    positions: std.AutoHashMapUnmanaged(Key, std.ArrayList(usize)) = .empty,
    scans: u64 = 0,

    pub fn deinit(self: *ElementOffsets) void {
        self.clear();
        self.positions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *ElementOffsets) void {
        var entries = self.positions.valueIterator();
        while (entries.next()) |list| list.deinit(self.allocator);
        self.positions.clearRetainingCapacity();
    }

    pub fn prune(self: *ElementOffsets, alive: []const bool) Error!void {
        var dead: std.ArrayList(Key) = .empty;
        defer dead.deinit(self.allocator);
        var keys = self.positions.keyIterator();
        while (keys.next()) |key| {
            const live = key.blob < alive.len and alive[@intCast(key.blob)];
            if (!live) try dead.append(self.allocator, key.*);
        }
        for (dead.items) |key| {
            var removed = self.positions.fetchRemove(key).?;
            removed.value.deinit(self.allocator);
        }
    }

    pub fn seek(
        self: *ElementOffsets,
        key: Key,
        encoded: []const u8,
        target: u64,
        reader_context: anytype,
    ) Error!usize {
        const entry = try self.positions.getOrPut(self.allocator, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
            entry.value_ptr.append(self.allocator, 0) catch |err| {
                self.positions.removeByPtr(entry.key_ptr);
                return err;
            };
        }
        const list = entry.value_ptr;
        const wanted = std.math.cast(usize, target) orelse return error.InvalidLength;
        if (wanted < list.items.len) return list.items[wanted];
        try list.ensureTotalCapacity(self.allocator, wanted + 1);
        while (list.items.len <= wanted) {
            var reader: data.wire.Reader = .{
                .input = encoded,
                .position = list.items[list.items.len - 1],
            };
            _ = try reader_context.readElement(key.element, &reader);
            self.scans +|= 1;
            list.appendAssumeCapacity(reader.position);
        }
        return list.items[wanted];
    }
};
