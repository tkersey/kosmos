const std = @import("std");
const horos = @import("horos");
const runtime = @import("kosmos");

pub fn main(init: std.process.Init) !void {
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    const mode = arguments.next() orelse return error.MissingMode;
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    if (std.mem.eql(u8, mode, "prepared-invoke-stream")) {
        try preparedStream(init.gpa, init.io, &output.interface);
    } else if (std.mem.eql(u8, mode, "specialized-invoke")) {
        try specializedInvoke(init.gpa, init.io, &output.interface);
    } else if (std.mem.eql(u8, mode, "invoke")) {
        var buffer: [4096]u8 = undefined;
        var input = std.Io.File.stdin().reader(init.io, &buffer);
        const bytes = try input.interface.allocRemaining(init.gpa, .unlimited);
        defer init.gpa.free(bytes);
        const result = try runtime.invocation.invokeBytes(init.gpa, bytes);
        defer init.gpa.free(result);
        try output.interface.writeAll(result);
    } else if (std.mem.eql(u8, mode, "image")) {
        const name = arguments.next() orelse return error.MissingName;
        try writeImage(init.gpa, name, &output.interface);
    } else return error.InvalidMode;
    try output.interface.flush();
}

const PreparedPeer = struct {
    allocator: std.mem.Allocator,
    image: []u8 = &.{},
    prepared: ?runtime.Prepared = null,

    fn deinit(self: *PreparedPeer) void {
        if (self.prepared) |*prepared| prepared.deinit();
        self.allocator.free(self.image);
    }

    fn invoke(self: *PreparedPeer, bytes: []const u8) ![]u8 {
        const data = horos.data;
        const a = self.allocator;
        var command = try data.invocation.decode(data.invocation.Input, a, bytes);
        defer command.deinit();
        try data.invocation.validate(data.invocation.Input, a, command.value);
        if (self.prepared == null or !std.mem.eql(u8, self.image, command.value.image)) {
            var prepared = try runtime.Prepared.init(a, command.value.image);
            errdefer prepared.deinit();
            const image = try a.dupe(u8, command.value.image);
            if (self.prepared) |*previous| previous.deinit();
            a.free(self.image);
            self.image = image;
            self.prepared = prepared;
        }
        var session = switch (command.value.instance) {
            .initial_args => |args| try runtime.Session.start(a, &self.prepared.?, args),
            .state => |state| try runtime.Session.restore(a, &self.prepared.?, state),
        };
        defer session.deinit();
        _ = try runtime.invocation.advance(&session, command.value.control, command.value.quantum);
        var result = try runtime.invocation.finish(a, &session, true);
        defer result.deinit();
        return data.invocation.encodeOwned(data.invocation.Outcome, a, result.record);
    }
};

fn preparedStream(a: std.mem.Allocator, io: std.Io, output: *std.Io.Writer) !void {
    var peer: PreparedPeer = .{ .allocator = a };
    defer peer.deinit();
    var buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().reader(io, &buffer);
    while (true) { // tiger: event-loop
        const length = input.interface.takeInt(u32, .little) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (length > 64 << 20) return error.OversizedTestCommand;
        const command = try a.alloc(u8, length);
        defer a.free(command);
        try input.interface.readSliceAll(command);
        const result = peer.invoke(command) catch |err| {
            const message = @errorName(err);
            try output.writeInt(u32, @intCast(message.len + 1), .little);
            try output.writeByte(1);
            try output.writeAll(message);
            try output.flush();
            continue;
        };
        defer a.free(result);
        try output.writeInt(u32, @intCast(result.len + 1), .little);
        try output.writeByte(0);
        try output.writeAll(result);
        try output.flush();
    }
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
    const kinds: []const examples.Kind = if (recursive) &.{ .even, .odd } else &.{
        .call, .state, .suspended, .double,
    };
    const keys: []const []const u8 = if (recursive) &.{ "even", "odd" } else &.{
        "call", "state", "suspend", "double",
    };
    var instances: [4]data.linker.Instance = undefined;
    var initialized: usize = 0;
    defer for (instances[0..initialized]) |instance| allocator.free(instance.object);
    for (kinds, keys, instances[0..kinds.len]) |kind, key, *instance| {
        instance.* = .{ .key = key, .object = try examples.emit(allocator, kind) };
        initialized += 1;
    }
    const instance_count: usize = if (recursive) 2 else if (doubled) 4 else 3;
    const bindings = if (recursive) blk: {
        break :blk &examples.recursive_bindings;
    } else if (doubled) &examples.double_bindings else &examples.bindings;
    var linked = try data.linker.link(allocator, instances[0..instance_count], bindings, .{
        .instance = if (recursive) "even" else if (doubled) "double" else "suspend",
        .symbol = "main",
    });
    defer linked.deinit();
    const bytes = try allocator.alloc(u8, try data.program_image.encodedLength(linked.program));
    errdefer allocator.free(bytes);
    _ = try linked.encode(allocator, bytes);
    return bytes;
}

