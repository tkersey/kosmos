//! The execution base is a checked subset of BPI3, not another bytecode.
//! This check constrains an already admitted image. It grants no execution or
//! environmental authority; the enclosing runtime owner binds approved bytes.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const ir = data.activation;

pub const identity = "kosmos.execution-base/1";
pub const Error = error{ UnsupportedBaseOperation, UnsupportedBaseSchema, UnsupportedBaseDeclaration, InvalidBridge, Capacity };

/// Exact declarations supplied by the selected core contract. Numeric schema
/// references belong to that exact admitted image, not a caller's substitute
/// schema catalog. Checking this contract is not production-runtime approval.
pub const Bridge = struct { effects: []const p.Effect = &.{} };

pub const Report = struct {
    opcodes: std.EnumSet(p.Opcode) = .empty,
    terminators: std.EnumSet(p.TerminatorTag) = .empty,
    schemas: std.EnumSet(p.SchemaTag) = .empty,
    instructions: usize = 0,
    blocks: usize = 0,
    functions: usize = 0,
};

pub fn check(admitted: *const data.program_image.Admitted, bridge: Bridge) Error!Report {
    return scan(admitted.program(), bridge);
}

// Exhaustive switches deliberately have no catch-all. A new language operation
// requires an explicit base disposition even if no current core emits it.
pub fn permitsOpcode(op: p.Opcode) bool {
    return switch (op) {
        .constant,
        .move,
        .integer_add,
        .integer_sub,
        .integer_mul,
        .integer_div,
        .equal,
        .less,
        .boolean_not,
        .product,
        .field,
        .variant,
        .variant_tag,
        .variant_payload,
        .sequence,
        .sequence_length,
        .sequence_get,
        .sequence_append,
        .sequence_concat,
        .sequence_pop,
        .integer_rem,
        .integer_bit_not,
        .integer_bit_and,
        .integer_bit_or,
        .integer_bit_xor,
        .integer_convert,
        .enum_tag,
        .blob_length,
        .blob_concat,
        .blob_slice,
        .blob_compare,
        .blob_byte,
        .text_scalar,
        .text_integer,
        .sequence_set,
        .sequence_take,
        .blob_from_byte,
        .sequence_pop_last,
        .select,
        => true,
        .computation,
        .cell_new,
        .cell_get,
        .cell_set,
        .clone_resumption,
        .package,
        .unpack,
        .resource_pack,
        .resource_unpack,
        => false,
    };
}

pub fn permitsTerminator(tag: p.TerminatorTag) bool {
    return switch (tag) {
        .return_value,
        .jump,
        .branch,
        .switch_variant,
        .unpack_product,
        .call,
        .perform,
        .yield_value,
        .fail,
        => true,
        .apply,
        .handle,
        .resume_value,
        .resume_with,
        .resume_computation,
        .dispose,
        .protect,
        .with_region,
        => false,
    };
}

pub fn permitsSchema(tag: p.SchemaTag) bool {
    return switch (tag) {
        .unit,
        .boolean,
        .i8,
        .i16,
        .i32,
        .i64,
        .u8,
        .u16,
        .u32,
        .u64,
        .bytes,
        .text,
        .product,
        .sum,
        .seq,
        .vector,
        .array,
        .bounded_bytes,
        .bounded_text,
        .enumeration,
        => true,
        .internal => false,
    };
}

fn plainBridgeEffect(effect: p.Effect) bool {
    return effect.external and effect.control_use == .linear and
        effect.bodies.len == 0 and effect.use_site_effects.len == 0;
}

