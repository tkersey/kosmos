const std = @import("std");
const Dir = std.Io.Dir;
const source = @import("release_source.zig");
const edit = @import("release_edit.zig");
const package = @import("release_package.zig");
const maximum_bytes = 64 << 20;

comptime {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0"))
        @compileError("Zig 0.17.0 is required");
}
const version_paths = [_][]const u8{
    "build.zig.zon", "package.json", "src/root.zig", "src/embedding/index.mjs",
};
const allowed = version_paths ++ [_][]const u8{
    "src/semantic-core.kar", "src/semantic_packaged.zig",
};
const Projection = struct { path: []const u8, bytes: []const u8 };
const Generated = struct { artifact: []const u8, packaged: []const u8 };

const Horos = struct {
    commit: []const u8,
    tree: []const u8,
    url: []const u8,
    packageIdentity: []const u8,
    sourceArchive: []const u8,
    sourceRepository: []const u8,
    sha256: []const u8,
    size: u64,
};
const Input = struct {
    schema: []const u8,
    baseCommit: []const u8,
    baseTree: []const u8,
    version: []const u8,
    horos: Horos,
};

const Runner = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    zig: []const u8,
    scratch: []const u8,
    deadline: std.Io.Clock.Timestamp,

    pub fn checkBudget(r: Runner) !void {
        if (r.deadline.durationFromNow(r.io).raw.nanoseconds <= 0)
            return error.QualificationDeadline;
    }
    pub fn path(r: Runner, parts: []const []const u8) ![]const u8 {
        return std.fs.path.join(r.a, parts);
    }
    pub fn run(
        r: Runner,
        argv: []const []const u8,
        cwd: []const u8,
        success: bool,
    ) !std.process.RunResult {
        try r.checkBudget();
        const result = try std.process.run(r.a, r.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = r.env,
            .stdout_limit = .limited(maximum_bytes),
            .stderr_limit = .limited(8 << 20),
            .timeout = .{ .deadline = r.deadline },
        });
        if (result.term != .exited or (result.term.exited == 0) != success) {
            std.debug.print("{s}\n", .{result.stderr});
            return error.ProcessFailed;
        }
        return result;
    }
    pub fn write(r: Runner, path_name: []const u8, bytes: []const u8) !void {
        var file = Dir.cwd().openFile(r.io, path_name, .{
            .mode = .read_write,
            .follow_symlinks = false,
            .allow_directory = false,
        }) catch |err| file: {
            if (err != error.FileNotFound) return err;
            break :file try Dir.cwd().createFile(r.io, path_name, .{ .exclusive = true });
        };
        defer file.close(r.io);
        if ((try file.stat(r.io)).kind != .file) return error.UnsupportedSourceKind;
        try file.setLength(r.io, 0);
        try file.writeStreamingAll(r.io, bytes);
    }
    pub fn read(r: Runner, path_name: []const u8) ![:0]const u8 {
        return r.a.dupeSentinel(u8, try source.readArchive(r, path_name), 0);
    }
    pub fn checkCoherence(r: Runner, root: []const u8) !void {
        try coherence(r, root);
    }
};

fn parseInput(r: Runner, path: []const u8) !Input {
    const bytes = try r.read(path);
    if (bytes.len > 1024 * 1024) return error.InputTooLarge;
    const selected = try std.json.parseFromSliceLeaky(Input, r.a, bytes, .{});
    if (!std.mem.eql(u8, selected.schema, "kosmos-refresh/v1")) return error.UnsupportedSchema;
    try edit.hex(selected.baseCommit, 40);
    try edit.hex(selected.baseTree, 40);
    try edit.version(selected.version);
    try edit.hex(selected.horos.commit, 40);
    try edit.hex(selected.horos.tree, 40);
    try edit.hex(selected.horos.sha256, 64);
    try edit.packageIdentity(selected.horos.packageIdentity);
    if (!std.mem.eql(u8, try edit.commit(selected.horos.url), selected.horos.commit))
        return error.DependencyCommitMismatch;
    if (selected.horos.size == 0 or selected.horos.size > maximum_bytes)
        return error.InvalidArchiveSize;
    const paths = [_][]const u8{ selected.horos.sourceArchive, selected.horos.sourceRepository };
    for (paths) |path_name| {
        if (!std.fs.path.isAbsolute(path_name)) return error.AbsolutePathRequired;
    }
    return selected;
}

fn digest(r: Runner, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return r.a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}

