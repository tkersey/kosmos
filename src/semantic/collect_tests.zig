const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const steps = @import("step_tests.zig");
const a = std.testing.allocator;

test "authored collection preserves cycles aliases pending exits and loans at every native cut" {
    var core = try steps.prepareCoreWithCollection(true);
    defer core.deinit();
    inline for (.{ source.examples.cloned, source.examples.yieldingCleanup, source.examples.resourcePair }, 0..) |example, i| {
        var b = source.Builder.init(a);
        defer b.deinit();
        var compiled = try source.lower(a, try example(&b));
        defer compiled.deinit();
        const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
        defer a.free(image);
        _ = try compiled.encode(a, image);
        steps.expectNativeCutsWithReplies(&core, image, if (i == 1) &.{1} else &.{}, 400, @import("cleanup_tests.zig").respond) catch |err| {
            std.debug.print("collection example {d}: {s}\n", .{ i, @errorName(err) });
            return err;
        };
    }
}
