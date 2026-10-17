//! Computation environments, cells, packages and resources are guest graph data.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const values = @import("values.zig");
const graphs = @import("graph.zig");
const access = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const p = data.program;
const field = access.field;

pub const Definition = struct { evaluate: Id, result: Id };
pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.memory_instructions/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const edge = try access.define(b, m);
    const v = try values.define(b, m);
    const captures = try @import("captures.zig").define(b, m);
    const outcome = try projection.schema(values.Outcome, b);
    const result = try b.schema(.{ .product = &.{ m.schema, outcome } });
    const d: Definition = .{ .evaluate = try b.declare(&.{ m.schema, m.frames.schema, try projection.schema(data.activation.Instruction, b), e.integer }, result, &.{}, &.{}), .result = result };
    const input = try e.param(d.evaluate, 0);
    const frame = try e.param(d.evaluate, 1);
    const instruction = try e.param(d.evaluate, 2);
    const result_schema = try e.param(d.evaluate, 3);
    const program = try m.field(e, input, .program);
    const operands = try field(e, instruction, data.activation.Instruction, "operands");
    const opcode = try field(e, instruction, data.activation.Instruction, "opcode");
    const left_var = try b.variable(v.value);
    const right_var = try b.variable(v.value);
    const left = try b.reference(left_var);
    const right = try b.reference(right_var);
    const reference = try b.variable(try projection.schema(g.NodeRef, b));
    const ref = try b.reference(reference);
    const saved_var = try b.variable(try projection.schema(g.Node, b));
    const saved = try b.reference(saved_var);
    const created = try b.variable(graph.appended);
    const changed = try e.field(try b.reference(created), 0);
    const new_ref = try e.field(try b.reference(created), 1);
    const produced = try b.variable(v.value);
    const finish = try b.pure(try e.tuple(result, &.{ changed, try e.variant(outcome, 0, try b.reference(produced)) }));
    const copy = try e.required(try field(e, try field(e, program, projection.Program, "uses"), data.traits.Facts, "copy"), result_schema);
    const wrap = try e.when(copy, try b.pure(try graphs.value(e, result_schema, new_ref, false)), try b.pure(try graphs.value(e, result_schema, new_ref, true)));
    const finish_created = try b.bind(produced, wrap, finish);
    const left_read = try e.call(m.frames.read, &.{ frame, try e.required(operands, e.zero) });
    const right_read = try e.call(m.frames.read, &.{ frame, try e.required(operands, e.one) });
    var dispatch = try e.fail();
    {
        const taken = try b.variable(captures.taken);
        const token = try e.replace(try e.field(try b.reference(taken), 1), machines.index(g.Capture, "schema"), result_schema);
        const body = try b.bind(left_var, left_read, try b.bind(taken, try e.call(captures.take, &.{ input, left }), try b.bind(created, try e.call(graph.template, &.{ try e.field(try b.reference(taken), 0), token }), finish_created)));
        dispatch = try e.when(try is(e, opcode, .clone_resumption), body, dispatch);
    }
    inline for ([_]p.Opcode{ .package, .resource_pack }) |kind| {
        const record = try graphs.record(e, if (kind == .package) .package else .resource, &.{ result_schema, left });
        const body = try b.bind(left_var, left_read, try b.bind(created, try e.call(graph.append, &.{ input, record }), finish_created));
        dispatch = try e.when(try is(e, opcode, kind), body, dispatch);
    }
    {
        const fields = try b.variable(try projection.schema([]const g.Value, b));
        const environment = try b.variable(graph.appended);
        const environment_record = try graphs.record(e, .environment, &.{ try b.reference(fields), try e.literal(?g.NodeRef, null) });
        const closure = try graphs.record(e, .computation, &.{ try field(e, instruction, data.activation.Instruction, "immediate"), try e.field(try b.reference(environment), 1) });
        const body = try b.bind(fields, try e.call(edge.collect, &.{ frame, operands }), try b.bind(environment, try e.call(graph.append, &.{ input, environment_record }), try b.bind(created, try e.call(graph.append, &.{ try e.field(try b.reference(environment), 0), closure }), finish_created)));
        dispatch = try e.when(try is(e, opcode, .computation), body, dispatch);
    }
    {
        const record = try graphs.record(e, .cell, &.{ result_schema, ref, try e.variant(try projection.schema(?g.Value, b), 1, right) });
        const body = try b.bind(left_var, left_read, try b.bind(right_var, right_read, try b.bind(reference, try e.call(graph.value_ref, &.{left}), try b.bind(created, try e.call(graph.append, &.{ input, record }), finish_created))));
        dispatch = try e.when(try is(e, opcode, .cell_new), body, dispatch);
    }
    inline for ([_]p.Opcode{ .cell_get, .unpack, .resource_unpack }) |kind| {
        var returned: Id = undefined;
        if (kind == .resource_unpack) {
            const resource = try b.variable(try projection.schema(g.Node, b));
            const indirect = try e.call(graph.record, &.{ input, try e.field(try e.payload(saved, @backingInt(g.NodeTag.borrow)), 1) });
            const select = try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{saved}, 0), try b.constant(u64, @backingInt(g.NodeTag.borrow))), indirect, try b.pure(saved));
            const value = try e.field(try e.payload(try b.reference(resource), @backingInt(g.NodeTag.resource)), 1);
            returned = try b.bind(resource, select, try b.pure(try e.tuple(result, &.{ input, try e.variant(outcome, 0, value) })));
        } else {
            const value = if (kind == .cell_get) try e.payload(try e.field(try e.payload(saved, @backingInt(g.NodeTag.cell)), 2), 1) else try e.field(try e.payload(saved, @backingInt(g.NodeTag.package)), 1);
            returned = try b.pure(try e.tuple(result, &.{ input, try e.variant(outcome, 0, value) }));
        }
        const body = try b.bind(left_var, left_read, try b.bind(reference, try e.call(graph.value_ref, &.{left}), try b.bind(saved_var, try e.call(graph.record, &.{ input, ref }), returned)));
        dispatch = try e.when(try is(e, opcode, kind), body, dispatch);
    }
    {
        const machine = try b.variable(m.schema);
        const unit = try b.variable(v.value);
        const cell = try e.replace(try e.payload(saved, @backingInt(g.NodeTag.cell)), 2, try e.variant(try projection.schema(?g.Value, b), 1, right));
        const record_type = try projection.schema(g.Node, b);
        const updated = try e.variant(record_type, @backingInt(g.NodeTag.cell), cell);
        const finish_set = try b.bind(machine, try e.call(graph.replace, &.{ input, ref, updated }), try b.bind(unit, try e.call(v.natural, &.{ result_schema, e.zero }), try b.pure(try e.tuple(result, &.{ try b.reference(machine), try e.variant(outcome, 0, try b.reference(unit)) }))));
        const body = try b.bind(left_var, left_read, try b.bind(right_var, right_read, try b.bind(reference, try e.call(graph.value_ref, &.{left}), try b.bind(saved_var, try e.call(graph.record, &.{ input, ref }), finish_set))));
        dispatch = try e.when(try is(e, opcode, .cell_set), body, dispatch);
    }
    try b.define(d.evaluate, dispatch);
    return cache.finish(b, d);
}
fn is(e: Author, opcode: Id, expected: p.Opcode) Error!Id {
    const tag = try e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{opcode}, 0);
    return e.binary(.equal, tag, try e.b.constant(u32, @backingInt(expected)));
}
