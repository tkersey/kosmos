const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const artifact = @import("artifact.zig");
const capsule = @import("capsule.zig");
const projection = @import("projection.zig");
const driver = @import("driver.zig");
const base = @import("../base/session.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");

const Custody = struct {
    expected: capsule.Reference,
    execution: [32]u8,
    consumed: bool = false,
    fn claim(context: *anyopaque, actual: capsule.Reference, record: capsule.Record, target: capsule.Reference) !void {
        const self: *Custody = @ptrCast(@alignCast(context));
        if (self.consumed or !std.meta.eql(self.expected, actual) or !std.mem.eql(u8, &self.execution, &record.provenance.execution) or !std.meta.eql(record.artifact, target)) return error.UnauthorizedCapsule;
        self.consumed = true;
    }
    fn verifier(self: *Custody) capsule.Verifier {
        return .{ .context = self, .claim = claim };
    }
};

test "outer capsule retains clone microprogress and requires exact consumed custody" {
    var selected = try artifact.Admitted.init(a, @import("packaged_runtime").bytes, artifact.digest(@import("packaged_runtime").bytes));
    defer selected.deinit();
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try support.encode(try source.examples.cloned(&b));
    defer a.free(image);
    var prepared = try base.Prepared.init(a, image);
    defer prepared.deinit();
    var original = try driver.Driver.start(a, &prepared, &selected, .{ .arguments = &.{} });
    var original_live = true;
    defer if (original_live) original.deinit();
    var initialized = try original.pump(null);
    initialized.event.deinit();
    var found = false;
    for (0..400) |_| {
        const control: @import("service.zig").Control = if (original.last_cut.?.status == .yielded) .resume_yield else .none;
        try original.submit(.{ .advance = .{ .control = control, .quantum = 1 } });
        while (true) {
            var step = try original.pump(16);
            if (step == .event) {
                step.event.deinit();
                break;
            }
            try std.testing.expect(step == .suspended);
            const current = original.outer.roots.current orelse continue;
            const frame = try original.outer.frames.get(current.id);
            var rebase = false;
            for (selected.content.value.recovery.anchors) |anchor| if (anchor.role == .clone_rebase and anchor.function == frame.function) {
                rebase = true;
            };
            if (!rebase) continue;
            const inspection = try @import("realization.zig").inspect(a, &original.outer, original.selected, original.guest.admitted());
            if (inspection.clone_rebases == 0) continue;
            found = true;
            break;
        }
        if (found) break;
        if (original.last_cut.?.status == .completed) return error.MissingClonePhase;
    }
    try std.testing.expect(found);
    try std.testing.expectError(error.GuestCutUnavailable, original.checkpoint(a));
    const provenance: capsule.Provenance = .{ .execution = @splat(3), .custody = @splat(7), .publication = null };
    const bytes = try capsule.publish(a, &original, .outer_execution, provenance);
    defer a.free(bytes);
    const before = try original.outer.checkpoint(a);
    defer a.free(before);
    var rejected: Custody = .{ .expected = capsule.reference(bytes), .execution = @splat(4) };
    try std.testing.expectError(error.UnauthorizedCapsule, capsule.restore(a, &prepared, &selected, bytes, rejected.verifier()));
    try std.testing.expect(!rejected.consumed);
    var edited = try projection.decode(capsule.Envelope, a, bytes);
    defer edited.deinit();
    edited.value.record.outer_revision += 1;
    const changed = try projection.encode(capsule.Envelope, a, edited.value);
    defer a.free(changed);
    var custody: Custody = .{ .expected = capsule.reference(bytes), .execution = provenance.execution };
    try std.testing.expectError(error.UnauthorizedCapsule, capsule.restore(a, &prepared, &selected, changed, custody.verifier()));
    try std.testing.expect(!custody.consumed);
    // The publisher retires at its publication fence before destination use.
    original.deinit();
    original_live = false;
    var restored = try capsule.restore(a, &prepared, &selected, bytes, custody.verifier());
    defer restored.deinit();
    const after = try restored.outer.checkpoint(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectError(error.UnauthorizedCapsule, capsule.restore(a, &prepared, &selected, bytes, custody.verifier()));
    var completed = try restored.pump(null);
    try std.testing.expect(completed == .event and completed.event.value == .cut);
    completed.event.deinit();
    const checkpoint = try restored.checkpoint(a);
    defer a.free(checkpoint);
    var state = try data.state_image.decodeGraph(a, checkpoint);
    defer state.deinit();
    try data.state_admission.validateAdmitted(a, restored.guest.admitted(), state.state);
}

test "resident capsule receipts bind level generation and exact outer progress" {
    const facade = @import("session.zig");
    var image: [52]u8 = undefined;
    _ = try std.fmt.hexToBytes(&image, "41424c5f4250493303000000200000000000000001000001020a0000000100000100010000020000070100000000000000000000");
    var prepared = try facade.Prepared.init(a, &image);
    defer prepared.deinit();
    var owner = try facade.Resident.start(a, &prepared, &.{ 1, 42 });
    defer if (owner.live) {
        const bytes = owner.takeCheckpoint(a) catch unreachable;
        a.free(bytes);
    };
    const provenance: capsule.Provenance = .{ .execution = @splat(5), .custody = @splat(8), .publication = null };
    var guest = try owner.publish(.{ .record = a }, .none, .{ .quantum = 0, .checkpoint = .receipt });
    defer guest.deinit();
    const guest_capsule = try owner.publishCapsule(a, .guest_cut, provenance);
    defer guest_capsule.deinit();
    try owner.beginAdvance(.none, 100);
    try std.testing.expectError(error.InvalidState, owner.transferCheckpoint(guest.checkpoint.?));
    try std.testing.expectError(error.InvalidState, owner.transferCapsule(guest_capsule, .guest_cut));
    try std.testing.expect(try owner.pump(1) == .suspended);
    try std.testing.expectError(error.GuestCutUnavailable, owner.publishCapsule(a, .guest_cut, provenance));
    const before = try owner.publishCapsule(a, .outer_execution, provenance);
    defer before.deinit();
    var failure = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, owner.publishCapsule(failure.allocator(), .outer_execution, provenance));
    const unchanged = try owner.publishCapsule(a, .outer_execution, provenance);
    defer unchanged.deinit();
    try std.testing.expectEqualSlices(u8, before.bytes(), unchanged.bytes());
    try std.testing.expectError(error.InvalidState, owner.transferCapsule(unchanged, .guest_cut));
    try std.testing.expect(try owner.pump(1) == .suspended);
    try std.testing.expectError(error.InvalidState, owner.transferCapsule(unchanged, .outer_execution));
    const current = try owner.publishCapsule(a, .outer_execution, provenance);
    defer current.deinit();
    try owner.transferCapsule(current, .outer_execution);
    try std.testing.expectError(error.InvalidState, owner.transferCapsule(current, .outer_execution));
    var custody: Custody = .{ .expected = capsule.reference(current.bytes()), .execution = provenance.execution };
    var restored = try facade.Resident.restoreCapsule(a, &prepared, current.bytes(), custody.verifier());
    defer if (restored.live) {
        const bytes = restored.takeCheckpoint(a) catch unreachable;
        a.free(bytes);
    };
    try std.testing.expectError(error.UnauthorizedCapsule, facade.Resident.restoreCapsule(a, &prepared, current.bytes(), custody.verifier()));
    while (try restored.pump(64) == .suspended) {}
    var result = try restored.drive(a, .resume_yield, .{});
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 42 }, result.record.completed);
    try restored.close();
}
