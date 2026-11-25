// Copyright (c) 2026 World contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const ir = data.activation;
const g = data.graph;
const bindings = @import("../interpreter_v2/activation_frames.zig");
const Values = @import("../interpreter_v2/values.zig").Values;
const Session = @import("session.zig").Session;
const Error = @import("session.zig").Error;
const control = @import("control.zig");

const collection_period = 256;

const Work = struct { units: u8 = 1, scalar: u8 = 0, collect_cursors: bool = false };

pub fn step(session: *Session, allowance: u8) Error!u8 {
    if (session.poisoned or session.terminal != null or
        (session.status != .active and session.status != .unwinding)) return error.InvalidState;
    errdefer session.poisoned = true;
    const current = session.roots.current orelse return error.InvalidState;
    const work: Work = if (session.status == .unwinding) unwinding: {
        _ = try @import("unwind.zig").step(session);
        break :unwinding .{};
    } else try stepActive(session, current, allowance);
    if (session.roots.current == null or session.roots.current.?.id != current.id) {
        if (try session.store.get(current) == .control) try session.frames.remove(current.id);
    }
    session.transitions +%= work.units;
    if (session.statistics) |statistics| {
        statistics.transitions +|= work.units;
        statistics.dispatches +|= 1;
        statistics.batched_scalar_operations +|= work.scalar;
    }
    if (session.terminal != null or session.status == .yielded or session.status == .parked or
        session.transitions % collection_period < work.units or work.collect_cursors)
    {
        try collect(session);
    }
    return work.units;
}

fn stepActive(session: *Session, current: g.NodeRef, allowance: u8) Error!Work {
    const saved = (try session.store.get(current)).control;
    const code = session.program.blocks[@intCast(saved.block)];
    session.frames.entries.lockPointers();
    var frame_borrow = true;
    defer if (frame_borrow) session.frames.entries.unlockPointers();
    const frame = try session.frames.getMutable(current.id);
    if (frame.position >= code.instructions.len) {
        var copied = frame.*;
        session.frames.entries.unlockPointers();
        frame_borrow = false;
        try control.execute(session, current, saved, code, &copied, null);
        return .{};
    }
    const instruction = code.instructions[frame.position];
    const fused = if (@sizeOf(usize) > 4 and allowance >= 2 and
        instruction.opcode == .computation and code.terminator == .handle and
        frame.position + 1 == code.instructions.len)
        control.knownHandlerBody(session, code)
    else
        null;
    if (fused) |constructor| {
        var copied = frame.*;
        copied.position += 1;
        session.frames.entries.unlockPointers();
        frame_borrow = false;
        try control.execute(session, current, saved, code, &copied, constructor);
        return .{ .units = 2 };
    }
    if (instruction.opcode == .clone_resumption) {
        var copied = frame.*;
        session.frames.entries.unlockPointers();
        frame_borrow = false;
        try executeInstruction(session, current, code, &copied);
        try session.frames.update(current.id, copied);
        return .{};
    }
    return stepValues(session, current, saved, code, frame, allowance);
}

fn stepValues(
    session: *Session,
    current: g.NodeRef,
    saved: g.Control,
    code: ir.Block,
    frame: *bindings.Frame,
    allowance: u8,
) Error!Work {
    const instruction = code.instructions[frame.position];
    if (instruction.opcode == .blob_length) session.pending_blob_collection =
        session.pending_blob_collection or try dropsLargeBlob(session, saved.block, code, frame);
    const count = scalarBatch(session, code, frame.position, allowance);
    const units = @max(1, count);
    for (0..units) |_| try executeInstruction(session, current, code, frame);
    const pops = instruction.opcode == .sequence_pop or instruction.opcode == .sequence_pop_last;
    return .{
        .units = units,
        .scalar = if (count > 1) count else 0,
        .collect_cursors = @sizeOf(usize) > 4 and pops and
            session.store.encoded_sequences.count() >= session.collection_cursors,
    };
}

