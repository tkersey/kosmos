const std = @import("std");
const maximum_bytes = 1024 * 1024;
pub const Manifest = struct {
    version: []const u8,
    minimum_zig_version: []const u8,
    dependencies: struct { horos: struct { url: []const u8, hash: []const u8 } },
};

fn bounded(source: [:0]const u8) !void {
    if (source.len > maximum_bytes) return error.ManifestTooLarge;
    var tokenizer = std.zig.Tokenizer.init(source);
    var depth: usize = 0;
    var remaining = source.len + 1;
    while (remaining > 0) : (remaining -= 1) {
        switch (tokenizer.next().tag) {
            .eof => return,
            .invalid => return error.InvalidSource,
            .l_brace, .l_bracket, .l_paren => {
                depth += 1;
                if (depth > 64) return error.SourceTooDeep;
            },
            .r_brace, .r_bracket, .r_paren => depth -|= 1,
            else => {},
        }
    }
    return error.InvalidSource;
}

pub fn version(value: []const u8) !void {
    const selected = std.SemanticVersion.parse(value) catch return error.InvalidVersion;
    if (selected.pre != null or selected.build != null) return error.UnsupportedVersion;
    for ([_]usize{ selected.major, selected.minor, selected.patch }) |part| {
        if (part > 9007199254740991) return error.UnsupportedVersion;
    }
}

pub fn manifest(a: std.mem.Allocator, source: [:0]const u8) !Manifest {
    try bounded(source);
    var ast = try std.zig.Ast.parse(a, source, .{ .mode = .zon });
    defer ast.deinit(a);
    var zoir = try std.zig.ZonGen.generate(a, ast, .{ .parse_str_lits = true });
    defer zoir.deinit(a);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const parsed = try std.zon.parse.fromZoir(Manifest, .{
        .arena = a,
        .ast = &ast,
        .zoir = &zoir,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });
    try version(parsed.version);
    if (!std.mem.eql(u8, parsed.minimum_zig_version, "0.17.0")) return error.CompilerMismatch;
    _ = try commit(parsed.dependencies.horos.url);
    try packageIdentity(parsed.dependencies.horos.hash);
    return parsed;
}

pub fn commit(url: []const u8) ![]const u8 {
    const prefix = "git+https://github.com/tkersey/horos#";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidDependencyUrl;
    const value = url[prefix.len..];
    try hex(value, 40);
    return value;
}

pub fn hex(value: []const u8, length: usize) !void {
    if (value.len != length) return error.InvalidIdentity;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f'))
            return error.InvalidIdentity;
    }
}

pub fn packageIdentity(value: []const u8) !void {
    if (!std.mem.startsWith(u8, value, "horos-") or value.len > 128)
        return error.InvalidPackageIdentity;
    const separator = std.mem.indexOfScalarPos(u8, value, 6, '-') orelse
        return error.InvalidPackageIdentity;
    try version(value[6..separator]);
    const digest = value[separator + 1 ..];
    if (digest.len != 44) return error.InvalidPackageIdentity;
    for (digest) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-')
            return error.InvalidPackageIdentity;
    }
}

fn field(
    a: std.mem.Allocator,
    ast: std.zig.Ast,
    root: std.zig.Ast.Node.Index,
    name: []const u8,
) !std.zig.Ast.Node.Index {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const object = ast.fullStructInit(&buffer, root) orelse return error.InvalidManifestRoot;
    for (object.ast.fields) |node| {
        const token = ast.tokenSlice(ast.firstToken(node) - 2);
        const key = if (std.mem.startsWith(u8, token, "@\""))
            try std.zig.string_literal.parseAlloc(a, token[1..])
        else
            token;
        if (std.mem.eql(u8, key, name)) return node;
    }
    return error.MissingField;
}

fn replaceLiteral(
    a: std.mem.Allocator,
    ast: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    value: []const u8,
) ![]const u8 {
    if (ast.nodeTag(node) != .string_literal) return error.UnsupportedLiteral;
    const token = ast.nodeMainToken(node);
    const literal = ast.tokenSlice(token);
    const previous = try std.zig.string_literal.parseAlloc(a, literal);
    if (std.mem.eql(u8, previous, value)) return ast.source;
    const quoted = try std.fmt.allocPrint(a, "\"{f}\"", .{std.zig.fmtString(value)});
    const start = ast.tokenStart(token);
    return std.mem.concat(a, u8, &.{
        ast.source[0..start], quoted, ast.source[start + literal.len ..],
    });
}

