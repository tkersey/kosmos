//! Previously compiled ordinary core bytes for authenticated downstream builds.
//! Kosmos itself still builds from source and checks exact byte correspondence.
//! These fingerprints select that checked content; they are not derivation proof.
const std = @import("std");
pub const bytes = @embedFile("semantic-core.kar");
pub const horos_package = "horos-8.0.0-flclaIItVgCRBCbUEysErcsQyVqsukGf2Q8X2is_wRuU";
pub const source_sha256 = "08c48a517383d1f8addd8175dcf73e4542cb3b781fba74ba3ba5d3f8fbfe8f6a";
pub const artifact_sha256 = "be16c35ee37dadadb69cb76bbfdad5be1c772f78e270638554457c19f43113f0";

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
