//! Source-level guest storage. A guest reference remains a numeric ID inside
//! ordinary data; every live and dormant node form uses its actual Horos record.
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const table = @import("table.zig");
const frames = @import("frames.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;

pub const Header = struct {
    program_identity: [32]u8,
    status: data.process_state.Status,
    roots: data.graph.Roots,
};

pub const Field = enum(usize) { program, header, nodes, blobs, work };

pub const Definition = struct {
    schema: Id,
    program: Id,
    header: Id,
    state: Id,
    nodes: table.Definition,
    blobs: table.Definition,
    frames: frames.Definition,
    hydrate: Id,
    project: Id,
    node_from_public: Id,
    node_to_public: Id,

    pub fn field(_: Definition, e: Author, machine: Id, which: Field) Error!Id {
        return e.field(machine, @backingInt(which));
    }
};

pub fn define(b: *source.Builder) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.machine/1", 0);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const program = try projection.schema(projection.Program, b);
    const header = try projection.schema(Header, b);
    const state = try projection.schema(projection.State, b);
    const frame = try frames.define(b);
    const optional_frame = try b.schema(.{ .sum = &.{ e.unit, frame.schema } });
    const node = try b.schema(.{ .product = &.{ try projection.schema(data.graph.Node, b), optional_frame } });
    const nodes = try table.define(b, node);
    const blobs = try table.define(b, try projection.schema(data.graph.Blob, b));
    const schema = try b.schema(.{ .product = &.{ program, header, nodes.table, blobs.table, e.integer } });
    const d: Definition = .{
        .node_from_public = try b.declare(&.{try projection.schema(data.process_state.Node, b)}, node, &.{}, &.{}),
        .node_to_public = try b.declare(&.{node}, try projection.schema(data.process_state.Node, b), &.{}, &.{}),
        .schema = schema,
        .program = program,
        .header = header,
        .state = state,
        .nodes = nodes,
        .blobs = blobs,
        .frames = frame,
        .hydrate = try b.declare(&.{ program, state }, schema, &.{}, &.{}),
        .project = try b.declare(&.{schema}, state, &.{}, &.{}),
    };
    const conversions = try nodeConversions(e, d);
    {
        const input = try e.param(d.hydrate, 1);
        const saved_nodes = try b.variable(nodes.table);
        const saved_blobs = try b.variable(blobs.table);
        const fields = @typeInfo(Header).@"struct";
        var header_values: [fields.field_names.len]Id = undefined;
        inline for (fields.field_names, 0..) |name, i|
            header_values[i] = try e.field(input, index(projection.State, name));
        const result = try b.pure(try e.tuple(schema, &.{
            try e.param(d.hydrate, 0),    try e.tuple(header, &header_values),
            try b.reference(saved_nodes), try b.reference(saved_blobs),
            e.zero,
        }));
        const fill_blobs = try b.bind(saved_blobs, try e.call(blobs.from_sequence, &.{try e.field(input, index(projection.State, "blobs"))}), result);
        try b.define(d.hydrate, try b.bind(saved_nodes, try e.call(conversions.hydrate, &.{try e.field(input, index(projection.State, "nodes"))}), fill_blobs));
    }
    {
        const machine = try e.param(d.project, 0);
        const saved_nodes = try b.variable(try projection.schema([]const data.process_state.Node, b));
        const saved_blobs = try b.variable(blobs.sequence);
        const fields = @typeInfo(projection.State).@"struct";
        var values: [fields.field_names.len]Id = undefined;
        inline for (fields.field_names, 0..) |name, i| {
            values[i] = if (comptime @import("std").mem.eql(u8, name, "nodes"))
                try b.reference(saved_nodes)
            else if (comptime @import("std").mem.eql(u8, name, "blobs"))
                try b.reference(saved_blobs)
            else
                try e.field(try d.field(e, machine, .header), index(Header, name));
        }
        const result = try b.pure(try e.tuple(state, &values));
        const collect_blobs = try b.bind(saved_blobs, try e.call(blobs.to_sequence, &.{try d.field(e, machine, .blobs)}), result);
        try b.define(d.project, try b.bind(saved_nodes, try e.call(conversions.project, &.{try d.field(e, machine, .nodes)}), collect_blobs));
    }
    return cache.finish(b, d);
}

