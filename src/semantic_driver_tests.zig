const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const artifact = @import("semantic/artifact.zig");
const projection = @import("semantic/projection.zig");
const driver = @import("semantic/driver.zig");
const native = @import("native_baseline");
const packaged = @import("packaged_runtime");
const a = std.testing.allocator;
const facade = @import("semantic/session.zig");
const capsules = @import("semantic/capsule.zig");
const support = @import("semantic/test_support.zig");
test {
    _ = @import("semantic/capsule_tests.zig");
}

test "downstream packaged core equals independently rebuilt and validated source" {
    const retained = @import("semantic_packaged.zig");

    const rebuilt = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "semantic-core.kar",
        a,
        .unlimited,
    );
    defer a.free(rebuilt);
    var admitted = try artifact.Admitted.init(a, rebuilt, artifact.digest(rebuilt));
    defer admitted.deinit();
    try expectSourceExport(&admitted);
    var exported = try @import("semantic/compiler.zig").exportSource(a, &admitted);
    defer exported.deinit();
    try @import("semantic/analysis_tests.zig").expectDisclosedAnalysis(exported.value);
    try retained.check(admitted.content.value.manifest.compiler.horos_package);
    try std.testing.expectEqualSlices(u8, rebuilt, retained.bytes);
    try std.testing.expectError(
        error.PackagedCompilerMismatch,
        retained.check("different-compiler-package"),
    );
}

test "artifact admission binds exact content and independently scans its inventory" {
    var admitted = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer admitted.deinit();
    try std.testing.expectEqualSlices(
        u8,
        &@import("semantic/source_identity.zig").digest(),
        &admitted.content.value.manifest.source,
    );
    try std.testing.expect(admitted.content.value.manifest.inventory.instructions > 0);
    var wrong = artifact.digest(packaged.bytes);
    wrong[0] ^= 1;
    try std.testing.expectError(
        error.ArtifactIdentityMismatch,
        artifact.Admitted.init(a, packaged.bytes, wrong),
    );
    var bundle = admitted.content.value;
    bundle.manifest.inventory.instructions += 1;
    const forged = try artifact.encode(a, bundle);
    defer a.free(forged);
    try std.testing.expectError(
        error.InvalidInventory,
        artifact.Admitted.init(a, forged, artifact.digest(forged)),
    );
    bundle = admitted.content.value;
    bundle.manifest.bridge.identity = "model-authored-bridge";
    const bridge = try artifact.encode(a, bundle);
    defer a.free(bridge);
    try std.testing.expectError(
        error.UnsupportedArtifact,
        artifact.Admitted.init(a, bridge, artifact.digest(bridge)),
    );
    bundle = admitted.content.value;
    const anchors = try a.dupe(artifact.Anchor, bundle.recovery.anchors);
    defer a.free(anchors);
    anchors[0].role = .committed_service;
    bundle.recovery.anchors = anchors;
    const changed_map = try artifact.encode(a, bundle);
    defer a.free(changed_map);
    var changed = try artifact.Admitted.init(a, changed_map, artifact.digest(changed_map));
    defer changed.deinit();
    try std.testing.expectError(
        error.InvalidRecovery,
        @import("semantic/compiler.zig").validate(a, &changed),
    );
}

fn artifactAdmissionFailure(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var admitted = try artifact.Admitted.init(allocator, bytes, artifact.digest(bytes));
    defer admitted.deinit();
    var retained = try admitted.clone();
    defer retained.deinit();
    admitted.deinit();
    try std.testing.expectEqual(@as(usize, 4), retained.helpers.len);
    try std.testing.expect(retained.program.program().effects.len == 1);
}

test "artifact admission releases all five prepared owners at every allocation failure" {
    var compiled = try admissionOwnerProgram();
    defer compiled.deinit();
    const image = try support.encodeCompiled(&compiled);
    defer a.free(image);
    const program = try data.program_image.Admitted.decode(a, image);
    defer program.deinit();
    const helper_image = try support.guestImage();
    defer a.free(helper_image);
    const helper = try data.program_image.Admitted.decode(a, helper_image);
    defer helper.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const profile = @import("base/profile.zig");
    const helper_content: artifact.Helper = .{
        .image = helper_image,
        .inventory = try artifact.inventory(arena.allocator(), try profile.check(helper, .{})),
    };
    const bytes = try admissionOwnerBundle(
        &compiled,
        image,
        program,
        helper_content,
        arena.allocator(),
    );
    defer a.free(bytes);
    try @import("../test/v2/allocation_testing.zig").check(a, artifactAdmissionFailure, .{bytes});
}

fn complete(pump: *driver.Driver) !projection.Owned(@import("semantic/service.zig").Event) {
    return switch (try pump.pump(null)) {
        .event => |event| event,
        else => error.UnexpectedPumpResult,
    };
}

