const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const projection = @import("projection.zig");
const Author = @import("author.zig").Author;
const a = std.testing.allocator;
const support = @import("test_support.zig");

const ProjectionAdmissionFixture = struct {
    const base = @import("../base/session.zig");
    const Entry = ProjectionCacheFixture.Entry;
    const Kind = @import("projection_cache.zig").Kind;
    const schemas: []const data.program.Schema = &.{
        .unit,
        .u64,
        .bytes,
        .{ .product = &.{ 1, 1, 2 } },
        .{ .sum = &.{ 0, 3 } },
        .{ .seq = 1 },
        .{ .vector = .{ .element = 1, .maximum = 512 } },
        .{ .array = .{ .element = 1, .length = 512 } },
        .{ .seq = 2 },
    };

    fn prepare() !base.Prepared {
        var b = source.Builder.init(a);
        defer b.deinit();
        const e = try Author.init(&b);
        const m = try @import("machine.zig").define(&b);
        const entry = try b.declare(&.{
            m.program, m.state, m.cache.entries.entries,
        }, e.boolean, &.{}, &.{});
        const machine = try b.variable(m.schema);
        const cache = try b.variable(m.cache.schema);
        const checked = try e.replace(
            try b.reference(machine),
            @backingInt(@import("machine.zig").Field.cache),
            try b.reference(cache),
        );
        const validate = try @import("recovery.zig").storage(&b, m);
        const body = try b.bind(cache, try e.call(m.cache.entries.from_sequence, &.{
            try e.param(entry, 2),
        }), try e.call(validate, &.{checked}));
        try b.define(entry, try b.bind(machine, try e.call(m.hydrate, &.{
            try e.param(entry, 0), try e.param(entry, 1),
        }), body));
        return support.prepare(b.module(entry, e.unit));
    }

    fn check(core: *base.Prepared, bytes: []const u8, entry: Entry, expected: bool) !void {
        _ = try checkEntries(core, bytes, entry.value.schema, &.{entry}, expected);
    }

    fn checkEntries(
        core: *base.Prepared,
        bytes: []const u8,
        schema: u64,
        saved: []const Entry,
        expected: bool,
    ) !usize {
        const program: data.activation.Program = .{
            .roots = .{ .entry = 0, .result = schema, .failure = 0 },
            .schemas = schemas,
            .constants = &.{},
            .effects = &.{},
            .functions = &.{.{
                .entry = 0,
                .inputs = &.{0},
                .layout = .{ .slots = &.{schema} },
                .result = schema,
            }},
            .blocks = &.{.{
                .function = 0,
                .instructions = &.{},
                .terminator = .{ .return_value = 0 },
            }},
        };
        const image = try a.alloc(u8, try data.program_image.encodedLength(program));
        defer a.free(image);
        _ = try data.program_image.encode(a, program, image);
        const admitted = try data.program_image.Admitted.decode(a, image);
        defer admitted.deinit();
        const guest = try projection.programBytes(a, admitted);
        defer a.free(guest);
        const value: data.graph.Value = .{ .schema = schema, .body = .{ .blob = .{ .id = 0 } } };
        const state = try projection.encode(data.process_state.State, a, .{
            .program_identity = admitted.identity(),
            .status = .completed,
            .roots = .{ .exit = .{ .id = 0 } },
            .nodes = &.{.{ .record = .{ .exit = .{ .reason = .{ .normal = value } } } }},
            .blobs = &.{
                .{ .schema = schema, .bytes = bytes },
                .{ .schema = schema, .bytes = bytes },
            },
        });
        defer a.free(state);
        const entries = try projection.encode([]const Entry, a, saved);
        defer a.free(entries);
        const input = try std.mem.concat(a, u8, &.{ guest, state, entries });
        defer a.free(input);
        var session = try base.Session.start(a, core, input, .{});
        defer session.deinit();
        const outcome = try session.run(null);
        if (outcome == .failed) {
            try std.testing.expect(!expected);
            return session.transitions;
        }
        try std.testing.expect(outcome == .completed);
        var result = try projection.decode(bool, a, try session.bytes(&outcome.completed));
        defer result.deinit();
        try std.testing.expectEqual(expected, result.value);
        return session.transitions;
    }

    fn cacheEntry(schema: u64, kind: Kind, index: u64, child: u64, start: u64, end: u64) Entry {
        return .{ .slot = (index ^ @backingInt(kind)) & 255, .value = .{
            .blob = 0,
            .schema = schema,
            .index = index,
            .kind = @backingInt(kind),
            .range = .{ .schema = child, .start = start, .end = end },
        } };
    }
};

