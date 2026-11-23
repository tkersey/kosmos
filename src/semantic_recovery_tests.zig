const std = @import("std");
const data = @import("horos_data");
const compiler = @import("root.zig").RuntimeCompiler;
const transport = @import("horos_recovery");
const base = @import("base/session.zig");
const driver = @import("semantic/driver.zig");
const service = @import("semantic/service.zig");
const artifact = @import("semantic/artifact.zig");
const capsule = @import("semantic/capsule.zig");
const native = @import("native_baseline");
const a = std.testing.allocator;
const provenance: capsule.Provenance = .{
    .execution = @splat(91),
    .custody = @splat(52),
    .publication = null,
};

fn scalarBytes(value: u64) [8]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return bytes;
}

fn branchGuest() ![]u8 {
    const p: data.activation.Program = .{
        .roots = .{ .entry = 0, .result = 1, .failure = 0 },
        .schemas = &.{ .unit, .u64, .boolean },
        .constants = &.{},
        .effects = &.{.{ .identity = "test/recovery-branch", .payload = 1, .result = 1 }},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 2, 1, 1 } },
            .result = 1,
            .effects = &.{0},
        }},
        .blocks = &.{
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .branch = .{
                .condition = 0,
                .when_true = .{ .block = 1 },
                .when_false = .{ .block = 2 },
            } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .perform = .{
                .effect = 0,
                .payload = 1,
                .next = .{ .block = 2, .assignments = &.{
                    .{ .source = .returned, .destination = 2 },
                } },
            } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        },
    };
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(p));
    errdefer a.free(bytes);
    _ = try data.program_image.encode(a, p, bytes);
    return bytes;
}

const Custody = struct {
    expected: capsule.Reference,
    target: artifact.Digest,
    consumed: bool = false,

    fn claim(
        ptr: *anyopaque,
        ref: capsule.Reference,
        record: capsule.Record,
        dest: capsule.Reference,
    ) !void {
        const self: *Custody = @ptrCast(@alignCast(ptr));
        if (self.consumed or !std.meta.eql(ref, self.expected) or
            !std.meta.eql(dest.digest, self.target) or
            !std.meta.eql(record.provenance, provenance)) return error.UnauthorizedCapsule;
        self.consumed = true;
    }

    fn verifier(self: *Custody) capsule.Verifier {
        return .{ .context = self, .claim = claim };
    }
};

const Location = struct { block: u64, position: usize };

fn targets(arena: std.mem.Allocator, selected: *const artifact.Admitted) ![]Location {
    const bytes = selected.content.value.evidence;
    var reader: data.wire.Reader = .{ .input = bytes };
    const envelope = try data.record.read(compiler.RecoveryEvidence, &reader, arena);
    try std.testing.expectEqual(bytes.len, reader.position);
    var inner = try transport.source.recovery_optimization.decode(
        arena,
        envelope.recovery,
        compiler.recovery_limits,
    );
    defer inner.deinit();
    const map = inner.evidence.correspondence.maps[@backingInt(data.relocation.Kind.block)];
    var sites: std.ArrayList(Location) = .empty;
    for (inner.evidence.witnesses) |witness| {
        const block = map[witness.target.block];
        if (block == data.relocation.missing) continue;
        const position = witness.target.instruction;
        const instructions = selected.program.program().blocks[@intCast(block)].instructions;
        const instruction = instructions[position];
        try std.testing.expectEqual(.move, instruction.opcode);
        try sites.append(arena, .{ .block = block, .position = position });
    }
    try std.testing.expect(sites.items.len != 0);
    return sites.items;
}

const Coverage = struct {
    init: bool = false,
    publish: bool = false,
    parked: bool = false,
    finish: bool = false,
    before: bool = false,
    after: bool = false,
    walk: bool = false,
    rebase: bool = false,
    cuts: u64 = 0,
};

