const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const artifact = @import("semantic/artifact.zig");
const projection = @import("semantic/projection.zig");
const driver = @import("semantic/driver.zig");
const native = @import("../test_oracle.zig");
const packaged = @import("packaged_runtime");
const a = std.testing.allocator;
test {
    _ = @import("semantic/capsule_tests.zig");
}

test "downstream packaged core equals independently rebuilt and validated source" {
    const retained = @import("semantic_packaged.zig");
    // The build's packaged_runtime is freshly compiled, admitted and validated
    // by semantic_artifact.zig, independently of the retained content below.
    var admitted = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer admitted.deinit();
    try retained.check(admitted.content.value.manifest.compiler.horos_package);
    try std.testing.expectEqualSlices(u8, packaged.bytes, retained.bytes);
    try std.testing.expectError(error.PackagedCompilerMismatch, retained.check("different-compiler-package"));
}

test "artifact admission binds exact content and independently scans its inventory" {
    var admitted = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer admitted.deinit();
    try std.testing.expectEqualSlices(u8, &@import("semantic/source_identity.zig").digest(), &admitted.content.value.manifest.source);
    try std.testing.expect(admitted.content.value.manifest.inventory.instructions > 0);
    var wrong = artifact.digest(packaged.bytes);
    wrong[0] ^= 1;
    try std.testing.expectError(error.ArtifactIdentityMismatch, artifact.Admitted.init(a, packaged.bytes, wrong));
    var bundle = admitted.content.value;
    bundle.manifest.inventory.instructions += 1;
    const forged = try projection.encode(artifact.Bundle, a, bundle);
    defer a.free(forged);
    try std.testing.expectError(error.InvalidInventory, artifact.Admitted.init(a, forged, artifact.digest(forged)));
    bundle = admitted.content.value;
    bundle.manifest.bridge.identity = "model-authored-bridge";
    const bridge = try projection.encode(artifact.Bundle, a, bundle);
    defer a.free(bridge);
    try std.testing.expectError(error.UnsupportedArtifact, artifact.Admitted.init(a, bridge, artifact.digest(bridge)));
    bundle = admitted.content.value;
    const anchors = try a.dupe(artifact.Anchor, bundle.recovery.anchors);
    defer a.free(anchors);
    anchors[0].role = .committed_service;
    bundle.recovery.anchors = anchors;
    const changed_map = try projection.encode(artifact.Bundle, a, bundle);
    defer a.free(changed_map);
    var changed = try artifact.Admitted.init(a, changed_map, artifact.digest(changed_map));
    defer changed.deinit();
    try std.testing.expectError(error.InvalidRecovery, @import("semantic/compiler.zig").validate(a, &changed));
}

fn complete(pump: *driver.Driver) !projection.Owned(@import("semantic/service.zig").Event) {
    return switch (try pump.pump(null)) {
        .event => |event| event,
        else => error.UnexpectedPumpResult,
    };
}

