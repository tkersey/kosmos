// Copyright (c) 2026 World contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const ir = data.activation;
const g = data.graph;
const heap = @import("../interpreter_v2/store.zig");
const bindings = @import("../interpreter_v2/activation_frames.zig");
const runtime_types = @import("../interpreter_v2/runtime_types.zig");
const preparation = @import("../interpreter_v2/prepared.zig");
const Values = @import("../interpreter_v2/values.zig").Values;
const ElementOffsets = @import("../interpreter_v2/element_offsets.zig").ElementOffsets;
const control = @import("control.zig");
const unwind = @import("unwind.zig");
const advance = @import("advance.zig");
const protocol = data.invocation;
pub const Prepared = preparation.Prepared;
pub const Statistics = runtime_types.Statistics;
pub const Observation = runtime_types.Observation;
pub const ExpectedReply = runtime_types.ExpectedReply;
pub const Pending = @import("../base/session.zig").Pending;
pub const Error = runtime_types.Error || bindings.Error || data.activation_ownership.Error ||
    data.program_image.Error || protocol.Error;

pub const Session = struct {
    pub const ExecutionError = Error;
    pub const UnwindOutcome = void;
    allocator: std.mem.Allocator,
    program: ir.Program,
    program_identity: [32]u8,
    prepared: *preparation.Core,
    flow: data.program_image.Analysis,
    uses: data.traits.Facts,
    value_facts: data.admission.SchemaFacts,
    store: heap.Store,
    frames: bindings.Frames,
    offsets: ElementOffsets,
    roots: g.Roots = .{},
    status: g.Status = .active,
    terminal: ?g.NodeRef = null,
    poisoned: bool = false,
    transitions: usize = 0,
    collection_cursors: usize = 8,
    pending_blob_collection: bool = false,
    statistics: ?*Statistics = null,

    pub const Transaction = struct {
        roots: g.Roots,
        status: g.Status,
        terminal: ?g.NodeRef,
        poisoned: bool,
        transitions: usize,
        collection_cursors: usize,
        pending_blob_collection: bool,

        pub fn commit(self: *Transaction, session: *Session) void {
            session.store.commit();
            session.frames.commit();
            self.* = undefined;
        }
        pub fn rollback(self: *Transaction, session: *Session) void {
            session.offsets.clear();
            session.frames.rollback(session.store.nodes.items.len);
            session.store.rollback();
            session.roots = self.roots;
            session.status = self.status;
            session.terminal = self.terminal;
            session.poisoned = self.poisoned;
            session.transitions = self.transitions;
            session.collection_cursors = self.collection_cursors;
            session.pending_blob_collection = self.pending_blob_collection;
            self.* = undefined;
        }
    };

    pub fn begin(self: *Session) Error!Transaction {
        if (self.poisoned) return error.InvalidState;
        try self.store.begin();
        errdefer self.store.rollback();
        try self.frames.begin(self.store.nodes.items.len);
        return .{
            .roots = self.roots,
            .status = self.status,
            .terminal = self.terminal,
            .poisoned = self.poisoned,
            .transitions = self.transitions,
            .collection_cursors = self.collection_cursors,
            .pending_blob_collection = self.pending_blob_collection,
        };
    }

    pub fn start(
        allocator: std.mem.Allocator,
        prepared: *const Prepared,
        arguments: []const u8,
    ) Error!Session {
        var result = try empty(allocator, prepared);
        errdefer result.deinit();
        try result.initialize(arguments);
        return result;
    }

    fn empty(allocator: std.mem.Allocator, prepared: *const Prepared) Error!Session {
        const core = try prepared.acquire();
        errdefer core.release();
        var flow = try core.admitted().analysis(allocator);
        errdefer flow.deinit();
        const frames = try bindings.Frames.init(allocator, flow.facts.pool, core.frameLayouts());
        return .{
            .allocator = allocator,
            .prepared = core,
            .program = core.admitted().program(),
            .program_identity = core.admitted().identity(),
            .flow = flow,
            .uses = core.admitted().traits(),
            .value_facts = core.admitted().schemaFacts(),
            .frames = frames,
            .store = .{ .allocator = allocator },
            .offsets = .{ .allocator = allocator },
        };
    }

    pub fn restore(
        allocator: std.mem.Allocator,
        prepared: *const Prepared,
        checkpoint_bytes: []const u8,
    ) Error!Session {
        var result = try empty(allocator, prepared);
        errdefer result.deinit();
        var incoming = try data.state_image.decodeGraph(allocator, checkpoint_bytes);
        var transferred = false;
        defer if (!transferred) incoming.deinit();
        const state = incoming.state;
        try data.state_admission.validateAdmitted(allocator, result.prepared.admitted(), state);
        try result.store.importOwned(&incoming);
        transferred = true;
        try result.restoreFrames(state);
        result.roots = state.roots;
        if (@backingInt(state.status) < 4) {
            result.status = @fromBackingInt(@intCast(@backingInt(state.status)));
        } else {
            result.terminal = state.roots.exit;
        }
        return result;
    }

    fn restoreFrames(self: *Session, state: data.process_state.State) Error!void {
        for (state.nodes, 0..) |node, id| if (node.activation) |activation| {
            const block = switch (node.record) {
                .control => |saved| saved.block,
                .continuation => |saved| saved.source_block,
                else => return error.InvalidState,
            };
            const function = self.program.blocks[@intCast(block)].function;
            try self.frames.restore(id, function, activation);
        };
    }

    pub fn deinit(self: *Session) void {
        self.offsets.deinit();
        self.frames.deinit();
        self.store.deinit();
        self.flow.deinit();
        self.prepared.release();
        self.* = undefined;
    }

    pub fn setStatistics(self: *Session, statistics: ?*Statistics) void {
        self.statistics = statistics;
        self.store.statistics = if (statistics) |value| &value.storage else null;
    }

    pub fn checkpoint(self: *Session, allocator: std.mem.Allocator) Error![]u8 {
        return (try self.serializeCheckpoint(.{ .allocate = allocator }, null)).bytes.?;
    }

    pub fn serializeCheckpoint(
        self: *Session,
        destination: data.state_image.Destination,
        hasher: ?*std.crypto.hash.sha2.Sha256,
    ) Error!data.state_image.Serialization {
        if (self.poisoned) return error.InvalidState;
        if (self.statistics) |statistics| statistics.state_projections +|= 1;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const nodes = try a.alloc(data.process_state.Node, self.store.nodes.items.len);
        for (self.store.nodes.items, self.store.alive.items, nodes, 0..) |node, alive, *out, id| {
            out.* = if (alive) .{
                .record = node,
                .activation = try self.frames.project(id, a),
            } else .{ .record = .{ .control = .{ .block = std.math.maxInt(u64) } } };
        }
        const public_state = try @import("../interpreter_v2/value_projection.zig").project(
            a,
            self.program.schemas,
            &self.store,
            data.process_state.State{
                .program_identity = self.program_identity,
                .status = try self.publicStatus(),
                .roots = self.roots,
                .nodes = nodes,
                .blobs = self.store.blobs.items,
            },
        );
        var canonical = try data.state_image.canonicalize(a, public_state);
        defer canonical.deinit();
        try data.state_admission.validateAdmitted(a, self.prepared.admitted(), canonical.state);
        return data.state_image.serialize(self.allocator, canonical.state, destination, hasher);
    }

    fn publicStatus(self: *const Session) Error!data.process_state.Status {
        if (self.terminal == null) return @fromBackingInt(@intCast(@backingInt(self.status)));
        return switch ((try self.terminalExit()).reason) {
            .normal => .completed,
            .failure => .failed,
            .cancellation => .cancelled,
            else => error.InvalidState,
        };
    }

    pub fn continuation(
        self: *Session,
        block: p.Id,
        _: anytype,
        saved: g.Control,
    ) Error!g.NodeRef {
        const current = self.roots.current orelse return error.InvalidState;
        const edge = control.nextEdge(self.program.blocks[@intCast(block)].terminator) orelse
            return error.InvalidState;
        const frame = try self.frames.getForUpdate(current.id);
        return control.captureContinuation(self, current, saved, frame, edge);
    }
    pub fn activate(self: *Session, token: g.Capture, after: g.NodeRef) Error!void {
        try @import("resumption.zig").activate(self, token, after);
    }
    pub fn unwindReturnTo(self: *Session, parent: ?g.NodeRef, value: g.Value) Error!?void {
        try control.returnTo(self, parent, value);
        return if (self.terminal != null) {} else null;
    }
    pub fn applyComputation(
        self: *Session,
        value: g.Value,
        supplied: []const g.Value,
        parent: ?g.NodeRef,
        evidence: ?g.NodeRef,
        region: ?g.NodeRef,
    ) Error!void {
        return control.applyComputation(self, value, supplied, parent, evidence, region);
    }
    pub fn resumeContinuation(self: *Session, reference: g.NodeRef, value: g.Value) Error!void {
        return control.resumeContinuation(self, reference, value);
    }
    pub fn takeCapture(self: *Session, value: g.Value) Error!g.Capture {
        return control.takeCapture(self, value);
    }
    pub fn terminalExit(self: *const Session) Error!g.Exit {
        const node = try self.store.get(self.terminal orelse return error.InvalidState);
        return switch (node) {
            .exit => |exit| exit,
            else => error.InvalidState,
        };
    }
    pub fn finishTerminal(self: *Session, reason: g.Exit) Error!void {
        const exit = try self.store.add(.{ .exit = reason });
        self.roots = .{ .exit = exit };
        self.terminal = exit;
    }
    pub fn finishUnwind(self: *Session, reason: g.Exit) Error!void {
        if (reason.reason != .failure and reason.reason != .cancellation) return error.InvalidState;
        if (reason.reason == .cancellation and reason.cancellation == null)
            return error.InvalidState;
        try self.finishTerminal(reason);
    }
    pub fn failCurrent(self: *Session, current: g.NodeRef, value: g.Value) Error!void {
        const saved = (try self.store.get(current)).control;
        const values = try self.frames.discards(current.id);
        defer self.allocator.free(values);
        try unwind.failValues(self, value, saved.parent, values);
    }
    pub fn cancel(self: *Session, reason: data.invocation.Reason) Error!void {
        if (self.poisoned or self.terminal != null) return error.InvalidState;
        if (reason == .text and !std.unicode.utf8ValidateSlice(reason.text))
            return error.InvalidUtf8;
        errdefer self.poisoned = true;
        try unwind.cancel(self, reason);
    }

    fn initialize(self: *Session, input: []const u8) Error!void {
        var temporary = std.heap.ArenaAllocator.init(self.allocator);
        defer temporary.deinit();
        const values = try self.store.importArguments(
            self.prepared.admitted(),
            input,
            temporary.allocator(),
        );
        try control.enter(self, self.program.roots.entry, values, null, null, null);
        try self.store.compactImported();
    }

    pub fn bytes(self: *Session, value: *const g.Value) Error![]const u8 {
        const values: Values = .{
            .allocator = self.allocator,
            .schemas = self.program.schemas,
            .store = &self.store,
        };
        return values.bytes(value);
    }

    pub fn instructionFailure(
        self: *Session,
        instruction: ir.Instruction,
        fault: p.Fault,
    ) Error!g.Value {
        for (instruction.failures) |failure| if (failure.kind == fault) return self.store.literal(
            self.program.schemas,
            self.program.constants[@intCast(failure.value)],
        );
        return error.InvalidProgram;
    }

    pub fn isTerminal(self: *const Session) bool {
        return self.terminal != null;
    }

    pub fn observe(self: *Session) Error!Observation {
        if (self.poisoned) return error.InvalidState;
        if (self.terminal != null) {
            const exit = try self.terminalExit();
            return switch (exit.reason) {
                .normal => |value| .{ .completed = value },
                .failure => |value| .{ .failed = value },
                .cancellation => .{ .cancelled = exit.cancellation orelse
                    return error.InvalidState },
                else => error.InvalidState,
            };
        }
        return switch (self.status) {
            .active, .unwinding => .progressed,
            .yielded => .yielded,
            .parked => blk: {
                const pending = (try self.store.get(self.roots.pending.?)).pending;
                break :blk .{ .requested = .{
                    .effect = pending.effect,
                    .payload = pending.payload,
                } };
            },
        };
    }

    pub fn run(self: *Session, quantum: ?u64) Error!Observation {
        var steps: u64 = 0;
        while (self.terminal == null and (self.status == .active or self.status == .unwinding) and
            (quantum == null or steps < quantum.?))
        {
            const remaining = if (quantum) |limit| @min(8, limit - steps) else 8;
            steps +|= try advance.step(self, @intCast(remaining));
        }
        try advance.finishRetention(self);
        return self.observe();
    }

    pub fn step(self: *Session) Error!void {
        _ = try advance.step(self, 1);
        try advance.finishRetention(self);
    }

    pub fn resumeYield(self: *Session) Error!void {
        if (self.poisoned or self.status != .yielded) return error.InvalidState;
        self.status = .active;
    }

    pub fn pendingRequest(self: *Session, allocator: std.mem.Allocator) Error!Pending {
        return self.pendingBinding(allocator, true);
    }

    pub fn pendingBinding(
        self: *Session,
        allocator: std.mem.Allocator,
        materialize: bool,
    ) Error!Pending {
        if (self.poisoned or self.terminal != null or self.status != .parked)
            return error.InvalidState;
        if (self.statistics) |statistics| statistics.pending_bindings +|= 1;
        const operation = (try self.store.get(self.roots.pending.?)).pending;
        const effect = self.program.effects[@intCast(operation.effect)];
        var hasher = protocol.stateDigestHasher();
        const serialized = try self.serializeCheckpoint(
            if (materialize) .{ .allocate = allocator } else .none,
            &hasher,
        );
        const state: []u8 = serialized.bytes orelse &.{};
        errdefer allocator.free(state);
        const contract = try self.prepared.contract(operation.effect);
        const payload_schema = try allocator.dupe(u8, contract.payload);
        errdefer allocator.free(payload_schema);
        const resume_schema = try allocator.dupe(u8, contract.resume_value);
        errdefer allocator.free(resume_schema);
        const name = try allocator.dupe(u8, effect.identity);
        errdefer allocator.free(name);
        const payload = try allocator.dupe(u8, try self.bytes(&operation.payload));
        errdefer allocator.free(payload);
        return .{ .allocator = allocator, .state = state, .request = try protocol.request(.{
            .program_identity = self.program_identity,
            .pending_state_digest = hasher.finalResult(),
            .effect = operation.effect,
            .semantic_identity = name,
            .payload_schema = payload_schema,
            .resume_schema = resume_schema,
            .payload = payload,
        }) };
    }

    pub fn answer(self: *Session, input: []const u8) Error!void {
        var response = try protocol.decode(protocol.Result, self.allocator, input);
        defer response.deinit();
        var expected = try self.pendingBinding(self.allocator, false);
        defer expected.deinit();
        try self.admitReply(response.value, ExpectedReply.fromRequest(expected.request));
    }

    pub fn answerExpected(self: *Session, input: []const u8, expected: ExpectedReply) Error!void {
        var response = try protocol.decode(protocol.Result, self.allocator, input);
        defer response.deinit();
        try self.admitReply(response.value, expected);
    }

    fn admitReply(self: *Session, response: protocol.Result, expected: ExpectedReply) Error!void {
        if (self.statistics) |statistics| statistics.expected_binding_checks +|= 1;
        if (self.poisoned or self.terminal != null or self.status != .parked)
            return error.InvalidState;
        const pending = (try self.store.get(self.roots.pending.?)).pending;
        if (pending.effect != expected.effect) return error.InvalidResult;
        if (!std.mem.eql(u8, &expected.identity, &response.request_identity))
            return error.InvalidResult;
        const literal: p.Literal = .{
            .schema = self.program.effects[@intCast(pending.effect)].result,
            .bytes = response.value,
        };
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        try data.admission.value(
            scratch.allocator(),
            self.program.schemas,
            self.value_facts,
            literal,
        );
        errdefer self.poisoned = true;
        const value = try self.store.literal(self.program.schemas, literal);
        try control.resumeContinuation(self, pending.continuation, value);
        self.roots.pending = null;
        self.status = .active;
    }
};
