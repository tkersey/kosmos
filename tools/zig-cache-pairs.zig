const std = @import("std");
const Cache = std.Build.Cache;
const Io = std.Io;
const PathPrefix = std.zig.Server.Message.PathPrefix;

const manifest_bytes_max: u32 = std.math.maxInt(u32);
const manifest_directory = "h/";
const output_directories = [_][]const u8{ "o/", "c/" };
const path_bytes_max: usize = 4096;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("Usage: zig-cache-pairs CACHE_DIRECTORY < MANIFEST_PATHS\n", .{});
        return error.InvalidUsage;
    }
    var cache = try Io.Dir.cwd().openDir(io, args[1], .{});
    defer cache.close(io);
    var input_buffer: [path_bytes_max]u8 = undefined;
    var input = Io.File.stdin().reader(io, &input_buffer);
    var output_buffer: [path_bytes_max]u8 = undefined;
    var output = Io.File.stdout().writer(io, &output_buffer);
    while (try input.interface.takeDelimiter('\n')) |manifest_path| {
        try writePair(io, init.gpa, cache, manifest_path, &output.interface);
    }
    try output.interface.flush();
}

fn writePair(
    io: Io,
    gpa: std.mem.Allocator,
    cache: Io.Dir,
    manifest_path: []const u8,
    writer: *Io.Writer,
) !void {
    try writer.print("{s}\t", .{manifest_path});
    const root = rootOf(manifest_path) orelse return writer.writeByte('\n');
    const limit: Io.Limit = .limited(manifest_bytes_max);
    const contents = try cache.readFileAlloc(io, manifest_path, gpa, limit);
    defer gpa.free(contents);
    var inputs: Io.Writer.Allocating = .init(gpa);
    defer inputs.deinit();
    const name = std.fs.path.basename(manifest_path);
    const digest = scan(name, contents, &inputs.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.InvalidManifest => return writer.writeByte('\n'),
    };
    for (output_directories) |directory| {
        var path_buffer: [path_bytes_max]u8 = undefined;
        const output_path = try std.fmt.bufPrint(&path_buffer, "{s}{s}{s}", .{
            root, directory, &digest,
        });
        if (try exists(io, cache, output_path)) {
            try writer.writeAll(output_path);
            break;
        }
    }
    try writer.writeAll(inputs.written());
    try writer.writeByte('\n');
}

fn rootOf(manifest_path: []const u8) ?[]const u8 {
    const name = std.fs.path.basename(manifest_path);
    const directory_end = manifest_path.len - name.len;
    if (directory_end < manifest_directory.len) return null;
    const root_end = directory_end - manifest_directory.len;
    const directory = manifest_path[root_end..directory_end];
    if (!std.mem.eql(u8, directory, manifest_directory)) return null;
    return manifest_path[0..root_end];
}

fn scan(
    name: []const u8,
    contents: []const u8,
    inputs: *Io.Writer,
) error{ InvalidManifest, WriteFailed }!Cache.HexDigest {
    if (contents.len == 0 or contents[contents.len - 1] != 0) return error.InvalidManifest;
    if (name.len != Cache.hex_digest_len) return error.InvalidManifest;
    var input_digest: Cache.BinDigest = undefined;
    _ = std.fmt.hexToBytes(&input_digest, name) catch return error.InvalidManifest;
    var hasher = Cache.hasher_init;
    hasher.update(&input_digest);
    var offset: usize = 0;
    while (offset + 1 < contents.len) {
        if (offset > std.math.maxInt(u32)) return error.InvalidManifest;
        const file_offset: Cache.Manifest.File.Offset = @fromBackingInt(@as(u32, @intCast(offset)));
        const file = file_offset.getFallibleConst(contents) catch return error.InvalidManifest;
        const path = file_offset.pathFallible(contents) catch return error.InvalidManifest;
        if (path.len == 0) return error.InvalidManifest;
        hasher.update(&file.digest);
        switch (file.flags.prefix) {
            @backingInt(PathPrefix.local_cache), @backingInt(PathPrefix.global_cache) => {
                try inputs.print("\t{s}", .{path});
            },
            else => {},
        }
        offset += Cache.Manifest.File.sizeOf(path.len);
    }
    if (offset + 1 != contents.len) return error.InvalidManifest;
    var digest: Cache.BinDigest = undefined;
    hasher.final(&digest);
    return Cache.binToHex(digest);
}

fn exists(io: Io, cache: Io.Dir, path: []const u8) !bool {
    cache.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}