test "carried recovery binds admitted image and helpers to reconstructed source" {
    const compiler = @import("semantic/compiler.zig");
    var admitted = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer admitted.deinit();
    var program = admitted.program.program();
    const constants = try a.dupe(data.program.Literal, program.constants);
    defer a.free(constants);
    var changed_literal: [8]u8 = undefined;
    var changed = false;
    for (constants) |*literal| {
        if (program.schemas[@intCast(literal.schema)] != .u64) continue;
        @memcpy(&changed_literal, literal.bytes);
        changed_literal[0] ^= 1;
        literal.bytes = &changed_literal;
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    program.constants = constants;
    const image = try a.alloc(u8, try data.program_image.encodedLength(program));
    defer a.free(image);
    _ = try data.program_image.encode(a, program, image);

    const checked = try data.program_image.Admitted.decode(a, image);
    defer checked.deinit();
    var bundle = admitted.content.value;
    bundle.image = image;
    bundle.manifest.image = checked.identity();
    const forged_bytes = try artifact.encode(a, bundle);
    defer a.free(forged_bytes);
    var forged = try artifact.Admitted.init(a, forged_bytes, artifact.digest(forged_bytes));
    defer forged.deinit();
    try std.testing.expectError(error.InvalidCorrespondence, compiler.validate(a, &forged));

    bundle = admitted.content.value;
    bundle.recovery.storage = bundle.recovery.projector;
    const helper_bytes = try artifact.encode(a, bundle);
    defer a.free(helper_bytes);
    var helper = try artifact.Admitted.init(a, helper_bytes, artifact.digest(helper_bytes));
    defer helper.deinit();
    try std.testing.expectError(error.InvalidRecovery, compiler.validate(a, &helper));
    try std.testing.expectError(error.InvalidRecovery, compiler.exportSource(a, &helper));

    bundle = admitted.content.value;
    bundle.manifest.compiler.policy = "kosmos.source-lower/1";
    bundle.evidence = &.{};
    const legacy_bytes = try artifact.encode(a, bundle);
    defer a.free(legacy_bytes);
    var legacy = try artifact.Admitted.init(a, legacy_bytes, artifact.digest(legacy_bytes));
    defer legacy.deinit();
    try std.testing.expectError(error.UnsupportedSource, compiler.validate(a, &legacy));
}

test "source instrumentation preserves cuts and blocks publication without guest failure" {
    const compiler = @import("semantic/compiler.zig");
    const bytes = try compiler.compile(a, .{
        .horos_package = "test-exact-horos",
        .hooks = .{ .control = true, .storage = true },
    });
    defer a.free(bytes);
    var selected = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer selected.deinit();
    try expectSourceExport(&selected);
    const image = try @import("semantic/test_support.zig").guestImage();
    defer a.free(image);
    try switchRealizations(image, &selected);
    try expectInstrumentationCuts(image, &selected);
    var prepared = try facade.Prepared.initWithRuntime(a, image, &selected);
    defer prepared.deinit();
    const input = std.mem.toBytes(@as(u64, 37));
    try expectTracePublication(&prepared, &input);
    var generic = try facade.Prepared.init(a, image);
    defer generic.deinit();
    var counterfeit = generic.runtime.content.value;
    counterfeit.hooks = .{ .control = true, .storage = true };
    const forged_bytes = try artifact.encode(a, counterfeit);
    defer a.free(forged_bytes);
    var forged = try artifact.Admitted.init(a, forged_bytes, artifact.digest(forged_bytes));
    defer forged.deinit();

    try std.testing.expectError(error.InvalidCorrespondence, compiler.validate(a, &forged));
}

test "packaged specialized realization carries independently checked recovery and guest binding" {
    const image = try @import("semantic/test_support.zig").guestImage();
    defer a.free(image);
    var prepared = try @import("base/session.zig").Prepared.init(a, image);
    defer prepared.deinit();
    const guest = try prepared.acquire();
    defer guest.release();
    const compiler = @import("semantic/compiler.zig");
    const bytes = try compiler.compile(a, .{
        .horos_package = "test-exact-horos",
        .guest = guest.admitted(),
    });
    defer a.free(bytes);
    var selected = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer selected.deinit();
    try expectSourceExport(&selected);
    try std.testing.expect(
        selected.content.value.guest != null and selected.content.value.specialization != null,
    );
    try switchRealizations(image, &selected);
    for ([_]u64{ 0, 37, std.math.maxInt(u64) - 7 }) |input| {
        var pump = try driver.Driver.start(a, &prepared, &selected, .{
            .arguments = &std.mem.toBytes(input),
        });
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
        const inspected = try @import("semantic/realization.zig").inspect(
            a,
            &pump.outer,
            pump.selected,
            guest.admitted(),
        );
        try std.testing.expect(inspected.committed > 0);
    }
}

fn switchRealizations(image: []const u8, specialized: *const artifact.Admitted) !void {
    var prepared = try facade.Prepared.init(a, image);
    defer prepared.deinit();
    var resident = try facade.Resident.start(a, &prepared, &std.mem.toBytes(@as(u64, 37)));
    defer if (resident.live) {
        const bytes = resident.takeCheckpoint(a) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        a.free(bytes);
    };
    var cut = try resident.publish(.{ .record = a }, .none, .{
        .quantum = 3,
        .checkpoint = .receipt,
    });
    defer cut.deinit();
    const binding = try resident.runtimeBinding();
    var publisher: Publisher = .{};
    try std.testing.expectEqual(.rejected, try resident.realize(
        binding,
        specialized,
        provenance,
        publisher.owner(),
    ));
    try std.testing.expectEqual(binding, try resident.runtimeBinding());
    publisher.decision = .uncertain;
    try std.testing.expectEqual(.uncertain, try resident.realize(
        binding,
        specialized,
        provenance,
        publisher.owner(),
    ));
    try std.testing.expectError(error.PublicationUncertain, resident.drive(a, .none, .{}));
    try std.testing.expectError(
        error.PublicationUncertain,
        resident.transferCheckpoint(cut.checkpoint.?),
    );
    publisher.decision = .committed;
    try std.testing.expectEqual(.committed, try resident.resolveRealization(publisher.owner()));
    const bound = try resident.runtimeBinding();
    try std.testing.expectEqual(binding.guest_revision, bound.guest_revision);
    try std.testing.expectEqual(binding.outer_revision + 1, bound.outer_revision);
    try std.testing.expectEqual(specialized.identity, bound.artifact.digest);
    try std.testing.expectError(error.StaleRuntimeBinding, resident.realize(
        binding,
        specialized,
        provenance,
        publisher.owner(),
    ));
    try std.testing.expectError(error.InvalidState, resident.transferCheckpoint(cut.checkpoint.?));
    try expectGenericSwitch(
        image,
        specialized,
        &prepared,
        &resident,
        &publisher,
        binding,
        bound,
        &cut,
    );
}

fn expectGenericSwitch(
    image: []const u8,
    specialized: *const artifact.Admitted,
    prepared: *const facade.Prepared,
    resident: *facade.Resident,
    publisher: *Publisher,
    binding: capsules.Binding,
    bound: capsules.Binding,
    cut: *facade.resident_types.Publication,
) !void {
    publisher.last = null;
    try std.testing.expectEqual(.committed, try resident.realize(
        bound,
        &prepared.runtime,
        provenance,
        publisher.owner(),
    ));
    const generic = try resident.runtimeBinding();
    try std.testing.expectEqual(binding.artifact, generic.artifact);
    try std.testing.expectEqual(binding.guest_revision, generic.guest_revision);
    const state = try resident.checkpoint(a);
    defer a.free(state);
    try std.testing.expectEqualSlices(u8, cut.checkpoint.?.bytes(), state);
    try expectSelectedCapsuleRestore(image, specialized, prepared, resident, generic, state);
}

test "portable public session preserves observations checkpoint bytes and rollback" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try support.encode(try source.examples.cloned(&b));
    defer a.free(image);
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
                try std.testing.expectEqualSlices(
                    u8,
                    try oracle.bytes(&expected.completed),
                    try portable.bytes(&value),
                );
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
    const image = try support.encode(try source.examples.resourceScalar(&b));
    defer a.free(image);
    var prepared = try @import("base/session.zig").Prepared.init(a, image);
    defer prepared.deinit();
    var expected = try native.Session.initImage(a, image, &.{});
    defer expected.deinit();
    var pump = try driver.Driver.start(a, &prepared, &selected, .{ .arguments = &.{} });
    defer pump.deinit();
    selected.deinit();
    prepared.deinit();
    var initialized = try complete(&pump);
    initialized.deinit();
    var statistics: @import("interpreter_v2/runtime_types.zig").Statistics = .{};
    pump.outer.statistics = &statistics;
    try std.testing.expectError(error.InvalidBridge, pump.outer.replyBridge(@splat(0), 0, &.{}));
    try std.testing.expectError(
        error.InvalidBridge,
        pump.outer.replyBridge(pump.core_identity, 1, &.{}),
    );
    try expectPumpRollback(&pump, &statistics);
    try expectPumpObservations(&pump, &expected);
}

