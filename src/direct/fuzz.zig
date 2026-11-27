const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const Author = @import("../semantic/author.zig").Author;
const source = horos.source;
const Id = data.program.Id;

pub const Program = struct {
    image: []u8,
    arguments: []u8,

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        allocator.free(self.image);
        allocator.free(self.arguments);
        self.* = undefined;
    }
};

const Kind = enum {
    arith,
    choose,
    call,
    loop,
    request,
    yield,
    ask,
    multi,
    abort,
    protect,
    unpack,
    hold,
    fail,
};
const weights = [_]u8{ 14, 6, 6, 4, 6, 4, 4, 2, 2, 4, 4, 6, 1 };
const helpers_max = 3;
const statements_max = 10;

const Shapes = struct {
    capability: Id,
    choice_capability: Id,
    linear: Id,
    multi: Id,
    body: Id,
    choice: Id,
    held: Id,
    protected: Id,
    cleanup: Id,
    exit_info: Id,
};

const Effects = struct { request: Id, finalize: Id, ask: Id, choose: Id };

const Handlers = struct { resume_once: Id, abort: Id, multi: Id };

const Generator = struct {
    b: *source.Builder,
    e: Author,
    random: std.Random,
    effects: Effects,
    shapes: Shapes,
    handlers: Handlers = undefined,
    ordinary: []const Id,
    pair: Id = undefined,
    loop: Id = undefined,
    helpers: [helpers_max]Id = undefined,
    helper_count: usize = 0,
    protected_body: Id = undefined,
    alternate_body: Id = undefined,
    cleanup: Id = undefined,
    body: Id = undefined,
    choice_body: Id = undefined,

    fn integerLiteral(self: *Generator) source.Error!Id {
        const interesting = [_]u64{ 0, 1, 2, 7, 255, 1 << 32, std.math.maxInt(u64) };
        const value = if (self.random.boolean())
            interesting[self.random.uintLessThan(usize, interesting.len)]
        else
            self.random.int(u64);
        return self.b.constant(u64, value);
    }

    fn pick(self: *Generator, variables: []const Id) source.Error!Id {
        if (variables.len == 0 or self.random.uintLessThan(u8, 8) == 0)
            return self.integerLiteral();
        return self.b.reference(variables[self.random.uintLessThan(usize, variables.len)]);
    }

    fn kind(self: *Generator) Kind {
        var total: usize = 0;
        for (weights) |weight| total += weight;
        var choice = self.random.uintLessThan(usize, total);
        for (weights, 0..) |weight, index| {
            if (choice < weight) return @fromBackingInt(@intCast(index));
            choice -= weight;
        }
        return .arith;
    }

    fn arith(self: *Generator, variables: []const Id) source.Error!Id {
        const operations = [_]data.program.Opcode{
            .integer_bit_xor, .integer_bit_and, .integer_bit_or, .integer_bit_xor,
            .integer_bit_and, .integer_add,     .integer_bit_or, .integer_bit_xor,
            .integer_sub,     .integer_mul,     .integer_div,    .integer_rem,
        };
        const operation = operations[self.random.uintLessThan(usize, operations.len)];
        const left = try self.pick(variables);
        return self.e.binary(operation, left, try self.pick(variables));
    }

    fn statement(self: *Generator, selected: Kind, variables: []const Id) source.Error!Id {
        const b = self.b;
        return switch (selected) {
            .arith => b.pure(try self.arith(variables)),
            .choose => self.e.when(
                try self.e.binary(.less, try self.pick(variables), try self.pick(variables)),
                try b.pure(try self.pick(variables)),
                try b.pure(try self.arith(variables)),
            ),
            .call => if (self.helper_count == 0)
                b.pure(try self.arith(variables))
            else
                self.e.call(self.helpers[self.random.uintLessThan(usize, self.helper_count)], &.{
                    try self.pick(variables), try self.pick(variables),
                }),
            .loop => self.e.call(self.loop, &.{
                try self.e.binary(
                    .integer_bit_and,
                    try self.pick(variables),
                    try b.constant(u64, 7),
                ),
                try self.pick(variables),
            }),
            .request => b.term(.{ .perform = .{
                .effect = self.effects.request,
                .payload = try self.pick(variables),
            } }),
            .yield => b.term(.{ .yield_then = try b.pure(try self.pick(variables)) }),
            .ask, .abort => b.term(.{ .handle = .{
                .handler = if (selected == .ask) self.handlers.resume_once else self.handlers.abort,
                .body = try b.lambda(self.body, self.shapes.body),
                .arguments = &.{try self.pick(variables)},
            } }),
            .multi => b.term(.{ .handle = .{
                .handler = self.handlers.multi,
                .body = try b.lambda(self.choice_body, self.shapes.choice),
                .arguments = &.{try self.pick(variables)},
            } }),
            .protect => b.term(.{ .protect = .{
                .body = try b.lambda(self.protected_body, self.shapes.protected),
                .cleanup = try b.lambda(self.cleanup, self.shapes.cleanup),
                .arguments = &.{try self.pick(variables)},
            } }),
            .unpack => self.unpack(variables),
            .hold => self.hold(variables),
            .fail => self.e.fail(),
        };
    }

    fn hold(self: *Generator, variables: []const Id) source.Error!Id {
        const b = self.b;
        const e = self.e;
        const first = try b.variable(self.shapes.held);
        const second = try b.variable(self.shapes.held);
        const reply = try b.variable(e.integer);
        const middle = try b.variable(e.integer);
        const applied = try b.bind(middle, try b.term(.{ .apply = .{
            .computation = try b.reference(first),
            .arguments = &.{try b.reference(reply)},
        } }), try b.term(.{ .apply = .{
            .computation = try b.reference(second),
            .arguments = &.{try b.reference(middle)},
        } }));
        const asked = try b.bind(reply, try b.term(.{ .perform = .{
            .effect = self.effects.request,
            .payload = try self.pick(variables),
        } }), applied);
        const held = self.shapes.held;
        return b.bind(first, try b.pure(try b.lambda(self.protected_body, held)), try b.bind(
            second,
            try b.pure(try b.lambda(self.alternate_body, held)),
            asked,
        ));
    }

    fn unpack(self: *Generator, variables: []const Id) source.Error!Id {
        const b = self.b;
        const e = self.e;
        const first = try b.variable(e.integer);
        const second = try b.variable(e.integer);
        const left = try self.pick(variables);
        const value = try e.tuple(self.pair, &.{ left, try self.pick(variables) });
        const mask = try b.constant(u64, 0xff00);
        const masked = try e.binary(.integer_bit_and, try b.reference(first), mask);
        return b.term(.{ .unpack_product = .{
            .value = value,
            .variables = &.{ first, second },
            .body = try b.pure(try e.binary(.integer_bit_xor, masked, try b.reference(second))),
        } });
    }

    fn sequence(self: *Generator, parameters: []const Id, count: usize) source.Error!Id {
        const b = self.b;
        var variables: [2 + statements_max]Id = undefined;
        @memcpy(variables[0..parameters.len], parameters);
        var terms: [statements_max]Id = undefined;
        for (0..count) |index| {
            const available = variables[0 .. parameters.len + index];
            terms[index] = try self.statement(self.kind(), available);
            variables[parameters.len + index] = try b.variable(self.e.integer);
        }
        var next = try b.pure(try self.pick(variables[0 .. parameters.len + count]));
        var index = count;
        while (index > 0) {
            index -= 1;
            next = try b.bind(variables[parameters.len + index], terms[index], next);
        }
        return next;
    }

    fn function(self: *Generator) source.Error!Id {
        const integer = self.e.integer;
        const declared = try self.b.declare(&.{ integer, integer }, integer, self.ordinary, &.{});
        const parameters = [_]Id{ self.b.parameter(declared, 0), self.b.parameter(declared, 1) };
        const count = 1 + self.random.uintLessThan(usize, statements_max);
        try self.b.define(declared, try self.sequence(&parameters, count));
        return declared;
    }
};

