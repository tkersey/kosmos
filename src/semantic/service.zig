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
pub const identity = "kosmos.semantic-service/2";
pub const instrumentation = @import("instrumentation.zig");
pub const Initial = union(enum) { arguments: []const u8, state: data.process_state.State };
/// Reply bytes are the value of an already bound ERS3, never that envelope.
pub const Control = union(enum) {
    none,
    answer: []const u8,
    resume_yield,
    cancel: data.invocation.Reason,
};
pub const Command = union(enum) { advance: struct {
    control: Control,
    quantum: u64,
}, observe, project, finish };
pub const Cut = struct {
    status: data.process_state.Status,
    guest_work: u64,
    trace: ?instrumentation.Trace = null,
};
pub const Event = union(enum) {
    cut: Cut,
    observation: @import("observe.zig").Observation,
    projection: data.process_state.State,
};
pub const Definition = struct {
    entry: Id,
    effect: Id,
    state: Id,
    loop: Id,
    dispatch: Id,
    advance: Id,
    commit: Id,
    control_commit: Id,
    publish: Id,
    cut: Id,
    command: Id,
    event: Id,
};

fn statusTag(e: Author, m: machines.Definition, input: Id) Error!Id {
    return e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{try edges.field(
        e,
        try m.field(e, input, .header),
        machines.Header,
        "status",
    )}, 0);
}
pub fn define(b: *source.Builder) Error!Definition {
    return defineWithHooks(b, false, .{});
}

/// The same service protocol with source-level finite address dispatch. Its
/// program parameter stays explicit across dynamic calls and bridge responses.
pub fn defineStaged(b: *source.Builder) Error!Definition {
    return defineWithHooks(b, true, .{});
}

pub fn defineWithHooks(
    b: *source.Builder,
    staged: bool,
    hooks: instrumentation.Hooks,
) Error!Definition {
    const cache = try defineWithHooksCache(b, staged, hooks);
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
    const cut_type = try projection.schema(Cut, b);
    const cut_function = try b.declare(&.{m.schema}, cut_type, &.{}, &.{});
    try emitCutFunction(hooks, e, m, cut_type, cut_function);
    const effect = try b.effect(.{
        .identity = identity,
        .payload = event_type,
        .result = command_type,
    });
    // The countdown is a retention policy, not a guest work/lifetime limit.
    const state = try b.schema(.{ .product = &.{ m.schema, e.integer } });
    const interval = try b.constant(u64, 64);
    const loop = try b.declare(&.{ m.program, state, event_type }, state, &.{effect}, &.{});
    const dispatch = try b.declare(&.{ m.program, state, command_type }, state, &.{effect}, &.{});
    const advance = try b.declare(&.{ m.program, state, e.integer }, state, &.{}, &.{});
    const publish = try b.declare(&.{
        m.program, state, state, event_type,
    }, state, &.{effect}, &.{});
    try emitPublish(e, m, loop, publish);
    try emitLoop(e, command_type, effect, loop, dispatch);
    const commit = try b.declare(&.{ m.schema, m.schema }, m.schema, &.{}, &.{});
    const control_commit = try b.declare(&.{ m.schema, m.schema }, m.schema, &.{}, &.{});
    try emitCommits(e, m, commit, control_commit);
    const entry = try emitService(e, m, life, step, active, collector, observe, .{
        .entry = undefined,
        .effect = effect,
        .state = state,
        .loop = loop,
        .dispatch = dispatch,
        .advance = advance,
        .commit = commit,
        .control_commit = control_commit,
        .publish = publish,
        .cut = cut_function,
        .command = command_type,
        .event = event_type,
    }, cut_type, interval);
    return cache.finish(b, .{
        .entry = entry,
        .effect = effect,
        .state = state,
        .loop = loop,
        .dispatch = dispatch,
        .advance = advance,
        .commit = commit,
        .control_commit = control_commit,
        .publish = publish,
        .cut = cut_function,
        .command = command_type,
        .event = event_type,
    });
}

