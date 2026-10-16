//! Host framing for the authored service. This module executes no guest
//! instruction, handler, resumption, clone, or cleanup algorithm.
const std = @import("std");
const data = @import("horos_data");
const base = @import("../base/session.zig");
const preparation = @import("../interpreter_v2/prepared.zig");
const artifact = @import("artifact.zig");
const service = @import("service.zig");
const projection = @import("projection.zig");
const protocol = data.invocation;

pub const Operation = enum { initialize, advance, observe, project, finish };
pub const Pump = union(enum) { suspended, event: projection.Owned(service.Event), closed };

pub const Driver = struct {
    allocator: std.mem.Allocator,
    guest: *preparation.Core,
    selected: *artifact.Core,
    outer: base.Session,
    artifact_identity: artifact.Digest,
    core_identity: artifact.Digest,
    operation: ?Operation = .initialize,
    /// Retained until the next command, so an outer publication can name the
    /// exact operation whose control has already been consumed once.
    command: []u8 = &.{},
    initial: []u8,
    last_cut: ?service.Cut = null,
    revision: u64 = 0,
    guest_revision: u64 = 0,
    closed: bool = false,
    transaction_active: bool = false,

    pub const Transaction = struct {
        outer: base.Session.Transaction,
        operation: ?Operation,
        command: []u8,
        last_cut: ?service.Cut,
        revision: u64,
        guest_revision: u64,
        closed: bool,

        pub fn commit(self: *Transaction, owner: *Driver) void {
            self.outer.commit(&owner.outer);
            owner.allocator.free(self.command);
            owner.transaction_active = false;
            self.* = undefined;
        }
        pub fn rollback(self: *Transaction, owner: *Driver) void {
            self.outer.rollback(&owner.outer);
            owner.allocator.free(owner.command);
            owner.command = self.command;
            owner.operation = self.operation;
            owner.last_cut = self.last_cut;
            owner.revision = self.revision;
            owner.guest_revision = self.guest_revision;
            owner.closed = self.closed;
            owner.transaction_active = false;
            self.* = undefined;
        }
    };

    /// The enclosing publication fence can include several private exchanges
    /// and output allocation. Journals retain only changed base storage.
    pub fn begin(self: *Driver) !Transaction {
        if (self.transaction_active) return error.InvalidState;
        const command = try self.allocator.dupe(u8, self.command);
        errdefer self.allocator.free(command);
        const outer = try self.outer.begin();
        self.transaction_active = true;
        return .{ .outer = outer, .operation = self.operation, .command = command, .last_cut = self.last_cut, .revision = self.revision, .guest_revision = self.guest_revision, .closed = self.closed };
    }

    pub fn start(a: std.mem.Allocator, guest: *const preparation.Prepared, selected: *const artifact.Admitted, initial: service.Initial) !Driver {
        const lease = try guest.acquire();
        errdefer lease.release();
        const runtime = try selected.acquire();
        errdefer runtime.release();
        if (selected.content.value.guest) |identity| if (!std.mem.eql(u8, &identity, &lease.admitted().identity())) return error.GuestIdentityMismatch;
        try admitInitial(a, lease.admitted(), initial);
        const program = try projection.programBytes(a, lease.admitted());
        defer a.free(program);
        const input = try projection.encode(service.Initial, a, initial);
        errdefer a.free(input);
        const arguments = if (selected.content.value.guest == null) try std.mem.concat(a, u8, &.{ program, input }) else try a.dupe(u8, input);
        defer a.free(arguments);
        return .{
            .allocator = a,
            .guest = lease,
            .selected = runtime,
            .initial = input,
            .outer = try base.Session.start(a, &runtime.executable, arguments, selected.bridge()),
            .artifact_identity = selected.identity,
            .core_identity = selected.program.identity(),
        };
    }
    pub fn deinit(self: *Driver) void {
        self.allocator.free(self.command);
        self.allocator.free(self.initial);
        self.outer.deinit();
        self.guest.release();
        self.selected.release();
        self.* = undefined;
    }

    /// Submit exactly once. Pumping after suspension never re-applies this
    /// command. A failed submission leaves the previous event retryable.
    pub fn submit(self: *Driver, command: service.Command) !void {
        if (self.closed or self.operation != null) return error.OperationInProgress;
        const revision = try std.math.add(u64, self.revision, 1);
        const bytes = try projection.encode(service.Command, self.allocator, command);
        errdefer self.allocator.free(bytes);
        var transaction: ?base.Session.Transaction = if (self.transaction_active) null else try self.outer.begin();
        errdefer if (transaction) |*active| active.rollback(&self.outer);
        try self.outer.replyBridge(self.core_identity, 0, bytes);
        if (transaction) |*active| active.commit(&self.outer);
        self.allocator.free(self.command);
        self.command = bytes;
        self.operation = switch (command) {
            .advance => .advance,
            .observe => .observe,
            .project => .project,
            .finish => .finish,
        };
        self.revision = revision;
    }

    /// The budget counts base transitions. It is never reported as guest work.
    pub fn pump(self: *Driver, budget: ?u64) !Pump {
        if (self.closed) return .closed;
        const operation = self.operation orelse return error.NoOperation;
        const revision = try std.math.add(u64, self.revision, 1);
        var guest_revision = self.guest_revision;
        if (operation == .advance) {
            var command = try projection.decode(service.Command, self.allocator, self.command);
            defer command.deinit();
            if (command.value.advance.quantum != 0 or command.value.advance.control != .none)
                guest_revision = try std.math.add(u64, guest_revision, 1);
        }
        const result = try self.outer.run(budget);
        self.revision = revision;
        switch (result) {
            .progressed => return .suspended,
            .completed => {
                if (operation != .finish) return error.RuntimeFailure;
                self.operation = null;
                self.closed = true;
                return .closed;
            },
            .failed, .yielded => return error.RuntimeFailure,
            .requested => |request| {
                if (request.effect != 0 or !std.mem.eql(u8, self.outer.program.effects[0].identity, service.identity)) return error.InvalidBridge;
                var event = try projection.decode(service.Event, self.allocator, try self.outer.bytes(&request.payload));
                errdefer event.deinit();
                switch (operation) {
                    .initialize, .advance => {
                        if (event.value != .cut) return error.InvalidServiceEvent;
                        const hooks = self.selected.content.value.hooks;
                        if (hooks.enabled() != (event.value.cut.trace != null)) return error.InvalidServiceEvent;
                        if (event.value.cut.trace) |trace| {
                            if (hooks.control != (trace.control != null) or hooks.storage != (trace.storage != null)) return error.InvalidServiceEvent;
                        }
                        if (operation == .initialize and event.value.cut.guest_work != 0) return error.InvalidServiceEvent;
                        if (operation == .advance) {
                            var command = try projection.decode(service.Command, self.allocator, self.command);
                            defer command.deinit();
                            if (event.value.cut.guest_work > command.value.advance.quantum) return error.InvalidServiceEvent;
                            if (event.value.cut.guest_work != 0 or command.value.advance.control != .none)
                                self.guest_revision = guest_revision;
                        }
                        self.last_cut = event.value.cut;
                    },
                    .observe => if (event.value != .observation) return error.InvalidServiceEvent,
                    .project => if (event.value != .projection) return error.InvalidServiceEvent,
                    .finish => return error.InvalidServiceEvent,
                }
                self.operation = null;
                return .{ .event = event };
            },
        }
    }

    pub fn exchange(self: *Driver, command: service.Command) !projection.Owned(service.Event) {
        try self.submit(command);
        return switch (try self.pump(null)) {
            .event => |event| event,
            else => error.InvalidServiceEvent,
        };
    }

    /// Demanded reconstruction, never a complete shadow on each guest step.
    pub fn checkpoint(self: *Driver, a: std.mem.Allocator) ![]u8 {
        var canonical = try self.projectState();
        defer canonical.deinit();
        return data.state_image.emitWith(self.allocator, canonical.state, a);
    }

    fn projectState(self: *Driver) !data.state_image.Owned {
        if (self.operation != null) return error.GuestCutUnavailable;
        return @import("realization.zig").guestCut(self.allocator, &self.outer, self.selected, self.guest.admitted());
    }

    pub fn pendingBinding(self: *Driver, a: std.mem.Allocator, materialize: bool) !base.Pending {
        var projected = try self.projectState();
        defer projected.deinit();
        const actual = projected.state;
        if (actual.status != .parked) return error.InvalidState;
        const reference = actual.roots.pending orelse return error.InvalidState;
        const pending = actual.nodes[@intCast(reference.id)].record.pending;
        const program = self.guest.admitted().program();
        const effect = program.effects[@intCast(pending.effect)];
        // Program-relative admission has checked this external value. Native
        // code only publishes its existing canonical scalar/blob encoding.
        const payload_bytes: []const u8 = switch (pending.payload.body) {
            .scalar => |*bytes| bytes[0..data.scalar.width(program.schemas[@intCast(effect.payload)]).?],
            .blob => |blob| actual.blobs[@intCast(blob.id)].bytes,
            else => return error.InvalidServiceEvent,
        };
        var hasher = protocol.stateDigestHasher();
        const serialized = try data.state_image.serialize(self.allocator, actual, if (materialize) .{ .allocate = a } else .none, &hasher);
        const state: []u8 = serialized.bytes orelse &.{};
        errdefer a.free(state);
        const contract = try self.guest.contract(pending.effect);
        const name = try a.dupe(u8, effect.identity);
        errdefer a.free(name);
        const payload_schema = try a.dupe(u8, contract.payload);
        errdefer a.free(payload_schema);
        const resume_schema = try a.dupe(u8, contract.resume_value);
        errdefer a.free(resume_schema);
        const payload = try a.dupe(u8, payload_bytes);
        errdefer a.free(payload);
        const request = try protocol.request(.{
            .program_identity = self.guest.admitted().identity(),
            .pending_state_digest = hasher.finalResult(),
            .effect = pending.effect,
            .semantic_identity = name,
            .payload_schema = payload_schema,
            .resume_schema = resume_schema,
            .payload = payload,
        });
        return .{ .allocator = a, .state = state, .request = request };
    }

    /// ERS3 is checked against the real guest request and result schema before
    /// the value enters the private source service. The bridge has no grant.
    pub fn reply(self: *Driver, bytes: []const u8, quantum: u64) !void {
        if (self.operation != null) return error.OperationInProgress;
        var pending = try self.pendingBinding(self.allocator, false);
        defer pending.deinit();
        var response = try protocol.decode(protocol.Result, self.allocator, bytes);
        defer response.deinit();
        if (!std.mem.eql(u8, &response.value.request_identity, &pending.request.request_identity)) return error.InvalidResult;
        const admitted = self.guest.admitted();
        const program = admitted.program();
        const effect = program.effects[@intCast(pending.request.binding.effect)];
        try data.admission.value(self.allocator, program.schemas, admitted.schemaFacts(), .{ .schema = effect.result, .bytes = response.value.value });
        try self.submit(.{ .advance = .{ .control = .{ .answer = response.value.value }, .quantum = quantum } });
    }
};

pub fn admitInitial(a: std.mem.Allocator, admitted: *const data.program_image.Admitted, initial: service.Initial) !void {
    switch (initial) {
        .arguments => |arguments| try admitArguments(a, admitted, arguments),
        .state => |state| try data.state_admission.validateAdmitted(a, admitted, state),
    }
}

fn admitArguments(a: std.mem.Allocator, admitted: *const data.program_image.Admitted, bytes: []const u8) !void {
    const program = admitted.program();
    const entry = program.functions[@intCast(program.roots.entry)];
    var reader: data.wire.Reader = .{ .input = bytes };
    for (entry.inputs) |slot| _ = try data.admission.readValue(a, program.schemas, admitted.schemaFacts(), entry.layout.slots[@intCast(slot)], &reader);
    try reader.finish();
}