fn specializedInvoke(a: std.mem.Allocator, io: std.Io, output: *std.Io.Writer) !void {
    const data = horos.data;
    var buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().reader(io, &buffer);
    const bytes = try input.interface.allocRemaining(a, .unlimited);
    defer a.free(bytes);
    var command = try data.invocation.decode(data.invocation.Input, a, bytes);
    defer command.deinit();
    const guest = try data.program_image.Admitted.decode(a, command.value.image);
    defer guest.deinit();
    const artifact = try runtime.RuntimeCompiler.compile(a, .{
        .guest = guest,
        .horos_package = "qualified-kernel-fixture",
    });
    defer a.free(artifact);
    var selected = try runtime.RuntimeArtifact.init(
        a,
        artifact,
        runtime.RuntimeCapsule.reference(artifact).digest,
    );
    defer selected.deinit();
    try runtime.RuntimeCompiler.validate(a, &selected);
    var prepared = try runtime.Prepared.initWithRuntime(
        a,
        command.value.image,
        &selected,
    );
    defer prepared.deinit();
    var session = switch (command.value.instance) {
        .initial_args => |args| try runtime.Session.start(a, &prepared, args),
        .state => |state| try runtime.Session.restore(a, &prepared, state),
    };
    defer session.deinit();
    _ = try runtime.invocation.advance(&session, command.value.control, command.value.quantum);
    var outcome = try runtime.invocation.finish(a, &session, true);
    defer outcome.deinit();
    const result = try data.invocation.encodeOwned(
        data.invocation.Outcome,
        a,
        outcome.record,
    );
    defer a.free(result);
    try output.writeAll(result);
}

fn writeImage(a: std.mem.Allocator, name: []const u8, output: *std.Io.Writer) !void {
    if (std.mem.eql(u8, name, "components") or
        std.mem.eql(u8, name, "componentsDouble") or
        std.mem.eql(u8, name, "componentsRecursive"))
    {
        const bytes = try linkedImage(a, name);
        defer a.free(bytes);
        try output.writeAll(bytes);
        return;
    }
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    const module = try sourceModule(&builder, name);
    var compiled = if (std.mem.eql(u8, name, "retainedScopeGeneral"))
        (try horos.source.component.compile(
            a,
            module,
            .{ .exports = &.{} },
        )).construction
    else
        try horos.program.compile(a, module);
    defer compiled.deinit();
    if (std.mem.eql(u8, name, "retainedScopeGeneral")) {
        const ir = horos.data.activation;
        const scratch = builder.allocator();
        const handlers = try scratch.dupe(ir.Handler, compiled.program.handlers);
        for (handlers, builder.handlers.items) |*handler, original| {
            const clauses = try scratch.dupe(ir.Clause, handler.clauses);
            for (clauses, original.clauses) |*clause, source_clause| {
                clause.strategy = .general;
                clause.function = source_clause.function;
            }
            handler.clauses = clauses;
        }
        compiled.program.handlers = handlers;
    }
    const bytes = try a.alloc(
        u8,
        try horos.data.program_image.encodedLength(compiled.program),
    );
    defer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    try output.writeAll(bytes);
}

fn sourceModule(builder: *horos.source.Builder, name: []const u8) !horos.source.Module {
    return blk: {
        if (std.mem.eql(u8, name, "largeRequest")) break :blk try largeRequest(builder);
        if (std.mem.eql(u8, name, "retainedScopeGeneral"))
            break :blk try horos.source.examples.retainedScope(builder);
        if (std.mem.eql(
            u8,
            name,
            "install",
        )) break :blk try horos.source.examples.installations(builder, 64);
        if (std.mem.eql(
            u8,
            name,
            "resource",
        )) break :blk try horos.source.examples.resourceScalar(builder);
        if (std.mem.eql(
            u8,
            name,
            "custody",
        )) break :blk try horos.source.examples.custodyOrder(builder, 0);
        inline for (.{
            "retainedScope",
            "branchingTail",
            "branchingTailProtected",
            "deep",
            "recursive",
            "reentrant",
            "generator",
            "shallow",
            "scalarContracts",
        }) |candidate| {
            if (std.mem.eql(
                u8,
                name,
                candidate,
            )) break :blk try @field(horos.source.examples, candidate)(builder);
        }
        return error.InvalidName;
    };
}