fn defineWithHooksCache(
    b: *source.Builder,
    staged: bool,
    hooks: instrumentation.Hooks,
) Error!source.Specialization(Definition) {
    return try b.specialization(
        Definition,
        "kosmos.semantic.service/2",
        @as(u64, @intFromBool(
            staged,
        )) | (@as(
            u64,
            @intFromBool(
                hooks.control,
            ),
        ) << 1) | (@as(
            u64,
            @intFromBool(
                hooks.storage,
            ),
        ) << 2),
    );
}

fn defineWithHooksCollect(
    e: Author,
    collector: anytype,
    input: Id,
    state: Id,
    interval: Id,
    advance: Id,
    program: Id,
    quantum: Id,
    collected: Id,
) Error!Id {
    return try e.b.bind(
        collected,
        try e.call(collector.run, &.{
            input,
        }),
        try e.call(
            advance,
            &.{
                program,
                try e.tuple(state, &.{
                    try e.b.reference(collected),
                    interval,
                }),
                quantum,
            },
        ),
    );
}

fn defineWithHooksRun(
    e: Author,
    active: anytype,
    input: Id,
    advance: Id,
    next: Id,
    commit: Id,
    after: Id,
    program: Id,
    quantum: Id,
    stepped: Id,
    committed: Id,
) Error!Id {
    return try e.b.bind(
        stepped,
        try e.call(active, &.{
            input,
        }),
        try e.b.bind(
            committed,
            try e.call(commit, &.{
                input,
                after,
            }),
            try e.call(advance, &.{ program, next, quantum }),
        ),
    );
}

fn defineWithHooksSettle(e: Author, collect: Id, tag: anytype, retain: Id) Error!Id {
    return try e.when(try e.binary(.equal, tag, try e.b.constant(
        u32,
        @backingInt(data.process_state.Status.active),
    )), retain, try e.when(
        try e.binary(
            .equal,
            tag,
            try e.b.constant(u32, @backingInt(
                data.process_state.Status.unwinding,
            )),
        ),
        retain,
        collect,
    ));
}

fn emitCutFunction(
    hooks: instrumentation.Hooks,
    e: Author,
    m: anytype,
    cut_type: Id,
    cut_function: Id,
) Error!void {
    const input = try e.param(cut_function, 0);
    const optional_trace = try projection.schema(?instrumentation.Trace, e.b);
    const trace = try e.b.variable(try projection.schema(instrumentation.Trace, e.b));
    const payload = if (hooks.enabled()) try e.variant(
        optional_trace,
        1,
        try e.b.reference(trace),
    ) else try e.variant(optional_trace, 0, e.unit_value);
    var body = try e.b.pure(try e.tuple(cut_type, &.{ try edges.field(
        e,
        try m.field(e, input, .header),
        machines.Header,
        "status",
    ), try m.field(e, input, .work), payload }));
    // Disabled hooks emit no observer call, graph traversal or trace data.
    if (hooks.enabled()) body = try e.b.bind(trace, try e.call(
        try instrumentation.define(e.b, m, hooks),
        &.{input},
    ), body);
    try e.b.define(cut_function, body);
}

fn emitPublish(e: Author, m: anytype, loop: Id, publish: Id) Error!void {
    const prior = try e.field(try e.param(publish, 1), 0);
    const next_state = try e.param(publish, 2);
    const next = try e.field(next_state, 0);
    const old_identity = try edges.field(
        e,
        try m.field(e, prior, .header),
        machines.Header,
        "program_identity",
    );
    const new_identity = try edges.field(
        e,
        try m.field(e, next, .header),
        machines.Header,
        "program_identity",
    );
    var body = try e.call(loop, &.{
        try e.param(publish, 0), next_state, try e.param(publish, 3),
    });
    for (0..32) |i| body = try e.when(try e.binary(.equal, try e.required(
        old_identity,
        try e.b.constant(u64, i),
    ), try e.required(new_identity, try e.b.constant(u64, i))), body, try e.fail());
    try e.b.define(publish, body);
}

