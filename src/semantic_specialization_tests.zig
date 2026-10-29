const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("semantic/projection.zig");
const machines = @import("semantic/machine.zig");
const steps = @import("semantic/step.zig");
const Author = @import("semantic/author.zig").Author;
const base = @import("base/session.zig");
const native = @import("native_baseline");
const service = @import("semantic/service.zig");
const support = @import("semantic/test_support.zig");
const a = std.testing.allocator;

fn prepareCompiled(compiled: *const source.Compiled) !base.Prepared {
    const image = try support.encodeCompiled(compiled);
    defer a.free(image);
    return base.Prepared.init(a, image);
}

fn loopImage() ![]u8 {
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const entry = try b.declare(&.{ e.integer, e.integer }, e.integer, &.{}, &.{});
    const loop = try b.declare(&.{ e.integer, e.integer }, e.integer, &.{}, &.{});
    const count = try e.param(loop, 0);
    const acc = try e.param(loop, 1);
    try b.define(
        loop,
        try e.when(
            try e.binary(.equal, count, e.zero),
            try b.pure(acc),
            try e.call(
                loop,
                &.{
                    try e.binary(.integer_sub, count, e.one),
                    try e.binary(.integer_bit_xor, acc, count),
                },
            ),
        ),
    );
    try b.define(entry, try e.call(loop, &.{ try e.param(entry, 0), try e.param(entry, 1) }));
    return support.encode(b.module(entry, e.unit));
}

fn context(guest: [32]u8) source.specialize.Context {
    const digest = @import("semantic/artifact.zig").digest;
    return .{
        .core = @import("semantic/source_identity.zig").digest(),
        .guest = guest,
        .observation = digest("canonical-pst3-every-guest-transition"),
        .base_profile = digest(@import("base/profile.zig").identity),
        .admission_profile = digest(@import("semantic/artifact.zig").admission_profile),
        .compiler_policy = digest("source-specialization-witness/1"),
    };
}

test "an authored scalar rule change reaches generic and regenerated specialized execution" {
    const image = try @import("semantic/test_support.zig").guestImage();
    defer a.free(image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    var keys: [2][32]u8 = undefined;
    inline for (.{ false, true }) |changed| {
        inline for (.{ false, true }) |staged| {
            var b = source.Builder.init(a);
            defer b.deinit();
            const d = if (staged) try service.defineStaged(&b) else try service.define(&b);
            const m = try machines.define(&b);
            if (changed) try changeAddToXor(&b);
            const module = b.module(d.entry, try b.scalar(void));
            var selected_context = context(admitted.identity());
            var source_hash = std.crypto.hash.sha2.Sha256.init(.{});
            var source_writer: data.wire.Writer = .{ .hasher = &source_hash };
            try data.record.write(source.ast.Module, module, &source_writer);
            selected_context.core = source_hash.finalResult();
            const request: source.specialize.Request = .{
                .function = d.entry,
                .arguments = &.{ .{ .known = .{
                    .schema = m.program,
                    .bytes = program,
                } }, .dynamic },
                .context = selected_context,
                .policy = .{ .work = 8_000_000, .keys_per_function = 128, .depth = 1024 },
            };
            var specialized: ?source.specialize.Output = if (staged)
                try source.specialize.specialize(
                    a,
                    module,
                    request,
                )
            else
                null;
            defer if (specialized) |*output| output.deinit();
            if (specialized) |*output| {
                try source.specialize.validate(a, module, request, output);
                keys[@intFromBool(changed)] = output.key;
            }
            var prepared = try support.prepare(
                if (specialized) |*output| output.module() else module,
            );
            defer prepared.deinit();
            try expectAuthoredScalarResults(&prepared, program, staged, changed);
        }
    }
    try std.testing.expect(!std.mem.eql(u8, &keys[0], &keys[1]));
}

test "specialized scalar sequence retains raw slots without intermediate byte packing" {
    const image = try @import("semantic/test_support.zig").guestImage();
    defer a.free(image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    var packing: [2]usize = @splat(0);
    var base_steps: [2]usize = @splat(0);
    inline for (.{ false, true }, 0..) |staged, index| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const d = if (staged) try service.defineStaged(&b) else try service.define(&b);
        const m = try machines.define(&b);
        const scalar = try @import("semantic/scalar.zig").define(&b);
        var specialized: ?source.specialize.Output = if (staged)
            try source.specialize.specialize(
                a,
                b.module(d.entry, try b.scalar(
                    void,
                )),
                .{
                    .function = d.entry,
                    .arguments = &.{ .{ .known = .{
                        .schema = m.program,
                        .bytes = program,
                    } }, .dynamic },
                    .context = context(admitted.identity()),
                    .policy = .{ .work = 8_000_000, .keys_per_function = 128, .depth = 1024 },
                },
            )
        else
            null;
        defer if (specialized) |*output| output.deinit();
        var compiled = try source.lowerObserved(
            a,
            if (specialized) |*output| output.module() else b.module(d.entry, try b.scalar(void)),
            .{ .recovery = true },
        );
        defer compiled.deinit();
        var prepared = try prepareCompiled(&compiled);
        defer prepared.deinit();
        const encoders = try scalarEncoders(
            &compiled,
            if (specialized) |*output| output else null,
            scalar.encode,
        );
        defer a.free(encoders);
        try expectScalarSequence(
            &prepared,
            image,
            admitted,
            program,
            staged,
            encoders,
            &packing[index],
            &base_steps[index],
        );
    }
    try std.testing.expectEqual(@as(usize, 6), packing[0]);
    try std.testing.expectEqual(@as(usize, 0), packing[1]);
    std.debug.print(
        "scalar sequence: generic/specialized encode calls={d}/{d}, base transitions={d}/{d}\n",
        .{ packing[0], packing[1], base_steps[0], base_steps[1] },
    );
}

test "source command predecessor remains available at every base cut through cloning" {
    var guest_source = source.Builder.init(a);
    defer guest_source.deinit();
    var guest_code = try source.lower(a, try source.examples.cloned(&guest_source));
    defer guest_code.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(guest_code.program));
    defer a.free(image);
    _ = try guest_code.encode(a, image);
    const guest = try data.program_image.Admitted.decode(a, image);
    defer guest.deinit();
    const program = try projection.programBytes(a, guest);
    defer a.free(program);
    for ([_]bool{ false, true }) |staged| try checkClonePredecessor(guest, program, staged);
}

fn checkClonePredecessor(
    guest: *const data.program_image.Admitted,
    program: []const u8,
    staged: bool,
) !void {
    var b = source.Builder.init(a);
    defer b.deinit();
    const d = if (staged) try service.defineStaged(&b) else try service.define(&b);
    const m = try machines.define(&b);
    const module = b.module(d.entry, try b.scalar(void));
    var specialized: ?source.specialize.Output = if (staged)
        try source.specialize.specialize(a, module, .{
            .function = d.entry,
            .arguments = &.{ .{ .known = .{ .schema = m.program, .bytes = program } }, .dynamic },
            .context = context(guest.identity()),
            .policy = .{ .work = 8_000_000, .keys_per_function = 128, .depth = 1024 },
        })
    else
        null;
    defer if (specialized) |*output| output.deinit();
    var compiled = try source.lowerObserved(
        a,
        if (specialized) |*output| output.module() else module,
        .{ .recovery = true },
    );
    defer compiled.deinit();
    var prepared = try prepareCompiled(&compiled);
    defer prepared.deinit();
    const owner = try prepared.acquire();
    defer owner.release();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const anchors = try commandAnchors(
        scratch.allocator(),
        &compiled,
        d,
        &b,
        if (specialized) |*output| output else null,
    );
    const initial = try projection.encode(service.Initial, a, .{ .arguments = &.{} });
    defer a.free(initial);
    const arguments = if (staged) try a.dupe(u8, initial) else try std.mem.concat(a, u8, &.{
        program, initial,
    });
    defer a.free(arguments);
    var session = try base.Session.start(a, &prepared, arguments, .{
        .effects = owner.admitted().program().effects,
    });
    defer session.deinit();
    try checkPredecessorCuts(&session, anchors);
}

