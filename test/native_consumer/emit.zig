//! The native package consumer's independent authored input.
const std = @import("std");
const horos = @import("horos");

pub fn main(init: std.process.Init) !void {
    var builder = horos.source.Builder.init(init.gpa);
    defer builder.deinit();
    var compiled = try horos.program.compile(
        init.gpa,
        try horos.source.examples.installations(&builder, 64),
    );
    defer compiled.deinit();
    const bytes = try init.gpa.alloc(
        u8,
        try horos.data.program_image.encodedLength(compiled.program),
    );
    defer init.gpa.free(bytes);
    _ = try compiled.encode(init.gpa, bytes);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(bytes);
    try output.interface.flush();
}
