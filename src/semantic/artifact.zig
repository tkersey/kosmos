//! Reproducible evaluator content. Admission checks content and requirements;
//! the enclosing owner separately decides which exact content it approves.
const std = @import("std");
const data = @import("horos_data");
const projection = @import("projection.zig");
const profile = @import("../base/profile.zig");
const service = @import("service.zig");
const Prepared = @import("../interpreter_v2/prepared.zig").Prepared;

pub const identity = "kosmos.semantic-artifact/2";
pub const derived_identity = "kosmos.semantic-artifact/3";
pub const derived_policy = "kosmos.source-relation/1";
pub const admission_profile = "kosmos.horos-admission/3";
pub const build_policy = "kosmos.source-lower/2";
pub const Digest = [32]u8;
pub const Requirements = struct { base: []const u8, admission: []const u8, bridge: []const u8 };
pub const Inventory = struct {
    opcodes: []const data.program.Opcode,
    terminators: []const data.program.TerminatorTag,
    schemas: []const data.program.SchemaTag,
    instructions: u64,
    blocks: u64,
    functions: u64,
};
pub const Manifest = struct {
    contract: []const u8 = identity,
    image: Digest,
    source: Digest,
    compiler: struct { horos_package: []const u8, zig: []const u8, policy: []const u8 },
    requirements: Requirements,
    bridge: data.program.Effect,
    inventory: Inventory,
};
pub const Helper = struct { image: []const u8, inventory: Inventory };
pub const Role = enum {
    published_service,
    committed_service,
    committed_machine,
    clone_context,
    clone_rebase,
};
pub const Parameter = struct { ordinal: u64, slot: data.program.Id, schema: data.program.Id };
pub const Anchor = struct { function: data.program.Id, role: Role, parameters: []const Parameter };
pub const Layout = struct {
    service_machine: u64 = 0,
    machine_program: u64 = 0,
    clone_machine: u64 = 0,
};
pub const Lineage = struct {
    root: Digest,
    parent: Digest,
    generic_source: Digest,
    selected_source: Digest,
    checker: []const u8,
    input: enum { program_and_initial, initial },
};
pub const Recovery = struct {
    projector: Helper,
    storage: Helper,
    clone_context: Helper,
    clone_rebase: Helper,
    anchors: []const Anchor,
    layout: Layout = .{},
};
pub const Bundle = struct {
    manifest: Manifest,
    image: []const u8,
    guest: ?Digest,
    specialization: ?Digest,
    hooks: service.instrumentation.Hooks = .{},
    recovery: Recovery,
    branch_returns: []const data.program.Id,
    template_entries: []const data.program.Id,
    /// Host compiler evidence is retained for independent inspection. It is
    /// content, not an execution grant or a self-issued approval certificate.
    evidence: []const u8,
    lineage: ?Lineage = null,
};

const LegacyBundle = struct {
    manifest: Manifest,
    image: []const u8,
    guest: ?Digest,
    specialization: ?Digest,
    hooks: service.instrumentation.Hooks,
    recovery: struct {
        projector: Helper,
        storage: Helper,
        clone_context: Helper,
        clone_rebase: Helper,
        anchors: []const Anchor,
    },
    branch_returns: []const data.program.Id,
    template_entries: []const data.program.Id,
    evidence: []const u8,
};

pub fn hasProgramArgument(bundle: Bundle) bool {
    if (bundle.lineage) |lineage| return lineage.input == .program_and_initial;
    return bundle.guest == null;
}

pub fn encode(a: std.mem.Allocator, bundle: Bundle) ![]u8 {
    if (std.mem.eql(u8, bundle.manifest.contract, derived_identity))
        return projection.encode(Bundle, a, bundle);
    if (!std.mem.eql(u8, bundle.manifest.contract, identity) or bundle.lineage != null or
        !std.meta.eql(bundle.recovery.layout, Layout{})) return error.UnsupportedArtifact;
    var legacy: LegacyBundle = undefined;
    inline for (comptime std.meta.fieldNames(LegacyBundle)) |name| {
        if (comptime std.mem.eql(u8, name, "recovery")) {
            inline for (comptime std.meta.fieldNames(@FieldType(LegacyBundle, "recovery"))) |field|
                @field(legacy.recovery, field) = @field(bundle.recovery, field);
        } else @field(legacy, name) = @field(bundle, name);
    }
    return projection.encode(LegacyBundle, a, legacy);
}

