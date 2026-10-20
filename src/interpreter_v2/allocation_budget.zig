// Copyright (c) 2026 World contributors. MIT license.
//! Live requested-byte budgets. Allocator backing/metadata is accounted separately.
const std = @import("std");
pub const Budget = struct {
    parent: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    required: u64 = 0,
    failed: bool = false,

    pub fn resetObservation(self: *Budget) void {
        self.peak = self.live;
        self.required = self.live;
        self.failed = false;
    }
    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocate,
            .free = release,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
        } };
    }
    fn allocate(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(context));
        const required = @as(u64, self.live) +| length;
        self.required = @max(self.required, required);
        if (required > self.limit or length > std.math.maxInt(usize) - self.live) {
            self.failed = true;
            return null;
        }
        const result = self.parent.rawAlloc(length, alignment, ra) orelse return null;
        self.live += length;
        self.peak = @max(self.peak, self.live);
        return result;
    }
    fn release(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Budget = @ptrCast(@alignCast(context));
        self.parent.rawFree(bytes, alignment, ra);
        self.live -= bytes.len;
    }
};

test "budget failure preserves live allocations and freed capacity is reusable" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 64 };
    const allocator = budget.allocator();
    const first = try allocator.alloc(u8, 32);
    @memset(first, 0xa5);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 40));
    try std.testing.expectEqual(32, budget.live);
    try std.testing.expectEqual(72, budget.required);
    try std.testing.expect(budget.failed and std.mem.allEqual(u8, first, 0xa5));
    allocator.free(first);
    const whole = try allocator.alloc(u8, 64);
    allocator.free(whole);
    budget.resetObservation();
    try std.testing.expectEqual(0, budget.live);
    try std.testing.expect(!budget.failed);
}
