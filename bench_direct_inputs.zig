const std = @import("std");
const workloads = @import("src/semantic_workloads.zig");

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    var arguments = try init.minimal.args.iterateAllocator(a);
    defer arguments.deinit();
    _ = arguments.skip();
    const path = arguments.next() orelse return error.MissingDirectory;
    var directory = try std.Io.Dir.cwd().createDirPathOpen(init.io, path, .{});
    defer directory.close(init.io);
    for (std.meta.tags(workloads.Workload)) |kind| {
        const image = try workloads.image(a, kind);
        defer a.free(image);
        var name_buffer: [64]u8 = undefined;
        const image_name = try std.fmt.bufPrint(&name_buffer, "{s}.bpi3", .{@tagName(kind)});
        try directory.writeFile(init.io, .{ .sub_path = image_name, .data = image });
        for (0..3) |sample| {
            const input = try workloads.arguments(a, kind, sample);
            defer a.free(input);
            const input_name = try std.fmt.bufPrint(
                &name_buffer,
                "{s}-{d}.args",
                .{ @tagName(kind), sample },
            );
            try directory.writeFile(init.io, .{ .sub_path = input_name, .data = input });
        }
    }
}