fn authenticate(r: Runner, selected: Horos) ![]const u8 {
    const admitted = try source.verify(
        r,
        selected.sourceRepository,
        selected.commit,
        selected.tree,
        selected.sourceArchive,
        try r.path(&.{ r.scratch, "horos" }),
    );
    if (!std.mem.eql(u8, admitted.sha256, selected.sha256) or admitted.size != selected.size)
        return error.ArchiveIdentityMismatch;
    const fetched = try r.run(&.{ r.zig, "fetch", admitted.source }, r.scratch, true);
    const identity = std.mem.trim(u8, fetched.stdout, "\r\n");
    if (!std.mem.eql(u8, identity, selected.packageIdentity)) return error.PackageIdentityMismatch;
    return admitted.source;
}

fn updateManifest(r: Runner, root: []const u8, input: Input) ![version_paths.len]Projection {
    const path = try r.path(&.{ root, "build.zig.zon" });
    var bytes = try r.read(path);
    const original = try edit.manifest(r.a, bytes);
    const before = try std.SemanticVersion.parse(original.version);
    const after = try std.SemanticVersion.parse(input.version);
    if (before.order(after) == .gt) return error.VersionDowngrade;
    inline for (.{
        .{ &.{"version"}, input.version },
        .{ &.{ "dependencies", "horos", "url" }, input.horos.url },
        .{ &.{ "dependencies", "horos", "hash" }, input.horos.packageIdentity },
    }) |change| {
        bytes = try r.a.dupeSentinel(u8, try edit.zon(r.a, bytes, change[0], change[1]), 0);
    }
    _ = try edit.manifest(r.a, bytes);
    try r.write(path, bytes);
    const mirror = try r.path(&.{ root, "package.json" });
    try r.write(mirror, try edit.jsonVersion(r.a, try r.read(mirror), input.version));
    const native = try r.path(&.{ root, "src/root.zig" });
    const native_version = try edit.declaration(
        r.a,
        try r.read(native),
        "package_version",
        input.version,
    );
    try r.write(native, native_version);
    const javascript = try r.path(&.{ root, "src/embedding/index.mjs" });
    try r.write(javascript, try edit.javascriptVersion(r.a, try r.read(javascript), input.version));
    var projected: [version_paths.len]Projection = undefined;
    for (version_paths, &projected) |name, *file| {
        file.* = .{ .path = name, .bytes = try r.read(try r.path(&.{ root, name })) };
    }
    return projected;
}

fn buildArtifact(r: Runner, root: []const u8, horos: ?[]const u8) ![]const u8 {
    const prefix = try r.path(&.{ r.scratch, "built" });
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(r.a, &.{
        r.zig,
        "build",
        "semantic-artifact",
        "-Doptimize=safe",
        "--prefix",
        prefix,
        "--cache-dir",
        try r.path(&.{ r.scratch, "build-cache" }),
    });
    if (horos) |path| {
        try args.append(r.a, try std.fmt.allocPrint(r.a, "-Dhoros-source={s}", .{path}));
    }
    _ = try r.run(args.items, root, true);
    return r.read(try r.path(&.{ prefix, "semantic-core.kar" }));
}