test "projection recovery binds every cache range to its source coordinate" {
    const F = ProjectionAdmissionFixture;
    var core = try F.prepare();
    defer core.deinit();
    const record = try projection.encode(struct { u64, u64, []const u8 }, a, .{
        17, 29, &@as([4096]u8, @splat(3)),
    });
    defer a.free(record);
    const variant = try std.mem.concat(a, u8, &.{ &.{1}, record });
    defer a.free(variant);
    var numbers: [512]u64 = @splat(23);
    numbers[0] = 7;
    numbers[1] = 11;
    const sequence = try projection.encode([]const u64, a, &numbers);
    defer a.free(sequence);
    const array = try projection.encode([512]u64, a, numbers);
    defer a.free(array);
    const entries = [_]F.Entry{
        F.cacheEntry(3, .field, 0, 1, 0, 8),
        F.cacheEntry(3, .field, 1, 1, 8, 16),
        F.cacheEntry(4, .payload, 0, 3, 1, variant.len),
        F.cacheEntry(5, .element, 0, 1, 2, 10),
        F.cacheEntry(6, .element, 1, 1, 10, 18),
        F.cacheEntry(7, .element, 511, 1, 4088, 4096),
    };
    const inputs = [_][]const u8{ record, record, variant, sequence, sequence, array };
    for (entries, inputs) |entry, input| {
        try F.check(&core, input, entry, true);
        var shifted = entry;
        shifted.value.range.start += 8;
        shifted.value.range.end += 8;
        try F.check(&core, input, shifted, false);
        var wrong_child = entry;
        wrong_child.value.range.schema = 0;
        try F.check(&core, input, wrong_child, false);
        var wrong_blob = entry;
        wrong_blob.value.blob = 256;
        try F.check(&core, input, wrong_blob, false);
        var wrong_slot = entry;
        wrong_slot.slot ^= 1;
        try F.check(&core, input, wrong_slot, false);
    }
    try F.check(&core, sequence, F.cacheEntry(5, .element, 512, 1, 4098, 4106), false);
    try F.check(&core, variant, F.cacheEntry(4, .payload, 1, 3, 1, variant.len), false);
}

test "projection validation reuses only verified variable-width prefixes" {
    const F = ProjectionAdmissionFixture;
    var core = try F.prepare();
    defer core.deinit();
    const payload: [64]u8 = @splat(37);
    var values: [512][]const u8 = undefined;
    var entries: [256]F.Entry = undefined;
    var offset: u64 = 2;
    for (&values, 0..) |*value, i| {
        value.* = payload[0 .. 16 + i % 32];
        const end = offset + 1 + value.len;
        if (i >= 256) entries[i - 256] = F.cacheEntry(8, .element, i, 2, offset, end);
        offset = end;
    }
    const encoded = try projection.encode([]const []const u8, a, &values);
    defer a.free(encoded);
    const transitions = try F.checkEntries(&core, encoded, 8, &entries, true);
    try std.testing.expect(transitions < 1_000_000);
    var sparse = [_]F.Entry{ entries[2], entries[0], entries[2], entries[0] };
    for (sparse[2..]) |*entry| {
        entry.value.blob = 1;
        entry.slot ^= 1;
    }
    _ = try F.checkEntries(&core, encoded, 8, &sparse, true);
    sparse[3].value.range.end = sparse[2].value.range.end;
    _ = try F.checkEntries(&core, encoded, 8, &sparse, false);
    entries[0].value.range = entries[1].value.range;
    _ = try F.checkEntries(&core, encoded, 8, &entries, false);
}

