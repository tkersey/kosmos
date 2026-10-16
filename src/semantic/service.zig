//! Persistent first-order service. Private controls are admitted by the bound
//! facade; guest semantics and guest work accounting remain ordinary source.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const edges = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
pub const identity = "kosmos.semantic-service/1";
pub const Initial = union(enum) { arguments: []const u8, state: data.process_state.State };
/// Reply bytes are the value of an already bound ERS3, never that envelope.
pub const Control = union(enum) { none, answer: []const u8, resume_yield, cancel: data.invocation.Reason };
pub const Command = union(enum) { advance: struct { control: Control, quantum: u64 }, observe, project, finish };
pub const Cut = struct { status: data.process_state.Status, guest_work: u64 };
pub const Event = union(enum) { cut: Cut, observation: @import("observe.zig").Observation, projection: data.process_state.State };
pub const Definition = struct { entry: Id, effect: Id, state: Id, loop: Id, dispatch: Id, receive: Id, advance: Id, commit: Id, control_commit: Id, publish: Id, command: Id, event: Id };

fn statusTag(e: Author, m: machines.Definition, input: Id) Error!Id {
    return e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{try edges.field(e, try m.field(e, input, .header), machines.Header, "status")}, 0);
}
pub fn define(b: *source.Builder) Error!Definition {
    return defineWithDispatch(b, false);
}

/// The same service protocol with source-level finite address dispatch. Its
/// program parameter stays explicit across dynamic calls and bridge responses.
pub fn defineStaged(b: *source.Builder) Error!Definition {
    return defineWithDispatch(b, true);
}

