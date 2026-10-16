//! Restricted BPI3 executor. Only ordinary data, direct calls, and the
//! explicitly bound environmental bridge are executable here. Guest control
//! is data consumed by the authored core, never dispatched to native modules.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const ir = data.activation;
const g = data.graph;
const heap = @import("../interpreter_v2/store.zig");
const bindings = @import("../interpreter_v2/activation_frames.zig");
const read = @import("../interpreter_v2/operands.zig").read;
const profile = @import("profile.zig");
const protocol = data.invocation;
pub const Prepared = @import("../interpreter_v2/prepared.zig").Prepared;
pub const Error = @import("../interpreter_v2/runtime_types.zig").Error || bindings.Error || data.activation_ownership.Error || profile.Error;
pub const Observation = union(enum) {
    progressed,
    yielded,
    requested: struct { effect: p.Id, payload: g.Value },
    completed: g.Value,
    failed: g.Value,
};
pub const Pending = struct {
    allocator: std.mem.Allocator,
    state: []u8,
    request: protocol.Request,
    pub fn deinit(self: *Pending) void {
        self.allocator.free(self.state);
        self.allocator.free(self.request.binding.semantic_identity);
        self.allocator.free(self.request.binding.payload_schema);
        self.allocator.free(self.request.binding.resume_schema);
        self.allocator.free(self.request.binding.payload);
        self.* = undefined;
    }
};
pub const Session = struct {
    pub const ExecutionError = Error;
    allocator: std.mem.Allocator,
    program: ir.Program,
    program_identity: [32]u8,
    prepared: *@import("../interpreter_v2/prepared.zig").Core,
    flow: data.program_image.Analysis,
    uses: data.traits.Facts,
    value_facts: data.admission.SchemaFacts,
    store: heap.Store,
    frames: bindings.Frames,
    roots: g.Roots = .{},
    status: g.Status = .active,
    terminal: ?g.NodeRef = null,
    poisoned: bool = false,
    transitions: usize = 0,
    statistics: ?*@import("../interpreter_v2/runtime_types.zig").Statistics = null,
    /// Optional observation of completed ordinary function returns. This has no
    /// effect on control, values or grants and is never serialized.
    return_counter: ?struct { functions: []const p.Id, count: *u64 } = null,

    pub const Transaction = struct {
        roots: g.Roots,
        status: g.Status,
        terminal: ?g.NodeRef,
        poisoned: bool,
        transitions: usize,

        pub fn commit(self: *Transaction, session: *Session) void {
            session.store.commit();
            session.frames.commit();
            self.* = undefined;
        }
        pub fn rollback(self: *Transaction, session: *Session) void {
            session.frames.rollback(session.store.nodes.items.len);
            session.store.rollback();
            session.roots = self.roots;
            session.status = self.status;
            session.terminal = self.terminal;
            session.poisoned = self.poisoned;
            session.transitions = self.transitions;
            self.* = undefined;
        }
    };

    pub fn begin(self: *Session) Error!Transaction {
        if (self.poisoned) return error.InvalidState;
        try self.store.begin();
        errdefer self.store.rollback();
        try self.frames.begin(self.store.nodes.items.len);
        return .{ .roots = self.roots, .status = self.status, .terminal = self.terminal, .poisoned = self.poisoned, .transitions = self.transitions };
    }

    pub fn observe(self: *Session) Error!Observation {
        if (self.poisoned) return error.InvalidState;
        if (self.terminal != null) return switch ((try self.terminalExit()).reason) {
            .normal => |value| .{ .completed = value },
            .failure => |value| .{ .failed = value },
            else => error.InvalidState,
        };
        return switch (self.status) {
            .active => .progressed,
            .yielded => .yielded,
            .parked => blk: {
                const pending = (try self.store.get(self.roots.pending orelse return error.InvalidState)).pending;
                break :blk .{ .requested = .{ .effect = pending.effect, .payload = pending.payload } };
            },
            .unwinding => error.InvalidState,
        };
    }

    pub fn run(self: *Session, quantum: ?u64) Error!Observation {
        var steps: u64 = 0;
        while (self.terminal == null and self.status == .active and (quantum == null or steps < quantum.?)) : (steps +|= 1)
            try self.step();
        return self.observe();
    }

    pub fn step(self: *Session) Error!void {
        if (self.poisoned or self.terminal != null or self.status != .active) return error.InvalidState;
        errdefer self.poisoned = true;
        const current = self.roots.current orelse return error.InvalidState;
        const control = (try self.store.get(current)).control;
        const code = self.program.blocks[@intCast(control.block)];
        var frame = try self.frames.getForUpdate(current.id);
        if (frame.position < code.instructions.len) {
            const op = code.instructions[frame.position];
            const layout = self.program.functions[@intCast(code.function)].layout.slots;
            const reader = try self.frames.slots.reader(frame.view);
            var temporary = std.heap.ArenaAllocator.init(self.allocator);
            defer temporary.deinit();
            var values: @import("../interpreter_v2/values.zig").Values = .{
                .allocator = temporary.allocator(),
                .schemas = self.program.schemas,
                .store = &self.store,
                .facts = self.value_facts,
                .traits = self.uses,
                .aggregate_storage = .structured,
            };
            switch (try @import("../interpreter_v2/data_instruction.zig").execute(self, op, layout[@intCast(op.destination)], reader, &values)) {
                .failed => |failure| try self.finishTerminal(.{ .reason = .{ .failure = failure } }),
                .value => |value| {
                    frame.position += 1;
                    try self.frames.apply(&frame, self.flow.facts.live[@intCast(control.block)][frame.position], @as([]const p.Id, &.{op.destination}), &.{value});
                    try self.frames.update(current.id, frame);
                },
            }
        } else {
            try self.executeControl(current, control, code, &frame);
            if (code.terminator == .return_value) if (self.return_counter) |counter| {
                if (std.mem.indexOfScalar(p.Id, counter.functions, code.function) != null) counter.count.* +|= 1;
            };
        }
        if (self.roots.current == null or self.roots.current.?.id != current.id)
            if (try self.store.get(current) == .control) try self.frames.remove(current.id);
        self.transitions +%= 1;
        if (self.statistics) |statistics| {
            statistics.transitions +|= 1;
            statistics.dispatches +|= 1;
        }
        if (self.terminal != null or self.status != .active or self.transitions % 256 == 0)
            try self.store.collectWith(self.roots, &self.frames);
    }

    fn executeControl(self: *Session, current: g.NodeRef, saved: g.Control, code: ir.Block, frame: *bindings.Frame) Error!void {
        const reader = try self.frames.slots.reader(frame.view);
        var temporary = std.heap.ArenaAllocator.init(self.allocator);
        defer temporary.deinit();
        const scratch = temporary.allocator();
        switch (code.terminator) {
            .return_value => |slot| {
                const value = try read(reader, slot);
                if (saved.parent) |parent| try self.resumeContinuation(parent, value) else try self.finishTerminal(.{ .reason = .{ .normal = value } });
            },
            .fail => |slot| try self.finishTerminal(.{ .reason = .{ .failure = try read(reader, slot) } }),
            .jump => |edge| try self.jump(current, saved, frame, edge, null),
            .yield_value => |edge| {
                try self.jump(current, saved, frame, edge, null);
                self.status = .yielded;
            },
            .branch => |branch| {
                const condition = try read(reader, branch.condition);
                try self.jump(current, saved, frame, if (condition.body.scalar[0] == 1) branch.when_true else branch.when_false, null);
            },
            .call => |call| {
                const arguments = try self.collectArguments(scratch, reader, call.arguments);
                const tail = self.isTail(call.next);
                if (tail and self.frames.canRestart(frame.*, call.function)) {
                    const entry = self.program.functions[@intCast(call.function)].entry;
                    try self.frames.restart(frame, call.function, self.flow.facts.live[@intCast(entry)][0], arguments);
                    var changed = saved;
                    changed.block = entry;
                    try self.store.replace(current, .{ .control = changed });
                    try self.frames.update(current.id, frame.*);
                    return;
                }
                const parent = if (tail) saved.parent else try self.captureContinuation(current, saved, frame.*, call.next);
                try self.enter(call.function, arguments, parent, null, null);
            },
            .perform => |operation| {
                const payload = try read(reader, operation.payload);
                const captured = try self.captureContinuation(current, saved, frame.*, operation.next);
                self.roots.pending = try self.store.add(.{ .pending = .{
                    .effect = operation.effect,
                    .payload = payload,
                    .continuation = captured,
                    .source_block = saved.block,
                } });
                self.roots.current = null;
                self.status = .parked;
            },
            .switch_variant, .unpack_product => try self.aggregateControl(current, saved, frame, code.terminator, reader, scratch),
            .apply, .handle, .resume_value, .resume_with, .resume_computation, .dispose, .protect, .with_region => return error.UnsupportedTransition,
        }
    }
    pub fn initImage(allocator: std.mem.Allocator, image: []const u8, arguments: []const u8, bridge: profile.Bridge) Error!Session {
        var prepared = try Prepared.init(allocator, image);
        defer prepared.deinit();
        return start(allocator, &prepared, arguments, bridge);
    }

    pub fn start(allocator: std.mem.Allocator, prepared: *const Prepared, arguments: []const u8, bridge: profile.Bridge) Error!Session {
        var result = try empty(allocator, prepared, bridge);
        errdefer result.deinit();
        try result.initialize(arguments);
        return result;
    }

    fn empty(allocator: std.mem.Allocator, prepared: *const Prepared, bridge: profile.Bridge) Error!Session {
        const core = try prepared.acquire();
        errdefer core.release();
        _ = try profile.check(core.admitted(), bridge);
        var flow = try core.admitted().analysis(allocator);
        errdefer flow.deinit();
        const program = core.admitted().program();
        const frames = try bindings.Frames.init(allocator, flow.facts.pool, core.frameLayouts());
        return .{
            .allocator = allocator,
            .prepared = core,
            .program = program,
            .program_identity = core.admitted().identity(),
            .flow = flow,
            .uses = core.admitted().traits(),
            .value_facts = core.admitted().schemaFacts(),
            .frames = frames,
            .store = .{ .allocator = allocator },
        };
    }

    pub fn restoreImage(allocator: std.mem.Allocator, image: []const u8, checkpoint_bytes: []const u8, bridge: profile.Bridge) Error!Session {
        var prepared = try Prepared.init(allocator, image);
        defer prepared.deinit();
        return restore(allocator, &prepared, checkpoint_bytes, bridge);
    }

    pub fn restore(allocator: std.mem.Allocator, prepared: *const Prepared, checkpoint_bytes: []const u8, bridge: profile.Bridge) Error!Session {
        var result = try empty(allocator, prepared, bridge);
        errdefer result.deinit();
        var incoming = try data.state_image.decodeGraph(allocator, checkpoint_bytes);
        var transferred = false;
        defer if (!transferred) incoming.deinit();
        const state = incoming.state;
        try data.state_admission.validateAdmitted(allocator, result.prepared.admitted(), state);
        if (state.status == .unwinding or state.status == .cancelled or state.roots.evidence != null) return error.InvalidState;
        for (state.nodes) |node| switch (node.record) {
            .control, .continuation, .aggregate, .pending => {},
            .exit => |value| switch (value.reason) {
                .normal, .failure => {},
                else => return error.InvalidState,
            },
            else => return error.InvalidState,
        };
        try result.store.importOwned(&incoming);
        transferred = true;
        for (state.nodes, 0..) |node, id| if (node.activation) |activation| {
            const block = switch (node.record) {
                .control => |control| control.block,
                .continuation => |saved| saved.source_block,
                else => unreachable, // Admitted shape.
            };
            try result.frames.restore(id, result.program.blocks[@intCast(block)].function, activation);
        };
        result.roots = state.roots;
        if (@backingInt(state.status) < 4) {
            result.status = @fromBackingInt(@intCast(@backingInt(state.status)));
        } else {
            result.terminal = state.roots.exit;
        }
        return result;
    }

    pub fn deinit(self: *Session) void {
        self.frames.deinit();
        self.store.deinit();
        self.flow.deinit();
        self.prepared.release();
        self.* = undefined;
    }

    pub fn checkpoint(self: *Session, allocator: std.mem.Allocator) Error![]u8 {
        return (try self.serializeCheckpoint(.{ .allocate = allocator }, null)).bytes.?;
    }

    pub fn serializeCheckpoint(self: *Session, destination: data.state_image.Destination, hasher: ?*std.crypto.hash.sha2.Sha256) Error!data.state_image.Serialization {
        if (self.poisoned) return error.InvalidState;
        if (self.statistics) |statistics| statistics.state_projections +|= 1;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const count = self.store.nodes.items.len;
        const nodes = try a.alloc(data.process_state.Node, count);
        for (self.store.nodes.items, self.store.alive.items, 0..) |node, alive, id| {
            // A reachable dead handle must fail graph shape checks, never become
            // a plausible empty semantic object in a checkpoint.
            nodes[id] = if (alive) .{ .record = node, .activation = try self.frames.project(id, a) } else .{ .record = .{ .control = .{ .block = std.math.maxInt(u64) } } };
        }
        const roots = self.roots;
        var status: data.process_state.Status = @fromBackingInt(@intCast(@backingInt(self.status)));
        if (self.terminal != null) {
            status = switch ((try self.terminalExit()).reason) {
                .normal => .completed,
                .failure => .failed,
                else => return error.InvalidState,
            };
        }

        const public_state = try @import("../interpreter_v2/value_projection.zig").projectOrdinary(a, self.program.schemas, &self.store, data.process_state.State{
            .program_identity = self.program_identity,
            .status = status,
            .roots = roots,
            .nodes = nodes,
            .blobs = self.store.blobs.items,
        });
        return data.state_image.serialize(self.allocator, public_state, destination, hasher);
    }

    pub fn terminalExit(self: *const Session) Error!g.Exit {
        const node = try self.store.get(self.terminal orelse return error.InvalidState);
        return switch (node) {
            .exit => |exit| exit,
            else => error.InvalidState,
        };
    }

    fn finishTerminal(self: *Session, reason: g.Exit) Error!void {
        const exit = try self.store.add(.{ .exit = reason });
        self.roots = .{ .exit = exit };
        self.terminal = exit;
    }

    fn initialize(self: *Session, input: []const u8) Error!void {
        var temporary = std.heap.ArenaAllocator.init(self.allocator);
        defer temporary.deinit();
        const scratch = temporary.allocator();
        const values = try self.store.importArguments(self.prepared.admitted(), input, scratch);
        try self.enter(self.program.roots.entry, values, null, null, null);
        try self.store.compactImported();
    }

    pub fn bytes(self: *Session, value: *const g.Value) Error![]const u8 {
        const values: @import("../interpreter_v2/values.zig").Values = .{
            .allocator = self.allocator,
            .schemas = self.program.schemas,
            .store = &self.store,
            .aggregate_storage = .structured,
        };
        return values.bytes(value);
    }

    pub fn instructionFailure(self: *Session, instruction: ir.Instruction, fault: p.Fault) Error!g.Value {
        for (instruction.failures) |failure| if (failure.kind == fault)
            return self.store.literal(self.program.schemas, self.program.constants[@intCast(failure.value)]);
        return error.InvalidProgram;
    }

    pub fn resumeYield(self: *Session) Error!void {
        if (self.poisoned or self.status != .yielded) return error.InvalidState;
        self.status = .active;
    }

    pub fn pendingRequest(self: *Session, allocator: std.mem.Allocator) Error!Pending {
        return self.pendingBinding(allocator, true);
    }

    pub fn pendingBinding(self: *Session, allocator: std.mem.Allocator, materialize: bool) Error!Pending {
        if (self.poisoned or self.terminal != null or self.status != .parked) return error.InvalidState;
        if (self.statistics) |statistics| statistics.pending_bindings +|= 1;
        const operation = (try self.store.get(self.roots.pending.?)).pending;
        const effect = self.program.effects[@intCast(operation.effect)];
        var hasher = protocol.stateDigestHasher();
        const serialized = try self.serializeCheckpoint(if (materialize) .{ .allocate = allocator } else .none, &hasher);
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
        var expected = try self.pendingBinding(self.allocator, false);
        defer expected.deinit();
        try @import("../interpreter_v2/response.zig").answer(self, input, expected.request.request_identity);
    }

    /// Closed, in-process framing under exclusive base ownership. The caller
    /// binds the selected image and exact environmental effect. This consumes
    /// the current private request; it is not a guest ERS3 or a transfer token.
    /// Portable/remote replies continue through answer() and its state digest.
    pub fn replyBridge(self: *Session, image: [32]u8, effect_id: p.Id, bytes_value: []const u8) Error!void {
        if (!std.mem.eql(u8, &image, &self.program_identity)) return error.InvalidBridge;
        if (self.poisoned or self.terminal != null or self.status != .parked) return error.InvalidState;
        const pending = (try self.store.get(self.roots.pending orelse return error.InvalidState)).pending;
        if (pending.effect != effect_id) return error.InvalidBridge;
        const effect = self.program.effects[@intCast(effect_id)];
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const literal: p.Literal = .{ .schema = effect.result, .bytes = bytes_value };
        try data.admission.value(scratch.allocator(), self.program.schemas, self.value_facts, literal);
        errdefer self.poisoned = true;
        const value = try self.store.literal(self.program.schemas, literal);
        try self.resumeContinuation(pending.continuation, value);
        self.roots.pending = null;
        self.status = .active;
    }

    fn collectArguments(_: *Session, allocator: std.mem.Allocator, reader: anytype, operands: []const p.Id) Error![]g.Value {
        const values = try allocator.alloc(g.Value, operands.len);
        for (values, operands) |*value, slot| value.* = try read(reader, slot);
        return values;
    }

    fn isTail(self: *Session, edge: ir.Edge) bool {
        const target = self.program.blocks[@intCast(edge.block)];
        return target.instructions.len == 0 and target.terminator == .return_value and
            edge.assignments.len == 1 and edge.assignments[0].source == .returned and
            edge.assignments[0].destination == target.terminator.return_value;
    }

    fn enter(self: *Session, function: p.Id, args: []const g.Value, parent: ?g.NodeRef, evidence: ?g.NodeRef, region: ?g.NodeRef) Error!void {
        const target = self.program.functions[@intCast(function)];
        if (target.inputs.len != args.len) return error.InvalidState;
        const record: g.Node = .{ .control = .{
            .block = target.entry,
            .parent = parent,
            .evidence = evidence,
            .region = region,
        } };
        // A retained caller has already become a continuation. An active
        // control has one custodian and can receive the completed new frame.
        const reuse = if (self.roots.current) |current|
            if (try self.store.get(current) == .control) current else null
        else
            null;
        const control = reuse orelse try self.store.add(record);
        var frame = try self.frames.create(function);
        errdefer self.frames.releaseFrame(frame);
        try self.frames.apply(&frame, self.flow.facts.live[@intCast(target.entry)][0], target.inputs, args);
        if (reuse != null) {
            const previous = try self.frames.get(control.id);
            try self.store.replace(control, record);
            try self.frames.update(control.id, frame);
            self.frames.releaseFrame(previous);
        } else try self.frames.put(control.id, frame);
        self.roots.current = control;
        self.roots.evidence = evidence;
    }

    fn retainedSlots(self: *Session, edge: ir.Edge) Error!data.analysis_sets.Root {
        const after = self.flow.facts.live[@intCast(edge.block)][0];
        var root = after;
        for (edge.assignments) |assignment| root = try self.flow.facts.pool.remove(root, assignment.destination);
        for (edge.assignments) |assignment| {
            if (assignment.source == .slot and self.flow.facts.pool.contains(after, assignment.destination))
                root = try self.flow.facts.pool.insert(root, assignment.source.slot);
        }
        return root;
    }

    fn captureContinuation(self: *Session, current: g.NodeRef, control: g.Control, original: bindings.Frame, edge: ir.Edge) Error!g.NodeRef {
        var frame = original;
        try self.frames.prune(&frame, try self.retainedSlots(edge));
        try self.store.replace(current, .{ .continuation = .{
            .source_block = control.block,
            .parent = control.parent,
            .evidence = control.evidence,
            .region = control.region,
        } });
        try self.frames.update(current.id, frame);
        return current;
    }

    fn assignEdge(self: *Session, frame: *bindings.Frame, next: ir.Edge, returned: ?g.Value) Error!void {
        const values = try self.allocator.alloc(g.Value, next.assignments.len);
        defer self.allocator.free(values);
        const live = self.flow.facts.live[@intCast(next.block)][0];
        for (values, next.assignments) |*value, assignment| {
            if (!self.flow.facts.pool.contains(live, assignment.destination)) continue;
            value.* = switch (assignment.source) {
                .slot => |slot| try self.frames.slots.get(frame.view, @intCast(slot)),
                .returned => returned orelse return error.InvalidState,
            };
        }
        const block = self.program.blocks[@intCast(next.block)];
        const layout = self.program.functions[@intCast(block.function)].layout.slots;
        for (next.assignments) |assignment| if (assignment.source == .slot) {
            const slot = assignment.source.slot;
            if (!self.uses.copy[@intCast(layout[@intCast(slot)])]) try self.frames.clear(frame, slot);
        };
        try self.frames.scope(frame, block.custody);
        try self.frames.apply(frame, live, next.assignments, values);
        frame.position = 0;
    }

    fn jump(self: *Session, current: g.NodeRef, control: g.Control, frame: *bindings.Frame, next: ir.Edge, returned: ?g.Value) Error!void {
        try self.assignEdge(frame, next, returned);
        var changed = control;
        changed.block = next.block;
        try self.store.replace(current, .{ .control = changed });
        try self.frames.update(current.id, frame.*);
    }

    pub fn resumeContinuation(self: *Session, reference: g.NodeRef, value: g.Value) Error!void {
        const saved = (try self.store.get(reference)).continuation;
        const next = nextEdge(self.program.blocks[@intCast(saved.source_block)].terminator).?;
        // Consume the existing continuation, keeping its frame custody.
        // Multi-shot activation reaches this path only after cloning its capture.
        const current = reference;
        try self.store.replace(current, .{ .control = .{
            .block = next.block,
            .parent = saved.parent,
            .evidence = saved.evidence,
            .region = saved.region,
        } });
        var frame = try self.frames.getForUpdate(reference.id);
        try self.assignEdge(&frame, next, value);
        try self.frames.update(current.id, frame);
        self.roots.current = current;
        self.roots.evidence = saved.evidence;
    }

    fn aggregateControl(self: *Session, current: g.NodeRef, control: g.Control, frame: *bindings.Frame, term: ir.Terminator, reader: anytype, scratch: std.mem.Allocator) Error!void {
        var values: @import("../interpreter_v2/values.zig").Values = .{
            .allocator = scratch,
            .schemas = self.program.schemas,
            .store = &self.store,
            .aggregate_storage = .structured,
        };
        switch (term) {
            .switch_variant => |selected| {
                const parts = try values.split(try read(reader, selected.value));
                const layout = self.program.functions[@intCast(self.program.blocks[@intCast(control.block)].function)].layout.slots;
                if (!self.uses.copy[@intCast(layout[@intCast(selected.value)])])
                    try self.frames.clear(frame, selected.value);
                try self.jump(current, control, frame, selected.cases[@intCast(parts.tag)], parts.fields[0]);
            },
            .unpack_product => |unpack| {
                const value = try read(reader, unpack.value);
                const parts = try values.split(value);
                if (!self.uses.copy[@intCast(value.schema)]) try self.frames.clear(frame, unpack.value);
                try self.frames.scope(frame, self.program.blocks[@intCast(unpack.next.block)].custody);
                for (parts.fields, unpack.destinations) |field, slot| try self.frames.write(frame, slot, field);
                try self.jump(current, control, frame, unpack.next, null);
            },
            else => unreachable,
        }
    }
};
fn nextEdge(term: ir.Terminator) ?ir.Edge {
    return switch (term) {
        .call => |op| op.next,
        .perform => |op| op.next,
        else => null,
    };
}
