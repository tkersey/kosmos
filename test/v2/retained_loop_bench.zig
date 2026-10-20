const horos = @import("horos");
const source = horos.source;

pub fn build(b: *source.Builder, count: usize) !source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const operation = try b.effect(.{
        .identity = "benchmark/retained-loop",
        .payload = unit,
        .result = unit,
        .control_use = .multi,
        .external = false,
    });
    const cap = try b.schema(.{ .internal = .{ .capability = operation } });
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = operation,
        .input = unit,
        .answer = integer,
        .capture_bound = &.{ cap, integer, boolean },
        .handled = &.{operation},
        .mode = .deep,
        .use = .multi,
    } } });
    const main = try b.declare(&.{}, integer, &.{}, &.{});
    const loop = try b.declare(&.{ cap, integer, integer, boolean }, integer, &.{operation}, &.{});
    const fault = try defineLoop(b, unit, integer, boolean, operation, loop);
    const handler = try defineHandler(b, unit, integer, operation, token, fault);
    const body = try b.declare(&.{cap}, integer, &.{operation}, &.{});
    try b.define(body, try b.term(.{ .call = .{ .function = loop, .arguments = &.{
        try b.reference(b.parameter(
            body,
            0,
        )),
        try b.constant(u64, 1),
        try b.constant(u64, count),
        try b.constant(bool, true),
    } } }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = integer,
        .effects = &.{operation},
    } } });
    try b.define(main, try b.term(.{ .handle = .{
        .handler = handler,
        .body = try b.lambda(body, body_type),
    } }));
    return b.module(main, unit);
}

const Id = horos.data.program.Id;

fn defineLoop(
    b: *source.Builder,
    unit: Id,
    integer: Id,
    boolean: Id,
    operation: Id,
    loop: Id,
) !Id {
    const capability = try b.reference(b.parameter(loop, 0));
    const x = try b.reference(b.parameter(loop, 1));
    const remaining = try b.reference(b.parameter(loop, 2));
    const first = try b.reference(b.parameter(loop, 3));
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const increment = try b.value(.{
        .schema = integer,
        .expression = .{ .primitive = .{
            .opcode = .integer_add,
            .operands = &.{ x, try b.constant(u64, 1) },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }},
        } },
    });
    const decrement = try b.value(.{
        .schema = integer,
        .expression = .{ .primitive = .{
            .opcode = .integer_sub,
            .operands = &.{ remaining, try b.constant(u64, 1) },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }},
        } },
    });
    const next = try b.term(.{ .call = .{ .function = loop, .arguments = &.{
        capability, increment, decrement, try b.constant(bool, false),
    } } });
    const capture = try b.term(.{ .perform = .{
        .effect = operation,
        .capability = capability,
        .payload = try b.constant(void, {}),
    } });
    const work = try b.term(.{ .conditional = .{ .condition = first, .when_true = try b.bind(
        try b.variable(unit),
        capture,
        next,
    ), .when_false = next } });
    try b.define(loop, try b.term(.{ .conditional = .{
        .condition = try b.primitive(boolean, .equal, &.{ remaining, try b.constant(u64, 0) }, 0),
        .when_true = try b.pure(x),
        .when_false = work,
    } }));
    return fault;
}

fn defineHandler(
    b: *source.Builder,
    unit: Id,
    integer: Id,
    operation: Id,
    token: Id,
    fault: Id,
) !Id {
    const returns = try b.declare(&.{integer}, integer, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    const clause = try b.declare(&.{ unit, token }, integer, &.{}, &.{});
    const k = try b.reference(b.parameter(clause, 1));
    const a = try b.variable(integer);
    const c = try b.variable(integer);
    const resume_once = try b.term(.{ .resume_value = .{
        .resumption = k,
        .argument = try b.constant(void, {}),
    } });
    const sum = try b.value(
        .{
            .schema = integer,
            .expression = .{
                .primitive = .{
                    .opcode = .integer_add,
                    .operands = &.{ try b.reference(a), try b.reference(c) },
                    .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }},
                },
            },
        },
    );
    try b.define(clause, try b.bind(a, resume_once, try b.bind(c, resume_once, try b.pure(sum))));
    return b.handler(
        .{
            .mode = .deep,
            .input = integer,
            .answer = integer,
            .return_function = returns,
            .clauses = &.{.{
                .effect = operation,
                .function = clause,
                .resumption = token,
            }},
        },
    );
}