pub fn generate(allocator: std.mem.Allocator, seed: u64) !Program {
    var prng = std.Random.DefaultPrng.init(seed);
    var b = source.Builder.init(allocator);
    defer b.deinit();
    const e = try Author.init(&b);
    const effects = try declareEffects(&b, e);
    const ordinary = [_]Id{ effects.request, effects.finalize };
    var generator: Generator = .{
        .b = &b,
        .e = e,
        .random = prng.random(),
        .effects = effects,
        .shapes = try declareShapes(&b, e, effects),
        .ordinary = &ordinary,
    };
    generator.pair = try b.schema(.{ .product = &.{ e.integer, e.integer } });
    try defineFixed(&generator);
    const helpers = prng.random().uintLessThan(usize, helpers_max + 1);
    for (0..helpers) |_| {
        const helper = try generator.function();
        generator.helpers[generator.helper_count] = helper;
        generator.helper_count += 1;
    }
    const entry = try generator.function();
    var compiled = try source.lower(allocator, b.module(entry, e.unit));
    defer compiled.deinit();
    const image = try allocator.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer allocator.free(image);
    _ = try compiled.encode(allocator, image);
    const arguments = try allocator.alloc(u8, 16);
    std.mem.writeInt(u64, arguments[0..8], prng.random().int(u64), .little);
    std.mem.writeInt(u64, arguments[8..16], prng.random().int(u64) % 1024, .little);
    return .{ .image = image, .arguments = arguments };
}