const ProjectionCacheFixture = struct {
    const Id = data.program.Id;
    const Entry = struct {
        slot: u64,
        value: struct {
            blob: u64,
            schema: u64,
            index: u64,
            kind: u64,
            range: @import("projection_cache.zig").Range,
        },
    };
    const Result = struct {
        values: [7][]const u8,
        allocations: [7]u64,
        warm: []const Entry,
        collected: []const Entry,
        hydrated: []const Entry,
        before: data.process_state.State,
        invisible: data.process_state.State,
        after: data.process_state.State,
        restored: data.process_state.State,
        valid: [3]bool,
    };

    e: Author,
    m: @import("machine.zig").Definition,
    v: @import("values.zig").Definition,
    read: Id,
    hit: Id,

    fn init(b: *source.Builder) !ProjectionCacheFixture {
        const e = try Author.init(b);
        const m = try @import("machine.zig").define(b);
        const v = try @import("values.zig").define(b, m);
        const c = try @import("collections.zig").define(b, m);
        const read = try b.declare(&.{ m.schema, v.value, e.integer }, v.result, &.{}, &.{});
        const hit = try b.declare(&.{ m.schema, v.value, e.integer }, v.result, &.{}, &.{});
        const view = try b.variable(c.schema);
        try b.define(read, try b.bind(view, try e.call(c.view, &.{
            try e.param(read, 0), try e.param(read, 1),
        }), try e.call(c.cached_item, &.{
            try e.param(read, 0),  try e.param(read, 1),
            try b.reference(view), try e.param(read, 2),
        })));
        try b.define(hit, try @import("projection_cache.zig").read(
            e,
            m,
            try e.param(hit, 0),
            try e.param(hit, 1),
            try e.param(hit, 2),
            .element,
            try e.fail(),
        ));
        return .{ .e = e, .m = m, .v = v, .read = read, .hit = hit };
    }

    fn build(f: ProjectionCacheFixture) !source.Module {
        const e = f.e;
        const b = e.b;
        const output = try projection.schema(Result, b);
        const main = try b.declare(&.{ f.m.program, f.m.state, f.v.value }, output, &.{}, &.{});
        const initial = try b.variable(f.m.schema);
        var reads: [7]Id = undefined;
        for (&reads) |*read| read.* = try b.variable(f.v.result);
        const collected = try b.variable(f.m.schema);
        const projected = try b.variable(f.m.state);
        const hydrated = try b.variable(f.m.schema);
        const live = try e.param(main, 2);
        const dead = try e.replace(live, 1, try e.variant(
            b.schemas.items[@intCast(f.v.value)].product[1],
            @backingInt(data.graph.ValueTag.blob),
            try e.literal(data.graph.BlobRef, .{ .id = 0 }),
        ));
        var body = try f.result(reads, collected, hydrated, output);
        const sources = [_]Id{ live, live, live, live, dead, dead, dead };
        const indices = [_]u64{ 0, 0, 256, 0, 10, 0, 0 };
        var i: usize = reads.len;
        while (i != 0) {
            i -= 1;
            const input = if (i == 0) try b.reference(initial) else if (i == 5)
                try b.reference(collected)
            else if (i == 6)
                try b.reference(hydrated)
            else
                try e.field(try b.reference(reads[i - 1]), 0);
            body = try b.bind(reads[i], try e.call(if (i == 1 or i == 5) f.hit else f.read, &.{
                input, sources[i], try b.constant(u64, indices[i]),
            }), body);
            if (i == 1) body = try b.term(.{ .yield_then = body });
            if (i == 5) {
                body = try b.bind(hydrated, try e.call(f.m.hydrate, &.{
                    try e.param(main, 0), try b.reference(projected),
                }), body);
                body = try b.bind(projected, try e.call(f.m.project, &.{
                    try b.reference(collected),
                }), body);
                body = try b.bind(collected, try e.call(
                    (try @import("collect.zig").define(b, f.m)).run,
                    &.{try e.field(try b.reference(reads[4]), 0)},
                ), body);
            }
        }
        try b.define(main, try b.bind(initial, try e.call(f.m.hydrate, &.{
            try e.param(main, 0), try e.param(main, 1),
        }), body));
        return b.module(main, e.unit);
    }

    fn result(f: ProjectionCacheFixture, reads: [7]Id, collected: Id, hydrated: Id, shape: Id) !Id {
        const e = f.e;
        const b = e.b;
        var bytes: [7]Id = undefined;
        var allocations: [7]Id = undefined;
        var states: [7]Id = undefined;
        for (reads, 0..) |read, i| {
            bytes[i] = try b.variable(try b.schema(.bytes));
            states[i] = try e.field(try b.reference(read), 0);
            allocations[i] = try e.field(try f.m.field(e, states[i], .blobs), 0);
        }
        const machines = [_]Id{ states[4], try b.reference(collected), try b.reference(hydrated) };
        const checked = try b.variable(try projection.schema([3]bool, b));
        var entries: [3]Id = undefined;
        for (&entries) |*entry| entry.* = try b.variable(f.m.cache.entries.entries);
        var projected: [4]Id = undefined;
        for (&projected) |*state| state.* = try b.variable(f.m.state);
        const invisible = try e.replace(
            states[4],
            @backingInt(@import("machine.zig").Field.cache),
            try f.m.cache.entries.empty(e),
        );
        const public = [_]Id{ states[4], invisible, states[5], states[6] };
        var byte_values: [7]Id = undefined;
        for (bytes, 0..) |value, i| byte_values[i] = try b.reference(value);
        var body = try b.pure(try e.tuple(shape, &.{
            try b.primitive(try projection.schema([7][]const u8, b), .sequence, &byte_values, 0),
            try b.primitive(try projection.schema([7]u64, b), .sequence, &allocations, 0),
            try b.reference(entries[0]),
            try b.reference(entries[1]),
            try b.reference(entries[2]),
            try b.reference(projected[0]),
            try b.reference(projected[1]),
            try b.reference(projected[2]),
            try b.reference(projected[3]),
            try b.reference(checked),
        }));
        body = try f.validation(machines, checked, body);
        for (projected, public) |target, input|
            body = try b.bind(target, try e.call(f.m.project, &.{input}), body);
        for (entries, machines) |target, input| body = try b.bind(target, try e.call(
            f.m.cache.entries.to_sequence,
            &.{try f.m.field(e, input, .cache)},
        ), body);
        for (bytes, reads, states) |target, read, state| body = try b.bind(
            target,
            try e.call(f.v.bytes, &.{ state, try e.field(try b.reference(read), 1) }),
            body,
        );
        return body;
    }

    fn validation(f: ProjectionCacheFixture, inputs: [3]Id, target: Id, next: Id) !Id {
        const b = f.e.b;
        const validate = try @import("projection_cache.zig").valid(b, f.m);
        var outputs: [3]Id = undefined;
        var refs: [3]Id = undefined;
        for (&outputs, &refs) |*output, *ref| {
            output.* = try b.variable(f.e.boolean);
            ref.* = try b.reference(output.*);
        }
        var body = try b.bind(target, try b.pure(try b.primitive(
            try projection.schema([3]bool, b),
            .sequence,
            &refs,
            0,
        )), next);
        for (outputs, inputs) |output, input|
            body = try b.bind(output, try f.e.call(validate, &.{input}), body);
        return body;
    }
};

