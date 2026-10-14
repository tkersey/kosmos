const std = @import("std");
const h = @import("horos");
const k = @import("kosmos");
const a = std.testing.allocator;
const Exit = enum { failure, instruction_fault, cancellation };
const Call = enum { direct, nested, closure, injected, injected_inner, injected_bound, deep_disposal, deep_owned_return, deep_owned_protected, nested_deep_disposal, nested_shallow_disposal, dispose, resume_capture, resume_successor };

fn fixture(b: *h.source.Builder, allow_seed: bool, exit: Exit, declared_effect: bool, invocation: Call) !h.source.Module {
    const nested_disposal = invocation == .nested_deep_disposal or invocation == .nested_shallow_disposal;
    const nested_token = nested_disposal or invocation == .dispose or invocation == .resume_capture or invocation == .resume_successor;
    const injection = invocation == .injected or invocation == .injected_inner or invocation == .injected_bound;
    const owned_return = invocation == .deep_owned_return or invocation == .deep_owned_protected;
    const deep = invocation == .deep_disposal or owned_return;
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const token_t = try b.reserveSchema();
    const token_v = if (nested_disposal) try b.reserveSchema() else token_t;
    const nested_token_u = if (nested_disposal) try b.reserveSchema() else null;
    const fault = try b.constant(void, {});
    const e = try b.effect(.{ .identity = "probe/outer", .payload = unit, .result = unit, .external = false });
    const t = if (deep) e else try b.effect(.{ .identity = "probe/token", .payload = unit, .result = unit, .external = false });
    const token_effects: []const u64 = if (deep) &.{e} else &.{ e, t };
    const token_mode: h.data.program.Mode = if (deep) .deep else .shallow;
    const u = if (injection or nested_token) try b.effect(.{ .identity = "probe/injection", .payload = unit, .result = unit, .external = false }) else t;
    const outer_effects: []const u64 = if (injection or nested_token) &.{ e, u } else &.{e};
    const residual_effects: []const u64 = if (injection or nested_token) &.{u} else &.{};
    const cap_e = try b.schema(.{ .internal = .{ .capability = e } });
    const cap_t = try b.schema(.{ .internal = .{ .capability = t } });
    const outer_capture: []const u64 = if (nested_disposal)
        (if (allow_seed) &.{ unit, cap_e, cap_t, token_t, token_v, nested_token_u.?, integer } else &.{ unit, cap_e, cap_t, token_t, token_v, nested_token_u.? })
    else
        (if (allow_seed) &.{ unit, cap_e, cap_t, token_t, integer } else &.{ unit, cap_e, cap_t, token_t });
    const token_e = try b.schema(.{ .internal = .{ .resumption = .{ .effect = e, .input = unit, .answer = integer, .effects = residual_effects, .handled = &.{e}, .capture_bound = outer_capture, .mode = .deep, .use = .linear, .obligations = true } } });
    try b.defineSchema(token_t, .{ .internal = .{ .resumption = .{ .effect = t, .input = unit, .answer = if (deep) token_t else unit, .effects = token_effects, .handled = &.{t}, .escaping = if (deep) &.{} else &.{e}, .capture_bound = &.{ unit, cap_e, cap_t, integer }, .mode = token_mode, .use = .linear, .obligations = true } } });
    const info = try h.library.cleanup.exitInfo(b, unit);
    const main = try b.declare(&.{}, integer, residual_effects, &.{});
    const outer = try b.declare(&.{cap_e}, integer, outer_effects, &.{});
    const ret_e = try b.declare(&.{integer}, integer, &.{}, &.{});
    const clause_e = try b.declare(&.{ unit, token_e }, integer, residual_effects, &.{});
    const inner = try b.declare(&.{cap_t}, unit, token_effects, &.{});
    const ret_t = try b.declare(&.{unit}, token_t, &.{}, &.{});
    const clause_t = try b.declare(&.{ unit, token_t }, token_t, &.{}, &.{});
    const work = try b.declare(&.{}, unit, &.{t}, &.{});
    const clean = try b.declare(&.{info}, unit, &.{e}, &.{});
    const helper = try b.declare(&.{token_t}, unit, if (declared_effect) &.{e} else &.{}, &.{});
    try b.define(ret_e, try b.pure(try b.reference(b.parameter(ret_e, 0))));
    try b.define(clause_e, try b.term(.{ .yield_then = try b.term(.{ .resume_value = .{ .resumption = try b.reference(b.parameter(clause_e, 1)), .argument = fault } }) }));
    try b.define(ret_t, try b.term(.{ .fail = fault }));
    if (invocation == .deep_owned_protected) {
        const body = try b.declare(&.{token_t}, token_t, &.{}, &.{});
        try b.define(body, try b.pure(try b.reference(b.parameter(body, 0))));
        const cleanup = try b.declare(&.{info}, unit, &.{}, &.{});
        try b.define(cleanup, try b.pure(fault));
        const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{token_t}, .result = token_t, .effects = &.{}, .capture_bound = &.{} } } });
        const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{info}, .result = unit, .effects = &.{}, .capture_bound = &.{} } } });
        try b.define(clause_t, try b.term(.{ .protect = .{ .body = try b.lambda(body, body_type), .arguments = &.{try b.reference(b.parameter(clause_t, 1))}, .cleanup = try b.lambda(cleanup, cleanup_type) } }));
    } else try b.define(clause_t, try b.pure(try b.reference(b.parameter(clause_t, 1))));
    try b.define(work, try b.term(.{ .perform = .{ .effect = t, .capability = try b.reference(b.parameter(inner, 0)), .payload = fault } }));
    try b.define(clean, try b.term(.{ .perform = .{ .effect = e, .capability = try b.reference(b.parameter(if (owned_return) inner else outer, 0)), .payload = fault } }));
    const failed = try b.term(.{ .fail = fault });
    const helper_body = switch (exit) {
        .failure => failed,
        .instruction_fault => blk: {
            const divided = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{
                .opcode = .integer_div,
                .operands = &.{ try b.constant(u64, 1), try b.constant(u64, 0) },
                .failures = &.{
                    .{ .kind = .arithmetic_overflow, .value = try b.failureLiteral(fault) },
                    .{ .kind = .division_by_zero, .value = try b.failureLiteral(fault) },
                },
            } } });
            break :blk try b.bind(try b.variable(integer), try b.pure(divided), failed);
        },
        .cancellation => try b.term(.{ .yield_then = try b.term(.{ .call = .{
            .function = helper,
            .arguments = &.{try b.reference(b.parameter(helper, 0))},
        } }) }),
    };
    try b.define(helper, if (owned_return)
        try b.bind(try b.variable(unit), try b.term(.{ .dispose = try b.reference(b.parameter(helper, 0)) }), try b.pure(fault))
    else
        helper_body);
    const work_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = unit, .effects = &.{t}, .capture_bound = &.{cap_t} } } });
    const clean_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{info}, .result = unit, .effects = &.{e}, .capture_bound = &.{cap_e} } } });
    try b.define(inner, try b.term(.{ .protect = .{ .body = try b.lambda(work, work_type), .cleanup = try b.lambda(clean, clean_type) } }));
    const handler_t = try b.handler(.{ .mode = token_mode, .input = unit, .answer = token_t, .return_function = ret_t, .clauses = &.{.{ .effect = t, .function = clause_t, .resumption = token_t }} });
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap_t}, .result = unit, .effects = token_effects, .capture_bound = &.{cap_e} } } });
    const token = try b.variable(token_t);
    const seed = try b.variable(integer);
    const ignored = try b.variable(if (nested_token) integer else unit);
    const call = switch (invocation) {
        .direct, .deep_disposal, .deep_owned_return, .deep_owned_protected => try b.term(.{ .call = .{ .function = helper, .arguments = &.{try b.reference(token)} } }),
        .nested => blk: {
            const wrapper = try b.declare(&.{token_t}, unit, if (declared_effect) &.{e} else &.{}, &.{});
            try b.define(wrapper, try b.term(.{ .call = .{ .function = helper, .arguments = &.{try b.reference(b.parameter(wrapper, 0))} } }));
            break :blk try b.term(.{ .call = .{ .function = wrapper, .arguments = &.{try b.reference(token)} } });
        },
        .injected, .injected_inner, .injected_bound, .dispose, .nested_deep_disposal, .nested_shallow_disposal, .resume_capture, .resume_successor => blk: {
            const carrier_result = if (invocation == .injected_inner or invocation == .injected_bound) integer else unit;
            const cap_u = try b.schema(.{ .internal = .{ .capability = u } });
            const token_u = nested_token_u orelse try b.reserveSchema();
            try b.defineSchema(token_u, .{ .internal = .{ .resumption = .{ .effect = u, .input = unit, .answer = carrier_result, .effects = if (invocation == .injected_bound) &.{ e, u } else &.{u}, .handled = &.{u}, .capture_bound = if (nested_token) &.{ unit, integer, token_t } else &.{ unit, integer }, .mode = .shallow, .use = .linear, .obligations = nested_token } } });
            const body_u = try b.declare(&.{cap_u}, carrier_result, &.{u}, &.{});
            const perform_u = try b.term(.{ .perform = .{ .effect = u, .capability = try b.reference(b.parameter(body_u, 0)), .payload = fault } });
            const inner_seed = try b.variable(integer);
            try b.define(body_u, if (nested_token)
                try b.bind(try b.variable(unit), perform_u, try b.term(.{ .call = .{ .function = helper, .arguments = &.{try b.reference(token)} } }))
            else if (invocation == .injected_inner or invocation == .injected_bound)
                try b.bind(inner_seed, try b.pure(try b.constant(u64, 42)), try b.bind(try b.variable(unit), perform_u, try b.pure(try b.reference(inner_seed))))
            else
                perform_u);
            const return_u = try b.declare(&.{carrier_result}, token_u, &.{}, &.{});
            try b.define(return_u, try b.term(.{ .fail = fault }));
            const clause_u = try b.declare(&.{ unit, token_u }, token_u, &.{}, &.{});
            try b.define(clause_u, try b.pure(try b.reference(b.parameter(clause_u, 1))));
            const handler_u = try b.handler(.{ .mode = .shallow, .input = carrier_result, .answer = token_u, .return_function = return_u, .clauses = &.{.{ .effect = u, .function = clause_u, .resumption = token_u }} });
            const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap_u}, .result = carrier_result, .effects = &.{u}, .capture_bound = if (nested_token) &.{token_t} else &.{}, .use = if (nested_token) .linear else .reusable } } });
            const thunk = try b.declare(&.{}, unit, &.{}, &.{});
            try b.define(thunk, try b.term(.{ .call = .{ .function = helper, .arguments = &.{try b.reference(token)} } }));
            const thunk_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = unit, .capture_bound = &.{token_t}, .use = .linear } } });
            const carrier = try b.variable(token_u);
            if (nested_token) {
                const after_capture = try b.variable(integer);
                const operation = switch (invocation) {
                    .dispose => try b.term(.{ .dispose = try b.reference(carrier) }),
                    .nested_deep_disposal, .nested_shallow_disposal => nested: {
                        const mode: h.data.program.Mode = if (invocation == .nested_deep_disposal) .deep else .shallow;
                        try b.defineSchema(token_v, .{ .internal = .{ .resumption = .{ .effect = e, .input = unit, .answer = if (mode == .deep) token_v else unit, .effects = if (mode == .deep) &.{} else &.{e}, .handled = &.{e}, .capture_bound = if (allow_seed) &.{ unit, token_u, integer, token_t, token_v } else &.{ unit, token_u, token_t, token_v }, .mode = mode, .use = .linear, .obligations = true } } });
                        const consumer_u = try b.declare(&.{token_u}, unit, &.{}, &.{});
                        try b.define(consumer_u, failed);
                        const work_v = try b.declare(&.{cap_e}, unit, &.{e}, &.{});
                        const perform_v = try b.term(.{ .perform = .{ .effect = e, .capability = try b.reference(b.parameter(work_v, 0)), .payload = fault } });
                        try b.define(work_v, try b.bind(try b.variable(unit), perform_v, try b.term(.{ .call = .{ .function = consumer_u, .arguments = &.{try b.reference(carrier)} } })));
                        const ret_v = try b.declare(&.{unit}, token_v, &.{}, &.{});
                        try b.define(ret_v, failed);
                        const clause_v = try b.declare(&.{ unit, token_v }, token_v, &.{}, &.{});
                        try b.define(clause_v, try b.pure(try b.reference(b.parameter(clause_v, 1))));
                        const handler_v = try b.handler(.{ .mode = mode, .input = unit, .answer = token_v, .return_function = ret_v, .clauses = &.{.{ .effect = e, .function = clause_v, .resumption = token_v }} });
                        const work_v_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap_e}, .result = unit, .effects = &.{e}, .capture_bound = &.{token_u}, .use = .linear } } });
                        const final = try b.variable(token_v);
                        const consumer_v = try b.declare(&.{token_v}, unit, &.{e}, &.{});
                        try b.define(consumer_v, failed);
                        break :nested try b.bind(final, try b.term(.{ .handle = .{ .handler = handler_v, .body = try b.lambda(work_v, work_v_type) } }), try b.term(.{ .call = .{ .function = consumer_v, .arguments = &.{try b.reference(final)} } }));
                    },
                    .resume_capture => try b.term(.{ .resume_value = .{ .resumption = try b.reference(carrier), .argument = fault } }),
                    .resume_successor => successor: {
                        const returns = try b.declare(&.{unit}, unit, &.{}, &.{});
                        try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
                        const clause = try b.declare(&.{ unit, token_u }, unit, &.{}, &.{});
                        try b.define(clause, try b.term(.{ .fail = fault }));
                        const handler = try b.handler(.{ .mode = .shallow, .input = unit, .answer = unit, .return_function = returns, .clauses = &.{.{ .effect = u, .function = clause, .resumption = token_u }} });
                        break :successor try b.term(.{ .resume_with = .{ .resumption = try b.reference(carrier), .argument = fault, .handler = handler } });
                    },
                    else => unreachable,
                };
                break :blk try b.bind(carrier, try b.term(.{ .handle = .{ .handler = handler_u, .body = try b.lambda(body_u, body_type) } }), try b.bind(after_capture, try b.pure(try b.constant(u64, 42)), try b.bind(try b.variable(unit), operation, try b.pure(try b.reference(after_capture)))));
            }
            break :blk try b.bind(carrier, try b.term(.{ .handle = .{ .handler = handler_u, .body = try b.lambda(body_u, body_type) } }), try b.bind(try b.variable(carrier_result), try b.term(.{ .resume_computation = .{ .resumption = try b.reference(carrier), .computation = try b.lambda(thunk, thunk_type) } }), try b.pure(fault)));
        },
        .closure => blk: {
            const callable = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{token_t}, .result = unit, .effects = if (declared_effect) &.{e} else &.{} } } });
            break :blk try b.term(.{ .apply = .{ .computation = try b.lambda(helper, callable), .arguments = &.{try b.reference(token)} } });
        },
    };
    const yield = try b.term(.{ .yield_then = call });
    const tail = try b.bind(ignored, yield, try b.pure(if (nested_token) try b.reference(ignored) else if (invocation == .injected_inner or invocation == .injected_bound) try b.constant(u64, 42) else try b.reference(seed)));
    const handled = try b.term(.{ .handle = .{ .handler = handler_t, .body = try b.lambda(inner, inner_type) } });
    try b.define(outer, try b.bind(token, handled, try b.bind(seed, try b.pure(try b.constant(u64, 42)), tail)));
    const handler_e = try b.handler(.{ .mode = .deep, .input = integer, .answer = integer, .effects = residual_effects, .return_function = ret_e, .clauses = &.{.{ .effect = e, .function = clause_e, .resumption = token_e }} });
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap_e}, .result = integer, .effects = outer_effects } } });
    try b.define(main, try b.term(.{ .handle = .{ .handler = handler_e, .body = try b.lambda(outer, outer_type) } }));
    return b.module(main, unit);
}