fn identitySource(r: Runner, root: []const u8) ![]const u8 {
    const destination = try r.path(&.{ r.scratch, "identity-source" });
    try Dir.cwd().deleteTree(r.io, destination);
    try Dir.cwd().createDir(r.io, destination, .fromMode(0o700));
    var source_dir = try Dir.cwd().openDir(r.io, try r.path(&.{ root, "src" }), .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer source_dir.close(r.io);
    var walker = try source_dir.walk(r.a);
    defer walker.deinit();
    var files: usize = 0;
    var bytes: usize = 0;
    while (try walker.next(r.io)) |entry| {
        const output = try r.path(&.{ destination, entry.path });
        if (entry.kind == .directory) {
            try Dir.cwd().createDirPath(r.io, output);
            continue;
        }
        if (entry.kind != .file) return error.UnsupportedSourceKind;
        files += 1;
        if (files > 10000) return error.SourceTooLarge;
        const content = try r.read(try r.path(&.{ root, "src", entry.path }));
        bytes = try std.math.add(usize, bytes, content.len);
        if (bytes > maximum_bytes) return error.SourceTooLarge;
        try r.write(output, content);
    }
    return destination;
}

fn sourceIdentity(r: Runner, root: []const u8) ![]const u8 {
    const copy = try identitySource(r, root);
    const helper = try r.path(&.{ copy, "release-identity.zig" });
    _ = try source.retain(r, helper, @embedFile("release_identity.zig"));
    const result = try r.run(&.{
        r.zig,         "run",                                         "-OReleaseSafe", helper,
        "--cache-dir", try r.path(&.{ r.scratch, "identity-cache" }),
    }, r.scratch, true);
    try edit.hex(result.stdout, 64);
    return result.stdout;
}

fn regenerate(
    r: Runner,
    root: []const u8,
    horos: []const u8,
    identity: []const u8,
    original: [:0]const u8,
) !Generated {
    const artifact = try buildArtifact(r, root, horos);
    try r.write(try r.path(&.{ root, "src/semantic-core.kar" }), artifact);
    const path = try r.path(&.{ root, "src/semantic_packaged.zig" });
    var bytes = original;
    inline for (.{
        .{ "horos_package", identity },
        .{ "source_sha256", try sourceIdentity(r, root) },
        .{ "artifact_sha256", try digest(r, artifact) },
    }) |change| {
        bytes = try r.a.dupeSentinel(u8, try edit.declaration(r.a, bytes, change[0], change[1]), 0);
    }
    try r.write(path, bytes);
    return .{ .artifact = artifact, .packaged = bytes };
}

fn validateProjection(r: Runner, root: []const u8, projected: []const Projection) !void {
    for (projected) |expected| {
        const actual = try r.read(try r.path(&.{ root, expected.path }));
        if (!std.mem.eql(u8, expected.bytes, actual)) return error.ForbiddenCandidateChange;
    }
}

fn readJson(r: Runner, root: []const u8, name: []const u8) !std.json.Value {
    const bytes = try r.read(try r.path(&.{ root, name }));
    if (bytes.len > 1024 * 1024) return error.InputTooLarge;
    return std.json.parseFromSliceLeaky(std.json.Value, r.a, bytes, .{});
}

fn profiles(r: Runner, root: []const u8) !void {
    const build = try readJson(r, root, "build-profile.json");
    const runtime = try readJson(r, root, "src/node/runtime-profile.json");
    if (build != .object or runtime != .object) return error.InvalidProfile;
    const compiler = build.object.get("zig") orelse return error.InvalidProfile;
    if (compiler != .string or !std.mem.eql(u8, compiler.string, "0.17.0"))
        return error.CompilerMismatch;
    var fields = build.object.iterator();
    while (fields.next()) |entry| {
        const counterpart = runtime.object.get(entry.key_ptr.*) orelse return error.ProfileMismatch;
        const expected = try std.json.Stringify.valueAlloc(r.a, entry.value_ptr.*, .{});
        const actual = try std.json.Stringify.valueAlloc(r.a, counterpart, .{});
        if (!std.mem.eql(u8, expected, actual)) return error.ProfileMismatch;
    }
}

fn coherence(r: Runner, root: []const u8) !void {
    const manifest = try edit.manifest(r.a, try r.read(try r.path(&.{ root, "build.zig.zon" })));
    const mirror = try readJson(r, root, "package.json");
    if (mirror != .object) return error.InvalidVersionMirror;
    const version = mirror.object.get("version") orelse return error.InvalidVersionMirror;
    if (version != .string or !std.mem.eql(u8, manifest.version, version.string))
        return error.VersionMirrorMismatch;
    const native = try r.read(try r.path(&.{ root, "src/root.zig" }));
    const native_version = try edit.declaration(r.a, native, "package_version", manifest.version);
    if (!std.mem.eql(u8, native, native_version))
        return error.VersionMirrorMismatch;
    const javascript = try r.read(try r.path(&.{ root, "src/embedding/index.mjs" }));
    if (!std.mem.eql(u8, javascript, try edit.javascriptVersion(r.a, javascript, manifest.version)))
        return error.VersionMirrorMismatch;
    try profiles(r, root);
    const packaged = try r.read(try r.path(&.{ root, "src/semantic_packaged.zig" }));
    const artifact = try r.read(try r.path(&.{ root, "src/semantic-core.kar" }));
    inline for (.{
        .{ "horos_package", manifest.dependencies.horos.hash },
        .{ "source_sha256", try sourceIdentity(r, root) },
        .{ "artifact_sha256", try digest(r, artifact) },
    }) |binding| {
        const projected = try edit.declaration(r.a, packaged, binding[0], binding[1]);
        if (!std.mem.eql(u8, projected, packaged)) return error.GeneratedBindingMismatch;
    }
}

fn allowedPath(path: []const u8) bool {
    for (allowed) |candidate| if (std.mem.eql(u8, path, candidate)) return true;
    return false;
}

fn validateDiff(r: Runner, base: source.Snapshot) ![]const []const u8 {
    var changes: std.ArrayList([]const u8) = .empty;
    var indexed: std.StringHashMapUnmanaged(source.File) = .empty;
    defer indexed.deinit(r.a);
    var directories: std.StringHashMapUnmanaged(void) = .empty;
    defer directories.deinit(r.a);
    for (base.files) |file| {
        try indexed.put(r.a, file.path, file);
        for (file.path, 0..) |byte, offset| {
            if (byte == '/') try directories.put(r.a, file.path[0..offset], {});
        }
    }
    var root = try Dir.cwd().openDir(r.io, base.source, .{ .iterate = true });
    defer root.close(r.io);
    var walker = try root.walk(r.a);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(r.io)) |entry| {
        if (entry.kind == .directory) {
            if (!directories.contains(entry.path)) {
                std.debug.print("unexpected candidate directory: {s}", .{entry.path});
                return error.UnexpectedCandidatePath;
            }
            continue;
        }
        if (entry.kind != .file) return error.UnexpectedCandidateKind;
        const original = indexed.get(entry.path) orelse {
            std.debug.print("unexpected candidate path: {s}", .{entry.path});
            return error.UnexpectedCandidatePath;
        };
        const path = try r.path(&.{ base.source, entry.path });
        const stat = try Dir.cwd().statFile(r.io, path, .{ .follow_symlinks = false });
        if (stat.permissions.toMode() & 0o7777 != original.mode) return error.CandidateModeChanged;
        const bytes = try r.read(path);
        var hash = std.crypto.hash.Sha1.init(.{});
        hash.update(try std.fmt.allocPrint(r.a, "blob {d}\x00", .{bytes.len}));
        hash.update(bytes);
        if (!std.mem.eql(u8, original.blob, &std.fmt.bytesToHex(hash.finalResult(), .lower))) {
            if (!allowedPath(entry.path)) return error.ForbiddenCandidateChange;
            try changes.append(r.a, try r.a.dupe(u8, entry.path));
        }
        count += 1;
        if (count > base.files.len) return error.UnexpectedCandidatePath;
    }
    if (count != base.files.len) return error.MissingCandidatePath;
    std.mem.sort([]const u8, changes.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return changes.toOwnedSlice(r.a);
}

fn stageCandidate(r: Runner, output: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(output) orelse return error.InvalidOutputPath;
    var random: [16]u8 = undefined;
    r.io.random(&random);
    const candidate = try r.path(&.{
        parent,
        try std.fmt.allocPrint(r.a, ".kosmos-refresh-{s}", .{std.fmt.bytesToHex(random, .lower)}),
    });
    try Dir.cwd().createDir(r.io, candidate, .fromMode(0o700));
    return candidate;
}

fn prepare(r: Runner, repository: []const u8, input_path: []const u8, output: []const u8) !void {
    if (Dir.cwd().statFile(r.io, output, .{ .follow_symlinks = false })) |_| {
        return error.OutputAlreadyExists;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }
    const input = try parseInput(r, input_path);
    const candidate = try stageCandidate(r, output);
    defer Dir.cwd().deleteTree(r.io, candidate) catch |err|
        std.log.err("candidate cleanup failed: {s}", .{@errorName(err)});
    const base = try source.prepare(r, repository, candidate);
    if (!std.mem.eql(u8, base.commit, input.baseCommit) or
        !std.mem.eql(u8, base.tree, input.baseTree)) return error.BaseChanged;
    const horos = try authenticate(r, input.horos);
    try coherence(r, base.source);
    const packaged_path = try r.path(&.{ base.source, "src/semantic_packaged.zig" });
    const original_packaged = try r.read(packaged_path);
    const versions = try updateManifest(r, base.source, input);
    const generated = try regenerate(
        r,
        base.source,
        horos,
        input.horos.packageIdentity,
        original_packaged,
    );
    try validateProjection(r, base.source, &versions);
    try validateProjection(r, base.source, &.{
        .{ .path = "src/semantic-core.kar", .bytes = generated.artifact },
        .{ .path = "src/semantic_packaged.zig", .bytes = generated.packaged },
    });
    try coherence(r, base.source);
    const changes = try validateDiff(r, base);
    const record = try std.json.Stringify.valueAlloc(r.a, .{
        .schema = "kosmos-refresh-result/v1",
        .baseCommit = input.baseCommit,
        .baseTree = input.baseTree,
        .version = input.version,
        .horosCommit = input.horos.commit,
        .horosTree = input.horos.tree,
        .horosPackageIdentity = input.horos.packageIdentity,
        .changed = changes,
    }, .{});
    try r.write(try r.path(&.{ candidate, "result.json" }), record);
    try Dir.cwd().deleteFile(r.io, base.archive);
    try r.checkBudget();
    try Dir.cwd().renamePreserve(candidate, Dir.cwd(), output, r.io);
    try std.Io.File.stdout().writeStreamingAll(r.io, record);
}

fn execute(r: Runner, args: *std.process.Args.Iterator) !void {
    const command = args.next() orelse return error.MissingCommand;
    _ = args.next() orelse return error.MissingCompiler;
    const repository = args.next() orelse return error.MissingRepository;
    if (!std.fs.path.isAbsolute(repository)) return error.AbsolutePathRequired;
    const compiler = try r.run(&.{ r.zig, "version" }, r.scratch, true);
    if (!std.mem.eql(u8, compiler.stdout, "0.17.0\n")) return error.CompilerMismatch;
    if (std.mem.eql(u8, command, "manifest")) {
        if (args.next() != null) return error.UnexpectedArgument;
        const facts = try package.manifestFacts(r, repository);
        const bytes = try std.json.Stringify.valueAlloc(r.a, facts, .{});
        try std.Io.File.stdout().writeStreamingAll(r.io, bytes);
    } else if (std.mem.eql(u8, command, "check")) {
        if (args.next() != null) return error.UnexpectedArgument;
        try coherence(r, repository);
    } else if (std.mem.eql(u8, command, "source") or std.mem.eql(u8, command, "source-build")) {
        const output = args.next() orelse return error.MissingOutput;
        const expected = args.next();
        if (args.next() != null) return error.UnexpectedArgument;
        if (!std.fs.path.isAbsolute(output)) return error.AbsolutePathRequired;
        const build_owned = std.mem.eql(u8, command, "source-build");
        try package.prepare(r, repository, output, expected, build_owned);
    } else if (std.mem.eql(u8, command, "prepare")) {
        const input = args.next() orelse return error.MissingInput;
        const output = args.next() orelse return error.MissingOutput;
        if (args.next() != null) return error.UnexpectedArgument;
        if (!std.fs.path.isAbsolute(output)) return error.AbsolutePathRequired;
        try prepare(r, repository, input, output);
    } else return error.UnknownCommand;
}

pub fn main(init: std.process.Init) !void {
    const deadline = std.Io.Clock.Timestamp.fromNow(init.io, .{
        .raw = .fromSeconds(600),
        .clock = .awake,
    });
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.next();
    var probe = args;
    _ = probe.next() orelse return error.MissingCommand;
    const zig = probe.next() orelse return error.MissingCompiler;
    if (!std.fs.path.isAbsolute(zig)) return error.AbsolutePathRequired;
    const temporary_root = init.environ_map.get("TMPDIR") orelse "/tmp";
    if (!std.fs.path.isAbsolute(temporary_root)) return error.AbsolutePathRequired;
    const template = try std.fs.path.join(a, &.{ temporary_root, "kosmos-refresh.XXXXXXXX" });
    const temp = try std.process.run(a, init.io, .{ .argv = &.{ "mktemp", "-d", template } });
    if (temp.term != .exited or temp.term.exited != 0) return error.TemporaryDirectoryFailed;
    const scratch = std.mem.trim(u8, temp.stdout, "\r\n");
    defer Dir.cwd().deleteTree(init.io, scratch) catch |err|
        std.log.err("temporary cleanup failed: {s}", .{@errorName(err)});
    var env = std.process.Environ.Map.init(a);
    if (init.environ_map.get("PATH")) |path| try env.put("PATH", path);
    try env.put("HOME", scratch);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("ZIG_GLOBAL_CACHE_DIR", try std.fs.path.join(a, &.{ scratch, "global" }));
    try env.put("ZIG_LOCAL_CACHE_DIR", try std.fs.path.join(a, &.{ scratch, "local" }));
    try env.put("ZIG_LOCAL_PKG_DIR", try std.fs.path.join(a, &.{ scratch, "packages" }));
    const runner: Runner = .{
        .a = a,
        .io = init.io,
        .env = &env,
        .zig = zig,
        .scratch = scratch,
        .deadline = deadline,
    };
    try execute(runner, &args);
    try runner.checkBudget();
}

test {
    _ = edit;
    _ = source;
}

fn testRunner(
    a: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    env: *std.process.Environ.Map,
) !Runner {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path);
    return .{
        .a = a,
        .io = std.testing.io,
        .env = env,
        .zig = "/unused-zig",
        .scratch = try a.dupe(u8, path[0..length]),
        .deadline = .fromNow(std.testing.io, .{ .raw = .fromSeconds(600), .clock = .awake }),
    };
}