fn scan(program: ir.Program, bridge: Bridge) Error!Report {
    var report: Report = .{ .blocks = program.blocks.len, .functions = program.functions.len };
    // Scan the complete catalogs, including unreachable declarations. Ordinary
    // Horos admission has already checked references and closed dependencies.
    for (program.schemas) |schema| {
        const tag = std.meta.activeTag(schema);
        if (!permitsSchema(tag)) return error.UnsupportedBaseSchema;
        report.schemas.insert(tag);
    }
    if (program.handlers.len != 0 or program.constructors.len != 0 or
        program.scopes.captures.len != 0 or program.scopes.resources.len != 0 or
        program.scopes.region_count != 0) return error.UnsupportedBaseDeclaration;
    for (program.functions) |function|
        if (function.regions.len != 0) return error.UnsupportedBaseDeclaration;
    if (program.effects.len != bridge.effects.len) return error.InvalidBridge;
    for (program.effects, bridge.effects) |actual, expected| {
        if (!plainBridgeEffect(actual) or !plainBridgeEffect(expected) or
            !std.mem.eql(u8, actual.identity, expected.identity) or
            actual.payload != expected.payload or actual.result != expected.result)
            return error.InvalidBridge;
    }
    for (program.blocks) |block| {
        report.instructions = std.math.add(usize, report.instructions, block.instructions.len) catch return error.Capacity;
        for (block.instructions) |instruction| {
            if (!permitsOpcode(instruction.opcode)) return error.UnsupportedBaseOperation;
            report.opcodes.insert(instruction.opcode);
        }
        const tag = std.meta.activeTag(block.terminator);
        if (!permitsTerminator(tag)) return error.UnsupportedBaseOperation;
        report.terminators.insert(tag);
        if (block.terminator == .perform) {
            const perform = block.terminator.perform;
            if (perform.capability != null or perform.bodies.len != 0 or
                perform.use_site_capabilities.len != 0) return error.InvalidBridge;
        }
    }
    return report;
}

const fixture: ir.Program = .{
    .roots = .{ .entry = 0, .result = 1, .failure = 0 },
    .schemas = &.{ .unit, .u64 },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{.{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{1} }, .result = 1 }},
    .blocks = &.{.{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } }},
};

fn admit(program: ir.Program) !*data.program_image.Admitted {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(program));
    defer a.free(bytes);
    return data.program_image.Admitted.decode(a, try data.program_image.encode(a, program, bytes));
}

test "base profile accepts admitted first-order data and reports actual operations" {
    const admitted = try admit(fixture);
    defer admitted.deinit();
    const report = try check(admitted, .{});
    try std.testing.expectEqual(@as(usize, 1), report.functions);
    try std.testing.expect(report.terminators.contains(.return_value));
    try std.testing.expect(report.schemas.contains(.u64));
    try std.testing.expect(!report.opcodes.contains(.clone_resumption));
}

test "base profile scans prohibited operations in every helper block" {
    // Inventory classification is independent of type admission. These mutations
    // exercise the scanner, not a claim that each synthetic operation is typed.
    inline for (std.meta.tags(p.Opcode)) |opcode| {
        var program = fixture;
        const instructions = [_]ir.Instruction{.{ .destination = 0, .opcode = opcode }};
        const blocks = [_]ir.Block{
            fixture.blocks[0],
            .{ .function = 0, .instructions = &instructions, .terminator = .{ .return_value = 0 } },
        };
        program.blocks = &blocks;
        if (permitsOpcode(opcode)) {
            const report = try scan(program, .{});
            try std.testing.expect(report.opcodes.contains(opcode));
        } else try std.testing.expectError(error.UnsupportedBaseOperation, scan(program, .{}));
    }
}

test "base profile rejects admitted unused internal declarations" {
    var program = fixture;
    program.schemas = &.{ .unit, .u64, .{ .internal = .{ .computation = .{ .parameters = &.{1}, .result = 1 } } } };
    const admitted = try admit(program);
    defer admitted.deinit();
    try std.testing.expectError(error.UnsupportedBaseSchema, check(admitted, .{}));
}

test "base profile distinguishes plain guest descriptors from executable schemas" {
    var program = fixture;
    program.schemas = &.{ .unit, .u64, .{ .enumeration = &.{ 0, 1, 2, 3, 4, 5, 6, 7 } }, .{ .seq = 2 } };
    const admitted = try admit(program);
    defer admitted.deinit();
    _ = try check(admitted, .{});
}

test "base bridge requires exact declared environmental linear effects" {
    var program = fixture;
    const effect: p.Effect = .{ .identity = "kosmos.test-bridge/1", .payload = 0, .result = 1 };
    program.effects = &.{effect};
    const admitted = try admit(program);
    defer admitted.deinit();
    try std.testing.expectError(error.InvalidBridge, check(admitted, .{}));
    _ = try check(admitted, .{ .effects = &.{effect} });
    var other = effect;
    other.identity = "forged";
    try std.testing.expectError(error.InvalidBridge, check(admitted, .{ .effects = &.{other} }));
    other = effect;
    other.result = 0;
    try std.testing.expectError(error.InvalidBridge, check(admitted, .{ .effects = &.{other} }));
    other = effect;
    other.control_use = .multi;
    try std.testing.expectError(error.InvalidBridge, check(admitted, .{ .effects = &.{other} }));
}