const Run = struct {
    prepared: *const base.Prepared,
    selected: *const artifact.Admitted,
    other: *const artifact.Admitted,
    failing: *std.testing.FailingAllocator,
    owner: ?driver.Driver,
    sites: []const Location,
    coverage: *Coverage,
    awaiting: ?Location = null,
    oracle_transitions: usize = 0,

    fn transfer(self: *Run, kind: capsule.Kind) !void {
        const owner = &self.owner.?;
        const bytes = try capsule.publish(a, owner, kind, provenance);
        defer a.free(bytes);
        const origin = self.selected;
        const target = if (kind == .guest_cut) self.other else origin;
        var custody: Custody = .{ .expected = capsule.reference(bytes), .target = target.identity };
        if (kind == .outer_execution) {
            try std.testing.expectError(error.IncompatibleRuntime, capsule.restoreSelected(
                a,
                self.prepared,
                origin,
                self.other,
                bytes,
                custody.verifier(),
            ));
            try std.testing.expect(!custody.consumed);
        }
        const before = if (kind == .guest_cut)
            try owner.checkpoint(a)
        else
            try owner.outer.checkpoint(a);
        defer a.free(before);
        const revision = owner.guest_revision;
        owner.deinit();
        self.owner = null;
        self.owner = try capsule.restoreSelected(
            self.failing.allocator(),
            self.prepared,
            origin,
            target,
            bytes,
            custody.verifier(),
        );
        self.selected = target;
        if (kind == .guest_cut) self.other = origin;
        try std.testing.expect(custody.consumed);
        try std.testing.expectEqual(revision, self.owner.?.guest_revision);
        const after = if (kind == .guest_cut)
            try self.owner.?.checkpoint(a)
        else
            try self.owner.?.outer.checkpoint(a);
        defer a.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
    }

    fn privateCut(self: *Run) !void {
        const owner = &self.owner.?;
        const coverage = self.coverage;
        coverage.cuts += 1;
        try std.testing.expectError(error.GuestCutUnavailable, owner.checkpoint(a));
        var restore = false;
        const operation = owner.operation.?;
        if (operation == .initialize and !coverage.init) {
            coverage.init = true;
            restore = true;
        }
        if (operation == .finish and !coverage.finish) {
            coverage.finish = true;
            restore = true;
        }
        if (owner.outer.roots.current) |current| {
            const control = (try owner.outer.store.get(current)).control;
            const frame = try owner.outer.frames.get(current.id);
            if (self.awaiting) |site| {
                try std.testing.expectEqual(site.block, control.block);
                try std.testing.expectEqual(site.position + 1, frame.position);
                self.awaiting = null;
                coverage.after = true;
                restore = true;
            } else if (!coverage.before) {
                for (self.sites) |site| {
                    if (control.block != site.block or frame.position != site.position) continue;
                    self.awaiting = site;
                    coverage.before = true;
                    restore = true;
                    break;
                }
            }
            if (operation == .advance and !coverage.publish and
                try self.publishing(frame))
            {
                coverage.publish = true;
                restore = true;
            }
            if (!coverage.walk or !coverage.rebase) {
                restore = try self.cloneCut(frame.function) or restore;
            }
        }
        if (restore) try self.transfer(.outer_execution);
    }

    fn publishing(self: *Run, frame: @import("interpreter_v2/activation_frames.zig").Frame) !bool {
        var retained: ?u64 = null;
        for (self.selected.content.value.recovery.anchors) |anchor| {
            if (anchor.function != frame.function or anchor.role != .committed_service) continue;
            const parameter = anchor.parameters[0];
            const view = try self.owner.?.outer.frames.slots.reader(frame.view);
            const value = view.at(@intCast(parameter.slot)) catch |err| switch (err) {
                error.UninitializedSlot => continue,
                else => return err,
            };
            try std.testing.expectEqual(parameter.schema, value.schema);
            if (retained) |slot| if (slot != parameter.slot) return true;
            retained = parameter.slot;
        }
        return false;
    }

    fn cloneCut(self: *Run, function: u64) !bool {
        const coverage = self.coverage;
        for (self.selected.content.value.recovery.anchors) |anchor| {
            if (anchor.function != function) continue;
            if ((anchor.role != .clone_context or coverage.walk) and
                (anchor.role != .clone_rebase or coverage.rebase)) continue;
            const owner = &self.owner.?;
            const inspected = try @import("semantic/realization.zig").inspect(
                a,
                &owner.outer,
                owner.selected,
                owner.guest.admitted(),
            );
            if (anchor.role == .clone_context and inspected.clone_contexts != 0) {
                coverage.walk = true;
                return true;
            }
            if (anchor.role == .clone_rebase and inspected.clone_rebases != 0) {
                coverage.rebase = true;
                return true;
            }
        }
        return false;
    }

    fn pump(self: *Run) !driver.Pump {
        for (0..8_000_000) |_| {
            const result = try self.owner.?.pump(1);
            if (result != .suspended) return result;
            try self.privateCut();
        }
        return error.PumpBoundExhausted;
    }

    fn committed(self: *Run, oracle: *native.Session) !void {
        var result = try self.pump();
        defer result.deinit();
        try std.testing.expect(result == .event and result.event.value == .cut);
        const work = oracle.transitions -% self.oracle_transitions;
        try std.testing.expectEqual(@as(u64, work), result.event.value.cut.guest_work);
        self.oracle_transitions = oracle.transitions;
        const expected = try oracle.checkpoint(a);
        defer a.free(expected);
        var expected_cut = try data.state_image.decodeGraph(a, expected);
        defer expected_cut.deinit();
        try std.testing.expectEqual(expected_cut.state.status, result.event.value.cut.status);
        const actual = try self.owner.?.checkpoint(a);
        defer a.free(actual);
        try std.testing.expectEqualSlices(u8, expected, actual);
        if (result.event.value.cut.status == .parked and !self.coverage.parked) {
            var pending = try oracle.pendingBinding(a, false);
            defer pending.deinit();
            try self.transfer(.outer_execution);
            var restored = try self.owner.?.pendingBinding(a, false);
            defer restored.deinit();
            try std.testing.expectEqualDeep(pending.request, restored.request);
            self.coverage.parked = true;
        }
    }

    fn rollback(self: *Run) !void {
        const owner = &self.owner.?;
        const before = try owner.outer.checkpoint(a);
        defer a.free(before);
        const revision = owner.revision;
        const command: service.Command = .{ .advance = .{ .control = .none, .quantum = 1 } };
        self.failing.fail_index = self.failing.alloc_index;
        try std.testing.expectError(error.OutOfMemory, owner.submit(command));
        self.failing.fail_index = std.math.maxInt(usize);
        var transaction = try owner.begin();
        try owner.submit(command);
        try std.testing.expect(try owner.pump(1) == .suspended);
        self.failing.fail_index = self.failing.alloc_index;
        const publication = capsule.publish(
            self.failing.allocator(),
            owner,
            .outer_execution,
            provenance,
        );
        self.failing.fail_index = std.math.maxInt(usize);
        transaction.rollback(owner);
        try std.testing.expectError(error.OutOfMemory, publication);
        try std.testing.expectEqual(revision, owner.revision);
        try std.testing.expect(owner.operation == null);
        const after = try owner.outer.checkpoint(a);
        defer a.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
    }
};