test "approved source instrumentation preserves cuts and blocks publication without a guest failure" {
    const compiler = @import("semantic/compiler.zig");
    const facade = @import("semantic/session.zig");
    const bytes = try compiler.compile(a, .{ .horos_package = "test-exact-horos", .hooks = .{ .control = true, .storage = true } });
    defer a.free(bytes);
    var selected = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer selected.deinit();
    try compiler.validate(a, &selected);
    const image = try @import("semantic/step_tests.zig").guestImage();
    defer a.free(image);
    try switchRealizations(image, &selected);
    var prepared = try facade.Prepared.initWithRuntime(a, image, &selected);
    defer prepared.deinit();
    var generic = try facade.Prepared.init(a, image);
    defer generic.deinit();
    const input = std.mem.toBytes(@as(u64, 37));
    var instrumented = try facade.Session.start(a, &prepared, &input);
    defer instrumented.deinit();
    var plain = try facade.Session.start(a, &generic, &input);
    defer plain.deinit();
    try std.testing.expect(plain.trace() == null);
    for (0..6) |_| {
        _ = try instrumented.run(1);
        _ = try plain.run(1);
        const actual = try instrumented.checkpoint(a);
        defer a.free(actual);
        const expected = try plain.checkpoint(a);
        defer a.free(expected);
        try std.testing.expectEqualSlices(u8, expected, actual);
        const trace = instrumented.trace().?;
        try std.testing.expectEqualDeep(selected.identity, trace.realization);
        try std.testing.expectEqualDeep(prepared.guest.core.?.admitted().identity(), trace.guest);
        try std.testing.expect(trace.trace.storage.?.node_slots != 0);
        try std.testing.expectEqual(instrumented.driver.last_cut.?.status, trace.trace.control.?.status);
        try std.testing.expect(plain.trace() == null);
    }
    std.debug.print("instrumentation_witness guest_steps=6 generic_base={d} instrumented_base={d} generic_artifact_bytes={d} instrumented_artifact_bytes={d}\n", .{ plain.driver.outer.transitions, instrumented.driver.outer.transitions, packaged.bytes.len, bytes.len });
    {
        var builder = source.Builder.init(a);
        defer builder.deinit();
        var lowered = try source.lower(a, try source.examples.resourceScalar(&builder));
        defer lowered.deinit();
        const effect_image = try a.alloc(u8, try data.program_image.encodedLength(lowered.program));
        defer a.free(effect_image);
        _ = try lowered.encode(a, effect_image);
        var effect_prepared = try facade.Prepared.initWithRuntime(a, effect_image, &selected);
        defer effect_prepared.deinit();
        var effect_session = try facade.Session.start(a, &effect_prepared, &.{});
        defer effect_session.deinit();
        const observed = try effect_session.run(100);
        try std.testing.expect(observed == .requested);
        try std.testing.expectEqual(observed.requested.effect, effect_session.trace().?.trace.control.?.effect.?);
        try std.testing.expectEqual(.parked, effect_session.trace().?.trace.control.?.status);
    }
    var resident = try facade.Resident.start(a, &prepared, &input);
    defer if (resident.live) {
        const checkpoint = resident.takeCheckpoint(a) catch unreachable;
        a.free(checkpoint);
    };
    const before = try resident.checkpoint(a);
    defer a.free(before);
    var no_space: [0]u8 = .{};
    try std.testing.expectError(error.TracePublicationBlocked, resident.publish(.{ .record = a }, .none, .{ .quantum = 3, .checkpoint = .receipt, .trace_buffer = &no_space }));
    const after = try resident.checkpoint(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    var room: [512]u8 = undefined;
    var published = try resident.publish(.{ .record = a }, .none, .{ .quantum = 3, .checkpoint = .receipt, .trace_buffer = &room });
    defer published.deinit();
    try std.testing.expect(published.trace != null);
    try std.testing.expect(published.outcome.record.record != .failed);
    // A label on an uninstrumented artifact cannot authorize observer output.
    var counterfeit = generic.runtime.content.value;
    counterfeit.hooks = .{ .control = true, .storage = true };
    const forged_bytes = try projection.encode(artifact.Bundle, a, counterfeit);
    defer a.free(forged_bytes);
    var forged = try artifact.Admitted.init(a, forged_bytes, artifact.digest(forged_bytes));
    defer forged.deinit();
    try std.testing.expectError(error.InvalidRealization, compiler.validate(a, &forged));
}

test "packaged specialized realization carries independently checked recovery and exact guest binding" {
    const image = try @import("semantic/step_tests.zig").guestImage();
    defer a.free(image);
    var prepared = try @import("base/session.zig").Prepared.init(a, image);
    defer prepared.deinit();
    const guest = try prepared.acquire();
    defer guest.release();
    const compiler = @import("semantic/compiler.zig");
    const bytes = try compiler.compile(a, .{ .horos_package = "test-exact-horos", .guest = guest.admitted() });
    defer a.free(bytes);
    var selected = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer selected.deinit();
    try compiler.validate(a, &selected);
    try std.testing.expect(selected.content.value.guest != null and selected.content.value.specialization != null);
    try switchRealizations(image, &selected);
    for ([_]u64{ 0, 37, std.math.maxInt(u64) - 7 }) |input| {
        var pump = try driver.Driver.start(a, &prepared, &selected, .{ .arguments = &std.mem.toBytes(input) });
        defer pump.deinit();
        var initial = try complete(&pump);
        initial.deinit();
        var advanced = try pump.exchange(.{ .advance = .{ .control = .none, .quantum = 3 } });
        advanced.deinit();
        const checkpoint = try pump.checkpoint(a);
        defer a.free(checkpoint);
        var expected = try native.Session.initImage(a, image, &std.mem.toBytes(input));
        defer expected.deinit();
        _ = try expected.run(3);
        const canonical = try expected.checkpoint(a);
        defer a.free(canonical);
        try std.testing.expectEqualSlices(u8, canonical, checkpoint);
        const inspected = try @import("semantic/realization.zig").inspect(a, &pump.outer, pump.selected, guest.admitted());
        try std.testing.expect(inspected.committed > 0);
    }
}

fn switchRealizations(image: []const u8, specialized: *const artifact.Admitted) !void {
    const facade = @import("semantic/session.zig");
    const capsules = @import("semantic/capsule.zig");
    const Publisher = struct {
        decision: capsules.SwitchDecision = .rejected,
        calls: usize = 0,
        last: ?capsules.Reference = null,
        fn publish(context_ptr: *anyopaque, binding: capsules.Binding, before: []const u8, after: []const u8) capsules.SwitchDecision {
            const self: *@This() = @ptrCast(@alignCast(context_ptr));
            var source_capsule = projection.decode(capsules.Envelope, a, before) catch unreachable;
            defer source_capsule.deinit();
            var target_capsule = projection.decode(capsules.Envelope, a, after) catch unreachable;
            defer target_capsule.deinit();
            std.testing.expectEqualSlices(u8, source_capsule.value.checkpoint, target_capsule.value.checkpoint) catch unreachable;
            std.testing.expectEqual(binding.guest_revision, target_capsule.value.record.guest_revision) catch unreachable;
            std.testing.expectEqual(binding.outer_revision + 1, target_capsule.value.record.outer_revision) catch unreachable;
            if (self.last) |last| std.testing.expectEqual(last, capsules.reference(after)) catch unreachable;
            self.last = capsules.reference(after);
            self.calls += 1;
            return self.decision;
        }
        fn owner(self: *@This()) capsules.SwitchOwner {
            return .{ .context = self, .publish = publish };
        }
    };
    var prepared = try facade.Prepared.init(a, image);
    defer prepared.deinit();
    var resident = try facade.Resident.start(a, &prepared, &std.mem.toBytes(@as(u64, 37)));
    defer if (resident.live) {
        const bytes = resident.takeCheckpoint(a) catch unreachable;
        a.free(bytes);
    };
    var cut = try resident.publish(.{ .record = a }, .none, .{ .quantum = 3, .checkpoint = .receipt });
    defer cut.deinit();
    const binding = try resident.runtimeBinding();
    const provenance: capsules.Provenance = .{ .execution = @splat(11), .custody = @splat(12), .publication = null };
    var publisher: Publisher = .{};
    try std.testing.expectEqual(.rejected, try resident.realize(binding, specialized, provenance, publisher.owner()));
    try std.testing.expectEqual(binding, try resident.runtimeBinding());
    publisher.decision = .uncertain;
    try std.testing.expectEqual(.uncertain, try resident.realize(binding, specialized, provenance, publisher.owner()));
    try std.testing.expectError(error.PublicationUncertain, resident.drive(a, .none, .{}));
    try std.testing.expectError(error.PublicationUncertain, resident.transferCheckpoint(cut.checkpoint.?));
    publisher.decision = .committed;
    try std.testing.expectEqual(.committed, try resident.resolveRealization(publisher.owner()));
    const bound = try resident.runtimeBinding();
    try std.testing.expectEqual(binding.guest_revision, bound.guest_revision);
    try std.testing.expectEqual(binding.outer_revision + 1, bound.outer_revision);
    try std.testing.expectEqual(specialized.identity, bound.artifact.digest);
    try std.testing.expectError(error.StaleRuntimeBinding, resident.realize(binding, specialized, provenance, publisher.owner()));
    try std.testing.expectError(error.InvalidState, resident.transferCheckpoint(cut.checkpoint.?));
    publisher.last = null;
    try std.testing.expectEqual(.committed, try resident.realize(bound, &prepared.runtime, provenance, publisher.owner()));
    const generic = try resident.runtimeBinding();
    try std.testing.expectEqual(binding.artifact, generic.artifact);
    try std.testing.expectEqual(binding.guest_revision, generic.guest_revision);
    const state = try resident.checkpoint(a);
    defer a.free(state);
    try std.testing.expectEqualSlices(u8, cut.checkpoint.?.bytes(), state);
    const Custody = struct {
        capsule: capsules.Reference,
        target: capsules.Reference,
        consumed: bool = false,
        fn claim(context: *anyopaque, actual: capsules.Reference, record: capsules.Record, target: capsules.Reference) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.consumed or !std.meta.eql(self.capsule, actual) or !std.meta.eql(self.target, target) or !std.meta.eql(record.provenance, provenance)) return error.UnauthorizedCapsule;
            self.consumed = true;
        }
        fn verifier(self: *@This()) capsules.Verifier {
            return .{ .context = self, .claim = claim };
        }
    };
    var selected_prepared = try facade.Prepared.initWithRuntime(a, image, specialized);
    defer selected_prepared.deinit();
    const portable_cut = try resident.publishCapsule(a, .guest_cut, provenance);
    defer portable_cut.deinit();
    try resident.transferCapsule(portable_cut, .guest_cut);
    var custody: Custody = .{ .capsule = capsules.reference(portable_cut.bytes()), .target = generic.artifact };
    try std.testing.expectError(error.UnauthorizedCapsule, facade.Resident.restoreCapsuleSelected(a, &selected_prepared, &prepared.runtime, portable_cut.bytes(), custody.verifier()));
    try std.testing.expect(!custody.consumed);
    custody.target = .{ .digest = specialized.identity, .bytes = specialized.core.?.encoded_length };
    var restored = try facade.Resident.restoreCapsuleSelected(a, &selected_prepared, &prepared.runtime, portable_cut.bytes(), custody.verifier());
    defer if (restored.live) {
        const bytes = restored.takeCheckpoint(a) catch unreachable;
        a.free(bytes);
    };
    const reconstructed = try restored.checkpoint(a);
    defer a.free(reconstructed);
    try std.testing.expectEqualSlices(u8, state, reconstructed);
    try std.testing.expectError(error.UnauthorizedCapsule, facade.Resident.restoreCapsuleSelected(a, &selected_prepared, &prepared.runtime, portable_cut.bytes(), custody.verifier()));
    var final = try restored.drive(a, .none, .{});
    defer final.deinit();
    try std.testing.expect(final.record == .completed);
    try restored.close();
}

