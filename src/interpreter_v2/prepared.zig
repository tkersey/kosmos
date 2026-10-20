// Copyright (c) 2026 World contributors. MIT license.
//! Reusable immutable Program ownership. Sessions retain their own strong lease.
const std = @import("std");
const data = @import("horos_data");
const Layouts = @import("frame_layouts.zig").Layouts;
pub const Error = data.program_image.Error || error{InvalidState};
pub const Contract = struct { payload: []const u8, resume_value: []const u8 };

const Storage = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    admitted: *data.program_image.Admitted,
    arena: std.heap.ArenaAllocator,
    contracts: []const ?Contract,
    layouts: Layouts,
};

pub const Core = opaque {
    fn storage(self: *Core) *Storage {
        return @ptrCast(@alignCast(self));
    }
    pub fn retain(self: *Core) Error!void {
        const owner = self.storage();
        // The caller holds a live lease and synchronizes its transfer. Retain
        // changes only the count; checked CAS cannot transiently wrap it to zero.
        var current = owner.references.load(.monotonic);
        while (true) { // tiger: event-loop
            std.debug.assert(current != 0);
            const next = std.math.add(usize, current, 1) catch return error.InvalidState;
            current = owner.references.cmpxchgWeak(
                current,
                next,
                .monotonic,
                .monotonic,
            ) orelse return;
        }
    }
    pub fn release(self: *Core) void {
        const owner = self.storage();
        // Distinct Sessions release through distinct gates. The final RMW is
        // the sole destruction winner and acquires all preceding releases.
        const previous = owner.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1) return;
        const allocator = owner.allocator;
        owner.layouts.deinit();
        owner.arena.deinit();
        owner.admitted.deinit();
        allocator.destroy(owner);
    }
    pub fn admitted(self: *Core) *const data.program_image.Admitted {
        return self.storage().admitted;
    }
    pub fn frameLayouts(self: *Core) *const Layouts {
        return &self.storage().layouts;
    }
    pub fn contract(self: *Core, effect: u64) Error!Contract {
        const contracts = self.storage().contracts;
        if (effect >= contracts.len) return error.InvalidState;
        return contracts[@intCast(effect)] orelse error.InvalidState;
    }
    pub fn storageBytes(self: *Core) usize {
        const owner = self.storage();
        return @sizeOf(Storage) + owner.arena.queryCapacity() +
            owner.admitted.storageBytes() + owner.layouts.storageBytes();
    }
};

/// An owning handle: clone explicitly to acquire another reference. Operations
/// on each handle are sequential. Independent Sessions may use separate threads
/// when their allocators, including this preparation's allocator, support it.
pub const Prepared = struct {
    core: ?*Core,

    pub fn init(allocator: std.mem.Allocator, image: []const u8) Error!Prepared {
        const admitted = try data.program_image.Admitted.decode(allocator, image);
        errdefer admitted.deinit();
        const program = admitted.program();
        var layouts = try Layouts.init(allocator, program.functions);
        errdefer layouts.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const contracts = try a.alloc(?Contract, program.effects.len);
        @memset(contracts, null);
        for (program.effects, contracts) |effect, *contract| if (effect.external) {
            contract.* = .{
                .payload = try encodeContract(allocator, a, program.schemas, effect.payload),
                .resume_value = try encodeContract(allocator, a, program.schemas, effect.result),
            };
        };
        const core = try allocator.create(Storage);
        core.* = .{
            .allocator = allocator,
            .admitted = admitted,
            .arena = arena,
            .contracts = contracts,
            .layouts = layouts,
        };
        return .{ .core = @ptrCast(core) };
    }

    pub fn clone(self: *const Prepared) Error!Prepared {
        return .{ .core = try self.acquire() };
    }
    pub fn acquire(self: *const Prepared) Error!*Core {
        const core = self.core orelse return error.InvalidState;
        try core.retain();
        return core;
    }
    pub fn deinit(self: *Prepared) void {
        const core = self.core orelse return;
        self.core = null;
        core.release();
    }
    pub fn storageBytes(self: *const Prepared) Error!usize {
        const core = self.core orelse return error.InvalidState;
        return core.storageBytes();
    }
};

fn encodeContract(
    scratch: std.mem.Allocator,
    retained: std.mem.Allocator,
    schemas: []const data.program.Schema,
    root: u64,
) Error![]const u8 {
    // Canonicalization owns temporary graphs. Allocating those through the
    // retained arena would keep their slabs after the encoder frees them.
    const bytes = try data.schema.encodeOwned(scratch, schemas, root);
    defer scratch.free(bytes);
    return retained.dupe(u8, bytes);
}