test "projection cache preserves collisions allocation collection and restored machine cuts" {
    const native = @import("native_baseline");
    const base = @import("../base/session.zig");
    var b = source.Builder.init(a);
    defer b.deinit();
    const bytes = try b.schema(.bytes);
    const sequence = try b.schema(.{ .seq = bytes });
    const main = try b.declare(&.{sequence}, sequence, &.{}, &.{});
    const argument = try b.reference(b.functions.items[@intCast(main)].parameters[0]);
    try b.define(main, try b.pure(argument));
    const guest_image = try support.encode(b.module(main, try b.scalar(void)));
    defer a.free(guest_image);
    const admitted = try data.program_image.Admitted.decode(a, guest_image);
    defer admitted.deinit();
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    var storage: [257][16]u8 = undefined;
    var elements: [257][]const u8 = undefined;
    for (&storage, &elements, 0..) |*element, *slice, i| {
        @memset(element, @truncate(i));
        element[1] = @truncate(i >> 8);
        slice.* = element;
    }
    const input = try projection.encode([]const []const u8, a, &elements);
    defer a.free(input);
    var oracle = try native.Session.initImage(a, guest_image, input);
    defer oracle.deinit();
    try std.testing.expect(try oracle.run(null) == .completed);
    const expected = try oracle.checkpoint(a);
    defer a.free(expected);
    const value: data.graph.Value = .{ .schema = sequence, .body = .{ .blob = .{ .id = 1 } } };
    const state = try projection.encode(data.process_state.State, a, .{
        .program_identity = admitted.identity(),
        .status = .completed,
        .roots = .{ .exit = .{ .id = 0 } },
        .nodes = &.{.{ .record = .{ .exit = .{ .reason = .{ .normal = value } } } }},
        .blobs = &.{
            .{ .schema = sequence, .bytes = input },
            .{ .schema = sequence, .bytes = input },
        },
    });
    defer a.free(state);
    const encoded_value = try projection.encode(data.graph.Value, a, value);
    defer a.free(encoded_value);
    const arguments = try std.mem.concat(a, u8, &.{ program, state, encoded_value });
    defer a.free(arguments);
    var fixture = source.Builder.init(a);
    defer fixture.deinit();
    const image = try support.encode(try (try ProjectionCacheFixture.init(&fixture)).build());
    defer a.free(image);
    var session = try base.Session.initImage(a, image, arguments, .{});
    defer session.deinit();
    try std.testing.expect(try session.run(null) == .yielded);
    const checkpoint = try session.checkpoint(a);
    defer a.free(checkpoint);
    var restored = try base.Session.restoreImage(a, image, checkpoint, .{});
    defer restored.deinit();
    try restored.resumeYield();
    const outcome = try restored.run(null);
    try std.testing.expect(outcome == .completed);
    var result = try projection.decode(
        ProjectionCacheFixture.Result,
        a,
        try restored.bytes(&outcome.completed),
    );
    defer result.deinit();
    try checkProjectionCacheResult(result.value, &elements, expected, sequence);
}

