const std = @import("std");
const h = @import("horos");
const k = @import("kosmos");
const a = std.testing.allocator;
const Exit = enum { failure, instruction_fault, cancellation };
const Call = enum {
    direct,
    nested,
    closure,
    injected,
    injected_inner,
    injected_bound,
    deep_disposal,
    deep_owned_return,
    deep_owned_protected,
    nested_deep_disposal,
    nested_shallow_disposal,
    dispose,
    resume_capture,
    resume_successor,
};

fn fixture(
    b: *h.source.Builder,
    allow_seed: bool,
    exit: Exit,
    declared_effect: bool,
    invocation: Call,
) !h.source.Module {
    const nested_disposal = invocation == .nested_deep_disposal or
        invocation == .nested_shallow_disposal;
    const nested_token = nested_disposal or
        invocation == .dispose or invocation == .resume_capture or invocation == .resume_successor;
    const injection = invocation == .injected or
        invocation == .injected_inner or invocation == .injected_bound;
    const owned_return = invocation == .deep_owned_return or invocation == .deep_owned_protected;
    const deep = invocation == .deep_disposal or owned_return;
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const token_t = try b.reserveSchema();
    const token_v = if (nested_disposal) try b.reserveSchema() else token_t;
    const nested_token_u = if (nested_disposal) try b.reserveSchema() else null;
    const fault = try b.constant(void, {});
    const effects = try disposalEffects(.{
        .b = b,
        .unit = unit,
        .deep = deep,
        .injection = injection,
        .nested_token = nested_token,
    });
    const e = effects.e;
    const t = effects.t;
    const u = effects.u;
    const token_effects: []const u64 = if (deep) &.{e} else &.{ e, t };
    const token_mode: h.data.program.Mode = if (deep) .deep else .shallow;
    const outer_effects: []const u64 = if (injection or nested_token) &.{ e, u } else &.{e};
    const residual_effects: []const u64 = if (injection or nested_token) &.{u} else &.{};
    const cap_e = try b.schema(.{ .internal = .{ .capability = e } });
    const cap_t = try b.schema(.{ .internal = .{ .capability = t } });
    return try disposalSchemaModule(.{
        .b = b,
        .nested_disposal = nested_disposal,
        .allow_seed = allow_seed,
        .unit = unit,
        .cap_e = cap_e,
        .cap_t = cap_t,
        .token_t = token_t,
        .token_v = token_v,
        .nested_token_u = nested_token_u,
        .integer = integer,
        .e = e,
        .residual_effects = residual_effects,
        .t = t,
        .deep = deep,
        .token_effects = token_effects,
        .token_mode = token_mode,
        .outer_effects = outer_effects,
        .declared_effect = declared_effect,
        .fault = fault,
        .invocation = invocation,
        .exit = exit,
        .owned_return = owned_return,
        .nested_token = nested_token,
        .u = u,
    });
}

test "explicit disposal retains owned cleanup answers across restore and cancellation" {
    for ([_]Call{
        .deep_owned_return,
        .deep_owned_protected,
    }) |variant| try checkOwnedReturn(variant);
}

fn checkOwnedReturn(variant: Call) !void {
    var builder = h.source.Builder.init(a);
    defer builder.deinit();
    const module = try fixture(&builder, true, .failure, true, variant);
    var compiled = try h.program.compileObserved(a, module, .{
        .coalescing = .{ .work_limit = 0 },
    });
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try h.data.program_image.encodedLength(compiled.program));
    defer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    var prepared = try k.Prepared.init(a, bytes);
    defer prepared.deinit();
    var resident = try k.Resident.start(a, &prepared, &.{});
    defer release(&resident);
    var control: h.data.invocation.Control = .none;
    for (0..1000) |step| {
        errdefer std.debug.print("owned cleanup {t} return at step {d}\n", .{ variant, step });
        var publication = try resident.publish(.{ .record = a }, control, .{
            .quantum = 1,
            .checkpoint = .receipt,
        });
        defer publication.deinit();
        const restored = try k.Resident.restore(a, &prepared, publication.checkpoint.?.bytes());
        release(&resident);
        resident = restored;
        if (publication.outcome.record.record == .completed) {
            try std.testing.expectEqualSlices(
                u8,
                &.{ 42, 0, 0, 0, 0, 0, 0, 0 },
                publication.outcome.record.record.completed,
            );
            try expectOwnedReturnCompletion(.{ .prepared = prepared, .publication = publication });
            return;
        }
        try expectOwnedReturnCancellation(.{ .prepared = prepared, .publication = publication });
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
    const checkpoint = resident.takeCheckpoint(a) catch |err|
        std.debug.panic("{s}", .{@errorName(err)});
    a.free(checkpoint);
}

