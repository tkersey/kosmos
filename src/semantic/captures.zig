//! Consumption, instantiation and deep/shallow reattachment of guest captures.
const data = @import("horos_data");
const source = @import("horos").source;
const machines = @import("machine.zig");
const projection = @import("projection.zig");
const graphs = @import("graph.zig");
const clones = @import("clone.zig");
const access = @import("edges.zig");
const Author = @import("author.zig").Author;
const Id = data.program.Id;
const Error = source.Error;
const g = data.graph;
const p = data.program;
pub const Definition = struct { take: Id, taken: Id, activate: Id, prepare: Id, prepared: Id };

pub fn define(b: *source.Builder, m: machines.Definition) Error!Definition {
    const cache = try b.specialization(Definition, "kosmos.semantic.captures/1", m.schema);
    if (cache.cached) |saved| return saved;
    const e = try Author.init(b);
    const graph = try graphs.define(b, m);
    const clone = try clones.define(b, m);
    const node = try projection.schema(g.Node, b);
    const ref_type = try projection.schema(g.NodeRef, b);
    const optional_ref = try projection.schema(?g.NodeRef, b);
    const capture = try projection.schema(g.Capture, b);
    const prepared = try b.schema(.{ .product = &.{ m.schema, optional_ref } });
    const d: Definition = .{
        .take = try b.declare(&.{ m.schema, try projection.schema(g.Value, b) }, clone.result, &.{}, &.{}),
        .taken = clone.result,
        .activate = try b.declare(&.{ m.schema, capture, ref_type }, m.schema, &.{}, &.{}),
        .prepare = try b.declare(&.{ m.schema, capture, ref_type }, prepared, &.{}, &.{}),
        .prepared = prepared,
    };
    {
        const input = try e.param(d.take, 0);
        const reference = try b.variable(ref_type);
        const record = try b.variable(node);
        const saved = try b.reference(record);
        const single = try e.payload(saved, @backingInt(g.NodeTag.one_shot));
        const changed = try b.variable(m.schema);
        const consumed = try e.replace(single, machines.index(g.Capture, "capture"), try e.literal(?g.NodeRef, null));
        const one = try b.bind(changed, try e.call(graph.replace, &.{ input, try b.reference(reference), try e.variant(node, @backingInt(g.NodeTag.one_shot), consumed) }), try b.pure(try e.tuple(d.taken, &.{ try b.reference(changed), single })));
        const valid_one = try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{try e.field(single, machines.index(g.Capture, "capture"))}, 0), e.one), one, try e.fail());
        const multiple = try e.call(clone.instantiate, &.{ input, try e.payload(saved, @backingInt(g.NodeTag.multi_template)) });
        const tag = try b.primitive(e.integer, .variant_tag, &.{saved}, 0);
        const dispatch = try e.when(try e.binary(.equal, tag, try b.constant(u64, @backingInt(g.NodeTag.multi_template))), multiple, try e.when(try e.binary(.equal, tag, try b.constant(u64, @backingInt(g.NodeTag.one_shot))), valid_one, try e.fail()));
        try b.define(d.take, try b.bind(reference, try e.call(graph.value_ref, &.{try e.param(d.take, 1)}), try b.bind(record, try e.call(graph.record, &.{ input, try b.reference(reference) }), dispatch)));
    }
    {
        const input = try e.param(d.activate, 0);
        const token = try e.param(d.activate, 1);
        const ref = try e.field(token, machines.index(g.Capture, "delimiter"));
        const record = try b.variable(node);
        const attachment = try e.payload(try b.reference(record), @backingInt(g.NodeTag.attachment));
        var changed = try e.replace(attachment, 2, try e.variant(optional_ref, 1, try e.param(d.activate, 2)));
        changed = try e.replace(changed, 3, try e.literal(@FieldType(@FieldType(g.Node, "attachment"), "phase"), .active));
        try b.define(d.activate, try b.bind(record, try e.call(graph.record, &.{ input, ref }), try e.call(graph.replace, &.{ input, ref, try e.variant(node, @backingInt(g.NodeTag.attachment), changed) })));
    }
    const replace_links = try b.declare(&.{ m.schema, ref_type, optional_ref, e.integer }, m.schema, &.{}, &.{});
    {
        const input = try e.param(replace_links, 0);
        const delimiter = try e.param(replace_links, 1);
        const outer = try e.param(replace_links, 2);
        const index = try e.param(replace_links, 3);
        const selected = try b.variable(m.nodes.optional);
        const element = try e.payload(try b.reference(selected), 1);
        const record = try e.field(element, 0);
        const changed = try b.variable(m.schema);
        var dispatch = try b.pure(input);
        inline for ([_]g.NodeTag{ .control, .continuation, .handler, .attachment, .protection, .one_shot, .multi_template }) |tag| {
            const name = @tagName(tag);
            const T = @FieldType(g.Node, name);
            const field_name = if (tag == .attachment) "outer" else "evidence";
            const payload = try e.payload(record, @backingInt(tag));
            const link = try e.field(payload, machines.index(T, field_name));
            const replacement = try e.variant(node, @backingInt(tag), try e.replace(payload, machines.index(T, field_name), outer));
            const same = try e.binary(.equal, try e.field(try e.payload(link, 1), 0), try e.field(delimiter, 0));
            const update = try e.call(graph.replace, &.{ input, try e.tuple(ref_type, &.{index}), replacement });
            const unchanged = try b.pure(input);
            const choose = try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{link}, 0), e.zero), unchanged, try e.when(same, update, unchanged));
            dispatch = try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{record}, 0), try b.constant(u64, @backingInt(tag))), choose, dispatch);
        }
        const next = try b.bind(selected, try e.call(m.nodes.get, &.{ try m.field(e, input, .nodes), index }), try b.bind(changed, dispatch, try e.call(replace_links, &.{ try b.reference(changed), delimiter, outer, try e.binary(.integer_add, index, e.one) })));
        try b.define(replace_links, try e.when(try e.binary(.less, index, try e.field(try m.field(e, input, .nodes), 0)), next, try b.pure(input)));
    }
    {
        const input = try e.param(d.prepare, 0);
        const token = try e.param(d.prepare, 1);
        const after = try e.param(d.prepare, 2);
        const delimiter = try e.field(token, machines.index(g.Capture, "delimiter"));
        const evidence = try e.field(token, machines.index(g.Capture, "evidence"));
        const program = try m.field(e, input, .program);
        const shapes = try access.field(e, try access.code(e, program), data.activation.Program, "schemas");
        const signature = try e.payload(try e.payload(try e.required(shapes, try e.field(token, 0)), @backingInt(p.SchemaTag.internal)), @backingInt(p.InternalTag.resumption));
        const mode = try access.field(e, signature, p.ResumptionType, "mode");
        const changed = try b.variable(m.schema);
        const deep = try b.bind(changed, try e.call(d.activate, &.{ input, token, after }), try b.pure(try e.tuple(prepared, &.{ try b.reference(changed), evidence })));
        const original = try b.variable(node);
        const replacement = try b.variable(m.nodes.element);
        const nodes = try b.variable(m.nodes.table);
        const outer = try e.field(try e.payload(try b.reference(original), @backingInt(g.NodeTag.attachment)), 1);
        const selected_evidence = try b.variable(optional_ref);
        const unchanged = try b.pure(evidence);
        const same = try e.binary(.equal, try e.field(try e.payload(evidence, 1), 0), try e.field(delimiter, 0));
        const choose = try e.when(try e.binary(.equal, try b.primitive(e.integer, .variant_tag, &.{evidence}, 0), e.zero), unchanged, try e.when(same, try b.pure(outer), unchanged));
        var shallow = try b.bind(selected_evidence, choose, try b.pure(try e.tuple(prepared, &.{ try b.reference(changed), try b.reference(selected_evidence) })));
        shallow = try b.bind(changed, try e.call(replace_links, &.{ try e.replace(input, @backingInt(machines.Field.nodes), try b.reference(nodes)), delimiter, outer, e.zero }), shallow);
        shallow = try b.bind(nodes, try e.call(m.nodes.set, &.{ try m.field(e, input, .nodes), try e.field(delimiter, 0), try b.reference(replacement) }), shallow);
        shallow = try b.bind(replacement, try e.call(graph.element, &.{ input, after }), shallow);
        shallow = try b.bind(original, try e.call(graph.record, &.{ input, delimiter }), shallow);
        try b.define(d.prepare, try e.when(try e.binary(.equal, try b.primitive(try b.scalar(u32), .enum_tag, &.{mode}, 0), try b.constant(u32, @backingInt(p.Mode.deep))), deep, shallow));
    }
    return cache.finish(b, d);
}
