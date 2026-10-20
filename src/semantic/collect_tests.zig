const std = @import("std");
const source = @import("horos").source;
const a = std.testing.allocator;
const support = @import("test_support.zig");

test "authored collection preserves cycles aliases pending exits and loans at every native cut" {
    var core = try support.prepareCoreWithCollection(true);
    defer core.deinit();
    inline for (.{
        source.examples.cloned, source.examples.yieldingCleanup, source.examples.resourcePair,
    }, 0..) |example, i| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const image = try support.encode(try example(&b));
        defer a.free(image);
        support.expectNativeCutsWithReplies(
            &core,
            image,
            if (i == 1) &.{1} else &.{},
            400,
            support.respond,
        ) catch |err| {
            std.debug.print("collection example {d}: {s}\n", .{ i, @errorName(err) });
            return err;
        };
    }
}