test "implicit disposal checks caller captures through failure faults and cancellation" {
    for ([_]Exit{ .failure, .instruction_fault, .cancellation }) |exit| {
        for ([_]Call{
            .resume_capture,
            .resume_successor,
            .dispose,
            .deep_disposal,
            .nested_deep_disposal,
            .nested_shallow_disposal,
            .direct,
            .nested,
            .closure,
            .injected,
            .injected_inner,
            .injected_bound,
        }) |invocation| {
            if ((invocation == .nested_deep_disposal or
                invocation == .nested_shallow_disposal) and exit != .failure) continue;
            if ((invocation == .dispose or
                invocation == .resume_capture or
                invocation == .resume_successor) and exit != .failure) continue;
            for ([_]bool{ false, true }) |declared_effect| {
                if ((invocation == .nested_deep_disposal or
                    invocation == .nested_shallow_disposal) and declared_effect) continue;
                if ((invocation == .injected or
                    invocation == .injected_inner or
                    invocation == .injected_bound or
                    invocation == .dispose or
                    invocation == .resume_capture or
                    invocation == .resume_successor) and declared_effect) continue;
                for ([_]bool{ false, true }) |allow_seed| {
                    try expectDisposalCase(.{
                        .exit = exit,
                        .invocation = invocation,
                        .declared_effect = declared_effect,
                        .allow_seed = allow_seed,
                    });
                }
            }
        }
    }
}

fn nestedDisposal(c: anytype) !u64 {
    const mode: h.data.program.Mode =
        if (c.invocation == .nested_deep_disposal) .deep else .shallow;
    try c.b.defineSchema(
        c.token_v,
        .{
            .internal = .{
                .resumption = .{
                    .effect = c.e,
                    .input = c.unit,
                    .answer = if (mode == .deep) c.token_v else c.unit,
                    .effects = if (mode == .deep) &.{} else &.{c.e},
                    .handled = &.{c.e},
                    .capture_bound = if (c.allow_seed) &.{
                        c.unit, c.token_u, c.integer, c.token_t, c.token_v,
                    } else &.{ c.unit, c.token_u, c.token_t, c.token_v },
                    .mode = mode,
                    .use = .linear,
                    .obligations = true,
                },
            },
        },
    );
    const consumer_u = try c.b.declare(&.{c.token_u}, c.unit, &.{}, &.{});
    try c.b.define(consumer_u, c.failed);
    const work_v = try c.b.declare(&.{c.cap_e}, c.unit, &.{c.e}, &.{});
    const perform_v = try c.b.term(.{ .perform = .{
        .effect = c.e,
        .capability = try c.b.reference(c.b.parameter(work_v, 0)),
        .payload = c.fault,
    } });
    try c.b.define(
        work_v,
        try c.b.bind(
            try c.b.variable(c.unit),
            perform_v,
            try c.b.term(
                .{
                    .call = .{
                        .function = consumer_u,
                        .arguments = &.{try c.b.reference(c.carrier)},
                    },
                },
            ),
        ),
    );
    return try nestedDisposalHandler(.{ .c = c, .work_v = work_v, .mode = mode });
}

fn nestedDisposalHandler(c: anytype) !u64 {
    const setup = c.c;
    const b = setup.b;
    const ret_v = try b.declare(&.{setup.unit}, setup.token_v, &.{}, &.{});
    try b.define(ret_v, setup.failed);
    const clause_v = try b.declare(
        &.{ setup.unit, setup.token_v },
        setup.token_v,
        &.{},
        &.{},
    );
    try b.define(clause_v, try b.pure(
        try b.reference(b.parameter(clause_v, 1)),
    ));
    const handler_v = try b.handler(
        .{
            .mode = c.mode,
            .input = setup.unit,
            .answer = setup.token_v,
            .return_function = ret_v,
            .clauses = &.{
                .{ .effect = setup.e, .function = clause_v, .resumption = setup.token_v },
            },
        },
    );
    const work_v_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{setup.cap_e},
        .result = setup.unit,
        .effects = &.{setup.e},
        .capture_bound = &.{setup.token_u},
        .use = .linear,
    } } });
    const final = try b.variable(setup.token_v);
    const consumer_v = try b.declare(&.{setup.token_v}, setup.unit, &.{setup.e}, &.{});
    try b.define(consumer_v, setup.failed);
    return try b.bind(final, try b.term(.{ .handle = .{
        .handler = handler_v,
        .body = try b.lambda(c.work_v, work_v_type),
    } }), try b.term(.{ .call = .{
        .function = consumer_v,
        .arguments = &.{try b.reference(final)},
    } }));
}