test "explicit disposal retains owned cleanup answers across restore and cancellation" {
    for ([_]Call{ .deep_owned_return, .deep_owned_protected }) |variant| try checkOwnedReturn(variant);
}

fn checkOwnedReturn(variant: Call) !void {
    var builder = h.source.Builder.init(a);
    defer builder.deinit();
    const module = try fixture(&builder, true, .failure, true, variant);
    var compiled = try h.program.compileObserved(a, module, .{ .coalescing = .{ .work_limit = 0 } });
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try h.data.program_image.encodedLength(compiled.program));
    defer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    var prepared = try k.Prepared.init(a, bytes);
    defer prepared.deinit();
    var resident = try k.Resident.start(a, &prepared, &.{});
    defer release(&resident);
    var control: h.data.invocation.Control = .none;
    // Observe every transition, including the clause returning a token whose
    // capture owns the running cleanup. Disposal must consume that answer.
    for (0..1000) |step| {
        errdefer std.debug.print("owned cleanup {t} return at step {d}\n", .{ variant, step });
        var publication = try resident.publish(.{ .record = a }, control, .{ .quantum = 1, .checkpoint = .receipt });
        defer publication.deinit();
        const restored = try k.Resident.restore(a, &prepared, publication.checkpoint.?.bytes());
        release(&resident);
        resident = restored;
        if (publication.outcome.record.record == .completed) {
            try std.testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, publication.outcome.record.record.completed);
            var uninterrupted = try k.Resident.start(a, &prepared, &.{});
            defer release(&uninterrupted);
            var yielded = try uninterrupted.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
            defer yielded.deinit();
            try std.testing.expect(yielded.outcome.record.record == .yielded);
            var terminal = try uninterrupted.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
            defer terminal.deinit();
            try std.testing.expectEqualSlices(u8, publication.checkpoint.?.bytes(), terminal.checkpoint.?.bytes());
            return;
        }
        var cancelled = try k.Resident.restore(a, &prepared, publication.checkpoint.?.bytes());
        defer release(&cancelled);
        var cancel_control: h.data.invocation.Control = .{ .cancel = .{ .text = "stop" } };
        var cancellation_done = false;
        for (0..1000) |_| {
            var stopped = try cancelled.publish(.{ .record = a }, cancel_control, .{ .quantum = 1, .checkpoint = .receipt });
            defer stopped.deinit();
            const restored_stop = try k.Resident.restore(a, &prepared, stopped.checkpoint.?.bytes());
            release(&cancelled);
            cancelled = restored_stop;
            switch (stopped.outcome.record.record) {
                .cancelled => |done| {
                    try std.testing.expectEqualStrings("stop", done.reason.text);
                    cancellation_done = true;
                    break;
                },
                // Cleanup remains ordinary authored code and can yield.
                .yielded => cancel_control = .resume_yield,
                .progressed => cancel_control = .none,
                else => return error.UnexpectedCancellationOutcome,
            }
        }
        try std.testing.expect(cancellation_done);
        control = switch (publication.outcome.record.record) {
            .yielded => .resume_yield,
            .progressed => .none,
            else => return error.UnexpectedOutcome,
        };
    }
    return error.InconclusiveTransitionLimit;
}

