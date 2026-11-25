const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const Author = @import("semantic/author.zig").Author;
const protocol = data.invocation;
pub const Workload = enum {
    scalar,
    scalar_chain,
    scalar_chain_large,
    dynamic_loop,
    structured,
    repeated_calls,
    higher_order,
    handlers,
    multi_shot,
    long_cleanup,
    retained_bytes,
};
pub fn image(a: std.mem.Allocator, kind: Workload) ![]u8 {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const module = switch (kind) {
        .higher_order => try horos.source.examples.lexical(&b),
        .handlers => try horos.source.examples.installations(&b, 12),
        .multi_shot => try horos.source.examples.localContinuation(&b, true),
        .retained_bytes => try horos.source.examples.blobCapture(&b),
        .scalar => try scalarModule(e),
        .scalar_chain, .scalar_chain_large => try scalarChainModule(e, kind),
        .structured => try structuredModule(e),
        .dynamic_loop, .repeated_calls => try loopModule(e, kind),
        .long_cleanup => try cleanupModule(e),
    };
    var compiled = try horos.source.lower(a, module);
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    return bytes;
}
pub fn integerBytes(value: u64) [8]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return bytes;
}
pub fn arguments(a: std.mem.Allocator, kind: Workload, sample: usize) ![]u8 {
    const seed: u64 = 41 + @as(u64, @intCast(sample)) * 19;
    return switch (kind) {
        .scalar, .scalar_chain, .scalar_chain_large, .higher_order => a.dupe(
            u8,
            &integerBytes(seed),
        ),
        .dynamic_loop, .repeated_calls => a.dupe(
            u8,
            &(integerBytes(16 + sample * 16) ++ integerBytes(seed)),
        ),
        .structured => a.dupe(u8, &(integerBytes(seed) ++ integerBytes(seed + 9))),
        .long_cleanup => a.dupe(u8, &integerBytes(8 + sample * 8)),
        .retained_bytes => blk: {
            const length = @as(usize, 1024) << @intCast(sample * 3);
            var size: data.wire.Writer = .{};
            try size.natural(length);
            const bytes = try a.alloc(u8, size.position + length);
            var w: data.wire.Writer = .{ .output = bytes };
            try w.natural(length);
            @memset(bytes[w.position..], @intCast(seed));
            break :blk bytes;
        },
        else => a.dupe(u8, &.{}),
    };
}
pub fn reply(a: std.mem.Allocator, request_bytes: []const u8, sample: usize) ![]u8 {
    var request = try protocol.decode(protocol.Request, a, request_bytes);
    defer request.deinit();
    const body: []const u8 = if (std.mem.eql(
        u8,
        request.value.binding.semantic_identity,
        "local/producer",
    )) &integerBytes(41 + sample * 19) else &.{};
    return protocol.encodeOwned(protocol.Result, a, .{
        .request_identity = request.value.request_identity,
        .value = body,
    });
}
fn scalarModule(e: Author) !horos.source.Module {
    const b = e.b;
    const entry = try b.declare(&.{e.integer}, e.integer, &.{}, &.{});
    try b.define(entry, try b.pure(try e.binary(
        .integer_bit_xor,
        try e.param(entry, 0),
        try b.constant(u64, 0x12345678),
    )));
    return b.module(entry, e.unit);
}
fn scalarChainModule(e: Author, kind: Workload) !horos.source.Module {
    const b = e.b;
    const entry = try b.declare(&.{e.integer}, e.integer, &.{}, &.{});
    var value = try e.param(entry, 0);
    for (0..@as(usize, if (kind == .scalar_chain_large) 96 else 24)) |i| {
        value = try e.binary(.integer_add, value, try b.constant(u64, 17 + i));
        value = try e.binary(.integer_bit_xor, value, try b.constant(u64, 0x12345678 + i));
    }
    try b.define(entry, try b.pure(value));
    return b.module(entry, e.unit);
}
fn structuredModule(e: Author) !horos.source.Module {
    const b = e.b;
    const pair = try b.schema(.{ .product = &.{ e.integer, e.integer } });
    const entry = try b.declare(&.{pair}, pair, &.{}, &.{});
    const value = try e.param(entry, 0);
    try b.define(entry, try b.pure(try e.tuple(pair, &.{ try e.binary(
        .integer_bit_xor,
        try e.field(value, 0),
        try e.field(value, 1),
    ), try e.field(value, 0) })));
    return b.module(entry, e.unit);
}
fn loopModule(e: Author, kind: Workload) !horos.source.Module {
    const b = e.b;
    const entry = try b.declare(&.{ e.integer, e.integer }, e.integer, &.{}, &.{});
    const loop = try b.declare(&.{ e.integer, e.integer }, e.integer, &.{}, &.{});
    const count = try e.param(loop, 0);
    const acc = try e.param(loop, 1);
    const step = try e.binary(.integer_bit_xor, acc, count);
    const next = try e.call(loop, &.{
        try e.binary(.integer_sub, count, e.one), if (kind == .dynamic_loop) step else acc,
    });
    const tail = if (kind == .dynamic_loop) next else blk2: {
        const value = try b.variable(e.integer);
        break :blk2 try b.bind(value, next, try b.pure(try e.binary(
            .integer_bit_xor,
            try b.reference(value),
            count,
        )));
    };
    try b.define(loop, try e.when(
        try e.binary(.equal, count, e.zero),
        try b.pure(acc),
        tail,
    ));
    try b.define(entry, try e.call(loop, &.{
        try e.param(entry, 0), try e.param(entry, 1),
    }));
    return b.module(entry, e.unit);
}
fn cleanupModule(e: Author) !horos.source.Module {
    const b = e.b;
    const releasing = try b.effect(.{
        .identity = "benchmark/cleanup",
        .payload = e.unit,
        .result = e.unit,
    });
    const exit_info = try horos.source.library.cleanup.exitInfo(b, e.unit);
    const recursive = try b.declare(&.{e.integer}, e.integer, &.{releasing}, &.{});
    const count = try e.param(recursive, 0);
    const body = try b.declare(&.{}, e.integer, &.{releasing}, &.{});
    try b.define(body, try e.call(recursive, &.{try e.binary(.integer_sub, count, e.one)}));
    const cleanup = try b.declare(&.{exit_info}, e.unit, &.{releasing}, &.{});
    try b.define(cleanup, try b.term(.{ .perform = .{
        .effect = releasing,
        .payload = try b.constant(void, {}),
    } }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = e.integer,
        .effects = &.{releasing},
        .capture_bound = &.{e.integer},
    } } });
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{exit_info},
        .result = e.unit,
        .effects = &.{releasing},
    } } });
    const protected = try b.term(.{ .protect = .{
        .body = try b.lambda(body, body_type),
        .cleanup = try b.lambda(cleanup, cleanup_type),
    } });
    try b.define(recursive, try e.when(
        try e.binary(.equal, count, e.zero),
        try b.pure(e.zero),
        protected,
    ));
    return b.module(recursive, e.unit);
}