fn emitAdvance(
    e: Author,
    m: anytype,
    step: anytype,
    active: anytype,
    collector: anytype,
    state: Id,
    interval: Id,
    advance: Id,
    commit: Id,
) Error!void {
    const program = try e.param(advance, 0);
    const saved = try e.param(advance, 1);
    const input = try e.replace(
        try e.field(saved, 0),
        @backingInt(machines.Field.program),
        program,
    );
    const remaining = try e.field(saved, 1);
    const quantum = try e.param(advance, 2);
    const collected = try e.b.variable(m.schema);
    const stepped = try e.b.variable(step.result);
    const committed = try e.b.variable(m.schema);
    const after = try e.payload(try e.b.reference(stepped), 0);
    const collect = try defineWithHooksCollect(
        e,
        collector,
        input,
        state,
        interval,
        advance,
        program,
        quantum,
        collected,
    );
    const next = try e.tuple(state, &.{
        try e.b.reference(committed), try e.binary(.integer_sub, remaining, e.one),
    });
    // The actual predecessor is a retained call argument until the source
    // transition commits. It is shared storage, never a shadow execution.
    const run = try defineWithHooksRun(
        e,
        active,
        input,
        advance,
        next,
        commit,
        after,
        program,
        quantum,
        stepped,
        committed,
    );
    const work = try e.when(try e.binary(.equal, remaining, e.zero), collect, run);
    const tag = try statusTag(e, m, input);
    const idle = try e.b.pure(saved);
    const live = try e.when(try e.binary(.equal, tag, try e.b.constant(
        u32,
        @backingInt(data.process_state.Status.active),
    )), work, try e.when(try e.binary(.equal, tag, try e.b.constant(u32, @backingInt(
        data.process_state.Status.unwinding,
    ))), work, idle));
    try e.b.define(advance, try e.when(try e.binary(
        .less,
        try m.field(e, input, .work),
        quantum,
    ), live, idle));
}

fn emitDispatch(
    e: Author,
    m: anytype,
    life: anytype,
    collector: anytype,
    observe: anytype,
    event_type: Id,
    cut_type: Id,
    cut_function: Id,
    state: Id,
    interval: Id,
    loop: Id,
    dispatch: Id,
    advance: Id,
    publish: Id,
    control_commit: Id,
) Error!void {
    const program = try e.param(dispatch, 0);
    const saved = try e.param(dispatch, 1);
    const input = try e.replace(
        try e.field(saved, 0),
        @backingInt(machines.Field.program),
        program,
    );
    const command = try e.param(dispatch, 2);
    const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
    var cases: [4]Case = undefined;
    inline for (@typeInfo(Command).@"union".field_types, 0..) |T, i| {
        const variable = try e.b.variable(try projection.schema(T, e.b));
        var body: Id = undefined;
        switch (i) {
            0 => body = try emitDispatchAdvance(
                e,
                m,
                life,
                collector,
                event_type,
                cut_type,
                cut_function,
                state,
                interval,
                advance,
                publish,
                control_commit,
                program,
                saved,
                input,
                variable,
            ),
            1, 2 => body = try emitDispatchObservation(
                e,
                m,
                observe,
                event_type,
                loop,
                program,
                saved,
                input,
                i,
            ),
            3 => body = try emitDispatchFinish(e, m, input, saved),
            else => unreachable,
        }
        cases[i] = .{ .variable = variable, .body = body };
    }
    try e.b.define(dispatch, try e.b.term(.{ .match_sum = .{
        .value = command,
        .cases = &cases,
    } }));
}

