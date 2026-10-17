//! Public guest-session framing. Every guest transition runs in the portable
//! service; native work here is ownership, wire admission and observation data.
const std = @import("std");
const data = @import("horos_data");
const artifact = @import("artifact.zig");
const service = @import("service.zig");
const projection = @import("projection.zig");
const driver = @import("driver.zig");
const realization = @import("realization.zig");
const g = data.graph;
const GuestPrepared = @import("../interpreter_v2/prepared.zig").Prepared;
pub const ExpectedReply = driver.ExpectedReply;
pub const Pending = @import("../base/session.zig").Pending;
pub const Workspace = @import("../interpreter_v2/arena.zig").Arena;
pub const AllocationBudget = @import("../interpreter_v2/allocation_budget.zig").Budget;
pub const invocation = @import("../interpreter_v2/invocation.zig").For(@This());
pub const resident_types = @import("../interpreter_v2/resident.zig").For(@This());
pub const Resident = resident_types.Resident;
pub const Observation = union(enum) {
    progressed,
    yielded,
    requested: struct { effect: data.program.Id, payload: g.Value },
    completed: g.Value,
    failed: g.Value,
    cancelled: data.invocation.Reason,
};

fn Errors(comptime function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.error_set;
}
pub const Error = Errors(driver.Driver.start) || Errors(driver.Driver.pump) || Errors(driver.Driver.reply) || Errors(driver.Driver.checkpoint) ||
    Errors(driver.Driver.begin) || Errors(realization.guestCut) || Errors(artifact.Admitted.init) || error{InvalidState};

/// Repeated sessions share both admitted guest metadata and the evaluator's
/// prepared code. Session allocation never recompiles or re-admits that code.
pub const Prepared = struct {
    guest: GuestPrepared,
    runtime: artifact.Admitted,
    pub fn init(a: std.mem.Allocator, image: []const u8) Error!Prepared {
        var runtime = try builtin(a);
        defer runtime.deinit();
        return initWithRuntime(a, image, &runtime);
    }
    pub fn initWithRuntime(a: std.mem.Allocator, image: []const u8, selected: *const artifact.Admitted) Error!Prepared {
        var runtime = try selected.clone();
        errdefer runtime.deinit();
        var guest = try GuestPrepared.init(a, image);
        errdefer guest.deinit();
        if (runtime.content.value.guest) |identity| if (!std.mem.eql(u8, &identity, &guest.core.?.admitted().identity())) return error.GuestIdentityMismatch;
        return .{ .guest = guest, .runtime = runtime };
    }
    pub fn acquire(self: *const Prepared) Error!*@import("../interpreter_v2/prepared.zig").Core {
        return self.guest.acquire();
    }
    pub fn clone(self: *const Prepared) Error!Prepared {
        var guest = try self.guest.clone();
        errdefer guest.deinit();
        return .{ .guest = guest, .runtime = try self.runtime.clone() };
    }
    pub fn deinit(self: *Prepared) void {
        self.guest.deinit();
        self.runtime.deinit();
    }
    pub fn storageBytes(self: *const Prepared) Error!usize {
        return try self.guest.storageBytes() + try (self.runtime.core orelse return error.InvalidState).storageBytes();
    }
};

