// Copyright (c) 2026 World contributors. MIT license.
//! Immutable exact frame-layout classes, derived once before sharing preparation.
const std = @import("std");
const data = @import("horos_data");

pub const Layouts = struct {
    allocator: std.mem.Allocator,
    functions: []const data.activation.Function,
    classes: []const usize,

    /// Borrows immutable function definitions; owns only the class array. This
    /// derives storage compatibility, not admission of the complete Program.
    pub fn init(
        allocator: std.mem.Allocator,
        functions: []const data.activation.Function,
    ) std.mem.Allocator.Error!Layouts {
        return derive(false, allocator, functions);
    }
    pub fn deinit(self: *Layouts) void {
        self.allocator.free(self.classes);
        self.* = undefined;
    }
    pub fn compatible(self: *const Layouts, left: data.program.Id, right: data.program.Id) bool {
        if (left >= self.functions.len or right >= self.functions.len) return false;
        if (left == right) return true;
        return self.classes[@intCast(left)] == self.classes[@intCast(right)];
    }
    pub fn storageBytes(self: *const Layouts) usize {
        return self.classes.len * @sizeOf(usize);
    }
    fn derive(
        comptime collide: bool,
        allocator: std.mem.Allocator,
        functions: []const data.activation.Function,
    ) std.mem.Allocator.Error!Layouts {
        if (functions.len < 2) return .{
            .allocator = allocator,
            .functions = functions,
            .classes = &.{},
        };
        const Context = struct {
            functions: []const data.activation.Function,
            pub fn hash(self: @This(), id: usize) u64 {
                if (collide) return 0;
                const function = self.functions[id];
                var digest = std.hash.Wyhash.init(0);
                digest.update(std.mem.asBytes(&function.custody.len));
                digest.update(std.mem.sliceAsBytes(function.layout.slots));
                return digest.final();
            }
            pub fn eql(self: @This(), left: usize, right: usize) bool {
                const a = self.functions[left];
                const b = self.functions[right];
                return a.custody.len == b.custody.len and std.mem.eql(
                    data.program.Id,
                    a.layout.slots,
                    b.layout.slots,
                );
            }
        };
        const classes = try allocator.alloc(usize, functions.len);
        errdefer allocator.free(classes);
        // A two-element partition needs only one exact comparison. Hashing
        // both full layouts and allocating a table adds no useful discovery.
        if (functions.len == 2) {
            classes[0] = 0;
            classes[1] = if ((Context{ .functions = functions }).eql(0, 1)) 0 else 1;
            return .{ .allocator = allocator, .functions = functions, .classes = classes };
        }
        var representatives: std.HashMapUnmanaged(
            usize,
            void,
            Context,
            std.hash_map.default_max_load_percentage,
        ) = .empty;
        defer representatives.deinit(allocator);
        for (classes, 0..) |*class, id| {
            const entry = try representatives.getOrPutContext(
                allocator,
                id,
                .{ .functions = functions },
            );
            class.* = entry.key_ptr.*;
        }
        return .{ .allocator = allocator, .functions = functions, .classes = classes };
    }
};

test "frame layout classes preserve exact schemas and custody under collisions" {
    const a = std.testing.allocator;
    const first = try a.alloc(data.program.Id, 65536);
    defer a.free(first);
    @memset(first, 0);
    const equal = try a.dupe(data.program.Id, first);
    defer a.free(equal);
    const different = try a.dupe(data.program.Id, first);
    defer a.free(different);
    different[different.len - 1] = 1;
    const functions = [_]data.activation.Function{
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = first }, .result = 0 },
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = equal }, .result = 0 },
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = different }, .result = 0 },
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = first[0..4] }, .result = 0 },
        .{
            .entry = 0,
            .inputs = &.{},
            .layout = .{ .slots = first },
            .result = 0,
            .custody = &.{},
        },
    };
    inline for (.{ false, true }) |collide| {
        var layouts = try Layouts.derive(collide, a, &functions);
        defer layouts.deinit();
        for (functions, 0..) |left, i| for (functions, 0..) |right, j| {
            const expected = left.custody.len == right.custody.len and std.mem.eql(
                data.program.Id,
                left.layout.slots,
                right.layout.slots,
            );
            try std.testing.expectEqual(expected, layouts.compatible(i, j));
        };
        try std.testing.expect(!layouts.compatible(functions.len, 0));
    }
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    const functions = [_]data.activation.Function{
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{ 0, 1 } }, .result = 0 },
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{ 0, 1 } }, .result = 0 },
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{ 1, 0 } }, .result = 0 },
    };
    var layouts = try Layouts.init(allocator, &functions);
    defer layouts.deinit();
    try std.testing.expect(layouts.compatible(0, 1));
    try std.testing.expect(!layouts.compatible(0, 2));
}
test "frame layout classification releases all allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationAttempt, .{});
}

fn pairAllocationAttempt(allocator: std.mem.Allocator) !void {
    var functions = [_]data.activation.Function{
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{ 0, 1 } }, .result = 0 },
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{ 0, 1 } }, .result = 0 },
    };
    for ([_][]const data.program.Id{ &.{ 0, 1 }, &.{ 0, 0 }, &.{0} }) |slots| {
        functions[1].layout.slots = slots;
        var layouts = try Layouts.init(allocator, &functions);
        defer layouts.deinit();
        try std.testing.expectEqual(std.mem.eql(
            data.program.Id,
            functions[0].layout.slots,
            slots,
        ), layouts.compatible(0, 1));
    }
}
test "two-function classification preserves equality and allocation failure cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pairAllocationAttempt, .{});
}
