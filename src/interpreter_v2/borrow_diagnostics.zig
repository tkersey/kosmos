//! Child-process fault injection into the real activation-view borrow interval.
const std = @import("std");
const Slots = @import("activation_slots.zig").ActivationSlots;
const Mode = enum { valid, grow, shift, oom, retire, owner_move };

const Injection = struct {
    parent: std.mem.Allocator,
    slots: ?*Slots = null,
    mode: Mode,
    armed: bool = false,

    fn allocator(self: *Injection) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Injection = @ptrCast(@alignCast(context));
        if (self.armed) {
            self.armed = false;
            const slots = self.slots.?;
            switch (self.mode) {
                .grow => {
                    std.debug.print("Z17 injected grow before invalidation\n", .{});
                    slots.views.ensureTotalCapacity(
                        self.allocator(),
                        slots.views.capacity + 1,
                    ) catch return null;
                    std.debug.print("Z17 invalidation escaped\n", .{});
                },
                .shift => {
                    std.debug.print("Z17 injected shift before invalidation\n", .{});
                    _ = slots.views.orderedRemove(0);
                    std.debug.print("Z17 invalidation escaped\n", .{});
                },
                .oom => return null,
                else => {},
            }
        }
        return self.parent.rawAlloc(len, alignment, ra);
    }
    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        len: usize,
        ra: usize,
    ) bool {
        const self: *Injection = @ptrCast(@alignCast(context));
        return self.parent.rawResize(memory, alignment, len, ra);
    }
    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *Injection = @ptrCast(@alignCast(context));
        return self.parent.rawRemap(memory, alignment, len, ra);
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Injection = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, ra);
    }
};

fn check(allocator: std.mem.Allocator, mode: Mode) !void {
    var injection = Injection{ .parent = allocator, .mode = mode };
    var slots = try Slots.init(injection.allocator());
    var owns_original = true;
    defer if (owns_original) slots.deinit();
    injection.slots = &slots;
    const first = try slots.create(8);
    _ = try slots.create(8);
    const value = @import("horos_data").graph.Value{ .schema = 0, .body = .{
        .scalar = .{ 7, 0, 0, 0, 0, 0, 0, 0 },
    } };
    injection.armed = true;
    if (mode == .oom) {
        if (slots.set(
            first,
            0,
            value,
        )) |_| {
            return error.MissingAllocationFailure;
        } else |err| if (err != error.OutOfMemory) return err;
        if (slots.get(
            first,
            0,
        )) |_| {
            return error.PartialPublication;
        } else |err| if (err != error.UninitializedSlot) return err;
    } else try slots.set(first, 0, value);
    if (mode == .grow or mode == .shift) return error.MissingPointerDiagnostic;
    // Growth after both successful and failed writes is legal: no lock escapes.
    const capacity = slots.views.capacity;
    while (slots.views.items.len <= capacity) _ = try slots.create(8);
    try slots.set(first, 0, value);
    if ((try slots.get(first, 0)).body.scalar[0] != 7) return error.WrongValue;
    if (mode == .retire) {
        const address = &slots.views.items[first.index];
        try slots.release(first);
        const successor = try slots.create(8);
        if (address != &slots.views.items[successor.index] or
            first.generation == successor.generation)
            return error.InvalidGenerationWitness;
        if (slots.get(
            first,
            0,
        )) |_| {
            return error.AcceptedRetiredHandle;
        } else |err| if (err != error.InvalidHandle) return err;
        try slots.set(successor, 0, value);
    }
    if (mode == .owner_move) {
        var moved = slots;
        owns_original = false;
        slots = undefined;
        defer moved.deinit();
        injection.slots = &moved;
        try moved.set(first, 1, value);
        const limit = moved.views.capacity;
        while (moved.views.items.len <= limit) _ = try moved.create(8);
        if ((try moved.get(first, 1)).body.scalar[0] != 7) return error.WrongMovedValue;
    }
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const selected = args.next() orelse return error.MissingMode;
    if (std.mem.eql(u8, selected, "check")) {
        const executable = args.next() orelse return error.MissingExecutable;
        if (args.next() != null) return error.UnexpectedArgument;
        for (std.enums.values(Mode)) |mode| {
            const result = try std.process.run(
                init.gpa,
                init.io,
                .{
                    .argv = &.{ executable, @tagName(
                        mode,
                    ) },
                    .stdout_limit = .limited(1 << 20),
                    .stderr_limit = .limited(1 << 20),
                    .timeout = .{ .duration = .{
                        .raw = .fromSeconds(30),
                        .clock = .awake,
                    } },
                },
            );
            defer init.gpa.free(result.stdout);
            defer init.gpa.free(result.stderr);
            const fault = mode == .grow or mode == .shift;
            const message = try std.fmt.allocPrint(init.gpa, "Z17 {s} {s}{s}", .{
                if (fault) "injected" else "valid",
                @tagName(mode),
                if (fault) " before invalidation" else "; leaks=0",
            });
            defer init.gpa.free(message);
            const valid = std.mem.indexOf(u8, result.stderr, message) != null and
                (if (fault) !result.term.success() and
                    (std.mem.indexOf(u8, result.stderr, "SafetyLock") != null or std.mem.indexOf(
                        u8,
                        result.stderr,
                        "assertUnlocked",
                    ) != null) and
                    std.mem.indexOf(
                        u8,
                        result.stderr,
                        "Z17 invalidation escaped",
                    ) == null else result.term.success());
            if (!valid) {
                std.debug.print("{s}\n", .{result.stderr});
                return error.DiagnosticMismatch;
            }
        }
        return;
    }
    const mode = std.meta.stringToEnum(Mode, selected) orelse return error.InvalidMode;
    if (args.next() != null) return error.UnexpectedArgument;
    var safety = std.heap.SafeAllocator.init(std.heap.page_allocator, .{});
    const result = check(safety.allocator(), mode);
    const leaks = safety.deinit();
    if (leaks != 0) return error.LeakedAllocation;
    try result;
    std.debug.print("Z17 valid {s}; leaks=0\n", .{@tagName(mode)});
}