const input_fixture: Input = .{
    .schema = "kosmos-refresh/v1",
    .baseCommit = "0000000000000000000000000000000000000000",
    .baseTree = "1111111111111111111111111111111111111111",
    .version = "9.1.1",
    .horos = .{
        .commit = "2222222222222222222222222222222222222222",
        .tree = "3333333333333333333333333333333333333333",
        .url = "git+https://github.com/tkersey/horos#2222222222222222222222222222222222222222",
        .packageIdentity = "horos-8.0.0-flclaIItVgCRBCbUEysErcsQyVqsukGf2Q8X2is_wRuU",
        .sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .size = 1,
        .sourceArchive = "/archive.tar",
        .sourceRepository = "/repository",
    },
};

test "candidate staging belongs to the output parent independently of scratch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    var destination = std.testing.tmpDir(.{});
    defer destination.cleanup();
    var env = std.process.Environ.Map.init(a);
    const r = try testRunner(a, scratch, &env);
    const parent = try destination.dir.realPathFileAlloc(r.io, ".", a);
    const output = try r.path(&.{ parent, "prepared" });
    const candidate = try stageCandidate(r, output);
    defer Dir.cwd().deleteTree(r.io, candidate) catch |err|
        std.log.err("candidate cleanup failed: {s}", .{@errorName(err)});
    try std.testing.expectEqualStrings(parent, std.fs.path.dirname(candidate).?);
    try std.testing.expect(!std.mem.eql(u8, parent, r.scratch));
    const retained = try r.path(&.{ parent, "retained" });
    try r.write(retained, "untouched");
    try r.write(try r.path(&.{ candidate, "result.json" }), "complete");
    try std.testing.expectError(
        error.FileNotFound,
        Dir.cwd().statFile(r.io, output, .{ .follow_symlinks = false }),
    );
    try Dir.cwd().renamePreserve(candidate, Dir.cwd(), output, r.io);
    try std.testing.expectEqualStrings("complete", try r.read(try r.path(&.{
        output, "result.json",
    })));
    try std.testing.expectEqualStrings("untouched", try r.read(retained));
}

