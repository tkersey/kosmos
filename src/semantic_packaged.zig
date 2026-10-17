//! Previously compiled ordinary core bytes for authenticated downstream builds.
//! Kosmos itself still builds from source and checks exact byte correspondence.
//! These fingerprints select that checked content; they are not derivation proof.
const std = @import("std");
pub const bytes = @embedFile("semantic-core.kar");
pub const horos_package = "horos-6.0.0-flclaIbEQADPdntvXZaUuHK4aUq1ipZ3ee4zGfy5DJD5";
pub const source_sha256 = "28a7dcbb8f79782b70255b7d9cc092ec2b3094d84a4fc2930d58d97a1b49f112";
pub const artifact_sha256 = "b77b7ff5e1d0e1798052adc6b8b58026c48274a232e3e27901e2bb025c38295a";

pub fn check(selected_horos: []const u8) !void {
    if (!std.mem.eql(u8, selected_horos, horos_package) or
        !std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0")) return error.PackagedCompilerMismatch;
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(@import("semantic/source_identity.zig").digest(), .lower), source_sha256)) return error.StalePackagedSource;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(hash, .lower), artifact_sha256)) return error.PackagedArtifactMismatch;
}

pub fn main(init: std.process.Init) !void {
    check(@import("artifact_options").horos_package) catch |err| {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        std.debug.print("Regenerate with zig build semantic-artifact before updating packaged bindings.\nCurrent source_sha256={s}\nCurrent artifact_sha256={s}\n", .{
            std.fmt.bytesToHex(@import("semantic/source_identity.zig").digest(), .lower),
            std.fmt.bytesToHex(hash, .lower),
        });
        return err;
    };
    var buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(bytes);
    try output.interface.flush();
}