pub fn zon(
    a: std.mem.Allocator,
    source: [:0]const u8,
    path: []const []const u8,
    value: []const u8,
) ![]const u8 {
    _ = try manifest(a, source);
    var ast = try std.zig.Ast.parse(a, source, .{ .mode = .zon });
    defer ast.deinit(a);
    var node = ast.rootDecls()[0];
    for (path) |name| node = try field(a, ast, node, name);
    return replaceLiteral(a, ast, node, value);
}

pub fn declaration(
    a: std.mem.Allocator,
    source: [:0]const u8,
    name: []const u8,
    value: []const u8,
) ![]const u8 {
    try bounded(source);
    var ast = try std.zig.Ast.parse(a, source, .{ .mode = .zig });
    defer ast.deinit(a);
    if (ast.errors.len != 0) return error.InvalidSource;
    var selected: ?std.zig.Ast.Node.Index = null;
    for (ast.rootDecls()) |node| {
        const variable = ast.fullVarDecl(node) orelse continue;
        if (!std.mem.eql(u8, ast.tokenSlice(variable.ast.mut_token + 1), name)) continue;
        if (selected != null) return error.DuplicateBinding;
        selected = variable.ast.init_node.unwrap() orelse return error.MissingInitializer;
    }
    return replaceLiteral(a, ast, selected orelse return error.MissingBinding, value);
}

pub fn jsonVersion(a: std.mem.Allocator, bytes: []const u8, target: []const u8) ![]const u8 {
    try version(target);
    if (bytes.len > maximum_bytes) return error.ManifestTooLarge;
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (parsed != .object) return error.InvalidManifestRoot;
    const previous = parsed.object.get("version") orelse return error.MissingVersion;
    if (previous != .string) return error.InvalidVersion;
    try version(previous.string);
    if (std.mem.eql(u8, previous.string, target)) return bytes;
    try parsed.object.put(a, "version", .{ .string = target });
    const result = try std.json.Stringify.valueAlloc(a, parsed, .{ .whitespace = .indent_2 });
    return std.mem.concat(a, u8, &.{ result, "\n" });
}

const fixture =
    \\.{ .version = "9.1.0", .minimum_zig_version = "0.17.0",
    \\ .dependencies = .{.horos = .{
    \\ .url = "git+https://github.com/tkersey/horos#7d34f2c72e818665be4d519fde4f2cef9c986048",
    \\ .hash = "horos-8.0.0-flclaIItVgCRBCbUEysErcsQyVqsukGf2Q8X2is_wRuU", .lazy=true}},
    \\ .other = .{.version="9.1.0", .hash="unchanged"} }
;

test "semantic edits preserve unrelated manifest fields and unchanged bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(fixture, try zon(a, fixture, &.{"version"}, "9.1.0"));
    const edited = try zon(a, fixture, &.{"version"}, "9.1.1");
    const selected = try manifest(a, try a.dupeSentinel(u8, edited, 0));
    try std.testing.expectEqualStrings("9.1.1", selected.version);
    try std.testing.expect(std.mem.indexOf(u8, edited, ".other = .{.version=\"9.1.0\"") != null);
    try std.testing.expectEqualStrings(
        (try manifest(a, fixture)).dependencies.horos.hash,
        selected.dependencies.horos.hash,
    );
}

test "duplicate or malformed nested dependency fields are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = fixture[0 .. fixture.len - 1];
    const duplicate = try std.mem.concat(a, u8, &.{ prefix, ", .version=\"9.2.0\"}" });
    try std.testing.expectError(error.ParseZon, manifest(a, try a.dupeSentinel(u8, duplicate, 0)));
    try std.testing.expectError(
        error.InvalidDependencyUrl,
        commit("https://github.com/tkersey/horos"),
    );
    try std.testing.expectError(
        error.InvalidIdentity,
        commit("git+https://github.com/tkersey/horos#main"),
    );
    try std.testing.expectError(
        error.InvalidPackageIdentity,
        packageIdentity("horos-8.0.0-madeup"),
    );
}

