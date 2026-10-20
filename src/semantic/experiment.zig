const std = @import("std");
const data = @import("horos_data");
const artifact = @import("artifact.zig");
const service = @import("service.zig");
const projection = @import("projection.zig");
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
        try self.execution.submit(.{ .advance = .{
            .control = control,
            .quantum = guest_quantum,
        } });
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
                    @import("observe.zig").Observation,
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
        const a = self.execution.allocator;
        var canonical = try data.state_image.canonicalize(a, event.projection);
        defer canonical.deinit();
        try data.state_admission.validateAdmitted(
            a,
            self.execution.guest.admitted(),
            canonical.state,
        );
        if (canonical.state.status != self.execution.last_cut.?.status)
            return error.InvalidServiceEvent;
        const checkpoint = try data.state_image.emit(a, canonical.state);
        const result: Segment = .{
            .allocator = a,
            .checkpoint = checkpoint,
            .observation = self.observation,
            .guest_work = self.guest_work,
            .stage = self.stage,
        };
        self.observation = &.{};
        self.phase = .ready;
        return .{ .complete = result };
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
        try validateRecord(record.value, runtime, prepared.core.?.admitted());
        var execution = try restoreExecution(a, &prepared, runtime, record.value);
        errdefer execution.deinit();
        return .{
            .execution = execution,
            .phase = record.value.phase,
            .stage = record.value.stage,
            .guest_work = record.value.guest_work,
            .observation = try a.dupe(u8, record.value.observation),
        };
    }
};

fn validateRecord(
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
    if (record.operation != expected or
        (record.phase == .projecting) != (record.observation.len != 0))
        return error.InvalidExperiment;
    if (record.phase == .initializing and record.stage != .initialized)
        return error.InvalidExperiment;
    if (record.phase != .initializing and record.last_cut == null)
        return error.InvalidExperiment;
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