test "candidate publication preserves an output created after staging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var env = std.process.Environ.Map.init(a);
    const r = try testRunner(a, temp, &env);
    const output = try r.path(&.{ r.scratch, "prepared" });
    const candidate = try stageCandidate(r, output);
    defer Dir.cwd().deleteTree(r.io, candidate) catch |err|
        std.log.err("candidate cleanup failed: {s}", .{@errorName(err)});
    try r.write(try r.path(&.{ candidate, "result.json" }), "candidate");
    try Dir.cwd().createDir(r.io, output, .fromMode(0o700));
    const record = try r.path(&.{ output, "result.json" });
    try r.write(record, "retained");
    try std.testing.expectError(
        error.PathAlreadyExists,
        Dir.cwd().renamePreserve(candidate, Dir.cwd(), output, r.io),
    );
    try std.testing.expectEqualStrings("retained", try r.read(record));
    try std.testing.expectEqualStrings("candidate", try r.read(try r.path(&.{
        candidate, "result.json",
    })));
}

test "failed preparation cleans only its destination staging directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    var destination = std.testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    var env = std.process.Environ.Map.init(a);
    var r = try testRunner(a, scratch, &env);
    const parent = try destination.dir.realPathFileAlloc(r.io, ".", a);
    const output = try r.path(&.{ parent, "prepared" });
    const input = try r.path(&.{ r.scratch, "input.json" });
    try r.write(input, try std.json.Stringify.valueAlloc(a, input_fixture, .{}));
    try r.write(try r.path(&.{ parent, "retained" }), "untouched");
    r.deadline = .fromNow(r.io, .{ .raw = .fromSeconds(-1), .clock = .awake });
    try std.testing.expectError(error.QualificationDeadline, prepare(r, "/unused", input, output));
    var entries = destination.dir.iterate();
    const retained = (try entries.next(r.io)) orelse return error.MissingRetainedFile;
    try std.testing.expectEqualStrings("retained", retained.name);
    try std.testing.expectEqual(@as(?Dir.Entry, null), try entries.next(r.io));
    try std.testing.expectEqualStrings("untouched", try r.read(try r.path(&.{
        parent, "retained",
    })));
    try std.testing.expectEqualStrings(
        try std.json.Stringify.valueAlloc(a, input_fixture, .{}),
        try r.read(input),
    );
}

