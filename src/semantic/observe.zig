//! Read-only guest observations, produced by the authored core at guest cuts.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const control = @import("control.zig");
const graphs = @import("graph.zig");
const edges = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
pub const Observation = union(enum) {
    progressed,
    yielded,
    requested: struct { effect: Id, payload: []const u8 },
    completed: []const u8,
    failed: struct { value: []const u8, cleanup_failures: []const []const u8, cancellation: ?data.invocation.Reason },
    cancelled: struct { reason: data.invocation.Reason, cleanup_failures: []const []const u8 },
};
pub fn define(b: *source.Builder, m: machines.Definition) Error!Id {
    const cache = try b.specialization(Id, "kosmos.semantic.observe/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const values = try @import("values.zig").define(b, m);
    const schema = try projection.schema(Observation, b);
    const bytes = try b.schema(.bytes);
    const failures_type = try projection.schema([]const []const u8, b);
    const failure_table = try @import("table.zig").define(b, bytes);
    const failures = try b.declare(&.{ m.schema, try projection.schema([]const g.Value, b), e.integer, failure_table.table }, failures_type, &.{}, &.{});
    {
        const input = try e.param(failures, 0);
        const list = try e.param(failures, 1);
        const at = try e.param(failures, 2);
        const prior = try e.param(failures, 3);
        const encoded = try b.variable(bytes);
        const appended = try b.variable(failure_table.table);
        const more = try b.bind(encoded, try e.call(values.bytes, &.{ input, try e.required(list, at) }), try b.bind(appended, try e.call(failure_table.append, &.{ prior, try b.reference(encoded) }), try e.call(failures, &.{ input, list, try e.binary(.integer_add, at, e.one), try b.reference(appended) })));
        try b.define(failures, try e.when(try e.binary(.less, at, try b.primitive(e.integer, .sequence_length, &.{list}, 0)), more, try e.call(failure_table.to_sequence, &.{prior})));
    }
    const f = try b.declare(&.{m.schema}, schema, &.{}, &.{});
    const input = try e.param(f, 0);
    const roots = try control.roots(e, m, input);
    const status = try edges.field(e, try m.field(e, input, .header), machines.Header, "status");
    const status_tag = try b.primitive(try b.scalar(u32), .enum_tag, &.{status}, 0);
    const record = try b.variable(try projection.schema(g.Node, b));
    const encoded = try b.variable(bytes);
    const encoded_failures = try b.variable(failures_type);
    const exit = try e.payload(try b.reference(record), @backingInt(g.NodeTag.exit));
    const reason = try e.field(exit, 0);
    const pending = try e.payload(try b.reference(record), @backingInt(g.NodeTag.pending));
    var body = try e.fail();
    inline for (.{ data.process_state.Status.active, data.process_state.Status.unwinding, data.process_state.Status.yielded, data.process_state.Status.parked, data.process_state.Status.completed, data.process_state.Status.failed, data.process_state.Status.cancelled }) |s| {
        const i: usize = switch (s) {
            .active, .unwinding => 0,
            .yielded => 1,
            .parked => 2,
            .completed => 3,
            .failed => 4,
            .cancelled => 5,
        };
        const payload_schema = b.schemas.items[@intCast(schema)].sum[i];
        var branch: Id = undefined;
        switch (s) {
            .active, .unwinding, .yielded => branch = try b.pure(try e.variant(schema, i, e.unit_value)),
            .parked => {
                branch = try b.bind(encoded, try e.call(values.bytes, &.{ input, try e.field(pending, 1) }), try b.pure(try e.variant(schema, i, try e.tuple(payload_schema, &.{ try e.field(pending, 0), try b.reference(encoded) }))));
                branch = try b.bind(record, try e.call(graph.record, &.{ input, try e.payload(try edges.field(e, roots, g.Roots, "pending"), 1) }), branch);
            },
            .completed => {
                branch = try b.bind(encoded, try e.call(values.bytes, &.{ input, try e.payload(reason, 0) }), try b.pure(try e.variant(schema, i, try b.reference(encoded))));
                branch = try b.bind(record, try e.call(graph.record, &.{ input, try e.payload(try edges.field(e, roots, g.Roots, "exit"), 1) }), branch);
            },
            .failed, .cancelled => {
                const cancellation = try edges.field(e, exit, g.Exit, "cancellation");
                const payload = if (s == .failed) try e.tuple(payload_schema, &.{ try b.reference(encoded), try b.reference(encoded_failures), cancellation }) else try e.tuple(payload_schema, &.{ try e.payload(cancellation, 1), try b.reference(encoded_failures) });
                branch = try b.pure(try e.variant(schema, i, payload));
                if (s == .failed) branch = try b.bind(encoded, try e.call(values.bytes, &.{ input, try e.payload(reason, 1) }), branch);
                branch = try b.bind(encoded_failures, try e.call(failures, &.{ input, try edges.field(e, exit, g.Exit, "cleanup_failures"), e.zero, try failure_table.empty(b) }), branch);
                branch = try b.bind(record, try e.call(graph.record, &.{ input, try e.payload(try edges.field(e, roots, g.Roots, "exit"), 1) }), branch);
            },
        }
        body = try e.when(try e.binary(.equal, status_tag, try b.constant(u32, @backingInt(s))), branch, body);
    }
    try b.define(f, body);
    return cache.finish(b, f);
}
