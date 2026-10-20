// Copyright (c) 2026 World contributors. MIT license.
//! Storage qualification only; this is not a Program evaluator or a kernel ABI.
const std = @import("std");
const Slots = @import("activation_slots").Slots(u64);
var memory: [1 << 20]u8 align(16) = undefined;

pub export fn test_storage() u32 {
    exercise() catch return 1;
    packedPages() catch return 2;
    return 0;
}

fn packedPages() !void {
    for ([_]usize{ 1, 2, 4, 8, 9, 16 }) |count| {
        var allocator = std.heap.FixedBufferAllocator.init(&memory);
        var store = try Slots.init(allocator.allocator());
        defer store.deinit();
        const original = try store.create(16);
        for (0..count) |slot| try store.set(original, slot, slot + 1);
        const dense = store.statistics.live_page_bytes;
        const active = try store.fork(original);
        try store.set(active, 0, 99);
        const copied = store.statistics.live_page_bytes - dense;
        if (count <= 8 and copied >= dense) return error.NotPacked;
        if (count > 8 and copied != dense) return error.DenseGrowth;
        for (0..count) |slot| {
            if (try store.get(original, slot) != slot + 1) return error.ChangedPredecessor;
            if (try store.get(active, slot) != (if (slot == 0) @as(
                u64,
                99,
            ) else slot + 1)) return error.WrongMapping;
        }
        if (count > 1) {
            try store.clear(active, 0);
            var iterator = try store.iterator(active);
            for (1..count) |slot| {
                const binding = (try iterator.next()) orelse return error.MissingBinding;
                if (binding.slot != slot or binding.value != slot + 1) return error.WrongIteration;
            }
            if (try iterator.next() != null) return error.ExtraBinding;
        }
        try store.release(active);
        try store.release(original);
        if (store.statistics.live_page_bytes != 0) return error.Leak;
    }
}

fn exercise() !void {
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    var store = try Slots.init(allocator.allocator());
    defer store.deinit();
    const current = try store.create(4096);
    for (0..256) |index| try store.set(current, index, index + 1);
    const retained = try store.fork(current);
    try store.set(current, 127, 900);
    if (try store.get(retained, 127) != 128) return error.Failed;
    if (try store.get(current, 127) != 900) return error.Failed;
    try store.retainOnly(current, &.{127});
    try store.release(retained);
    if (store.statistics.live_pages != 1) return error.Failed;
    const successor = try store.fork(current);
    try store.set(successor, 127, 901);
    try store.commit(current, successor);
    var values = try store.iterator(current);
    const binding = (try values.next()) orelse return error.Failed;
    if (binding.slot != 127 or binding.value != 901 or try values.next() != null)
        return error.Failed;
    try store.release(current);
    if (store.statistics.live_pages != 0 or store.statistics.live_directories != 0)
        return error.Failed;
}