fn advance(owner: *driver.Driver, oracle: *native.Session) !void {
    switch (owner.last_cut.?.status) {
        .yielded => {
            try oracle.resumeYield();
            try owner.submit(.{ .advance = .{ .control = .resume_yield, .quantum = 1 } });
        },
        .parked => {
            var expected = try oracle.pendingBinding(a, false);
            defer expected.deinit();
            var actual = try owner.pendingBinding(a, false);
            defer actual.deinit();
            try std.testing.expectEqualDeep(expected.request, actual.request);
            const response = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = expected.request.request_identity,
                .value = &scalarBytes(41),
            });
            defer a.free(response);
            try oracle.answer(response);
            try owner.reply(response, 1);
        },
        else => try owner.submit(.{ .advance = .{ .control = .none, .quantum = 1 } }),
    }
}

const Fixture = struct {
    image: []const u8,
    input: []const u8,
    answer: ?u64 = null,
    hydration: enum { none, committed, parked } = .none,
};

fn execute(
    selected: *const artifact.Admitted,
    other: *const artifact.Admitted,
    fixture: Fixture,
    sites: []const Location,
    coverage: *Coverage,
) !void {
    var prepared = try base.Prepared.init(a, fixture.image);
    defer prepared.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{});
    var run: Run = .{
        .owner = try driver.Driver.start(failing.allocator(), &prepared, selected, .{
            .arguments = fixture.input,
        }),
        .failing = &failing,
        .selected = selected,
        .other = other,
        .prepared = &prepared,
        .sites = sites,
        .coverage = coverage,
    };
    defer if (run.owner) |*owner| owner.deinit();
    var oracle = try native.Session.initImage(a, fixture.image, fixture.input);
    defer oracle.deinit();
    try run.committed(&oracle);
    try run.rollback();
    var hydrated = false;
    for (0..1000) |_| {
        try advance(&run.owner.?, &oracle);
        const observed = try oracle.run(1);
        try run.committed(&oracle);
        if (observed != .completed) {
            const transfer_cut = switch (fixture.hydration) {
                .none => false,
                .committed => true,
                .parked => run.owner.?.last_cut.?.status == .parked,
            };
            if (transfer_cut and !hydrated) {
                try run.transfer(.guest_cut);
                run.sites = &.{};
                hydrated = true;
            }
            continue;
        }
        try std.testing.expectEqual(fixture.hydration != .none, hydrated);
        const value = try oracle.bytes(&observed.completed);
        if (fixture.answer) |expected| try std.testing.expectEqualSlices(
            u8,
            &scalarBytes(expected),
            value,
        );
        try run.owner.?.submit(.observe);
        var result = try run.pump();
        defer result.deinit();
        try std.testing.expect(result == .event and result.event.value == .observation);
        try std.testing.expectEqualSlices(u8, value, result.event.value.observation.completed);
        try run.owner.?.submit(.finish);
        try std.testing.expect(try run.pump() == .closed);
        return;
    }
    return error.UnfinishedTest;
}