fn emitEntry(
    e: Author,
    m: anytype,
    life: anytype,
    event_type: Id,
    cut_type: Id,
    cut_function: Id,
    state: Id,
    interval: Id,
    loop: Id,
    entry: Id,
) Error!void {
    const initialized = try e.b.variable(m.schema);
    const args = try e.b.variable(try e.b.schema(.bytes));
    const restored = try e.b.variable(m.state);
    const start = try e.b.term(.{ .match_sum = .{ .value = try e.param(entry, 1), .cases = &.{
        .{ .variable = args, .body = try e.call(life.initialize, &.{
            try e.param(entry, 0), try e.b.reference(args),
        }) },
        .{ .variable = restored, .body = try e.call(m.hydrate, &.{
            try e.param(entry, 0), try e.b.reference(restored),
        }) },
    } } });
    const machine = try e.b.reference(initialized);
    const cut = try e.b.variable(cut_type);
    const saved = try e.tuple(state, &.{ machine, interval });
    try e.b.define(
        entry,
        try e.b.bind(
            initialized,
            start,
            try e.b.bind(
                cut,
                try e.call(cut_function, &.{
                    machine,
                }),
                try e.call(
                    loop,
                    &.{
                        try e.param(entry, 0),
                        saved,
                        try e.variant(event_type, 0, try e.b.reference(cut)),
                    },
                ),
            ),
        ),
    );
}

fn emitDispatchBody(
    e: Author,
    event_type: Id,
    cut_function: Id,
    state: Id,
    advance: Id,
    publish: Id,
    program: Id,
    saved: Id,
    operation: Id,
    controlled: Id,
    advanced: Id,
    settled: Id,
    settle: anytype,
    after: Id,
    cut: Id,
) Error!Id {
    return try e.b.bind(
        advanced,
        try e.call(
            advance,
            &.{
                program,
                try e.tuple(
                    state,
                    &.{
                        try e.replace(
                            try e.b.reference(controlled),
                            @backingInt(machines.Field.work),
                            e.zero,
                        ),
                        try e.field(saved, 1),
                    },
                ),
                try e.field(operation, 1),
            },
        ),
        try e.b.bind(
            settled,
            settle,
            try e.b.bind(
                cut,
                try e.call(cut_function, &.{
                    after,
                }),
                try e.call(
                    publish,
                    &.{
                        program,                    saved,
                        try e.b.reference(settled),
                        try e.variant(
                            event_type,
                            0,
                            try e.b.reference(cut),
                        ),
                    },
                ),
            ),
        ),
    );
}

fn emitLoop(e: Author, command_type: Id, effect: Id, loop: Id, dispatch: Id) Error!void {
    const command = try e.b.variable(command_type);
    const exchange = try e.b.term(.{ .perform = .{
        .effect = effect,
        .payload = try e.param(loop, 2),
    } });
    try e.b.define(loop, try e.b.bind(command, exchange, try e.call(dispatch, &.{
        try e.param(loop, 0), try e.param(loop, 1), try e.b.reference(command),
    })));
}

fn emitCommits(e: Author, m: machines.Definition, commit: Id, control_commit: Id) Error!void {
    inline for (.{ commit, control_commit }, 0..) |function, kind| {
        const before = try e.param(function, 0);
        const after = try e.param(function, 1);
        const prior_work = try m.field(e, before, .work);
        const expected = if (kind == 0)
            try e.binary(.integer_add, prior_work, e.one)
        else
            prior_work;
        try e.b.define(function, try e.when(try e.binary(
            .equal,
            try m.field(e, after, .work),
            expected,
        ), try e.b.pure(after), try e.fail()));
    }
}

