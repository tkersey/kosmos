//! Previously compiled ordinary core bytes for authenticated downstream builds.
//! Kosmos itself still builds from source and checks exact byte correspondence.
//! These fingerprints select that checked content; they are not derivation proof.
const std = @import("std");
pub const bytes = @embedFile("semantic-core.kar");
pub const horos_package = "horos-6.0.0-flclaDfbQAD6K8zS9U8ts9xpziBg_1zaU23OvgqKePKb";
pub const source_sha256 = "ae2e86f57d67fe6b1ac568ef703013b124f279b06b1a3e3b38415f4fcb637af5";
pub const artifact_sha256 = "2866f4660fa7f022e74db3f3ac9a42a995d999a4816be89d9618d5ba7e8cdd85";

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