fn nodeConversions(e: Author, d: Definition) Error!struct { hydrate: Id, project: Id } {
    const b = e.b;
    const public_node = try projection.schema(data.process_state.Node, b);
    const public_nodes = try projection.schema([]const data.process_state.Node, b);
    const from_node = d.node_from_public;
    const to_node = d.node_to_public;
    inline for (.{ true, false }) |hydrate| {
        const function = if (hydrate) from_node else to_node;
        const output = if (hydrate) d.nodes.element else public_node;
        const optional = b.schemas.items[@intCast(output)].product[1];
        const input = try e.param(function, 0);
        const nil = try b.variable(e.unit);
        const present = try b.variable(if (hydrate) d.frames.public else d.frames.schema);
        const converted = try b.variable(if (hydrate) d.frames.schema else d.frames.public);
        try b.define(function, try b.term(.{ .match_sum = .{
            .value = try e.field(input, 1),
            .cases = &.{
                .{ .variable = nil, .body = try b.pure(try e.tuple(output, &.{ try e.field(input, 0), try e.variant(optional, 0, e.unit_value) })) },
                .{ .variable = present, .body = try b.bind(converted, try e.call(if (hydrate) d.frames.from_public else d.frames.to_public, &.{try b.reference(present)}), try b.pure(try e.tuple(output, &.{ try e.field(input, 0), try e.variant(optional, 1, try b.reference(converted)) }))) },
            },
        } }));
    }
    const hydrate = try b.declare(&.{public_nodes}, d.nodes.table, &.{}, &.{});
    const project = try b.declare(&.{d.nodes.table}, public_nodes, &.{}, &.{});
    {
        const loop = try b.declare(&.{ public_nodes, d.nodes.table }, d.nodes.table, &.{}, &.{});
        const parts = try b.schema(.{ .product = &.{ public_node, public_nodes } });
        const popped = try b.schema(.{ .sum = &.{ e.unit, parts } });
        const nil = try b.variable(e.unit);
        const present = try b.variable(parts);
        const pair = try b.reference(present);
        const converted = try b.variable(d.nodes.element);
        const appended = try b.variable(d.nodes.table);
        const prior = try e.param(loop, 1);
        try b.define(loop, try b.term(.{ .match_sum = .{
            .value = try b.primitive(popped, .sequence_pop, &.{try e.param(loop, 0)}, 0),
            .cases = &.{
                .{ .variable = nil, .body = try b.pure(prior) },
                .{ .variable = present, .body = try b.bind(converted, try e.call(from_node, &.{try e.field(pair, 0)}), try b.bind(appended, try e.call(d.nodes.append, &.{ prior, try b.reference(converted) }), try e.call(loop, &.{ try e.field(pair, 1), try b.reference(appended) }))) },
            },
        } }));
        try b.define(hydrate, try e.call(loop, &.{ try e.param(hydrate, 0), try d.nodes.empty(b) }));
    }
    {
        const output = try table.define(b, public_node);
        const loop = try b.declare(&.{ d.nodes.table, e.integer, output.table }, output.table, &.{}, &.{});
        const input = try e.param(loop, 0);
        const offset = try e.param(loop, 1);
        const prior = try e.param(loop, 2);
        const selected = try b.variable(d.nodes.optional);
        const converted = try b.variable(public_node);
        const appended = try b.variable(output.table);
        const more = try b.bind(selected, try e.call(d.nodes.get, &.{ input, offset }), try b.bind(converted, try e.call(to_node, &.{try e.payload(try b.reference(selected), 1)}), try b.bind(appended, try e.call(output.append, &.{ prior, try b.reference(converted) }), try e.call(loop, &.{ input, try e.binary(.integer_add, offset, e.one), try b.reference(appended) }))));
        try b.define(loop, try e.when(try e.binary(.less, offset, try e.field(input, 0)), more, try b.pure(prior)));
        const collected = try b.variable(output.table);
        try b.define(project, try b.bind(collected, try e.call(loop, &.{ try e.param(project, 0), e.zero, try output.empty(b) }), try e.call(output.to_sequence, &.{try b.reference(collected)})));
    }
    return .{ .hydrate = hydrate, .project = project };
}

pub fn index(comptime T: type, comptime name: []const u8) usize {
    const names = switch (@typeInfo(T)) {
        .@"struct" => |s| s.field_names,
        .@"union" => |u| u.field_names,
        else => @compileError("projected fields require a struct or union"),
    };
    inline for (names, 0..) |field, i|
        if (comptime @import("std").mem.eql(u8, field, name)) return i;
    @compileError("missing projected field " ++ @typeName(T) ++ "." ++ name);
}
