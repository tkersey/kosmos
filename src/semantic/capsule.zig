//! Two explicit checkpoint levels. Content admission is deliberately separate
//! from the enclosing host's authenticated publication and custody decision.
const std = @import("std");
const data = @import("horos_data");
const artifact = @import("artifact.zig");
const service = @import("service.zig");
const driver = @import("driver.zig");
const projection = @import("projection.zig");
const realization = @import("realization.zig");
const base = @import("../base/session.zig");
const preparation = @import("../interpreter_v2/prepared.zig");

pub const identity = "kosmos.runtime-capsule/1";
pub const Kind = enum { guest_cut, outer_execution };
pub const Reference = struct { digest: artifact.Digest, bytes: u64 };
pub const Provenance = struct {
    execution: artifact.Digest,
    custody: artifact.Digest,
    /// The owning host's last durable publication, if initialization has one.
    publication: ?Reference,
};
pub const Disposition = enum { initializing, consumed, completed };
pub const Record = struct {
    contract: []const u8 = identity,
    kind: Kind,
    source: artifact.Digest,
    artifact: Reference,
    realization: struct { image: Reference, identity: artifact.Digest },
    guest: struct { image: Reference, identity: artifact.Digest },
    checkpoint: Reference,
    initial: Reference,
    command: Reference,
    requirements: artifact.Requirements,
    last_cut: ?service.Cut,
    guest_revision: u64,
    outer_revision: u64,
    operation: ?driver.Operation,
    disposition: Disposition,
    dependencies: []const Reference,
    provenance: Provenance,
};
pub const Envelope = struct { record: Record, checkpoint: []const u8, initial: []const u8, command: []const u8 };

pub fn reference(bytes: []const u8) Reference {
    return .{ .digest = artifact.digest(bytes), .bytes = bytes.len };
}

/// Read-only content inspection. This supplies no custody or execution grant.
pub fn read(a: std.mem.Allocator, bytes: []const u8) !projection.Owned(Envelope) {
    var decoded = try projection.decode(Envelope, a, bytes);
    errdefer decoded.deinit();
    const canonical = try projection.encode(Envelope, a, decoded.value);
    defer a.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical) or !std.mem.eql(u8, decoded.value.record.contract, identity)) return error.InvalidCapsule;
    return decoded;
}

pub fn publish(a: std.mem.Allocator, pump: *driver.Driver, kind: Kind, provenance: Provenance) ![]u8 {
    if (pump.closed) return error.InvalidState;
    if (kind == .guest_cut and pump.operation != null) return error.GuestCutUnavailable;
    const checked = try realization.inspect(a, &pump.outer, pump.selected, pump.guest.admitted());
    if (pump.operation != .initialize and checked.committed == 0) return error.MissingRecoveryAnchor;
    const checkpoint = if (kind == .guest_cut) try pump.checkpoint(a) else try pump.outer.checkpoint(a);
    defer a.free(checkpoint);
    const guest_bytes = try image(a, pump.guest.admitted());
    defer a.free(guest_bytes);
    const selected = pump.selected;
    const artifact_ref: Reference = .{ .digest = selected.identity, .bytes = selected.encoded_length };
    const guest_ref = reference(guest_bytes);
    return projection.encode(Envelope, a, .{
        .record = .{
            .kind = kind,
            .source = selected.content.value.manifest.source,
            .artifact = artifact_ref,
            .realization = .{ .image = reference(selected.content.value.image), .identity = selected.program.identity() },
            .guest = .{ .image = guest_ref, .identity = pump.guest.admitted().identity() },
            .checkpoint = reference(checkpoint),
            .initial = reference(pump.initial),
            .command = reference(pump.command),
            .requirements = selected.content.value.manifest.requirements,
            .last_cut = pump.last_cut,
            .guest_revision = pump.guest_revision,
            .outer_revision = pump.revision,
            .operation = pump.operation,
            .disposition = if (pump.operation == .initialize) .initializing else if (pump.operation != null) .consumed else .completed,
            .dependencies = &.{ artifact_ref, guest_ref },
            .provenance = provenance,
        },
        .checkpoint = checkpoint,
        .initial = pump.initial,
        .command = pump.command,
    });
}

/// This callback belongs to the conforming publication/custody owner. It must
/// authenticate this exact content and current execution scope, and reject an
/// already consumed import. Neither hash agreement nor a model-supplied name
/// supplies that authority. It runs after all fallible local preparation.
pub const Verifier = struct {
    context: *anyopaque,
    claim: *const fn (*anyopaque, Reference, Record, Reference) anyerror!void,
};