test "frozen input rejects mismatched commit duplicate keys and future schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var env = std.process.Environ.Map.init(a);
    const r = try testRunner(a, temp, &env);
    const path = try r.path(&.{ r.scratch, "input.json" });
    const valid = try std.json.Stringify.valueAlloc(a, input_fixture, .{});
    try r.write(path, valid);
    const admitted = try parseInput(r, path);
    try std.testing.expectEqualStrings(input_fixture.horos.commit, admitted.horos.commit);
    var mismatch = input_fixture;
    mismatch.horos.commit = input_fixture.baseCommit;
    try r.write(path, try std.json.Stringify.valueAlloc(a, mismatch, .{}));
    try std.testing.expectError(error.DependencyCommitMismatch, parseInput(r, path));
    mismatch = input_fixture;
    mismatch.schema = "kosmos-refresh/v2";
    try r.write(path, try std.json.Stringify.valueAlloc(a, mismatch, .{}));
    try std.testing.expectError(error.UnsupportedSchema, parseInput(r, path));
    try r.write(path, try std.mem.concat(a, u8, &.{
        valid[0 .. valid.len - 1], ",\"version\":\"9.1.1\"}",
    }));
    try std.testing.expectError(error.DuplicateField, parseInput(r, path));
    try std.testing.expectError(
        error.OutputAlreadyExists,
        prepare(r, "/unused", "/unused", r.scratch),
    );
}

