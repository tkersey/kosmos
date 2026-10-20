const std = @import("std");
const source = @import("horos").source;
const a = std.testing.allocator;
const support = @import("test_support.zig");

test "cleanup preserves primary exits failure order yields and resource loans at every native cut" {
    var core = try support.prepareCore();
    defer core.deinit();
    inline for (.{
        source.examples.yieldingCleanup,
        source.examples.resourceScalar,
        source.examples.resourcePair,
    }, 0..) |example, i| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const image = try support.encode(try example(&b));
        defer a.free(image);
        for (0..if (i == 0) @as(usize, 2) else 1) |n| {
            const flag: [1]u8 = .{@intCast(n)};
            support.expectNativeCutsWithReplies(
                &core,
                image,
                if (i == 0) &flag else &.{},
                400,
                support.respond,
            ) catch |err| {
                std.debug.print("cleanup example {d} input {d}: {s}\n", .{ i, n, @errorName(err) });
                return err;
            };
        }
    }
}
