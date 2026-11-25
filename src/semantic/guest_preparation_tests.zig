const std = @import("std");
const facade = @import("session.zig");
const artifact = @import("artifact.zig");
const support = @import("test_support.zig");
const packaged = @import("packaged_runtime");
const a = std.testing.allocator;

test "admitted guest ownership survives caller bytes and preparation teardown" {
    const image = try support.guestImage();
    defer a.free(image);
    var guest = try facade.Prepared.Guest.init(a, image);
    defer guest.deinit();
    @memset(image, 0);
    var prepared = try facade.Prepared.initWithGuest(a, &guest);
    defer prepared.deinit();
    try std.testing.expect(guest.core == prepared.guest.core);
    var retained = try prepared.clone();
    defer retained.deinit();
    try std.testing.expect(prepared.guest.core == retained.guest.core);
    try std.testing.expect(prepared.runtime.core == retained.runtime.core);
    var session = try facade.Session.start(a, &retained, &std.mem.toBytes(@as(u64, 37)));
    defer session.deinit();
    guest.deinit();
    prepared.deinit();
    retained.deinit();
    const observation = try session.run(null);
    try std.testing.expect(observation == .completed);
    try std.testing.expectEqualSlices(
        u8,
        &std.mem.toBytes(@as(u64, 43)),
        try session.bytes(&observation.completed),
    );
}

test "admitted guest selection shares owners and rejects unavailable leases" {
    const image = try support.guestImage();
    defer a.free(image);
    var guest = try facade.Prepared.Guest.init(a, image);
    defer guest.deinit();
    var runtime = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer runtime.deinit();
    var prepared = try facade.Prepared.initWithGuestAndRuntime(a, &guest, &runtime);
    defer prepared.deinit();
    try std.testing.expect(prepared.guest.core == guest.core);
    try std.testing.expect(prepared.runtime.core == runtime.core);
    guest.deinit();
    try std.testing.expectError(
        error.InvalidState,
        facade.Prepared.initWithGuestAndRuntime(a, &guest, &runtime),
    );
    runtime.deinit();
    try std.testing.expectError(
        error.InvalidState,
        facade.Prepared.initWithGuestAndRuntime(a, &prepared.guest, &runtime),
    );
    var session = try facade.Session.start(a, &prepared, &std.mem.toBytes(@as(u64, 37)));
    defer session.deinit();
    try std.testing.expect(try session.run(null) == .completed);
}

test "admitted guest selection preserves runtime guest identity rejection" {
    const image = try support.guestImage();
    defer a.free(image);
    var guest = try facade.Prepared.Guest.init(a, image);
    defer guest.deinit();
    var runtime = try artifact.Admitted.init(a, packaged.bytes, artifact.digest(packaged.bytes));
    defer runtime.deinit();
    var bundle = runtime.content.value;
    bundle.guest = @splat(0xa5);
    bundle.specialization = @splat(0x5a);
    const bytes = try artifact.encode(a, bundle);
    defer a.free(bytes);
    var mismatch = try artifact.Admitted.init(a, bytes, artifact.digest(bytes));
    defer mismatch.deinit();
    try std.testing.expectError(
        error.GuestIdentityMismatch,
        facade.Prepared.initWithGuestAndRuntime(a, &guest, &mismatch),
    );
    try std.testing.expectError(
        error.GuestIdentityMismatch,
        facade.Prepared.initWithRuntime(a, image, &mismatch),
    );
}