fn checkProjectionCacheResult(
    result: ProjectionCacheFixture.Result,
    elements: []const []const u8,
    expected: []const u8,
    sequence: u64,
) !void {
    try std.testing.expectEqualDeep([_]bool{ true, true, true }, result.valid);
    for (result.values, [_]usize{ 0, 0, 256, 0, 10, 0, 0 }) |actual, index| {
        const encoded = try projection.encode([]const u8, a, elements[index]);
        defer a.free(encoded);
        try std.testing.expectEqualSlices(u8, encoded, actual);
    }
    try std.testing.expectEqualSlices(u64, &.{ 3, 4, 5, 6, 7, 2, 2 }, &result.allocations);
    try std.testing.expectEqual(2, result.warm.len);
    try std.testing.expectEqual(3, result.warm[0].slot);
    try std.testing.expectEqual(1, result.warm[0].value.blob);
    try std.testing.expectEqual(0, result.warm[0].value.index);
    try std.testing.expectEqual(8, result.warm[1].slot);
    try std.testing.expectEqual(0, result.warm[1].value.blob);
    try std.testing.expectEqual(10, result.warm[1].value.index);
    try std.testing.expectEqual(1, result.collected.len);
    try std.testing.expectEqual(0, result.hydrated.len);
    try std.testing.expectEqual(2, result.collected[0].slot);
    try std.testing.expectEqual(0, result.collected[0].value.blob);
    try std.testing.expectEqual(sequence, result.collected[0].value.schema);
    try std.testing.expectEqual(0, result.collected[0].value.index);
    try std.testing.expectEqualDeep(result.before, result.invisible);
    try std.testing.expectEqualDeep(result.after, result.restored);
    var canonical = try data.state_image.canonicalize(a, result.after);
    defer canonical.deinit();
    const actual = try data.state_image.emit(a, canonical.state);
    defer a.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

const SparseProjectionFixture = struct {
    const cache = @import("projection_cache.zig");
    const Id = data.program.Id;
    const indices = [_]u64{ 5, 7, 9, 3, 8, 4, 256, 0, 7 };
    const Result = struct {
        values: [indices.len][]const u8,
        predecessors: [indices.len]?cache.Predecessor,
        collision: ?cache.Predecessor,
        wrong_blob: ?cache.Predecessor,
        wrong_schema: ?cache.Predecessor,
        wrong_kind: ?cache.Predecessor,
    };
    const Reads = struct {
        results: [indices.len]Id,
        priors: [indices.len]Id,
        bytes: [indices.len]Id,
    };

    fn build(f: ProjectionCacheFixture) !source.Module {
        const e = f.e;
        const b = e.b;
        const optional = try projection.schema(?cache.Predecessor, b);
        const output = try projection.schema(Result, b);
        const main = try b.declare(&.{ f.m.program, f.m.state, f.v.value }, output, &.{}, &.{});
        const initial = try b.variable(f.m.schema);
        const live = try e.param(main, 2);
        var reads: Reads = undefined;
        for (&reads.results, &reads.priors, &reads.bytes) |*result, *prior, *bytes| {
            result.* = try b.variable(f.v.result);
            prior.* = try b.variable(optional);
            bytes.* = try b.variable(try b.schema(.bytes));
        }
        var body = try assemble(f, reads, live, optional, output);
        var i = indices.len;
        while (i != 0) {
            i -= 1;
            const prior = if (i == 0) try b.reference(initial) else try e.field(
                try b.reference(reads.results[i - 1]),
                0,
            );
            const read = try b.reference(reads.results[i]);
            const index = try b.constant(u64, indices[i]);
            body = try b.bind(reads.bytes[i], try e.call(f.v.bytes, &.{
                try e.field(read, 0), try e.field(read, 1),
            }), body);
            body = try b.bind(reads.results[i], try e.call(f.read, &.{ prior, live, index }), body);
            body = try b.bind(reads.priors[i], try cache.predecessor(
                e,
                f.m,
                prior,
                live,
                index,
            ), body);
        }
        try b.define(main, try b.bind(initial, try e.call(f.m.hydrate, &.{
            try e.param(main, 0), try e.param(main, 1),
        }), body));
        return b.module(main, e.unit);
    }

    fn assemble(f: ProjectionCacheFixture, reads: Reads, live: Id, optional: Id, output: Id) !Id {
        const e = f.e;
        const b = e.b;
        var byte_values: [indices.len]Id = undefined;
        var prior_values: [indices.len]Id = undefined;
        for (reads.bytes, reads.priors, 0..) |bytes, prior, i| {
            byte_values[i] = try b.reference(bytes);
            prior_values[i] = try b.reference(prior);
        }
        var checks: [4]Id = undefined;
        var checked: [4]Id = undefined;
        for (&checks, &checked) |*check, *value| {
            check.* = try b.variable(optional);
            value.* = try b.reference(check.*);
        }
        const body = try b.pure(try e.tuple(output, &.{
            try b.primitive(
                try projection.schema([indices.len][]const u8, b),
                .sequence,
                &byte_values,
                0,
            ),
            try b.primitive(
                try projection.schema([indices.len]?cache.Predecessor, b),
                .sequence,
                &prior_values,
                0,
            ),
            checked[0],
            checked[1],
            checked[2],
            checked[3],
        }));
        const last = try e.field(try b.reference(reads.results[indices.len - 1]), 0);
        return checkKeys(f, last, live, checks, body);
    }

    fn checkKeys(f: ProjectionCacheFixture, last: Id, live: Id, checks: [4]Id, body: Id) !Id {
        const e = f.e;
        const b = e.b;
        const replaced = try b.variable(f.m.cache.schema);
        const bad_machine = try e.replace(
            last,
            @backingInt(@import("machine.zig").Field.cache),
            try b.reference(replaced),
        );
        const bad_entry = try e.tuple(f.m.cache.entry, &.{
            e.one,
            try e.field(live, 0),
            try b.constant(u64, 6),
            try b.constant(u64, @backingInt(cache.Kind.field)),
            try e.literal(cache.Range, .{ .schema = 0, .start = 1, .end = 2 }),
        });
        const other_blob = try e.replace(live, 1, try e.variant(
            b.schemas.items[@intCast(f.v.value)].product[1],
            @backingInt(data.graph.ValueTag.blob),
            try e.literal(data.graph.BlobRef, .{ .id = 0 }),
        ));
        const other_schema = try e.replace(
            live,
            0,
            try e.binary(.integer_add, try e.field(live, 0), e.one),
        );
        const target = try b.constant(u64, 257);
        var next = try b.bind(checks[3], try cache.predecessor(
            e,
            f.m,
            bad_machine,
            live,
            target,
        ), body);
        next = try b.bind(replaced, try e.call(f.m.cache.entries.set, &.{
            try f.m.cache.entries.empty(e), e.zero, bad_entry,
        }), next);
        next = try b.bind(checks[2], try cache.predecessor(
            e,
            f.m,
            last,
            other_schema,
            target,
        ), next);
        next = try b.bind(checks[1], try cache.predecessor(e, f.m, last, other_blob, target), next);
        return b.bind(checks[0], try cache.predecessor(e, f.m, last, live, target), next);
    }
};

test "projection cache preserves sparse reverse random reads and rejects mismatched keys" {
    const base = @import("../base/session.zig");
    var b = source.Builder.init(a);
    defer b.deinit();
    const bytes = try b.schema(.bytes);
    const sequence = try b.schema(.{ .seq = bytes });
    const main = try b.declare(&.{sequence}, sequence, &.{}, &.{});
    try b.define(main, try b.pure(try b.reference(b.parameter(main, 0))));
    const guest_image = try support.encode(b.module(main, try b.scalar(void)));
    defer a.free(guest_image);
    const admitted = try data.program_image.Admitted.decode(a, guest_image);
    defer admitted.deinit();
    var storage: [257][18]u8 = undefined;
    var elements: [257][]const u8 = undefined;
    for (&storage, &elements, 0..) |*element, *slice, i| {
        @memset(element, @truncate(i));
        element[1] = @truncate(i >> 8);
        slice.* = element[0 .. 16 + i % 3];
    }
    const input = try projection.encode([]const []const u8, a, &elements);
    defer a.free(input);
    try std.testing.expect(input.len >= 4096);
    const arguments = try sparseProjectionArguments(admitted, sequence, input);
    defer a.free(arguments);
    var authored = source.Builder.init(a);
    defer authored.deinit();
    const image = try support.encode(try SparseProjectionFixture.build(
        try ProjectionCacheFixture.init(&authored),
    ));
    defer a.free(image);
    var session = try base.Session.initImage(a, image, arguments, .{});
    defer session.deinit();
    const outcome = try session.run(null);
    try std.testing.expect(outcome == .completed);
    var result = try projection.decode(
        SparseProjectionFixture.Result,
        a,
        try session.bytes(&outcome.completed),
    );
    defer result.deinit();
    try checkSparseProjection(result.value, &elements, input.len, bytes);
}

fn sparseProjectionArguments(
    admitted: *const data.program_image.Admitted,
    sequence: u64,
    input: []const u8,
) ![]u8 {
    const program = try projection.programBytes(a, admitted);
    defer a.free(program);
    const value: data.graph.Value = .{ .schema = sequence, .body = .{ .blob = .{ .id = 1 } } };
    const state = try projection.encode(data.process_state.State, a, .{
        .program_identity = admitted.identity(),
        .status = .completed,
        .roots = .{ .exit = .{ .id = 0 } },
        .nodes = &.{.{ .record = .{ .exit = .{ .reason = .{ .normal = value } } } }},
        .blobs = &.{
            .{ .schema = sequence, .bytes = input },
            .{ .schema = sequence, .bytes = input },
        },
    });
    defer a.free(state);
    const encoded_value = try projection.encode(data.graph.Value, a, value);
    defer a.free(encoded_value);
    return std.mem.concat(a, u8, &.{ program, state, encoded_value });
}

fn checkSparseProjection(
    result: SparseProjectionFixture.Result,
    elements: []const []const u8,
    length: usize,
    schema: u64,
) !void {
    const cache = @import("projection_cache.zig");
    var ranges: [257]cache.Range = undefined;
    var offset: u64 = 2;
    for (elements, &ranges) |element, *range| {
        const encoded = try projection.encode([]const u8, a, element);
        defer a.free(encoded);
        range.* = .{ .schema = schema, .start = offset, .end = offset + encoded.len };
        offset = range.end;
    }
    try std.testing.expectEqual(length, offset);
    const expected = [_]?u64{ null, 5, 7, null, 7, 3, 9, null, 5 };
    for (SparseProjectionFixture.indices, expected, 0..) |index, prior_index, i| {
        const encoded = try projection.encode([]const u8, a, elements[@intCast(index)]);
        defer a.free(encoded);
        try std.testing.expectEqualSlices(u8, encoded, result.values[i]);
        if (prior_index) |selected| {
            try std.testing.expectEqualDeep(cache.Predecessor{
                .index = selected,
                .range = ranges[@intCast(selected)],
            }, result.predecessors[i].?);
        } else try std.testing.expect(result.predecessors[i] == null);
    }
    try std.testing.expectEqualDeep(cache.Predecessor{
        .index = 9,
        .range = ranges[9],
    }, result.collision.?);
    try std.testing.expect(result.wrong_blob == null);
    try std.testing.expect(result.wrong_schema == null);
    try std.testing.expect(result.wrong_kind == null);
}

test "authored lexical closures and bounded data preserve every native cut" {
    var core = try support.prepareCore();
    defer core.deinit();
    inline for (.{ source.examples.lexical, source.examples.boundedValues }, 0..) |build, i| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const image = try support.encode(try build(&b));
        defer a.free(image);
        try support.expectNativeCuts(
            &core,
            image,
            if (i == 0) &std.mem.toBytes(@as(u64, 41)) else &.{},
            40,
        );
    }
}