fn declareEffects(b: *source.Builder, e: Author) source.Error!Effects {
    return .{
        .request = try b.effect(.{
            .identity = "fuzz/request",
            .payload = e.integer,
            .result = e.integer,
        }),
        .finalize = try b.effect(.{
            .identity = "fuzz/finalize",
            .payload = e.integer,
            .result = e.unit,
        }),
        .ask = try b.effect(.{
            .identity = "fuzz/ask",
            .payload = e.integer,
            .result = e.integer,
            .external = false,
        }),
        .choose = try b.effect(.{
            .identity = "fuzz/choose",
            .payload = e.integer,
            .result = e.integer,
            .external = false,
            .control_use = .multi,
        }),
    };
}

fn declareShapes(b: *source.Builder, e: Author, effects: Effects) source.Error!Shapes {
    const external = [_]Id{ effects.request, effects.finalize };
    const exit_info = try source.library.cleanup.exitInfo(b, e.unit);
    const capability = try b.schema(.{ .internal = .{ .capability = effects.ask } });
    const choice_capability = try b.schema(.{ .internal = .{ .capability = effects.choose } });
    return .{
        .capability = capability,
        .choice_capability = choice_capability,
        .linear = try b.schema(.{ .internal = .{ .resumption = .{
            .effect = effects.ask,
            .input = e.integer,
            .answer = e.integer,
            .effects = &external,
            .handled = &.{effects.ask},
            .capture_bound = &.{e.integer},
            .mode = .deep,
            .use = .linear,
        } } }),
        .multi = try b.schema(.{ .internal = .{ .resumption = .{
            .effect = effects.choose,
            .input = e.integer,
            .answer = e.integer,
            .effects = &external,
            .handled = &.{effects.choose},
            .capture_bound = &.{e.integer},
            .mode = .deep,
            .use = .multi,
        } } }),
        .body = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{ capability, e.integer },
            .result = e.integer,
            .effects = &.{ effects.request, effects.finalize, effects.ask },
        } } }),
        .choice = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{ choice_capability, e.integer },
            .result = e.integer,
            .effects = &.{ effects.request, effects.finalize, effects.choose },
        } } }),
        .protected = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{e.integer},
            .result = e.integer,
            .effects = &external,
        } } }),
        .held = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{e.integer},
            .result = e.integer,
            .effects = &external,
            .use = .linear,
        } } }),
        .cleanup = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{exit_info},
            .result = e.unit,
            .effects = &external,
        } } }),
        .exit_info = exit_info,
    };
}

fn defineFixed(generator: *Generator) source.Error!void {
    try defineLoop(generator);
    try defineProtected(generator);
    try defineBodies(generator);
    try defineHandlers(generator);
}

fn defineLoop(generator: *Generator) source.Error!void {
    const b = generator.b;
    const e = generator.e;
    const loop = try b.declare(&.{ e.integer, e.integer }, e.integer, generator.ordinary, &.{});
    const count = try e.param(loop, 0);
    const step = try e.call(loop, &.{
        try e.binary(.integer_sub, count, e.one),
        try e.binary(.integer_bit_xor, try e.param(loop, 1), try e.param(loop, 0)),
    });
    try b.define(loop, try e.when(
        try e.binary(.equal, try e.param(loop, 0), e.zero),
        try b.pure(try e.param(loop, 1)),
        step,
    ));
    generator.loop = loop;
}

