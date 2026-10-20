const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const machines = @import("machine.zig");
const Author = @import("author.zig").Author;
const base = @import("../base/session.zig");
const native = @import("native_baseline");
const a = std.testing.allocator;
const support = @import("test_support.zig");
const Command = union(enum) {
    initialize: []const u8,
    step,
    resume_yield,
    answer: []const u8,
    cancel: data.invocation.Reason,
};

fn prepare() !base.Prepared {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const m = try machines.define(&b);
    const life = try @import("lifecycle.zig").define(&b, m);
    const step = try @import("step.zig").define(&b, m);
    const command = try projection.schema(Command, &b);
    const entry = try b.declare(&.{ m.program, m.state, command }, m.state, &.{}, &.{});
    const hydrated = try b.variable(m.schema);
    const changed = try b.variable(m.schema);
    const stepped = try b.variable(step.result);
    const projected = try e.call(m.project, &.{try b.reference(changed)});
    const Case = std.meta.Elem(@FieldType(@FieldType(source.ast.Term, "match_sum"), "cases"));
    var cases: [5]Case = undefined;
    inline for (@typeInfo(Command).@"union".field_types, 0..) |T, i| {
        const parameter = try b.variable(try projection.schema(T, &b));
        const input = try b.reference(hydrated);
        const argument = try b.reference(parameter);
        var call = switch (i) {
            0 => try e.call(life.initialize, &.{ try e.param(entry, 0), argument }),
            1 => try b.bind(stepped, try e.call(step.active, &.{input}), try b.pure(
                try e.payload(try b.reference(stepped), 0),
            )),
            2 => try e.call(life.resume_yield, &.{input}),
            3 => try e.call(life.respond, &.{ input, argument }),
            4 => try e.call(life.cancel, &.{ input, argument }),
            else => unreachable,
        };
        call = try b.bind(changed, call, projected);
        if (i != 0) call = try b.bind(hydrated, try e.call(m.hydrate, &.{
            try e.param(entry, 0), try e.param(entry, 1),
        }), call);
        cases[i] = .{ .variable = parameter, .body = call };
    }
    try b.define(entry, try b.term(.{ .match_sum = .{
        .value = try e.param(entry, 2),
        .cases = &cases,
    } }));
    return support.prepare(b.module(entry, e.unit));
}

fn compare(
    core: *base.Prepared,
    guest: *native.Session,
    admitted: *const data.program_image.Admitted,
    command: Command,
) !void {
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    const before = try guest.checkpoint(a);
    defer a.free(before);
    var decoded = try data.state_image.decodeGraph(a, before);
    defer decoded.deinit();
    const state = try projection.stateBytes(a, admitted, decoded.state);
    defer a.free(state);
    const control = try projection.encode(Command, a, command);
    defer a.free(control);
    const arguments = try std.mem.concat(a, u8, &.{ program, state, control });
    defer a.free(arguments);
    var portable = try base.Session.start(a, core, arguments, .{});
    defer portable.deinit();
    const result = try portable.run(null);
    try std.testing.expect(result == .completed);
    var actual = try projection.readState(a, admitted, try portable.bytes(&result.completed));
    defer actual.deinit();
    const bytes = try data.state_image.emit(a, actual.state);
    defer a.free(bytes);
    switch (command) {
        .initialize => {},
        .step => try guest.step(),
        .resume_yield => try guest.resumeYield(),
        .cancel => |reason| try guest.cancel(reason),
        .answer => |value| {
            var pending = try guest.pendingRequest(a);
            defer pending.deinit();
            const response = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = pending.request.request_identity,
                .value = value,
            });
            defer a.free(response);
            try guest.answer(response);
        },
    }
    const expected = try guest.checkpoint(a);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

test "authored lifecycle initializes responds resumes and cancels nested cleanup exactly" {
    var core = try prepare();
    defer core.deinit();
    var b = source.Builder.init(a);
    defer b.deinit();
    const image = try support.encode(try source.examples.yieldingCleanup(&b));
    defer a.free(image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    // Before entry, while yielded in cleanup, and while a cleanup request is
    // pending. Two distinct reasons exercise the first-reason-wins rule.
    for (0..3) |cancel_at| {
        var guest = try native.Session.initImage(a, image, &.{0});
        defer guest.deinit();
        try compare(&core, &guest, admitted, .{ .initialize = &.{0} });
        var cancelled = false;
        var done = false;
        for (0..200) |cut| {
            const observed = try guest.observe();
            if (observed == .completed or observed == .failed or observed == .cancelled) {
                done = true;
                break;
            }
            if (!cancelled and ((cancel_at == 0 and
                cut == 0) or (cancel_at == 1 and
                observed == .yielded) or (cancel_at == 2 and observed == .requested)))
            {
                try compare(&core, &guest, admitted, .{ .cancel = .{ .text = "stop λ" } });
                try compare(&core, &guest, admitted, .{ .cancel = .{ .bytes = &.{ 0xff, 0 } } });
                cancelled = true;
                continue;
            }
            const command: Command = if (observed == .yielded)
                .resume_yield
            else if (observed == .requested)
                .{ .answer = &.{} }
            else
                .step;
            compare(&core, &guest, admitted, command) catch |err| {
                std.debug.print("lifecycle cancellation case {d} cut {d} command {s}: {s}\n", .{
                    cancel_at, cut, @tagName(command), @errorName(err),
                });
                return err;
            };
        }
        try std.testing.expect(cancelled and done);
    }
}