pub const Binding = struct { artifact: Reference, guest_revision: u64, outer_revision: u64, generation: u64 };
pub const SwitchDecision = enum { committed, rejected, uncertain };
/// The execution owner authenticates the exact target artifact, checks its
/// current work/control/disclosure authority, and publishes the binding and
/// candidate together. Repeated calls with these same bytes resolve/replay the
/// same operation. Unknown durable outcome MUST return uncertain.
pub const SwitchOwner = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, Binding, []const u8, []const u8) SwitchDecision,
};

/// Construct only a private candidate. Guest equality is checked independently
/// of hydration, using the canonical guest codec at both ends.
pub fn rehydrate(a: std.mem.Allocator, original: *driver.Driver, target: *const artifact.Admitted) !driver.Driver {
    if (original.operation != null or original.closed) return error.GuestCutUnavailable;
    const lease = try target.acquire();
    defer lease.release();
    if (!data.record.equal(artifact.Requirements, original.selected.content.value.manifest.requirements, lease.content.value.manifest.requirements)) return error.IncompatibleRuntime;
    const revision = try std.math.add(u64, original.revision, 1);
    const before = try original.checkpoint(a);
    defer a.free(before);
    var decoded = try data.state_image.decodeGraph(a, before);
    defer decoded.deinit();
    const guest: preparation.Prepared = .{ .core = original.guest };
    var candidate = try driver.Driver.start(a, &guest, target, .{ .state = decoded.state });
    errdefer candidate.deinit();
    var event = try candidate.pump(null);
    if (event != .event) return error.InvalidCapsule;
    event.event.deinit();
    const after = try candidate.checkpoint(a);
    defer a.free(after);
    if (!std.mem.eql(u8, before, after)) return error.ReconstructionMismatch;
    candidate.guest_revision = original.guest_revision;
    candidate.revision = revision;
    return candidate;
}

/// No unverified outer-restoration entry point is exported by the public API.
/// A failed verifier destroys only this private candidate and performs no guest
/// step or environmental operation. Successful return consumes host custody.
pub fn restore(a: std.mem.Allocator, guest: *const preparation.Prepared, selected: *const artifact.Admitted, bytes: []const u8, verifier: Verifier) !driver.Driver {
    return restoreSelected(a, guest, selected, selected, bytes, verifier);
}

