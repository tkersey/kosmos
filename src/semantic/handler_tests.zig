const std = @import("std");
const source = @import("horos").source;
const a = std.testing.allocator;
const support = @import("test_support.zig");

test "handlers and resumptions match deep shallow multi-shot and private-region native cuts" {
    var core = try support.prepareCore();
    defer core.deinit();
    inline for (.{
        source.examples.deep,
        source.examples.shallow,
        source.examples.choicesAll,
        source.examples.cloned,
        source.examples.stateLocal,
        source.examples.stateShared,
        source.examples.shallowResumptions,
        source.examples.shallowInjection,
    }, 0..) |example, i| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const image = try support.encode(try example(&b));
        defer a.free(image);
        support.expectNativeCuts(
            &core,
            image,
            if (i == 1 or i == 7) &.{0} else &.{},
            400,
        ) catch |err| {
            std.debug.print("handler example {d}: {s}\n", .{ i, @errorName(err) });
            return err;
        };
    }
}

test "retained scopes owned packages generators and abandoned cleanup preserve native cuts" {
    var core = try support.prepareCore();
    defer core.deinit();
    inline for (.{
        source.examples.ownership,
        source.examples.schedulerFifo,
        source.examples.generator,
        source.examples.retainedScope,
        source.examples.clauseAbort,
        source.examples.branchingTailProtected,
    }, 0..) |example, i| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const image = try support.encode(try example(&b));
        defer a.free(image);
        for (0..if (i == 5) @as(usize, 2) else 1) |input| {
            const flag: [1]u8 = .{@intCast(input)};
            support.expectNativeCutsWithReplies(
                &core,
                image,
                if (i == 5) &flag else &.{},
                1200,
                support.respond,
            ) catch |err| {
                std.debug.print(
                    "retained handler example {d} input {d}: {s}\n",
                    .{ i, input, @errorName(err) },
                );
                return err;
            };
        }
    }
}