fn decode(a: std.mem.Allocator, bytes: []const u8) !projection.Owned(Bundle) {
    var reader: data.wire.Reader = .{ .input = bytes };
    const contract = try reader.bytes();
    if (std.mem.eql(u8, contract, derived_identity)) return projection.decode(Bundle, a, bytes);
    if (!std.mem.eql(u8, contract, identity)) return error.UnsupportedArtifact;
    const legacy = try projection.decode(LegacyBundle, a, bytes);
    var bundle: Bundle = undefined;
    inline for (comptime std.meta.fieldNames(LegacyBundle)) |name| {
        if (comptime std.mem.eql(u8, name, "recovery")) {
            inline for (comptime std.meta.fieldNames(@FieldType(LegacyBundle, "recovery"))) |field|
                @field(bundle.recovery, field) = @field(legacy.value.recovery, field);
        } else @field(bundle, name) = @field(legacy.value, name);
    }
    bundle.recovery.layout = .{};
    bundle.lineage = null;
    return .{ .arena = legacy.arena, .value = bundle };
}

fn validateFamily(bundle: Bundle) !void {
    if (std.mem.eql(u8, bundle.manifest.contract, identity)) {
        if ((bundle.guest == null) != (bundle.specialization == null) or bundle.lineage != null)
            return error.InvalidRealization;
    } else {
        const lineage = bundle.lineage orelse return error.InvalidRealization;
        if (bundle.guest == null or !std.mem.eql(u8, lineage.checker, derived_policy) or
            !std.mem.eql(u8, bundle.manifest.compiler.policy, derived_policy))
            return error.InvalidRealization;
    }
}

pub fn digest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

/// Retains the checked bundle and admitted image. This is deliberately named
/// Admitted, not Approved: possession or self-description grants no authority.
pub const Admitted = struct {
    core: ?*Core,
    content: projection.Owned(Bundle),
    program: *const data.program_image.Admitted,
    helpers: [4]*const data.program_image.Admitted,
    identity: Digest,

    pub fn init(a: std.mem.Allocator, bytes: []const u8, expected: Digest) !Admitted {
        if (!std.mem.eql(u8, &digest(bytes), &expected)) return error.ArtifactIdentityMismatch;
        var content = try decode(a, bytes);
        errdefer content.deinit();
        try validateManifest(content.value.manifest);
        var executable = try Prepared.init(a, content.value.image);
        errdefer executable.deinit();
        const program = executable.core.?.admitted();
        const m = content.value.manifest;
        if (!std.mem.eql(u8, &program.identity(), &m.image)) return error.ArtifactIdentityMismatch;
        const report = try profile.check(program, .{ .effects = &.{m.bridge} });
        if (!inventoryMatches(m.inventory, report)) return error.InvalidInventory;
        try validateFamily(content.value);
        var helpers: [4]*const data.program_image.Admitted = undefined;
        var helper_executables: [4]Prepared = undefined;
        var count: usize = 0;
        errdefer for (helper_executables[0..count]) |*helper| helper.deinit();
        const recovery = content.value.recovery;
        for ([_]Helper{
            recovery.projector, recovery.storage, recovery.clone_context, recovery.clone_rebase,
        }, 0..) |helper, i| {
            helper_executables[i] = try Prepared.init(a, helper.image);
            helpers[i] = helper_executables[i].core.?.admitted();
            count += 1;
            const checked = try profile.check(helpers[i], .{});
            if (!inventoryMatches(helper.inventory, checked)) return error.InvalidInventory;
        }
        try validateRecovery(program, content.value);
        // The canonical value codec rejects trailing data; this round trip also
        // rejects alternative natural-number spellings in reusable artifacts.
        const canonical = try @import("artifact.zig").encode(a, content.value);
        defer a.free(canonical);
        if (!std.mem.eql(u8, canonical, bytes)) return error.NonCanonicalArtifact;
        const core = try a.create(Core);
        core.* = .{
            .allocator = a,
            .content = content,
            .program = program,
            .helpers = helpers,
            .executable = executable,
            .helper_executables = helper_executables,
            .identity = expected,
            .encoded_length = bytes.len,
        };
        return .{
            .core = core,
            .content = content,
            .program = program,
            .helpers = helpers,
            .identity = expected,
        };
    }
    pub fn deinit(self: *Admitted) void {
        const core = self.core orelse return;
        self.core = null;
        core.release();
    }
    pub fn acquire(self: *const Admitted) !*Core {
        const core = self.core orelse return error.InvalidState;
        try core.retain();
        return core;
    }
    pub fn clone(self: *const Admitted) !Admitted {
        const core = try self.acquire();
        return .{
            .core = core,
            .content = core.content,
            .program = core.program,
            .helpers = core.helpers,
            .identity = core.identity,
        };
    }
    pub fn encode(self: *const Admitted, a: std.mem.Allocator) ![]u8 {
        const core = try self.acquire();
        defer core.release();
        return @import("artifact.zig").encode(a, core.content.value);
    }
    pub fn bridge(self: *const Admitted) profile.Bridge {
        return .{ .effects = self.program.program().effects };
    }
};

