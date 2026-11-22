const std = @import("std");
const horos = @import("horos_recovery");
const source = horos.source;
const base = @import("base/session.zig");
const bench = @import("semantic_benchmark.zig");
const StoreStatistics = @import("interpreter_v2/store.zig").Statistics;

fn diamond(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const f = try b.declare(&.{ boolean, pair, word, word }, word, &.{}, &.{});
    const condition = try b.reference(b.parameter(f, 0));
    const aggregate = try b.reference(b.parameter(f, 1));
    const left = try b.reference(b.parameter(f, 2));
    const right = try b.reference(b.parameter(f, 3));
    const first = try b.variable(word);
    const first_value = try b.reference(first);
    const selected = try b.variable(word);
    const when_true = try b.primitive(word, .integer_bit_and, &.{ first_value, left }, 0);
    const when_false = try b.primitive(word, .integer_bit_or, &.{ first_value, right }, 0);
    const branch = try b.term(.{ .conditional = .{
        .condition = condition,
        .when_true = try b.pure(when_true),
        .when_false = try b.pure(when_false),
    } });
    const later = try b.primitive(word, .field, &.{aggregate}, 1);
    const merged = try b.reference(selected);
    const result = try b.primitive(word, .integer_bit_xor, &.{ merged, later }, 0);
    const early = try b.primitive(word, .field, &.{aggregate}, 1);
    try b.define(f, try b.bind(first, try b.pure(early), try b.bind(
        selected,
        branch,
        try b.pure(result),
    )));
    return b.module(f, unit);
}

const Observation = struct { value: u64, fields: u64, moves: u64, transitions: usize };

fn execute(a: std.mem.Allocator, program: horos.data.activation.Program, flag: bool) !Observation {
    const iri = horos.data.program_image;
    const image = try a.alloc(u8, try iri.encodedLength(program));
    defer a.free(image);
    _ = try iri.encode(a, program, image);
    var input: [33]u8 = undefined;
    input[0] = @intFromBool(flag);
    for ([_]u64{ 0x1155, 0xabc5, 0xcf, 0x7810 }, 0..) |n, i| {
        std.mem.writeInt(u64, input[1 + 8 * i ..][0..8], n, .little);
    }
    var session = try base.Session.initImage(a, image, &input, .{});
    defer session.deinit();
    var stats: StoreStatistics = .{};
    session.store.statistics = &stats;
    const event = try session.run(null);
    if (event != .completed) return error.DiamondDidNotReturn;
    const bytes = try session.bytes(&event.completed);
    if (bytes.len != 8) return error.DiamondResultChanged;
    return .{
        .value = std.mem.readInt(u64, bytes[0..8], .little),
        .fields = stats.base_field_evaluations,
        .moves = stats.base_move_slot_reads,
        .transitions = session.transitions,
    };
}

pub fn measure(a: std.mem.Allocator, out: *std.Io.Writer) !void {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const module = try diamond(&builder);
    const options: source.recovery_optimization.Options = .{
        .rule = .scalar_field_reuse_v1,
        .limits = .{},
        .formals = &.{.{ .function = module.entry, .ordinal = 0 }},
    };
    var baseline = try source.lowerObserved(a, module, .{ .recovery = true });
    defer baseline.deinit();
    var selected = try source.lowerRecoveryOptimized(a, module, options);
    defer selected.deinit();
    if (selected.outcome != .applied or selected.evidence.witnesses.len != 1)
        return error.NoDiamondReplacement;
    const checked = try source.recovery_optimization.parameters(
        a,
        module,
        selected.program,
        selected.evidence,
        options,
    );
    defer a.free(checked);
    for ([_]bool{ false, true }) |flag| {
        const before = try execute(a, baseline.program, flag);
        const after = try execute(a, selected.program, flag);
        const expected: u64 = if (flag) 43776 else 20496;
        if (before.value != expected or after.value != expected or before.fields != 2 or
            after.fields != 1 or after.moves != before.moves + 1) return error.DiamondChanged;
        try bench.emit(out, .{
            .phase = "recovery-base-diamond",
            .condition = flag,
            .structural = before,
            .optimized = after,
            .original_witness = selected.evidence.witnesses[0],
        });
    }
}