fn scalarBatch(session: *const Session, code: ir.Block, position: usize, allowance: u8) u8 {
    const limit = @min(
        @as(usize, allowance),
        collection_period - session.transitions % collection_period,
    );
    const layout = session.program.functions[@intCast(code.function)].layout.slots;
    var count: usize = 0;
    while (count < limit and position + count < code.instructions.len) : (count += 1) {
        const operation = code.instructions[position + count];
        switch (operation.opcode) {
            .integer_bit_and, .integer_bit_or, .integer_bit_xor, .integer_bit_not => {},
            else => break,
        }
        if (operation.failures.len != 0) break;
        switch (session.program.schemas[@intCast(layout[@intCast(operation.destination)])]) {
            .u8, .u16, .u32, .u64 => {},
            else => break,
        }
    }
    return @intCast(count);
}

pub fn collect(session: *Session) Error!void {
    try session.store.collectWith(session.roots, &session.frames);
    try session.offsets.prune(session.store.blob_alive.items);
    session.pending_blob_collection = false;
    if (@sizeOf(usize) > 4) {
        const live = session.store.encoded_sequences.count();
        session.collection_cursors = @max(8, @as(usize, live) *| 2);
    }
}

pub fn finishRetention(session: *Session) Error!void {
    if (!session.pending_blob_collection) return;
    errdefer session.poisoned = true;
    try collect(session);
    if (session.statistics) |statistics| statistics.early_blob_collections +|= 1;
}

fn dropsLargeBlob(
    session: *Session,
    block: p.Id,
    code: ir.Block,
    frame: *const bindings.Frame,
) Error!bool {
    const source = code.instructions[frame.position];
    const slot = source.operands[0];
    const pool = session.flow.facts.pool;
    const live = session.flow.facts.live[@intCast(block)][frame.position + 1];
    if (pool.contains(live, slot)) return false;
    const value = try session.frames.slots.get(frame.view, @intCast(slot));
    if (value.body != .blob) return false;
    const id = std.math.cast(usize, value.body.blob.id) orelse return error.InvalidState;
    if (id >= session.store.blobs.items.len or !session.store.blob_alive.items[id])
        return error.InvalidState;
    if (session.store.blobs.items[id].bytes.len < 64 << 10) return false;
    var iterator = try session.frames.slots.iterator(frame.view);
    while (try iterator.next()) |binding| {
        if (binding.slot == slot or !pool.contains(live, binding.slot)) continue;
        if (binding.value.body == .blob and binding.value.body.blob.id == value.body.blob.id)
            return false;
    }
    return true;
}

fn executeInstruction(
    session: *Session,
    current: g.NodeRef,
    code: ir.Block,
    frame: *bindings.Frame,
) Error!void {
    const source = code.instructions[frame.position];
    const layout = session.program.functions[@intCast(code.function)].layout.slots;
    const reader = try session.frames.slots.reader(frame.view);
    var temporary = std.heap.ArenaAllocator.init(session.allocator);
    defer temporary.deinit();
    var values: Values = .{
        .allocator = temporary.allocator(),
        .schemas = session.program.schemas,
        .store = &session.store,
        .facts = session.value_facts,
        .traits = session.uses,
        .offsets = &session.offsets,
    };
    const result_type = layout[@intCast(source.destination)];
    switch (try @import("instruction.zig").execute(session, source, result_type, reader, &values)) {
        .failed => |failure| try session.failCurrent(current, failure),
        .value => |value| {
            if (!source.opcode.borrowsOperands()) for (source.operands) |slot| {
                if (!session.uses.copy[@intCast(layout[@intCast(slot)])])
                    try session.frames.clear(frame, slot);
            };
            frame.position += 1;
            const block = (try session.store.get(current)).control.block;
            try session.frames.apply(
                frame,
                session.flow.facts.live[@intCast(block)][frame.position],
                @as([]const p.Id, &.{source.destination}),
                &.{value},
            );
        },
    }
}