fn checkPredecessorCuts(session: *base.Session, anchors: []const std.ArrayList(Anchor)) !void {
    var first = try support.event(session);
    defer first.deinit();
    var control: service.Control = .none;
    var outer_steps: usize = 0;
    var completed = false;
    for (0..400) |_| {
        try support.send(session, .{ .advance = .{ .control = control, .quantum = 1 } });
        try expectCommandAnchors(session, anchors, &outer_steps);
        var cut = try support.event(session);
        defer cut.deinit();
        try std.testing.expect(cut.value == .cut);
        if (cut.value.cut.status == .completed) {
            completed = true;
            break;
        }
        control = if (cut.value.cut.status == .yielded) .resume_yield else .none;
    }
    try std.testing.expect(completed and outer_steps > 1000);
}

test "specialized portable dispatch persists across dynamic service commands" {
    const image = try loopImage();
    defer a.free(image);
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    var b = source.Builder.init(a);
    defer b.deinit();
    const d = try service.defineStaged(&b);
    const m = try machines.define(&b);
    var specialized = try source.specialize.specialize(a, b.module(d.entry, try b.scalar(void)), .{
        .function = d.entry,
        .arguments = &.{ .{ .known = .{ .schema = m.program, .bytes = program } }, .dynamic },
        .context = context(admitted.identity()),
        .policy = .{ .work = 8_000_000, .keys_per_function = 128, .depth = 1024 },
    });
    defer specialized.deinit();
    const step = try steps.define(&b, m);
    var covered: usize = 0;
    for (specialized.functions.items) |f| if (f.before == step.instruction_at and
        f.arguments[2] == .known)
    {
        covered += 1;
    };
    try std.testing.expect(covered >= 3);
    var compiled = try source.lowerObserved(a, specialized.module(), .{ .recovery = true });
    defer compiled.deinit();
    var prepared = try prepareCompiled(&compiled);
    defer prepared.deinit();
    const reifier = try @import("semantic/recovery.zig").define(&b, m);
    var projector = try support.prepare(b.module(reifier, try b.scalar(void)));
    defer projector.deinit();
    try expectDynamicDispatch(
        &prepared,
        &compiled,
        &specialized,
        d.loop,
        &projector,
        admitted,
        image,
    );
}

fn recoverAtBridge(
    session: *base.Session,
    compiled: *const source.Compiled,
    specialized: *const source.specialize.Output,
    loop: data.program.Id,
    projector: *const base.Prepared,
    guest: *const data.program_image.Admitted,
) ![]u8 {
    const pending = (try session.store.get(session.roots.pending.?)).pending;
    const frame = try session.frames.get(pending.continuation.id);
    const reader = try session.frames.slots.reader(frame.view);
    for (specialized.functions.items) |function| {
        if (function.before != loop) continue;

        if (function.arguments[1] == .known) return error.InvalidRecovery;
        const parameter: usize = @intFromBool(function.arguments[0] != .known);
        const variable = specialized.builder.functions.items[
            @intCast(function.after)
        ].parameters[parameter];
        for (compiled.parameters) |binding| {
            if (binding.source_function != function.after or
                binding.variable != variable or binding.function != frame.function) continue;
            const saved = try reader.at(@intCast(binding.slot));
            if (saved.schema != binding.schema) return error.InvalidRecovery;
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            var values: @import("interpreter_v2/values.zig").Values = .{
                .allocator = scratch.allocator(),
                .schemas = session.program.schemas,
                .store = &session.store,
                .aggregate_storage = .structured,
            };
            const fields = try values.split(saved);
            const machine = fields.fields[0];
            const machine_fields = try values.split(machine);
            const actual_program = try values.bytes(&machine_fields.fields[0]);
            const expected_program = try projection.programBytes(a, guest);
            defer a.free(expected_program);
            try std.testing.expectEqualSlices(u8, expected_program, actual_program);
            var reification = try base.Session.start(a, projector, try values.bytes(&machine), .{});
            defer reification.deinit();
            const outcome = try reification.run(null);
            try std.testing.expect(outcome == .completed);
            var reconstructed = try projection.decode(
                data.process_state.State,
                a,
                try reification.bytes(&outcome.completed),
            );
            defer reconstructed.deinit();
            var canonical = try data.state_image.canonicalize(a, reconstructed.value);
            defer canonical.deinit();
            try data.state_admission.validateAdmitted(a, guest, canonical.state);
            return data.state_image.emit(a, canonical.state);
        }
    }
    return error.MissingRecoveryAnchor;
}

test "specialized portable dispatch executes dynamic loops and guest calls at exact cuts" {
    const image = try loopImage();
    defer a.free(image);
    const inputs = [_][2]u64{ .{ 0, 91 }, .{ 1, 91 }, .{ 4, 91 } };
    var bytes: [inputs.len][]const u8 = undefined;
    for (&inputs, &bytes) |*input, *out| out.* = std.mem.asBytes(input);
    try expectSpecializedCuts(image, &bytes, 100);
}

test "specialized portable dispatch retains useful instructions amid multi-shot clone control" {
    var b = source.Builder.init(a);
    defer b.deinit();
    var compiled = try source.lower(a, try source.examples.cloned(&b));
    defer compiled.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    defer a.free(image);
    _ = try compiled.encode(a, image);
    try expectSpecializedCuts(image, &.{&.{}}, 400);
}

fn expectSpecializedCuts(image: []const u8, inputs: []const []const u8, max_cuts: usize) !void {
    const admitted = try data.program_image.Admitted.decode(a, image);
    defer admitted.deinit();
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const machine = try machines.define(&b);
    const step = try steps.define(&b, machine);
    const dispatch = try @import("semantic/staged.zig").define(&b, machine, step);
    const entry = try b.declare(&.{ machine.program, machine.state }, machine.state, &.{}, &.{});
    const hydrated = try b.variable(machine.schema);
    const advanced = try b.variable(step.result);

    const state = try e.replace(
        try b.reference(hydrated),
        @backingInt(machines.Field.program),
        try e.param(entry, 0),
    );
    try b.define(entry, try b.bind(hydrated, try e.call(machine.hydrate, &.{
        try e.param(entry, 0), try e.param(entry, 1),
    }), try b.bind(advanced, try e.call(dispatch, &.{state}), try e.call(machine.project, &.{
        try e.payload(try b.reference(advanced), 0),
    }))));
    const original = b.module(entry, e.unit);
    const request: source.specialize.Request = .{
        .function = entry,
        .arguments = &.{ .{ .known = .{ .schema = machine.program, .bytes = program } }, .dynamic },
        .context = context(admitted.identity()),
        .policy = .{ .work = 8_000_000, .keys_per_function = 128, .depth = 1024 },
    };
    var specialized = try source.specialize.specialize(a, original, request);
    defer specialized.deinit();
    try expectStaticInstructions(&specialized, step.instruction_at);
    var core = try support.prepare(specialized.module());
    defer core.deinit();
    try expectInputCuts(&core, admitted, image, inputs, max_cuts);
}