fn carrierCall(c: anytype) !u64 {
    const carrier_result = if (c.invocation == .injected_inner or
        c.invocation == .injected_bound) c.integer else c.unit;
    const cap_u = try c.b.schema(.{ .internal = .{ .capability = c.u } });
    const token_u = c.nested_token_u orelse try c.b.reserveSchema();
    try c.b.defineSchema(token_u, .{ .internal = .{ .resumption = .{
        .effect = c.u,
        .input = c.unit,
        .answer = carrier_result,
        .effects = if (c.invocation == .injected_bound) &.{ c.e, c.u } else &.{c.u},
        .handled = &.{c.u},
        .capture_bound = if (c.nested_token)
            &.{ c.unit, c.integer, c.token_t }
        else
            &.{ c.unit, c.integer },
        .mode = .shallow,
        .use = .linear,
        .obligations = c.nested_token,
    } } });
    const body_u = try c.b.declare(&.{cap_u}, carrier_result, &.{c.u}, &.{});
    const perform_u = try c.b.term(.{ .perform = .{
        .effect = c.u,
        .capability = try c.b.reference(c.b.parameter(body_u, 0)),
        .payload = c.fault,
    } });
    const inner_seed = try c.b.variable(c.integer);
    try c.b.define(body_u, if (c.nested_token)
        try c.b.bind(try c.b.variable(c.unit), perform_u, try c.b.term(.{ .call = .{
            .function = c.helper,
            .arguments = &.{try c.b.reference(c.token)},
        } }))
    else if (c.invocation == .injected_inner or c.invocation == .injected_bound)
        try c.b.bind(inner_seed, try c.b.pure(try c.b.constant(u64, 42)), try c.b.bind(
            try c.b.variable(c.unit),
            perform_u,
            try c.b.pure(try c.b.reference(inner_seed)),
        ))
    else
        perform_u);
    return try carrierHandlerCall(.{
        .c = c,
        .carrier_result = carrier_result,
        .token_u = token_u,
        .body_u = body_u,
        .cap_u = cap_u,
    });
}

fn carrierOperation(c: anytype) !u64 {
    const setup = c.c;
    const b = setup.b;
    const operation = switch (setup.invocation) {
        .dispose => try b.term(.{ .dispose = try b.reference(c.carrier) }),
        .nested_deep_disposal, .nested_shallow_disposal => nested: {
            break :nested try nestedDisposal(.{
                .b = b,
                .invocation = setup.invocation,
                .token_v = setup.token_v,
                .e = setup.e,
                .unit = setup.unit,
                .allow_seed = setup.allow_seed,
                .token_u = c.token_u,
                .integer = setup.integer,
                .token_t = setup.token_t,
                .failed = setup.failed,
                .cap_e = setup.cap_e,
                .fault = setup.fault,
                .carrier = c.carrier,
            });
        },
        .resume_capture => try b.term(.{ .resume_value = .{
            .resumption = try b.reference(c.carrier),
            .argument = setup.fault,
        } }),
        .resume_successor => successor: {
            const returns = try b.declare(&.{setup.unit}, setup.unit, &.{}, &.{});
            try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
            const clause = try b.declare(&.{ setup.unit, c.token_u }, setup.unit, &.{}, &.{});
            try b.define(clause, try b.term(.{ .fail = setup.fault }));
            const handler = try b.handler(
                .{
                    .mode = .shallow,
                    .input = setup.unit,
                    .answer = setup.unit,
                    .return_function = returns,
                    .clauses = &.{
                        .{ .effect = setup.u, .function = clause, .resumption = c.token_u },
                    },
                },
            );
            break :successor try b.term(.{ .resume_with = .{
                .resumption = try b.reference(c.carrier),
                .argument = setup.fault,
                .handler = handler,
            } });
        },
        else => unreachable,
    };
    return operation;
}

fn carrierHandlerCall(c: anytype) !u64 {
    const setup = c.c;
    const b = setup.b;
    const return_u = try b.declare(&.{c.carrier_result}, c.token_u, &.{}, &.{});
    try b.define(return_u, try b.term(.{ .fail = setup.fault }));
    const clause_u = try b.declare(&.{ setup.unit, c.token_u }, c.token_u, &.{}, &.{});
    try b.define(clause_u, try b.pure(try b.reference(b.parameter(clause_u, 1))));
    const handler_u = try b.handler(
        .{
            .mode = .shallow,
            .input = c.carrier_result,
            .answer = c.token_u,
            .return_function = return_u,
            .clauses = &.{
                .{ .effect = setup.u, .function = clause_u, .resumption = c.token_u },
            },
        },
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{c.cap_u},
        .result = c.carrier_result,
        .effects = &.{setup.u},
        .capture_bound = if (setup.nested_token) &.{setup.token_t} else &.{},
        .use = if (setup.nested_token) .linear else .reusable,
    } } });
    return try carrierResumeCall(.{ .c = c, .handler_u = handler_u, .body_type = body_type });
}

