//! Explicit compiler-dependent fixture builder and independent native byte peer.
const std = @import("std");
const horos = @import("horos");
const runtime = @import("kosmos");

pub fn main(init: std.process.Init) !void {
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    const mode = arguments.next() orelse return error.MissingMode;
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    if (std.mem.eql(u8, mode, "invoke")) {
        var buffer: [4096]u8 = undefined;
        var input = std.Io.File.stdin().reader(init.io, &buffer);
        const bytes = try input.interface.allocRemaining(init.gpa, .unlimited);
        defer init.gpa.free(bytes);
        const result = try runtime.invocation.invokeBytes(init.gpa, bytes);
        defer init.gpa.free(result);
        try output.interface.writeAll(result);
    } else if (std.mem.eql(u8, mode, "image")) {
        const name = arguments.next() orelse return error.MissingName;
        if (std.mem.eql(u8, name, "components") or std.mem.eql(u8, name, "componentsDouble") or std.mem.eql(u8, name, "componentsRecursive")) {
            const bytes = try linkedImage(init.gpa, name);
            defer init.gpa.free(bytes);
            try output.interface.writeAll(bytes);
            try output.interface.flush();
            return;
        }
        var builder = horos.source.Builder.init(init.gpa);
        defer builder.deinit();
        const module = blk: {
            if (std.mem.eql(u8, name, "largeRequest")) break :blk try largeRequest(&builder);
            if (std.mem.eql(u8, name, "retainedScopeGeneral"))
                break :blk try horos.source.examples.retainedScope(&builder);
            if (std.mem.eql(u8, name, "install")) break :blk try horos.source.examples.installations(&builder, 64);
            if (std.mem.eql(u8, name, "resource")) break :blk try horos.source.examples.resourceScalar(&builder);
            if (std.mem.eql(u8, name, "custody")) break :blk try horos.source.examples.custodyOrder(&builder, 0);
            inline for (.{ "retainedScope", "branchingTail", "branchingTailProtected", "deep", "recursive", "reentrant", "generator", "shallow", "scalarContracts" }) |candidate| {
                if (std.mem.eql(u8, name, candidate)) break :blk try @field(horos.source.examples, candidate)(&builder);
            }
            return error.InvalidName;
        };
        // The general reference fixture rewrites clause functions by source ID.
        // A component retains those declarations; encoding still admits a closed Program.
        var compiled = if (std.mem.eql(u8, name, "retainedScopeGeneral"))
            (try horos.source.component.compile(init.gpa, module, .{ .exports = &.{} })).construction
        else
            try horos.program.compile(init.gpa, module);
        defer compiled.deinit();
        if (std.mem.eql(u8, name, "retainedScopeGeneral")) {
            const ir = horos.data.activation;
            const a = builder.allocator();
            const handlers = try a.dupe(ir.Handler, compiled.program.handlers);
            for (handlers, builder.handlers.items) |*handler, original| {
                const clauses = try a.dupe(ir.Clause, handler.clauses);
                for (clauses, original.clauses) |*clause, source_clause| {
                    clause.strategy = .general;
                    clause.function = source_clause.function;
                }
                handler.clauses = clauses;
            }
            compiled.program.handlers = handlers;
        }
        const bytes = try init.gpa.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
        defer init.gpa.free(bytes);
        _ = try compiled.encode(init.gpa, bytes);
        try output.interface.writeAll(bytes);
    } else return error.InvalidMode;
    try output.interface.flush();
}

fn largeRequest(b: *horos.source.Builder) !horos.source.Module {
    const a = horos.authoring;
    const c = try a.Context.init(b);
    const Envelope = struct { content: struct { bytes: []const u8 } };
    const bytes = try c.schema([]const u8);
    const unit = try c.schema(void);
    const envelope = try c.schema(Envelope);
    const content = try c.schema(@FieldType(Envelope, "content"));
    const project = try c.function("request bytes", .{ .envelope = envelope }, bytes, .{});
    const projection = try c.body(project);
    const nested = try projection.field(try projection.parameter("envelope"), "content");
    const payload = try projection.field(nested, "bytes");
    comptime std.debug.assert(@TypeOf(payload) == *const a.Value(a.Shape([]const u8)));
    try c.define(project, try projection.ret(payload));

    const effect = try c.external("capacity/large", bytes, unit);
    const entry = try c.function("large request", .{ .input = bytes }, bytes, .{effect});
    const body = try c.body(entry);
    const input = try body.parameter("input");
    const wrapped = try body.product(envelope, .{
        .content = try body.product(content, .{ .bytes = input }),
    });
    const requested = try body.call(project, .{ .envelope = wrapped });
    _ = try body.perform(effect, requested);
    try c.define(entry, try body.ret(input));
    return c.module(entry, unit);
}

fn linkedImage(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const examples = horos.source.component_examples;
    const data = horos.data;
    const doubled = std.mem.eql(u8, name, "componentsDouble");
    const recursive = std.mem.eql(u8, name, "componentsRecursive");
    const kinds: []const examples.Kind = if (recursive) &.{ .even, .odd } else &.{ .call, .state, .suspended, .double };
    const keys: []const []const u8 = if (recursive) &.{ "even", "odd" } else &.{ "call", "state", "suspend", "double" };
    var instances: [4]data.linker.Instance = undefined;
    var initialized: usize = 0;
    defer for (instances[0..initialized]) |instance| allocator.free(instance.object);
    for (kinds, keys, instances[0..kinds.len]) |kind, key, *instance| {
        instance.* = .{ .key = key, .object = try examples.emit(allocator, kind) };
        initialized += 1;
    }
    // Each emitter has already destroyed its source and construction owners.
    var linked = try data.linker.link(allocator, instances[0..@as(usize, if (recursive) 2 else if (doubled) 4 else 3)], if (recursive) &examples.recursive_bindings else if (doubled) &examples.double_bindings else &examples.bindings, .{
        .instance = if (recursive) "even" else if (doubled) "double" else "suspend",
        .symbol = "main",
    });
    defer linked.deinit();
    const bytes = try allocator.alloc(u8, try data.program_image.encodedLength(linked.program));
    errdefer allocator.free(bytes);
    _ = try linked.encode(allocator, bytes);
    return bytes;
}
