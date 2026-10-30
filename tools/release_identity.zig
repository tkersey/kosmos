const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const bytes = @import("semantic/source_identity.zig").digest();
    try std.Io.File.stdout().writeStreamingAll(init.io, &std.fmt.bytesToHex(bytes, .lower));
}