fn changeAddToXor(b: *source.Builder) !void {
    const scalar = try @import("semantic/scalar.zig").define(b);
    const e = try Author.init(b);
    const original = b.functions.items[@intCast(scalar.binary_raw)].body.?;
    const replacement = try b.pure(try e.variant(scalar.raw_result, 0, try e.binary(
        .integer_bit_xor,
        try e.param(scalar.binary_raw, 2),
        try e.param(scalar.binary_raw, 3),
    )));
    b.functions.items[@intCast(scalar.binary_raw)].body = try e.when(
        try e.binary(.equal, try b.primitive(
            try b.scalar(u32),
            .enum_tag,
            &.{try e.param(scalar.binary_raw, 0)},
            0,
        ), try b.constant(u32, @backingInt(data.program.Opcode.integer_add))),
        replacement,
        original,
    );
}

fn expectAuthoredScalarResults(
    prepared: *const base.Prepared,
    program: []const u8,
    staged: bool,
    changed: bool,
) !void {
    const owner = try prepared.acquire();
    defer owner.release();
    for ([_]u64{ 17, 37, 100 }) |input| {
        const initial = try projection.encode(service.Initial, a, .{
            .arguments = &std.mem.toBytes(input),
        });
        defer a.free(initial);
        const arguments = if (staged) try a.dupe(u8, initial) else try std.mem.concat(a, u8, &.{
            program,
            initial,
        });
        defer a.free(arguments);
        var session = try base.Session.start(a, prepared, arguments, .{
            .effects = owner.admitted().program().effects,
        });
        defer session.deinit();
        var first = try support.event(&session);
        defer first.deinit();
        try std.testing.expect(first.value == .cut);
        try support.send(&session, .{ .advance = .{ .control = .none, .quantum = 100 } });
        var cut = try support.event(&session);
        defer cut.deinit();
        try std.testing.expect(cut.value == .cut and cut.value.cut.status == .completed);
        try support.send(&session, .observe);
        var observed = try support.event(&session);
        defer observed.deinit();
        try std.testing.expect(
            observed.value == .observation and observed.value.observation == .completed,
        );
        const expected = if (changed) input else (input + 7) ^ 7;
        try std.testing.expectEqualSlices(
            u8,
            &std.mem.toBytes(expected),
            observed.value.observation.completed,
        );
        try std.testing.expect(input != (input + 7) ^ 7);
    }
}

fn scalarEncoders(
    compiled: *const source.Compiled,
    specialized: ?*const source.specialize.Output,
    scalar_encode: data.program.Id,
) ![]bool {
    const encoders = try a.alloc(bool, compiled.program.functions.len);
    errdefer a.free(encoders);
    @memset(encoders, false);
    for (compiled.parameters) |binding| {
        var encoder = binding.source_function == scalar_encode;
        if (specialized) |output| for (output.functions.items) |function| {
            if (function.before == scalar_encode and
                function.after == binding.source_function) encoder = true;
        };
        if (encoder) encoders[@intCast(binding.function)] = true;
    }
    try std.testing.expect(std.mem.indexOfScalar(bool, encoders, true) != null);
    return encoders;
}

fn expectScalarSequence(
    prepared: *const base.Prepared,
    image: []const u8,
    admitted: *const data.program_image.Admitted,
    program: []const u8,
    staged: bool,
    encoders: []const bool,
    packing: *usize,
    base_steps: *usize,
) !void {
    const owner = try prepared.acquire();
    defer owner.release();
    for ([_]u64{ 0, 17, std.math.maxInt(u64) - 7 }) |input| {
        const initial = try projection.encode(service.Initial, a, .{
            .arguments = &std.mem.toBytes(input),
        });
        defer a.free(initial);
        const arguments = if (staged) try a.dupe(u8, initial) else try std.mem.concat(a, u8, &.{
            program,
            initial,
        });
        defer a.free(arguments);
        var session = try base.Session.start(a, prepared, arguments, .{
            .effects = owner.admitted().program().effects,
        });
        defer session.deinit();
        var first = try support.event(&session);
        defer first.deinit();
        try support.send(&session, .{ .advance = .{ .control = .none, .quantum = 3 } });

        try measureScalarPacking(&session, encoders, packing, base_steps);
        var cut = try support.event(&session);
        defer cut.deinit();
        try std.testing.expect(cut.value == .cut and cut.value.cut.guest_work == 3);
        const outer = try session.checkpoint(a);
        defer a.free(outer);
        const restored = try base.Session.restore(a, prepared, outer, .{
            .effects = owner.admitted().program().effects,
        });
        session.deinit();
        session = restored;
        try expectScalarCheckpoint(&session, admitted, image, input);
    }
}

fn measureScalarPacking(
    session: *base.Session,
    encoders: []const bool,
    packing: *usize,
    base_steps: *usize,
) !void {
    for (0..8_000_000) |_| {
        if (session.status != .active or session.terminal != null) return;
        const current = session.roots.current.?;
        const control = (try session.store.get(current)).control;
        const frame = try session.frames.get(current.id);
        const function = session.program.blocks[@intCast(control.block)].function;
        if (encoders[@intCast(function)] and
            control.block == session.program.functions[@intCast(function)].entry and
            frame.position == 0)
            packing.* += 1;
        try session.step();
        base_steps.* += 1;
    }
    return error.UnfinishedTest;
}