test "generated declaration edits select exact AST initializers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "pub const hash = \"old\";\nconst other = \"old\";\n";
    try std.testing.expectEqualStrings(source, try declaration(a, source, "hash", "old"));
    try std.testing.expectEqualStrings(
        "pub const hash = \"new\";\nconst other = \"old\";\n",
        try declaration(a, source, "hash", "new"),
    );
    try std.testing.expectError(error.DuplicateBinding, declaration(
        a,
        "const hash=\"a\";const hash=\"b\";",
        "hash",
        "c",
    ));
}

test "JSON mirror updates preserve values and reject duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "{\"version\":\"9.1.0\",\"other\":{\"version\":\"9.1.0\"}}";
    try std.testing.expectEqualStrings(source, try jsonVersion(a, source, "9.1.0"));
    const changed = try jsonVersion(a, source, "9.1.1");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, changed, .{});
    try std.testing.expectEqualStrings("9.1.1", parsed.object.get("version").?.string);
    try std.testing.expectEqualStrings(
        "9.1.0",
        parsed.object.get("other").?.object.get("version").?.string,
    );
    try std.testing.expectError(error.DuplicateField, jsonVersion(
        a,
        "{\"version\":\"9.1.0\",\"version\":\"9.1.0\"}",
        "9.1.1",
    ));
}

pub fn javascriptVersion(a: std.mem.Allocator, source: []const u8, target: []const u8) ![]const u8 {
    try version(target);
    if (source.len > maximum_bytes) return error.ManifestTooLarge;
    const prefix = "export const packageVersion = ";
    var lines = std.mem.splitScalar(u8, source, '\n');
    var offset: usize = 0;
    var selected: ?struct { start: usize, end: usize, version: []const u8 } = null;
    while (lines.next()) |line| {
        const content = std.mem.trimEnd(u8, line, "\r");
        if (selected == null and !std.mem.startsWith(u8, content, prefix)) {
            const before = std.mem.trim(u8, content, " \t");
            if (before.len != 0 and !std.mem.startsWith(u8, before, "//"))
                return error.UnsupportedVersionBinding;
            if (std.mem.indexOfScalar(u8, before, '\r') != null or
                std.mem.indexOf(u8, before, "\xe2\x80\xa8") != null or
                std.mem.indexOf(u8, before, "\xe2\x80\xa9") != null)
                return error.UnsupportedVersionBinding;
        }
        if (std.mem.startsWith(u8, content, prefix)) {
            if (selected != null) return error.DuplicateBinding;
            if (!std.mem.endsWith(u8, content, ";")) return error.UnsupportedLiteral;
            const literal = content[prefix.len .. content.len - 1];
            const previous = std.json.parseFromSliceLeaky([]const u8, a, literal, .{}) catch |err| {
                if (err == error.OutOfMemory) return err;
                return error.UnsupportedLiteral;
            };
            try version(previous);
            selected = .{
                .start = offset + prefix.len,
                .end = offset + content.len - 1,
                .version = previous,
            };
        }
        offset += line.len + 1;
    }
    const binding = selected orelse return error.MissingBinding;
    if (std.mem.eql(u8, binding.version, target)) return source;
    return std.mem.concat(a, u8, &.{
        source[0..binding.start], "\"", target, "\"", source[binding.end..],
    });
}

test "JavaScript version projection owns only the exact export literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = "export const packageVersion = \"9.1.0\";\n" ++
        "export const unrelated = \"9.1.0\";\n";
    try std.testing.expectEqualStrings(original, try javascriptVersion(a, original, "9.1.0"));
    try std.testing.expectEqualStrings(
        "export const packageVersion = \"9.1.1\";\n" ++
            "export const unrelated = \"9.1.0\";\n",
        try javascriptVersion(a, original, "9.1.1"),
    );
    const commented = try std.mem.concat(a, u8, &.{ "/*\n", original, "*/\n" });
    try std.testing.expectError(
        error.UnsupportedVersionBinding,
        javascriptVersion(a, commented, "9.1.1"),
    );
    const duplicate = try std.mem.concat(a, u8, &.{ original, original });
    try std.testing.expectError(error.DuplicateBinding, javascriptVersion(a, duplicate, "9.1.1"));
    try std.testing.expectError(error.UnsupportedLiteral, javascriptVersion(
        a,
        "export const packageVersion = \"9.1.0\" + value;\n",
        "9.1.1",
    ));
}