test "portable public session preserves observations checkpoint bytes and rollback" {
    const facade = @import("semantic/session.zig");
    var b = source.Builder.init(a);
    defer b.deinit();
    var compiled = try source.lower(a, try source.examples.cloned(&b));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    var prepared = try facade.Prepared.init(a, image);
    defer prepared.deinit();
    var portable = try facade.Session.start(a, &prepared, &.{});
    defer portable.deinit();
    var oracle = try native.Session.initImage(a, image, &.{});
    defer oracle.deinit();
    {
        const before = try portable.checkpoint(a);
        defer a.free(before);
        var transaction = try portable.begin();
        _ = try portable.run(3);
        transaction.rollback(&portable);
        const after = try portable.checkpoint(a);
        defer a.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
        try std.testing.expectEqual(@as(usize, 0), portable.transitions);
    }
    for (0..100) |_| {
        const actual = try portable.run(5);
        const expected = try oracle.run(5);
        try std.testing.expectEqualStrings(@tagName(expected), @tagName(actual));
        const checkpoint = try portable.checkpoint(a);
        defer a.free(checkpoint);
        const baseline = try oracle.checkpoint(a);
        defer a.free(baseline);
        try std.testing.expectEqualSlices(u8, baseline, checkpoint);
        switch (actual) {
            .completed => |value| {
                try std.testing.expectEqualSlices(u8, try oracle.bytes(&expected.completed), try portable.bytes(&value));
                const final = try portable.terminalExit();
                try std.testing.expect(final.reason == .normal and portable.isTerminal());
                return;
            },
            .yielded => {
                try portable.resumeYield();
                try oracle.resumeYield();
            },
            .progressed => {},
            else => return error.UnexpectedObservation,
        }
    }
    return error.UnfinishedTest;
}