fn admissionOwnerProgram() !source.Compiled {
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const bridge = try b.effect(.{
        .identity = @import("semantic/service.zig").identity,
        .payload = unit,
        .result = unit,
        .external = true,
    });
    const entry = try b.declare(&.{integer}, integer, &.{bridge}, &.{});
    const call = try b.term(.{ .perform = .{
        .effect = bridge,
        .payload = try b.constant(void, {}),
    } });
    try b.define(entry, try b.bind(try b.variable(unit), call, try b.pure(
        try b.reference(b.parameter(entry, 0)),
    )));
    return source.lower(a, b.module(entry, unit));
}

fn admissionOwnerBundle(
    compiled: *const source.Compiled,
    image: []const u8,
    program: *const data.program_image.Admitted,
    helper_content: artifact.Helper,
    allocator: std.mem.Allocator,
) ![]u8 {
    const profile = @import("base/profile.zig");
    const root = compiled.program.functions[@intCast(compiled.program.roots.entry)];
    return artifact.encode(a, .{
        .manifest = .{
            .image = program.identity(),
            .source = artifact.digest(image),
            .compiler = .{
                .horos_package = "allocation-owner-fixture",
                .zig = "0.17.0",
                .policy = artifact.build_policy,
            },
            .requirements = .{
                .base = profile.identity,
                .admission = artifact.admission_profile,
                .bridge = @import("semantic/service.zig").identity,
            },
            .bridge = compiled.program.effects[0],
            .inventory = try artifact.inventory(allocator, try profile.check(program, .{
                .effects = compiled.program.effects,
            })),
        },
        .image = image,
        .guest = null,
        .specialization = null,
        .recovery = .{
            .projector = helper_content,
            .storage = helper_content,
            .clone_context = helper_content,
            .clone_rebase = helper_content,
            .anchors = &.{
                .{
                    .function = compiled.program.roots.entry,
                    .role = .published_service,
                    .parameters = &.{
                        .{
                            .ordinal = 0,
                            .slot = root.inputs[0],
                            .schema = root.layout.slots[@intCast(root.inputs[0])],
                        },
                    },
                },
            },
        },
        .branch_returns = &.{},
        .template_entries = &.{},
        .evidence = &.{},
    });
}

fn expectInstrumentationCuts(image: []const u8, selected: *const artifact.Admitted) !void {
    var prepared = try facade.Prepared.initWithRuntime(a, image, selected);
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
        try std.testing.expectEqual(
            instrumented.driver.last_cut.?.status,
            trace.trace.control.?.status,
        );
        try std.testing.expect(plain.trace() == null);
    }
    std.debug.print(
        "instrumentation_witness guest_steps=6 generic_base={d} instrumen" ++
            "ted_base={d} generic_artifact_bytes={d} instrumented_artifact_bytes={d}\n",
        .{
            plain.driver.outer.transitions,
            instrumented.driver.outer.transitions,
            packaged.bytes.len,
            selected.core.?.encoded_length,
        },
    );
    try expectEffectTrace(selected);
}

fn expectEffectTrace(selected: *const artifact.Admitted) !void {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const effect_image = try support.encode(try source.examples.resourceScalar(&builder));
    defer a.free(effect_image);
    var effect_prepared = try facade.Prepared.initWithRuntime(a, effect_image, selected);
    defer effect_prepared.deinit();
    var effect_session = try facade.Session.start(a, &effect_prepared, &.{});
    defer effect_session.deinit();
    const observed = try effect_session.run(100);
    try std.testing.expect(observed == .requested);
    try std.testing.expectEqual(
        observed.requested.effect,
        effect_session.trace().?.trace.control.?.effect.?,
    );
    try std.testing.expectEqual(.parked, effect_session.trace().?.trace.control.?.status);
}