fn expectScalarCheckpoint(
    session: *base.Session,
    admitted: *const data.program_image.Admitted,
    image: []const u8,
    input: u64,
) !void {
    try support.send(session, .project);
    var projected = try support.event(session);
    defer projected.deinit();
    var canonical = try data.state_image.canonicalize(a, projected.value.projection);
    defer canonical.deinit();
    try data.state_admission.validateAdmitted(a, admitted, canonical.state);
    const actual = try data.state_image.emit(a, canonical.state);
    defer a.free(actual);
    var native_guest = try native.Session.initImage(a, image, &std.mem.toBytes(input));
    defer native_guest.deinit();
    _ = try native_guest.run(3);
    const expected = try native_guest.checkpoint(a);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

const Anchor = struct { slot: data.program.Id, schema: data.program.Id };

fn commandAnchors(
    allocator: std.mem.Allocator,
    compiled: *const source.Compiled,
    d: service.Definition,
    b: *source.Builder,
    specialized: ?*const source.specialize.Output,
) ![]std.ArrayList(Anchor) {
    const anchors = try allocator.alloc(
        std.ArrayList(Anchor),
        compiled.program.functions.len,
    );
    @memset(anchors, .empty);
    for (compiled.parameters) |binding| {
        var wanted = false;
        for ([_][2]data.program.Id{
            .{ d.loop, 1 }, .{ d.dispatch, 1 }, .{ d.publish, 1 }, .{ d.publish, 2 },
        }) |role| {
            if (matchesCommandBinding(b, specialized, binding, role)) wanted = true;
        }
        if (wanted) try anchors[@intCast(binding.function)].append(allocator, .{
            .slot = binding.slot,
            .schema = binding.schema,
        });
    }
    return anchors;
}

fn matchesCommandBinding(
    b: *source.Builder,
    specialized: ?*const source.specialize.Output,
    binding: source.RecoveryBinding,
    role: [2]data.program.Id,
) bool {
    if (specialized) |output| {
        for (output.functions.items) |function| {
            if (function.before != role[0] or function.after != binding.source_function or
                function.arguments[@intCast(role[1])] == .known) continue;
            var parameter: usize = 0;
            for (function.arguments[0..@intCast(role[1])]) |argument| {
                if (argument != .known) parameter += 1;
            }
            return binding.variable == output.builder.functions.items[
                @intCast(function.after)
            ].parameters[parameter];
        }
        return false;
    }
    return binding.source_function == role[0] and
        binding.variable == b.parameter(role[0], @intCast(role[1]));
}

fn expectCommandAnchors(
    session: *base.Session,
    anchors: []const std.ArrayList(Anchor),
    outer_steps: *usize,
) !void {
    for (0..8_000_000) |_| {
        if (session.status != .active or session.terminal != null) return;
        var found = false;
        var frames = session.frames.entries.iterator();
        while (frames.next()) |entry| {
            const frame = entry.value_ptr.*;
            const reader = try session.frames.slots.reader(frame.view);
            for (anchors[@intCast(frame.function)].items) |anchor| {
                const retained = reader.at(@intCast(anchor.slot)) catch |err| switch (err) {
                    error.UninitializedSlot => continue,
                    else => return err,
                };
                if (retained.schema == anchor.schema) found = true;
            }
        }
        if (!found) std.debug.print(
            "missing command anchor after {d} base transitions\n",
            .{outer_steps.*},
        );
        try std.testing.expect(found);
        try session.step();
        outer_steps.* += 1;
    }
    return error.UnfinishedTest;
}

fn expectDynamicDispatch(
    prepared: *const base.Prepared,
    compiled: *const source.Compiled,
    specialized: *const source.specialize.Output,
    loop: data.program.Id,
    projector: *const base.Prepared,
    admitted: *const data.program_image.Admitted,
    image: []const u8,
) !void {
    const owner = try prepared.acquire();
    defer owner.release();
    const initial = try projection.encode(service.Initial, a, .{
        .arguments = &std.mem.toBytes([2]u64{ 4, 91 }),
    });
    defer a.free(initial);
    var session = try base.Session.start(a, prepared, initial, .{
        .effects = owner.admitted().program().effects,
    });
    defer session.deinit();
    var guest = try native.Session.initImage(a, image, &std.mem.toBytes([2]u64{ 4, 91 }));
    defer guest.deinit();
    var first = try support.event(&session);
    defer first.deinit();
    try std.testing.expect(first.value == .cut);
    var finished = false;
    var restored = false;
    for (0..100) |_| {
        try support.send(&session, .{ .advance = .{ .control = .none, .quantum = 3 } });
        if (!restored) {
            try std.testing.expect(try session.run(127) == .progressed);
            const outer = try session.checkpoint(a);
            defer a.free(outer);
            const replacement = try base.Session.restore(a, prepared, outer, .{
                .effects = owner.admitted().program().effects,
            });
            session.deinit();
            session = replacement;
            restored = true;
        }
        var cut = try support.event(&session);
        defer cut.deinit();
        try std.testing.expect(cut.value == .cut);
        const observation = try guest.run(3);
        try expectDispatchRecovery(
            &session,
            compiled,
            specialized,
            loop,
            projector,
            admitted,
            &guest,
        );
        if (observation == .completed) {
            try support.send(&session, .finish);
            try std.testing.expect(try session.run(null) == .completed);
            finished = true;
            break;
        }
        try std.testing.expect(observation == .progressed);
    }
    try std.testing.expect(finished and restored);
}

fn expectDispatchRecovery(
    session: *base.Session,
    compiled: *const source.Compiled,
    specialized: *const source.specialize.Output,
    loop: data.program.Id,
    projector: *const base.Prepared,
    admitted: *const data.program_image.Admitted,
    guest: *native.Session,
) !void {
    const outer_before = try session.checkpoint(a);
    defer a.free(outer_before);
    const recovered = try recoverAtBridge(
        session,
        compiled,
        specialized,
        loop,
        projector,
        admitted,
    );
    defer a.free(recovered);
    const outer_after = try session.checkpoint(a);
    defer a.free(outer_after);
    try std.testing.expectEqualSlices(u8, outer_before, outer_after);
    try support.send(session, .project);
    var projected = try support.event(session);
    defer projected.deinit();
    try std.testing.expect(projected.value == .projection);
    var canonical = try data.state_image.canonicalize(a, projected.value.projection);
    defer canonical.deinit();
    try data.state_admission.validateAdmitted(a, admitted, canonical.state);
    const actual = try data.state_image.emit(a, canonical.state);
    defer a.free(actual);
    const expected = try guest.checkpoint(a);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, actual);
    try std.testing.expectEqualSlices(u8, expected, recovered);
}

fn expectStaticInstructions(
    specialized: *const source.specialize.Output,
    instruction_at: data.program.Id,
) !void {
    var static_instructions: usize = 0;
    for (specialized.functions.items) |f| if (f.before == instruction_at and
        f.arguments[2] == .known)
    {
        static_instructions += 1;
        try std.testing.expect(f.arguments[1] == .known);
        try std.testing.expect(f.arguments[3] == .known);
        try std.testing.expect(f.arguments[4] == .known);
        try std.testing.expect(f.arguments[5] == .known);
        try std.testing.expect(f.arguments[6] == .known);
        try std.testing.expectEqual(
            @as(usize, 1),
            specialized.builder.functions.items[@intCast(f.after)].parameters.len,
        );
    };
    try std.testing.expect(static_instructions >= 3);
}

fn expectInputCuts(
    core: *const base.Prepared,
    admitted: *const data.program_image.Admitted,
    image: []const u8,
    inputs: []const []const u8,
    max_cuts: usize,
) !void {
    for (inputs) |input| {
        var guest = try native.Session.initImage(a, image, input);
        defer guest.deinit();
        var cut: usize = 0;
        while (cut < max_cuts) : (cut += 1) {
            const before = try guest.checkpoint(a);
            defer a.free(before);
            var decoded = try data.state_image.decodeGraph(a, before);
            defer decoded.deinit();
            if (decoded.state.status == .completed) break;
            if (decoded.state.status == .yielded) {
                try guest.resumeYield();
                continue;
            }
            const argument = try projection.stateBytes(a, admitted, decoded.state);
            defer a.free(argument);
            var portable = try base.Session.start(a, core, argument, .{});
            defer portable.deinit();
            const outcome = try portable.run(null);
            try std.testing.expect(outcome == .completed);
            var result = try projection.decode(
                data.process_state.State,
                a,
                try portable.bytes(&outcome.completed),
            );
            defer result.deinit();
            var canonical = try data.state_image.canonicalize(a, result.value);
            defer canonical.deinit();
            try data.state_admission.validateAdmitted(a, admitted, canonical.state);
            const actual = try data.state_image.emit(a, canonical.state);
            defer a.free(actual);
            try guest.step();
            const expected = try guest.checkpoint(a);
            defer a.free(expected);
            try std.testing.expectEqualSlices(u8, expected, actual);
        }
        try std.testing.expect(cut < max_cuts);
    }
}