/// Guest cuts can hydrate an independently approved target realization. Outer
/// execution requires the exact origin artifact. The custody owner approves
/// the target reference as well as consuming the authenticated source capsule.
pub fn restoreSelected(a: std.mem.Allocator, guest: *const preparation.Prepared, origin: *const artifact.Admitted, target: *const artifact.Admitted, bytes: []const u8, verifier: Verifier) !driver.Driver {
    var selected = try origin.clone();
    defer selected.deinit();
    var destination = try target.clone();
    defer destination.deinit();
    var envelope = try projection.decode(Envelope, a, bytes);
    defer envelope.deinit();
    const value = envelope.value;
    const record = value.record;
    const target_ref: Reference = .{ .digest = destination.identity, .bytes = destination.core.?.encoded_length };
    if (record.kind == .outer_execution and !std.mem.eql(u8, &selected.identity, &destination.identity)) return error.IncompatibleRuntime;
    if (!data.record.equal(artifact.Requirements, selected.content.value.manifest.requirements, destination.content.value.manifest.requirements)) return error.IncompatibleRuntime;
    const canonical = try projection.encode(Envelope, a, value);
    defer a.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical) or !std.mem.eql(u8, record.contract, identity)) return error.InvalidCapsule;
    const lease = try guest.acquire();
    defer lease.release();
    const guest_bytes = try image(a, lease.admitted());
    defer a.free(guest_bytes);
    const expected_artifact: Reference = .{ .digest = selected.identity, .bytes = (selected.core orelse return error.InvalidState).encoded_length };
    if (!std.meta.eql(record.artifact, expected_artifact) or !std.meta.eql(record.guest.image, reference(guest_bytes)) or
        !std.mem.eql(u8, &record.guest.identity, &lease.admitted().identity()) or
        !std.mem.eql(u8, &record.source, &selected.content.value.manifest.source) or
        !std.meta.eql(record.realization.image, reference(selected.content.value.image)) or
        !std.mem.eql(u8, &record.realization.identity, &selected.program.identity()) or
        !data.record.equal(artifact.Requirements, record.requirements, selected.content.value.manifest.requirements) or
        !std.meta.eql(record.checkpoint, reference(value.checkpoint)) or !std.meta.eql(record.initial, reference(value.initial)) or
        !std.meta.eql(record.command, reference(value.command)) or record.dependencies.len != 2 or
        !std.meta.eql(record.dependencies[0], expected_artifact) or !std.meta.eql(record.dependencies[1], record.guest.image)) return error.InvalidCapsule;
    if (selected.content.value.guest) |binding| if (!std.mem.eql(u8, &binding, &record.guest.identity)) return error.GuestIdentityMismatch;
    try disposition(a, value);
    var initial = try projection.decode(service.Initial, a, value.initial);
    defer initial.deinit();
    try driver.admitInitial(a, lease.admitted(), initial.value);
    var result = if (record.kind == .guest_cut) guest_cut: {
        var state = try data.state_image.decodeGraph(a, value.checkpoint);
        defer state.deinit();
        if (record.last_cut == null or state.state.status != record.last_cut.?.status) return error.InvalidCapsule;
        var restored = try driver.Driver.start(a, guest, &destination, .{ .state = state.state });
        errdefer restored.deinit();
        var first = try restored.pump(null);
        if (first != .event) return error.InvalidCapsule;
        first.event.deinit();
        const reconstructed = try restored.checkpoint(a);
        defer a.free(reconstructed);
        if (!std.mem.eql(u8, value.checkpoint, reconstructed)) return error.ReconstructionMismatch;
        break :guest_cut restored;
    } else outer_execution: {
        const runtime = try selected.acquire();
        errdefer runtime.release();
        const guest_lease = try guest.acquire();
        errdefer guest_lease.release();
        const initial_copy = try a.dupe(u8, value.initial);
        errdefer a.free(initial_copy);
        const command_copy = try a.dupe(u8, value.command);
        errdefer a.free(command_copy);
        break :outer_execution driver.Driver{
            .allocator = a,
            .guest = guest_lease,
            .selected = runtime,
            .outer = try base.Session.restore(a, &runtime.executable, value.checkpoint, selected.bridge()),
            .artifact_identity = selected.identity,
            .core_identity = selected.program.identity(),
            .initial = initial_copy,
            .command = command_copy,
            .operation = record.operation,
            .last_cut = record.last_cut,
            .revision = record.outer_revision,
            .guest_revision = record.guest_revision,
        };
    };
    errdefer result.deinit();
    if (record.kind == .outer_execution) {
        const checked = try realization.inspect(a, &result.outer, result.selected, result.guest.admitted());
        if (result.operation != .initialize and checked.committed == 0) return error.MissingRecoveryAnchor;
        if (result.operation == null) {
            var cut = try realization.guestCut(a, &result.outer, result.selected, result.guest.admitted());
            defer cut.deinit();
            if (record.last_cut == null or cut.state.status != record.last_cut.?.status) return error.InvalidCapsule;
        }
    } else {
        result.guest_revision = record.guest_revision;
        // Hydration is a new realization revision, never a guest transition.
        result.revision = try std.math.add(u64, record.outer_revision, 1);
    }
    try verifier.claim(verifier.context, reference(bytes), record, target_ref);
    return result;
}

fn disposition(a: std.mem.Allocator, value: Envelope) !void {
    const record = value.record;
    if (record.kind == .guest_cut and (record.operation != null or record.disposition != .completed or record.last_cut == null)) return error.InvalidCapsule;
    if (record.operation == .initialize) {
        if (record.disposition != .initializing or record.last_cut != null or record.guest_revision != 0 or value.command.len != 0) return error.InvalidCapsule;
        return;
    }
    if (record.last_cut == null or record.disposition != (if (record.operation == null) Disposition.completed else Disposition.consumed)) return error.InvalidCapsule;
    if (value.command.len == 0) {
        if (record.operation != null) return error.InvalidCapsule;
        return;
    }
    var command = try projection.decode(service.Command, a, value.command);
    defer command.deinit();
    if (record.operation) |operation| {
        const expected: driver.Operation = switch (command.value) {
            .advance => .advance,
            .observe => .observe,
            .project => .project,
            .finish => .finish,
        };
        if (operation != expected) return error.InvalidCapsule;
    }
}

fn image(a: std.mem.Allocator, program: *const data.program_image.Admitted) ![]u8 {
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(program.program()));
    errdefer a.free(bytes);
    _ = try data.program_image.encode(a, program.program(), bytes);
    return bytes;
}