fn expectTracePublication(prepared: *const facade.Prepared, input: []const u8) !void {
    var resident = try facade.Resident.start(a, prepared, input);
    defer if (resident.live) {
        const checkpoint = resident.takeCheckpoint(a) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        a.free(checkpoint);
    };
    const before = try resident.checkpoint(a);
    defer a.free(before);
    var no_space: [0]u8 = .{};
    try std.testing.expectError(
        error.TracePublicationBlocked,
        resident.publish(
            .{ .record = a },
            .none,
            .{ .quantum = 3, .checkpoint = .receipt, .trace_buffer = &no_space },
        ),
    );
    const after = try resident.checkpoint(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    var room: [512]u8 = undefined;
    var published = try resident.publish(.{ .record = a }, .none, .{
        .quantum = 3,
        .checkpoint = .receipt,
        .trace_buffer = &room,
    });
    defer published.deinit();
    try std.testing.expect(published.trace != null);
    try std.testing.expect(published.outcome.record.record != .failed);
}

const Publisher = struct {
    decision: capsules.SwitchDecision = .rejected,
    calls: usize = 0,
    last: ?capsules.Reference = null,
    fn publish(
        context_ptr: *anyopaque,
        binding: capsules.Binding,
        before: []const u8,
        after: []const u8,
    ) capsules.SwitchDecision {
        const self: *@This() = @ptrCast(@alignCast(context_ptr));
        var source_capsule = projection.decode(capsules.Envelope, a, before) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        defer source_capsule.deinit();
        var target_capsule = projection.decode(capsules.Envelope, a, after) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        defer target_capsule.deinit();
        std.testing.expectEqualSlices(
            u8,
            source_capsule.value.checkpoint,
            target_capsule.value.checkpoint,
        ) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        std.testing.expectEqual(
            binding.guest_revision,
            target_capsule.value.record.guest_revision,
        ) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        std.testing.expectEqual(
            binding.outer_revision + 1,
            target_capsule.value.record.outer_revision,
        ) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        if (self.last) |last| std.testing.expectEqual(last, capsules.reference(
            after,
        )) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        self.last = capsules.reference(after);
        self.calls += 1;
        return self.decision;
    }
    fn owner(self: *@This()) capsules.SwitchOwner {
        return .{ .context = self, .publish = publish };
    }
};

const provenance: capsules.Provenance = .{
    .execution = @splat(11),
    .custody = @splat(12),
    .publication = null,
};

const Custody = struct {
    capsule: capsules.Reference,
    target: capsules.Reference,
    consumed: bool = false,
    fn claim(
        context: *anyopaque,
        actual: capsules.Reference,
        record: capsules.Record,
        target: capsules.Reference,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.consumed or !std.meta.eql(self.capsule, actual) or
            !std.meta.eql(self.target, target) or
            !std.meta.eql(record.provenance, provenance)) return error.UnauthorizedCapsule;
        self.consumed = true;
    }
    fn verifier(self: *@This()) capsules.Verifier {
        return .{ .context = self, .claim = claim };
    }
};

fn expectSelectedCapsuleRestore(
    image: []const u8,
    specialized: *const artifact.Admitted,
    prepared: *const facade.Prepared,
    resident: *facade.Resident,
    generic: capsules.Binding,
    state: []const u8,
) !void {
    var selected_prepared = try facade.Prepared.initWithRuntime(a, image, specialized);
    defer selected_prepared.deinit();
    const portable_cut = try resident.publishCapsule(a, .guest_cut, provenance);
    defer portable_cut.deinit();
    try resident.transferCapsule(portable_cut, .guest_cut);
    var custody: Custody = .{
        .capsule = capsules.reference(portable_cut.bytes()),
        .target = generic.artifact,
    };
    try std.testing.expectError(error.UnauthorizedCapsule, facade.Resident.restoreCapsuleSelected(
        a,
        &selected_prepared,
        &prepared.runtime,
        portable_cut.bytes(),
        custody.verifier(),
    ));
    try std.testing.expect(!custody.consumed);
    custody.target = .{
        .digest = specialized.identity,
        .bytes = specialized.core.?.encoded_length,
    };
    var restored = try facade.Resident.restoreCapsuleSelected(
        a,
        &selected_prepared,
        &prepared.runtime,
        portable_cut.bytes(),
        custody.verifier(),
    );
    defer if (restored.live) {
        const bytes = restored.takeCheckpoint(a) catch |err|
            std.debug.panic("{s}", .{@errorName(err)});
        a.free(bytes);
    };
    const reconstructed = try restored.checkpoint(a);
    defer a.free(reconstructed);
    try std.testing.expectEqualSlices(u8, state, reconstructed);
    try std.testing.expectError(error.UnauthorizedCapsule, facade.Resident.restoreCapsuleSelected(
        a,
        &selected_prepared,
        &prepared.runtime,
        portable_cut.bytes(),
        custody.verifier(),
    ));
    var final = try restored.drive(a, .none, .{});
    defer final.deinit();
    try std.testing.expect(final.record == .completed);
    try restored.close();
}

