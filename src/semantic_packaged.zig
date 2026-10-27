//! Previously compiled ordinary core bytes for authenticated downstream builds.
//! Kosmos itself still builds from source and checks exact byte correspondence.
//! These fingerprints select that checked content; they are not derivation proof.
const std = @import("std");
pub const bytes = @embedFile("semantic-core.kar");
pub const horos_package = "horos-7.0.0-flclaBZkVAAmdNWxLXAEoA4vdT3jZa8rzgL7d5KXysQg";
pub const source_sha256 = "db1f6e65bd0a4a7272f21971670fff474c9c0c0a272de69ca46e346894b397f3";
pub const artifact_sha256 = "4a1bf4ab547b149ef55753b8d0dc976f4e43d281d785a6cf3893abbfb8ed9020";

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
