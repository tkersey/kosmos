//! Guest disposal and exit traversal, authored as ordinary Horos computation.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const graphs = @import("graph.zig");
const control = @import("control.zig");
const edges = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const Reason = @FieldType(g.Exit, "reason");
const field = edges.field;
pub const Definition = struct { position: Id, begin: Id, outermost: Id, discarded: Id, remember_failure: Id, fail_current: Id, dispose: Id, returned_disposal: Id, step: Id, cleanup: @import("cleanup.zig").Definition };
pub fn declare(b: *source.Builder, m: machines.Definition) Error!Definition {
    const ref = try projection.schema(g.NodeRef, b);
    const maybe = try projection.schema(?g.NodeRef, b);
    const values = try projection.schema([]const g.Value, b);
    return .{
        .cleanup = try @import("cleanup.zig").declare(b, m),
        .position = try b.declare(&.{ m.schema, maybe, values }, m.schema, &.{}, &.{}),
        .begin = try b.declare(&.{ m.schema, try projection.schema(Reason, b), maybe, maybe, values }, m.schema, &.{}, &.{}),
        .outermost = try b.declare(&.{ m.schema, ref }, ref, &.{}, &.{}),
        .discarded = try b.declare(&.{try projection.schema(g.Exit, b)}, values, &.{}, &.{}),
        .remember_failure = try b.declare(&.{ m.schema, try projection.schema(g.Value, b) }, m.schema, &.{}, &.{}),
        .fail_current = try b.declare(&.{ m.schema, try projection.schema(g.Value, b) }, m.schema, &.{}, &.{}),
        .dispose = try b.declare(&.{ m.schema, ref, try projection.schema(g.Control, b), m.frames.schema, try projection.schema(@FieldType(data.activation.Terminator, "dispose"), b) }, m.schema, &.{}, &.{}),
        .returned_disposal = try b.declare(&.{ m.schema, try projection.schema(@FieldType(g.Node, "disposal_return"), b), try projection.schema(g.Value, b) }, m.schema, &.{}, &.{}),
        .step = try b.declare(&.{m.schema}, m.schema, &.{}, &.{}),
    };
}
pub fn tag(e: Author, value: Id) Error!Id {
    return e.b.primitive(e.integer, .variant_tag, &.{value}, 0);
}
pub fn is(e: Author, value: Id, n: u64) Error!Id {
    return e.binary(.equal, try tag(e, value), try e.b.constant(u64, n));
}
pub fn some(e: Author, ref: Id) Error!Id {
    return e.variant(try projection.schema(?g.NodeRef, e.b), 1, ref);
}
pub fn empty(e: Author) Error!Id {
    return e.literal([]const g.Value, &.{});
}
pub fn seq(e: Author, values: []const Id) Error!Id {
    return e.b.primitive(try projection.schema([]const g.Value, e.b), .sequence, values, 0);
}
pub fn concat(e: Author, a: Id, b: Id) Error!Id {
    return e.b.primitive(try projection.schema([]const g.Value, e.b), .sequence_concat, &.{ a, b }, 0);
}
fn tailOf(e: Author, values: Id) Error!Id {
    const t = try projection.schema([]const g.Value, e.b);
    const pair = try e.b.schema(.{ .product = &.{ try projection.schema(g.Value, e.b), t } });
    const optional = try e.b.schema(.{ .sum = &.{ e.unit, pair } });
    return e.field(try e.payload(try e.b.primitive(optional, .sequence_pop, &.{values}, 0), 1), 1);
}
pub fn status(e: Author, m: machines.Definition, input: Id, value: data.process_state.Status) Error!Id {
    return e.replace(input, @backingInt(machines.Field.header), try e.replace(try m.field(e, input, .header), machines.index(machines.Header, "status"), try e.literal(data.process_state.Status, value)));
}
pub fn root(e: Author, m: machines.Definition, input: Id, comptime name: []const u8, value: Id) Error!Id {
    return control.withRoots(e, input, try e.replace(try control.roots(e, m, input), machines.index(g.Roots, name), value));
}
pub fn emit(b: *source.Builder, m: machines.Definition, d: Definition, calls: control.Definition) Error!void {
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const captures = try @import("captures.zig").define(b, m);
    const node_type = try projection.schema(g.Node, b);
    const ref_type = try projection.schema(g.NodeRef, b);
    const values_type = try projection.schema([]const g.Value, b);
    const null_ref = try e.literal(?g.NodeRef, null);
    {
        const input = try e.param(d.position, 0);
        const appended = try b.variable(graph.appended);
        var changed = try root(e, m, try e.field(try b.reference(appended), 0), "current", try some(e, try e.field(try b.reference(appended), 1)));
        changed = try root(e, m, changed, "pending", null_ref);
        changed = try root(e, m, changed, "evidence", null_ref);
        const record = try graphs.record(e, .unwind, &.{ try e.param(d.position, 1), try e.param(d.position, 2) });
        try b.define(d.position, try b.bind(appended, try e.call(graph.append, &.{ input, record }), try b.pure(try status(e, m, changed, .unwinding))));
    }
    {
        const input = try e.param(d.begin, 0);
        const appended = try b.variable(graph.appended);
        var exit = try e.literal(g.Exit, .{ .reason = .abandoned });
        exit = try e.replace(exit, 0, try e.param(d.begin, 1));
        exit = try e.replace(exit, machines.index(g.Exit, "stop"), try e.param(d.begin, 3));
        exit = try e.replace(exit, machines.index(g.Exit, "outer"), try field(e, try control.roots(e, m, input), g.Roots, "exit"));
        const changed = try root(e, m, try e.field(try b.reference(appended), 0), "exit", try some(e, try e.field(try b.reference(appended), 1)));
        try b.define(d.begin, try b.bind(appended, try e.call(graph.append, &.{ input, try e.variant(node_type, @backingInt(g.NodeTag.exit), exit) }), try e.call(d.position, &.{ changed, try e.param(d.begin, 2), try e.param(d.begin, 4) })));
    }
    {
        const input = try e.param(d.outermost, 0);
        const ref = try e.param(d.outermost, 1);
        const record = try b.variable(node_type);
        const outer = try field(e, try e.payload(try b.reference(record), @backingInt(g.NodeTag.exit)), g.Exit, "outer");
        try b.define(d.outermost, try b.bind(record, try e.call(graph.record, &.{ input, ref }), try e.when(try is(e, outer, 0), try b.pure(ref), try e.call(d.outermost, &.{ input, try e.payload(outer, 1) }))));
    }
    {
        const exit = try e.param(d.discarded, 0);
        const prior = try field(e, exit, g.Exit, "discarded");
        const reason = try e.field(exit, 0);
        const normal = try e.payload(reason, 0);
        const keep = try b.pure(prior);
        try b.define(d.discarded, try e.when(try is(e, reason, 0), try e.when(try is(e, try e.field(normal, 1), 3), try b.pure(try concat(e, prior, try seq(e, &.{normal}))), keep), keep));
    }
    {
        const input = try e.param(d.remember_failure, 0);
        const value = try e.param(d.remember_failure, 1);
        const ref = try b.variable(ref_type);
        const record = try b.variable(node_type);
        const exit = try e.payload(try b.reference(record), @backingInt(g.NodeTag.exit));
        const discarded = try b.variable(values_type);
        var changed = try e.replace(exit, machines.index(g.Exit, "cleanup_failures"), try concat(e, try field(e, exit, g.Exit, "cleanup_failures"), try seq(e, &.{value})));
        changed = try e.replace(changed, machines.index(g.Exit, "discarded"), try b.reference(discarded));
        const selected = try b.variable(try projection.schema(g.Exit, b));
        const failure = try e.replace(try e.replace(changed, 0, try e.variant(try projection.schema(Reason, b), 1, value)), machines.index(g.Exit, "stop"), null_ref);
        const choose = try e.when(try is(e, try e.field(exit, 0), 0), try b.pure(failure), try e.when(try is(e, try e.field(exit, 0), 3), try b.pure(failure), try b.pure(changed)));
        var body = try b.bind(selected, choose, try e.call(graph.replace, &.{ input, try b.reference(ref), try e.variant(node_type, @backingInt(g.NodeTag.exit), try b.reference(selected)) }));
        body = try b.bind(discarded, try e.call(d.discarded, &.{exit}), body);
        body = try b.bind(record, try e.call(graph.record, &.{ input, try b.reference(ref) }), body);
        try b.define(d.remember_failure, try b.bind(ref, try e.call(d.outermost, &.{ input, try e.payload(try field(e, try control.roots(e, m, input), g.Roots, "exit"), 1) }), body));
    }
    {
        const input = try e.param(d.fail_current, 0);
        const current = try e.payload(try field(e, try control.roots(e, m, input), g.Roots, "current"), 1);
        const element = try b.variable(m.nodes.element);
        const saved = try e.payload(try e.field(try b.reference(element), 0), 0);
        const discarded = try b.variable(values_type);
        const changed = try b.variable(m.schema);
        const value = try e.param(d.fail_current, 1);
        const prior_exit = try field(e, try control.roots(e, m, input), g.Roots, "exit");
        const remember = try e.when(try is(e, prior_exit, 0), try b.pure(input), try e.call(d.remember_failure, &.{ input, value }));
        var body = try b.bind(changed, remember, try e.call(d.begin, &.{ try b.reference(changed), try e.variant(try projection.schema(Reason, b), 1, value), try e.field(saved, 1), null_ref, try b.reference(discarded) }));
        body = try b.bind(discarded, try e.call(m.frames.discards, &.{try e.payload(try e.field(try b.reference(element), 1), 1)}), body);
        try b.define(d.fail_current, try b.bind(element, try e.call(graph.element, &.{ input, current }), body));
    }
    {
        const input = try e.param(d.dispose, 0);
        const current = try e.param(d.dispose, 1);
        const saved = try e.param(d.dispose, 2);
        const frame = try e.param(d.dispose, 3);
        const operation = try e.param(d.dispose, 4);
        const value = try b.variable(try projection.schema(g.Value, b));
        const taken = try b.variable(captures.taken);
        const captured = try b.variable(m.schema);
        const activated = try b.variable(m.schema);
        const token = try e.field(try b.reference(taken), 1);
        var body = try b.bind(activated, try e.call(captures.activate, &.{ try b.reference(captured), token, current }), try e.call(d.begin, &.{ try b.reference(activated), try e.literal(Reason, .abandoned), try field(e, token, g.Capture, "capture"), try some(e, current), try empty(e) }));
        body = try b.bind(captured, try e.call(calls.capture, &.{ try e.field(try b.reference(taken), 0), current, saved, frame, try e.field(operation, 1) }), body);
        body = try b.bind(taken, try e.call(captures.take, &.{ input, try b.reference(value) }), body);
        try b.define(d.dispose, try b.bind(value, try e.call(m.frames.read, &.{ frame, try e.field(operation, 0) }), body));
    }
    {
        const input = try e.param(d.returned_disposal, 0);
        const frame = try e.param(d.returned_disposal, 1);
        const value = try e.param(d.returned_disposal, 2);
        const prior = try e.field(frame, 2);
        const selected = try b.variable(values_type);
        try b.define(d.returned_disposal, try b.bind(selected, try e.when(try is(e, try e.field(value, 1), 3), try b.pure(try concat(e, try seq(e, &.{value}), prior)), try b.pure(prior)), try e.call(d.position, &.{ input, try e.field(frame, 1), try b.reference(selected) })));
    }
    // Flatten owned children in their original custody order.
    const owned = try b.declare(&.{values_type}, values_type, &.{}, &.{});
    {
        const values = try e.param(owned, 0);
        const head = try e.required(values, e.zero);
        const tail = try tailOf(e, values);
        const rest = try b.variable(values_type);
        const body = try b.bind(rest, try e.call(owned, &.{tail}), try e.when(try is(e, try e.field(head, 1), 3), try b.pure(try concat(e, try seq(e, &.{head}), try b.reference(rest))), try b.pure(try b.reference(rest))));
        try b.define(owned, try e.when(try e.binary(.equal, try b.primitive(e.integer, .sequence_length, &.{values}, 0), e.zero), try b.pure(try empty(e)), body));
    }
    {
        const input = try e.param(d.step, 0);
        const roots = try control.roots(e, m, input);
        const current_node = try b.variable(node_type);
        const current = try e.payload(try b.reference(current_node), @backingInt(g.NodeTag.unwind));
        const cursor = try e.field(current, 0);
        const current_values = try e.field(current, 1);
        const exit_ref = try e.payload(try field(e, roots, g.Roots, "exit"), 1);
        const exit_node = try b.variable(node_type);
        const exit = try e.payload(try b.reference(exit_node), @backingInt(g.NodeTag.exit));
        const root_ref = try b.variable(ref_type);
        const root_node = try b.variable(node_type);
        const root_exit = try e.payload(try b.reference(root_node), @backingInt(g.NodeTag.exit));
        const discarded = try field(e, root_exit, g.Exit, "discarded");
        const changed = try b.variable(m.schema);
        const drain = try b.bind(changed, try e.call(graph.replace, &.{ input, try b.reference(root_ref), try e.variant(node_type, @backingInt(g.NodeTag.exit), try e.replace(root_exit, machines.index(g.Exit, "discarded"), try empty(e))) }), try e.call(d.position, &.{ try b.reference(changed), cursor, try concat(e, discarded, current_values) }));
        const head = try e.required(current_values, e.zero);
        const tail = try tailOf(e, current_values);
        const owned_node = try b.variable(node_type);
        const record = try b.reference(owned_node);
        var disposal = try e.fail();
        {
            const taken = try b.variable(captures.taken);
            const after = try b.variable(graph.appended);
            const token = try e.field(try b.reference(taken), 1);
            const frame = try graphs.record(e, .disposal_return, &.{ try e.field(head, 0), cursor, tail });
            var body = try b.bind(changed, try e.call(captures.activate, &.{ try e.field(try b.reference(after), 0), token, try e.field(try b.reference(after), 1) }), try e.call(d.position, &.{ try b.reference(changed), try field(e, token, g.Capture, "capture"), try empty(e) }));
            body = try b.bind(after, try e.call(graph.append, &.{ try e.field(try b.reference(taken), 0), frame }), body);
            body = try b.bind(taken, try e.call(captures.take, &.{ input, head }), body);
            disposal = try e.when(try is(e, record, @backingInt(g.NodeTag.one_shot)), body, disposal);
        }
        inline for ([_]g.NodeTag{ .aggregate, .computation, .package }) |kind| {
            const payload = try e.payload(record, @backingInt(kind));
            const environment = try b.variable(node_type);
            const children = switch (kind) {
                .aggregate => try e.field(payload, 2),
                .package => try seq(e, &.{try field(e, payload, @FieldType(g.Node, "package"), "continuation")}),
                .computation => try e.field(try e.payload(try b.reference(environment), @backingInt(g.NodeTag.environment)), 0),
                else => unreachable,
            };
            const filtered = try b.variable(values_type);
            var body = try b.bind(filtered, try e.call(owned, &.{children}), try e.call(d.position, &.{ input, cursor, try concat(e, try b.reference(filtered), tail) }));
            if (kind == .computation) body = try b.bind(environment, try e.call(graph.record, &.{ input, try e.field(payload, 1) }), body);
            disposal = try e.when(try is(e, record, @backingInt(kind)), body, disposal);
        }
        disposal = try e.when(try is(e, record, @backingInt(g.NodeTag.resource)), try e.call(d.position, &.{ input, cursor, tail }), disposal);
        disposal = try b.bind(owned_node, try e.call(graph.record, &.{ input, try e.field(try e.payload(try e.field(head, 1), 3), 0) }), disposal);
        const selected = try b.variable(m.nodes.element);
        const selected_record = try e.field(try b.reference(selected), 0);
        var walk = try e.fail();
        inline for ([_]g.NodeTag{ .control, .continuation, .attachment, .region_scope, .injection, .disposal_return }) |kind| {
            const payload = try e.payload(selected_record, @backingInt(kind));
            const parent = switch (kind) {
                .control, .continuation => try e.field(payload, 1),
                .attachment, .region_scope => try e.field(payload, 2),
                .injection => try some(e, try e.field(payload, 0)),
                .disposal_return => try e.field(payload, 1),
                else => unreachable,
            };
            var body = try e.call(d.position, &.{ input, parent, if (kind == .disposal_return) try e.field(payload, 2) else try empty(e) });
            if (kind == .control or kind == .continuation) {
                const values = try b.variable(values_type);
                body = try b.bind(values, try e.call(m.frames.discards, &.{try e.payload(try e.field(try b.reference(selected), 1), 1)}), try e.call(d.position, &.{ input, parent, try b.reference(values) }));
            }
            walk = try e.when(try is(e, selected_record, @backingInt(kind)), body, walk);
        }
        walk = try e.when(try is(e, selected_record, @backingInt(g.NodeTag.protection)), try e.call(d.cleanup.run, &.{ input, try e.payload(selected_record, @backingInt(g.NodeTag.protection)), exit_ref, root_exit }), walk);
        walk = try e.when(try is(e, selected_record, @backingInt(g.NodeTag.cleanup_return)), try e.call(d.cleanup.crossed, &.{ input, try e.payload(selected_record, @backingInt(g.NodeTag.cleanup_return)), exit }), walk);
        walk = try b.bind(selected, try e.call(graph.element, &.{ input, try e.payload(cursor, 1) }), walk);
        const terminal = try b.variable(graph.appended);
        const terminal_input = try e.field(try b.reference(terminal), 0);
        const terminal_roots = try e.replace(try e.literal(g.Roots, .{}), machines.index(g.Roots, "exit"), try some(e, try e.field(try b.reference(terminal), 1)));
        const terminal_status = try e.when(try is(e, try e.field(root_exit, 0), 1), try b.pure(try status(e, m, try control.withRoots(e, terminal_input, terminal_roots), .failed)), try b.pure(try status(e, m, try control.withRoots(e, terminal_input, terminal_roots), .cancelled)));
        const finish = try b.bind(terminal, try e.call(graph.append, &.{ input, try b.reference(root_node) }), terminal_status);
        const onward = try e.when(try is(e, cursor, 0), finish, walk);
        const restored = try status(e, m, try root(e, m, input, "exit", try field(e, exit, g.Exit, "outer")), .active);
        const resume_saved = try e.when(try is(e, try e.field(exit, 0), 0), try e.call(calls.return_to, &.{ restored, cursor, try e.payload(try e.field(exit, 0), 0) }), try e.call(calls.resume_continuation, &.{ restored, try e.payload(cursor, 1), try e.literal(g.Value, .{ .schema = 0, .body = .{ .scalar = @splat(0) } }) }));
        const stop = try field(e, exit, g.Exit, "stop");
        const both_present = try e.when(try e.binary(.equal, try e.field(try e.payload(cursor, 1), 0), try e.field(try e.payload(stop, 1), 0)), resume_saved, onward);
        const stopped = try e.when(try e.binary(.equal, try tag(e, cursor), try tag(e, stop)), try e.when(try is(e, cursor, 0), resume_saved, both_present), onward);
        const progress = try e.when(try is(e, try e.field(exit, 0), 0), stopped, try e.when(try is(e, try e.field(exit, 0), 3), stopped, onward));
        var body = try e.when(try e.binary(.less, e.zero, try b.primitive(e.integer, .sequence_length, &.{discarded}, 0)), drain, try e.when(try e.binary(.less, e.zero, try b.primitive(e.integer, .sequence_length, &.{current_values}, 0)), disposal, progress));
        body = try b.bind(root_node, try e.call(graph.record, &.{ input, try b.reference(root_ref) }), body);
        body = try b.bind(root_ref, try e.call(d.outermost, &.{ input, exit_ref }), body);
        body = try b.bind(exit_node, try e.call(graph.record, &.{ input, exit_ref }), body);
        try b.define(d.step, try b.bind(current_node, try e.call(graph.record, &.{ input, try e.payload(try field(e, roots, g.Roots, "current"), 1) }), body));
    }
    try @import("cleanup.zig").emit(b, m, d.cleanup, d, calls);
}
