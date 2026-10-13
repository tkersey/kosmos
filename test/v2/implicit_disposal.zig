const std = @import("std");
const h = @import("horos");
const k = @import("kosmos");
const a = std.testing.allocator;
const Exit = enum { failure, instruction_fault, cancellation };
const Call = enum { direct, nested, closure, injected, injected_inner, injected_bound, deep_disposal, dispose, resume_capture, resume_successor };

fn fixture(b: *h.source.Builder, allow_seed: bool, exit: Exit, declared_effect: bool, invocation: Call) !h.source.Module {
    const nested_token = invocation == .dispose or invocation == .resume_capture or invocation == .resume_successor;
    const injection = invocation == .injected or invocation == .injected_inner or invocation == .injected_bound;
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const token_t = try b.reserveSchema();
    const fault = try b.constant(void, {});
    const e = try b.effect(.{ .identity = "probe/outer", .payload = unit, .result = unit, .external = false });
    const t = if (invocation == .deep_disposal) e else try b.effect(.{ .identity = "probe/token", .payload = unit, .result = unit, .external = false });
    const token_effects: []const u64 = if (invocation == .deep_disposal) &.{e} else &.{ e, t };
    const token_mode: h.data.program.Mode = if (invocation == .deep_disposal) .deep else .shallow;
    const u = if (injection or nested_token) try b.effect(.{ .identity = "probe/injection", .payload = unit, .result = unit, .external = false }) else t;
    const outer_effects: []const u64 = if (injection or nested_token) &.{ e, u } else &.{e};
    const residual_effects: []const u64 = if (injection or nested_token) &.{u} else &.{};
    const cap_e = try b.schema(.{ .internal = .{ .capability = e } });
    const cap_t = try b.schema(.{ .internal = .{ .capability = t } });
    const token_e = try b.schema(.{ .internal = .{ .resumption = .{ .effect = e, .input = unit, .answer = integer, .effects = residual_effects, .handled = &.{e}, .capture_bound = if (allow_seed) &.{ unit, cap_e, cap_t, token_t, integer } else &.{ unit, cap_e, cap_t, token_t }, .mode = .deep, .use = .linear, .obligations = true } } });
    try b.defineSchema(token_t, .{ .internal = .{ .resumption = .{ .effect = t, .input = unit, .answer = if (invocation == .deep_disposal) token_t else unit, .effects = token_effects, .handled = &.{t}, .escaping = if (invocation == .deep_disposal) &.{} else &.{e}, .capture_bound = &.{ unit, cap_e, cap_t, integer }, .mode = token_mode, .use = .linear, .obligations = true } } });
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
    try b.define(clause_t, try b.pure(try b.reference(b.parameter(clause_t, 1))));
    try b.define(work, try b.term(.{ .perform = .{ .effect = t, .capability = try b.reference(b.parameter(inner, 0)), .payload = fault } }));
    try b.define(clean, try b.term(.{ .perform = .{ .effect = e, .capability = try b.reference(b.parameter(outer, 0)), .payload = fault } }));
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
    try b.define(helper, helper_body);
    const work_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = unit, .effects = &.{t}, .capture_bound = &.{cap_t} } } });
    const clean_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{info}, .result = unit, .effects = &.{e}, .capture_bound = &.{cap_e} } } });
    try b.define(inner, try b.term(.{ .protect = .{ .body = try b.lambda(work, work_type), .cleanup = try b.lambda(clean, clean_type) } }));
    const handler_t = try b.handler(.{ .mode = token_mode, .input = unit, .answer = token_t, .return_function = ret_t, .clauses = &.{.{ .effect = t, .function = clause_t, .resumption = token_t }} });
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap_t}, .result = unit, .effects = token_effects, .capture_bound = &.{cap_e} } } });
    const token = try b.variable(token_t);
    const seed = try b.variable(integer);
    const ignored = try b.variable(if (nested_token) integer else unit);
    const call = switch (invocation) {
        .direct, .deep_disposal => try b.term(.{ .call = .{ .function = helper, .arguments = &.{try b.reference(token)} } }),
        .nested => blk: {
            const wrapper = try b.declare(&.{token_t}, unit, if (declared_effect) &.{e} else &.{}, &.{});
            try b.define(wrapper, try b.term(.{ .call = .{ .function = helper, .arguments = &.{try b.reference(b.parameter(wrapper, 0))} } }));
            break :blk try b.term(.{ .call = .{ .function = wrapper, .arguments = &.{try b.reference(token)} } });
        },
        .injected, .injected_inner, .injected_bound, .dispose, .resume_capture, .resume_successor => blk: {
            const carrier_result = if (invocation == .injected_inner or invocation == .injected_bound) integer else unit;
            const cap_u = try b.schema(.{ .internal = .{ .capability = u } });
            const token_u = try b.schema(.{ .internal = .{ .resumption = .{ .effect = u, .input = unit, .answer = carrier_result, .effects = if (invocation == .injected_bound) &.{ e, u } else &.{u}, .handled = &.{u}, .capture_bound = if (nested_token) &.{ unit, integer, token_t } else &.{ unit, integer }, .mode = .shallow, .use = .linear, .obligations = nested_token } } });
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

fn release(resident: *k.Resident) void {
    if (!resident.live) return;
    const checkpoint = resident.takeCheckpoint(a) catch unreachable;
    a.free(checkpoint);
}

test "implicit disposal checks caller captures through failure faults and cancellation" {
    for ([_]Exit{ .failure, .instruction_fault, .cancellation }) |exit| {
        for ([_]Call{ .resume_capture, .resume_successor, .dispose, .deep_disposal, .direct, .nested, .closure, .injected, .injected_inner, .injected_bound }) |invocation| {
            if ((invocation == .dispose or invocation == .resume_capture or invocation == .resume_successor) and exit != .failure) continue;
            for ([_]bool{ false, true }) |declared_effect| {
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