fn testFile(r: Runner, name: []const u8, bytes: []const u8) !source.File {
    const path = try r.path(&.{ r.scratch, name });
    try r.write(path, bytes);
    var file = try Dir.cwd().openFile(r.io, path, .{});
    defer file.close(r.io);
    try file.setPermissions(r.io, .fromMode(0o644));
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(try std.fmt.allocPrint(r.a, "blob {d}\x00", .{bytes.len}));
    hash.update(bytes);
    return .{
        .path = name,
        .mode = 0o644,
        .blob = try r.a.dupe(u8, &std.fmt.bytesToHex(hash.finalResult(), .lower)),
    };
}

test "complete candidate diff excludes control changes extra files and permission drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var env = std.process.Environ.Map.init(a);
    const r = try testRunner(a, temp, &env);
    const files = [_]source.File{
        try testFile(r, "build.zig.zon", "manifest"),
        try testFile(r, "build.zig", "control"),
    };
    const base: source.Snapshot = .{
        .files = &files,
        .source = r.scratch,
        .archive = "",
        .sha256 = "",
        .size = 0,
        .commit = input_fixture.baseCommit,
        .tree = input_fixture.baseTree,
    };
    try std.testing.expectEqual(@as(usize, 0), (try validateDiff(r, base)).len);
    try r.write(try r.path(&.{ r.scratch, "build.zig.zon" }), "changed");
    try std.testing.expectEqualStrings("build.zig.zon", (try validateDiff(r, base))[0]);
    try r.write(try r.path(&.{ r.scratch, "build.zig" }), "forbidden");
    try std.testing.expectError(error.ForbiddenCandidateChange, validateDiff(r, base));
    try r.write(try r.path(&.{ r.scratch, "build.zig" }), "control");
    const extra = try r.path(&.{ r.scratch, "extra" });
    try r.write(extra, "extra");
    try std.testing.expectError(error.UnexpectedCandidatePath, validateDiff(r, base));
    try Dir.cwd().deleteFile(r.io, extra);
    var file = try Dir.cwd().openFile(r.io, try r.path(&.{ r.scratch, "build.zig" }), .{});
    defer file.close(r.io);
    try file.setPermissions(r.io, .fromMode(0o755));
    try std.testing.expectError(error.CandidateModeChanged, validateDiff(r, base));
    try Dir.cwd().deleteFile(r.io, try r.path(&.{ r.scratch, "build.zig" }));
    try std.testing.expectError(error.MissingCandidatePath, validateDiff(r, base));
}