fn carrierResumeCall(c: anytype) !u64 {
    const setup = c.c.c;
    const functions = c.c;
    const b = setup.b;
    const thunk = try b.declare(&.{}, setup.unit, &.{}, &.{});
    try b.define(thunk, try b.term(.{ .call = .{
        .function = setup.helper,
        .arguments = &.{try b.reference(setup.token)},
    } }));
    const thunk_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = setup.unit,
        .capture_bound = &.{setup.token_t},
        .use = .linear,
    } } });
    const carrier = try b.variable(functions.token_u);
    if (setup.nested_token) {
        const after_capture = try b.variable(setup.integer);
        const operation = try carrierOperation(.{
            .c = functions.c,
            .token_u = functions.token_u,
            .carrier = carrier,
        });
        return try b.bind(carrier, try b.term(.{ .handle = .{
            .handler = c.handler_u,
            .body = try b.lambda(functions.body_u, c.body_type),
        } }), try b.bind(after_capture, try b.pure(try b.constant(u64, 42)), try b.bind(
            try b.variable(setup.unit),
            operation,
            try b.pure(try b.reference(after_capture)),
        )));
    }
    return try b.bind(carrier, try b.term(.{ .handle = .{
        .handler = c.handler_u,
        .body = try b.lambda(functions.body_u, c.body_type),
    } }), try b.bind(try b.variable(functions.carrier_result), try b.term(
        .{ .resume_computation = .{
            .resumption = try b.reference(carrier),
            .computation = try b.lambda(thunk, thunk_type),
        } },
    ), try b.pure(setup.fault)));
}

fn invocationCall(c: anytype) !u64 {
    const call = switch (c.invocation) {
        .direct, .deep_disposal, .deep_owned_return, .deep_owned_protected => try c.b.term(
            .{ .call = .{
                .function = c.helper,
                .arguments = &.{try c.b.reference(c.token)},
            } },
        ),
        .nested => blk: {
            const wrapper = try c.b.declare(
                &.{c.token_t},
                c.unit,
                if (c.declared_effect) &.{c.e} else &.{},
                &.{},
            );
            try c.b.define(wrapper, try c.b.term(.{ .call = .{
                .function = c.helper,
                .arguments = &.{try c.b.reference(c.b.parameter(wrapper, 0))},
            } }));
            break :blk try c.b.term(.{ .call = .{
                .function = wrapper,
                .arguments = &.{try c.b.reference(c.token)},
            } });
        },
        .injected,
        .injected_inner,
        .injected_bound,
        .dispose,
        .nested_deep_disposal,
        .nested_shallow_disposal,
        .resume_capture,
        .resume_successor,
        => blk: {
            break :blk try carrierCall(.{
                .b = c.b,
                .invocation = c.invocation,
                .unit = c.unit,
                .integer = c.integer,
                .u = c.u,
                .nested_token_u = c.nested_token_u,
                .nested_token = c.nested_token,
                .token_t = c.token_t,
                .helper = c.helper,
                .token = c.token,
                .fault = c.fault,
                .token_v = c.token_v,
                .e = c.e,
                .allow_seed = c.allow_seed,
                .failed = c.failed,
                .cap_e = c.cap_e,
            });
        },
        .closure => blk: {
            const callable = try c.b.schema(.{ .internal = .{ .computation = .{
                .parameters = &.{c.token_t},
                .result = c.unit,
                .effects = if (c.declared_effect) &.{c.e} else &.{},
            } } });
            break :blk try c.b.term(.{ .apply = .{
                .computation = try c.b.lambda(c.helper, callable),
                .arguments = &.{try c.b.reference(c.token)},
            } });
        },
    };
    return call;
}

