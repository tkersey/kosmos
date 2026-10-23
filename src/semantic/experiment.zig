const std = @import("std");
const data = @import("horos_data");
const artifact = @import("artifact.zig");
const service = @import("service.zig");
const projection = @import("projection.zig");
const Observation = @import("observe.zig").Observation;
const driver = @import("driver.zig");
const base = @import("../base/session.zig");
const Prepared = @import("../interpreter_v2/prepared.zig").Prepared;

pub const Control = service.Control;
pub const Stage = enum { initialized, advanced };
pub const Phase = enum { initializing, advancing, observing, projecting, ready };
pub const Segment = struct {
    allocator: std.mem.Allocator,
    checkpoint: []u8,
    observation: []u8,
    guest_work: u64,
    stage: Stage,

    pub fn deinit(self: *Segment) void {
        self.allocator.free(self.checkpoint);
        self.allocator.free(self.observation);
        self.* = undefined;
    }
};
pub const Pump = union(enum) { suspended, complete: Segment };
pub const Record = struct {
    contract: []const u8 = "kosmos.runtime-experiment/1",
    runtime: artifact.Digest,
    guest: artifact.Digest,
    phase: Phase,
    stage: Stage,
    guest_work: u64,
    checkpoint: []const u8,
    initial: []const u8,
    command: []const u8,
    operation: ?driver.Operation,
    last_cut: ?service.Cut,
    revision: u64,
    guest_revision: u64,
    observation: []const u8,
};

pub const Experiment = struct {
    execution: driver.Driver,
    phase: Phase = .initializing,
    stage: Stage = .initialized,
    guest_work: u64 = 0,
    observation: []u8 = &.{},

    pub fn init(
        a: std.mem.Allocator,
        image: []const u8,
        runtime: *const artifact.Admitted,
        checkpoint: []const u8,
    ) !Experiment {
        var prepared = try Prepared.init(a, image);
        defer prepared.deinit();
        var decoded = try data.state_image.decodeGraphBorrowed(a, checkpoint, .{});
        defer decoded.deinit();
        return .{ .execution = try driver.Driver.start(
            a,
            &prepared,
            runtime,
            .{ .state = decoded.state },
        ) };
    }

    pub fn deinit(self: *Experiment) void {
        self.execution.allocator.free(self.observation);
        self.execution.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Experiment, control: Control, guest_quantum: u64) !void {
        if (self.phase != .ready) return error.OperationInProgress;
        if (control == .answer) try self.execution.prepareProjectedReply();
        try self.execution.submit(.{ .advance = .{
            .control = control,
            .quantum = guest_quantum,
        } });
        self.execution.allocator.free(self.observation);
        self.observation = &.{};
        self.phase = .advancing;
        self.stage = .advanced;
    }

    pub fn pump(self: *Experiment, base_quantum: u64) !Pump {
        if (self.phase == .ready) return error.NoOperation;
        if (base_quantum == 0) return .suspended;
        var transaction = try self.execution.begin();
        errdefer transaction.rollback(&self.execution);
        var outcome = try self.execution.pump(base_quantum);
        defer outcome.deinit();
        if (outcome == .suspended) {
            transaction.commit(&self.execution);
            return .suspended;
        }
        if (outcome != .event) return error.InvalidServiceEvent;
        const result = try self.acceptEvent(outcome.event.value);
        transaction.commit(&self.execution);
        return result;
    }

    fn acceptEvent(self: *Experiment, event: service.Event) !Pump {
        switch (self.phase) {
            .initializing, .advancing => {
                if (event != .cut) return error.InvalidServiceEvent;
                try self.execution.submit(.observe);
                self.guest_work = event.cut.guest_work;
                self.phase = .observing;
                return .suspended;
            },
            .observing => {
                if (event != .observation) return error.InvalidServiceEvent;
                const bytes = try projection.encode(
                    Observation,
                    self.execution.allocator,
                    event.observation,
                );
                errdefer self.execution.allocator.free(bytes);
                try self.execution.submit(.project);
                self.observation = bytes;
                self.phase = .projecting;
                return .suspended;
            },
            .projecting => return self.acceptProjection(event),
            .ready => return error.NoOperation,
        }
    }

    fn acceptProjection(self: *Experiment, event: service.Event) !Pump {
        if (event != .projection) return error.InvalidServiceEvent;
        const result = try self.segmentFromProjection(self.execution.allocator, event.projection);
        self.phase = .ready;
        return .{ .complete = result };
    }

    pub fn completedSegment(self: *Experiment, a: std.mem.Allocator) !Segment {
        if (self.phase != .ready) return error.OperationInProgress;
        if (self.execution.closed or self.execution.operation != null)
            return error.InvalidExperiment;
        const actual = try self.execution.outer.observe();
        if (actual != .requested or actual.requested.effect != 0 or !std.mem.eql(
            u8,
            self.execution.outer.program.effects[0].identity,
            service.identity,
        )) return error.InvalidServiceEvent;
        var event = try projection.decode(
            service.Event,
            a,
            try self.execution.outer.bytes(&actual.requested.payload),
        );
        defer event.deinit();
        if (event.value != .projection) return error.InvalidServiceEvent;
        return self.segmentFromProjection(a, event.value.projection);
    }

    fn segmentFromProjection(
        self: *Experiment,
        a: std.mem.Allocator,
        state: data.process_state.State,
    ) !Segment {
        const cut = self.execution.last_cut orelse return error.InvalidServiceEvent;
        if (self.guest_work != cut.guest_work) return error.InvalidExperiment;
        try validateObservation(a, self.observation);
        var canonical = try data.state_image.canonicalize(a, state);
        defer canonical.deinit();
        try data.state_admission.validateAdmitted(
            a,
            self.execution.guest.admitted(),
            canonical.state,
        );
        if (canonical.state.status != cut.status)
            return error.InvalidServiceEvent;
        const checkpoint = try data.state_image.emit(a, canonical.state);
        errdefer a.free(checkpoint);
        return .{
            .allocator = a,
            .checkpoint = checkpoint,
            .observation = try a.dupe(u8, self.observation),
            .guest_work = self.guest_work,
            .stage = self.stage,
        };
    }

    pub fn checkpointOuter(self: *Experiment, a: std.mem.Allocator) ![]u8 {
        const checkpoint = try self.execution.outer.checkpoint(a);
        defer a.free(checkpoint);
        return projection.encode(Record, a, .{
            .runtime = self.execution.artifact_identity,
            .guest = self.execution.guest.admitted().identity(),
            .phase = self.phase,
            .stage = self.stage,
            .guest_work = self.guest_work,
            .checkpoint = checkpoint,
            .initial = self.execution.initial,
            .command = self.execution.command,
            .operation = self.execution.operation,
            .last_cut = self.execution.last_cut,
            .revision = self.execution.revision,
            .guest_revision = self.execution.guest_revision,
            .observation = self.observation,
        });
    }

    pub fn restore(
        a: std.mem.Allocator,
        image: []const u8,
        runtime: *const artifact.Admitted,
        capsule: []const u8,
    ) !Experiment {
        var record = try projection.decode(Record, a, capsule);
        defer record.deinit();
        const encoded = try projection.encode(Record, a, record.value);
        defer a.free(encoded);
        if (!std.mem.eql(u8, encoded, capsule)) return error.NonCanonicalExperiment;
        var prepared = try Prepared.init(a, image);
        defer prepared.deinit();
        try validateRecord(a, record.value, runtime, prepared.core.?.admitted());
        var execution = try restoreExecution(a, &prepared, runtime, record.value);
        errdefer execution.deinit();
        const observation = try a.dupe(u8, record.value.observation);
        errdefer a.free(observation);
        var result: Experiment = .{
            .execution = execution,
            .phase = record.value.phase,
            .stage = record.value.stage,
            .guest_work = record.value.guest_work,
            .observation = observation,
        };
        if (result.phase == .ready) {
            var completed = try result.completedSegment(a);
            completed.deinit();
        }
        return result;
    }
};

