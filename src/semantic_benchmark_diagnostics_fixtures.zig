const std = @import("std");
const source = @import("horos").source;
const data = @import("horos_data");
const Author = @import("semantic/author.zig").Author;
const analysis = @import("semantic/analysis.zig");
const bench = @import("semantic_benchmark.zig");
const protocol = data.invocation;

pub const Family = enum { scalar, structured_fields, blob, aliased_graph };
pub const Fixture = struct {
    family: Family,
    sample: usize,
    requests: usize,
    elements: usize,
    image: []const u8,
    input: []const u8,
};
pub const Reference = struct {
    exchanges: []analysis.ReplayExchange,
    terminal: []const u8,
    pending: []const u8,
    pending_checkpoints: []const []const u8,
    terminal_checkpoint: []const u8,
};

pub fn encode(a: std.mem.Allocator, module: source.Module) ![]u8 {
    var compiled = try source.lower(a, module);
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    return bytes;
}

pub fn make(a: std.mem.Allocator, family: Family, sample: usize) !Fixture {
    const elements = switch (family) {
        .scalar => 1,
        .structured_fields => @as(usize, 4) << @intCast(sample * 2),
        .blob, .aliased_graph => @as(usize, 64) << @intCast(sample * 2),
    };
    const requests = @as(usize, 2) << @intCast(sample);
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try program(&b, family, elements, requests);
    const image = try encode(a, module);
    errdefer a.free(image);
    return .{
        .family = family,
        .sample = sample,
        .requests = requests,
        .elements = elements,
        .image = image,
        .input = try arguments(a, family, elements),
    };
}

fn program(b: *source.Builder, family: Family, elements: usize, requests: usize) !source.Module {
    if (family == .aliased_graph) return aliasedProgram(b, requests);
    const e = try Author.init(b);
    const fields = try b.allocator().alloc(data.program.Id, elements);
    @memset(fields, e.integer);
    const payload = switch (family) {
        .scalar => e.integer,
        .structured_fields => try b.schema(.{ .product = fields }),
        .blob, .aliased_graph => try b.schema(.bytes),
    };
    const result = payload;
    const effect = try b.effect(.{
        .identity = "benchmark/diagnostic",
        .payload = payload,
        .result = e.unit,
    });
    const entry = try b.declare(&.{payload}, result, &.{effect}, &.{});
    const input = try e.param(entry, 0);
    const value = input;
    const retained = try b.variable(result);
    var body = try b.pure(try b.reference(retained));
    for (0..requests) |_| {
        const ignored = try b.variable(e.unit);
        body = try b.bind(ignored, try b.term(.{ .perform = .{
            .effect = effect,
            .payload = input,
        } }), body);
    }
    try b.define(entry, try b.bind(retained, try b.pure(value), body));
    return b.module(entry, e.unit);
}

fn arguments(a: std.mem.Allocator, family: Family, elements: usize) ![]u8 {
    if (family == .scalar or family == .structured_fields) {
        const bytes = try a.alloc(u8, elements * 8);
        for (0..elements) |i| std.mem.writeInt(u64, bytes[i * 8 ..][0..8], 41 + i, .little);
        return bytes;
    }
    var size: data.wire.Writer = .{};
    try size.natural(elements);
    const bytes = try a.alloc(u8, size.position + elements);
    var writer: data.wire.Writer = .{ .output = bytes };
    try writer.natural(elements);
    @memset(bytes[writer.position..], 41);
    return bytes;
}

pub fn reference(a: std.mem.Allocator, trace: []const bench.Step) !Reference {
    var exchanges: std.ArrayList(analysis.ReplayExchange) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    var terminal: ?[]const u8 = null;
    for (trace) |step| {
        var outcome = try protocol.decode(protocol.Outcome, a, step.outcome);
        defer outcome.deinit();
        switch (outcome.value) {
            .requested => |value| {
                var request = try protocol.decode(protocol.Request, a, value.request);
                defer request.deinit();
                try exchanges.append(a, .{ .expected_request = .{
                    .effect = request.value.binding.effect,
                    .payload = try a.dupe(u8, request.value.binding.payload),
                }, .response = &.{} });
                try pending.append(a, step.checkpoint);
            },
            .completed => |value| terminal = try a.dupe(u8, value),
            .progressed => {},
            else => return error.UnexpectedDiagnosticBoundary,
        }
    }
    return .{
        .exchanges = exchanges.items,
        .terminal = terminal orelse return error.NoTerminal,
        .pending = if (pending.items.len > 0) pending.items[0] else return error.NoPending,
        .pending_checkpoints = pending.items,
        .terminal_checkpoint = trace[trace.len - 1].checkpoint,
    };
}

pub fn assertAliased(a: std.mem.Allocator, checkpoint: []const u8) !void {
    var state = try data.state_image.decodeGraph(a, checkpoint);
    defer state.deinit();
    for (state.state.nodes) |node| {
        if (node.record != .aggregate) continue;
        const fields = node.record.aggregate.fields;
        if (fields.len != 4 or fields[0].body != .reference) continue;
        var matching: usize = 0;
        for (fields) |field| {
            if (field.body == .reference and
                field.body.reference.id == fields[0].body.reference.id)
                matching += 1;
        }
        if (matching == 4) return;
    }
    return error.MissingRetainedAliases;
}

fn aliasedProgram(b: *source.Builder, requests: usize) !source.Module {
    const e = try Author.init(b);
    const bytes = try b.schema(.bytes);
    const effect = try b.effect(.{
        .identity = "benchmark/diagnostic",
        .payload = bytes,
        .result = e.unit,
    });
    const entry = try b.declare(&.{bytes}, bytes, &.{effect}, &.{});
    const input = try e.param(entry, 0);
    const inner = try b.declare(&.{}, bytes, &.{}, &.{});
    try b.define(inner, try b.pure(input));
    const callable = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = bytes,
        .capture_bound = &.{bytes},
    } } });
    const closure = try b.variable(callable);
    const reference_value = try b.reference(closure);
    const aliases = try b.schema(.{ .product = &.{ callable, callable, callable, callable } });
    const retained = try b.variable(aliases);
    var body = try b.term(.{ .apply = .{
        .computation = try e.field(try b.reference(retained), 0),
        .arguments = &.{},
    } });
    for (0..requests) |_| {
        body = try b.bind(try b.variable(e.unit), try b.term(.{ .perform = .{
            .effect = effect,
            .payload = input,
        } }), body);
    }
    body = try b.bind(retained, try b.pure(try e.tuple(aliases, &.{
        reference_value, reference_value, reference_value, reference_value,
    })), body);
    try b.define(entry, try b.bind(closure, try b.pure(try b.lambda(inner, callable)), body));
    return b.module(entry, e.unit);
}