fn disposalTokenSchemas(c: anytype) !u64 {
    const outer_capture: []const u64 = if (c.nested_disposal)
        (if (c.allow_seed) &.{
            c.unit, c.cap_e, c.cap_t, c.token_t, c.token_v, c.nested_token_u.?, c.integer,
        } else &.{
            c.unit, c.cap_e, c.cap_t, c.token_t, c.token_v, c.nested_token_u.?,
        })
    else
        (if (c.allow_seed) &.{
            c.unit, c.cap_e, c.cap_t, c.token_t, c.integer,
        } else &.{ c.unit, c.cap_e, c.cap_t, c.token_t });
    const token_e = try c.b.schema(.{ .internal = .{ .resumption = .{
        .effect = c.e,
        .input = c.unit,
        .answer = c.integer,
        .effects = c.residual_effects,
        .handled = &.{c.e},
        .capture_bound = outer_capture,
        .mode = .deep,
        .use = .linear,
        .obligations = true,
    } } });
    try c.b.defineSchema(c.token_t, .{ .internal = .{ .resumption = .{
        .effect = c.t,
        .input = c.unit,
        .answer = if (c.deep) c.token_t else c.unit,
        .effects = c.token_effects,
        .handled = &.{c.t},
        .escaping = if (c.deep) &.{} else &.{c.e},
        .capture_bound = &.{ c.unit, c.cap_e, c.cap_t, c.integer },
        .mode = c.token_mode,
        .use = .linear,
        .obligations = true,
    } } });
    return token_e;
}

fn disposalFunctions(c: anytype) !h.source.Module {
    const info = try h.library.cleanup.exitInfo(c.b, c.unit);
    const main = try c.b.declare(&.{}, c.integer, c.residual_effects, &.{});
    const outer = try c.b.declare(&.{c.cap_e}, c.integer, c.outer_effects, &.{});
    const ret_e = try c.b.declare(&.{c.integer}, c.integer, &.{}, &.{});
    const clause_e = try c.b.declare(&.{ c.unit, c.token_e }, c.integer, c.residual_effects, &.{});
    const inner = try c.b.declare(&.{c.cap_t}, c.unit, c.token_effects, &.{});
    const ret_t = try c.b.declare(&.{c.unit}, c.token_t, &.{}, &.{});
    const clause_t = try c.b.declare(&.{ c.unit, c.token_t }, c.token_t, &.{}, &.{});
    const work = try c.b.declare(&.{}, c.unit, &.{c.t}, &.{});
    const clean = try c.b.declare(&.{info}, c.unit, &.{c.e}, &.{});
    const helper = try c.b.declare(
        &.{c.token_t},
        c.unit,
        if (c.declared_effect) &.{c.e} else &.{},
        &.{},
    );
    try c.b.define(ret_e, try c.b.pure(try c.b.reference(c.b.parameter(ret_e, 0))));
    try c.b.define(clause_e, try c.b.term(.{ .yield_then = try c.b.term(.{ .resume_value = .{
        .resumption = try c.b.reference(c.b.parameter(clause_e, 1)),
        .argument = c.fault,
    } }) }));
    try c.b.define(ret_t, try c.b.term(.{ .fail = c.fault }));
    try defineProtectedTokenReturn(.{ .c = c, .info = info, .clause_t = clause_t });
    try defineDisposalCleanup(.{
        .c = c,
        .work = work,
        .inner = inner,
        .clean = clean,
        .outer = outer,
    });
    const failed = try c.b.term(.{ .fail = c.fault });
    try defineDisposalHelper(.{ .c = c, .failed = failed, .helper = helper });
    return try disposalHandlerModule(.{
        .c = c,
        .info = info,
        .work = work,
        .clean = clean,
        .inner = inner,
        .ret_t = ret_t,
        .clause_t = clause_t,
        .helper = helper,
        .failed = failed,
        .outer = outer,
        .ret_e = ret_e,
        .clause_e = clause_e,
        .main = main,
    });
}

fn defineDisposalCleanup(c: anytype) !void {
    const setup = c.c;
    const b = setup.b;
    try b.define(c.work, try b.term(.{ .perform = .{
        .effect = setup.t,
        .capability = try b.reference(b.parameter(c.inner, 0)),
        .payload = setup.fault,
    } }));
    try b.define(
        c.clean,
        try b.term(
            .{
                .perform = .{
                    .effect = setup.e,
                    .capability = try b.reference(
                        b.parameter(if (setup.owned_return) c.inner else c.outer, 0),
                    ),
                    .payload = setup.fault,
                },
            },
        ),
    );
}