fn expectBranchPaths(
    legacy: *const artifact.Admitted,
    optimized: *const artifact.Admitted,
    sites: []const Location,
) !void {
    const image = try branchGuest();
    defer a.free(image);
    var before: Coverage = .{};
    var after: Coverage = .{};
    for ([_]u8{ 0, 1 }) |condition| {
        const input = [1]u8{condition} ++ scalarBytes(17) ++
            scalarBytes(29);
        const fixture: Fixture = .{
            .image = image,
            .input = &input,
            .answer = if (condition != 0) 41 else 29,
        };
        try execute(legacy, optimized, fixture, &.{}, &before);
        try execute(optimized, legacy, fixture, sites, &after);
        try std.testing.expectEqual(condition != 0, before.parked);
        try std.testing.expectEqual(condition != 0, after.parked);
    }
    try std.testing.expect(before.init and before.publish and before.parked and before.finish);
    try std.testing.expect(after.init and after.publish and after.parked and after.finish);
    try std.testing.expect(before.cuts > 0 and after.cuts > 0);
    std.debug.print("branch suspensions structural={d} optimized={d}\n", .{
        before.cuts, after.cuts,
    });
    for ([_]u8{ 0, 1 }) |condition| {
        const input = [1]u8{condition} ++ scalarBytes(2) ++ scalarBytes(5);
        var hydration: Coverage = .{};
        try execute(legacy, optimized, .{
            .image = image,
            .input = &input,
            .answer = if (condition == 0) 5 else 41,
            .hydration = if (condition == 0) .committed else .parked,
        }, &.{}, &hydration);
    }
}