const View = struct {
    event: projection.Owned(service.Event),
    arena: std.heap.ArenaAllocator,
    blobs: std.ArrayList([]const u8) = .empty,
    observation: Observation = undefined,
    exit: ?g.Exit = null,

    fn makeValue(self: *View, schema: data.program.Id, bytes: []const u8) Error!g.Value {
        const id = self.blobs.items.len;
        try self.blobs.append(self.arena.allocator(), bytes);
        return .{ .schema = schema, .body = .{ .blob = .{ .id = id } } };
    }
    fn init(a: std.mem.Allocator, event: projection.Owned(service.Event), admitted: *const data.program_image.Admitted) Error!View {
        var self: View = .{ .event = event, .arena = .init(a) };
        errdefer self.arena.deinit();
        if (event.value != .observation) return error.InvalidServiceEvent;
        const program = admitted.program();
        const failure = program.roots.failure;
        const result = program.functions[@intCast(program.roots.entry)].result;
        self.observation = switch (event.value.observation) {
            .progressed => .progressed,
            .yielded => .yielded,
            .requested => |request| request: {
                if (request.effect >= program.effects.len or !program.effects[@intCast(request.effect)].external) return error.InvalidServiceEvent;
                const schema = program.effects[@intCast(request.effect)].payload;
                try admitValue(a, admitted, schema, request.payload);
                break :request .{ .requested = .{ .effect = request.effect, .payload = try self.makeValue(schema, request.payload) } };
            },
            .completed => |bytes| complete: {
                try admitValue(a, admitted, result, bytes);
                const value = try self.makeValue(result, bytes);
                self.exit = .{ .reason = .{ .normal = value } };
                break :complete .{ .completed = value };
            },
            .failed => |failed| failed: {
                try admitValue(a, admitted, failure, failed.value);
                const value = try self.makeValue(failure, failed.value);
                const failures = try self.arena.allocator().alloc(g.Value, failed.cleanup_failures.len);
                for (failures, failed.cleanup_failures) |*out, bytes| {
                    try admitValue(a, admitted, failure, bytes);
                    out.* = try self.makeValue(failure, bytes);
                }
                self.exit = .{ .reason = .{ .failure = value }, .cleanup_failures = failures, .cancellation = failed.cancellation };
                break :failed .{ .failed = value };
            },
            .cancelled => |cancelled| cancelled: {
                const failures = try self.arena.allocator().alloc(g.Value, cancelled.cleanup_failures.len);
                for (failures, cancelled.cleanup_failures) |*out, bytes| {
                    try admitValue(a, admitted, failure, bytes);
                    out.* = try self.makeValue(failure, bytes);
                }
                self.exit = .{ .reason = .cancellation, .cleanup_failures = failures, .cancellation = cancelled.reason };
                break :cancelled .{ .cancelled = cancelled.reason };
            },
        };
        return self;
    }
    fn deinit(self: *View) void {
        self.event.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
    fn admitValue(a: std.mem.Allocator, admitted: *const data.program_image.Admitted, schema: data.program.Id, bytes: []const u8) Error!void {
        try data.admission.value(a, admitted.program().schemas, admitted.schemaFacts(), .{ .schema = schema, .bytes = bytes });
    }
};

pub const Session = struct {
    pub const ExecutionError = Error;
    allocator: std.mem.Allocator,
    program: data.activation.Program,
    program_identity: [32]u8,
    prepared: *@import("../interpreter_v2/prepared.zig").Core,
    driver: driver.Driver,
    view: ?View = null,
    transitions: usize = 0,
    statistics: ?*@import("../interpreter_v2/runtime_types.zig").Statistics = null,

    pub const Transaction = struct {
        driver: driver.Driver.Transaction,
        view: ?View,
        transitions: usize,
        pub fn commit(self: *Transaction, session: *Session) void {
            self.driver.commit(&session.driver);
            if (self.view) |*view| view.deinit();
            self.* = undefined;
        }
        pub fn rollback(self: *Transaction, session: *Session) void {
            self.driver.rollback(&session.driver);
            session.clearView();
            session.view = self.view;
            session.transitions = self.transitions;
            self.* = undefined;
        }
    };
    pub fn begin(self: *Session) Error!Transaction {
        const transaction = try self.driver.begin();
        const view = self.view;
        self.view = null;
        return .{ .driver = transaction, .view = view, .transitions = self.transitions };
    }

    pub fn initImage(a: std.mem.Allocator, image: []const u8, arguments: []const u8) Error!Session {
        var prepared = try Prepared.init(a, image);
        defer prepared.deinit();
        return start(a, &prepared, arguments);
    }
    pub fn start(a: std.mem.Allocator, prepared: *const Prepared, arguments: []const u8) Error!Session {
        return startSelected(a, prepared, &prepared.runtime, .{ .arguments = arguments });
    }
    pub fn startSelected(a: std.mem.Allocator, prepared: *const Prepared, selected: *const artifact.Admitted, initial: service.Initial) Error!Session {
        var execution = try driver.Driver.start(a, &prepared.guest, selected, initial);
        errdefer execution.deinit();
        var first = try execution.pump(null);
        if (first != .event) return error.InvalidServiceEvent;
        defer first.event.deinit();
        return fromDriver(execution);
    }
    pub fn fromDriver(execution: driver.Driver) Session {
        return .{ .allocator = execution.allocator, .program = execution.guest.admitted().program(), .program_identity = execution.guest.admitted().identity(), .prepared = execution.guest, .driver = execution };
    }
    pub fn restoreImage(a: std.mem.Allocator, image: []const u8, checkpoint_bytes: []const u8) Error!Session {
        var prepared = try Prepared.init(a, image);
        defer prepared.deinit();
        return restore(a, &prepared, checkpoint_bytes);
    }
    pub fn restore(a: std.mem.Allocator, prepared: *const Prepared, checkpoint_bytes: []const u8) Error!Session {
        var state = try data.state_image.decodeGraph(a, checkpoint_bytes);
        defer state.deinit();
        return startSelected(a, prepared, &prepared.runtime, .{ .state = state.state });
    }
    pub fn deinit(self: *Session) void {
        self.clearView();
        self.driver.deinit();
        self.* = undefined;
    }
    pub fn setStatistics(self: *Session, statistics: ?*@import("../interpreter_v2/runtime_types.zig").Statistics) void {
        self.statistics = statistics;
        self.driver.statistics = statistics;
        self.attachCounters();
        self.driver.outer.store.statistics = if (statistics) |value| &value.storage else null;
    }
    fn attachCounters(self: *Session) void {
        self.driver.outer.entry_counter = if (self.statistics) |statistics| .{ .functions = self.driver.selected.content.value.template_entries, .count = &statistics.multi_templates } else null;
        self.driver.outer.return_counter = if (self.statistics) |statistics| .{ .functions = self.driver.selected.content.value.branch_returns, .count = &statistics.branch_activations } else null;
    }
    fn clearView(self: *Session) void {
        if (self.view) |*view| view.deinit();
        self.view = null;
    }
    pub fn isTerminal(self: *const Session) bool {
        const cut = self.driver.last_cut orelse return false;
        return cut.status == .completed or cut.status == .failed or cut.status == .cancelled;
    }
    pub fn observe(self: *Session) Error!Observation {
        if (self.driver.operation != null) return error.GuestCutUnavailable;
        const cut = self.driver.last_cut orelse return error.InvalidState;
        switch (cut.status) {
            .active, .unwinding => return .progressed,
            else => {},
        }
        if (self.view == null) {
            var event = try self.driver.exchange(.observe);
            errdefer event.deinit();
            self.view = try View.init(self.allocator, event, self.prepared.admitted());
        }
        return self.view.?.observation;
    }
    pub fn terminalExit(self: *Session) Error!g.Exit {
        _ = try self.observe();
        return if (self.view) |view| view.exit orelse error.InvalidState else error.InvalidState;
    }
    pub fn bytes(self: *Session, value: *const g.Value) Error![]const u8 {
        if (value.schema >= self.program.schemas.len) return error.InvalidValue;
        return switch (value.body) {
            .scalar => |*scalar| scalar[0 .. data.scalar.width(self.program.schemas[@intCast(value.schema)]) orelse return error.InvalidValue],
            .blob => |blob| if (self.view) |view| if (blob.id < view.blobs.items.len) view.blobs.items[@intCast(blob.id)] else error.InvalidValue else error.InvalidValue,
            else => error.InvalidValue,
        };
    }
    fn control(self: *Session, command: service.Control, quantum: u64) Error!void {
        if (self.isTerminal()) return error.InvalidState;
        self.attachCounters();
        const before = self.driver.outer.transitions;
        defer if (self.statistics) |statistics| {
            statistics.base_transitions +|= self.driver.outer.transitions -% before;
        };
        var event = try self.driver.exchange(.{ .advance = .{ .control = command, .quantum = quantum } });
        defer event.deinit();
        self.clearView();
        const work = event.value.cut.guest_work;
        self.transitions +%= @intCast(work);
        if (self.statistics) |statistics| statistics.transitions +|= work;
    }
    /// Select once, then use pump to make bounded outer progress.
    pub fn submitAdvance(self: *Session, command: data.invocation.Control, quantum: u64, expected: ?ExpectedReply) Error!void {
        if (self.isTerminal()) return error.InvalidState;
        if (command == .reply) {
            if (expected) |binding| try self.driver.replyExpected(command.reply, binding, quantum) else try self.driver.reply(command.reply, quantum);
        } else {
            const control_value: service.Control = switch (command) {
                .none => .none,
                .resume_yield => .resume_yield,
                .cancel => |reason| .{ .cancel = reason },
                .reply => unreachable,
            };
            if (command == .resume_yield and self.driver.last_cut.?.status != .yielded) return error.InvalidState;
            if (command == .cancel and command.cancel == .text and !std.unicode.utf8ValidateSlice(command.cancel.text)) return error.InvalidUtf8;
            try self.driver.submit(.{ .advance = .{ .control = control_value, .quantum = quantum } });
        }
    }
    pub const Pump = driver.Pump;
    /// Last established cut only. Reading never advances, collects or records
    /// additional guest events. Disabled source hooks return null.
    pub fn trace(self: *const Session) ?service.instrumentation.Output {
        const cut = self.driver.last_cut orelse return null;
        return .{ .source = self.driver.selected.content.value.manifest.source, .realization = self.driver.artifact_identity, .guest = self.driver.guest.admitted().identity(), .guest_revision = self.driver.guest_revision, .trace = cut.trace orelse return null };
    }
    /// Continue any admitted operation, including one restored before its first
    /// cut. The caller owns observation/projection output until Pump.deinit.
    pub fn pump(self: *Session, quantum: u64) Error!Pump {
        self.attachCounters();
        const before = self.driver.outer.transitions;
        defer if (self.statistics) |statistics| {
            statistics.base_transitions +|= self.driver.outer.transitions -% before;
        };
        const result = try self.driver.pump(quantum);
        if (result == .event and result.event.value == .cut) {
            self.clearView();
            self.transitions +%= @intCast(result.event.value.cut.guest_work);
            if (self.statistics) |statistics| statistics.transitions +|= result.event.value.cut.guest_work;
        }
        return result;
    }
    pub fn run(self: *Session, quantum: ?u64) Error!Observation {
        if (self.isTerminal()) return self.observe();
        if (quantum == 0) return self.observe();
        while (true) {
            try self.control(.none, quantum orelse std.math.maxInt(u64));
            const observed = try self.observe();
            if (quantum != null or observed != .progressed) return observed;
        }
    }
    pub fn step(self: *Session) Error!void {
        const observation = try self.observe();
        if (observation != .progressed) return error.InvalidState;
        _ = try self.run(1);
    }
    pub fn cancel(self: *Session, reason: data.invocation.Reason) Error!void {
        if (reason == .text and !std.unicode.utf8ValidateSlice(reason.text)) return error.InvalidUtf8;
        try self.control(.{ .cancel = reason }, 0);
    }
    pub fn resumeYield(self: *Session) Error!void {
        if (try self.observe() != .yielded) return error.InvalidState;
        try self.control(.resume_yield, 0);
    }
    pub fn answer(self: *Session, input: []const u8) Error!void {
        try self.driver.reply(input, 0);
        var outcome = try self.driver.pump(null);
        if (outcome != .event) return error.InvalidServiceEvent;
        outcome.event.deinit();
        self.clearView();
    }
    pub fn answerExpected(self: *Session, input: []const u8, expected: ExpectedReply) Error!void {
        try self.driver.replyExpected(input, expected, 0);
        var outcome = try self.driver.pump(null);
        defer outcome.deinit();
        if (outcome != .event or outcome.event.value != .cut) return error.InvalidServiceEvent;
        self.clearView();
    }
    pub fn pendingBinding(self: *Session, a: std.mem.Allocator, materialize: bool) Error!Pending {
        return self.driver.pendingBinding(a, materialize);
    }
    pub fn pendingRequest(self: *Session, a: std.mem.Allocator) Error!Pending {
        return self.pendingBinding(a, true);
    }
    pub fn checkpoint(self: *Session, a: std.mem.Allocator) Error![]u8 {
        return (try self.serializeCheckpoint(.{ .allocate = a }, null)).bytes.?;
    }
    pub fn serializeCheckpoint(self: *Session, destination: data.state_image.Destination, hasher: ?*std.crypto.hash.sha2.Sha256) Error!data.state_image.Serialization {
        if (self.driver.operation != null) return error.GuestCutUnavailable;
        if (self.statistics) |statistics| statistics.state_projections +|= 1;
        var state = try realization.guestCut(self.allocator, &self.driver.outer, self.driver.selected, self.driver.guest.admitted());
        defer state.deinit();
        return data.state_image.serialize(self.allocator, state.state, destination, hasher);
    }
};

fn builtin(a: std.mem.Allocator) Error!artifact.Admitted {
    const bytes = @import("packaged_runtime").bytes;
    return artifact.Admitted.init(a, bytes, artifact.digest(bytes));
}