fn defineDisposalHelper(c: anytype) !void {
    const setup = c.c;
    const b = setup.b;
    const helper_body = switch (setup.exit) {
        .failure => c.failed,
        .instruction_fault => blk: {
            const divided = try b.value(.{
                .schema = setup.integer,
                .expression = .{ .primitive = .{
                    .opcode = .integer_div,
                    .operands = &.{ try b.constant(u64, 1), try b.constant(u64, 0) },
                    .failures = &.{
                        .{
                            .kind = .arithmetic_overflow,
                            .value = try b.failureLiteral(setup.fault),
                        },
                        .{
                            .kind = .division_by_zero,
                            .value = try b.failureLiteral(setup.fault),
                        },
                    },
                } },
            });
            break :blk try b.bind(try b.variable(setup.integer), try b.pure(divided), c.failed);
        },
        .cancellation => try b.term(.{ .yield_then = try b.term(.{ .call = .{
            .function = c.helper,
            .arguments = &.{try b.reference(b.parameter(c.helper, 0))},
        } }) }),
    };
    try b.define(c.helper, if (setup.owned_return)
        try b.bind(try b.variable(setup.unit), try b.term(.{
            .dispose = try b.reference(b.parameter(c.helper, 0)),
        }), try b.pure(setup.fault))
    else
        helper_body);
}

fn disposalHandlerModule(c: anytype) !h.source.Module {
    const setup = c.c;
    const b = setup.b;
    const work_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = setup.unit,
        .effects = &.{setup.t},
        .capture_bound = &.{setup.cap_t},
    } } });
    const clean_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{c.info},
        .result = setup.unit,
        .effects = &.{setup.e},
        .capture_bound = &.{setup.cap_e},
    } } });
    try b.define(c.inner, try b.term(.{ .protect = .{
        .body = try b.lambda(c.work, work_type),
        .cleanup = try b.lambda(c.clean, clean_type),
    } }));
    const handler_t = try b.handler(
        .{
            .mode = setup.token_mode,
            .input = setup.unit,
            .answer = setup.token_t,
            .return_function = c.ret_t,
            .clauses = &.{.{
                .effect = setup.t,
                .function = c.clause_t,
                .resumption = setup.token_t,
            }},
        },
    );
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{setup.cap_t},
        .result = setup.unit,
        .effects = setup.token_effects,
        .capture_bound = &.{setup.cap_e},
    } } });
    return try disposalOuterModule(.{ .c = c, .handler_t = handler_t, .inner_type = inner_type });
}

fn defineProtectedTokenReturn(c: anytype) !void {
    const setup = c.c;
    const b = setup.b;
    if (setup.invocation == .deep_owned_protected) {
        const body = try b.declare(&.{setup.token_t}, setup.token_t, &.{}, &.{});
        try b.define(body, try b.pure(try b.reference(b.parameter(body, 0))));
        const cleanup = try b.declare(&.{c.info}, setup.unit, &.{}, &.{});
        try b.define(cleanup, try b.pure(setup.fault));
        const body_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{setup.token_t},
            .result = setup.token_t,
            .effects = &.{},
            .capture_bound = &.{},
        } } });
        const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{c.info},
            .result = setup.unit,
            .effects = &.{},
            .capture_bound = &.{},
        } } });
        try b.define(
            c.clause_t,
            try b.term(
                .{
                    .protect = .{
                        .body = try b.lambda(body, body_type),
                        .arguments = &.{try b.reference(b.parameter(c.clause_t, 1))},
                        .cleanup = try b.lambda(cleanup, cleanup_type),
                    },
                },
            ),
        );
    } else try b.define(c.clause_t, try b.pure(try b.reference(b.parameter(c.clause_t, 1))));
}

fn disposalOuterModule(c: anytype) !h.source.Module {
    const setup = c.c.c;
    const functions = c.c;
    const b = setup.b;
    const token = try b.variable(setup.token_t);
    const seed = try b.variable(setup.integer);
    const ignored = try b.variable(if (setup.nested_token) setup.integer else setup.unit);
    const call = try invocationCall(.{
        .b = b,
        .invocation = setup.invocation,
        .helper = functions.helper,
        .token = token,
        .token_t = setup.token_t,
        .unit = setup.unit,
        .declared_effect = setup.declared_effect,
        .e = setup.e,
        .integer = setup.integer,
        .u = setup.u,
        .nested_token_u = setup.nested_token_u,
        .nested_token = setup.nested_token,
        .fault = setup.fault,
        .token_v = setup.token_v,
        .allow_seed = setup.allow_seed,
        .failed = functions.failed,
        .cap_e = setup.cap_e,
    });
    const yield = try b.term(.{ .yield_then = call });
    const tail = try b.bind(ignored, yield, try b.pure(
        if (setup.nested_token)
            try b.reference(ignored)
        else if (setup.invocation == .injected_inner or setup.invocation == .injected_bound)
            try b.constant(u64, 42)
        else
            try b.reference(seed),
    ));
    const handled = try b.term(.{ .handle = .{
        .handler = c.handler_t,
        .body = try b.lambda(functions.inner, c.inner_type),
    } });
    try b.define(functions.outer, try b.bind(token, handled, try b.bind(
        seed,
        try b.pure(try b.constant(u64, 42)),
        tail,
    )));
    return try installDisposalOuterHandler(.{ .c = c });
}

