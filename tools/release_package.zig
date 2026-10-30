const std = @import("std");
const Dir = std.Io.Dir;
const source = @import("release_source.zig");
const edit = @import("release_edit.zig");

fn build(r: anytype, root: []const u8, step: []const u8, prefix: []const u8) !void {
    _ = try r.run(&.{
        r.zig,
        "build",
        step,
        "-Doptimize=safe",
        "--prefix",
        prefix,
        "--cache-dir",
        try r.path(&.{ r.scratch, "package-build-cache" }),
    }, root, true);
}

fn identity(r: anytype, snapshot: source.Snapshot) ![]const u8 {
    const result = try r.run(&.{ r.zig, "fetch", snapshot.source }, r.scratch, true);
    const actual = std.mem.trim(u8, result.stdout, "\r\n");
    const manifest_path = try r.path(&.{ snapshot.source, "build.zig.zon" });
    const manifest = try edit.manifest(r.a, try r.read(manifest_path));
    const prefix = try std.fmt.allocPrint(r.a, "kosmos-{s}-", .{manifest.version});
    if (!std.mem.startsWith(u8, actual, prefix) or actual.len != prefix.len + 44)
        return error.InvalidPackageIdentity;
    return actual;
}

fn consume(r: anytype, snapshot: source.Snapshot, hash: []const u8) !void {
    const emitted = try r.path(&.{ r.scratch, "emitted" });
    try build(r, snapshot.source, "emit-native-input", emitted);
    const package = try r.path(&.{ r.scratch, "kosmos" });
    const consumer = try r.path(&.{ r.scratch, "consumer" });
    try Dir.cwd().createDir(r.io, package, .fromMode(0o700));
    try Dir.cwd().createDir(r.io, consumer, .fromMode(0o700));
    const archive = try r.path(&.{
        r.scratch, "global", "p", try std.fmt.allocPrint(r.a, "{s}.tar.gz", .{hash}),
    });
    _ = try r.run(&.{
        "tar", "-xzf", archive, "--strip-components=1", "--no-same-owner", "-C", package,
    }, r.scratch, true);
    inline for (.{ "build.zig", "build.zig.zon", "main.zig" }) |file| try r.write(
        try r.path(&.{ consumer, file }),
        try r.read(try r.path(&.{ snapshot.source, "test/native_consumer", file })),
    );
    _ = try r.run(&.{
        r.zig,
        "build",
        "-Doptimize=safe",
        try std.fmt.allocPrint(r.a, "-Dimage={s}", .{
            try r.path(&.{ emitted, "native-consumer.bpi3" }),
        }),
        "--prefix",
        try r.path(&.{ r.scratch, "consumed" }),
        "--cache-dir",
        try r.path(&.{ r.scratch, "consumer-cache" }),
    }, consumer, true);
}

fn verifyRetained(r: anytype, path: []const u8, expected: []const u8) !void {
    const actual = source.readArchive(r, path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    if (!std.mem.eql(u8, actual, expected)) return error.ReleaseArtifactCollision;
}

pub fn manifestFacts(r: anytype, root: []const u8) !struct {
    sha256: []const u8,
    version: []const u8,
    minimumCompiler: []const u8,
    horos: struct { url: []const u8, commit: []const u8, packageIdentity: []const u8 },
} {
    const bytes = try r.read(try r.path(&.{ root, "build.zig.zon" }));
    const manifest = try edit.manifest(r.a, bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{
        .sha256 = try r.a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)),
        .version = manifest.version,
        .minimumCompiler = manifest.minimum_zig_version,
        .horos = .{
            .url = manifest.dependencies.horos.url,
            .commit = try edit.commit(manifest.dependencies.horos.url),
            .packageIdentity = manifest.dependencies.horos.hash,
        },
    };
}

pub fn prepare(
    r: anytype,
    repository: []const u8,
    output: []const u8,
    expected: ?[]const u8,
    build_owned: bool,
) !void {
    const owner = try source.BuildOutput.acquire(r, output);
    defer owner.close(r.io);
    const staging = try r.path(&.{ r.scratch, "publishing" });
    try Dir.cwd().createDir(r.io, staging, .fromMode(0o700));
    const snapshot = try source.prepare(r, repository, staging);
    if (expected) |value| {
        const commit = std.mem.trim(u8, value, "\r\n");
        try edit.hex(commit, 40);
        if (!std.mem.eql(u8, snapshot.commit, commit)) return error.SourceChanged;
    }
    var compiler = try source.CapturedCompiler.acquire(r, r.zig, staging, r.env);
    defer compiler.close(r.io);
    var selected = r;
    selected.zig = compiler.path;
    selected.env = &compiler.env;
    const version = try selected.run(&.{ selected.zig, "version" }, selected.scratch, true);
    if (!std.mem.eql(u8, version.stdout, "0.17.0\n")) return error.CompilerMismatch;
    try selected.checkCoherence(snapshot.source);
    const hash = try identity(selected, snapshot);
    try consume(selected, snapshot, hash);
    const record = try std.json.Stringify.valueAlloc(r.a, .{
        .commit = snapshot.commit,
        .tree = snapshot.tree,
        .archive = "source.tar",
        .sha256 = snapshot.sha256,
        .size = snapshot.size,
        .packageIdentity = hash,
        .files = snapshot.files,
        .compiler = "0.17.0",
        .compilerSha256 = compiler.sha256,
        .compilerPlatform = source.compilerPlatform(),
        .manifest = try manifestFacts(r, snapshot.source),
    }, .{});
    const archive = try source.testedArchive(r, snapshot);
    try r.checkBudget();
    if (build_owned) return owner.retain(r.io, archive, record);
    try Dir.cwd().createDirPath(r.io, output);
    const archive_path = try r.path(&.{ output, "source.tar" });
    const record_path = try r.path(&.{ output, "source.json" });
    try verifyRetained(r, archive_path, archive);
    try verifyRetained(r, record_path, record);
    _ = try source.retain(r, archive_path, archive);
    _ = try source.retain(r, record_path, record);
}
