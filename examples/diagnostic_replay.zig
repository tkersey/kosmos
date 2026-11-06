const std = @import("std");
const example = @import("diagnostic_example");

pub fn main(init: std.process.Init) !void {
    const report = try example.run(init.gpa);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