test "generated source transformer emits reusable checked scalar and layout candidates" {
    const transformation = @import("semantic/transformation.zig");
    var producer_builder = source.Builder.init(a);
    defer producer_builder.deinit();
    var producer = try support.prepare(try transformation.scalar(&producer_builder));
    defer producer.deinit();
    for ([_]u64{ 9, 37 }) |key| {
        var subject_builder = source.Builder.init(a);
        defer subject_builder.deinit();
        const original = try transformationSubject(&subject_builder, key);
        const bytes = try projection.encode(transformation.Input, a, .{ .module = original });
        defer a.free(bytes);
        var proposal_value = try runGenerated(&producer, bytes);
        defer proposal_value.deinit();
        const proposed = proposal_value.value;
        try std.testing.expectEqual(@as(usize, 1), proposed.steps.len);
        try std.testing.expect(proposed.steps[0].rule == .scalar);
        try validateGenerated(original, proposed, &.{});
        try expectRejectedScalar(original, proposed);
        try expectTransformedDynamic(original, proposed.selected, key);
    }
    try expectGeneratedLayout();
}

test "generated transformer reads actual generic semantic source" {
    const compiler = @import("semantic/compiler.zig");
    const transformation = @import("semantic/transformation.zig");
    var definition = try compiler.SourceDefinition.init(a, false, .{});
    defer definition.deinit();
    var builder = source.Builder.init(a);
    defer builder.deinit();
    var producer = try support.prepare(try transformation.scalar(&builder));
    defer producer.deinit();
    const original = definition.module();
    const input = try projection.encode(transformation.Input, a, .{ .module = original });
    defer a.free(input);
    var proposed = try runGenerated(&producer, input);
    defer proposed.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposed.value.steps.len);
    try std.testing.expectError(error.Capacity, validateGeneratedWithBudget(
        original,
        proposed.value,
        &.{},
        1_000_000,
    ));
    const allocated_bytes = try validateGeneratedWithBudget(
        original,
        proposed.value,
        &.{},
        (compiler.ValidationPolicy{}).work,
    );
    std.debug.print("generated source decoding allocated_bytes={d}\n", .{allocated_bytes});
}

fn emittedReferenceModule(b: *source.Builder, failure: bool) !source.Module {
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const effect = try b.effect(.{
        .identity = "source-reference/dispose",
        .payload = unit,
        .result = unit,
        .external = false,
    });
    const resumption = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = unit,
        .answer = unit,
        .handled = &.{effect},
        .mode = .deep,
        .use = .linear,
    } } });
    const dispose = try b.declare(&.{resumption}, unit, &.{}, &.{});
    try b.define(dispose, try b.term(.{ .dispose = try b.reference(b.parameter(dispose, 0)) }));
    const entry = try b.declare(
        if (failure) &.{ word, word } else &.{},
        if (failure) word else unit,
        &.{},
        &.{},
    );
    const value = if (failure) try b.value(.{
        .schema = word,
        .expression = .{ .primitive = .{
            .opcode = .integer_div,
            .operands = &.{
                try b.reference(b.parameter(entry, 0)),
                try b.reference(b.parameter(entry, 1)),
            },
            .failures = &.{
                .{ .kind = .arithmetic_overflow, .value = 0 },
                .{ .kind = .division_by_zero, .value = 0 },
            },
        } },
    }) else try b.primitive(unit, .constant, &.{}, 0);
    try b.define(entry, try b.pure(value));
    return b.module(entry, unit);
}

test "source references include emitted constants and failure literals" {
    const compiler = @import("semantic/compiler.zig");
    const relocation = source.relation.Relocation;
    for ([_]bool{ false, true }) |failure| {
        var builder = source.Builder.init(a);
        defer builder.deinit();
        const module = try emittedReferenceModule(&builder, failure);
        try std.testing.expectEqual(@as(usize, 0), module.constants.len);
        var compiled = try source.lower(a, module);
        defer compiled.deinit();
        try std.testing.expectEqual(@as(usize, 1), compiled.program.constants.len);
        var references = try compiler.sourceReferences(a, module);
        defer references.deinit();
        try std.testing.expectEqualSlices(
            u8,
            &(try compiler.sourceModule(module)).digest,
            &references.value.source,
        );
        const constants = references.value.users[@backingInt(relocation.Kind.constant)];
        try std.testing.expectEqual(@as(usize, 1), constants.len);
        const expected: []const relocation.Reference = &.{
            .{ .kind = .value, .id = module.values.len - 1 },
            .{ .kind = .term, .id = 0 },
        };
        try std.testing.expectEqualDeep(expected, constants[0]);
        const unit_users = references.value.users[@backingInt(relocation.Kind.schema)][0];
        var constant_schema = false;
        for (unit_users) |reference| {
            constant_schema = constant_schema or std.meta.eql(reference, relocation.Reference{
                .kind = .constant,
                .id = 0,
            });
        }
        try std.testing.expect(constant_schema);
    }
}

test "indexed generated layout reuses exact source facts and rejects omitted users" {
    const compiler = @import("semantic/compiler.zig");
    const transformation = @import("semantic/transformation.zig");
    var subject = source.Builder.init(a);
    defer subject.deinit();
    const e = try Author.init(&subject);
    const product = try subject.schema(.{ .product = &.{ e.integer, e.integer } });
    const entry = try subject.declare(&.{e.integer}, e.integer, &.{}, &.{});
    const value = try e.tuple(product, &.{ try e.param(entry, 0), try subject.constant(u64, 37) });
    const left = try subject.variable(e.integer);
    const right = try subject.variable(e.integer);
    const result = try e.binary(.integer_add, try e.field(value, 0), try subject.reference(left));
    try subject.define(entry, try subject.term(.{ .unpack_product = .{
        .value = value,
        .variables = &.{ left, right },
        .body = try subject.pure(result),
    } }));
    const original = subject.module(entry, e.unit);
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const driver = try transformation.indexedLayout(&builder);
    var producer = try support.prepare(builder.module(driver, try builder.scalar(void)));
    defer producer.deinit();
    var references = try compiler.sourceReferences(a, original);
    defer references.deinit();
    try std.testing.expectEqualSlices(
        u8,
        &(try compiler.sourceModule(original)).digest,
        &references.value.source,
    );
    var first = try runIndexedLayout(&producer, original, product, references.value);
    defer first.deinit();
    try validateGenerated(original, first.value, &.{product});
    try expectRepeatedLayoutSites(
        &producer,
        original,
        product,
        value,
        references.value,
        first.value,
    );
    try expectFullScanLayout(original, product, first.value);
    var successor_references = try compiler.sourceReferences(a, first.value.selected);
    defer successor_references.deinit();
    var second = try runIndexedLayout(
        &producer,
        first.value.selected,
        product,
        successor_references.value,
    );
    defer second.deinit();
    try validateGenerated(first.value.selected, second.value, &.{product});
    try std.testing.expect(data.record.equal(source.Module, original, second.value.selected));
    const kind = @backingInt(source.relation.Relocation.Kind.value);
    @constCast(references.value.users[kind])[@intCast(value)] = &.{};
    var omitted = try runIndexedLayout(&producer, original, product, references.value);
    defer omitted.deinit();
    var admitted = try source.lower(a, omitted.value.selected);
    defer admitted.deinit();
    try std.testing.expectError(error.InvalidRelation, validateGenerated(
        original,
        omitted.value,
        &.{product},
    ));
}

