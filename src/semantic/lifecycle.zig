//! Source initialization and controls over admitted guest inputs. ERQ3/ERS3
//! binding and byte admission remain with the existing facade data owner.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const control = @import("control.zig");
const graphs = @import("graph.zig");
const edges = @import("edges.zig");
const unwind = @import("unwind.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const field = edges.field;
pub const Definition = struct { initialize: Id, respond: Id, resume_yield: Id, cancel: Id };
fn hasStatus(e: Author, m: machines.Definition, input: Id, wanted: data.process_state.Status) Error!Id {
    const current = try field(e, try m.field(e, input, .header), machines.Header, "status");
    return e.binary(.equal, try e.b.primitive(try e.b.scalar(u32), .enum_tag, &.{current}, 0), try e.b.constant(u32, @backingInt(wanted)));
}
pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.lifecycle/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const c = try control.define(b, m);
    const graph = try graphs.define(b, m);
    const values = try @import("values.zig").define(b, m);
    const codec = try @import("codec.zig").define(b, m);
    const bytes = try b.schema(.bytes);
    const d: Definition = .{
        .initialize = try b.declare(&.{ m.program, bytes }, m.schema, &.{}, &.{}),
        .respond = try b.declare(&.{ m.schema, bytes }, m.schema, &.{}, &.{}),
        .resume_yield = try b.declare(&.{m.schema}, m.schema, &.{}, &.{}),
        .cancel = try b.declare(&.{ m.schema, try projection.schema(data.invocation.Reason, b) }, m.schema, &.{}, &.{}),
    };
    {
        const program = try e.param(d.initialize, 0);
        const input = try e.param(d.initialize, 1);
        const code = try edges.code(e, program);
        const entry = try field(e, try field(e, code, data.activation.Program, "roots"), data.program.Roots, "entry");
        const function = try edges.function(e, program, entry);
        const layout = try e.field(try field(e, function, data.activation.Function, "layout"), 0);
        const slots = try field(e, function, data.activation.Function, "inputs");
        const header = try e.tuple(m.header, &.{ try field(e, program, projection.Program, "identity"), try e.literal(data.process_state.Status, .active), try e.literal(g.Roots, .{}) });
        const initial = try e.tuple(m.schema, &.{ program, header, try m.nodes.empty(b), try m.blobs.empty(b), e.zero });
        const vals = try projection.schema([]const g.Value, b);
        const loop = try b.declare(&.{ m.schema, bytes, e.integer, e.integer, vals }, m.schema, &.{}, &.{});
        const machine = try e.param(loop, 0);
        const encoded = try e.param(loop, 1);
        const at = try e.param(loop, 2);
        const offset = try e.param(loop, 3);
        const prior = try e.param(loop, 4);
        const guest_program = try m.field(e, machine, .program);
        const guest_code = try edges.code(e, guest_program);
        const guest_entry = try field(e, try field(e, guest_code, data.activation.Program, "roots"), data.program.Roots, "entry");
        const guest_fn = try edges.function(e, guest_program, guest_entry);
        const guest_slots = try field(e, guest_fn, data.activation.Function, "inputs");
        const guest_layout = try e.field(try field(e, guest_fn, data.activation.Function, "layout"), 0);
        const schema = try e.required(guest_layout, try e.required(guest_slots, at));
        const end = try b.variable(e.integer);
        const decoded = try b.variable(values.result);
        const literal = try e.tuple(try projection.schema(data.program.Literal, b), &.{ schema, try e.slice(encoded, offset, try b.reference(end)) });
        var more = try b.bind(decoded, try e.call(values.literal, &.{ machine, literal }), try e.call(loop, &.{ try e.field(try b.reference(decoded), 0), encoded, try e.binary(.integer_add, at, e.one), try b.reference(end), try unwind.concat(e, prior, try unwind.seq(e, &.{try e.field(try b.reference(decoded), 1)})) }));
        more = try b.bind(end, try e.call(codec.skip, &.{ guest_program, schema, encoded, offset }), more);
        const none = try e.literal(?g.NodeRef, null);
        const enter = try e.call(c.enter, &.{ machine, guest_entry, prior, none, none, none });
        const finish = try e.when(try e.binary(.equal, offset, try b.primitive(e.integer, .blob_length, &.{encoded}, 0)), enter, try e.fail());
        try b.define(loop, try e.when(try e.binary(.less, at, try b.primitive(e.integer, .sequence_length, &.{guest_slots}, 0)), more, finish));
        try b.define(d.initialize, try e.call(loop, &.{ initial, input, e.zero, e.zero, try unwind.empty(e) }));
        _ = layout;
        _ = slots;
    }
    {
        const input = try e.param(d.respond, 0);
        const pending = try e.payload(try field(e, try control.roots(e, m, input), g.Roots, "pending"), 1);
        const record = try b.variable(try projection.schema(g.Node, b));
        const request = try e.payload(try b.reference(record), @backingInt(g.NodeTag.pending));
        const effect = try e.required(try field(e, try edges.code(e, try m.field(e, input, .program)), data.activation.Program, "effects"), try e.field(request, 0));
        const result = try b.variable(values.result);
        const changed = try b.variable(m.schema);
        const literal = try e.tuple(try projection.schema(data.program.Literal, b), &.{ try field(e, effect, data.program.Effect, "result"), try e.param(d.respond, 1) });
        var body = try b.bind(changed, try e.call(c.resume_continuation, &.{ try e.field(try b.reference(result), 0), try e.field(request, 2), try e.field(try b.reference(result), 1) }), try b.pure(try unwind.status(e, m, try unwind.root(e, m, try b.reference(changed), "pending", try e.literal(?g.NodeRef, null)), .active)));
        body = try b.bind(result, try e.call(values.literal, &.{ input, literal }), body);
        body = try b.bind(record, try e.call(graph.record, &.{ input, pending }), body);
        try b.define(d.respond, try e.when(try hasStatus(e, m, input, .parked), body, try e.fail()));
    }
    {
        const input = try e.param(d.resume_yield, 0);
        try b.define(d.resume_yield, try e.when(try hasStatus(e, m, input, .yielded), try b.pure(try unwind.status(e, m, input, .active)), try e.fail()));
    }
    {
        const input = try e.param(d.cancel, 0);
        var body = try e.fail();
        inline for (.{ data.process_state.Status.active, data.process_state.Status.yielded, data.process_state.Status.parked, data.process_state.Status.unwinding }) |s| body = try e.when(try hasStatus(e, m, input, s), try e.call(c.unwind.cleanup.cancel, &.{ input, try e.param(d.cancel, 1) }), body);
        try b.define(d.cancel, body);
    }
    return cache.finish(b, d);
}