fn release(resident: *k.Resident) void {
    if (!resident.live) return;
    const checkpoint = resident.takeCheckpoint(a) catch unreachable;
    a.free(checkpoint);
}

test "implicit disposal checks caller captures through failure faults and cancellation" {
    for ([_]Exit{ .failure, .instruction_fault, .cancellation }) |exit| {
        for ([_]Call{ .resume_capture, .resume_successor, .dispose, .deep_disposal, .nested_deep_disposal, .nested_shallow_disposal, .direct, .nested, .closure, .injected, .injected_inner, .injected_bound }) |invocation| {
            if ((invocation == .nested_deep_disposal or invocation == .nested_shallow_disposal) and exit != .failure) continue;
            if ((invocation == .dispose or invocation == .resume_capture or invocation == .resume_successor) and exit != .failure) continue;
            for ([_]bool{ false, true }) |declared_effect| {
                if ((invocation == .nested_deep_disposal or invocation == .nested_shallow_disposal) and declared_effect) continue;
                if ((invocation == .injected or invocation == .injected_inner or invocation == .injected_bound or invocation == .dispose or invocation == .resume_capture or invocation == .resume_successor) and declared_effect) continue;
                for ([_]bool{ false, true }) |allow_seed| {
                    var diagnostic: h.source.Diagnostic = .{};
                    errdefer std.debug.print("implicit disposal {t}/{t}, declared={}, broad={}: {any}\n", .{ exit, invocation, declared_effect, allow_seed, diagnostic });
                    var builder = h.source.Builder.init(a);
                    defer builder.deinit();
                    const module = try fixture(&builder, allow_seed, exit, declared_effect, invocation);
                    if (!allow_seed) {
                        var unexpected = h.program.compileObserved(a, module, .{ .diagnostic = &diagnostic, .coalescing = .{ .work_limit = 0 } }) catch |err| {
                            try std.testing.expectEqual(error.InvalidOwnership, err);
                            continue;
                        };
                        unexpected.deinit();
                        return error.NarrowCaptureAccepted;
                    }
                    var compiled = try h.program.compileObserved(a, module, .{ .diagnostic = &diagnostic, .coalescing = .{ .work_limit = 0 } });
                    defer compiled.deinit();
                    const bytes = try a.alloc(u8, try h.data.program_image.encodedLength(compiled.program));
                    defer a.free(bytes);
                    _ = try compiled.encode(a, bytes);
                    var prepared = try k.Prepared.init(a, bytes);
                    defer prepared.deinit();
                    var resident = try k.Resident.start(a, &prepared, &.{});
                    defer release(&resident);
                    var first = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
                    defer first.deinit();
                    try std.testing.expect(first.outcome.record.record == .yielded);
                    // Save a position after the initial yield and before cleanup
                    // starts, then execute from the public restored owner.
                    var entered = try resident.publish(.{ .record = a }, .resume_yield, .{ .quantum = 1, .checkpoint = .receipt });
                    defer entered.deinit();
                    var restored = try k.Resident.restore(a, &prepared, entered.checkpoint.?.bytes());
                    defer release(&restored);
                    const control: h.data.invocation.Control = if (exit == .cancellation) .{ .cancel = .{ .text = "stop" } } else .none;
                    var cleanup = try restored.publish(.{ .record = a }, control, .{ .checkpoint = .receipt });
                    defer cleanup.deinit();
                    // The outer E handler yields: this witnesses actual cleanup
                    // dispatch, not only acceptance of a dormant token.
                    try std.testing.expect(cleanup.outcome.record.record == .yielded);
                    var nonstop = try restored.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
                    defer nonstop.deinit();
                    var resumed = try k.Resident.restore(a, &prepared, cleanup.checkpoint.?.bytes());
                    defer release(&resumed);
                    var terminal = try resumed.publish(.{ .record = a }, .resume_yield, .{ .checkpoint = .receipt });
                    defer terminal.deinit();
                    try std.testing.expectEqualSlices(u8, nonstop.checkpoint.?.bytes(), terminal.checkpoint.?.bytes());
                    if (invocation == .dispose) {
                        try std.testing.expect(terminal.outcome.record.record == .completed);
                        try std.testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 0, 0, 0, 0 }, terminal.outcome.record.record.completed);
                    } else if (exit == .cancellation)
                        try std.testing.expect(terminal.outcome.record.record == .cancelled)
                    else
                        try std.testing.expect(terminal.outcome.record.record == .failed);
                }
            }
        }
    }
}