fn expectRepeatedLayoutSites(
    producer: *const base.Prepared,
    module: source.Module,
    schema: u64,
    value: u64,
    references: @import("semantic/compiler.zig").SourceReferences,
    expected: @import("semantic/compiler.zig").RecordProposal,
) !void {
    const compiler = @import("semantic/compiler.zig");
    const relocation = source.relation.Relocation;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    const repeated = try source.own(compiler.SourceReferences, storage, references);
    const users = repeated.users[@backingInt(relocation.Kind.value)][@intCast(value)];
    var value_user = false;
    var term_user = false;
    for (users) |user| {
        value_user = value_user or user.kind == .value;
        term_user = term_user or user.kind == .term;
    }
    try std.testing.expect(value_user and term_user);
    inline for (.{
        .{ relocation.Kind.schema, schema },
        .{ relocation.Kind.value, value },
    }) |row| {
        const table = @constCast(repeated.users[@backingInt(row[0])]);
        const index: usize = @intCast(row[1]);
        const duplicated = try std.mem.concat(storage, relocation.Reference, &.{
            table[index], table[index],
        });
        std.mem.reverse(relocation.Reference, duplicated);
        table[index] = duplicated;
    }
    var actual = try runIndexedLayout(producer, module, schema, repeated);
    defer actual.deinit();
    try std.testing.expect(data.record.equal(compiler.RecordProposal, expected, actual.value));
}

fn expectFullScanLayout(
    module: source.Module,
    schema: u64,
    expected: @import("semantic/compiler.zig").RecordProposal,
) !void {
    const compiler = @import("semantic/compiler.zig");
    const transformation = @import("semantic/transformation.zig");
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const entry = try transformation.layout(&builder);
    var producer = try support.prepare(builder.module(entry, try builder.scalar(void)));
    defer producer.deinit();
    const input = try projection.encode(transformation.LayoutInput, a, .{
        .module = module,
        .layout = .{ .schema = schema, .coordinates = &.{ 1, 0 } },
    });
    defer a.free(input);
    var actual = try runGenerated(&producer, input);
    defer actual.deinit();
    try std.testing.expect(data.record.equal(compiler.RecordProposal, expected, actual.value));
}

fn runIndexedLayout(
    producer: *const base.Prepared,
    module: source.Module,
    schema: u64,
    references: @import("semantic/compiler.zig").SourceReferences,
) !projection.Owned(@import("semantic/compiler.zig").RecordProposal) {
    const transformation = @import("semantic/transformation.zig");
    const input = try projection.encode(transformation.IndexedLayoutInput, a, .{
        .module = module,
        .layout = .{ .schema = schema, .coordinates = &.{ 1, 0 } },
        .references = references,
    });
    defer a.free(input);
    return runGenerated(producer, input);
}

fn transformationSubject(b: *source.Builder, key: u64) !source.Module {
    const e = try Author.init(b);
    const entry = try b.declare(&.{e.integer}, e.integer, &.{}, &.{});
    const input = try e.param(entry, 0);
    const redundant = try e.binary(.integer_bit_or, input, input);
    try b.define(entry, try b.pure(try e.binary(
        .integer_bit_xor,
        redundant,
        try b.constant(u64, key),
    )));
    return b.module(entry, e.unit);
}

fn runGenerated(
    producer: *const base.Prepared,
    input: []const u8,
) !projection.Owned(@import("semantic/compiler.zig").RecordProposal) {
    var work = try base.Session.start(a, producer, input, .{});
    defer work.deinit();
    const outcome = try work.run(null);
    try std.testing.expect(outcome == .completed);
    const bytes = try work.bytes(&outcome.completed);
    std.debug.print("generated transform input/output bytes={d}/{d}, base transitions={d}\n", .{
        input.len, bytes.len, work.transitions,
    });
    return projection.decode(@import("semantic/compiler.zig").RecordProposal, a, bytes);
}

