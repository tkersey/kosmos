const std = @import("std");
const data = @import("horos_data");
const source = @import("horos").source;
const steps = @import("step_tests.zig");
const native = @import("../../test_oracle.zig");
const a = std.testing.allocator;

// A host response is a fixture input. Every guest transition before and after
// it is independently executed by the authored core and compared as PST3.
pub fn respond(guest: *native.Session, shape: data.program.Schema) !void {
    var pending = try guest.pendingRequest(a);
    defer pending.deinit();
    const number = std.mem.toBytes(@as(u64, 41));
    const bytes: []const u8 = switch (shape) {
        .unit => &.{},
        .u64 => &number,
        else => return error.UnsupportedTestResponse,
    };
    const wire = try data.invocation.encodeOwned(data.invocation.Result, a, .{ .request_identity = pending.request.request_identity, .value = bytes });
    defer a.free(wire);
    try guest.answer(wire);
}

test "authored cleanup preserves primary exits failure order yields and resource loans at every native cut" {
    var core = try steps.prepareCore();
    defer core.deinit();
    inline for (.{ source.examples.yieldingCleanup, source.examples.resourceScalar, source.examples.resourcePair }, 0..) |example, i| {
        var b = source.Builder.init(a);
        defer b.deinit();
        var compiled = try source.lower(a, try example(&b));
        defer compiled.deinit();
        const image = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
        defer a.free(image);
        _ = try compiled.encode(a, image);
        for (0..if (i == 0) @as(usize, 2) else 1) |n| {
            const flag: [1]u8 = .{@intCast(n)};
            steps.expectNativeCutsWithReplies(&core, image, if (i == 0) &flag else &.{}, 400, respond) catch |err| {
                std.debug.print("cleanup example {d} input {d}: {s}\n", .{ i, n, @errorName(err) });
                return err;
            };
        }
    }
}