pub const Core = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    content: projection.Owned(Bundle),
    program: *const data.program_image.Admitted,
    helpers: [4]*const data.program_image.Admitted,
    executable: Prepared,
    helper_executables: [4]Prepared,
    identity: Digest,
    encoded_length: usize,

    pub fn retain(self: *Core) !void {
        var current = self.references.load(.monotonic);
        while (true) { // tiger: event-loop
            std.debug.assert(current != 0);
            const next = try std.math.add(usize, current, 1);
            current = self.references.cmpxchgWeak(
                current,
                next,
                .monotonic,
                .monotonic,
            ) orelse return;
        }
    }
    pub fn release(self: *Core) void {
        const prior = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(prior != 0);
        if (prior != 1) return;
        self.executable.deinit();
        for (&self.helper_executables) |*helper| helper.deinit();
        self.content.deinit();
        self.allocator.destroy(self);
    }
    pub fn storageBytes(self: *const Core) !usize {
        var bytes = @sizeOf(Core) + self.content.arena.queryCapacity() +
            try self.executable.storageBytes();
        for (&self.helper_executables) |*helper| bytes += try helper.storageBytes();
        return bytes;
    }
};

fn inventoryMatches(actual: Inventory, expected: profile.Report) bool {
    return actual.instructions == expected.instructions and
        actual.blocks == expected.blocks and actual.functions == expected.functions and
        sameTags(
            data.program.Opcode,
            actual.opcodes,
            expected.opcodes,
        ) and sameTags(data.program.TerminatorTag, actual.terminators, expected.terminators) and
        sameTags(data.program.SchemaTag, actual.schemas, expected.schemas);
}

fn sameTags(comptime T: type, actual: []const T, expected: std.EnumSet(T)) bool {
    var i: usize = 0;
    for (std.meta.tags(T)) |tag| if (expected.contains(tag)) {
        if (i == actual.len or actual[i] != tag) return false;
        i += 1;
    };
    return i == actual.len;
}

pub fn inventory(a: std.mem.Allocator, report: profile.Report) !Inventory {
    return .{
        .opcodes = try tags(data.program.Opcode, a, report.opcodes),
        .terminators = try tags(data.program.TerminatorTag, a, report.terminators),
        .schemas = try tags(data.program.SchemaTag, a, report.schemas),
        .instructions = report.instructions,
        .blocks = report.blocks,
        .functions = report.functions,
    };
}
fn tags(comptime T: type, a: std.mem.Allocator, set: std.EnumSet(T)) ![]const T {
    var result: std.ArrayList(T) = .empty;
    errdefer result.deinit(a);
    for (std.meta.tags(T)) |tag| if (set.contains(tag)) try result.append(a, tag);
    return result.toOwnedSlice(a);
}

fn validateManifest(m: Manifest) !void {
    if ((!std.mem.eql(u8, m.contract, identity) and
        !std.mem.eql(u8, m.contract, derived_identity)) or
        !std.mem.eql(u8, m.requirements.base, profile.identity) or
        !std.mem.eql(u8, m.requirements.admission, admission_profile) or
        !std.mem.eql(u8, m.requirements.bridge, service.identity) or
        !std.mem.eql(u8, m.bridge.identity, service.identity)) return error.UnsupportedArtifact;
}

fn validateRecovery(program: *const data.program_image.Admitted, content: Bundle) !void {
    for (content.recovery.anchors) |anchor| {
        const p = program.program();
        if (anchor.function >= p.functions.len or
            anchor.parameters.len == 0) return error.InvalidRecovery;
        const f = p.functions[@intCast(anchor.function)];
        for (anchor.parameters, 0..) |parameter, i| {
            if (parameter.slot >= f.layout.slots.len or
                f.layout.slots[@intCast(parameter.slot)] != parameter.schema or
                std.mem.indexOfScalar(
                    data.program.Id,
                    f.inputs,
                    parameter.slot,
                ) == null) return error.InvalidRecovery;
            for (anchor.parameters[0..i]) |prior| if (prior.ordinal == parameter.ordinal or
                prior.slot == parameter.slot) return error.InvalidRecovery;
        }
        const arity: usize = switch (anchor.role) {
            .clone_rebase => 4,
            .clone_context => 2,
            else => 1,
        };
        if (anchor.parameters.len != arity) return error.InvalidRecovery;
    }
    for ([_][]const data.program.Id{
        content.branch_returns, content.template_entries,
    }) |functions| {
        for (functions, 0..) |function, i| {
            if (function >= program.program().functions.len or std.mem.indexOfScalar(
                data.program.Id,
                functions[0..i],
                function,
            ) != null) return error.InvalidRecovery;
        }
    }
}
