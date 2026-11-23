const std = @import("std");
const runtime = @import("../runtime_sources.zig");
const legacy = runtime.compiler;
const backend = @import("recovery_backend.zig");
const artifact = runtime.artifact;

const export_source = @import("recovery_export.zig");

pub const recovery_policy = backend.policy;
pub const recovery_limits = backend.limits;
pub const recoveryContext = backend.context;
pub const RecoveryEvidence = backend.Evidence;
pub const RecoveryDerivation = backend.Derivation;

pub const Options = struct {
    horos_package: []const u8 = runtime.packaged.horos_package,
    guest: @FieldType(legacy.Options, "guest") = null,
    hooks: @FieldType(legacy.Options, "hooks") = .{},
    policy: @FieldType(legacy.Options, "policy") = (legacy.Options{ .horos_package = "" }).policy,
    scalar_field_reuse: bool = false,
};

pub fn compile(a: std.mem.Allocator, options: Options) ![]u8 {
    const original: legacy.Options = .{
        .horos_package = options.horos_package,
        .guest = options.guest,
        .hooks = options.hooks,
        .policy = options.policy,
    };
    if (options.scalar_field_reuse) return backend.compile(a, original);
    return legacy.compile(a, original);
}

pub fn validate(a: std.mem.Allocator, admitted: *const artifact.Admitted) !void {
    return validateWithPolicy(a, admitted, .{});
}

pub fn validateWithPolicy(
    a: std.mem.Allocator,
    admitted: *const artifact.Admitted,
    policy: ValidationPolicy,
) !void {
    var owned = try admitted.clone();
    defer owned.deinit();
    if (std.mem.eql(u8, owned.content.value.manifest.compiler.policy, recovery_policy))
        return backend.validate(a, &owned);
    return legacy.validateWithPolicy(a, &owned, policy);
}

pub fn validateAgainst(
    a: std.mem.Allocator,
    candidate: *const artifact.Admitted,
    ancestor: *const artifact.Admitted,
) !void {
    var owned = try candidate.clone();
    defer owned.deinit();
    var parent = try ancestor.clone();
    defer parent.deinit();
    if (!std.mem.eql(u8, owned.content.value.manifest.compiler.policy, recovery_policy))
        return legacy.validateAgainst(a, &owned, &parent);
    if (!std.mem.eql(u8, &owned.identity, &parent.identity)) return error.InvalidAncestor;
    return backend.validate(a, &owned);
}

pub const checker_identity = legacy.checker_identity;
pub const Proposal = legacy.Proposal;
pub const RecordProposal = legacy.RecordProposal;
pub const ProposedInterfaces = legacy.ProposedInterfaces;
pub const DeriveOptions = legacy.DeriveOptions;
pub const ValidationPolicy = legacy.ValidationPolicy;
pub const derive = legacy.derive;
pub const deriveRecord = legacy.deriveRecord;
pub const approvedRootIdentity = legacy.approvedRootIdentity;
pub const Derivation = legacy.Derivation;
pub const Evidence = legacy.Evidence;
pub const SourceDefinition = legacy.SourceDefinition;
pub const SourceModule = legacy.SourceModule;
pub const SourceReferences = legacy.SourceReferences;
pub const OwnedSourceReferences = legacy.OwnedSourceReferences;
pub const sourceReferences = legacy.sourceReferences;
pub const SourceHelper = legacy.SourceHelper;
pub const PureEntry = legacy.PureEntry;
pub const SourceEntries = legacy.SourceEntries;
pub const SourceBundle = legacy.SourceBundle;
pub const ExportedSource = legacy.ExportedSource;
pub const exportSource = legacy.exportSource;
pub const exportBuiltinSource = legacy.exportBuiltinSource;
pub const RecoverySourceBundle = export_source.RecoverySourceBundle;
pub const ExportedRecoverySource = export_source.ExportedRecoverySource;
pub const exportRecoverySource = export_source.exportRecoverySource;
pub const sourceModule = legacy.sourceModule;
pub const context = legacy.context;
pub const contextWithHooks = legacy.contextWithHooks;
pub const SourceRole = legacy.SourceRole;
pub const anchorsForRoles = legacy.anchorsForRoles;