test "authored cell updates preserve alias identity inside a guest region" {
    var core = try support.prepareCore();
    defer core.deinit();
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const r = b.region();
    const region = try b.schema(.{ .internal = .{ .region = r } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{ .region = r, .element = e.integer } } });
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region},
        .result = e.integer,
        .regions = &.{r},
    } } });
    const body = try b.declare(&.{region}, e.integer, &.{}, &.{r});
    const allocated = try b.variable(cell);
    const alias = try b.variable(cell);
    const changed = try b.variable(e.unit);
    const allocation = try b.primitive(cell, .cell_new, &.{
        try e.param(body, 0), try b.constant(u64, 17),
    }, 0);
    const update = try b.primitive(e.unit, .cell_set, &.{
        try b.reference(allocated), try b.constant(u64, 29),
    }, 0);
    const read = try b.primitive(e.integer, .cell_get, &.{try b.reference(alias)}, 0);
    try b.define(
        body,
        try b.bind(
            allocated,
            try b.pure(allocation),
            try b.bind(
                alias,
                try b.pure(try b.primitive(
                    cell,
                    .move,
                    &.{try b.reference(allocated)},
                    0,
                )),
                try b.bind(changed, try b.pure(update), try b.pure(read)),
            ),
        ),
    );
    const main = try b.declare(&.{}, e.integer, &.{}, &.{});
    try b.define(main, try b.term(.{ .with_region = .{
        .region = r,
        .body = try b.lambda(body, body_type),
    } }));
    const image = try support.encode(b.module(main, e.unit));
    defer a.free(image);
    try support.expectNativeCuts(&core, image, &.{}, 40);
}