fn expectPumpRollback(
    pump: *driver.Driver,
    statistics: *@import("interpreter_v2/runtime_types.zig").Statistics,
) !void {
    const before = try pump.outer.checkpoint(a);
    defer a.free(before);
    const revision = pump.revision;
    var transaction = try pump.begin();
    try pump.submit(.{ .advance = .{ .control = .none, .quantum = 5 } });
    try std.testing.expectEqual(
        @as(u64, 1),
        statistics.state_projections,
    );
    try std.testing.expect(try pump.pump(7) == .suspended);
    transaction.rollback(pump);
    const after = try pump.outer.checkpoint(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(revision, pump.revision);
    try std.testing.expect(pump.operation == null);
}

fn expectRecoveryPreservesPump(pump: *driver.Driver) !void {
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

fn answerPumpRequest(pump: *driver.Driver, expected: *native.Session) !void {
    var request = try expected.pendingBinding(a, false);
    defer request.deinit();
    var actual_request = try pump.pendingBinding(a, false);
    defer actual_request.deinit();
    try std.testing.expectEqualSlices(
        u8,
        &request.request.request_identity,
        &actual_request.request.request_identity,
    );
    const effect = expected.program.effects[@intCast(request.request.binding.effect)];
    const value: []const u8 = if (expected.program.schemas[
        @intCast(effect.result)
    ] == .unit) &.{} else &.{ 41, 0, 0, 0, 0, 0, 0, 0 };
    const malformed = try a.alloc(u8, value.len + 1);
    defer a.free(malformed);
    @memcpy(malformed[0..value.len], value);
    malformed[value.len] = 255;
    const before = try pump.outer.checkpoint(a);
    defer a.free(before);
    const revision = pump.revision;
    const invalid: @import("semantic/service.zig").Command = .{ .advance = .{
        .control = .{ .answer = malformed },
        .quantum = 0,
    } };
    try std.testing.expectError(error.NonCanonical, pump.submit(invalid));
    try std.testing.expectError(error.NonCanonical, pump.exchange(invalid));
    const after = try pump.outer.checkpoint(a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(revision, pump.revision);
    try std.testing.expect(pump.operation == null);
    var wrong = request.request.request_identity;
    wrong[0] ^= 1;
    const rejected = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = wrong,
        .value = value,
    });
    defer a.free(rejected);
    try std.testing.expectError(error.InvalidResult, pump.reply(rejected, 0));
    const response = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = request.request.request_identity,
        .value = value,
    });
    defer a.free(response);
    try pump.reply(response, 0);
    try std.testing.expectError(error.OperationInProgress, pump.reply(response, 0));
    var replied = try complete(pump);
    replied.deinit();
    try expected.answer(response);
}

fn expectPumpObservations(pump: *driver.Driver, expected: *native.Session) !void {
    for (0..100) |_| {
        try pump.submit(.{ .advance = .{ .control = .none, .quantum = 5 } });
        try std.testing.expectError(error.OperationInProgress, pump.submit(.observe));
        try std.testing.expectError(error.GuestCutUnavailable, pump.checkpoint(a));
        try std.testing.expect(try pump.pump(1) == .suspended);
        var cut = try complete(pump);
        defer cut.deinit();
        const native_result = try expected.run(5);
        const actual = try pump.checkpoint(a);
        defer a.free(actual);
        const canonical = try expected.checkpoint(a);
        defer a.free(canonical);
        try std.testing.expectEqualSlices(u8, canonical, actual);
        if (native_result == .requested) {
            try expectRecoveryPreservesPump(pump);
        }
        var observed = try pump.exchange(.observe);
        defer observed.deinit();
        switch (native_result) {
            .requested => {
                try answerPumpRequest(pump, expected);
            },
            .completed => |value| {
                try std.testing.expect(observed.value.observation == .completed);
                try std.testing.expectEqualSlices(
                    u8,
                    try expected.bytes(&value),
                    observed.value.observation.completed,
                );
                try pump.submit(.finish);
                try std.testing.expect(try pump.pump(null) == .closed);
                return;
            },
            .yielded => {
                var resumed = try pump.exchange(.{ .advance = .{
                    .control = .resume_yield,
                    .quantum = 0,
                } });
                resumed.deinit();
                try expected.resumeYield();
            },
            .progressed => {},
            else => return error.UnexpectedGuestFailure,
        }
    }
    return error.UnfinishedTest;
}

fn expectSourceExport(runtime: *const artifact.Admitted) !void {
    const compiler = @import("semantic/compiler.zig");
    var exported = try compiler.exportSource(a, runtime);
    defer exported.deinit();
    const value = exported.value;
    try std.testing.expectEqual(runtime.identity, value.realization);
    try std.testing.expectEqual(runtime.content.value.manifest.image, value.image);
    try std.testing.expectEqual(runtime.content.value.manifest.source, value.emitter);
    try std.testing.expect(exported.retained.core != runtime.core);
    try std.testing.expect(!std.mem.eql(u8, &value.generic.digest, &value.emitter));
    try std.testing.expect(!std.mem.eql(u8, &value.selected.digest, &value.image));
    try expectModuleDigest(value.generic);
    try expectModuleDigest(value.selected);
    if (value.construction == null)
        try std.testing.expectEqual(value.evidence.derivation != null, value.guest != null);
    if (value.guest == null) {
        try std.testing.expectEqual(value.generic.digest, value.selected.digest);
    } else if (value.evidence.derivation != null) {
        try std.testing.expect(!std.mem.eql(u8, &value.generic.digest, &value.selected.digest));
    }
    for (value.helpers, runtime.helpers) |helper, image| {
        try expectModuleDigest(helper.source);
        var lowered = try source.lower(a, helper.source.module);
        defer lowered.deinit();
        try std.testing.expect(data.record.equal(
            data.activation.Program,
            lowered.program,
            image.program(),
        ));
    }
    for (value.generic_pure_entries) |entry| {
        try std.testing.expectEqual(@as(usize, 0), entry.signature.effects.len);
        try std.testing.expect(data.record.equal(
            source.ast.Function,
            entry.signature,
            value.generic.module.functions[entry.function],
        ));
    }
    try std.testing.expect(value.parameters.len != 0);
    try std.testing.expect(data.record.equal(
        []const artifact.Anchor,
        runtime.content.value.recovery.anchors,
        value.anchors,
    ));
    for (value.selected_roles) |role| {
        const function = value.selected.module.functions[role.function];
        for (role.ordinals) |ordinal| try std.testing.expect(ordinal < function.parameters.len);
    }
}

fn expectModuleDigest(module: @import("semantic/compiler.zig").SourceModule) !void {
    var length: data.wire.Writer = .{};
    try data.record.write(source.ast.Module, module.module, &length);
    const bytes = try a.alloc(u8, length.position);
    defer a.free(bytes);
    var writer: data.wire.Writer = .{ .output = bytes };
    try data.record.write(source.ast.Module, module.module, &writer);
    try std.testing.expectEqual(artifact.digest(bytes), module.digest);
}