fn installDisposalOuterHandler(c: anytype) !h.source.Module {
    const setup = c.c.c.c;
    const functions = c.c.c;
    const b = setup.b;
    const handler_e = try b.handler(
        .{
            .mode = .deep,
            .input = setup.integer,
            .answer = setup.integer,
            .effects = setup.residual_effects,
            .return_function = functions.ret_e,
            .clauses = &.{.{
                .effect = setup.e,
                .function = functions.clause_e,
                .resumption = setup.token_e,
            }},
        },
    );
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{setup.cap_e},
        .result = setup.integer,
        .effects = setup.outer_effects,
    } } });
    try b.define(functions.main, try b.term(.{ .handle = .{
        .handler = handler_e,
        .body = try b.lambda(functions.outer, outer_type),
    } }));
    return b.module(functions.main, setup.unit);
}

fn expectOwnedReturnCompletion(c: anytype) !void {
    var uninterrupted = try k.Resident.start(a, &c.prepared, &.{});
    defer release(&uninterrupted);
    var yielded = try uninterrupted.publish(
        .{ .record = a },
        .none,
        .{ .checkpoint = .receipt },
    );
    defer yielded.deinit();
    try std.testing.expect(yielded.outcome.record.record == .yielded);
    var terminal = try uninterrupted.publish(
        .{ .record = a },
        .resume_yield,
        .{ .checkpoint = .receipt },
    );
    defer terminal.deinit();
    try std.testing.expectEqualSlices(
        u8,
        c.publication.checkpoint.?.bytes(),
        terminal.checkpoint.?.bytes(),
    );
}

fn expectOwnedReturnCancellation(c: anytype) !void {
    var cancelled = try k.Resident.restore(a, &c.prepared, c.publication.checkpoint.?.bytes());
    defer release(&cancelled);
    var cancel_control: h.data.invocation.Control = .{ .cancel = .{ .text = "stop" } };
    var cancellation_done = false;
    for (0..1000) |_| {
        var stopped = try cancelled.publish(.{ .record = a }, cancel_control, .{
            .quantum = 1,
            .checkpoint = .receipt,
        });
        defer stopped.deinit();
        const restored_stop = try k.Resident.restore(
            a,
            &c.prepared,
            stopped.checkpoint.?.bytes(),
        );
        release(&cancelled);
        cancelled = restored_stop;
        switch (stopped.outcome.record.record) {
            .cancelled => |done| {
                try std.testing.expectEqualStrings("stop", done.reason.text);
                cancellation_done = true;
                break;
            },
            .yielded => cancel_control = .resume_yield,
            .progressed => cancel_control = .none,
            else => return error.UnexpectedCancellationOutcome,
        }
    }
    try std.testing.expect(cancellation_done);
}

fn expectDisposalCase(c: anytype) !void {
    var diagnostic: h.source.Diagnostic = .{};
    errdefer std.debug.print(
        "implicit disposal {t}/{t}, declared={}, broad={}: {any}\n",
        .{ c.exit, c.invocation, c.declared_effect, c.allow_seed, diagnostic },
    );
    var builder = h.source.Builder.init(a);
    defer builder.deinit();
    const module = try fixture(
        &builder,
        c.allow_seed,
        c.exit,
        c.declared_effect,
        c.invocation,
    );
    if (!c.allow_seed) {
        var unexpected = h.program.compileObserved(a, module, .{
            .diagnostic = &diagnostic,
            .coalescing = .{ .work_limit = 0 },
        }) catch |err| {
            try std.testing.expectEqual(error.InvalidOwnership, err);
            return;
        };
        unexpected.deinit();
        return error.NarrowCaptureAccepted;
    }
    var compiled = try h.program.compileObserved(a, module, .{
        .diagnostic = &diagnostic,
        .coalescing = .{ .work_limit = 0 },
    });
    defer compiled.deinit();
    try expectDisposalExecution(.{ .compiled = compiled, .c = c });
}

