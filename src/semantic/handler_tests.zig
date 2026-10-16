const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const steps = @import("step_tests.zig");
const a = std.testing.allocator;

test "authored handlers and resumptions match deep shallow multi-shot and private-region native cuts" {
    var core = try steps.prepareCore();
    defer core.deinit();
    inline for (.{ source.examples.deep, source.examples.shallow, source.examples.choicesAll, source.examples.cloned, source.examples.stateLocal, source.examples.stateShared, source.examples.shallowResumptions, source.examples.shallowInjection }, 0..) |example, i| {
        var b = source.Builder.init(a);
        defer b.deinit();
        var compiled = try source.lower(a, try example(&b));
        defer compiled.deinit();
        const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
        defer a.free(image);
        _ = try compiled.encode(a, image);
        steps.expectNativeCuts(&core, image, if (i == 1 or i == 7) &.{0} else &.{}, 400) catch |err| {
            std.debug.print("handler example {d}: {s}\n", .{ i, @errorName(err) });
            return err;
        };
    }
}

test "authored retained scopes owned packages generators and abandoned cleanup preserve native cuts" {
    var core = try steps.prepareCore();
    defer core.deinit();
    inline for (.{ source.examples.ownership, source.examples.schedulerFifo, source.examples.generator, source.examples.retainedScope, source.examples.clauseAbort, source.examples.branchingTailProtected }, 0..) |example, i| {
        var b = source.Builder.init(a);
        defer b.deinit();
        var compiled = try source.lower(a, try example(&b));
        defer compiled.deinit();
        const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
        defer a.free(image);
        _ = try compiled.encode(a, image);
        for (0..if (i == 5) @as(usize, 2) else 1) |input| {
            const flag: [1]u8 = .{@intCast(input)};
            steps.expectNativeCutsWithReplies(&core, image, if (i == 5) &flag else &.{}, 1200, @import("cleanup_tests.zig").respond) catch |err| {
                std.debug.print("retained handler example {d} input {d}: {s}\n", .{ i, input, @errorName(err) });
                return err;
            };
        }
    }
}