fn defineWithDispatch(b: *source.Builder, comptime staged: bool) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.service/1", @intFromBool(staged));
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const m = try machines.define(b);
    const life = try @import("lifecycle.zig").define(b, m);
    const step = try @import("step.zig").define(b, m);
    const active = if (staged) try @import("staged.zig").define(b, m, step) else step.active;
    const collector = try @import("collect.zig").define(b, m);
    const observe = try @import("observe.zig").define(b, m);
    const command_type = try projection.schema(Command, b);
    const event_type = try projection.schema(Event, b);
    const effect = try b.effect(.{ .identity = identity, .payload = event_type, .result = command_type });
    // The countdown is a retention policy, not a guest work/lifetime limit.
    const state = try b.schema(.{ .product = &.{ m.schema, e.integer } });
    const interval = try b.constant(u64, 64);
    const loop = try b.declare(&.{ m.program, state, event_type, state }, e.unit, &.{effect}, &.{});
    const dispatch = try b.declare(&.{ m.program, state, command_type }, e.unit, &.{effect}, &.{});
    const receive = try b.declare(&.{ m.program, state, state, command_type }, e.unit, &.{effect}, &.{});
    const advance = try b.declare(&.{ m.program, state, e.integer }, state, &.{}, &.{});
    const publish = try b.declare(&.{ m.program, state, state, event_type }, e.unit, &.{effect}, &.{});
    {
        const prior = try e.field(try e.param(publish, 1), 0);
        const next_state = try e.param(publish, 2);
        const next = try e.field(next_state, 0);
        const old_identity = try edges.field(e, try m.field(e, prior, .header), machines.Header, "program_identity");
        const new_identity = try edges.field(e, try m.field(e, next, .header), machines.Header, "program_identity");
        var body = try e.call(loop, &.{ try e.param(publish, 0), next_state, try e.param(publish, 3), try e.param(publish, 1) });
        for (0..32) |i| body = try e.when(try e.binary(.equal, try e.required(old_identity, try b.constant(u64, i)), try e.required(new_identity, try b.constant(u64, i))), body, try e.fail());
        try b.define(publish, body);
    }
    {
        const prior = try e.field(try e.param(receive, 1), 0);
        const current = try e.param(receive, 2);
        const old_identity = try edges.field(e, try m.field(e, prior, .header), machines.Header, "program_identity");
        const current_identity = try edges.field(e, try m.field(e, try e.field(current, 0), .header), machines.Header, "program_identity");
        var body = try e.call(dispatch, &.{ try e.param(receive, 0), current, try e.param(receive, 3) });
        for (0..32) |i| body = try e.when(try e.binary(.equal, try e.required(old_identity, try b.constant(u64, i)), try e.required(current_identity, try b.constant(u64, i))), body, try e.fail());
        try b.define(receive, body);
        const command = try b.variable(command_type);
        const exchange = try b.term(.{ .perform = .{ .effect = effect, .payload = try e.param(loop, 2) } });
        // The complete prior command input remains a real call argument until
        // the event has been acknowledged by the enclosing bridge owner.
        try b.define(loop, try b.bind(command, exchange, try e.call(receive, &.{ try e.param(loop, 0), try e.param(loop, 3), try e.param(loop, 1), try b.reference(command) })));
    }
    const commit = try b.declare(&.{ m.schema, m.schema }, m.schema, &.{}, &.{});
    const control_commit = try b.declare(&.{ m.schema, m.schema }, m.schema, &.{}, &.{});
    inline for (.{ commit, control_commit }, 0..) |function, kind| {
        const before = try e.param(function, 0);
        const after = try e.param(function, 1);
        const prior_work = try m.field(e, before, .work);
        const expected = if (kind == 0) try e.binary(.integer_add, prior_work, e.one) else prior_work;
        try b.define(function, try e.when(try e.binary(.equal, try m.field(e, after, .work), expected), try b.pure(after), try e.fail()));
    }
    {
        const program = try e.param(advance, 0);
        const saved = try e.param(advance, 1);
        const input = try e.replace(try e.field(saved, 0), @backingInt(machines.Field.program), program);
        const remaining = try e.field(saved, 1);
        const quantum = try e.param(advance, 2);
        const collected = try b.variable(m.schema);
        const stepped = try b.variable(step.result);
        const committed = try b.variable(m.schema);
        const after = try e.payload(try b.reference(stepped), 0);
        const collect = try b.bind(collected, try e.call(collector.run, &.{input}), try e.call(advance, &.{ program, try e.tuple(state, &.{ try b.reference(collected), interval }), quantum }));
        const next = try e.tuple(state, &.{ try b.reference(committed), try e.binary(.integer_sub, remaining, e.one) });
        // The actual predecessor is a retained call argument until the source
        // transition commits. It is shared storage, never a shadow execution.
        const run = try b.bind(stepped, try e.call(active, &.{input}), try b.bind(committed, try e.call(commit, &.{ input, after }), try e.call(advance, &.{ program, next, quantum })));
        const work = try e.when(try e.binary(.equal, remaining, e.zero), collect, run);
        const tag = try statusTag(e, m, input);
        const idle = try b.pure(saved);
        const live = try e.when(try e.binary(.equal, tag, try b.constant(u32, @backingInt(data.process_state.Status.active))), work, try e.when(try e.binary(.equal, tag, try b.constant(u32, @backingInt(data.process_state.Status.unwinding))), work, idle));
        try b.define(advance, try e.when(try e.binary(.less, try m.field(e, input, .work), quantum), live, idle));
    }
    {
        const program = try e.param(dispatch, 0);
        const saved = try e.param(dispatch, 1);
        const input = try e.replace(try e.field(saved, 0), @backingInt(machines.Field.program), program);
        const command = try e.param(dispatch, 2);
        const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
        var cases: [4]Case = undefined;
        inline for (@typeInfo(Command).@"union".field_types, 0..) |T, i| {
            const variable = try b.variable(try projection.schema(T, b));
            var body: Id = undefined;
            switch (i) {
                0 => {
                    const operation = try b.reference(variable);
                    const changed = try b.variable(m.schema);
                    const controlled = try b.variable(m.schema);
                    const advanced = try b.variable(state);
                    const after = try e.field(try b.reference(advanced), 0);
                    const cut = try e.tuple(try projection.schema(Cut, b), &.{ try edges.field(e, try m.field(e, after, .header), machines.Header, "status"), try m.field(e, after, .work) });
                    // Passing the original service state after advance keeps
                    // the committed command predecessor in the real outer
                    // continuation throughout control, cloning, and cleanup.
                    body = try b.bind(advanced, try e.call(advance, &.{ program, try e.tuple(state, &.{ try e.replace(try b.reference(controlled), @backingInt(machines.Field.work), e.zero), try e.field(saved, 1) }), try e.field(operation, 1) }), try e.call(publish, &.{ program, saved, try b.reference(advanced), try e.variant(event_type, 0, cut) }));
                    body = try b.bind(controlled, try e.call(control_commit, &.{ input, try b.reference(changed) }), body);
                    var controls: [4]Case = undefined;
                    inline for (@typeInfo(Control).@"union".field_types, 0..) |C, j| {
                        const arg = try b.variable(try projection.schema(C, b));
                        const call = switch (j) {
                            0 => try b.pure(input),
                            1 => try e.call(life.respond, &.{ input, try b.reference(arg) }),
                            2 => try e.call(life.resume_yield, &.{input}),
                            3 => try e.call(life.cancel, &.{ input, try b.reference(arg) }),
                            else => unreachable,
                        };
                        controls[j] = .{ .variable = arg, .body = call };
                    }
                    body = try b.bind(changed, try b.term(.{ .match_sum = .{ .value = try e.field(operation, 0), .cases = &controls } }), body);
                },
                1, 2 => {
                    const output = try b.variable(if (i == 1) try projection.schema(@import("observe.zig").Observation, b) else m.state);
                    body = try b.bind(output, try e.call(if (i == 1) observe else m.project, &.{input}), try e.call(loop, &.{ program, saved, try e.variant(event_type, if (i == 1) 1 else 2, try b.reference(output)), saved }));
                },
                3 => {
                    const tag = try statusTag(e, m, input);
                    body = try e.fail();
                    inline for (.{ data.process_state.Status.completed, data.process_state.Status.failed, data.process_state.Status.cancelled }) |s| body = try e.when(try e.binary(.equal, tag, try b.constant(u32, @backingInt(s))), try b.pure(e.unit_value), body);
                },
                else => unreachable,
            }
            cases[i] = .{ .variable = variable, .body = body };
        }
        try b.define(dispatch, try b.term(.{ .match_sum = .{ .value = command, .cases = &cases } }));
    }
    const entry = try b.declare(&.{ m.program, try projection.schema(Initial, b) }, e.unit, &.{effect}, &.{});
    {
        const initialized = try b.variable(m.schema);
        const args = try b.variable(try b.schema(.bytes));
        const restored = try b.variable(m.state);
        const start = try b.term(.{ .match_sum = .{ .value = try e.param(entry, 1), .cases = &.{
            .{ .variable = args, .body = try e.call(life.initialize, &.{ try e.param(entry, 0), try b.reference(args) }) },
            .{ .variable = restored, .body = try e.call(m.hydrate, &.{ try e.param(entry, 0), try b.reference(restored) }) },
        } } });
        const machine = try b.reference(initialized);
        const cut = try e.tuple(try projection.schema(Cut, b), &.{ try edges.field(e, try m.field(e, machine, .header), machines.Header, "status"), e.zero });
        const saved = try e.tuple(state, &.{ machine, interval });
        try b.define(entry, try b.bind(initialized, start, try e.call(loop, &.{ try e.param(entry, 0), saved, try e.variant(event_type, 0, cut), saved })));
    }
    return cache.finish(b, .{ .entry = entry, .effect = effect, .state = state, .loop = loop, .dispatch = dispatch, .receive = receive, .advance = advance, .commit = commit, .control_commit = control_commit, .publish = publish, .command = command_type, .event = event_type });
}