fn expectClone(
    legacy: *const artifact.Admitted,
    optimized: *const artifact.Admitted,
    sites: []const Location,
) !void {
    const image = try @import("semantic/capsule_tests.zig").rawCloneGuest();
    defer a.free(image);
    const fixture: Fixture = .{ .image = image, .input = &scalarBytes(17) };
    var before: Coverage = .{};
    var after: Coverage = .{};
    try execute(legacy, optimized, fixture, &.{}, &before);
    try execute(optimized, legacy, fixture, sites, &after);
    try std.testing.expect(before.walk and before.rebase);
    try std.testing.expect(after.walk and after.rebase and after.before and after.after);
    std.debug.print("multi-shot suspensions structural={d} optimized={d}\n", .{
        before.cuts, after.cuts,
    });
}

fn altered(
    selected: *const artifact.Admitted,
    policy: []const u8,
    evidence: []const u8,
) !artifact.Admitted {
    var bundle = selected.content.value;
    bundle.manifest.compiler.policy = policy;
    bundle.evidence = evidence;
    const bytes = try artifact.encode(a, bundle);
    defer a.free(bytes);
    return artifact.Admitted.init(a, bytes, artifact.digest(bytes));
}

fn expectForgedEndpoint(optimized: *const artifact.Admitted) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    const records = @import("semantic/recovery_records.zig");
    var reader: transport.data.wire.Reader = .{ .input = optimized.content.value.evidence };
    var envelope = try transport.data.record.read(compiler.RecoveryEvidence, &reader, mem);
    try reader.finish();
    var proof = try transport.source.recovery_optimization.decode(
        a,
        envelope.recovery,
        compiler.recovery_limits,
    );
    defer proof.deinit();
    try std.testing.expect(proof.evidence.witnesses.len != 0);
    const endpoint = &@constCast(proof.evidence.witnesses)[0];
    endpoint.source = endpoint.target;
    envelope.recovery = try records.encode(mem, proof.evidence);
    const bytes = try records.encode(mem, envelope);
    var forged = try altered(optimized, compiler.recovery_policy, bytes);
    defer forged.deinit();
    try std.testing.expectError(error.InvalidExpressionReuse, compiler.validate(a, &forged));
}

fn expectIdentity(legacy: *const artifact.Admitted, optimized: *const artifact.Admitted) !void {
    const original = legacy.content.value;
    const candidate = optimized.content.value;
    try std.testing.expectEqualStrings(artifact.build_policy, original.manifest.compiler.policy);
    try std.testing.expectEqualStrings(
        compiler.recovery_policy,
        candidate.manifest.compiler.policy,
    );
    try std.testing.expect(!std.meta.eql(legacy.identity, optimized.identity));
    try std.testing.expect(!std.meta.eql(original.manifest.image, candidate.manifest.image));
    var unknown = try altered(optimized, "kosmos.source-lower/unknown", candidate.evidence);
    defer unknown.deinit();
    try std.testing.expectError(error.UnsupportedSource, compiler.validate(a, &unknown));
    var wrong = try altered(optimized, compiler.recovery_policy, original.evidence);
    defer wrong.deinit();
    if (compiler.validate(a, &wrong)) return error.AcceptedStructuralProof else |_| {}
}

test "checked scalar recovery executes both paths and restores interrupted phases" {
    const retained = @import("packaged_runtime").bytes;
    var legacy = try artifact.Admitted.init(a, retained, artifact.digest(retained));
    defer legacy.deinit();
    try compiler.validate(a, &legacy);
    const bytes = try compiler.compile(a, .{
        .horos_package = legacy.content.value.manifest.compiler.horos_package,
        .scalar_field_reuse = true,
    });
    defer a.free(bytes);
    var optimized = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer optimized.deinit();
    try compiler.validate(a, &optimized);
    try expectIdentity(&legacy, &optimized);
    try expectForgedEndpoint(&optimized);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sites = try targets(arena.allocator(), &optimized);
    try expectBranchPaths(&legacy, &optimized, sites);
    try expectClone(&legacy, &optimized, sites);
}