fn defineProtected(generator: *Generator) source.Error!void {
    const b = generator.b;
    const e = generator.e;
    const body = try b.declare(&.{e.integer}, e.integer, generator.ordinary, &.{});
    const reply = try b.variable(e.integer);
    try b.define(body, try b.bind(reply, try b.term(.{ .perform = .{
        .effect = generator.effects.request,
        .payload = try e.param(body, 0),
    } }), try b.pure(try e.binary(.integer_bit_xor, try b.reference(reply), e.one))));
    const cleanup = try b.declare(&.{generator.shapes.exit_info}, e.unit, generator.ordinary, &.{});
    try b.define(cleanup, try b.term(.{ .perform = .{
        .effect = generator.effects.finalize,
        .payload = try b.constant(u64, 3),
    } }));
    generator.protected_body = body;
    generator.cleanup = cleanup;
    const alternate = try b.declare(&.{e.integer}, e.integer, generator.ordinary, &.{});
    try b.define(alternate, try b.pure(try e.binary(
        .integer_bit_or,
        try e.param(alternate, 0),
        try b.constant(u64, 2),
    )));
    generator.alternate_body = alternate;
}

fn defineBodies(generator: *Generator) source.Error!void {
    const b = generator.b;
    const e = generator.e;
    inline for (.{ "body", "choice_body" }, .{ generator.effects.ask, generator.effects.choose }) |
        name,
        selected,
    | {
        const capability = if (selected == generator.effects.ask)
            generator.shapes.capability
        else
            generator.shapes.choice_capability;
        const row = [_]Id{ generator.effects.request, generator.effects.finalize, selected };
        const function = try b.declare(&.{ capability, e.integer }, e.integer, &row, &.{});
        const first = try b.variable(e.integer);
        const asked = try b.term(.{ .perform = .{
            .effect = selected,
            .capability = try e.param(function, 0),
            .payload = try e.param(function, 1),
        } });
        try b.define(function, try b.bind(first, asked, try b.pure(try e.binary(
            .integer_bit_xor,
            try b.reference(first),
            try e.param(function, 1),
        ))));
        @field(generator, name) = function;
    }
}

fn defineHandlers(generator: *Generator) source.Error!void {
    const b = generator.b;
    const e = generator.e;
    const returns = try b.declare(&.{e.integer}, e.integer, generator.ordinary, &.{});
    try b.define(returns, try b.pure(try e.binary(.integer_add, try e.param(returns, 0), e.one)));
    const linear = generator.shapes.linear;
    const once = try clause(generator, linear);
    try b.define(once, try b.term(.{ .resume_value = .{
        .resumption = try e.param(once, 1),
        .argument = try e.binary(.integer_bit_xor, try e.param(once, 0), try b.constant(u64, 5)),
    } }));
    const abort = try clause(generator, linear);
    const disposed = try b.variable(e.unit);
    try b.define(abort, try b.bind(
        disposed,
        try b.term(.{ .dispose = try e.param(abort, 1) }),
        try b.pure(try e.param(abort, 0)),
    ));
    const twice = try clause(generator, generator.shapes.multi);
    try defineTwice(generator, twice);
    const ask = generator.effects.ask;
    generator.handlers = .{
        .resume_once = try handler(generator, returns, ask, once, linear),
        .abort = try handler(generator, returns, ask, abort, linear),
        .multi = try handler(
            generator,
            returns,
            generator.effects.choose,
            twice,
            generator.shapes.multi,
        ),
    };
}

fn clause(generator: *Generator, resumption: Id) source.Error!Id {
    const integer = generator.e.integer;
    return generator.b.declare(&.{ integer, resumption }, integer, generator.ordinary, &.{});
}

fn defineTwice(generator: *Generator, twice: Id) source.Error!void {
    const b = generator.b;
    const e = generator.e;
    const left = try b.variable(e.integer);
    const right = try b.variable(e.integer);
    const second = try b.bind(right, try b.term(.{ .resume_value = .{
        .resumption = try e.param(twice, 1),
        .argument = try e.param(twice, 0),
    } }), try b.pure(try e.binary(
        .integer_bit_xor,
        try b.reference(left),
        try b.reference(right),
    )));
    try b.define(twice, try b.bind(left, try b.term(.{ .resume_value = .{
        .resumption = try e.param(twice, 1),
        .argument = e.one,
    } }), second));
}

fn handler(
    generator: *Generator,
    returns: Id,
    effect: Id,
    function: Id,
    resumption: Id,
) source.Error!Id {
    return generator.b.handler(.{
        .mode = .deep,
        .input = generator.e.integer,
        .answer = generator.e.integer,
        .return_function = returns,
        .clauses = &.{.{ .effect = effect, .function = function, .resumption = resumption }},
        .effects = generator.ordinary,
    });
}