test "source candidates keep exact checked ancestry through retained guest switching" {
    const compiler = @import("semantic/compiler.zig");
    var root = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer root.deinit();
    var exported = try compiler.exportSource(a, &root);
    defer exported.deinit();
    const image = try support.guestImage();
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    var proposed = try generatedProposal(exported.value.selected.module, null, 1);
    defer proposed.deinit();
    const proposal = proposed.value;
    const bytes = try compiler.deriveRecord(a, &root, guest, proposal, .{
        .horos_package = root.content.value.manifest.compiler.horos_package,
    });
    defer a.free(bytes);
    var candidate = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer candidate.deinit();
    try compiler.validateAgainst(a, &candidate, &root);
    try std.testing.expectEqual(root.identity, compiler.approvedRootIdentity(&candidate));
    try std.testing.expect(artifact.hasProgramArgument(candidate.content.value));
    try expectSourceExport(&candidate);
    try switchRealizations(image, &candidate);
    try expectCanonicalDelta(&candidate);
    try expectDerivedChain(&candidate, guest, proposal.selected);
    expectLayoutChain(&candidate, guest, image) catch |err| {
        std.debug.print("source layout chain: {s}\n", .{@errorName(err)});
        return err;
    };
    expectSpecializedChain(&candidate, guest, image) catch |err| {
        std.debug.print("source specialization chain: {s}\n", .{@errorName(err)});
        return err;
    };
    try expectRejectedCandidate(&root, guest, exported.value.selected.module);
    try expectGuestRestriction(&root, guest, exported.value.selected.module);
    try expectRejectedRoleSelectors(&root, guest, &exported);
    try expectEvidencePolicy(&root, guest, exported.value.selected.module);
    try std.testing.expectError(error.RelationLimit, compiler.validateWithPolicy(
        a,
        &candidate,
        .{ .work = 1 },
    ));
    try compiler.validateWithPolicy(a, &candidate, .{ .work = std.math.maxInt(u64) });
}

fn identityCandidate(
    root: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
    selected: source.ast.Module,
) !artifact.Admitted {
    const compiler = @import("semantic/compiler.zig");
    const bytes = try compiler.derive(a, root, guest, .{
        .selected = selected,
        .steps = &.{},
    }, .{ .horos_package = root.content.value.manifest.compiler.horos_package });
    defer a.free(bytes);
    return artifact.Admitted.init(a, bytes, artifact.digest(bytes));
}

fn expectGuestRestriction(
    root: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
    selected: source.ast.Module,
) !void {
    const compiler = @import("semantic/compiler.zig");
    var parent = try identityCandidate(root, guest, selected);
    defer parent.deinit();
    try compiler.validateAgainst(a, &parent, root);
    var same_guest = try identityCandidate(&parent, guest, selected);
    defer same_guest.deinit();
    try compiler.validateAgainst(a, &same_guest, &parent);
    var program = guest.program();
    const constants = try a.dupe(data.program.Literal, program.constants);
    defer a.free(constants);
    constants[0].bytes = &std.mem.toBytes(@as(u64, 8));
    program.constants = constants;
    const image = try a.alloc(u8, try data.program_image.encodedLength(program));
    defer a.free(image);
    _ = try data.program_image.encode(a, program, image);
    const other = try data.program_image.Admitted.decode(a, image);
    defer other.deinit();
    try std.testing.expectError(error.GuestIdentityMismatch, identityCandidate(
        &parent,
        other,
        selected,
    ));
    var unrelated = try identityCandidate(root, other, selected);
    defer unrelated.deinit();
    try compiler.validateAgainst(a, &unrelated, root);
    var bundle = unrelated.content.value;
    bundle.lineage.?.parent = parent.identity;
    const bytes = try artifact.encode(a, bundle);
    defer a.free(bytes);
    var reparented = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer reparented.deinit();
    try std.testing.expectError(error.GuestIdentityMismatch, compiler.validateAgainst(
        a,
        &reparented,
        &parent,
    ));
}

fn expectRejectedRoleSelectors(
    root: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
    exported: *const @import("semantic/compiler.zig").ExportedSource,
) !void {
    const compiler = @import("semantic/compiler.zig");
    const roles = try a.dupe(compiler.SourceRole, exported.value.selected_roles);
    defer a.free(roles);
    var helpers: [4]data.program.Id = undefined;
    for (exported.value.helpers, 0..) |helper, i| helpers[i] = helper.source.module.entry;
    for (0..3) |mutation| {
        roles[0] = exported.value.selected_roles[0];
        switch (mutation) {
            0 => roles[0].ordinals = &.{},
            1 => roles[0].function = std.math.maxInt(data.program.Id),
            2 => roles[0].ordinals = &.{std.math.maxInt(u32)},
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidRecovery, compiler.deriveRecord(a, root, guest, .{
            .selected = exported.value.selected.module,
            .steps = &.{},
            .interfaces = .{
                .roles = roles,
                .entries = exported.value.selected_entries,
                .helpers = helpers,
                .layout = .{},
                .input = .program_and_initial,
            },
        }, .{ .horos_package = root.content.value.manifest.compiler.horos_package }));
    }
}

fn expectEvidencePolicy(
    root: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
    selected: source.ast.Module,
) !void {
    const compiler = @import("semantic/compiler.zig");
    var steps: [64]source.relation.Step = undefined;
    for (&steps) |*step| step.* = .{ .successor = selected, .rule = .identity };
    const bytes = try compiler.derive(a, root, guest, .{
        .selected = selected,
        .steps = &steps,
    }, .{ .horos_package = root.content.value.manifest.compiler.horos_package });
    defer a.free(bytes);
    var candidate = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer candidate.deinit();
    if (compiler.validate(a, &candidate)) {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.Capacity, error.RelationLimit => {},
        else => return err,
    }
    try compiler.validateWithPolicy(a, &candidate, .{ .work = 1_000_000_000 });
}