test "host pump binds guest ERS3 while retaining private operation microprogress" {
    var selected = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer selected.deinit();
    var b = source.Builder.init(a);
    defer b.deinit();
    var compiled = try source.lower(a, try source.examples.resourceScalar(&b));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    var prepared = try @import("base/session.zig").Prepared.init(a, image);
    defer prepared.deinit();
    var expected = try native.Session.initImage(a, image, &.{});
    defer expected.deinit();
    var pump = try driver.Driver.start(a, &prepared, &selected, .{ .arguments = &.{} });
    defer pump.deinit();
    selected.deinit(); // the driver retains its own artifact and helper lease
    prepared.deinit(); // both executions hold independent strong leases
    var initialized = try complete(&pump);
    initialized.deinit();
    var statistics: native.Statistics = .{};
    pump.outer.statistics = &statistics;
    try std.testing.expectError(error.InvalidBridge, pump.outer.replyBridge(@splat(0), 0, &.{}));
    try std.testing.expectError(error.InvalidBridge, pump.outer.replyBridge(pump.core_identity, 1, &.{}));
    {
        const before = try pump.outer.checkpoint(a);
        defer a.free(before);
        const revision = pump.revision;
        var transaction = try pump.begin();
        try pump.submit(.{ .advance = .{ .control = .none, .quantum = 5 } });
        try std.testing.expectEqual(@as(u64, 1), statistics.state_projections); // only the explicitly requested snapshot
        try std.testing.expect(try pump.pump(7) == .suspended);
        transaction.rollback(&pump);
        const after = try pump.outer.checkpoint(a);
        defer a.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
        try std.testing.expectEqual(revision, pump.revision);
        try std.testing.expect(pump.operation == null);
    }
    for (0..100) |_| {
        try pump.submit(.{ .advance = .{ .control = .none, .quantum = 5 } });
        try std.testing.expectError(error.OperationInProgress, pump.submit(.observe));
        try std.testing.expectError(error.GuestCutUnavailable, pump.checkpoint(a));
        try std.testing.expect(try pump.pump(1) == .suspended);
        var cut = try complete(&pump);
        defer cut.deinit();
        const native_result = try expected.run(5);
        const actual = try pump.checkpoint(a);
        defer a.free(actual);
        const canonical = try expected.checkpoint(a);
        defer a.free(canonical);
        try std.testing.expectEqualSlices(u8, canonical, actual);
        if (native_result == .requested) {
            const outer_before = try pump.outer.checkpoint(a);
            defer a.free(outer_before);
            const revision = pump.revision;
            const recovered = try pump.checkpoint(a);
            defer a.free(recovered);
            const outer_after = try pump.outer.checkpoint(a);
            defer a.free(outer_after);
            try std.testing.expectEqualSlices(u8, outer_before, outer_after);
            try std.testing.expectEqual(revision, pump.revision);
        }
        var observed = try pump.exchange(.observe);
        defer observed.deinit();
        switch (native_result) {
            .requested => {
                var request = try expected.pendingBinding(a, false);
                defer request.deinit();
                var actual_request = try pump.pendingBinding(a, false);
                defer actual_request.deinit();
                try std.testing.expectEqualSlices(u8, &request.request.request_identity, &actual_request.request.request_identity);
                const effect = expected.program.effects[@intCast(request.request.binding.effect)];
                const value: []const u8 = if (expected.program.schemas[@intCast(effect.result)] == .unit) &.{} else &.{ 41, 0, 0, 0, 0, 0, 0, 0 };
                var wrong = request.request.request_identity;
                wrong[0] ^= 1;
                const rejected = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = wrong, .value = value });
                defer a.free(rejected);
                try std.testing.expectError(error.InvalidResult, pump.reply(rejected, 0));
                const response = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = request.request.request_identity, .value = value });
                defer a.free(response);
                try pump.reply(response, 0);
                try std.testing.expectError(error.OperationInProgress, pump.reply(response, 0));
                var replied = try complete(&pump);
                replied.deinit();
                try expected.answer(response);
            },
            .completed => |value| {
                try std.testing.expect(observed.value.observation == .completed);
                try std.testing.expectEqualSlices(u8, try expected.bytes(&value), observed.value.observation.completed);
                try pump.submit(.finish);
                try std.testing.expect(try pump.pump(null) == .closed);
                return;
            },
            .yielded => {
                var resumed = try pump.exchange(.{ .advance = .{ .control = .resume_yield, .quantum = 0 } });
                resumed.deinit();
                try expected.resumeYield();
            },
            .progressed => {},
            else => return error.UnexpectedGuestFailure,
        }
    }
    return error.UnfinishedTest;
}
