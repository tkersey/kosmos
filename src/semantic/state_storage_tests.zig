//! Bootstrap representation witnesses. Guest transitions still use the frozen
//! native implementation here; the storage/projection algorithm is Horos code.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const kosmos = @import("native_baseline");
const projection = @import("projection.zig");
const machine = @import("machine.zig");
const Base = @import("../base/session.zig").Session;
const Author = @import("author.zig").Author;
const profile = @import("../base/profile.zig");
const a = std.testing.allocator;
const support = @import("test_support.zig");

fn storageImage() ![]u8 {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const d = try machine.define(&b);
    const entry = try b.declare(&.{ d.program, d.state }, d.state, &.{}, &.{});
    const stored = try b.variable(d.schema);
    const finish = try e.call(d.project, &.{try b.reference(stored)});
    try b.define(entry, try b.bind(stored, try e.call(d.hydrate, &.{ try e.param(entry, 0), try e.param(entry, 1) }), try b.term(.{ .yield_then = finish })));
    return support.encode(b.module(entry, e.unit));
}

test "first-order storage retains actual cyclic multi-shot and cleanup guest states" {
    const storage_image = try storageImage();
    defer a.free(storage_image);
    const storage_admitted = try data.program_image.Admitted.decode(a, storage_image);
    defer storage_admitted.deinit();
    _ = try profile.check(storage_admitted, .{});
    inline for (.{ source.examples.cloned, source.examples.yieldingCleanup }) |example| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const guest_image = try support.encode(try example(&b));
        defer a.free(guest_image);
        const admitted = try data.program_image.Admitted.decode(a, guest_image);
        defer admitted.deinit();
        const program_projection = try projection.programBytes(a, admitted);
        defer a.free(program_projection);
        var program = try projection.decode(projection.Program, a, program_projection);
        defer program.deinit();
        try std.testing.expectEqualDeep(admitted.program(), program.value.code);
        try std.testing.expectEqualDeep(admitted.traits(), program.value.uses);
        try std.testing.expectEqualSlices(u8, &admitted.identity(), &program.value.identity);
        var guest = try kosmos.Session.initImage(a, guest_image, if (example == source.examples.cloned) &.{} else &.{1});
        defer guest.deinit();
        try std.testing.expect(try guest.run(null) == .yielded);
        const original = try guest.checkpoint(a);
        defer a.free(original);
        var graph = try data.state_image.decodeGraph(a, original);
        defer graph.deinit();
        const required: data.graph.NodeTag = if (example == source.examples.cloned) .multi_template else .cleanup_return;
        var present = false;
        for (graph.state.nodes) |entry| if (std.meta.activeTag(entry.record) == required) {
            present = true;
        };
        try std.testing.expect(present);
        const input = try projection.stateBytes(a, admitted, graph.state);
        defer a.free(input);
        const arguments = try std.mem.concat(a, u8, &.{ program_projection, input });
        defer a.free(arguments);
        var storage = try Base.initImage(a, storage_image, arguments, .{});
        defer storage.deinit();
        try std.testing.expect(try storage.run(null) == .yielded);
        const outer_checkpoint = try storage.checkpoint(a);
        defer a.free(outer_checkpoint);
        var resumed = try Base.restoreImage(a, storage_image, outer_checkpoint, .{});
        defer resumed.deinit();
        try resumed.resumeYield();
        const result = try resumed.run(null);
        try std.testing.expect(result == .completed);
        var reconstructed = try projection.readState(a, admitted, try resumed.bytes(&result.completed));
        defer reconstructed.deinit();
        const checkpoint = try data.state_image.emit(a, reconstructed.state);
        defer a.free(checkpoint);
        try std.testing.expectEqualSlices(u8, original, checkpoint);

        // The reconstructed state supports the same next actual transition,
        // including dynamic identities and suspended obligations.
        var restored_guest = try kosmos.Session.restoreImage(a, guest_image, checkpoint);
        defer restored_guest.deinit();
        try guest.resumeYield();
        try restored_guest.resumeYield();
        _ = try guest.run(1);
        _ = try restored_guest.run(1);
        const next = try guest.checkpoint(a);
        defer a.free(next);
        const next_restored = try restored_guest.checkpoint(a);
        defer a.free(next_restored);
        try std.testing.expectEqualSlices(u8, next, next_restored);
    }
}