const core = @import("../semantic/session.zig");
const Lockstep = @import("lockstep.zig").Lockstep;
const protocol = data.invocation;
const cuts_max = 4096;
const quanta = [_]?u64{ null, 0, 1, 1, 2, 3, 5, 17, 256 };

pub const Summary = struct {
    cuts: usize = 0,
    requests: usize = 0,
    rejections: usize = 0,
    completed: usize = 0,
    failed: usize = 0,
    cancelled: usize = 0,
};

const Driver = struct {
    allocator: std.mem.Allocator,
    prepared: *const core.Prepared,
    random: std.Random,
    execution: Lockstep,
    summary: Summary = .{},
    stepping: u8 = 0,

    fn chance(self: *Driver, denominator: u8) bool {
        return self.random.uintLessThan(u8, denominator) == 0;
    }

    fn restore(self: *Driver) !void {
        const saved = try self.execution.checkpoint(self.allocator);
        defer self.allocator.free(saved);
        var restored = try Lockstep.restore(self.allocator, self.prepared, saved);
        std.mem.swap(Lockstep, &self.execution, &restored);
        restored.deinit();
    }

    fn cancel(self: *Driver) !void {
        const reason: protocol.Reason = if (self.random.boolean())
            .{ .text = "fuzz" }
        else
            .{ .bytes = &.{ 0, 255, 7 } };
        try self.execution.cancel(reason);
        self.stepping = 4;
    }

    fn reply(self: *Driver) !void {
        var pending = try self.execution.pendingRequest(self.allocator);
        defer pending.deinit();
        const request = pending.request;
        const unit = std.mem.eql(u8, request.binding.semantic_identity, "fuzz/finalize");
        var value: [8]u8 = undefined;
        std.mem.writeInt(u64, &value, self.random.int(u64), .little);
        if (self.chance(12)) try self.rejected(request, if (unit) &value else value[0..3], true);
        if (self.chance(12)) try self.rejected(request, if (unit) &.{} else &value, false);
        const answer = try protocol.encodeOwned(protocol.Result, self.allocator, .{
            .request_identity = request.request_identity,
            .value = if (unit) &.{} else &value,
        });
        defer self.allocator.free(answer);
        try self.execution.answer(answer);
    }

    fn rejected(self: *Driver, request: protocol.Request, value: []const u8, bound: bool) !void {
        var identity = request.request_identity;
        if (!bound) identity[0] ^= 1;
        const answer = try protocol.encodeOwned(protocol.Result, self.allocator, .{
            .request_identity = identity,
            .value = value,
        });
        defer self.allocator.free(answer);
        if (self.execution.answer(answer)) |_| return error.AcceptedInvalidReply else |err| {
            if (err == error.RealizationDiverged) return err;
        }
        self.summary.rejections += 1;
    }

    fn advance(self: *Driver) !bool {
        const quantum: ?u64 = if (self.stepping != 0) 1 else quanta[
            self.random.uintLessThan(usize, quanta.len)
        ];
        self.stepping -|= 1;
        self.summary.cuts += 1;
        const observation = self.execution.run(quantum) catch |err| switch (err) {
            error.RealizationDiverged, error.OutOfMemory => return err,
            else => {
                self.summary.rejections += 1;
                return true;
            },
        };
        switch (observation) {
            .progressed => if (self.chance(48)) try self.cancel(),
            .yielded => if (self.chance(8)) try self.cancel() else try self.execution.resumeYield(),
            .requested => {
                self.summary.requests += 1;
                if (self.chance(8)) try self.cancel() else try self.reply();
            },
            .completed => {
                self.summary.completed += 1;
                return false;
            },
            .failed => {
                self.summary.failed += 1;
                return false;
            },
            .cancelled => {
                self.summary.cancelled += 1;
                return false;
            },
        }
        if (self.chance(4)) try self.restore();
        return true;
    }
};

pub fn drive(
    allocator: std.mem.Allocator,
    prepared: *const core.Prepared,
    arguments: []const u8,
    seed: u64,
) !Summary {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x9e3779b97f4a7c15);
    var driver: Driver = .{
        .allocator = allocator,
        .prepared = prepared,
        .random = prng.random(),
        .execution = try Lockstep.start(allocator, prepared, arguments),
    };
    defer driver.execution.deinit();
    for (0..cuts_max) |_| if (!try driver.advance()) return driver.summary;
    return error.UnboundedFuzzProgram;
}