test "coherence rejects version mirror and profile mismatch without release lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var env = std.process.Environ.Map.init(a);
    const r = try testRunner(a, temp, &env);
    try r.write(try r.path(&.{ r.scratch, "build.zig.zon" }),
        \\.{.version="9.1.0",.minimum_zig_version="0.17.0",.dependencies=.{.horos=.{
        \\.url="git+https://github.com/tkersey/horos#2222222222222222222222222222222222222222",
        \\.hash="horos-8.0.0-flclaIItVgCRBCbUEysErcsQyVqsukGf2Q8X2is_wRuU"}}}
    );
    try r.write(try r.path(&.{ r.scratch, "package.json" }), "{\"version\":\"9.1.1\"}");
    try std.testing.expectError(error.VersionMirrorMismatch, coherence(r, r.scratch));
    try r.write(try r.path(&.{ r.scratch, "package.json" }), "{\"version\":\"9.1.0\"}");
    try Dir.cwd().createDirPath(r.io, try r.path(&.{ r.scratch, "src/embedding" }));
    const native = try r.path(&.{ r.scratch, "src/root.zig" });
    try r.write(native, "pub const package_version = \"9.1.1\";\n");
    try std.testing.expectError(error.VersionMirrorMismatch, coherence(r, r.scratch));
    try r.write(native, "pub const package_version = \"9.1.0\";\n");
    try r.write(
        try r.path(&.{ r.scratch, "src/embedding/index.mjs" }),
        "export const packageVersion = \"9.1.1\";\n",
    );
    try std.testing.expectError(error.VersionMirrorMismatch, coherence(r, r.scratch));
    try Dir.cwd().createDirPath(r.io, try r.path(&.{ r.scratch, "src/node" }));
    try r.write(
        try r.path(&.{ r.scratch, "build-profile.json" }),
        "{\"zig\":\"0.17.0\",\"target\":\"wasm32-freestanding\"}",
    );
    const profile_path = try r.path(&.{ r.scratch, "src/node/runtime-profile.json" });
    try r.write(
        profile_path,
        "{\"zig\":\"0.17.0\",\"target\":\"wasm32-freestanding\",\"boundary\":{\"legacy\":true}}",
    );
    try profiles(r, r.scratch);
    try r.write(profile_path, "{\"zig\":\"0.17.0\",\"target\":\"other\"}");
    try std.testing.expectError(error.ProfileMismatch, profiles(r, r.scratch));
}

test "semantic projections reject unrelated changes inside an allowed file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var env = std.process.Environ.Map.init(a);
    const r = try testRunner(a, temp, &env);
    const projected = [_]Projection{.{
        .path = "package.json",
        .bytes = "{\"version\":\"9.1.1\",\"private\":false}",
    }};
    const path = try r.path(&.{ r.scratch, "package.json" });
    try r.write(path, projected[0].bytes);
    try validateProjection(r, r.scratch, &projected);
    try r.write(path, "{\"version\":\"9.1.1\",\"private\":true}");
    try std.testing.expectError(
        error.ForbiddenCandidateChange,
        validateProjection(r, r.scratch, &projected),
    );
}

test "all native subprocesses retain one nonrenewable qualification deadline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var env = std.process.Environ.Map.init(a);
    var r = try testRunner(a, temp, &env);
    r.deadline = .fromNow(r.io, .{ .raw = .fromSeconds(-1), .clock = .awake });
    try std.testing.expectError(
        error.QualificationDeadline,
        r.run(&.{"must-not-execute"}, r.scratch, true),
    );
}

test "candidate writers reject substituted symlinks and truncate only regular files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var env = std.process.Environ.Map.init(a);
    const r = try testRunner(a, temp, &env);
    const outside = try r.path(&.{ r.scratch, "outside" });
    const projected = try r.path(&.{ r.scratch, "projected" });
    try r.write(outside, "retained");
    try Dir.cwd().symLink(r.io, outside, projected, .{});
    try std.testing.expectError(error.SymLinkLoop, r.write(projected, "corrupted"));
    try std.testing.expectEqualStrings("retained", try r.read(outside));
    try Dir.cwd().deleteFile(r.io, projected);
    try r.write(projected, "long initial value");
    try r.write(projected, "short");
    try std.testing.expectEqualStrings("short", try r.read(projected));
}