test "authored owned aggregate extraction preserves a resource identity" {
    var core = try support.prepareCore();
    defer core.deinit();
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const resource = try b.resource(e.integer);
    const pair = try b.schema(.{ .product = &.{ resource, e.integer } });
    const main = try b.declare(&.{e.integer}, e.integer, &.{}, &.{});
    try b.resourceAuthority(resource, &.{main}, &.{main});
    const owned = try b.primitive(resource, .resource_pack, &.{try e.param(main, 0)}, 0);
    const product = try e.tuple(pair, &.{ owned, try b.constant(u64, 3) });
    const projected = try e.field(product, 0);
    try b.define(main, try b.pure(try b.primitive(e.integer, .resource_unpack, &.{projected}, 0)));
    const image = try support.encode(b.module(main, e.unit));
    defer a.free(image);
    try support.expectNativeCuts(&core, image, &std.mem.toBytes(@as(u64, 53)), 30);
}

test "authored bytes and text rules match native instruction cuts" {
    var core = try support.prepareCore();
    defer core.deinit();
    var b = source.Builder.init(a);
    defer b.deinit();
    const e = try Author.init(&b);
    const bytes = try b.schema(.bytes);
    const text = try b.schema(.text);
    const signed = try b.scalar(i64);
    const codepoint = try b.scalar(u32);
    const byte = try b.scalar(u8);
    const optional = try b.schema(.{ .sum = &.{ e.unit, byte } });
    const comparison = try b.scalar(i8);
    const output = try b.schema(.{ .product = &.{
        e.integer, bytes, bytes, comparison, optional, text, text, bytes,
    } });
    const main = try b.declare(&.{ bytes, e.integer, signed, codepoint }, output, &.{}, &.{});
    const input = try e.param(main, 0);
    const index = try e.param(main, 1);
    const length = try b.primitive(e.integer, .blob_length, &.{input}, 0);
    const concat = try e.concat(input, try e.literal([]const u8, &.{ 0, 128, 255 }));
    const slice = try e.slice(input, e.zero, try b.constant(u64, 2));
    const compare = try b.primitive(comparison, .blob_compare, &.{
        input, try e.literal([]const u8, &.{ 42, 0, 11 }),
    }, 0);
    const get = try b.primitive(optional, .blob_byte, &.{ input, index }, 0);
    const integer_text = try b.primitive(text, .text_integer, &.{try e.param(main, 2)}, 0);
    const scalar_text = try e.checked(
        text,
        .text_scalar,
        &.{try e.param(main, 3)},
        &.{.invalid_utf8},
    );
    const one = try b.primitive(bytes, .blob_from_byte, &.{try b.constant(u8, 251)}, 0);
    try b.define(main, try b.pure(try e.tuple(output, &.{
        length, concat, slice, compare, get, integer_text, scalar_text, one,
    })));
    const image = try support.encode(b.module(main, e.unit));
    defer a.free(image);
    const Input = struct { bytes: []const u8, index: u64, integer: i64, codepoint: u32 };
    const cases = [_]Input{
        .{
            .bytes = &.{ 0, 0, 2 },
            .index = 0,
            .integer = std.math.minInt(i64),
            .codepoint = 0x10ffff,
        },
        .{ .bytes = &.{ 42, 0, 11 }, .index = 1, .integer = -1, .codepoint = 0xe9 },
        .{ .bytes = &.{ 43, 0, 9 }, .index = 2, .integer = 0, .codepoint = 0x20ac },
        .{
            .bytes = &.{ 255, 1, 8 },
            .index = std.math.maxInt(u64),
            .integer = std.math.maxInt(i64),
            .codepoint = 65,
        },
    };
    for (cases) |case| {
        const input_bytes = try projection.encode(Input, a, case);
        defer a.free(input_bytes);
        try support.expectNativeCuts(&core, image, input_bytes, 60);
    }
}

