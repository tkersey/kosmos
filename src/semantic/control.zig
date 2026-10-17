//! Portable guest control transitions. All graph changes are ordinary values.
const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const edges = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const ir = data.activation;
const g = data.graph;
const field = edges.field;

pub const Definition = struct { execute: Id, jump: Id, capture: Id, enter: Id, apply: Id, resume_continuation: Id, return_to: Id, unwind: @import("unwind.zig").Definition };

pub fn roots(e: Author, m: machines.Definition, input: Id) Error!Id {
    return field(e, try m.field(e, input, .header), machines.Header, "roots");
}
pub fn withRoots(e: Author, input: Id, changed: Id) Error!Id {
    return e.replace(input, @backingInt(machines.Field.header), try e.replace(try e.field(input, @backingInt(machines.Field.header)), machines.index(machines.Header, "roots"), changed));
}
fn node(e: Author, m: machines.Definition, record: Id, frame: ?Id) Error!Id {
    const optional = e.b.schemas.items[@intCast(m.nodes.element)].product[1];
    return e.tuple(m.nodes.element, &.{ record, try e.variant(optional, if (frame != null) 1 else 0, frame orelse e.unit_value) });
}
fn reference(e: Author, id: Id) Error!Id {
    return e.tuple(try projection.schema(g.NodeRef, e.b), &.{id});
}
fn optionalRef(e: Author, ref: ?Id) Error!Id {
    return e.variant(try projection.schema(?g.NodeRef, e.b), if (ref != null) 1 else 0, ref orelse e.unit_value);
}
fn changedNodes(e: Author, input: Id, table: Id) Error!Id {
    return e.replace(input, @backingInt(machines.Field.nodes), table);
}

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.control/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const edge = try edges.define(b, m);
    const aggregate = try @import("aggregate.zig").define(b, m);
    const graph = try @import("graph.zig").define(b, m);
    const ref_type = try projection.schema(g.NodeRef, b);
    const maybe_ref = try projection.schema(?g.NodeRef, b);
    const value = try projection.schema(g.Value, b);
    const maybe_value = try projection.schema(?g.Value, b);
    const control_type = try projection.schema(g.Control, b);
    const edge_type = try projection.schema(ir.Edge, b);
    const node_type = try projection.schema(g.Node, b);
    const d: Definition = .{
        .unwind = try @import("unwind.zig").declare(b, m),
        .execute = try b.declare(&.{m.schema}, m.schema, &.{}, &.{}),
        .jump = try b.declare(&.{ m.schema, ref_type, control_type, m.frames.schema, edge_type, maybe_value }, m.schema, &.{}, &.{}),
        .capture = try b.declare(&.{ m.schema, ref_type, control_type, m.frames.schema, edge_type }, m.schema, &.{}, &.{}),
        .enter = try b.declare(&.{ m.schema, e.integer, try projection.schema([]const g.Value, b), maybe_ref, maybe_ref, maybe_ref }, m.schema, &.{}, &.{}),
        .apply = try b.declare(&.{ m.schema, value, try projection.schema([]const g.Value, b), maybe_ref, maybe_ref, maybe_ref }, m.schema, &.{}, &.{}),
        .resume_continuation = try b.declare(&.{ m.schema, ref_type, value }, m.schema, &.{}, &.{}),
        .return_to = try b.declare(&.{ m.schema, maybe_ref, value }, m.schema, &.{}, &.{}),
    };
    const handlers = try @import("handlers.zig").define(b, m, .{ .enter = d.enter, .apply = d.apply, .capture = d.capture, .resume_continuation = d.resume_continuation });
    {
        const input = try e.param(d.apply, 0);
        const ref = try b.variable(ref_type);
        const closure = try b.variable(node_type);
        const environment = try b.variable(node_type);
        const closure_data = try e.payload(try b.reference(closure), @backingInt(g.NodeTag.computation));
        const constructors = try field(e, try edges.code(e, try m.field(e, input, .program)), ir.Program, "constructors");
        const constructor = try e.required(constructors, try e.field(closure_data, 0));
        const captured = try e.field(try e.payload(try b.reference(environment), @backingInt(g.NodeTag.environment)), 0);
        const arguments = try b.primitive(try projection.schema([]const g.Value, b), .sequence_concat, &.{ captured, try e.param(d.apply, 2) }, 0);
        try b.define(d.apply, try b.bind(ref, try e.call(graph.value_ref, &.{try e.param(d.apply, 1)}), try b.bind(closure, try e.call(graph.record, &.{ input, try b.reference(ref) }), try b.bind(environment, try e.call(graph.record, &.{ input, try e.field(closure_data, 1) }), try e.call(d.enter, &.{ input, try field(e, constructor, data.program.Constructor, "function"), arguments, try e.param(d.apply, 3), try e.param(d.apply, 4), try e.param(d.apply, 5) })))));
    }
    {
        const input = try e.param(d.jump, 0);
        const current = try e.param(d.jump, 1);
        const control = try e.param(d.jump, 2);
        const transfer = try e.param(d.jump, 4);
        const frame = try b.variable(m.frames.schema);
        const table = try b.variable(m.nodes.table);
        const record = try e.variant(node_type, @backingInt(g.NodeTag.control), try e.replace(control, 0, try e.field(transfer, 0)));
        try b.define(d.jump, try b.bind(frame, try e.call(edge.assign, &.{ try m.field(e, input, .program), try e.param(d.jump, 3), transfer, try e.param(d.jump, 5) }), try b.bind(table, try e.call(m.nodes.set, &.{ try m.field(e, input, .nodes), try e.field(current, 0), try node(e, m, record, try b.reference(frame)) }), try b.pure(try changedNodes(e, input, try b.reference(table))))));
    }
    {
        const input = try e.param(d.capture, 0);
        const current = try e.param(d.capture, 1);
        const control = try e.param(d.capture, 2);
        const mask = try b.variable((try @import("sets.zig").define(b)).map.tree);
        const frame = try b.variable(m.frames.schema);
        const table = try b.variable(m.nodes.table);
        const saved = try e.tuple(try projection.schema(g.Continuation, b), &.{ try e.field(control, 0), try e.field(control, 1), try e.field(control, 2), try e.field(control, 3) });
        const record = try e.variant(node_type, @backingInt(g.NodeTag.continuation), saved);
        try b.define(d.capture, try b.bind(mask, try e.call(edge.retained, &.{ try m.field(e, input, .program), try e.param(d.capture, 4) }), try b.bind(frame, try e.call(m.frames.retain, &.{ try e.param(d.capture, 3), try b.reference(mask) }), try b.bind(table, try e.call(m.nodes.set, &.{ try m.field(e, input, .nodes), try e.field(current, 0), try node(e, m, record, try b.reference(frame)) }), try b.pure(try changedNodes(e, input, try b.reference(table)))))));
    }
    {
        const input = try e.param(d.enter, 0);
        const program = try m.field(e, input, .program);
        const fn_code = try edges.function(e, program, try e.param(d.enter, 1));
        const entry = try field(e, fn_code, ir.Function, "entry");
        const parent = try e.param(d.enter, 3);
        const evidence = try e.param(d.enter, 4);
        const region = try e.param(d.enter, 5);
        const frame = try b.variable(m.frames.schema);
        const pruned = try b.variable(m.frames.schema);
        const chosen = try b.variable(e.integer);
        const table = try b.variable(m.nodes.table);
        const prior = try m.field(e, input, .nodes);
        const record = try e.variant(node_type, @backingInt(g.NodeTag.control), try e.tuple(control_type, &.{ entry, parent, evidence, region }));
        const replacement = try node(e, m, record, try b.reference(pruned));
        const count = try e.field(prior, 0);
        const id = try b.reference(chosen);
        const append = try e.call(m.nodes.append, &.{ prior, replacement });
        const replace = try e.call(m.nodes.set, &.{ prior, id, replacement });
        var new_roots = try roots(e, m, input);
        new_roots = try e.replace(new_roots, machines.index(g.Roots, "current"), try optionalRef(e, try reference(e, id)));
        new_roots = try e.replace(new_roots, machines.index(g.Roots, "evidence"), evidence);
        const changed = try withRoots(e, try changedNodes(e, input, try b.reference(table)), new_roots);
        const save = try b.bind(table, try e.when(try e.binary(.equal, id, count), append, replace), try b.pure(changed));
        const absent = try b.variable(e.unit);
        const present = try b.variable(ref_type);
        const found = try b.variable(m.nodes.optional);
        const current = try b.reference(present);
        const record_tag = try b.primitive(e.integer, .variant_tag, &.{try e.field(try e.payload(try b.reference(found), 1), 0)}, 0);
        const select = try b.term(.{ .match_sum = .{ .value = try field(e, try roots(e, m, input), g.Roots, "current"), .cases = &.{
            .{ .variable = absent, .body = try b.pure(count) },
            .{ .variable = present, .body = try b.bind(found, try e.call(m.nodes.get, &.{ prior, try e.field(current, 0) }), try e.when(try e.binary(.equal, record_tag, e.zero), try b.pure(try e.field(current, 0)), try b.pure(count))) },
        } } });
        const empty_frame = try e.tuple(m.frames.schema, &.{ e.zero, e.zero, try m.frames.slots.empty(e), try e.literal([]const data.process_state.Owner, &.{}) });
        try b.define(d.enter, try b.bind(frame, try e.call(edge.write, &.{ empty_frame, try field(e, fn_code, ir.Function, "inputs"), try e.param(d.enter, 2) }), try b.bind(pruned, try e.call(m.frames.prune, &.{ try b.reference(frame), try edges.live(e, program, entry) }), try b.bind(chosen, select, save))));
    }
    {
        const input = try e.param(d.resume_continuation, 0);
        const current = try e.param(d.resume_continuation, 1);
        const found = try b.variable(m.nodes.optional);
        const saved_node = try e.payload(try b.reference(found), 1);
        const saved = try e.payload(try e.field(saved_node, 0), @backingInt(g.NodeTag.continuation));
        const frame = try e.payload(try e.field(saved_node, 1), 1);
        const transfer = try b.variable(edge_type);
        const next = try b.reference(transfer);
        const control = try e.tuple(control_type, &.{ try e.field(next, 0), try e.field(saved, 1), try e.field(saved, 2), try e.field(saved, 3) });
        const changed = try b.variable(m.schema);
        var new_roots = try roots(e, m, input);
        new_roots = try e.replace(new_roots, machines.index(g.Roots, "current"), try optionalRef(e, current));
        new_roots = try e.replace(new_roots, machines.index(g.Roots, "evidence"), try e.field(saved, 2));
        const target = try edges.block(e, try m.field(e, input, .program), try e.field(saved, 0));
        try b.define(d.resume_continuation, try b.bind(found, try e.call(m.nodes.get, &.{ try m.field(e, input, .nodes), try e.field(current, 0) }), try b.bind(transfer, try e.call(edge.next, &.{try field(e, target, ir.Block, "terminator")}), try b.bind(changed, try e.call(d.jump, &.{ input, current, control, frame, next, try e.variant(maybe_value, 1, try e.param(d.resume_continuation, 2)) }), try b.pure(try withRoots(e, try b.reference(changed), new_roots))))));
    }
    {
        const input = try e.param(d.return_to, 0);
        const returned = try e.param(d.return_to, 2);
        const absent = try b.variable(e.unit);
        const present = try b.variable(ref_type);
        const current = try b.reference(present);
        const found = try b.variable(m.nodes.optional);
        const saved = try e.field(try e.payload(try b.reference(found), 1), 0);
        const tag = try b.primitive(e.integer, .variant_tag, &.{saved}, 0);
        var dispatch = try e.fail();
        {
            const attachment = try e.payload(saved, @backingInt(g.NodeTag.attachment));
            const handler = try b.variable(node_type);
            const definition = try e.payload(try b.reference(handler), @backingInt(g.NodeTag.handler));
            const catalog = try field(e, try edges.code(e, try m.field(e, input, .program)), ir.Program, "handlers");
            const handler_code = try e.required(catalog, try e.field(definition, 0));
            const arguments = try b.primitive(try projection.schema([]const g.Value, b), .sequence_concat, &.{ try e.field(definition, 1), try b.primitive(try projection.schema([]const g.Value, b), .sequence, &.{returned}, 0) }, 0);
            const enter = try b.bind(handler, try e.call(graph.record, &.{ input, try e.field(attachment, 0) }), try e.call(d.enter, &.{ input, try field(e, handler_code, ir.Handler, "return_function"), arguments, try e.field(attachment, 2), try e.field(definition, 2), try e.field(definition, 3) }));
            const phase = try b.primitive(try b.scalar(u32), .enum_tag, &.{try e.field(attachment, 3)}, 0);
            dispatch = try e.when(try e.binary(.equal, tag, try b.constant(u64, @backingInt(g.NodeTag.attachment))), try e.when(try e.binary(.equal, phase, try b.constant(u32, 0)), enter, try e.fail()), dispatch);
        }
        const protection = try e.payload(saved, @backingInt(g.NodeTag.protection));
        dispatch = try e.when(try e.binary(.equal, tag, try b.constant(u64, @backingInt(g.NodeTag.protection))), try e.call(d.unwind.begin, &.{ input, try e.variant(try projection.schema(@FieldType(g.Exit, "reason"), b), 0, returned), try optionalRef(e, current), try e.field(protection, 2), try e.literal([]const g.Value, &.{}) }), dispatch);
        dispatch = try e.when(try e.binary(.equal, tag, try b.constant(u64, @backingInt(g.NodeTag.cleanup_return))), try e.call(d.unwind.cleanup.returned, &.{ input, try e.payload(saved, @backingInt(g.NodeTag.cleanup_return)) }), dispatch);
        dispatch = try e.when(try e.binary(.equal, tag, try b.constant(u64, @backingInt(g.NodeTag.disposal_return))), try e.call(d.unwind.returned_disposal, &.{ input, try e.payload(saved, @backingInt(g.NodeTag.disposal_return)), returned }), dispatch);
        dispatch = try e.when(try e.binary(.equal, tag, try b.constant(u64, @backingInt(g.NodeTag.continuation))), try e.when(try @import("unwind.zig").is(e, try e.field(returned, 1), 3), try e.when(try @import("unwind.zig").is(e, try field(e, try edges.block(e, try m.field(e, input, .program), try e.field(try e.payload(saved, @backingInt(g.NodeTag.continuation)), 0)), ir.Block, "terminator"), machines.index(ir.Terminator, "dispose")), try e.call(d.unwind.begin, &.{ input, try e.literal(@FieldType(g.Exit, "reason"), .abandoned), try optionalRef(e, current), try optionalRef(e, current), try @import("unwind.zig").seq(e, &.{returned}) }), try e.call(d.resume_continuation, &.{ input, current, returned })), try e.call(d.resume_continuation, &.{ input, current, returned })), dispatch);
        dispatch = try e.when(try e.binary(.equal, tag, try b.constant(u64, @backingInt(g.NodeTag.injection))), try e.call(d.resume_continuation, &.{ input, try e.field(try e.payload(saved, @backingInt(g.NodeTag.injection)), 0), returned }), dispatch);
        dispatch = try e.when(try e.binary(.equal, tag, try b.constant(u64, @backingInt(g.NodeTag.region_scope))), try e.call(d.return_to, &.{ input, try e.field(try e.payload(saved, @backingInt(g.NodeTag.region_scope)), 2), returned }), dispatch);
        // The root return produces the existing canonical terminal exit record.
        const exit_schema = try projection.schema(g.Exit, b);
        const reason_type = b.schemas.items[@intCast(exit_schema)].product[0];
        const exit_record = try e.replace(try e.literal(g.Exit, .{ .reason = .abandoned }), 0, try e.variant(reason_type, 0, returned));
        const table = try b.variable(m.nodes.table);
        const old = try m.field(e, input, .nodes);
        const ref = try reference(e, try e.field(old, 0));
        const new_roots = try e.replace(try e.literal(g.Roots, .{}), machines.index(g.Roots, "exit"), try optionalRef(e, ref));
        var completed = try withRoots(e, try changedNodes(e, input, try b.reference(table)), new_roots);
        completed = try e.replace(completed, @backingInt(machines.Field.header), try e.replace(try m.field(e, completed, .header), machines.index(machines.Header, "status"), try e.literal(data.process_state.Status, .completed)));
        const finish = try b.bind(table, try e.call(m.nodes.append, &.{ old, try node(e, m, try e.variant(node_type, @backingInt(g.NodeTag.exit), exit_record), null) }), try b.pure(completed));
        try b.define(d.return_to, try b.term(.{ .match_sum = .{ .value = try e.param(d.return_to, 1), .cases = &.{
            .{ .variable = absent, .body = finish },
            .{ .variable = present, .body = try b.bind(found, try e.call(m.nodes.get, &.{ old, try e.field(current, 0) }), dispatch) },
        } } }));
    }
    {
        const input = try e.param(d.execute, 0);
        const current = try e.payload(try field(e, try roots(e, m, input), g.Roots, "current"), 1);
        const found = try b.variable(m.nodes.optional);
        const selected = try e.payload(try b.reference(found), 1);
        const control = try e.payload(try e.field(selected, 0), 0);
        const frame = try e.payload(try e.field(selected, 1), 1);
        const program = try m.field(e, input, .program);
        const target = try edges.block(e, program, try e.field(control, 0));
        const term = try field(e, target, ir.Block, "terminator");
        const term_type = try projection.schema(ir.Terminator, b);
        const variants = b.schemas.items[@intCast(term_type)].sum;
        const info = @typeInfo(ir.Terminator).@"union";
        const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
        var cases: [info.field_names.len]Case = undefined;
        inline for (info.field_names, 0..) |name, i| {
            const variable = try b.variable(variants[i]);
            const operation = try b.reference(variable);
            const T = @FieldType(ir.Terminator, name);
            const tag: data.program.TerminatorTag = @field(data.program.TerminatorTag, name);
            const body = switch (tag) {
                .jump, .yield_value => blk: {
                    const jump = try e.call(d.jump, &.{ input, current, control, frame, operation, try e.variant(maybe_value, 0, e.unit_value) });
                    if (tag == .jump) break :blk jump;
                    const changed = try b.variable(m.schema);
                    break :blk try b.bind(changed, jump, try b.pure(try e.replace(try b.reference(changed), @backingInt(machines.Field.header), try e.replace(try m.field(e, try b.reference(changed), .header), machines.index(machines.Header, "status"), try e.literal(data.process_state.Status, .yielded)))));
                },
                .branch => blk: {
                    const condition = try b.variable(value);
                    const condition_bytes = try e.payload(try e.field(try b.reference(condition), 1), 0);
                    const choose = try e.when(try e.binary(.equal, try e.required(condition_bytes, e.zero), try b.constant(u8, 1)), try e.call(d.jump, &.{ input, current, control, frame, try field(e, operation, T, "when_true"), try e.variant(maybe_value, 0, e.unit_value) }), try e.call(d.jump, &.{ input, current, control, frame, try field(e, operation, T, "when_false"), try e.variant(maybe_value, 0, e.unit_value) }));
                    break :blk try b.bind(condition, try e.call(m.frames.read, &.{ frame, try field(e, operation, T, "condition") }), choose);
                },
                .call, .apply => blk: {
                    const arguments = try b.variable(try projection.schema([]const g.Value, b));
                    const computation = try b.variable(value);
                    const tail = try b.variable(e.boolean);
                    const captured = try b.variable(m.schema);
                    const next = try field(e, operation, T, "next");
                    const function_id = if (tag == .call) try field(e, operation, T, "function") else try b.reference(computation);
                    const invoke = if (tag == .call) d.enter else d.apply;
                    const tail_call = try e.call(invoke, &.{ input, function_id, try b.reference(arguments), try e.field(control, 1), try e.field(control, 2), try e.field(control, 3) });
                    const call = try b.bind(captured, try e.call(d.capture, &.{ input, current, control, frame, next }), try e.call(invoke, &.{ try b.reference(captured), function_id, try b.reference(arguments), try optionalRef(e, current), try e.field(control, 2), try e.field(control, 3) }));
                    const invoke_term = try b.bind(arguments, try e.call(edge.collect, &.{ frame, try field(e, operation, T, "arguments") }), try b.bind(tail, try e.call(edge.tail, &.{ program, next }), try e.when(try b.reference(tail), tail_call, call)));
                    break :blk if (tag == .call) invoke_term else try b.bind(computation, try e.call(m.frames.read, &.{ frame, try field(e, operation, T, "computation") }), invoke_term);
                },
                .with_region => blk: {
                    const graphs = @import("graph.zig");
                    const region = try b.variable(graph.appended);
                    const body_value = try b.variable(value);
                    const arguments = try b.variable(try projection.schema([]const g.Value, b));
                    const captured = try b.variable(m.schema);
                    const wrapper = try b.variable(graph.appended);
                    const region_ref = try e.field(try b.reference(region), 1);
                    const shape = try e.required(try field(e, try edges.code(e, program), ir.Program, "schemas"), try e.field(try b.reference(body_value), 0));
                    const computation = try e.payload(try e.payload(shape, @backingInt(data.program.SchemaTag.internal)), @backingInt(data.program.InternalTag.computation));
                    const parameter = try e.required(try field(e, computation, data.program.ComputationType, "parameters"), e.zero);
                    const region_value = try graphs.value(e, parameter, region_ref, false);
                    const prefix = try b.primitive(try projection.schema([]const g.Value, b), .sequence, &.{region_value}, 0);
                    const supplied = try b.primitive(try projection.schema([]const g.Value, b), .sequence_concat, &.{ prefix, try b.reference(arguments) }, 0);
                    const scope_record = try graphs.record(e, .region_scope, &.{ try e.field(control, 0), region_ref, try optionalRef(e, current) });
                    var follow = try e.call(d.apply, &.{ try e.field(try b.reference(wrapper), 0), try b.reference(body_value), supplied, try optionalRef(e, try e.field(try b.reference(wrapper), 1)), try e.field(control, 2), try optionalRef(e, region_ref) });
                    follow = try b.bind(wrapper, try e.call(graph.append, &.{ try b.reference(captured), scope_record }), follow);
                    follow = try b.bind(captured, try e.call(d.capture, &.{ try e.field(try b.reference(region), 0), current, control, frame, try field(e, operation, T, "next") }), follow);
                    follow = try b.bind(arguments, try e.call(edge.collect, &.{ frame, try field(e, operation, T, "arguments") }), follow);
                    follow = try b.bind(body_value, try e.call(m.frames.read, &.{ frame, try field(e, operation, T, "body") }), follow);
                    const region_record = try graphs.record(e, .region, &.{ try field(e, operation, T, "region"), try e.field(control, 3), try e.literal([]const g.OwnedRef, &.{}) });
                    break :blk try b.bind(region, try e.call(graph.append, &.{ input, region_record }), follow);
                },
                .protect => try e.call(d.unwind.cleanup.protect, &.{ input, current, control, frame, operation }),
                .dispose => try e.call(d.unwind.dispose, &.{ input, current, control, frame, operation }),
                .fail => blk: {
                    const failed_value = try b.variable(value);
                    break :blk try b.bind(failed_value, try e.call(m.frames.read, &.{ frame, operation }), try e.call(d.unwind.fail_current, &.{ input, try b.reference(failed_value) }));
                },
                .handle => try e.call(handlers.install, &.{ input, current, control, frame, operation }),
                .perform => try e.call(handlers.perform, &.{ input, current, control, frame, operation }),
                .resume_value, .resume_with, .resume_computation => try e.call(handlers.resume_control, &.{ input, current, control, frame, term }),
                .return_value => blk: {
                    const returned = try b.variable(value);
                    break :blk try b.bind(returned, try e.call(m.frames.read, &.{ frame, operation }), try e.call(d.return_to, &.{ input, try e.field(control, 1), try b.reference(returned) }));
                },
                .switch_variant, .unpack_product => blk: {
                    const aggregate_value = try b.variable(value);
                    const split = try b.variable(aggregate.split_result);
                    const changed = try e.field(try b.reference(split), 0);
                    const parts = try e.field(try b.reference(split), 1);
                    const source_slot = try field(e, operation, T, "value");
                    const cleared = try b.variable(m.frames.schema);
                    const copy = try e.required(try field(e, try field(e, program, projection.Program, "uses"), data.traits.Facts, "copy"), try e.field(try b.reference(aggregate_value), 0));
                    const clear = try e.when(copy, try b.pure(frame), try e.call(m.frames.clear, &.{ frame, source_slot }));
                    var follow: Id = undefined;
                    if (tag == .switch_variant) {
                        const transfer = try e.required(try field(e, operation, T, "cases"), try e.field(parts, 0));
                        follow = try e.call(d.jump, &.{ changed, current, control, try b.reference(cleared), transfer, try e.variant(maybe_value, 1, try e.required(try e.field(parts, 1), e.zero)) });
                    } else {
                        const transfer = try field(e, operation, T, "next");
                        const destination_block = try edges.block(e, program, try e.field(transfer, 0));
                        const destination_function = try edges.function(e, program, try field(e, destination_block, ir.Block, "function"));
                        const scoped = try b.variable(m.frames.schema);
                        const written = try b.variable(m.frames.schema);
                        follow = try b.bind(scoped, try e.call(m.frames.scope, &.{ try b.reference(cleared), try field(e, destination_function, ir.Function, "custody"), try field(e, destination_block, ir.Block, "custody") }), try b.bind(written, try e.call(edge.write, &.{ try b.reference(scoped), try field(e, operation, T, "destinations"), try e.field(parts, 1) }), try e.call(d.jump, &.{ changed, current, control, try b.reference(written), transfer, try e.variant(maybe_value, 0, e.unit_value) })));
                    }
                    break :blk try b.bind(aggregate_value, try e.call(m.frames.read, &.{ frame, source_slot }), try b.bind(split, try e.call(aggregate.split, &.{ input, try b.reference(aggregate_value) }), try b.bind(cleared, clear, follow)));
                },
            };
            cases[i] = .{ .variable = variable, .body = body };
        }
        try b.define(d.execute, try b.bind(found, try e.call(m.nodes.get, &.{ try m.field(e, input, .nodes), try e.field(current, 0) }), try b.term(.{ .match_sum = .{ .value = term, .cases = &cases } })));
    }
    try @import("unwind.zig").emit(b, m, d.unwind, d);
    return cache.finish(b, d);
}
