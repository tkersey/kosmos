//! Previously compiled ordinary core bytes for authenticated downstream builds.
//! Kosmos itself still builds from source and checks exact byte correspondence.
//! These fingerprints select that checked content; they are not derivation proof.
const std = @import("std");
pub const bytes = @embedFile("semantic-core.kar");
pub const horos_package = "horos-6.1.0-flclaD9lTQDIPTTYqpKRQVlTuqLNPdbhjkex50CzBfiw";
pub const source_sha256 = "2b4f0b67fd564fb2c763fd1a7a99b54619a3ccdc460aa4293e7e6a95425ca084";
pub const artifact_sha256 = "bc258c694c9bde928f21363a17f3b9efd9fd0b8407e8153c2b705755c64daeb2";

pub fn check(selected_horos: []const u8) !void {
    if (!std.mem.eql(u8, selected_horos, horos_package) or
        !std.mem.eql(
            u8,
            @import("builtin").zig_version_string,
            "0.17.0",
        )) return error.PackagedCompilerMismatch;
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(
        @import("semantic/source_identity.zig").digest(),
        .lower,
    ), source_sha256)) return error.StalePackagedSource;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    if (!std.mem.eql(
        u8,
        &std.fmt.bytesToHex(hash, .lower),
        artifact_sha256,
    )) return error.PackagedArtifactMismatch;
}

pub fn main(init: std.process.Init) !void {
    check(@import("artifact_options").horos_package) catch |err| {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        std.debug.print(
            "Regenerate with zig build semantic-artifact before updating pack" ++
                "aged bindings.\nCurrent source_sha256={s}\nCurrent artifact_sha256={s}\n",
            .{
                std.fmt.bytesToHex(@import("semantic/source_identity.zig").digest(), .lower),
                std.fmt.bytesToHex(hash, .lower),
            },
        );
        return err;
    };
    var buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(bytes);
    try output.interface.flush();
}
