//! Guest handler installation, effect capture, and resumption in Horos.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const graphs = @import("graph.zig");
const captures = @import("captures.zig");
const access = @import("edges.zig");
const tables = @import("table.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const p = data.program;
const ir = data.activation;
const field = access.field;
pub const Calls = struct { enter: Id, apply: Id, capture: Id, resume_continuation: Id };
pub const Definition = struct { install: Id, perform: Id, resume_control: Id };

pub fn define(b: *source.Builder, m: machines.Definition, calls: Calls) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.handlers/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const tokens = try captures.define(b, m);
    const edge = try access.define(b, m);
    const ref_type = try projection.schema(g.NodeRef, b);
    const optional_ref = try projection.schema(?g.NodeRef, b);
    const value = try projection.schema(g.Value, b);
    const values = try projection.schema([]const g.Value, b);
    const control_type = try projection.schema(g.Control, b);
    const node = try projection.schema(g.Node, b);
    const d: Definition = .{
        .install = try b.declare(&.{ m.schema, ref_type, control_type, m.frames.schema, try projection.schema(@FieldType(ir.Terminator, "handle"), b) }, m.schema, &.{}, &.{}),
        .perform = try b.declare(&.{ m.schema, ref_type, control_type, m.frames.schema, try projection.schema(ir.Perform, b) }, m.schema, &.{}, &.{}),
        .resume_control = try b.declare(&.{ m.schema, ref_type, control_type, m.frames.schema, try projection.schema(ir.Terminator, b) }, m.schema, &.{}, &.{}),
    };
    const capability_arguments = try b.declare(&.{ try projection.schema([]const Id, b), e.integer, ref_type, e.integer, (try tables.define(b, value)).table }, values, &.{}, &.{});
    const list = try tables.define(b, value);
    {
        const types = try e.param(capability_arguments, 0);
        const count = try e.param(capability_arguments, 1);
        const ref = try e.param(capability_arguments, 2);
        const index = try e.param(capability_arguments, 3);
        const prior = try e.param(capability_arguments, 4);
        const appended = try b.variable(list.table);
        const next = try b.bind(appended, try e.call(list.append, &.{ prior, try graphs.value(e, try e.required(types, index), ref, false) }), try e.call(capability_arguments, &.{ types, count, ref, try e.binary(.integer_add, index, e.one), try b.reference(appended) }));
        try b.define(capability_arguments, try e.when(try e.binary(.less, index, count), next, try e.call(list.to_sequence, &.{prior})));
    }
    {
        const input = try e.param(d.install, 0);
        const current = try e.param(d.install, 1);
        const control = try e.param(d.install, 2);
        const frame = try e.param(d.install, 3);
        const operation = try e.param(d.install, 4);
        const T = @FieldType(ir.Terminator, "handle");
        const program = try m.field(e, input, .program);
        const code = try access.code(e, program);
        const definition = try e.required(try field(e, code, ir.Program, "handlers"), try field(e, operation, T, "handler"));
        const state = try b.variable(values);
        const body = try b.variable(value);
        const arguments = try b.variable(values);
        const handler = try b.variable(graph.appended);
        const captured = try b.variable(m.schema);
        const attachment = try b.variable(graph.appended);
        const capabilities = try b.variable(values);
        const attachment_ref = try e.field(try b.reference(attachment), 1);
        const signature = try e.payload(try e.payload(try e.required(try field(e, code, ir.Program, "schemas"), try e.field(try b.reference(body), 0)), @backingInt(p.SchemaTag.internal)), @backingInt(p.InternalTag.computation));
        const parent = try e.variant(optional_ref, 1, attachment_ref);
        var install = try e.call(calls.apply, &.{ try e.field(try b.reference(attachment), 0), try b.reference(body), try b.primitive(values, .sequence_concat, &.{ try b.reference(capabilities), try b.reference(arguments) }, 0), parent, parent, try e.field(control, 3) });
        install = try b.bind(capabilities, try e.call(capability_arguments, &.{ try field(e, signature, p.ComputationType, "parameters"), try b.primitive(e.integer, .sequence_length, &.{try field(e, definition, ir.Handler, "clauses")}, 0), attachment_ref, e.zero, try list.empty(b) }), install);
        const attachment_record = try graphs.record(e, .attachment, &.{ try e.field(try b.reference(handler), 1), try e.field(control, 2), try e.variant(optional_ref, 1, current), try e.literal(@FieldType(@FieldType(g.Node, "attachment"), "phase"), .active), try e.field(control, 3) });
        install = try b.bind(attachment, try e.call(graph.append, &.{ try b.reference(captured), attachment_record }), install);
        install = try b.bind(captured, try e.call(calls.capture, &.{ try e.field(try b.reference(handler), 0), current, control, frame, try field(e, operation, T, "next") }), install);
        const handler_record = try graphs.record(e, .handler, &.{ try field(e, operation, T, "handler"), try b.reference(state), try e.field(control, 2), try e.field(control, 3) });
        install = try b.bind(handler, try e.call(graph.append, &.{ input, handler_record }), install);
        install = try b.bind(arguments, try e.call(edge.collect, &.{ frame, try field(e, operation, T, "arguments") }), install);
        install = try b.bind(body, try e.call(m.frames.read, &.{ frame, try field(e, operation, T, "body") }), install);
        install = try b.bind(state, try e.call(edge.collect, &.{ frame, try field(e, operation, T, "state") }), install);
        try b.define(d.install, install);
    }
    const in_scope = try b.declare(&.{ m.schema, optional_ref, ref_type }, e.unit, &.{}, &.{});
    {
        const input = try e.param(in_scope, 0);
        const ref = try e.payload(try e.param(in_scope, 1), 1);
        const target = try e.param(in_scope, 2);
        const record_var = try b.variable(node);
        const record = try b.reference(record_var);
        var visit = try e.fail();
        inline for ([_]g.NodeTag{ .continuation, .attachment, .region_scope, .injection, .protection, .cleanup_return, .disposal_return }) |tag| {
            const T = @FieldType(g.Node, @tagName(tag));
            const payload = try e.payload(record, @backingInt(tag));
            const parent = if (tag == .injection) try e.variant(optional_ref, 1, try e.field(payload, 0)) else try field(e, payload, T, if (tag == .continuation or tag == .cleanup_return or tag == .disposal_return) "parent" else "return_to");
            visit = try e.when(try is(e, record, tag), try e.call(in_scope, &.{ input, parent, target }), visit);
        }
        try b.define(in_scope, try e.when(try e.binary(.equal, try e.field(ref, 0), try e.field(target, 0)), try b.pure(e.unit_value), try b.bind(record_var, try e.call(graph.record, &.{ input, ref }), visit)));
    }
    const find_clause = try b.declare(&.{ try projection.schema([]const ir.Clause, b), e.integer }, try projection.schema(ir.Clause, b), &.{}, &.{});
    {
        const clauses = try e.param(find_clause, 0);
        const pair_type = try b.schema(.{ .product = &.{ try projection.schema(ir.Clause, b), try projection.schema([]const ir.Clause, b) } });
        const optional = try b.schema(.{ .sum = &.{ e.unit, pair_type } });
        const pair = try e.payload(try b.primitive(optional, .sequence_pop, &.{clauses}, 0), 1);
        const head = try e.field(pair, 0);
        const effect = try e.param(find_clause, 1);
        try b.define(find_clause, try e.when(try e.binary(.equal, try field(e, head, ir.Clause, "effect"), effect), try b.pure(head), try e.call(find_clause, &.{ try e.field(pair, 1), effect })));
    }
    {
        const input = try e.param(d.perform, 0);
        const current = try e.param(d.perform, 1);
        const control = try e.param(d.perform, 2);
        const frame = try e.param(d.perform, 3);
        const operation = try e.param(d.perform, 4);
        const program = try m.field(e, input, .program);
        const code = try access.code(e, program);
        const payload_var = try b.variable(value);
        const payload = try b.reference(payload_var);
        const captured = try b.variable(m.schema);
        const pending = try b.variable(graph.appended);
        const pending_record = try graphs.record(e, .pending, &.{ try field(e, operation, ir.Perform, "effect"), payload, current, try e.field(control, 0) });
        const pending_machine = try e.field(try b.reference(pending), 0);
        var pending_roots = try @import("control.zig").roots(e, m, pending_machine);
        pending_roots = try e.replace(pending_roots, machines.index(g.Roots, "current"), try e.literal(?g.NodeRef, null));
        pending_roots = try e.replace(pending_roots, machines.index(g.Roots, "pending"), try e.variant(optional_ref, 1, try e.field(try b.reference(pending), 1)));
        var parked = try @import("control.zig").withRoots(e, pending_machine, pending_roots);
        parked = try e.replace(parked, @backingInt(machines.Field.header), try e.replace(try m.field(e, parked, .header), machines.index(machines.Header, "status"), try e.literal(data.process_state.Status, .parked)));
        const external = try b.bind(captured, try e.call(calls.capture, &.{ input, current, control, frame, try field(e, operation, ir.Perform, "next") }), try b.bind(pending, try e.call(graph.append, &.{ try b.reference(captured), pending_record }), try b.pure(parked)));
        const cap_slot = try b.variable(e.integer);
        const cap_value = try b.variable(value);
        const selected = try b.variable(ref_type);
        const scoped = try b.variable(e.unit);
        const attachment_var = try b.variable(node);
        const handler_var = try b.variable(node);
        const attachment = try e.payload(try b.reference(attachment_var), @backingInt(g.NodeTag.attachment));
        const handler = try e.payload(try b.reference(handler_var), @backingInt(g.NodeTag.handler));
        const definition = try e.required(try field(e, code, ir.Program, "handlers"), try e.field(handler, 0));
        const clause_var = try b.variable(try projection.schema(ir.Clause, b));
        const clause = try b.reference(clause_var);
        const state_and_payload = try b.primitive(values, .sequence_concat, &.{ try e.field(handler, 1), try b.primitive(values, .sequence, &.{payload}, 0) }, 0);
        const tail = try b.bind(captured, try e.call(calls.capture, &.{ input, current, control, frame, try field(e, operation, ir.Perform, "next") }), try e.call(calls.enter, &.{ try b.reference(captured), try field(e, clause, ir.Clause, "function"), state_and_payload, try e.variant(optional_ref, 1, current), try e.field(handler, 2), try e.field(handler, 3) }));
        const use_site = try b.variable(values);
        const bodies = try b.variable(values);
        const multi = try b.variable(e.boolean);
        const token = try b.variable(graph.appended);
        const changed = try b.variable(m.schema);
        const token_value = try b.variable(value);
        const token_ref = try e.field(try b.reference(token), 1);
        const token_schema = try field(e, clause, ir.Clause, "resumption");
        const signature = try e.payload(try e.payload(try e.required(try field(e, code, ir.Program, "schemas"), token_schema), @backingInt(p.SchemaTag.internal)), @backingInt(p.InternalTag.resumption));
        const use = try field(e, signature, p.ResumptionType, "use");
        const is_multi = try e.binary(.equal, try b.primitive(try b.scalar(u32), .enum_tag, &.{use}, 0), try b.constant(u32, @backingInt(p.Use.multi)));
        const capture = try e.tuple(try projection.schema(g.Capture, b), &.{ token_schema, try e.variant(optional_ref, 1, current), try b.reference(selected), try e.field(control, 2), try b.reference(use_site) });
        const choose_token = try e.when(try b.reference(multi), try e.call(graph.template, &.{ try b.reference(captured), capture }), try e.call(graph.append, &.{ try b.reference(captured), try e.variant(node, @backingInt(g.NodeTag.one_shot), capture) }));
        const choose_value = try e.when(try b.reference(multi), try b.pure(try graphs.value(e, token_schema, token_ref, false)), try b.pure(try graphs.value(e, token_schema, token_ref, true)));
        const args = try b.primitive(values, .sequence_concat, &.{ try b.primitive(values, .sequence_concat, &.{ state_and_payload, try b.reference(bodies) }, 0), try b.primitive(values, .sequence, &.{try b.reference(token_value)}, 0) }, 0);
        var general = try e.call(calls.enter, &.{ try b.reference(changed), try field(e, clause, ir.Clause, "function"), args, try e.field(attachment, 2), try e.field(handler, 2), try e.field(handler, 3) });
        var suspended = try e.replace(attachment, 2, try e.literal(?g.NodeRef, null));
        suspended = try e.replace(suspended, 3, try e.literal(@FieldType(@FieldType(g.Node, "attachment"), "phase"), .suspended));
        general = try b.bind(changed, try e.call(graph.replace, &.{ try e.field(try b.reference(token), 0), try b.reference(selected), try e.variant(node, @backingInt(g.NodeTag.attachment), suspended) }), general);
        general = try b.bind(token_value, choose_value, general);
        general = try b.bind(token, choose_token, general);
        general = try b.bind(captured, try e.call(calls.capture, &.{ input, current, control, frame, try field(e, operation, ir.Perform, "next") }), general);
        general = try b.bind(multi, try b.pure(is_multi), general);
        general = try b.bind(bodies, try e.call(edge.collect, &.{ frame, try field(e, operation, ir.Perform, "bodies") }), general);
        general = try b.bind(use_site, try e.call(edge.collect, &.{ frame, try field(e, operation, ir.Perform, "use_site_capabilities") }), general);
        const strategy = try field(e, clause, ir.Clause, "strategy");
        var local = try e.when(try e.binary(.equal, try b.primitive(try b.scalar(u32), .enum_tag, &.{strategy}, 0), try b.constant(u32, 2)), tail, general);
        local = try b.bind(clause_var, try e.call(find_clause, &.{ try field(e, definition, ir.Handler, "clauses"), try field(e, operation, ir.Perform, "effect") }), local);
        local = try b.bind(handler_var, try e.call(graph.record, &.{ input, try e.field(attachment, 0) }), local);
        const phase = try e.field(attachment, 3);
        local = try e.when(try e.binary(.equal, try b.primitive(try b.scalar(u32), .enum_tag, &.{phase}, 0), try b.constant(u32, 0)), local, try e.fail());
        local = try b.bind(attachment_var, try e.call(graph.record, &.{ input, try b.reference(selected) }), local);
        local = try b.bind(scoped, try e.call(in_scope, &.{ input, try e.field(control, 1), try b.reference(selected) }), local);
        local = try b.bind(selected, try e.call(graph.value_ref, &.{try b.reference(cap_value)}), local);
        local = try b.bind(cap_value, try e.call(m.frames.read, &.{ frame, try b.reference(cap_slot) }), local);
        const absent = try b.variable(e.unit);
        try b.define(d.perform, try b.bind(payload_var, try e.call(m.frames.read, &.{ frame, try field(e, operation, ir.Perform, "payload") }), try b.term(.{ .match_sum = .{ .value = try field(e, operation, ir.Perform, "capability"), .cases = &.{ .{ .variable = absent, .body = external }, .{ .variable = cap_slot, .body = local } } } })));
    }
    {
        const input = try e.param(d.resume_control, 0);
        const current = try e.param(d.resume_control, 1);
        const control = try e.param(d.resume_control, 2);
        const frame = try e.param(d.resume_control, 3);
        const term = try e.param(d.resume_control, 4);
        const info = @typeInfo(ir.Terminator).@"union";
        const term_schema = try projection.schema(ir.Terminator, b);
        const Case = @import("std").meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
        var cases: [info.field_names.len]Case = undefined;
        inline for (info.field_names, 0..) |name, i| {
            const variable = try b.variable(b.schemas.items[@intCast(term_schema)].sum[i]);
            const operation = try b.reference(variable);
            const T = @FieldType(ir.Terminator, name);
            const tag: p.TerminatorTag = @field(p.TerminatorTag, name);
            var body = try e.fail();
            if (tag == .resume_value or tag == .resume_with or tag == .resume_computation) {
                const token_value = try b.variable(value);
                const taken = try b.variable(tokens.taken);
                const token = try e.field(try b.reference(taken), 1);
                const argument = try b.variable(value);
                const captured = try b.variable(m.schema);
                const state = try b.variable(values);
                const capture_ref = try e.payload(try field(e, token, g.Capture, "capture"), 1);
                if (tag == .resume_with) {
                    const handler = try b.variable(graph.appended);
                    const changed = try b.variable(m.schema);
                    const record = try graphs.record(e, .handler, &.{ try field(e, operation, T, "handler"), try b.reference(state), try e.field(control, 2), try e.field(control, 3) });
                    const attachment = try graphs.record(e, .attachment, &.{ try e.field(try b.reference(handler), 1), try e.field(control, 2), try e.variant(optional_ref, 1, current), try e.literal(@FieldType(@FieldType(g.Node, "attachment"), "phase"), .active), try e.field(control, 3) });
                    body = try b.bind(handler, try e.call(graph.append, &.{ try b.reference(captured), record }), try b.bind(changed, try e.call(graph.replace, &.{ try e.field(try b.reference(handler), 0), try field(e, token, g.Capture, "delimiter"), attachment }), try e.call(calls.resume_continuation, &.{ try b.reference(changed), capture_ref, try b.reference(argument) })));
                } else {
                    const prepared = try b.variable(tokens.prepared);
                    const machine = try e.field(try b.reference(prepared), 0);
                    if (tag == .resume_computation) {
                        const saved = try b.variable(node);
                        const injection = try b.variable(graph.appended);
                        const record = try graphs.record(e, .injection, &.{capture_ref});
                        body = try b.bind(saved, try e.call(graph.record, &.{ machine, capture_ref }), try b.bind(injection, try e.call(graph.append, &.{ machine, record }), try e.call(calls.apply, &.{ try e.field(try b.reference(injection), 0), try b.reference(argument), try field(e, token, g.Capture, "use_site_capabilities"), try e.variant(optional_ref, 1, try e.field(try b.reference(injection), 1)), try e.field(try b.reference(prepared), 1), try e.field(try e.payload(try b.reference(saved), @backingInt(g.NodeTag.continuation)), 3) })));
                    } else body = try e.call(calls.resume_continuation, &.{ machine, capture_ref, try b.reference(argument) });
                    body = try b.bind(prepared, try e.call(tokens.prepare, &.{ try b.reference(captured), token, current }), body);
                }
                body = try b.bind(captured, try e.call(calls.capture, &.{ try e.field(try b.reference(taken), 0), current, control, frame, try field(e, operation, T, "next") }), body);
                if (tag == .resume_with) body = try b.bind(state, try e.call(edge.collect, &.{ frame, try field(e, operation, T, "state") }), body);
                body = try b.bind(argument, try e.call(m.frames.read, &.{ frame, try field(e, operation, T, if (tag == .resume_computation) "computation" else "argument") }), body);
                body = try b.bind(taken, try e.call(tokens.take, &.{ input, try b.reference(token_value) }), body);
                body = try b.bind(token_value, try e.call(m.frames.read, &.{ frame, try field(e, operation, T, "resumption") }), body);
            }
            cases[i] = .{ .variable = variable, .body = body };
        }
        try b.define(d.resume_control, try b.term(.{ .match_sum = .{ .value = term, .cases = &cases } }));
    }
    return cache.finish(b, d);
}
fn is(e: Author, record: Id, tag: g.NodeTag) Error!Id {
    return e.binary(.equal, try e.b.primitive(e.integer, .variant_tag, &.{record}, 0), try e.b.constant(u64, @backingInt(tag)));
}