test "text slices preserve empty ranges and fault precedence at every byte offset" {
    var core = try support.prepareCore();
    defer core.deinit();
    const Input = struct { text: []const u8, start: u64, end: u64 };
    // One representative of each UTF-8 width. Every pair of offsets includes
    // interior empty ranges, nonempty partial characters, reversed ranges and
    // one-past-end ranges. The frozen evaluator supplies every expected cut.
    inline for (.{
        data.program.Schema.text,
        data.program.Schema{
            .bounded_text = 4,
        },
        data.program.Schema{
            .bounded_text = 0,
        },
    }) |result_shape| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const e = try Author.init(&b);
        const text = try b.schema(.text);
        const result = try b.schema(result_shape);
        const failure = try b.scalar(u8);
        const main = try b.declare(&.{ text, e.integer, e.integer }, result, &.{}, &.{});
        const sliced = try b.value(.{ .schema = result, .expression = .{ .primitive = .{
            .opcode = .blob_slice,
            .operands = &.{ try e.param(main, 0), try e.param(main, 1), try e.param(main, 2) },
            .failures = &.{
                .{
                    .kind = .capacity_exceeded,
                    .value = try b.failureLiteral(try b.constant(u8, 1)),
                },
                .{ .kind = .invalid_utf8, .value = try b.failureLiteral(try b.constant(u8, 2)) },
            },
        } } });
        try b.define(main, try b.pure(sliced));
        const image = try support.encode(b.module(main, failure));
        defer a.free(image);
        for ([_][]const u8{ "", "A", "é", "€", "𐍈" }) |text_bytes| {
            for (0..text_bytes.len + 2) |start| {
                for (0..text_bytes.len + 2) |end| {
                    const input = try projection.encode(Input, a, .{
                        .text = text_bytes,
                        .start = start,
                        .end = end,
                    });
                    defer a.free(input);
                    try support.expectNativeCuts(&core, image, input, 20);
                }
            }
        }
    }
}
