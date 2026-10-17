const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("semantic/projection.zig");
const machines = @import("semantic/machine.zig");
const steps = @import("semantic/step.zig");
const Author = @import("semantic/author.zig").Author;
const base = @import("base/session.zig");
const native = @import("../test/oracle/stable_session.zig");
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
    try b.define(loop, try e.when(try e.binary(.equal, count, e.zero), try b.pure(acc), try e.call(loop, &.{ try e.binary(.integer_sub, count, e.one), try e.binary(.integer_bit_xor, acc, count) })));
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
            if (changed) {
                // Change the actual authored guest rule, before lowering or
                // specialization. This test-only interpretation makes guest add
                // compute xor; every other scalar rule keeps its original body.
                // Neither the guest image nor native base operations change.
                const scalar = try @import("semantic/scalar.zig").define(&b);
                const e = try Author.init(&b);
                const original = b.functions.items[@intCast(scalar.binary_raw)].body.?;
                const replacement = try b.pure(try e.variant(scalar.raw_result, 0, try e.binary(.integer_bit_xor, try e.param(scalar.binary_raw, 2), try e.param(scalar.binary_raw, 3))));
                b.functions.items[@intCast(scalar.binary_raw)].body = try e.when(
                    try e.binary(.equal, try b.primitive(try b.scalar(u32), .enum_tag, &.{try e.param(scalar.binary_raw, 0)}, 0), try b.constant(u32, @backingInt(data.program.Opcode.integer_add))),
                    replacement,
                    original,
                );
            }
            const module = b.module(d.entry, try b.scalar(void));
            var selected_context = context(admitted.identity());
            var source_hash = std.crypto.hash.sha2.Sha256.init(.{});
            var source_writer: data.wire.Writer = .{ .hasher = &source_hash };
            try data.record.write(source.ast.Module, module, &source_writer);
            selected_context.core = source_hash.finalResult();
            const request: source.specialize.Request = .{
                .function = d.entry,
                .arguments = &.{ .{ .known = .{ .schema = m.program, .bytes = program } }, .dynamic },
                .context = selected_context,
                .policy = .{ .work = 8_000_000, .keys_per_function = 128, .depth = 1024 },
            };
            var specialized: ?source.specialize.Output = if (staged) try source.specialize.specialize(a, module, request) else null;
            defer if (specialized) |*output| output.deinit();
            if (specialized) |*output| {
                try source.specialize.validate(a, module, request, output);
                keys[@intFromBool(changed)] = output.key;
            }
            var prepared = try support.prepare(if (specialized) |*output| output.module() else module);
            defer prepared.deinit();
            const owner = try prepared.acquire();
            defer owner.release();
            for ([_]u64{ 17, 37, 100 }) |input| {
                const initial = try projection.encode(service.Initial, a, .{ .arguments = &std.mem.toBytes(input) });
                defer a.free(initial);
                const arguments = if (staged) try a.dupe(u8, initial) else try std.mem.concat(a, u8, &.{ program, initial });
                defer a.free(arguments);
                var session = try base.Session.start(a, &prepared, arguments, .{ .effects = owner.admitted().program().effects });
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
                try std.testing.expect(observed.value == .observation and observed.value.observation == .completed);
                const expected = if (changed) input else (input + 7) ^ 7;
                try std.testing.expectEqualSlices(u8, &std.mem.toBytes(expected), observed.value.observation.completed);
                try std.testing.expect(input != (input + 7) ^ 7);
            }
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
        var specialized: ?source.specialize.Output = if (staged) try source.specialize.specialize(a, b.module(d.entry, try b.scalar(void)), .{
            .function = d.entry,
            .arguments = &.{ .{ .known = .{ .schema = m.program, .bytes = program } }, .dynamic },
            .context = context(admitted.identity()),
            .policy = .{ .work = 8_000_000, .keys_per_function = 128, .depth = 1024 },
        }) else null;
        defer if (specialized) |*output| output.deinit();
        var compiled = try source.lowerObserved(a, if (specialized) |*output| output.module() else b.module(d.entry, try b.scalar(void)), .{ .recovery = true });
        defer compiled.deinit();
        var prepared = try prepareCompiled(&compiled);
        defer prepared.deinit();
        const owner = try prepared.acquire();
        defer owner.release();
        const encoders = try a.alloc(bool, compiled.program.functions.len);
        defer a.free(encoders);
        @memset(encoders, false);
        for (compiled.parameters) |binding| {
            var encoder = binding.source_function == scalar.encode;
            if (specialized) |*output| for (output.functions.items) |function| {
                if (function.before == scalar.encode and function.after == binding.source_function) encoder = true;
            };
            if (encoder) encoders[@intCast(binding.function)] = true;
        }
        try std.testing.expect(std.mem.indexOfScalar(bool, encoders, true) != null);
        for ([_]u64{ 0, 17, std.math.maxInt(u64) - 7 }) |input| {
            const initial = try projection.encode(service.Initial, a, .{ .arguments = &std.mem.toBytes(input) });
            defer a.free(initial);
            const arguments = if (staged) try a.dupe(u8, initial) else try std.mem.concat(a, u8, &.{ program, initial });
            defer a.free(arguments);
            var session = try base.Session.start(a, &prepared, arguments, .{ .effects = owner.admitted().program().effects });
            defer session.deinit();
            var first = try support.event(&session);
            defer first.deinit();
            try support.send(&session, .{ .advance = .{ .control = .none, .quantum = 3 } });
            // This interval covers constant -> add -> xor with a live scalar
            // dependency. Projection is deliberately outside the measurement.
            while (session.status == .active and session.terminal == null) {
                const current = session.roots.current.?;
                const control = (try session.store.get(current)).control;
                const frame = try session.frames.get(current.id);
                const function = session.program.blocks[@intCast(control.block)].function;
                if (encoders[@intCast(function)] and control.block == session.program.functions[@intCast(function)].entry and frame.position == 0)
                    packing[index] += 1;
                try session.step();
                base_steps[index] += 1;
            }
            var cut = try support.event(&session);
            defer cut.deinit();
            try std.testing.expect(cut.value == .cut and cut.value.cut.guest_work == 3);
            const outer = try session.checkpoint(a);
            defer a.free(outer);
            const restored = try base.Session.restore(a, &prepared, outer, .{ .effects = owner.admitted().program().effects });
            session.deinit();
            session = restored;
            try support.send(&session, .project);
            var projected = try support.event(&session);
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
    }
    try std.testing.expectEqual(@as(usize, 6), packing[0]);
    try std.testing.expectEqual(@as(usize, 0), packing[1]);
    std.debug.print("scalar sequence: generic/specialized encode calls={d}/{d}, base transitions={d}/{d}\n", .{ packing[0], packing[1], base_steps[0], base_steps[1] });
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
    var b = source.Builder.init(a);
    defer b.deinit();
    const d = try service.define(&b);
    var compiled = try source.lowerObserved(a, b.module(d.entry, try b.scalar(void)), .{ .recovery = true });
    defer compiled.deinit();
    var prepared = try prepareCompiled(&compiled);
    defer prepared.deinit();
    const owner = try prepared.acquire();
    defer owner.release();
    const Anchor = struct { slot: data.program.Id, schema: data.program.Id };
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const anchors = try scratch.allocator().alloc(std.ArrayList(Anchor), compiled.program.functions.len);
    @memset(anchors, .empty);
    for (compiled.parameters) |binding| {
        const wanted = ((binding.source_function == d.loop or binding.source_function == d.dispatch) and binding.variable == b.parameter(binding.source_function, 1)) or
            (binding.source_function == d.receive and (binding.variable == b.parameter(d.receive, 1) or binding.variable == b.parameter(d.receive, 2))) or
            (binding.source_function == d.publish and (binding.variable == b.parameter(d.publish, 1) or binding.variable == b.parameter(d.publish, 2)));
        if (wanted) try anchors[@intCast(binding.function)].append(scratch.allocator(), .{ .slot = binding.slot, .schema = binding.schema });
    }
    const initial = try projection.encode(service.Initial, a, .{ .arguments = &.{} });
    defer a.free(initial);
    const arguments = try std.mem.concat(a, u8, &.{ program, initial });
    defer a.free(arguments);
    var session = try base.Session.start(a, &prepared, arguments, .{ .effects = owner.admitted().program().effects });
    defer session.deinit();
    var first = try support.event(&session);
    defer first.deinit();
    var control: service.Control = .none;
    var outer_steps: usize = 0;
    var completed = false;
    for (0..400) |_| {
        try support.send(&session, .{ .advance = .{ .control = control, .quantum = 1 } });
        while (session.status == .active and session.terminal == null) {
            var found = false;
            var frames = session.frames.entries.iterator();
            while (frames.next()) |entry| {
                const frame = entry.value_ptr.*;
                const reader = try session.frames.slots.reader(frame.view);
                for (anchors[@intCast(frame.function)].items) |anchor| {
                    const retained = reader.at(@intCast(anchor.slot)) catch continue;
                    if (retained.schema == anchor.schema) found = true;
                }
            }
            if (!found) std.debug.print("missing command anchor after {d} base transitions\n", .{outer_steps});
            try std.testing.expect(found);
            try session.step();
            outer_steps += 1;
        }
        var cut = try support.event(&session);
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
    for (specialized.functions.items) |f| if (f.before == step.instruction_at and f.arguments[2] == .known) {
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
    const owner = try prepared.acquire();
    defer owner.release();
    const initial = try projection.encode(service.Initial, a, .{ .arguments = &std.mem.toBytes([2]u64{ 4, 91 }) });
    defer a.free(initial);
    var session = try base.Session.start(a, &prepared, initial, .{ .effects = owner.admitted().program().effects });
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
            const replacement = try base.Session.restore(a, &prepared, outer, .{ .effects = owner.admitted().program().effects });
            session.deinit();
            session = replacement;
            restored = true;
        }
        var cut = try support.event(&session);
        defer cut.deinit();
        try std.testing.expect(cut.value == .cut);
        const observation = try guest.run(3);
        const outer_before = try session.checkpoint(a);
        defer a.free(outer_before);
        const recovered = try recoverAtBridge(&session, &compiled, &specialized, d.loop, &projector, admitted);
        defer a.free(recovered);
        const outer_after = try session.checkpoint(a);
        defer a.free(outer_after);
        try std.testing.expectEqualSlices(u8, outer_before, outer_after);
        try support.send(&session, .project);
        var projected = try support.event(&session);
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

fn recoverAtBridge(session: *base.Session, compiled: *const source.Compiled, specialized: *const source.specialize.Output, loop: data.program.Id, projector: *const base.Prepared, guest: *const data.program_image.Admitted) ![]u8 {
    const pending = (try session.store.get(session.roots.pending.?)).pending;
    const frame = try session.frames.get(pending.continuation.id);
    const reader = try session.frames.slots.reader(frame.view);
    for (specialized.functions.items) |function| {
        if (function.before != loop) continue;
        // Original loop parameter 0 is immutable program; parameter 1 is the
        // service state. Specialization removes only wholly known parameters.
        if (function.arguments[1] == .known) return error.InvalidRecovery;
        const parameter: usize = @intFromBool(function.arguments[0] != .known);
        const variable = specialized.builder.functions.items[@intCast(function.after)].parameters[parameter];
        for (compiled.parameters) |binding| {
            if (binding.source_function != function.after or binding.variable != variable or binding.function != frame.function) continue;
            const saved = try reader.at(@intCast(binding.slot));
            if (saved.schema != binding.schema) return error.InvalidRecovery;
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            var values: @import("interpreter_v2/values.zig").Values = .{ .allocator = scratch.allocator(), .schemas = session.program.schemas, .store = &session.store, .aggregate_storage = .structured };
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
            var reconstructed = try projection.decode(data.process_state.State, a, try reification.bytes(&outcome.completed));
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
    // Hydration installs this exact program; spelling the field explicitly
    // makes its static knowledge available across the dynamic hydration call.
    const state = try e.replace(try b.reference(hydrated), @backingInt(machines.Field.program), try e.param(entry, 0));
    try b.define(entry, try b.bind(hydrated, try e.call(machine.hydrate, &.{ try e.param(entry, 0), try e.param(entry, 1) }), try b.bind(advanced, try e.call(dispatch, &.{state}), try e.call(machine.project, &.{try e.payload(try b.reference(advanced), 0)}))));
    const original = b.module(entry, e.unit);
    const request: source.specialize.Request = .{
        .function = entry,
        .arguments = &.{ .{ .known = .{ .schema = machine.program, .bytes = program } }, .dynamic },
        .context = context(admitted.identity()),
        .policy = .{ .work = 8_000_000, .keys_per_function = 128, .depth = 1024 },
    };
    var specialized = try source.specialize.specialize(a, original, request);
    defer specialized.deinit();
    var static_instructions: usize = 0;
    for (specialized.functions.items) |f| if (f.before == step.instruction_at and f.arguments[2] == .known) {
        static_instructions += 1;
        try std.testing.expect(f.arguments[1] == .known);
        try std.testing.expect(f.arguments[3] == .known);
        try std.testing.expect(f.arguments[4] == .known);
        try std.testing.expect(f.arguments[5] == .known);
        try std.testing.expect(f.arguments[6] == .known);
        try std.testing.expectEqual(@as(usize, 1), specialized.builder.functions.items[@intCast(f.after)].parameters.len);
    };
    try std.testing.expect(static_instructions >= 3);
    var core = try support.prepare(specialized.module());
    defer core.deinit();
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
            var portable = try base.Session.start(a, &core, argument, .{});
            defer portable.deinit();
            const outcome = try portable.run(null);
            try std.testing.expect(outcome == .completed);
            var result = try projection.decode(data.process_state.State, a, try portable.bytes(&outcome.completed));
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