test "generated scalar candidates measure actual evaluator work on identical guest cuts" {
    const compiler = @import("semantic/compiler.zig");
    var root = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer root.deinit();
    var exported = try compiler.exportSource(a, &root);
    defer exported.deinit();
    const image = try support.guestImage();
    defer a.free(image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    try expectGeneratedWork(&root, guest, image, exported.value.selected.module);
}

fn expectSpecializedChain(
    parent: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
    image: []const u8,
) !void {
    const compiler = @import("semantic/compiler.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var exported = try compiler.exportSource(a, parent);
    defer exported.deinit();
    const request: source.specialize.Request = .{
        .function = exported.value.selected.module.entry,
        .arguments = &.{ .{ .known = .{
            .schema = exported.definition.machine.program,
            .bytes = try projection.programBytes(scratch, guest),
        } }, .dynamic },
        .context = compiler.contextWithHooks(guest.identity(), parent.content.value.hooks),
        .policy = .{ .work = 8_000_000, .keys_per_function = 1, .depth = 1024 },
    };
    var specialized = try source.specialize.specialize(
        a,
        exported.value.selected.module,
        request,
    );
    defer specialized.deinit();
    var projected = try generatedProposal(specialized.module(), null, 1);
    defer projected.deinit();
    const specialized_step: source.relation.Step = .{
        .successor = specialized.module(),
        .rule = .{ .specialization = .{
            .request = request,
            .entry = specialized.entry,
            .functions = specialized.functions.items,
            .values = specialized.value_proofs.items,
            .terms = specialized.term_proofs.items,
        } },
    };
    const records = [_]source.relation.RecordStep{
        try source.relation.encodeRecordStep(scratch, specialized_step),
        projected.value.steps[0],
    };
    const bytes = try compiler.deriveRecord(a, parent, guest, .{
        .selected = projected.value.selected,
        .steps = &records,
    }, .{ .horos_package = parent.content.value.manifest.compiler.horos_package });
    defer a.free(bytes);
    var candidate = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer candidate.deinit();
    try compiler.validateAgainst(a, &candidate, parent);
    try std.testing.expect(!artifact.hasProgramArgument(candidate.content.value));
    try expectCompactEvidence(&candidate);
    try expectSourceExport(&candidate);
    try switchRealizations(image, &candidate);
}

fn expectRejectedLayout(original: source.ast.Module, machine: u64) !void {
    const Field = @import("semantic/machine.zig").Field;
    const coordinates = try a.alloc(u64, original.schemas[@intCast(machine)].product.len);
    defer a.free(coordinates);
    for (coordinates, 0..) |*coordinate, i| coordinate.* = @intCast(i);
    std.mem.swap(
        u64,
        &coordinates[@backingInt(Field.program)],
        &coordinates[@backingInt(Field.work)],
    );
    var proposed = try generatedProposal(original, .{
        .schema = machine,
        .coordinates = coordinates,
    }, 1);
    defer proposed.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var remaining: usize = 64_000_000;
    const step = try source.relation.decodeRecordStep(
        arena.allocator(),
        proposed.value.steps[0],
        &remaining,
    );
    try std.testing.expectError(error.UnsupportedRelation, source.relation.validate(
        a,
        original,
        proposed.value.selected,
        &.{step},
        .{ .work = 64_000_000, .private_schemas = &.{machine} },
    ));
}

fn expectCandidateWork(
    root: *const artifact.Admitted,
    candidate: *const artifact.Admitted,
    image: []const u8,
) !bool {
    var original = try facade.Prepared.initWithRuntime(a, image, root);
    defer original.deinit();
    var transformed = try facade.Prepared.initWithRuntime(a, image, candidate);
    defer transformed.deinit();
    const input = std.mem.toBytes(@as(u64, 37));
    var before = try facade.Session.start(a, &original, &input);
    defer before.deinit();
    var after = try facade.Session.start(a, &transformed, &input);
    defer after.deinit();
    const initialized = [2]u64{ before.driver.outer.transitions, after.driver.outer.transitions };
    for (0..6) |_| {
        _ = try before.run(1);
        _ = try after.run(1);
        const expected = try before.checkpoint(a);
        defer a.free(expected);
        const actual = try after.checkpoint(a);
        defer a.free(actual);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
    std.debug.print(
        "source_candidate_work guest_steps=6 generic_init={d} candidate_init={d} " ++
            "generic_total={d} candidate_total={d}\n",
        .{
            initialized[0],                  initialized[1],
            before.driver.outer.transitions, after.driver.outer.transitions,
        },
    );
    return after.driver.outer.transitions < before.driver.outer.transitions;
}

fn expectGeneratedWork(
    root: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
    image: []const u8,
    original: source.ast.Module,
) !void {
    const compiler = @import("semantic/compiler.zig");
    var proposed = try generatedProposal(original, null, 16);
    defer proposed.deinit();
    std.debug.print("source_candidate_edits={d}\n", .{proposed.value.steps.len});
    const bytes = try compiler.deriveRecord(a, root, guest, proposed.value, .{
        .horos_package = root.content.value.manifest.compiler.horos_package,
    });
    defer a.free(bytes);
    var candidate = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer candidate.deinit();
    try compiler.validateAgainst(a, &candidate, root);
    _ = try expectCandidateWork(root, &candidate, image);
}

fn generatedProposal(
    original: source.ast.Module,
    layout: ?source.relation.Layout,
    edits_max: u64,
) !projection.Owned(@import("semantic/compiler.zig").RecordProposal) {
    const compiler = @import("semantic/compiler.zig");
    const transformation = @import("semantic/transformation.zig");
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const module = if (layout != null)
        builder.module(try transformation.layout(&builder), try builder.scalar(void))
    else
        try transformation.scalar(&builder);
    var prepared = try support.prepare(module);
    defer prepared.deinit();
    const input = if (layout) |selected|
        try projection.encode(transformation.LayoutInput, a, .{
            .module = original,
            .layout = selected,
        })
    else
        try projection.encode(transformation.Input, a, .{
            .module = original,
            .edits_max = edits_max,
        });
    defer a.free(input);
    var work = try @import("base/session.zig").Session.start(a, &prepared, input, .{});
    defer work.deinit();
    const outcome = try work.run(null);
    try std.testing.expect(outcome == .completed);
    var result = try projection.decode(compiler.RecordProposal, a, try work.bytes(
        &outcome.completed,
    ));
    errdefer result.deinit();
    try std.testing.expect(result.value.steps.len > 0 and result.value.steps.len <= edits_max);
    return result;
}

fn expectLayoutChain(
    parent: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
    image: []const u8,
) !void {
    const compiler = @import("semantic/compiler.zig");
    var exported = try compiler.exportSource(a, parent);
    defer exported.deinit();
    var proposed = try generatedProposal(exported.value.selected.module, .{
        .schema = exported.definition.service.state,
        .coordinates = &.{ 1, 0 },
    }, 1);
    defer proposed.deinit();
    const bytes = try compiler.deriveRecord(a, parent, guest, proposed.value, .{
        .horos_package = parent.content.value.manifest.compiler.horos_package,
    });
    defer a.free(bytes);
    var candidate = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer candidate.deinit();
    try compiler.validateAgainst(a, &candidate, parent);
    try std.testing.expectEqual(
        @as(u64, 1),
        candidate.content.value.recovery.layout.service_machine,
    );
    try expectCompactEvidence(&candidate);
    try expectSourceExport(&candidate);
    try switchRealizations(image, &candidate);
    try expectRejectedLayout(exported.value.selected.module, exported.definition.machine.schema);
}

fn expectCompactEvidence(candidate: *const artifact.Admitted) !void {
    const construction = @import("semantic/construction.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    const stored = candidate.content.value.evidence;
    var evidence = try construction.decodeEvidence(storage, stored);
    evidence.selected = null;
    var expanded: data.wire.Writer = .{};
    try data.record.writeAlloc(construction.Evidence, storage, evidence, &expanded);
    try std.testing.expect(stored.len < expanded.position);
}

fn expectCanonicalDelta(candidate: *const artifact.Admitted) !void {
    const construction = @import("semantic/construction.zig");
    const evidence = candidate.content.value.evidence;
    var reader: data.wire.Reader = .{ .input = evidence };
    _ = try reader.bytes();
    _ = try reader.bytes();
    _ = try reader.natural();
    try std.testing.expectEqual(@as(u64, 1), try reader.natural());
    const start = reader.position;
    const prefix = try reader.natural();
    try std.testing.expect(prefix != 0);
    try std.testing.expectEqual(@as(u64, 0), try reader.natural());
    try std.testing.expectEqual(@as(usize, 0), (try reader.bytes()).len);
    const mutated = try a.alloc(u8, evidence.len + 20);
    defer a.free(mutated);
    var writer: data.wire.Writer = .{ .output = mutated };
    try writer.put(evidence[0..start]);
    try writer.natural(prefix - 1);
    try writer.natural(1);
    try writer.bytes(&.{});
    try writer.put(evidence[reader.position..]);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.NonCanonicalSourceDelta, construction.decodeEvidence(
        arena.allocator(),
        mutated[0..writer.position],
    ));
    writer.position = 0;
    try writer.put(evidence[0..start]);
    try writer.natural(std.math.maxInt(u64));
    try writer.natural(0);
    try writer.bytes(&.{});
    try writer.put(evidence[reader.position..]);
    try std.testing.expectError(error.InvalidSourceDelta, construction.decodeEvidence(
        arena.allocator(),
        mutated[0..writer.position],
    ));
}

fn expectDerivedChain(
    parent: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
    selected: source.ast.Module,
) !void {
    const compiler = @import("semantic/compiler.zig");
    const bytes = try compiler.derive(a, parent, guest, .{
        .selected = selected,
        .steps = &.{},
    }, .{ .horos_package = parent.content.value.manifest.compiler.horos_package });
    defer a.free(bytes);
    var next = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer next.deinit();
    try compiler.validateAgainst(a, &next, parent);
    try std.testing.expectEqual(
        compiler.approvedRootIdentity(parent),
        compiler.approvedRootIdentity(&next),
    );
    try std.testing.expectEqual(parent.identity, next.content.value.lineage.?.parent);
    try std.testing.expectError(error.InvalidAncestor, compiler.validateAgainst(a, parent, &next));
    var wrong = next.content.value;
    wrong.recovery.layout.machine_program = 1;
    const forged = try artifact.encode(a, wrong);
    defer a.free(forged);
    var admitted = try artifact.Admitted.init(a, forged, artifact.digest(forged));
    defer admitted.deinit();
    try std.testing.expectError(error.InvalidRecovery, compiler.validate(a, &admitted));
}

fn expectRejectedCandidate(
    root: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
    original: source.ast.Module,
) !void {
    const compiler = @import("semantic/compiler.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const selected = try source.own(source.ast.Module, scratch, original);
    var changed = false;
    for (@constCast(selected.constants)) |*literal| {
        if (selected.schemas[@intCast(literal.schema)] != .u64) continue;
        @constCast(literal.bytes)[0] ^= 1;
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    const bytes = try compiler.derive(a, root, guest, .{
        .selected = selected,
        .steps = &.{},
    }, .{ .horos_package = root.content.value.manifest.compiler.horos_package });
    defer a.free(bytes);
    var candidate = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer candidate.deinit();
    try std.testing.expectError(
        error.InvalidRelation,
        compiler.validateAgainst(a, &candidate, root),
    );
    try std.testing.expectError(error.InvalidRelation, compiler.exportSource(a, &candidate));
}
