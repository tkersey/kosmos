//! Ordinary authored cleanup obligations and the exit information they observe.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const graphs = @import("graph.zig");
const control = @import("control.zig");
const edges = @import("edges.zig");
const unwind = @import("unwind.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const field = edges.field;
const some = unwind.some;
const empty = unwind.empty;
const seq = unwind.seq;
const concat = unwind.concat;
const is = unwind.is;
const root = unwind.root;
const status = unwind.status;
pub const Definition = struct { protect: Id, information: Id, run: Id, returned: Id, crossed: Id, unlink: Id, cancel: Id };
pub fn declare(b: *source.Builder, m: machines.Definition) Error!Definition {
    const ref = try projection.schema(g.NodeRef, b);
    const value_result = (try @import("values.zig").define(b, m)).result;
    return .{
        .protect = try b.declare(&.{ m.schema, ref, try projection.schema(g.Control, b), m.frames.schema, try projection.schema(@FieldType(data.activation.Terminator, "protect"), b) }, m.schema, &.{}, &.{}),
        .information = try b.declare(&.{ m.schema, try b.scalar(u64), try projection.schema(g.Exit, b) }, value_result, &.{}, &.{}),
        .run = try b.declare(&.{ m.schema, try projection.schema(@FieldType(g.Node, "protection"), b), ref, try projection.schema(g.Exit, b) }, m.schema, &.{}, &.{}),
        .returned = try b.declare(&.{ m.schema, try projection.schema(@FieldType(g.Node, "cleanup_return"), b) }, m.schema, &.{}, &.{}),
        .crossed = try b.declare(&.{ m.schema, try projection.schema(@FieldType(g.Node, "cleanup_return"), b), try projection.schema(g.Exit, b) }, m.schema, &.{}, &.{}),
        .unlink = try b.declare(&.{ m.schema, ref, ref }, m.schema, &.{}, &.{}),
        .cancel = try b.declare(&.{ m.schema, try projection.schema(data.invocation.Reason, b) }, m.schema, &.{}, &.{}),
    };
}
fn shapes(e: Author, m: machines.Definition, input: Id) Error!Id {
    return field(e, try edges.code(e, try m.field(e, input, .program)), data.activation.Program, "schemas");
}
fn parameters(e: Author, m: machines.Definition, input: Id, value: Id) Error!Id {
    const schema = try e.required(try shapes(e, m, input), try e.field(value, 0));
    const computation = try e.payload(try e.payload(schema, @backingInt(data.program.SchemaTag.internal)), @backingInt(data.program.InternalTag.computation));
    return field(e, computation, data.program.ComputationType, "parameters");
}
pub fn emit(b: *source.Builder, m: machines.Definition, d: Definition, u: unwind.Definition, calls: control.Definition) Error!void {
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const values = try @import("values.zig").define(b, m);
    const aggregate = try @import("aggregate.zig").define(b, m);
    const codec = try @import("codec.zig").define(b, m);
    const edge = try edges.define(b, m);
    const node = try projection.schema(g.Node, b);
    const value = try projection.schema(g.Value, b);
    const maybe_value = try projection.schema(?g.Value, b);
    const ref = try projection.schema(g.NodeRef, b);
    const maybe_ref = try projection.schema(?g.NodeRef, b);
    const vals = try projection.schema([]const g.Value, b);
    const null_ref = try e.literal(?g.NodeRef, null);
    const null_value = try e.literal(?g.Value, null);
    const obligation_type = @FieldType(g.Node, "obligation");
    const obligation_status = try projection.schema(@FieldType(obligation_type, "status"), b);
    {
        const input = try e.param(d.protect, 0);
        const current = try e.param(d.protect, 1);
        const saved = try e.param(d.protect, 2);
        const frame = try e.param(d.protect, 3);
        const operation = try e.param(d.protect, 4);
        const T = @FieldType(data.activation.Terminator, "protect");
        const body_value = try b.variable(value);
        const cleanup_value = try b.variable(value);
        const resource_value = try b.variable(maybe_value);
        const read_resource = try b.variable(value);
        const resource_slot = try field(e, operation, T, "resource");
        const read = try b.bind(read_resource, try e.call(m.frames.read, &.{ frame, try e.payload(resource_slot, 1) }), try b.pure(try e.variant(maybe_value, 1, try b.reference(read_resource))));
        const resource = try e.when(try is(e, resource_slot, 0), try b.pure(null_value), read);
        const obligation = try b.variable(graph.appended);
        const obligation_record = try graphs.record(e, .obligation, &.{ try e.field(saved, 0), try e.variant(maybe_value, 1, try b.reference(cleanup_value)), try b.reference(resource_value), try e.variant(obligation_status, 0, e.unit_value) });
        const loan_pair_type = try b.schema(.{ .product = &.{ m.schema, maybe_ref } });
        const loan_pair = try b.variable(loan_pair_type);
        const loan_node = try b.variable(graph.appended);
        const loan_descriptor = try field(e, operation, T, "loan_region");
        const after_obligation = try e.field(try b.reference(obligation), 0);
        const loan_record = try graphs.record(e, .region, &.{ try e.payload(loan_descriptor, 1), try e.field(saved, 3), try e.literal([]const g.OwnedRef, &.{}) });
        const loan = try e.when(try is(e, loan_descriptor, 0), try b.pure(try e.tuple(loan_pair_type, &.{ after_obligation, null_ref })), try b.bind(loan_node, try e.call(graph.append, &.{ after_obligation, loan_record }), try b.pure(try e.tuple(loan_pair_type, &.{ try e.field(try b.reference(loan_node), 0), try some(e, try e.field(try b.reference(loan_node), 1)) }))));
        const loan_ref = try e.field(try b.reference(loan_pair), 1);
        const after_loan = try e.field(try b.reference(loan_pair), 0);
        const arguments = try b.variable(vals);
        const prefix_pair_type = try b.schema(.{ .product = &.{ m.schema, vals } });
        const prefix_pair = try b.variable(prefix_pair_type);
        const borrow = try b.variable(graph.appended);
        const borrowed_schema = try e.required(try parameters(e, m, input, try b.reference(body_value)), e.zero);
        const owned_resource = try e.payload(try b.reference(resource_value), 1);
        const borrow_record = try graphs.record(e, .borrow, &.{ borrowed_schema, try e.field(try e.payload(try e.field(owned_resource, 1), 3), 0), try e.payload(loan_ref, 1) });
        const borrowed_value = try graphs.value(e, borrowed_schema, try e.field(try b.reference(borrow), 1), false);
        const prefix = try e.when(try is(e, try b.reference(resource_value), 0), try b.pure(try e.tuple(prefix_pair_type, &.{ after_loan, try b.reference(arguments) })), try b.bind(borrow, try e.call(graph.append, &.{ after_loan, borrow_record }), try b.pure(try e.tuple(prefix_pair_type, &.{ try e.field(try b.reference(borrow), 0), try concat(e, try seq(e, &.{borrowed_value}), try b.reference(arguments)) }))));
        const captured = try b.variable(m.schema);
        const protection = try b.variable(graph.appended);
        const region = try b.variable(maybe_ref);
        const protection_record = try graphs.record(e, .protection, &.{ try e.field(saved, 0), try e.tuple(try projection.schema(g.OwnedRef, b), &.{try e.field(try b.reference(obligation), 1)}), try some(e, current), try e.field(saved, 2), try e.field(saved, 3), loan_ref });
        var body = try b.bind(region, try e.when(try is(e, loan_ref, 0), try b.pure(try e.field(saved, 3)), try b.pure(loan_ref)), try e.call(calls.apply, &.{ try e.field(try b.reference(protection), 0), try b.reference(body_value), try e.field(try b.reference(prefix_pair), 1), try some(e, try e.field(try b.reference(protection), 1)), try e.field(saved, 2), try b.reference(region) }));
        body = try b.bind(protection, try e.call(graph.append, &.{ try b.reference(captured), protection_record }), body);
        body = try b.bind(captured, try e.call(calls.capture, &.{ try e.field(try b.reference(prefix_pair), 0), current, saved, frame, try field(e, operation, T, "next") }), body);
        body = try b.bind(prefix_pair, prefix, body);
        body = try b.bind(arguments, try e.call(edge.collect, &.{ frame, try field(e, operation, T, "arguments") }), body);
        body = try b.bind(loan_pair, loan, body);
        body = try b.bind(obligation, try e.call(graph.append, &.{ input, obligation_record }), body);
        body = try b.bind(resource_value, resource, body);
        body = try b.bind(cleanup_value, try e.call(m.frames.read, &.{ frame, try field(e, operation, T, "cleanup") }), body);
        try b.define(d.protect, try b.bind(body_value, try e.call(m.frames.read, &.{ frame, try field(e, operation, T, "body") }), body));
    }
    {
        const input = try e.param(d.information, 0);
        const schema = try e.param(d.information, 1);
        const exit = try e.param(d.information, 2);
        const catalog = try shapes(e, m, input);
        const product = try e.payload(try e.required(catalog, schema), @backingInt(data.program.SchemaTag.product));
        const primary_schema = try e.required(product, e.zero);
        const optional_schema = try e.required(product, e.one);
        const failures_schema = try e.required(product, try b.constant(u64, 2));
        const primary_cases = try e.payload(try e.required(catalog, primary_schema), @backingInt(data.program.SchemaTag.sum));
        const unit_schema = try e.required(primary_cases, e.zero);
        const reason_schema = try e.required(primary_cases, try b.constant(u64, 2));
        const reason_cases = try e.payload(try e.required(catalog, reason_schema), @backingInt(data.program.SchemaTag.sum));
        const unit_value = try e.replace(try e.literal(g.Value, .{ .schema = 0, .body = .{ .scalar = @splat(0) } }), 0, unit_schema);
        const cancellation = try field(e, exit, g.Exit, "cancellation");
        const reason = try e.payload(cancellation, 1);
        const raw = try b.variable(try b.schema(.bytes));
        const prefix = try b.variable(try b.schema(.bytes));
        const payload = try b.variable(values.result);
        const encoded_reason = try b.variable(values.result);
        const reason_kind = try unwind.tag(e, reason);
        const choose_raw = try e.when(try is(e, reason, 0), try b.pure(try e.payload(reason, 0)), try b.pure(try e.payload(reason, 1)));
        var construct_reason = try b.bind(payload, try e.call(values.literal, &.{ input, try e.tuple(try projection.schema(data.program.Literal, b), &.{ try e.required(reason_cases, reason_kind), try e.concat(try b.reference(prefix), try b.reference(raw)) }) }), try e.call(aggregate.construct, &.{ try e.field(try b.reference(payload), 0), reason_schema, reason_kind, try seq(e, &.{try e.field(try b.reference(payload), 1)}) }));
        construct_reason = try b.bind(prefix, try e.call(codec.natural, &.{try b.primitive(e.integer, .blob_length, &.{try b.reference(raw)}, 0)}), construct_reason);
        construct_reason = try b.bind(raw, choose_raw, construct_reason);
        const choose_reason = try e.when(try is(e, cancellation, 0), try b.pure(try e.tuple(values.result, &.{ input, unit_value })), construct_reason);
        const primary_value = try b.variable(value);
        const primary = try b.variable(values.result);
        const optional = try b.variable(values.result);
        const failures = try b.variable(values.result);
        const reason_value = try e.field(try b.reference(encoded_reason), 1);
        const primary_reason = try e.field(exit, 0);
        const choose_primary = try e.when(try is(e, primary_reason, 1), try b.pure(try e.payload(primary_reason, 1)), try e.when(try is(e, primary_reason, 2), try b.pure(reason_value), try b.pure(unit_value)));
        var body = try e.call(aggregate.construct, &.{ try e.field(try b.reference(failures), 0), schema, e.zero, try seq(e, &.{ try e.field(try b.reference(primary), 1), try e.field(try b.reference(optional), 1), try e.field(try b.reference(failures), 1) }) });
        body = try b.bind(failures, try e.call(aggregate.construct, &.{ try e.field(try b.reference(optional), 0), failures_schema, e.zero, try field(e, exit, g.Exit, "cleanup_failures") }), body);
        body = try b.bind(optional, try e.call(aggregate.construct, &.{ try e.field(try b.reference(primary), 0), optional_schema, try unwind.tag(e, cancellation), try seq(e, &.{reason_value}) }), body);
        body = try b.bind(primary, try e.call(aggregate.construct, &.{ try e.field(try b.reference(encoded_reason), 0), primary_schema, try unwind.tag(e, primary_reason), try seq(e, &.{try b.reference(primary_value)}) }), body);
        body = try b.bind(primary_value, choose_primary, body);
        try b.define(d.information, try b.bind(encoded_reason, choose_reason, body));
    }
    {
        const input = try e.param(d.run, 0);
        const protection = try e.param(d.run, 1);
        const obligation_ref = try e.field(try e.field(protection, 1), 0);
        const record = try b.variable(node);
        const obligation = try e.payload(try b.reference(record), @backingInt(g.NodeTag.obligation));
        const cleanup = try e.payload(try e.field(obligation, 1), 1);
        const resource = try e.field(obligation, 2);
        const frame = try b.variable(graph.appended);
        const changed = try b.variable(m.schema);
        var transferred = try e.replace(obligation, 1, null_value);
        transferred = try e.replace(transferred, 2, null_value);
        transferred = try e.replace(transferred, 3, try e.variant(obligation_status, 1, try e.field(try b.reference(frame), 1)));
        const info = try b.variable(values.result);
        const arguments = try b.variable(vals);
        const base_args = try seq(e, &.{try e.field(try b.reference(info), 1)});
        var body = try b.bind(arguments, try e.when(try is(e, resource, 0), try b.pure(base_args), try b.pure(try concat(e, base_args, try seq(e, &.{try e.payload(resource, 1)})))), try e.call(calls.apply, &.{ try status(e, m, try e.field(try b.reference(info), 0), .active), cleanup, try b.reference(arguments), try some(e, try e.field(try b.reference(frame), 1)), try e.field(protection, 3), try e.field(protection, 4) }));
        body = try b.bind(info, try e.call(d.information, &.{ try b.reference(changed), try e.required(try parameters(e, m, input, cleanup), e.zero), try e.param(d.run, 3) }), body);
        body = try b.bind(changed, try e.call(graph.replace, &.{ try e.field(try b.reference(frame), 0), obligation_ref, try e.variant(node, @backingInt(g.NodeTag.obligation), transferred) }), body);
        body = try b.bind(frame, try e.call(graph.append, &.{ input, try graphs.record(e, .cleanup_return, &.{ try e.field(protection, 1), try e.field(protection, 2), try e.param(d.run, 2) }) }), body);
        body = try e.when(try is(e, try e.field(obligation, 3), 0), body, try e.fail());
        try b.define(d.run, try b.bind(record, try e.call(graph.record, &.{ input, obligation_ref }), body));
    }
    {
        const input = try e.param(d.returned, 0);
        const frame = try e.param(d.returned, 1);
        const obligation_ref = try e.field(try e.field(frame, 0), 0);
        const record = try b.variable(node);
        const changed = try b.variable(m.schema);
        const obligation = try e.payload(try b.reference(record), @backingInt(g.NodeTag.obligation));
        const completed = try e.replace(obligation, 3, try e.variant(obligation_status, 2, e.unit_value));
        const restored = try root(e, m, try b.reference(changed), "exit", try some(e, try e.field(frame, 2)));
        try b.define(d.returned, try b.bind(record, try e.call(graph.record, &.{ input, obligation_ref }), try b.bind(changed, try e.call(graph.replace, &.{ input, obligation_ref, try e.variant(node, @backingInt(g.NodeTag.obligation), completed) }), try e.call(u.position, &.{ restored, try e.field(frame, 1), try empty(e) }))));
    }
    try emitExitCrossing(b, m, d, u);
    _ = ref;
}

fn emitExitCrossing(b: *source.Builder, m: machines.Definition, d: Definition, u: unwind.Definition) Error!void {
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const node = try projection.schema(g.Node, b);
    const ref = try projection.schema(g.NodeRef, b);
    const vals = try projection.schema([]const g.Value, b);
    const exit_type = try projection.schema(g.Exit, b);
    const reason_type = try projection.schema(@FieldType(g.Exit, "reason"), b);
    const obligation_status = try projection.schema(@FieldType(@FieldType(g.Node, "obligation"), "status"), b);
    const null_ref = try e.literal(?g.NodeRef, null);
    {
        const input = try e.param(d.unlink, 0);
        const retired = try e.param(d.unlink, 1);
        const cursor = try e.param(d.unlink, 2);
        const prior_node = try b.variable(node);
        const prior = try e.payload(try b.reference(prior_node), @backingInt(g.NodeTag.exit));
        const cursor_node = try b.variable(node);
        const current = try e.payload(try b.reference(cursor_node), @backingInt(g.NodeTag.exit));
        const outer = try e.payload(try field(e, current, g.Exit, "outer"), 1);
        const changed = try b.variable(m.schema);
        const active_node = try b.variable(node);
        const active_ref = try e.payload(try field(e, try control.roots(e, m, input), g.Roots, "exit"), 1);
        const active = try e.payload(try b.reference(active_node), @backingInt(g.NodeTag.exit));
        const selected_reason = try b.variable(reason_type);
        const selected_cancellation = try b.variable(try projection.schema(?data.invocation.Reason, b));
        const prior_reason = try e.field(prior, 0);
        const prior_cancellation = try field(e, prior, g.Exit, "cancellation");
        var merged = try e.replace(active, 0, try b.reference(selected_reason));
        merged = try e.replace(merged, machines.index(g.Exit, "cancellation"), try b.reference(selected_cancellation));
        merged = try e.replace(merged, machines.index(g.Exit, "cleanup_failures"), try concat(e, try field(e, prior, g.Exit, "cleanup_failures"), try field(e, active, g.Exit, "cleanup_failures")));
        merged = try e.replace(merged, machines.index(g.Exit, "stop"), null_ref);
        var merge = try e.call(graph.replace, &.{ try b.reference(changed), active_ref, try e.variant(node, @backingInt(g.NodeTag.exit), merged) });
        merge = try b.bind(selected_cancellation, try e.when(try is(e, prior_cancellation, 0), try b.pure(try field(e, active, g.Exit, "cancellation")), try b.pure(prior_cancellation)), merge);
        merge = try b.bind(selected_reason, try e.when(try is(e, prior_reason, 1), try b.pure(prior_reason), try b.pure(try e.literal(@FieldType(g.Exit, "reason"), .cancellation))), merge);
        merge = try b.bind(active_node, try e.call(graph.record, &.{ try b.reference(changed), active_ref }), merge);
        const keep = try b.pure(try b.reference(changed));
        const choose = try e.when(try is(e, prior_reason, 1), merge, try e.when(try is(e, prior_reason, 2), merge, try e.when(try is(e, prior_cancellation, 1), merge, keep)));
        const replacement = try e.replace(current, machines.index(g.Exit, "outer"), try field(e, prior, g.Exit, "outer"));
        const unlink = try b.bind(changed, try e.call(graph.replace, &.{ input, cursor, try e.variant(node, @backingInt(g.NodeTag.exit), replacement) }), choose);
        const walk = try e.when(try e.binary(.equal, try e.field(outer, 0), try e.field(retired, 0)), unlink, try e.call(d.unlink, &.{ input, retired, outer }));
        var body = try b.bind(cursor_node, try e.call(graph.record, &.{ input, cursor }), walk);
        body = try b.bind(prior_node, try e.call(graph.record, &.{ input, retired }), body);
        try b.define(d.unlink, try e.when(try e.binary(.equal, try e.field(cursor, 0), try e.field(retired, 0)), try b.pure(input), body));
    }
    {
        const input = try e.param(d.crossed, 0);
        const frame = try e.param(d.crossed, 1);
        const exit = try e.param(d.crossed, 2);
        const obligation_ref = try e.field(try e.field(frame, 0), 0);
        const prior_ref = try e.field(frame, 2);
        const obligation_node = try b.variable(node);
        const obligation = try e.payload(try b.reference(obligation_node), @backingInt(g.NodeTag.obligation));
        const prior_node = try b.variable(node);
        const prior = try e.payload(try b.reference(prior_node), @backingInt(g.NodeTag.exit));
        const discarded = try b.variable(vals);
        const changed = try b.variable(m.schema);
        const finished = try b.variable(m.schema);
        const completed_obligation = try e.replace(obligation, 3, try e.variant(obligation_status, 2, e.unit_value));
        var abandoned = try b.bind(finished, try e.call(graph.replace, &.{ try b.reference(changed), obligation_ref, try e.variant(node, @backingInt(g.NodeTag.obligation), completed_obligation) }), try e.call(u.position, &.{ try b.reference(finished), try e.field(frame, 1), try b.reference(discarded) }));
        abandoned = try b.bind(changed, try e.call(d.unlink, &.{ input, prior_ref, try e.payload(try field(e, try control.roots(e, m, input), g.Roots, "exit"), 1) }), abandoned);
        abandoned = try b.bind(discarded, try e.call(u.discarded, &.{prior}), abandoned);
        const failed_obligation = try e.replace(obligation, 3, try e.variant(obligation_status, 3, try e.payload(try e.field(exit, 0), 1)));
        var parent_failed = try e.replace(prior, 0, try e.field(exit, 0));
        parent_failed = try e.replace(parent_failed, machines.index(g.Exit, "stop"), null_ref);
        parent_failed = try e.replace(parent_failed, machines.index(g.Exit, "discarded"), try b.reference(discarded));
        const update_parent = try b.bind(discarded, try e.call(u.discarded, &.{prior}), try e.call(graph.replace, &.{ try b.reference(changed), prior_ref, try e.variant(node, @backingInt(g.NodeTag.exit), parent_failed) }));
        const choose_parent = try e.when(try is(e, try e.field(prior, 0), 0), update_parent, try e.when(try is(e, try e.field(prior, 0), 3), update_parent, try b.pure(try b.reference(changed))));
        var failure = try b.bind(finished, choose_parent, try e.call(u.position, &.{ try root(e, m, try b.reference(finished), "exit", try some(e, prior_ref)), try e.field(frame, 1), try empty(e) }));
        failure = try b.bind(changed, try e.call(graph.replace, &.{ input, obligation_ref, try e.variant(node, @backingInt(g.NodeTag.obligation), failed_obligation) }), failure);
        const select = try e.when(try is(e, try e.field(exit, 0), 3), abandoned, try e.when(try is(e, try e.field(exit, 0), 2), abandoned, try e.when(try is(e, try e.field(exit, 0), 1), failure, try e.fail())));
        try b.define(d.crossed, try b.bind(obligation_node, try e.call(graph.record, &.{ input, obligation_ref }), try b.bind(prior_node, try e.call(graph.record, &.{ input, prior_ref }), select)));
    }
    {
        const input = try e.param(d.cancel, 0);
        const cancellation = try e.param(d.cancel, 1);
        const roots = try control.roots(e, m, input);
        const prior_exit = try field(e, roots, g.Roots, "exit");
        const pending = try field(e, roots, g.Roots, "pending");
        const pending_node = try b.variable(node);
        const cursor = try b.variable(try projection.schema(?g.NodeRef, b));
        const choose_cursor = try e.when(try is(e, pending, 0), try b.pure(try field(e, roots, g.Roots, "current")), try b.bind(pending_node, try e.call(graph.record, &.{ input, try e.payload(pending, 1) }), try b.pure(try some(e, try e.field(try e.payload(try b.reference(pending_node), @backingInt(g.NodeTag.pending)), 2)))));
        const started = try b.variable(m.schema);
        const start = try e.when(try is(e, prior_exit, 0), try b.bind(cursor, choose_cursor, try e.call(u.begin, &.{ input, try e.literal(@FieldType(g.Exit, "reason"), .cancellation), try b.reference(cursor), null_ref, try empty(e) })), try b.pure(input));
        const root_ref = try b.variable(ref);
        const root_node = try b.variable(node);
        const exit = try e.payload(try b.reference(root_node), @backingInt(g.NodeTag.exit));
        const discarded = try b.variable(vals);
        const selected = try b.variable(exit_type);
        const annotated = try e.replace(exit, machines.index(g.Exit, "cancellation"), try e.variant(try projection.schema(?data.invocation.Reason, b), 1, cancellation));
        var replaced = try e.replace(annotated, 0, try e.literal(@FieldType(g.Exit, "reason"), .cancellation));
        replaced = try e.replace(replaced, machines.index(g.Exit, "stop"), null_ref);
        replaced = try e.replace(replaced, machines.index(g.Exit, "discarded"), try b.reference(discarded));
        const select = try e.when(try is(e, try e.field(exit, 0), 0), try b.pure(replaced), try e.when(try is(e, try e.field(exit, 0), 3), try b.pure(replaced), try b.pure(annotated)));
        var annotate = try b.bind(selected, select, try e.call(graph.replace, &.{ try b.reference(started), try b.reference(root_ref), try e.variant(node, @backingInt(g.NodeTag.exit), try b.reference(selected)) }));
        annotate = try b.bind(discarded, try e.call(u.discarded, &.{exit}), annotate);
        var body = try b.bind(root_node, try e.call(graph.record, &.{ try b.reference(started), try b.reference(root_ref) }), try e.when(try is(e, try field(e, exit, g.Exit, "cancellation"), 0), annotate, try b.pure(try b.reference(started))));
        body = try b.bind(root_ref, try e.call(u.outermost, &.{ try b.reference(started), try e.payload(try field(e, try control.roots(e, m, try b.reference(started)), g.Roots, "exit"), 1) }), body);
        try b.define(d.cancel, try b.bind(started, start, body));
    }
}