fn validateRecord(
    a: std.mem.Allocator,
    record: Record,
    runtime: *const artifact.Admitted,
    guest: *const data.program_image.Admitted,
) !void {
    if (!std.mem.eql(u8, record.contract, "kosmos.runtime-experiment/1") or
        !std.meta.eql(record.runtime, runtime.identity) or
        !std.meta.eql(record.guest, guest.identity())) return error.InvalidExperiment;
    if (runtime.content.value.guest) |bound| {
        if (!std.meta.eql(bound, guest.identity())) return error.GuestIdentityMismatch;
    }
    const expected: ?driver.Operation = switch (record.phase) {
        .initializing => .initialize,
        .advancing => .advance,
        .observing => .observe,
        .projecting => .project,
        .ready => null,
    };
    const has_observation = record.phase == .projecting or record.phase == .ready;
    if (record.operation != expected or has_observation != (record.observation.len != 0))
        return error.InvalidExperiment;
    if (has_observation) try validateObservation(a, record.observation);
    if (record.stage == .initialized and record.guest_work != 0)
        return error.InvalidExperiment;
    if (record.phase == .initializing) {
        if (record.stage != .initialized or record.command.len != 0 or
            record.last_cut != null or record.guest_revision != 0)
            return error.InvalidExperiment;
        return;
    }
    if (record.last_cut == null or
        (record.phase == .advancing and record.stage != .advanced) or record.command.len == 0)
        return error.InvalidExperiment;
    if (record.guest_work != record.last_cut.?.guest_work) return error.InvalidExperiment;
    var command = try projection.decode(service.Command, a, record.command);
    defer command.deinit();
    const tag: std.meta.Tag(service.Command) = switch (record.phase) {
        .advancing => .advance,
        .observing => .observe,
        .projecting, .ready => .project,
        .initializing => unreachable,
    };
    if (std.meta.activeTag(command.value) != tag) return error.InvalidExperiment;
}

fn validateObservation(a: std.mem.Allocator, bytes: []const u8) !void {
    var observation = try projection.decode(Observation, a, bytes);
    defer observation.deinit();
    const canonical = try projection.encode(Observation, a, observation.value);
    defer a.free(canonical);
    if (!std.mem.eql(u8, bytes, canonical)) return error.InvalidExperiment;
}

fn restoreExecution(
    a: std.mem.Allocator,
    prepared: *const Prepared,
    runtime: *const artifact.Admitted,
    record: Record,
) !driver.Driver {
    const guest = try prepared.acquire();
    errdefer guest.release();
    const selected = try runtime.acquire();
    errdefer selected.release();
    const initial = try a.dupe(u8, record.initial);
    errdefer a.free(initial);
    const command = try a.dupe(u8, record.command);
    errdefer a.free(command);
    return .{
        .allocator = a,
        .guest = guest,
        .selected = selected,
        .outer = try base.Session.restore(
            a,
            &selected.executable,
            record.checkpoint,
            runtime.bridge(),
        ),
        .artifact_identity = runtime.identity,
        .core_identity = runtime.program.identity(),
        .initial = initial,
        .command = command,
        .operation = record.operation,
        .last_cut = record.last_cut,
        .revision = record.revision,
        .guest_revision = record.guest_revision,
    };
}