test "generated consumer composition inspects dynamic sites and emits checked inline steps" {
    const transformation = @import("semantic/transformation.zig");
    var builder = source.Builder.init(a);
    defer builder.deinit();
    var producer = try support.prepare(try transformation.consumer(&builder));
    defer producer.deinit();
    var subject = source.Builder.init(a);
    defer subject.deinit();
    const module = try source.examples.consumerComposition(&subject);
    var count: usize = 0;
    for (module.functions, 0..) |function, id| {
        const body = function.body orelse continue;
        if (module.terms[@intCast(body)] != .bind) continue;
        const site: source.consumer.Site = .{ .function = id, .binding = body };
        var inspected = try source.consumer.inspect(a, module, site, .{});
        defer inspected.deinit();
        if (inspected.outcome != .boundary) continue;
        const input = try projection.encode(transformation.ConsumerInput, a, .{
            .module = module,
            .site = site,
        });
        defer a.free(input);
        var generated = try runGenerated(&producer, input);
        defer generated.deinit();
        try validateGenerated(module, generated.value, &.{});
        var expected = try source.consumer.compose(a, module, site, .{});
        defer expected.deinit();
        try std.testing.expect(data.record.equal(
            source.Module,
            expected.module,
            generated.value.selected,
        ));
        try std.testing.expectEqual(@as(usize, 2), generated.value.steps.len);
        for (generated.value.steps) |step| try std.testing.expect(step.rule == .inline_call);
        try expectConsumerDynamic(module, generated.value.selected, count == 0);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try expectSharedConsumerCall(&producer);
    try expectConsumerTermBodies(&producer);
}

const ConsumerBody = enum { value, bind, conditional, call, fail, yield_then, match_sum, unpack };
const ConsumerArgument = enum { parameter, computed, fault, duplicate, indirect };
const ConsumerCase = struct {
    body: ConsumerBody,
    consumer: bool = false,
    argument: ConsumerArgument = .parameter,
};

fn expectConsumerTermBodies(producer: *const base.Prepared) !void {
    for (std.enums.values(ConsumerBody)) |body| {
        for ([_]bool{ false, true }) |consumer| try expectConsumerCase(producer, .{
            .body = body,
            .consumer = consumer,
        });
    }
    for ([_]ConsumerArgument{ .computed, .fault, .duplicate, .indirect }) |argument|
        try expectConsumerCase(producer, .{ .body = .value, .argument = argument });
}

fn consumerCaseInput(b: *source.Builder, case: ConsumerCase) !source.Module {
    const e = try Author.init(b);
    const producer = try b.declare(&.{ e.integer, e.integer }, e.integer, &.{}, &.{});
    const consumer = try b.declare(&.{ e.integer, e.integer }, e.integer, &.{}, &.{});
    const entry = try b.declare(&.{e.integer}, e.integer, &.{}, &.{});
    try b.define(producer, try consumerCaseBody(
        e,
        producer,
        if (case.consumer) .value else case.body,
    ));
    try b.define(consumer, try consumerCaseBody(
        e,
        consumer,
        if (case.consumer) case.body else .value,
    ));
    const argument = try e.param(entry, 0);
    const variable = try b.variable(e.integer);
    const result = try b.reference(variable);
    const extra = switch (case.argument) {
        .parameter => argument,
        .computed => try e.binary(.integer_bit_xor, argument, e.one),
        .fault => try e.binary(.integer_div, argument, e.zero),
        .duplicate => result,
        .indirect => try e.binary(.integer_bit_xor, result, result),
    };
    var calls: [2]u64 = undefined;
    for (0..2) |index| {
        const position = if (case.consumer) 1 - index else index;
        calls[position] = if (position == 0)
            try e.call(producer, &.{ argument, argument })
        else
            try e.call(consumer, &.{ result, extra });
    }
    try b.define(entry, try b.bind(variable, calls[0], calls[1]));
    return b.module(entry, e.unit);
}

fn consumerCaseBody(e: Author, function: u64, body: ConsumerBody) !u64 {
    const input = try e.param(function, 0);
    const returned = try e.b.pure(input);
    return switch (body) {
        .value => returned,
        .fail => e.fail(),
        .yield_then => e.b.term(.{ .yield_then = returned }),
        .conditional => e.when(
            try e.binary(.less, input, e.one),
            returned,
            try e.b.pure(try e.binary(.integer_bit_xor, input, e.one)),
        ),
        .call => e.when(
            try e.binary(.equal, input, e.zero),
            returned,
            try e.call(function, &.{ e.zero, try e.param(function, 1) }),
        ),
        .bind => blk: {
            const variable = e.b.parameter(function, 0);
            const flipped = try e.b.pure(try e.binary(.integer_bit_xor, input, e.one));
            break :blk e.b.bind(variable, flipped, try e.b.bind(variable, flipped, returned));
        },
        .match_sum, .unpack => consumerCaseDestructure(e, input, body),
    };
}

fn consumerCaseDestructure(e: Author, input: u64, body: ConsumerBody) !u64 {
    const first = try e.b.variable(e.integer);
    const second = try e.b.variable(e.integer);
    const fields: []const u64 = &.{ e.integer, e.integer };
    if (body == .match_sum) {
        const sum = try e.b.schema(.{ .sum = fields });
        return e.b.term(.{ .match_sum = .{
            .value = try e.variant(sum, 1, input),
            .cases = &.{
                .{ .variable = first, .body = try e.b.pure(try e.b.reference(first)) },
                .{ .variable = second, .body = try e.b.pure(try e.b.reference(second)) },
            },
        } });
    }
    const product = try e.b.schema(.{ .product = fields });
    return e.b.term(.{ .unpack_product = .{
        .value = try e.tuple(product, &.{ try e.binary(.integer_bit_xor, input, e.one), input }),
        .variables = &.{ first, second },
        .body = try e.b.pure(try e.b.reference(second)),
    } });
}

fn expectConsumerCase(producer: *const base.Prepared, case: ConsumerCase) !void {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try consumerCaseInput(&b, case);
    const site: source.consumer.Site = .{
        .function = module.entry,
        .binding = module.functions[@intCast(module.entry)].body.?,
    };
    var inspected = try source.consumer.inspect(a, module, site, .{});
    defer inspected.deinit();
    const blocked = case.argument == .duplicate or case.argument == .indirect;
    if (blocked) {
        try std.testing.expect(inspected.outcome == .blocked);
        try std.testing.expectEqual(
            if (case.argument == .duplicate)
                @as(std.meta.Tag(source.consumer.Blocker), .multiple_consumer_arguments)
            else
                .indirect_consumer_argument,
            std.meta.activeTag(inspected.outcome.blocked),
        );
    } else {
        try std.testing.expect(inspected.outcome == .boundary);
        try std.testing.expect(inspected.outcome.boundary.blocker == null);
    }
    const input = try projection.encode(@import("semantic/transformation.zig").ConsumerInput, a, .{
        .module = module,
        .site = site,
    });
    defer a.free(input);
    var generated = try runGenerated(producer, input);
    defer generated.deinit();
    try validateGenerated(module, generated.value, &.{});
    if (!blocked) {
        var expected = try source.consumer.compose(a, module, site, .{});
        defer expected.deinit();
        try std.testing.expectEqual(expected.steps.len, generated.value.steps.len);
        for (expected.steps, generated.value.steps) |left, right| {
            try std.testing.expectEqual(left.rule.inline_call, right.rule.inline_call);
            try std.testing.expect(data.record.equal(
                source.Module,
                left.successor,
                right.successor,
            ));
        }
        try std.testing.expect(data.record.equal(
            source.Module,
            expected.module,
            generated.value.selected,
        ));
    }
    for ([_]source.Module{ module, generated.value.selected }) |selected|
        try expectConsumerCaseExecution(selected, case);
}

fn expectConsumerCaseExecution(module: source.Module, case: ConsumerCase) !void {
    var prepared = try support.prepare(module);
    defer prepared.deinit();
    for ([_]u64{ 0, 7 }) |value| {
        var input: [8]u8 = undefined;
        std.mem.writeInt(u64, &input, value, .little);
        var session = try base.Session.start(a, &prepared, &input, .{});
        defer session.deinit();
        var outcome = try session.run(null);
        if (case.body == .yield_then) {
            try std.testing.expect(outcome == .yielded);
            try session.resumeYield();
            outcome = try session.run(null);
        }
        if (case.body == .fail or case.argument == .fault) {
            try std.testing.expect(outcome == .failed);
            try std.testing.expectEqual(@as(usize, 0), (try session.bytes(&outcome.failed)).len);
        } else {
            try std.testing.expect(outcome == .completed);
            const expected = switch (case.body) {
                .call => 0,
                .conditional => if (value < 1) value else value ^ 1,
                else => value,
            };
            const result = try session.bytes(&outcome.completed);
            try std.testing.expectEqual(expected, std.mem.readInt(u64, result[0..8], .little));
        }
    }
}

fn expectSharedConsumerCall(producer: *const base.Prepared) !void {
    const transformation = @import("semantic/transformation.zig");
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const e = try Author.init(&builder);
    const increment = try builder.declare(&.{e.integer}, e.integer, &.{}, &.{});
    try builder.define(increment, try builder.pure(try e.binary(
        .integer_add,
        try e.param(increment, 0),
        e.one,
    )));
    const entry = try builder.declare(&.{e.integer}, e.integer, &.{}, &.{});
    const call = try e.call(increment, &.{try e.param(entry, 0)});
    const binding = try builder.bind(builder.parameter(entry, 0), call, call);
    try builder.define(entry, binding);
    const module = builder.module(entry, e.unit);
    var original = try support.prepare(module);
    defer original.deinit();
    const input = try projection.encode(transformation.ConsumerInput, a, .{
        .module = module,
        .site = .{ .function = entry, .binding = binding },
    });
    defer a.free(input);
    var generated = try runGenerated(producer, input);
    defer generated.deinit();
    try std.testing.expectEqual(@as(usize, 1), generated.value.steps.len);
    try std.testing.expect(generated.value.steps[0].rule == .inline_call);
    try std.testing.expectEqual(call, generated.value.steps[0].rule.inline_call);
    try validateGenerated(module, generated.value, &.{});
    var selected = try support.prepare(generated.value.selected);
    defer selected.deinit();
    for ([_]u64{ 0, 17, 99 }) |value| {
        var arguments: [8]u8 = undefined;
        std.mem.writeInt(u64, &arguments, value, .little);
        for ([_]*const base.Prepared{ &original, &selected }) |program| {
            var session = try base.Session.start(a, program, &arguments, .{});
            defer session.deinit();
            const outcome = try session.run(null);
            try std.testing.expect(outcome == .completed);
            const result = try session.bytes(&outcome.completed);
            try std.testing.expectEqual(value + 2, std.mem.readInt(u64, result[0..8], .little));
        }
    }
}

fn expectConsumerDynamic(original: source.Module, selected: source.Module, first_site: bool) !void {
    try reportConsumerSemanticBaseline(original, selected);
    var before = try support.prepare(original);
    defer before.deinit();
    var after = try support.prepare(selected);
    defer after.deinit();
    for ([_][3]u64{ .{ 7, 3, 4 }, .{ 17, 9, 24 }, .{ 0, 0, 0 } }) |values| {
        for ([_]bool{ false, true }) |first| {
            var input: [25]u8 = undefined;
            for (values, 0..) |value, index|
                std.mem.writeInt(u64, input[index * 8 ..][0..8], value, .little);
            input[24] = @intFromBool(first);
            var prior = try base.Session.start(a, &before, &input, .{});
            defer prior.deinit();
            var successor = try base.Session.start(a, &after, &input, .{});
            defer successor.deinit();
            const functions = try a.alloc(
                u64,
                @max(prior.program.functions.len, successor.program.functions.len),
            );
            defer a.free(functions);
            for (functions, 0..) |*id, index| id.* = index;
            var prior_entries: u64 = 0;
            var successor_entries: u64 = 0;
            prior.entry_counter = .{ .functions = functions, .count = &prior_entries };
            successor.entry_counter = .{ .functions = functions, .count = &successor_entries };
            const left = try prior.run(null);
            const right = try successor.run(null);
            try std.testing.expect(left == .completed and right == .completed);
            const wanted = if (first)
                (values[0] & values[1]) < values[2]
            else
                (values[0] ^ values[1]) == values[2];
            const expected = [_]u8{@intFromBool(wanted)};
            try std.testing.expectEqualSlices(u8, &expected, try prior.bytes(&left.completed));
            try std.testing.expectEqualSlices(u8, &expected, try successor.bytes(&right.completed));
            if (first == first_site) {
                try std.testing.expect(successor_entries < prior_entries);
            } else try std.testing.expectEqual(prior_entries, successor_entries);
            std.debug.print("consumer calls={d}/{d} base transitions={d}/{d}\n", .{
                prior_entries, successor_entries, prior.transitions, successor.transitions,
            });
        }
    }
}

fn reportConsumerSemanticBaseline(original: source.Module, selected: source.Module) !void {
    var before = try source.lowerObserved(a, original, .{ .contract = .semantic });
    defer before.deinit();
    var after = try source.lowerObserved(a, selected, .{ .contract = .semantic });
    defer after.deinit();
    var counts: [2]usize = .{ 0, 0 };
    for ([_]data.activation.Program{ before.program, after.program }, &counts) |program, *count|
        for (program.blocks) |block| {
            if (block.terminator == .call) count.* += 1;
        };
    std.debug.print("existing semantic optimizer call records={d}/{d}\n", .{
        counts[0], counts[1],
    });
}

fn validateGenerated(
    original: source.Module,
    proposed: @import("semantic/compiler.zig").RecordProposal,
    private_schemas: []const u64,
) !void {
    _ = try validateGeneratedWithBudget(
        original,
        proposed,
        private_schemas,
        (@import("semantic/compiler.zig").ValidationPolicy{}).work,
    );
}

fn validateGeneratedWithBudget(
    original: source.Module,
    proposed: @import("semantic/compiler.zig").RecordProposal,
    private_schemas: []const u64,
    allocation_bytes_max: usize,
) !usize {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    const evidence = try storage.alloc(source.relation.Step, proposed.steps.len);
    var remaining = allocation_bytes_max;
    for (proposed.steps, evidence) |record, *step|
        step.* = try source.relation.decodeRecordStep(storage, record, &remaining);
    try source.relation.validate(a, original, proposed.selected, evidence, .{
        .private_schemas = private_schemas,
        .work = 64_000_000,
    });
    return allocation_bytes_max - remaining;
}

fn expectTransformedDynamic(original: source.Module, selected: source.Module, key: u64) !void {
    var before = try support.prepare(original);
    defer before.deinit();
    var after = try support.prepare(selected);
    defer after.deinit();
    for ([_]u64{ 0, 17, std.math.maxInt(u64) }) |value| {
        var arguments: [8]u8 = undefined;
        std.mem.writeInt(u64, &arguments, value, .little);
        var prior = try base.Session.start(a, &before, &arguments, .{});
        defer prior.deinit();
        var successor = try base.Session.start(a, &after, &arguments, .{});
        defer successor.deinit();
        const prior_result = try prior.run(null);
        const next_result = try successor.run(null);
        try std.testing.expect(prior_result == .completed and next_result == .completed);
        const expected_bytes = try prior.bytes(&prior_result.completed);
        const actual_bytes = try successor.bytes(&next_result.completed);
        try std.testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
        try std.testing.expectEqual(value ^ key, std.mem.readInt(u64, actual_bytes[0..8], .little));
        try std.testing.expect(successor.transitions < prior.transitions);
    }
}

fn expectGeneratedLayout() !void {
    const transformation = @import("semantic/transformation.zig");
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const product = try b.schema(.{ .product = &.{ e.integer, e.boolean } });
    const entry = try b.declare(&.{ e.integer, e.boolean }, e.integer, &.{}, &.{});
    const value = try e.tuple(product, &.{ try e.param(entry, 0), try e.param(entry, 1) });
    try b.define(entry, try b.pure(try e.field(value, 0)));
    const original = b.module(entry, e.unit);
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const driver = try transformation.layout(&builder);
    var producer = try support.prepare(builder.module(driver, try builder.scalar(void)));
    defer producer.deinit();
    const input = try projection.encode(transformation.LayoutInput, a, .{
        .module = original,
        .layout = .{ .schema = product, .coordinates = &.{ 1, 0 } },
    });
    defer a.free(input);
    var proposed = try runGenerated(&producer, input);
    defer proposed.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposed.value.steps.len);
    try validateGenerated(original, proposed.value, &.{product});
    const selected_fields = proposed.value.selected.schemas[@intCast(product)].product;
    try std.testing.expectEqualSlices(u64, &.{ e.boolean, e.integer }, selected_fields);
}

fn expectRejectedScalar(
    original: source.Module,
    proposed: @import("semantic/compiler.zig").RecordProposal,
) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    const mutant = try source.own(source.Module, storage, proposed.selected);
    const scalar_rule = proposed.steps[0].rule.scalar;
    const target = &@constCast(mutant.values)[@intCast(scalar_rule.value)];
    for (original.values) |value| {
        if (value.schema != target.schema or value.expression != .literal) continue;
        target.* = value;
        break;
    }
    var compiled = try source.lower(a, mutant);
    defer compiled.deinit();
    const evidence = [_]source.relation.Step{.{
        .successor = mutant,
        .rule = .{ .scalar = scalar_rule },
    }};
    try std.testing.expectError(
        error.InvalidRelation,
        source.relation.validate(a, original, mutant, &evidence, .{}),
    );
}