fn emitDispatchAdvance(
    e: Author,
    m: machines.Definition,
    life: anytype,
    collector: anytype,
    event_type: Id,
    cut_type: Id,
    cut_function: Id,
    state: Id,
    interval: Id,
    advance: Id,
    publish: Id,
    control_commit: Id,
    program: Id,
    saved: Id,
    input: Id,
    variable: Id,
) Error!Id {
    const operation = try e.b.reference(variable);
    const changed = try e.b.variable(m.schema);
    const controlled = try e.b.variable(m.schema);
    const advanced = try e.b.variable(state);
    const settled = try e.b.variable(state);
    const collected = try e.b.variable(m.schema);
    const advanced_state = try e.b.reference(advanced);
    const advanced_machine = try e.field(advanced_state, 0);
    const tag = try statusTag(e, m, advanced_machine);
    const retain = try e.b.pure(advanced_state);
    const collect = try e.b.bind(collected, try e.call(
        collector.run,
        &.{advanced_machine},
    ), try e.b.pure(try e.tuple(state, &.{ try e.b.reference(collected), interval })));
    const settle = try defineWithHooksSettle(e, collect, tag, retain);
    const after = try e.field(try e.b.reference(settled), 0);
    const cut = try e.b.variable(cut_type);
    // Passing the original service state after advance keeps
    // the committed command predecessor in the real outer
    // continuation throughout control, cloning, and cleanup.
    var body = try emitDispatchBody(
        e,
        event_type,
        cut_function,
        state,
        advance,
        publish,
        program,
        saved,
        operation,
        controlled,
        advanced,
        settled,
        settle,
        after,
        cut,
    );
    body = try e.b.bind(controlled, try e.call(
        control_commit,
        &.{ input, try e.b.reference(changed) },
    ), body);
    const controls = try dispatchControls(e, life, input);
    body = try e.b.bind(changed, try e.b.term(.{ .match_sum = .{
        .value = try e.field(operation, 0),
        .cases = &controls,
    } }), body);
    return body;
}

const DispatchCase = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));

fn dispatchControls(e: Author, life: anytype, input: Id) Error![4]DispatchCase {
    var controls: [4]DispatchCase = undefined;
    inline for (@typeInfo(Control).@"union".field_types, 0..) |C, j| {
        const arg = try e.b.variable(try projection.schema(C, e.b));
        const call = switch (j) {
            0 => try e.b.pure(input),
            1 => try e.call(life.respond, &.{ input, try e.b.reference(arg) }),
            2 => try e.call(life.resume_yield, &.{input}),
            3 => try e.call(life.cancel, &.{ input, try e.b.reference(arg) }),
            else => unreachable,
        };
        controls[j] = .{ .variable = arg, .body = call };
    }
    return controls;
}

fn emitService(
    e: Author,
    m: machines.Definition,
    life: anytype,
    step: anytype,
    active: Id,
    collector: anytype,
    observe: Id,
    d: Definition,
    cut_type: Id,
    interval: Id,
) Error!Id {
    try emitAdvance(e, m, step, active, collector, d.state, interval, d.advance, d.commit);
    try emitDispatch(
        e,
        m,
        life,
        collector,
        observe,
        d.event,
        cut_type,
        d.cut,
        d.state,
        interval,
        d.loop,
        d.dispatch,
        d.advance,
        d.publish,
        d.control_commit,
    );
    const entry = try e.b.declare(&.{
        m.program, try projection.schema(Initial, e.b),
    }, d.state, &.{d.effect}, &.{});
    try emitEntry(e, m, life, d.event, cut_type, d.cut, d.state, interval, d.loop, entry);
    return entry;
}

fn emitDispatchObservation(
    e: Author,
    m: machines.Definition,
    observe: Id,
    event_type: Id,
    loop: Id,
    program: Id,
    saved: Id,
    input: Id,
    comptime i: usize,
) Error!Id {
    const output = try e.b.variable(if (i == 1) try projection.schema(
        @import("observe.zig").Observation,
        e.b,
    ) else m.state);
    return try e.b.bind(output, try e.call(
        if (i == 1) observe else m.project,
        &.{input},
    ), try e.call(loop, &.{ program, saved, try e.variant(
        event_type,
        if (i == 1) 1 else 2,
        try e.b.reference(output),
    ) }));
}

fn emitDispatchFinish(e: Author, m: machines.Definition, input: Id, saved: Id) Error!Id {
    const tag = try statusTag(e, m, input);
    var body = try e.fail();
    inline for (.{
        data.process_state.Status.completed,
        data.process_state.Status.failed,
        data.process_state.Status.cancelled,
    }) |s| body = try e.when(try e.binary(
        .equal,
        tag,
        try e.b.constant(u32, @backingInt(s)),
    ), try e.b.pure(saved), body);
    return body;
}