fn expectDisposalExecution(c: anytype) !void {
    const bytes = try a.alloc(
        u8,
        try h.data.program_image.encodedLength(c.compiled.program),
    );
    defer a.free(bytes);
    _ = try c.compiled.encode(a, bytes);
    var prepared = try k.Prepared.init(a, bytes);
    defer prepared.deinit();
    var resident = try k.Resident.start(a, &prepared, &.{});
    defer release(&resident);
    var first = try resident.publish(
        .{ .record = a },
        .none,
        .{ .checkpoint = .receipt },
    );
    defer first.deinit();
    try std.testing.expect(first.outcome.record.record == .yielded);
    var entered = try resident.publish(.{ .record = a }, .resume_yield, .{
        .quantum = 1,
        .checkpoint = .receipt,
    });
    defer entered.deinit();
    var restored = try k.Resident.restore(
        a,
        &prepared,
        entered.checkpoint.?.bytes(),
    );
    defer release(&restored);
    try expectRestoredDisposalCleanup(.{ .c = c, .prepared = prepared, .restored = &restored });
}

fn expectRestoredDisposalCleanup(c: anytype) !void {
    const setup = c.c.c;
    const control: h.data.invocation.Control = if (setup.exit == .cancellation) .{
        .cancel = .{ .text = "stop" },
    } else .none;
    var cleanup = try c.restored.publish(
        .{ .record = a },
        control,
        .{ .checkpoint = .receipt },
    );
    defer cleanup.deinit();
    try std.testing.expect(cleanup.outcome.record.record == .yielded);
    var nonstop = try c.restored.publish(
        .{ .record = a },
        .resume_yield,
        .{ .checkpoint = .receipt },
    );
    defer nonstop.deinit();
    var resumed = try k.Resident.restore(
        a,
        &c.prepared,
        cleanup.checkpoint.?.bytes(),
    );
    defer release(&resumed);
    var terminal = try resumed.publish(
        .{ .record = a },
        .resume_yield,
        .{ .checkpoint = .receipt },
    );
    defer terminal.deinit();
    try std.testing.expectEqualSlices(
        u8,
        nonstop.checkpoint.?.bytes(),
        terminal.checkpoint.?.bytes(),
    );
    if (setup.invocation == .dispose) {
        try std.testing.expect(terminal.outcome.record.record == .completed);
        try std.testing.expectEqualSlices(
            u8,
            &.{ 42, 0, 0, 0, 0, 0, 0, 0 },
            terminal.outcome.record.record.completed,
        );
    } else if (setup.exit == .cancellation)
        try std.testing.expect(terminal.outcome.record.record == .cancelled)
    else
        try std.testing.expect(terminal.outcome.record.record == .failed);
}

fn disposalEffects(c: anytype) !struct { e: u64, t: u64, u: u64 } {
    const e = try c.b.effect(.{
        .identity = "probe/outer",
        .payload = c.unit,
        .result = c.unit,
        .external = false,
    });
    const t = if (c.deep) e else try c.b.effect(.{
        .identity = "probe/token",
        .payload = c.unit,
        .result = c.unit,
        .external = false,
    });
    const u = if (c.injection or c.nested_token) try c.b.effect(.{
        .identity = "probe/injection",
        .payload = c.unit,
        .result = c.unit,
        .external = false,
    }) else t;
    return .{ .e = e, .t = t, .u = u };
}

fn disposalSchemaModule(c: anytype) !h.source.Module {
    const token_e = try disposalTokenSchemas(.{
        .b = c.b,
        .nested_disposal = c.nested_disposal,
        .allow_seed = c.allow_seed,
        .unit = c.unit,
        .cap_e = c.cap_e,
        .cap_t = c.cap_t,
        .token_t = c.token_t,
        .token_v = c.token_v,
        .nested_token_u = c.nested_token_u,
        .integer = c.integer,
        .e = c.e,
        .residual_effects = c.residual_effects,
        .t = c.t,
        .deep = c.deep,
        .token_effects = c.token_effects,
        .token_mode = c.token_mode,
    });
    return try disposalFunctions(.{
        .b = c.b,
        .unit = c.unit,
        .integer = c.integer,
        .residual_effects = c.residual_effects,
        .cap_e = c.cap_e,
        .outer_effects = c.outer_effects,
        .token_e = token_e,
        .cap_t = c.cap_t,
        .token_effects = c.token_effects,
        .token_t = c.token_t,
        .t = c.t,
        .e = c.e,
        .declared_effect = c.declared_effect,
        .fault = c.fault,
        .invocation = c.invocation,
        .exit = c.exit,
        .owned_return = c.owned_return,
        .token_mode = c.token_mode,
        .nested_token = c.nested_token,
        .u = c.u,
        .nested_token_u = c.nested_token_u,
        .token_v = c.token_v,
        .allow_seed = c.allow_seed,
    });
}
