//! Selected, nonsemantic observations at established guest cuts. These source
//! helpers return metadata only; they never return a replacement guest machine.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const edges = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;

pub const Hooks = struct {
    control: bool = false,
    storage: bool = false,

    pub fn enabled(self: Hooks) bool {
        return self.control or self.storage;
    }
};
pub const Control = struct { status: data.process_state.Status, effect: ?Id };
/// Counts of retained source storage slots, including slots not yet reclaimed
/// by the normal guest collector. They are not a claim of graph reachability.
pub const Storage = struct { node_slots: u64, blob_slots: u64 };
pub const Trace = struct { control: ?Control, storage: ?Storage };
pub const Output = struct { source: [32]u8, realization: [32]u8, guest: [32]u8, guest_revision: u64, trace: Trace };

pub fn define(b: *source.Builder, m: machines.Definition, hooks: Hooks) source.Error!Id {
    const e = try Author.init(b);
    const result = try projection.schema(Trace, b);
    const f = try b.declare(&.{m.schema}, result, &.{}, &.{});
    const machine = try e.param(f, 0);
    const optional_control = try projection.schema(?Control, b);
    const optional_storage = try projection.schema(?Storage, b);
    var control = try e.variant(optional_control, 0, e.unit_value);
    var storage = try e.variant(optional_storage, 0, e.unit_value);
    var body: Id = undefined;
    const effect_type = try projection.schema(?Id, b);
    const effect = try b.variable(effect_type);
    if (hooks.control) {
        const status = try edges.field(e, try m.field(e, machine, .header), machines.Header, "status");
        control = try e.variant(optional_control, 1, try e.tuple(try projection.schema(Control, b), &.{ status, try b.reference(effect) }));
    }
    if (hooks.storage) storage = try e.variant(optional_storage, 1, try e.tuple(try projection.schema(Storage, b), &.{
        try e.field(try m.field(e, machine, .nodes), 0),
        try e.field(try m.field(e, machine, .blobs), 0),
    }));
    body = try b.pure(try e.tuple(result, &.{ control, storage }));
    if (hooks.control) {
        const graph = try @import("graph.zig").define(b, m);
        const roots = try @import("control.zig").roots(e, m, machine);
        const pending = try edges.field(e, roots, data.graph.Roots, "pending");
        const record = try b.variable(try projection.schema(data.graph.Node, b));
        const some = try b.bind(record, try e.call(graph.record, &.{ machine, try e.payload(pending, 1) }), try b.pure(try e.variant(effect_type, 1, try e.field(try e.payload(try b.reference(record), @backingInt(data.graph.NodeTag.pending)), 0))));
        const absent = try b.pure(try e.variant(effect_type, 0, e.unit_value));
        const selected = try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{pending}, 0), e.one), some, absent);
        body = try b.bind(effect, selected, body);
    }
    try b.define(f, body);
    return f;
}
